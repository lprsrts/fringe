// The solved field, drawn by the core's renderer, with the scene's elements
// and sources as things you can pick up and move. The canvas always shows
// exactly the scene's domain, so a pointer position maps straight to µm.
import {useCallback, useEffect, useLayoutEffect, useRef, useState, type ReactNode} from 'react';
import type {Solver} from './solver';
import {extentOf, itemsOf, objectOf, reachOf, round, sameItem, type Item, type Scene} from './scene';

interface Props {
  solver: Solver;
  scene: Scene;
  /** Changes whenever a new field is stored in the worker; 0 for none. */
  fieldVersion: number;
  /** View JSON without the phase. */
  view: Record<string, unknown>;
  animate: boolean;
  selected: Item | null;
  onSelect: (item: Item | null) => void;
  onMove: (item: Item, x: number, y: number) => void;
  label: string;
  /** Shown right under the field (the status line). */
  footer?: ReactNode;
  /** Fit inside the box's height too; off where the page scrolls (phones). */
  fitHeight?: boolean;
}

export function FieldCanvas({solver, scene, fieldVersion, view, animate, selected, onSelect, onMove, label, footer, fitHeight = true}: Props) {
  const box = useRef<HTMLDivElement>(null);
  const field = useRef<HTMLCanvasElement>(null);
  const marks = useRef<HTMLCanvasElement>(null);
  const foot = useRef<HTMLDivElement>(null);
  const [size, setSize] = useState({w: 0, h: 0, dpr: 1});
  const [hover, setHover] = useState<Item | null>(null);
  const drag = useRef<{item: Item; dx: number; dy: number} | null>(null);
  const d = scene.domain;
  const spanX = d.x_max_um - d.x_min_um;
  const spanY = d.y_max_um - d.y_min_um;

  // Fit the domain's aspect ratio inside the box.
  useLayoutEffect(() => {
    const el = box.current;
    if (!el) return;
    const fit = () => {
      const {width, height} = el.getBoundingClientRect();
      const reserved = foot.current ? foot.current.getBoundingClientRect().height + 8 : 0;
      const scale = fitHeight && height ? Math.min(width / spanX, (height - reserved) / spanY) : width / spanX;
      const w = Math.max(1, Math.floor(spanX * scale));
      const h = Math.max(1, Math.floor(spanY * scale));
      setSize({w, h, dpr: Math.min(window.devicePixelRatio || 1, 2)});
    };
    fit();
    const ro = new ResizeObserver(fit);
    ro.observe(el);
    if (foot.current) ro.observe(foot.current);
    return () => ro.disconnect();
  }, [spanX, spanY, fitHeight]);

  // Render the stored field. One render at a time; the newest request wins.
  const rendering = useRef(false);
  const queued = useRef<string | null>(null);
  const phase = useRef(0);
  const viewJson = useCallback(
    () =>
      JSON.stringify({
        ...view,
        phase_deg: animate ? phase.current : 0,
        view_um: {x_min_um: d.x_min_um, x_max_um: d.x_max_um, y_min_um: d.y_min_um, y_max_um: d.y_max_um},
        outlines: true,
      }),
    [view, animate, d.x_min_um, d.x_max_um, d.y_min_um, d.y_max_um],
  );

  const draw = useCallback(async () => {
    const canvas = field.current;
    if (!canvas || !fieldVersion || !size.w) return;
    const json = viewJson();
    if (rendering.current) {
      queued.current = json;
      return;
    }
    rendering.current = true;
    try {
      let next: string | null = json;
      while (next) {
        queued.current = null;
        const width = Math.round(size.w * size.dpr);
        const height = Math.round(size.h * size.dpr);
        const rgba = await solver.render(next, width, height);
        canvas.width = width;
        canvas.height = height;
        canvas.getContext('2d')!.putImageData(new ImageData(new Uint8ClampedArray(rgba.buffer as ArrayBuffer), width, height), 0, 0);
        next = queued.current;
      }
    } catch {
      // The worker was replaced (a stop or a crash); the next solve redraws.
    } finally {
      rendering.current = false;
    }
  }, [solver, fieldVersion, size, viewJson]);

  useEffect(() => {
    draw();
  }, [draw]);

  // Turn the phase for the field and phase views; the colour scale comes from
  // |E|, which doesn't change with the phase, so only the wave moves.
  useEffect(() => {
    if (!animate || !fieldVersion) return;
    let frame = 0;
    let last = performance.now();
    const tick = (now: number) => {
      // One optical cycle every two seconds, whatever the frame rate.
      phase.current = (phase.current + ((now - last) / 2000) * 360) % 360;
      last = now;
      if (!rendering.current) draw();
      frame = requestAnimationFrame(tick);
    };
    frame = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(frame);
  }, [animate, fieldVersion, draw]);

  // Pointer ↔ µm.
  const toUm = (e: {clientX: number; clientY: number}) => {
    const r = marks.current!.getBoundingClientRect();
    return {
      x: d.x_min_um + ((e.clientX - r.left) / r.width) * spanX,
      y: d.y_max_um - ((e.clientY - r.top) / r.height) * spanY,
    };
  };
  const toPx = (x: number, y: number) => ({
    x: ((x - d.x_min_um) / spanX) * size.w,
    y: ((d.y_max_um - y) / spanY) * size.h,
  });

  const pick = (x: number, y: number): Item | null => {
    // A finger needs more room than a mouse: at least 14 px either way.
    const slack = (14 / size.w) * spanX;
    let best: Item | null = null;
    let bestScore = Infinity;
    for (const item of itemsOf(scene)) {
      const o = objectOf(scene, item);
      const dist = Math.hypot(x - Number(o[item.xKey]), y - Number(o[item.yKey]));
      const reach = Math.max(reachOf(scene, item), slack);
      if (dist <= reach && dist / reach < bestScore) {
        best = item;
        bestScore = dist / reach;
      }
    }
    return best;
  };

  const onPointerDown = (e: React.PointerEvent) => {
    const p = toUm(e);
    const item = pick(p.x, p.y);
    onSelect(item);
    if (!item) return;
    const o = objectOf(scene, item);
    drag.current = {item, dx: Number(o[item.xKey]) - p.x, dy: Number(o[item.yKey]) - p.y};
    (e.target as Element).setPointerCapture(e.pointerId);
    e.preventDefault();
  };

  const onPointerMove = (e: React.PointerEvent) => {
    const p = toUm(e);
    if (drag.current) {
      const {item, dx, dy} = drag.current;
      const x = Math.min(d.x_max_um, Math.max(d.x_min_um, p.x + dx));
      const y = Math.min(d.y_max_um, Math.max(d.y_min_um, p.y + dy));
      onMove(item, round(x, 2), round(y, 2));
    } else if (e.pointerType === 'mouse') {
      const item = pick(p.x, p.y);
      if (!sameItem(item, hover)) setHover(item);
    }
  };

  const endDrag = () => {
    drag.current = null;
  };

  const onKeyDown = (e: React.KeyboardEvent) => {
    if (!selected) return;
    const step = e.shiftKey ? 1 : 0.1;
    const delta = {ArrowLeft: [-step, 0], ArrowRight: [step, 0], ArrowUp: [0, step], ArrowDown: [0, -step]}[e.key];
    if (!delta) {
      if (e.key === 'Escape') onSelect(null);
      return;
    }
    e.preventDefault();
    const o = objectOf(scene, selected);
    onMove(selected, round(Number(o[selected.xKey]) + delta[0], 2), round(Number(o[selected.yKey]) + delta[1], 2));
  };

  // Selection and hover marks over the field.
  useEffect(() => {
    const canvas = marks.current;
    if (!canvas || !size.w) return;
    canvas.width = Math.round(size.w * size.dpr);
    canvas.height = Math.round(size.h * size.dpr);
    const g = canvas.getContext('2d')!;
    g.scale(size.dpr, size.dpr);
    // Corner brackets around the element's footprint: amber when selected,
    // dashed white on hover. A dark halo keeps them visible on bright field.
    const mark = (item: Item, strong: boolean) => {
      const o = objectOf(scene, item);
      const c = toPx(Number(o[item.xKey]), Number(o[item.yKey]));
      const e = extentOf(scene, item);
      const pad = 6;
      const hx = (e.hx / spanX) * size.w + pad;
      const hy = (e.hy / spanY) * size.h + pad;
      const arm = Math.min(12, hx, hy);
      const path = () => {
        g.beginPath();
        for (const [sx, sy] of [[-1, -1], [1, -1], [1, 1], [-1, 1]]) {
          const x = c.x + sx * hx;
          const y = c.y + sy * hy;
          g.moveTo(x - sx * arm, y);
          g.lineTo(x, y);
          g.lineTo(x, y - sy * arm);
        }
      };
      g.lineCap = 'round';
      g.setLineDash(strong ? [] : [3, 3]);
      g.lineWidth = strong ? 4 : 3;
      g.strokeStyle = 'rgba(0,0,0,0.5)';
      path();
      g.stroke();
      g.lineWidth = strong ? 2 : 1.25;
      g.strokeStyle = strong ? '#f3c623' : 'rgba(255,255,255,0.9)';
      path();
      g.stroke();
    };
    if (hover && !sameItem(hover, selected)) mark(hover, false);
    if (selected) mark(selected, true);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [scene, selected, hover, size]);

  const cursor = drag.current ? 'grabbing' : hover ? 'grab' : 'default';

  return (
    <div className="field-box" ref={box}>
      <div className="field-column" style={{width: size.w || undefined}}>
      <div className="field-frame" style={{width: size.w, height: size.h}}>
        <canvas ref={field} className="field" aria-hidden="true" />
        <canvas
          ref={marks}
          className="marks"
          style={{cursor}}
          tabIndex={0}
          role="application"
          aria-label={label}
          onPointerDown={onPointerDown}
          onPointerMove={onPointerMove}
          onPointerUp={endDrag}
          onPointerCancel={endDrag}
          onPointerLeave={() => setHover(null)}
          onKeyDown={onKeyDown}
        />
      </div>
      {footer && (
        <div className="field-footer" ref={foot}>
          {footer}
        </div>
      )}
      </div>
    </div>
  );
}
