// The solved field, drawn by the core's renderer, with interactive overlays for
// elements, sources, detectors and puzzle constraints. The canvas always shows
// exactly the scene's domain, so a pointer position maps straight to µm.
import {useCallback, useEffect, useLayoutEffect, useRef, useState} from 'react';
import type {BodyOutline, SceneOutlines, Solver} from './solver';
import {
  detectorNormal,
  extentOf,
  makeItem,
  objectOf,
  positionKeys,
  reachOf,
  round,
  sameItem,
  shiftDetector,
  type Item,
  type Json,
  type Scene,
} from './scene';

export interface PuzzleOverlayState {
  region: [number, number, number, number];
  lockedIds: Set<string>;
  sourceLabels: Record<string, string>;
  outOfRegionIds: Set<string>;
}

interface Props {
  solver: Solver;
  scene: Scene;
  outlines: SceneOutlines | null;
  /** Changes whenever a new field is stored in the worker; 0 for none. */
  fieldVersion: number;
  /** True when all sources are off in a truth-table puzzle before Check. */
  darkCase?: boolean;
  /** View JSON without the phase. */
  view: Record<string, unknown>;
  animate: boolean;
  selected: Item | null;
  onSelect: (item: Item | null) => void;
  onEdit: (change: (draft: Scene) => void) => void;
  onDelete?: (item: Item) => void;
  /** Floating text badge beside each enabled detector, keyed by detector id. */
  detectorLabels?: Record<string, string>;
  readingsStale?: boolean;
  /** True while the shown field was solved for an earlier version of the scene. */
  fieldStale?: boolean;
  puzzleOverlay?: PuzzleOverlayState | null;
  label: string;
  /** Fit inside the box's height too; off where the page scrolls (phones). */
  fitHeight?: boolean;
  /** Reports the shape (width ÷ height) of the space the field can fill. */
  onAspect?: (aspect: number) => void;
  /** Read-only embed mode disables editing handles and dragging. */
  readOnly?: boolean;
}

type DragMode =
  | {
      kind: 'move';
      item: Item;
      startX: number;
      startY: number;
      origX: number;
      origY: number;
      /** Allowed range of the position, so the whole body stays inside the domain. */
      bounds: {x0: number; x1: number; y0: number; y1: number};
    }
  | {kind: 'beamAngle'; item: Item}
  | {kind: 'detMove'; item: Item; lastX: number; lastY: number}
  | {kind: 'lineEnd'; item: Item; end: 1 | 2}
  | {kind: 'boxCorner'; item: Item; oppX: number; oppY: number};

function pointInPolygon(x: number, y: number, poly: [number, number][]): boolean {
  let inside = false;
  for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    const [xi, yi] = poly[i];
    const [xj, yj] = poly[j];
    const intersect = yi > y !== yj > y && x < ((xj - xi) * (y - yi)) / (yj - yi + 1e-18) + xi;
    if (intersect) inside = !inside;
  }
  return inside;
}

function distToSegment(px: number, py: number, x1: number, y1: number, x2: number, y2: number): number {
  const dx = x2 - x1;
  const dy = y2 - y1;
  const len2 = dx * dx + dy * dy;
  if (len2 <= 1e-12) return Math.hypot(px - x1, py - y1);
  const t = Math.max(0, Math.min(1, ((px - x1) * dx + (py - y1) * dy) / len2));
  return Math.hypot(px - (x1 + t * dx), py - (y1 + t * dy));
}

/** Copies `from` onto `over` and fades `over` out, so the next image `from` shows blends in. */
function crossfade(from: HTMLCanvasElement, over: HTMLCanvasElement | null) {
  if (!over || !from.width || !from.height) return;
  over.width = from.width;
  over.height = from.height;
  over.getContext('2d')!.drawImage(from, 0, 0);
  over.style.transition = 'none';
  over.style.opacity = '1';
  // Commit the opaque state before starting the transition.
  void over.offsetWidth;
  over.style.transition = '';
  over.style.opacity = '0';
}

function beamArrowLength(waistUm: number, spanX: number): number {
  return Math.max(2.5 * waistUm, 0.12 * spanX);
}

const ACCENT = '#f3c623';
const BEAM_COLOR = 'rgba(89, 230, 255, 0.95)';
const BEAM_DIM = 'rgba(89, 230, 255, 0.45)';
const DETECTOR_COLOR = 'rgba(255, 194, 74, 0.95)';
const DETECTOR_DIM = 'rgba(255, 194, 74, 0.45)';
const WARNING_COLOR = '#ff9e0a';

export function FieldCanvas({
  solver,
  scene,
  outlines,
  fieldVersion,
  darkCase = false,
  view,
  animate,
  selected,
  onSelect,
  onEdit,
  onDelete,
  detectorLabels = {},
  readingsStale = false,
  fieldStale = false,
  puzzleOverlay = null,
  label,
  fitHeight = true,
  onAspect,
  readOnly = false,
}: Props) {
  const box = useRef<HTMLDivElement>(null);
  const field = useRef<HTMLCanvasElement>(null);
  // The previous field, laid over the new one and faded out when a solve lands.
  const fade = useRef<HTMLCanvasElement>(null);
  const shownVersion = useRef(0);
  const marks = useRef<HTMLCanvasElement>(null);
  const [size, setSize] = useState({w: 0, h: 0, dpr: 1});
  const [hover, setHover] = useState<Item | null>(null);
  const [cursorStyle, setCursorStyle] = useState<'default' | 'grab' | 'grabbing' | 'crosshair'>('default');
  const drag = useRef<DragMode | null>(null);
  const d = scene.domain;
  const spanX = d.x_max_um - d.x_min_um;
  const spanY = d.y_max_um - d.y_min_um;

  // Fit the domain's aspect ratio inside the box.
  useLayoutEffect(() => {
    const el = box.current;
    if (!el) return;
    const fit = () => {
      const {width, height} = el.getBoundingClientRect();
      if (fitHeight && width && height) onAspect?.(width / height);
      const scale = fitHeight && height ? Math.min(width / spanX, height / spanY) : width / spanX;
      const w = Math.max(1, Math.floor(spanX * scale));
      const h = Math.max(1, Math.floor(spanY * scale));
      setSize({w, h, dpr: Math.min(window.devicePixelRatio || 1, 2)});
    };
    fit();
    const ro = new ResizeObserver(fit);
    ro.observe(el);
    return () => ro.disconnect();
  }, [spanX, spanY, fitHeight, onAspect]);

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
        // The overlay draws the outlines from the current scene, so they
        // follow edits at once instead of waiting for the next solve.
        outlines: false,
      }),
    [view, animate, d.x_min_um, d.x_max_um, d.y_min_um, d.y_max_um],
  );

  const draw = useCallback(async () => {
    const canvas = field.current;
    if (!canvas || !size.w) return;
    if (darkCase) {
      const width = Math.round(size.w * size.dpr);
      const height = Math.round(size.h * size.dpr);
      canvas.width = width;
      canvas.height = height;
      const ctx = canvas.getContext('2d')!;
      ctx.fillStyle = '#000';
      ctx.fillRect(0, 0, width, height);
      return;
    }
    if (!fieldVersion) return;
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
        const version = fieldVersion;
        const rgba = await solver.render(next, width, height);
        if (version !== shownVersion.current) {
          crossfade(canvas, fade.current);
          shownVersion.current = version;
        }
        canvas.width = width;
        canvas.height = height;
        canvas
          .getContext('2d')!
          .putImageData(new ImageData(new Uint8ClampedArray(rgba.buffer as ArrayBuffer), width, height), 0, 0);
        next = queued.current;
      }
    } catch {
      // The worker was replaced (a stop or a crash); the next solve redraws.
    } finally {
      rendering.current = false;
    }
  }, [solver, fieldVersion, darkCase, size, viewJson]);

  useEffect(() => {
    draw();
  }, [draw]);

  // Turn the phase for the field and phase views.
  useEffect(() => {
    if (!animate || !fieldVersion || darkCase) return;
    let frame = 0;
    let last = performance.now();
    const tick = (now: number) => {
      phase.current = (phase.current + ((now - last) / 2000) * 360) % 360;
      last = now;
      if (!rendering.current) draw();
      frame = requestAnimationFrame(tick);
    };
    frame = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(frame);
  }, [animate, fieldVersion, darkCase, draw]);

  // Pointer ↔ µm.
  const toUm = (e: {clientX: number; clientY: number}) => {
    const r = marks.current!.getBoundingClientRect();
    return {
      x: d.x_min_um + ((e.clientX - r.left) / r.width) * spanX,
      y: d.y_max_um - ((e.clientY - r.top) / r.height) * spanY,
    };
  };
  const toPx = useCallback(
    (x: number, y: number) => ({
      x: ((x - d.x_min_um) / spanX) * size.w,
      y: ((d.y_max_um - y) / spanY) * size.h,
    }),
    [d.x_min_um, d.y_max_um, spanX, spanY, size.w, size.h],
  );

  const isLocked = useCallback(
    (item: Item) => {
      if (readOnly) return true;
      if (!puzzleOverlay) return false;
      if (item.kind !== 'element') return true;
      return puzzleOverlay.lockedIds.has(item.id);
    },
    [puzzleOverlay, readOnly],
  );

  // Check if pointer hits an active resize/rotate handle on the selected item.
  const pickHandle = (x: number, y: number): DragMode | null => {
    if (readOnly || !selected || isLocked(selected) || !size.w) return null;
    const o = objectOf(scene, selected);
    if (!o) return null;
    const hitTol = (12 / size.w) * spanX;
    if (selected.kind === 'source' && o.type === 'gaussian_beam' && !puzzleOverlay) {
      const a = (Number(o.angle_deg ?? 0) * Math.PI) / 180;
      const len = beamArrowLength(Number(o.waist_um ?? 1), spanX);
      const hx = Number(o.waist_x_um) + len * Math.cos(a);
      const hy = Number(o.waist_y_um) + len * Math.sin(a);
      if (Math.hypot(x - hx, y - hy) <= hitTol) return {kind: 'beamAngle', item: selected};
    }
    if (selected.kind === 'detector' && !puzzleOverlay) {
      const s = o.shape as Json;
      if (s.kind === 'line') {
        if (Math.hypot(x - Number(s.x1_um), y - Number(s.y1_um)) <= hitTol) return {kind: 'lineEnd', item: selected, end: 1};
        if (Math.hypot(x - Number(s.x2_um), y - Number(s.y2_um)) <= hitTol) return {kind: 'lineEnd', item: selected, end: 2};
      } else if (s.kind === 'box') {
        const cx = Number(s.x_um), cy = Number(s.y_um), hw = Number(s.width_um) / 2, hh = Number(s.height_um) / 2;
        const corners: [number, number, number, number][] = [
          [cx - hw, cy - hh, cx + hw, cy + hh],
          [cx + hw, cy - hh, cx - hw, cy + hh],
          [cx + hw, cy + hh, cx - hw, cy - hh],
          [cx - hw, cy + hh, cx + hw, cy - hh],
        ];
        for (const [kx, ky, ox, oy] of corners) {
          if (Math.hypot(x - kx, y - ky) <= hitTol) return {kind: 'boxCorner', item: selected, oppX: ox, oppY: oy};
        }
      }
    }
    return null;
  };

  const pick = (x: number, y: number): Item | null => {
    if (readOnly || !size.w) return null;
    const slack = (14 / size.w) * spanX;

    // 1. Detectors (simulator mode only).
    if (!puzzleOverlay) {
      let bestDet: Item | null = null;
      let bestDetDist = Infinity;
      scene.detectors.forEach((det, index) => {
        const s = det.shape as Json;
        let dist = Infinity;
        if (s.kind === 'line') {
          dist = distToSegment(x, y, Number(s.x1_um), Number(s.y1_um), Number(s.x2_um), Number(s.y2_um));
          if (dist > slack) return;
        } else if (s.kind === 'box') {
          const cx = Number(s.x_um), cy = Number(s.y_um), hw = Number(s.width_um) / 2, hh = Number(s.height_um) / 2;
          const dx = Math.max(0, Math.abs(x - cx) - hw);
          const dy = Math.max(0, Math.abs(y - cy) - hh);
          dist = Math.hypot(dx, dy);
          if (dist > slack * 0.75) return;
        }
        if (dist < bestDetDist) {
          bestDetDist = dist;
          bestDet = makeItem('detector', scene.detectors, index);
        }
      });
      if (bestDet) return bestDet;
    }

    // 2. Elements: exact outline polygon hit first, then proximity fallback.
    const bodiesById = new Map<string, BodyOutline[]>();
    if (outlines) {
      for (const b of outlines.bodies) {
        const arr = bodiesById.get(b.element_id);
        if (arr) arr.push(b);
        else bodiesById.set(b.element_id, [b]);
      }
    }

    for (let index = scene.elements.length - 1; index >= 0; index--) {
      const el = scene.elements[index];
      const item = makeItem('element', scene.elements, index);
      if (isLocked(item)) continue;
      const bodies = bodiesById.get(String(el.id));
      if (bodies && bodies.length > 0) {
        if (bodies.some((b) => pointInPolygon(x, y, b.outline))) return item;
        // Also allow picking thin slabs/mirrors within touch slack of any contour edge.
        const nearEdge = bodies.some((b) => {
          const pts = b.outline;
          for (let i = 0; i < pts.length; i++) {
            const [ax, ay] = pts[i];
            const [bx, by] = pts[(i + 1) % pts.length];
            if (distToSegment(x, y, ax, ay, bx, by) <= slack * 0.65) return true;
          }
          return false;
        });
        if (nearEdge) return item;
      }
    }

    // 3. Sources (simulator mode only) and elements without outlines yet.
    let best: Item | null = null;
    let bestScore = Infinity;
    const candidates: Item[] = [];
    scene.elements.forEach((_, i) => candidates.push(makeItem('element', scene.elements, i)));
    if (!puzzleOverlay) scene.sources.forEach((_, i) => candidates.push(makeItem('source', scene.sources, i)));

    for (const item of candidates) {
      if (isLocked(item)) continue;
      const o = objectOf(scene, item);
      if (!o) continue;
      const keys = positionKeys(item, o);
      if (!keys) continue;
      const dist = Math.hypot(x - Number(o[keys[0]]), y - Number(o[keys[1]]));
      const reach = Math.max(reachOf(scene, item), slack);
      if (dist <= reach && dist / reach < bestScore) {
        best = item;
        bestScore = dist / reach;
      }
    }
    return best;
  };

  const onPointerDown = (e: React.PointerEvent) => {
    if (readOnly) return;
    const p = toUm(e);
    const handle = pickHandle(p.x, p.y);
    if (handle) {
      drag.current = handle;
      setCursorStyle('grabbing');
      (e.target as Element).setPointerCapture(e.pointerId);
      e.preventDefault();
      return;
    }
    const item = pick(p.x, p.y);
    onSelect(item);
    if (!item || isLocked(item)) return;
    const o = objectOf(scene, item);
    if (!o) return;
    if (item.kind === 'detector') {
      drag.current = {kind: 'detMove', item, lastX: p.x, lastY: p.y};
    } else {
      const keys = positionKeys(item, o);
      if (!keys) return;
      const origX = Number(o[keys[0]]);
      const origY = Number(o[keys[1]]);
      drag.current = {kind: 'move', item, startX: p.x, startY: p.y, origX, origY, bounds: moveBounds(item, origX, origY)};
    }
    setCursorStyle('grabbing');
    (e.target as Element).setPointerCapture(e.pointerId);
    e.preventDefault();
  };

  /**
   * Where a dragged item's position may go: an element's whole body (its exact
   * outline, or its rough extent before outlines arrive) stays inside the
   * domain with the solver's quarter-wavelength margin. A drag past the edge
   * otherwise makes the scene invalid, and solving stops until it is undone.
   */
  const moveBounds = (item: Item, x: number, y: number) => {
    const open = {x0: d.x_min_um, x1: d.x_max_um, y0: d.y_min_um, y1: d.y_max_um};
    if (item.kind !== 'element') return open;
    const margin = (0.25 * scene.wavelength_um) / (scene.background?.n || 1) + 0.01;
    const pts = (outlines?.bodies ?? []).filter((b) => b.element_id === item.id).flatMap((b) => b.outline);
    let lo: {x: number; y: number};
    let hi: {x: number; y: number};
    if (pts.length) {
      lo = {x: Math.min(...pts.map((q) => q[0])) - x, y: Math.min(...pts.map((q) => q[1])) - y};
      hi = {x: Math.max(...pts.map((q) => q[0])) - x, y: Math.max(...pts.map((q) => q[1])) - y};
    } else {
      const {hx, hy} = extentOf(scene, item);
      lo = {x: -hx, y: -hy};
      hi = {x: hx, y: hy};
    }
    const b = {
      x0: d.x_min_um + margin - lo.x,
      x1: d.x_max_um - margin - hi.x,
      y0: d.y_min_um + margin - lo.y,
      y1: d.y_max_um - margin - hi.y,
    };
    // A body bigger than the domain can't fit anywhere: keep the plain limits.
    return b.x0 <= b.x1 && b.y0 <= b.y1 ? b : open;
  };

  const onPointerMove = (e: React.PointerEvent) => {
    if (readOnly) return;
    const p = toUm(e);
    const cur = drag.current;
    if (cur) {
      if (cur.kind === 'move') {
        const {x0, x1, y0, y1} = cur.bounds;
        const nx = Math.min(x1, Math.max(x0, cur.origX + (p.x - cur.startX)));
        const ny = Math.min(y1, Math.max(y0, cur.origY + (p.y - cur.startY)));
        onEdit((draft) => {
          const o = objectOf(draft, cur.item);
          if (!o) return;
          const keys = positionKeys(cur.item, o);
          if (!keys) return;
          o[keys[0]] = round(nx, 2);
          o[keys[1]] = round(ny, 2);
        });
      } else if (cur.kind === 'beamAngle') {
        onEdit((draft) => {
          const o = objectOf(draft, cur.item);
          if (!o) return;
          let deg = (Math.atan2(p.y - Number(o.waist_y_um), p.x - Number(o.waist_x_um)) * 180) / Math.PI;
          if (e.shiftKey) deg = Math.round(deg / 15) * 15;
          else deg = Math.round(deg);
          o.angle_deg = deg;
        });
      } else if (cur.kind === 'detMove') {
        const dx = p.x - cur.lastX;
        const dy = p.y - cur.lastY;
        cur.lastX = p.x;
        cur.lastY = p.y;
        onEdit((draft) => {
          const o = objectOf(draft, cur.item);
          if (o) shiftDetector(o, dx, dy, draft.domain);
        });
      } else if (cur.kind === 'lineEnd') {
        const nx = round(Math.min(d.x_max_um, Math.max(d.x_min_um, p.x)), 2);
        const ny = round(Math.min(d.y_max_um, Math.max(d.y_min_um, p.y)), 2);
        onEdit((draft) => {
          const o = objectOf(draft, cur.item);
          const s = o?.shape as Json | undefined;
          if (!s || s.kind !== 'line') return;
          if (cur.end === 1) { s.x1_um = nx; s.y1_um = ny; }
          else { s.x2_um = nx; s.y2_um = ny; }
        });
      } else if (cur.kind === 'boxCorner') {
        const nx = Math.min(d.x_max_um, Math.max(d.x_min_um, p.x));
        const ny = Math.min(d.y_max_um, Math.max(d.y_min_um, p.y));
        const w = Math.max(0.1, Math.abs(nx - cur.oppX));
        const h = Math.max(0.1, Math.abs(ny - cur.oppY));
        const cx = (nx + cur.oppX) / 2;
        const cy = (ny + cur.oppY) / 2;
        onEdit((draft) => {
          const o = objectOf(draft, cur.item);
          const s = o?.shape as Json | undefined;
          if (!s || s.kind !== 'box') return;
          s.x_um = round(cx, 2);
          s.y_um = round(cy, 2);
          s.width_um = round(w, 2);
          s.height_um = round(h, 2);
        });
      }
      return;
    }
    if (e.pointerType === 'mouse') {
      const handle = pickHandle(p.x, p.y);
      if (handle) {
        setCursorStyle('crosshair');
        return;
      }
      const item = pick(p.x, p.y);
      if (!sameItem(item, hover)) setHover(item);
      setCursorStyle(item ? 'grab' : 'default');
    }
  };

  const endDrag = () => {
    drag.current = null;
    setCursorStyle(hover ? 'grab' : 'default');
  };

  const onKeyDown = (e: React.KeyboardEvent) => {
    if (readOnly || !selected) return;
    if (e.key === 'Escape') {
      onSelect(null);
      return;
    }
    if ((e.key === 'Delete' || e.key === 'Backspace') && onDelete && !isLocked(selected)) {
      e.preventDefault();
      onDelete(selected);
      return;
    }
    if (isLocked(selected)) return;
    if ((e.key === 'r' || e.key === 'R') && selected.kind === 'element') {
      e.preventDefault();
      const step = e.altKey ? 1 : 5;
      const dir = e.shiftKey ? -1 : 1;
      onEdit((draft) => {
        const o = objectOf(draft, selected);
        if (!o) return;
        o.rotation_deg = round(Number(o.rotation_deg ?? 0) + dir * step, 1);
      });
      return;
    }
    const step = e.shiftKey ? 1 : 0.1;
    const delta = {ArrowLeft: [-step, 0], ArrowRight: [step, 0], ArrowUp: [0, step], ArrowDown: [0, -step]}[e.key];
    if (!delta) return;
    e.preventDefault();
    onEdit((draft) => {
      const o = objectOf(draft, selected);
      if (!o) return;
      if (selected.kind === 'detector') {
        shiftDetector(o, delta[0], delta[1], draft.domain);
      } else {
        const keys = positionKeys(selected, o);
        if (!keys) return;
        o[keys[0]] = round(Number(o[keys[0]]) + delta[0], 2);
        o[keys[1]] = round(Number(o[keys[1]]) + delta[1], 2);
      }
    });
  };

  // Vector overlays: puzzle region, locked bodies, outlines, sources, detectors, labels, handles.
  useEffect(() => {
    const canvas = marks.current;
    if (!canvas || !size.w) return;
    canvas.width = Math.round(size.w * size.dpr);
    canvas.height = Math.round(size.h * size.dpr);
    const g = canvas.getContext('2d')!;
    g.scale(size.dpr, size.dpr);

    const drawArrow = (ax: number, ay: number, bx: number, by: number, color: string, dash: number[] = [], head = 7, wing = 3.5) => {
      g.save();
      g.strokeStyle = color;
      g.fillStyle = color;
      g.lineWidth = 1.6;
      g.setLineDash(dash);
      g.beginPath();
      g.moveTo(ax, ay);
      g.lineTo(bx, by);
      g.stroke();
      const dx = bx - ax, dy = by - ay;
      const len = Math.max(1e-6, Math.hypot(dx, dy));
      const ux = dx / len, uy = dy / len;
      g.setLineDash([]);
      g.beginPath();
      g.moveTo(bx, by);
      g.lineTo(bx - ux * head - uy * wing, by - uy * head + ux * wing);
      g.lineTo(bx - ux * head + uy * wing, by - uy * head - ux * wing);
      g.closePath();
      g.fill();
      g.restore();
    };

    const drawPlate = (text: string, x: number, y: number, color: string, alignX = 0, alignY = 0, bold = false) => {
      g.save();
      g.font = `${bold ? 700 : 500} 11px ui-monospace, SFMono-Regular, Menlo, Monaco, monospace`;
      const m = g.measureText(text);
      const tw = m.width;
      const th = 13;
      const padX = 6, padY = 3;
      let rx = x - alignX * tw - padX;
      let ry = y - alignY * th - padY;
      rx = Math.max(4, Math.min(size.w - tw - 2 * padX - 4, rx));
      ry = Math.max(4, Math.min(size.h - th - 2 * padY - 4, ry));
      g.fillStyle = 'rgba(11, 13, 15, 0.72)';
      g.beginPath();
      g.roundRect(rx, ry, tw + 2 * padX, th + 2 * padY, 5);
      g.fill();
      g.strokeStyle = 'rgba(255, 255, 255, 0.14)';
      g.lineWidth = 1;
      g.stroke();
      g.fillStyle = color;
      g.textBaseline = 'middle';
      g.textAlign = 'left';
      g.fillText(text, rx + padX, ry + padY + th / 2 + 0.5);
      g.restore();
    };

    const tracePoly = (pts: [number, number][]) => {
      g.beginPath();
      pts.forEach(([x, y], i) => {
        const p = toPx(x, y);
        if (i === 0) g.moveTo(p.x, p.y);
        else g.lineTo(p.x, p.y);
      });
      g.closePath();
    };

    const drawHandle = (px: number, py: number, roundHandle: boolean, fill = ACCENT) => {
      g.save();
      g.fillStyle = fill;
      g.strokeStyle = 'rgba(255,255,255,0.95)';
      g.lineWidth = 1.5;
      g.beginPath();
      if (roundHandle) g.arc(px, py, 4.5, 0, Math.PI * 2);
      else g.rect(px - 4.5, py - 4.5, 9, 9);
      g.fill();
      g.stroke();
      g.restore();
    };

    // 1. Puzzle region veil and dashed border.
    if (puzzleOverlay) {
      const [rx0, rx1, ry0, ry1] = puzzleOverlay.region;
      const tl = toPx(rx0, ry1);
      const br = toPx(rx1, ry0);
      const rw = br.x - tl.x;
      const rh = br.y - tl.y;
      g.save();
      g.fillStyle = 'rgba(0, 0, 0, 0.28)';
      g.beginPath();
      g.rect(0, 0, size.w, size.h);
      g.rect(tl.x, tl.y, rw, rh);
      g.fill('evenodd');
      g.strokeStyle = 'rgba(0, 0, 0, 0.55)';
      g.lineWidth = 3.5;
      g.strokeRect(tl.x, tl.y, rw, rh);
      g.strokeStyle = ACCENT;
      g.lineWidth = 1.5;
      g.setLineDash([6, 4]);
      g.strokeRect(tl.x, tl.y, rw, rh);
      g.restore();
    }

    // 2. Body overlays (locked hatch + padlocks, disabled/out-of-region/hover/selection contours).
    const bodies = outlines?.bodies ?? [];
    if (puzzleOverlay && puzzleOverlay.lockedIds.size > 0) {
      const lockedBoxes = new Map<string, {minX: number; maxX: number; minY: number; maxY: number}>();
      for (const b of bodies) {
        if (!puzzleOverlay.lockedIds.has(b.element_id) || b.outline.length === 0) continue;
        const pxPts = b.outline.map(([x, y]) => toPx(x, y));
        const minX = Math.min(...pxPts.map((p) => p.x));
        const maxX = Math.max(...pxPts.map((p) => p.x));
        const minY = Math.min(...pxPts.map((p) => p.y));
        const maxY = Math.max(...pxPts.map((p) => p.y));
        const prev = lockedBoxes.get(b.element_id);
        lockedBoxes.set(b.element_id, prev
          ? {minX: Math.min(prev.minX, minX), maxX: Math.max(prev.maxX, maxX), minY: Math.min(prev.minY, minY), maxY: Math.max(prev.maxY, maxY)}
          : {minX, maxX, minY, maxY});
        g.save();
        tracePoly(b.outline);
        g.clip();
        g.strokeStyle = 'rgba(255, 255, 255, 0.26)';
        g.lineWidth = 1;
        g.beginPath();
        for (let x = minX - (maxY - minY); x < maxX; x += 6) {
          g.moveTo(x, maxY);
          g.lineTo(x + (maxY - minY), minY);
        }
        g.stroke();
        g.restore();
      }
      // Small padlock icon centered on each locked element.
      for (const bb of lockedBoxes.values()) {
        const cx = (bb.minX + bb.maxX) / 2;
        const cy = (bb.minY + bb.maxY) / 2;
        const s = 8;
        g.save();
        g.fillStyle = 'rgba(0,0,0,0.58)';
        g.beginPath();
        g.arc(cx, cy, s, 0, Math.PI * 2);
        g.fill();
        g.strokeStyle = 'rgba(255,255,255,0.9)';
        g.lineWidth = 1.25;
        g.beginPath();
        g.arc(cx, cy - 1.5, 2.3, Math.PI, 0, false);
        g.stroke();
        g.fillStyle = 'rgba(255,255,255,0.9)';
        g.beginPath();
        g.roundRect(cx - 3.4, cy - 1.2, 6.8, 5.2, 1.2);
        g.fill();
        g.restore();
      }
    }

    // Disabled / out-of-region / hover / selected elements.
    const selectedElId = selected?.kind === 'element' ? selected.id : null;
    const hoverElId = hover?.kind === 'element' && !sameItem(hover, selected) ? hover.id : null;
    for (const b of bodies) {
      if (b.outline.length === 0) continue;
      const isOut = puzzleOverlay?.outOfRegionIds.has(b.element_id) ?? false;
      const isSel = b.element_id === selectedElId;
      const isHov = b.element_id === hoverElId;
      if (isOut) {
        g.save();
        tracePoly(b.outline);
        g.strokeStyle = 'rgba(0,0,0,0.55)';
        g.lineWidth = 4.5;
        g.stroke();
        g.strokeStyle = WARNING_COLOR;
        g.lineWidth = isSel ? 3 : 2;
        g.stroke();
        g.restore();
      } else if (isSel) {
        g.save();
        tracePoly(b.outline);
        g.strokeStyle = 'rgba(0,0,0,0.55)';
        g.lineWidth = 4.5;
        g.stroke();
        g.strokeStyle = ACCENT;
        g.lineWidth = 2.25;
        if (!b.enabled) g.setLineDash([5, 4]);
        g.stroke();
        g.restore();
      } else if (isHov) {
        g.save();
        tracePoly(b.outline);
        g.strokeStyle = 'rgba(0,0,0,0.45)';
        g.lineWidth = 3.5;
        g.stroke();
        g.strokeStyle = 'rgba(255,255,255,0.92)';
        g.lineWidth = 1.5;
        g.setLineDash([4, 3]);
        g.stroke();
        g.restore();
      } else if (!b.enabled) {
        g.save();
        tracePoly(b.outline);
        g.strokeStyle = 'rgba(255,255,255,0.45)';
        g.lineWidth = 1.25;
        g.setLineDash([5, 4]);
        g.stroke();
        g.restore();
      } else {
        g.save();
        tracePoly(b.outline);
        g.strokeStyle = 'rgba(255,255,255,0.6)';
        g.lineWidth = 1.5;
        g.stroke();
        g.restore();
      }
    }

    // Center drag dot on selected unlocked element (or corner brackets fallback if no outlines).
    if (selected?.kind === 'element' && !isLocked(selected)) {
      const o = objectOf(scene, selected);
      if (o && typeof o.x_um === 'number') {
        const c = toPx(Number(o.x_um), Number(o.y_um));
        if (bodies.some((b) => b.element_id === selected.id)) {
          drawHandle(c.x, c.y, true);
        } else {
          const e = extentOf(scene, selected);
          const hx = (e.hx / spanX) * size.w + 6;
          const hy = (e.hy / spanY) * size.h + 6;
          g.save();
          g.strokeStyle = ACCENT;
          g.lineWidth = 2;
          g.strokeRect(c.x - hx, c.y - hy, 2 * hx, 2 * hy);
          g.restore();
        }
      }
    }

    // 3. Detectors.
    for (let i = 0; i < scene.detectors.length; i++) {
      const det = scene.detectors[i];
      const item = makeItem('detector', scene.detectors, i);
      const isSel = sameItem(selected, item);
      const isHov = sameItem(hover, item) && !isSel;
      const enabled = det.enabled !== false;
      const color = isSel ? ACCENT : isHov ? '#fff' : enabled ? DETECTOR_COLOR : DETECTOR_DIM;
      const dash = enabled ? [] : [5, 4];
      const s = det.shape as Json;
      if (s.kind === 'line') {
        const a = toPx(Number(s.x1_um), Number(s.y1_um));
        const b = toPx(Number(s.x2_um), Number(s.y2_um));
        const dx = b.x - a.x, dy = b.y - a.y;
        const len = Math.max(1e-6, Math.hypot(dx, dy));
        const tx = (-dy / len) * 4, ty = (dx / len) * 4;
        g.save();
        g.lineCap = 'round';
        g.setLineDash(dash);
        const trace = () => {
          g.beginPath();
          g.moveTo(a.x, a.y);
          g.lineTo(b.x, b.y);
          g.moveTo(a.x - tx, a.y - ty);
          g.lineTo(a.x + tx, a.y + ty);
          g.moveTo(b.x - tx, b.y - ty);
          g.lineTo(b.x + tx, b.y + ty);
        };
        g.strokeStyle = 'rgba(0,0,0,0.5)';
        g.lineWidth = 4.5;
        trace();
        g.stroke();
        g.strokeStyle = color;
        g.lineWidth = isSel ? 2.5 : 2;
        trace();
        g.stroke();
        g.restore();
        const n = detectorNormal(det);
        if (n) {
          const midX = (a.x + b.x) / 2, midY = (a.y + b.y) / 2;
          drawArrow(midX, midY, midX + n[0] * 13, midY - n[1] * 13, color, [], 5, 3);
        }
        if (isSel && !readOnly && !puzzleOverlay) {
          drawHandle(a.x, a.y, true);
          drawHandle(b.x, b.y, true);
        }
      } else if (s.kind === 'box') {
        const cx = Number(s.x_um), cy = Number(s.y_um), hw = Number(s.width_um) / 2, hh = Number(s.height_um) / 2;
        const tl = toPx(cx - hw, cy + hh);
        const br = toPx(cx + hw, cy - hh);
        const rw = br.x - tl.x, rh = br.y - tl.y;
        g.save();
        g.fillStyle = isSel ? 'rgba(243, 198, 35, 0.14)' : 'rgba(255, 194, 74, 0.12)';
        g.fillRect(tl.x, tl.y, rw, rh);
        g.setLineDash(dash);
        g.strokeStyle = 'rgba(0,0,0,0.45)';
        g.lineWidth = 3.5;
        g.strokeRect(tl.x, tl.y, rw, rh);
        g.strokeStyle = color;
        g.lineWidth = isSel ? 2 : 1.5;
        g.strokeRect(tl.x, tl.y, rw, rh);
        g.restore();
        if (isSel && !readOnly && !puzzleOverlay) {
          drawHandle(tl.x, tl.y, false);
          drawHandle(br.x, tl.y, false);
          drawHandle(br.x, br.y, false);
          drawHandle(tl.x, br.y, false);
        }
      }
    }

    // 4. Sources.
    for (let i = 0; i < scene.sources.length; i++) {
      const src = scene.sources[i];
      const item = makeItem('source', scene.sources, i);
      const isSel = sameItem(selected, item);
      const enabled = src.enabled !== false;
      const color = enabled ? BEAM_COLOR : BEAM_DIM;
      const dash = enabled ? [] : [4, 3];
      const plateLabel = puzzleOverlay?.sourceLabels[String(src.id)];
      const a = (Number(src.angle_deg ?? 0) * Math.PI) / 180;
      const dirX = Math.cos(a), dirY = Math.sin(a);

      if (src.type === 'gaussian_beam') {
        const wx = Number(src.waist_x_um), wy = Number(src.waist_y_um), w0 = Number(src.waist_um ?? 1);
        const nx = -dirY, ny = dirX;
        const top = toPx(wx + w0 * nx, wy + w0 * ny);
        const bot = toPx(wx - w0 * nx, wy - w0 * ny);
        const waist = toPx(wx, wy);
        g.save();
        g.strokeStyle = color;
        g.lineWidth = 1.5;
        g.setLineDash(dash);
        g.beginPath();
        g.moveTo(top.x, top.y);
        g.lineTo(bot.x, bot.y);
        g.stroke();
        g.restore();

        const len = beamArrowLength(w0, spanX);
        const tip = toPx(wx + len * dirX, wy + len * dirY);
        drawArrow(waist.x, waist.y, tip.x, tip.y, isSel ? ACCENT : color, dash);
        g.save();
        g.fillStyle = color;
        g.beginPath();
        g.arc(waist.x, waist.y, 4, 0, Math.PI * 2);
        g.fill();
        if (isSel && !readOnly && !puzzleOverlay) {
          g.strokeStyle = ACCENT;
          g.lineWidth = 2;
          g.beginPath();
          g.arc(waist.x, waist.y, 7.5, 0, Math.PI * 2);
          g.stroke();
          drawHandle(tip.x, tip.y, true, '#181a1f');
        }
        g.restore();

        if (plateLabel) {
          const back = 0.45 * len;
          const m = 0.06 * Math.min(spanX, spanY);
          const px = Math.min(Math.max(wx - back * dirX, d.x_min_um + m), d.x_max_um - m);
          const py = Math.min(Math.max(wy - back * dirY, d.y_min_um + m), d.y_max_um - m);
          const pt = toPx(px, py);
          drawPlate(plateLabel, pt.x, pt.y, color, 0.5, 0.5, true);
        }
      } else if (src.type === 'plane_wave') {
        const cx = (d.x_min_um + d.x_max_um) / 2;
        const cy = (d.y_min_um + d.y_max_um) / 2;
        const extent = 0.5 * spanX * Math.abs(dirX) + 0.5 * spanY * Math.abs(dirY);
        const len = 0.06 * (spanX + spanY);
        const back = extent - 0.04 * (spanX + spanY);
        const sx = cx - dirX * back, sy = cy - dirY * back;
        const nx = -dirY, ny = dirX;
        const spread = 0.18 * Math.min(spanX, spanY);
        for (const off of [-spread, 0, spread]) {
          const p0 = toPx(sx + nx * off, sy + ny * off);
          const p1 = toPx(sx + nx * off + dirX * len, sy + ny * off + dirY * len);
          drawArrow(p0.x, p0.y, p1.x, p1.y, off === 0 && isSel ? ACCENT : color, dash);
        }
        if (plateLabel) {
          const p = toPx(sx + dirX * len, sy + dirY * len);
          drawPlate(plateLabel, p.x + 8, p.y, color, 0, 0.5, true);
        }
      } else if (src.type === 'line_source') {
        const pt = toPx(Number(src.x_um), Number(src.y_um));
        g.save();
        g.fillStyle = color;
        g.beginPath();
        g.arc(pt.x, pt.y, 4, 0, Math.PI * 2);
        g.fill();
        for (const [idx, rad] of [9, 15].entries()) {
          for (const center of [0, Math.PI]) {
            g.beginPath();
            g.arc(pt.x, pt.y, rad, center - 0.75, center + 0.75);
            g.strokeStyle = 'rgba(0,0,0,0.45)';
            g.lineWidth = 3.5;
            g.setLineDash(dash);
            g.stroke();
            g.strokeStyle = idx === 0 ? color : BEAM_DIM;
            g.lineWidth = 1.5;
            g.stroke();
          }
        }
        if (isSel && !readOnly && !puzzleOverlay) {
          g.setLineDash([]);
          g.strokeStyle = ACCENT;
          g.lineWidth = 2;
          g.beginPath();
          g.arc(pt.x, pt.y, 8, 0, Math.PI * 2);
          g.stroke();
        }
        g.restore();
        if (plateLabel) drawPlate(plateLabel, pt.x, pt.y + 24, color, 0.5, 0, true);
      }
    }

    // 5. Floating detector labels.
    const labelColor = readingsStale ? 'rgba(255, 219, 153, 0.55)' : 'rgba(255, 224, 158, 0.96)';
    for (const det of scene.detectors) {
      if (det.enabled === false) continue;
      const text = detectorLabels[String(det.id)];
      if (!text) continue;
      const s = det.shape as Json;
      if (s.kind === 'line') {
        const a = toPx(Number(s.x1_um), Number(s.y1_um));
        const b = toPx(Number(s.x2_um), Number(s.y2_um));
        if (Math.abs(a.y - b.y) < 4) {
          // Horizontal line (e.g. Sum detector near top): clear the 13 px normal arrow.
          const midX = (a.x + b.x) / 2;
          const y = (a.y + b.y) / 2;
          const n = detectorNormal(det);
          const arrowUp = n ? n[1] > 0.2 : false;
          const topPad = arrowUp ? 17 : 8;
          if (y > topPad + 20) drawPlate(text, midX, y - topPad, labelColor, 0.5, 1);
          else drawPlate(text, midX, y + (arrowUp ? 10 : 17), labelColor, 0.5, 0);
        } else {
          const top = a.y < b.y ? a : b;
          const bot = a.y < b.y ? b : a;
          if (top.y > 30) drawPlate(text, top.x + 6, top.y - 8, labelColor, 0, 1);
          else drawPlate(text, bot.x + 6, bot.y + 8, labelColor, 0, 0);
        }
      } else if (s.kind === 'box') {
        const cx = Number(s.x_um), cy = Number(s.y_um), hw = Number(s.width_um) / 2, hh = Number(s.height_um) / 2;
        const tr = toPx(cx + hw, cy + hh);
        drawPlate(text, tr.x + 6, tr.y, labelColor, 0, 1);
      }
    }

    // 6. Dark puzzle case hint.
    if (darkCase) {
      drawPlate('All inputs off — no light', size.w / 2, size.h / 2, 'rgba(255,255,255,0.75)', 0.5, 0.5);
    }
  }, [scene, outlines, selected, hover, size, d, spanX, spanY, toPx, puzzleOverlay, detectorLabels, readingsStale, darkCase, readOnly, isLocked]);

  return (
    <div className="field-box" ref={box}>
      <div className="field-frame" style={{width: size.w, height: size.h}}>
        <canvas ref={field} className={fieldStale ? 'field stale' : 'field'} aria-hidden="true" />
        <canvas ref={fade} className="fade" aria-hidden="true" />
        <canvas
          ref={marks}
          className="marks"
          style={{cursor: readOnly ? 'default' : cursorStyle}}
          tabIndex={readOnly ? -1 : 0}
          role="application"
          aria-label={label}
          onPointerDown={onPointerDown}
          onPointerMove={onPointerMove}
          onPointerUp={endDrag}
          onPointerCancel={endDrag}
          onPointerLeave={() => {
            setHover(null);
            if (!drag.current) setCursorStyle('default');
          }}
          onKeyDown={onKeyDown}
        />
      </div>
    </div>
  );
}
