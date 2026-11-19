import {Fragment, useCallback, useEffect, useMemo, useRef, useState} from 'react';
import {Button} from '@astryxdesign/core/Button';
import {Dialog} from '@astryxdesign/core/Dialog';
import {Divider} from '@astryxdesign/core/Divider';
import {useMediaQuery} from '@astryxdesign/core/hooks';
import {Icon} from '@astryxdesign/core/Icon';
import {HStack, Layout, LayoutContent, LayoutFooter, LayoutHeader, LayoutPanel, VStack} from '@astryxdesign/core/Layout';
import {NumberInput} from '@astryxdesign/core/NumberInput';
import {Section} from '@astryxdesign/core/Section';
import {SegmentedControl, SegmentedControlItem} from '@astryxdesign/core/SegmentedControl';
import {Selector} from '@astryxdesign/core/Selector';
import {Slider} from '@astryxdesign/core/Slider';
import {Spinner} from '@astryxdesign/core/Spinner';
import {Switch} from '@astryxdesign/core/Switch';
import {Heading, Text} from '@astryxdesign/core/Text';
import {TextArea} from '@astryxdesign/core/TextArea';
import {useToast} from '@astryxdesign/core/Toast';
import {ArrowDownTrayIcon, ArrowTopRightOnSquareIcon, CodeBracketIcon, HomeIcon, LinkIcon} from '@heroicons/react/24/outline';
import {ExclamationTriangleIcon, InformationCircleIcon, XCircleIcon} from '@heroicons/react/20/solid';

import {FieldCanvas} from './FieldCanvas';
import {Inspector} from './Inspector';
import {pageUrl, readLink, writeLink, decompress} from './link';
import {fitDomain, objectOf, type Item, type Scene} from './scene';
import {Solver, type Example, type Issue, type SolveMeta} from './solver';

const QUANTITIES = [
  {value: 'intensity', label: 'Intensity'},
  {value: 'real', label: 'Field'},
  {value: 'magnitude', label: 'Magnitude'},
  {value: 'phase', label: 'Phase'},
];
const DEFAULT_COLORMAP: Record<string, string> = {intensity: 'inferno', magnitude: 'inferno', real: 'rdbu', phase: 'twilight'};
const COLORMAPS = [
  {value: '', label: 'Automatic'},
  {value: 'inferno', label: 'Inferno'},
  {value: 'viridis', label: 'Viridis'},
  {value: 'plasma', label: 'Plasma'},
  {value: 'turbo', label: 'Turbo'},
  {value: 'laser_glow', label: 'Laser glow'},
  {value: 'spectral_glow', label: 'Spectral glow'},
  {value: 'asympton', label: 'Asympton'},
  {value: 'rdbu', label: 'Red–blue'},
  {value: 'twilight', label: 'Twilight'},
  {value: 'phase_wheel', label: 'Phase wheel'},
];
const METHOD_LABEL: Record<string, string> = {fdtd: 'FDTD', mom: 'MoM', fem: 'FEM'};

const fmtTime = (s: number) => (s < 1 ? `${Math.round(s * 1000)} ms` : `${s.toFixed(1)} s`);
const link = readLink();

export function App() {
  const solver = useMemo(() => new Solver(), []);
  const showToast = useToast();
  const isNarrow = useMediaQuery('(max-width: 860px)');

  const [examples, setExamples] = useState<Example[]>([]);
  const [example, setExample] = useState<string | null>(null);
  const [scene, setScene] = useState<Scene | null>(null);
  const [method, setMethod] = useState(link.method);
  const [quantity, setQuantity] = useState(link.quantity ?? 'intensity');
  const [colormap, setColormap] = useState(link.colormap);
  const [animate, setAnimate] = useState(link.animate);
  const [selected, setSelected] = useState<Item | null>(null);

  const [fieldVersion, setFieldVersion] = useState(0);
  const [meta, setMeta] = useState<SolveMeta | null>(null);
  const [issues, setIssues] = useState<Issue[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [solvingSince, setSolvingSince] = useState<number | null>(null);
  const [now, setNow] = useState(0);
  const [embedOpen, setEmbedOpen] = useState(false);
  const [embedCode, setEmbedCode] = useState('');
  const [sceneText, setSceneText] = useState('');
  const exampleScenes = useRef(new Map<string, string>());

  const effectiveMethod = method || scene?.solver.method || 'fdtd';

  // The field fills the space it is shown in: the solve uses the scene's
  // domain grown to that space's shape (phones scroll instead, so there the
  // scene's own shape stays). The scene itself, and its links, keep the domain
  // they had. The shape settles for a moment before it re-solves.
  const [aspect, setAspect] = useState<number | null>(null);
  const aspectTimer = useRef<ReturnType<typeof setTimeout>>(undefined);
  const reportAspect = useCallback((a: number) => {
    clearTimeout(aspectTimer.current);
    aspectTimer.current = setTimeout(() => setAspect((old) => (old && Math.abs(old - a) / a < 0.02 ? old : a)), 200);
  }, []);
  const fills = link.embed || !isNarrow;
  const solveScene = useMemo(
    () => (scene && aspect && fills ? {...scene, domain: {...scene.domain, ...fitDomain(scene.domain, aspect)}} : scene),
    [scene, aspect, fills],
  );

  // ---- solving: at most one solve at a time; edits during a solve coalesce
  // into one more solve with the newest scene.
  const latest = useRef({scene: solveScene, method: effectiveMethod});
  latest.current = {scene: solveScene, method: effectiveMethod};
  const busy = useRef(false);
  const dirty = useRef(false);

  const runSolve = useCallback(async () => {
    const {scene: s, method: m} = latest.current;
    if (!s) return;
    const json = JSON.stringify(s);
    const report = await solver.check(json);
    setIssues(report.issues);
    if (!report.ok) return;
    const result = await solver.solve(json, m);
    setMeta(result);
    setError(null);
    setFieldVersion((v) => v + 1);
  }, [solver]);

  const requestSolve = useCallback(async () => {
    if (busy.current) {
      dirty.current = true;
      return;
    }
    busy.current = true;
    setSolvingSince(performance.now());
    try {
      do {
        dirty.current = false;
        await runSolve();
      } while (dirty.current);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      busy.current = false;
      setSolvingSince(null);
    }
  }, [runSolve]);

  const stop = () => {
    dirty.current = false;
    solver.reset('Stopped.');
  };

  useEffect(() => {
    solver.onReset = () => {
      busy.current = false;
      setSolvingSince(null);
      setFieldVersion(0);
      setMeta(null);
    };
  }, [solver]);

  // Elapsed time while a solve takes long enough to notice.
  useEffect(() => {
    if (solvingSince === null) return;
    const t = setInterval(() => setNow(performance.now()), 100);
    return () => clearInterval(t);
  }, [solvingSince]);
  const elapsed = solvingSince === null ? 0 : Math.max(0, now - solvingSince) / 1000;

  // ---- loading
  const loadExample = useCallback(
    async (name: string) => {
      let text = exampleScenes.current.get(name);
      if (!text) {
        text = await solver.example(name);
        exampleScenes.current.set(name, text);
      }
      setScene(JSON.parse(text));
      setExample(name);
      setSelected(null);
    },
    [solver],
  );

  useEffect(() => {
    (async () => {
      // An embed further down a page waits until it scrolls into view.
      if (link.embed) {
        await new Promise<void>((resolve) => {
          const io = new IntersectionObserver((entries) => {
            if (entries.some((e) => e.isIntersecting)) {
              io.disconnect();
              resolve();
            }
          });
          io.observe(document.body);
        });
      }
      const list = await solver.examples();
      setExamples(list);
      if (link.scene) {
        try {
          setScene(JSON.parse(await decompress(link.scene)));
          return;
        } catch {
          setError("The link's scene couldn't be read, so this is the lens example.");
        }
      }
      await loadExample(list.some((e) => e.name === link.example) ? link.example! : 'lens');
    })().catch((e) => setError((e as Error).message));
  }, [solver, loadExample]);

  // Solve whenever the scene or the solver changes.
  useEffect(() => {
    if (solveScene) requestSolve();
  }, [solveScene, effectiveMethod, requestSolve]);

  // Keep the URL shareable.
  useEffect(() => {
    if (!scene || link.embed) return;
    const t = setTimeout(async () => {
      const hash = await writeLink({example, sceneJson: JSON.stringify(scene), method, quantity, colormap, animate});
      history.replaceState(null, '', `#${hash}`);
    }, 300);
    return () => clearTimeout(t);
  }, [scene, example, method, quantity, colormap, animate]);

  // ---- editing
  const edit = useCallback((change: (draft: Scene) => void) => {
    setScene((s) => {
      if (!s) return s;
      const draft = structuredClone(s);
      change(draft);
      return draft;
    });
    setExample(null);
  }, []);

  const move = useCallback(
    (item: Item, x: number, y: number) =>
      edit((draft) => {
        const o = objectOf(draft, item);
        o[item.xKey] = x;
        o[item.yKey] = y;
      }),
    [edit],
  );

  // ---- view
  const exampleInfo = examples.find((e) => e.name === example);
  const view = useMemo(
    () => ({
      quantity,
      colormap:
        colormap || (exampleInfo && exampleInfo.quantity === quantity ? exampleInfo.colormap : DEFAULT_COLORMAP[quantity]),
    }),
    [quantity, colormap, exampleInfo],
  );
  const canAnimate = quantity === 'real' || quantity === 'phase';

  // ---- actions
  const currentLink = async (embed = false) =>
    `${pageUrl()}#${await writeLink({example, sceneJson: JSON.stringify(scene), method, quantity, colormap, animate, embed})}`;

  const share = async () => {
    const url = await currentLink();
    if (navigator.share && matchMedia('(pointer: coarse)').matches) {
      navigator.share({title: 'Fringe', url}).catch(() => {});
      return;
    }
    try {
      await navigator.clipboard.writeText(url);
      showToast({body: 'Link copied. It opens this scene exactly as it is now.', uniqueID: 'share'});
    } catch {
      showToast({body: "Couldn't copy the link; it's in the address bar.", type: 'error', uniqueID: 'share'});
    }
  };

  const openEmbed = async () => {
    const src = await currentLink(true);
    const d = scene!.domain;
    const height = Math.round((640 * (d.y_max_um - d.y_min_um)) / (d.x_max_um - d.x_min_um));
    const attr = (s: string) => s.replace(/&/g, '&amp;').replace(/"/g, '&quot;');
    setEmbedCode(
      `<iframe src="${attr(src)}" width="640" height="${height}" style="border:0;border-radius:8px" loading="lazy" title="Fringe simulation"></iframe>`,
    );
    setEmbedOpen(true);
  };

  const saveImage = () => {
    const canvas = document.querySelector<HTMLCanvasElement>('canvas.field');
    canvas?.toBlob((blob) => {
      if (!blob) return;
      const a = document.createElement('a');
      a.href = URL.createObjectURL(blob);
      a.download = `fringe-${example ?? 'scene'}.png`;
      a.click();
      setTimeout(() => URL.revokeObjectURL(a.href), 1000);
    });
  };

  // The status bar: what the solver did on the left, the scene's errors,
  // warnings and notes on the right, one line each.
  const solvingLong = solvingSince !== null && elapsed > 0.4;
  const messages: {severity: 'error' | 'warning' | 'info'; text: string}[] = [
    ...(error ? [{severity: 'error' as const, text: error}] : []),
    ...issues.map((i) => ({severity: i.severity, text: i.message})),
  ];
  const statusParts = solvingLong
    ? [`Solving with ${METHOD_LABEL[effectiveMethod]}…`, fmtTime(elapsed)]
    : meta
      ? [METHOD_LABEL[meta.method] ?? meta.method, `${meta.nx} × ${meta.ny} grid`, `Solved in ${fmtTime(meta.wall_s)}`]
      : [scene ? 'Solving…' : 'Loading the solver…'];
  const MESSAGE_ICON = {error: XCircleIcon, warning: ExclamationTriangleIcon, info: InformationCircleIcon};
  const status = (
    <LayoutFooter hasDivider padding={0} label="Status">
      <div className="statusbar">
        <span className="statusbar-solve">
          {solvingLong && <Spinner size="sm" />}
          {statusParts.map((part, n) => (
            <Fragment key={n}>
              {n > 0 && <Divider orientation="vertical" />}
              <Text type="supporting" hasTabularNumbers>
                {part}
              </Text>
            </Fragment>
          ))}
          {solvingLong && <Button label="Stop" size="sm" variant="ghost" onClick={stop} />}
        </span>
        <span className="statusbar-messages" role="status">
          {messages.map((m, n) => (
            <span key={n} className="statusbar-message" title={m.text}>
              <Icon icon={MESSAGE_ICON[m.severity]} size="xsm" color={m.severity} />
              <Text type="supporting" color={m.severity === 'info' ? 'secondary' : 'primary'}>
                {m.text}
              </Text>
            </span>
          ))}
        </span>
      </div>
    </LayoutFooter>
  );

  // ---- pieces
  const canvasLabel = 'The solved field. Drag an element or a source to move it; arrow keys move the selected one.';
  const fieldView = scene && (
    <FieldCanvas
      solver={solver}
      scene={solveScene!}
      fieldVersion={fieldVersion}
      view={view}
      animate={animate && canAnimate}
      selected={selected}
      onSelect={setSelected}
      onMove={move}
      label={canvasLabel}
      fitHeight={fills}
      onAspect={reportAspect}
    />
  );

  if (link.embed) {
    const full = new URLSearchParams(location.hash.slice(1));
    full.delete('embed');
    return (
      <div className="embed">
        {fieldView}
        {!fieldVersion && (
          <div className="embed-wait">
            <Spinner size="lg" label={error ?? 'Solving…'} />
          </div>
        )}
        <div className="embed-open">
          <Button
            label="Open in Fringe"
            size="sm"
            icon={<Icon icon={ArrowTopRightOnSquareIcon} size="sm" />}
            onClick={() => window.open(`${pageUrl()}#${full}`, '_blank', 'noopener')}
          />
        </div>
      </div>
    );
  }

  const panel = scene && (
    <VStack gap={0}>
      <Section variant="transparent" padding={4}>
        <VStack gap={4}>
          <Heading level={3}>Scene</Heading>
          <Selector
            label="Example"
            value={example ?? ''}
            onChange={(v) => v && loadExample(v)}
            options={[
              ...(example ? [] : [{value: '', label: 'Your scene'}]),
              ...examples.map((e) => ({value: e.name, label: e.title})),
            ]}
          />
          <Slider
            label={`Wavelength · ${scene.wavelength_um} µm`}
            value={scene.wavelength_um}
            min={0.3}
            max={3}
            step={0.01}
            onChange={(v: number) => edit((s) => void (s.wavelength_um = v))}
          />
          <NumberInput
            label="Background index"
            value={scene.background.n}
            min={1}
            max={5}
            step={0.01}
            onChange={(v) => edit((s) => void (s.background.n = v))}
          />
        </VStack>
      </Section>
      <Divider />
      {selected ? (
        <Inspector
          scene={scene}
          item={selected}
          onEdit={edit}
          onClose={() => setSelected(null)}
        />
      ) : (
        <Section variant="transparent" padding={4}>
          <Text type="supporting">Select a lens, slit or source on the field to edit it, or drag it to move it.</Text>
        </Section>
      )}
      <Divider />
      <Section variant="transparent" padding={4}>
        <VStack gap={4}>
          <Heading level={3}>Solver</Heading>
          <SegmentedControl label="Solver" value={effectiveMethod} onChange={setMethod}>
            <SegmentedControlItem value="fdtd" label="FDTD" />
            <SegmentedControlItem value="mom" label="MoM" />
            <SegmentedControlItem value="fem" label="FEM" />
          </SegmentedControl>
          <Text type="supporting">
            {effectiveMethod === 'fem'
              ? 'FEM is the slowest in a browser: a few seconds and a lot of memory for larger scenes.'
              : effectiveMethod === 'mom'
                ? 'Method of moments: exact radiation, solves only on the elements.'
                : 'Time domain on a grid: fast for most scenes.'}
          </Text>
        </VStack>
      </Section>
      <Divider />
      <Section variant="transparent" padding={4}>
        <VStack gap={4}>
          <Heading level={3}>Display</Heading>
          <div className="fit-segments">
            <SegmentedControl label="Show" value={quantity} onChange={setQuantity}>
              {QUANTITIES.map((q) => (
                <SegmentedControlItem key={q.value} value={q.value} label={q.label} />
              ))}
            </SegmentedControl>
          </div>
          <Selector label="Colors" value={colormap} onChange={setColormap} options={COLORMAPS} />
          <Switch
            label="Animate the wave"
            description={canAnimate ? undefined : 'For the field and phase views.'}
            value={animate}
            isDisabled={!canAnimate}
            onChange={setAnimate}
          />
        </VStack>
      </Section>
      <Divider />
      <Section variant="transparent" padding={4}>
        <VStack gap={3}>
          <Heading level={3}>Scene file</Heading>
          <TextArea
            label="Scene JSON"
            isLabelHidden
            description="The format the Mac app and fringe-cli read and write."
            value={sceneText || JSON.stringify(scene, null, 2)}
            onChange={setSceneText}
            rows={8}
          />
          <HStack gap={2}>
            <Button
              label="Apply"
              size="sm"
              isDisabled={!sceneText}
              onClick={() => {
                try {
                  setScene(JSON.parse(sceneText));
                  setExample(null);
                  setSelected(null);
                  setSceneText('');
                } catch (e) {
                  showToast({body: `That isn't valid JSON: ${(e as Error).message}`, type: 'error', uniqueID: 'json'});
                }
              }}
            />
            {sceneText && <Button label="Revert" size="sm" variant="ghost" onClick={() => setSceneText('')} />}
          </HStack>
        </VStack>
      </Section>
    </VStack>
  );

  const header = (
    <LayoutHeader hasDivider>
      <HStack gap={3} vAlign="center" hAlign="between">
        <HStack gap={2} vAlign="center">
          <Button label="Fringe home" href="/" variant="ghost" isIconOnly icon={<Icon icon={HomeIcon} size="sm" />} tooltip="Fringe home" />
          <Heading level={1}>Fringe Web</Heading>
        </HStack>
        <HStack gap={1}>
          <Button label="Share" variant="ghost" icon={<Icon icon={LinkIcon} size="sm" />} isIconOnly={isNarrow} onClick={share} isDisabled={!scene} />
          <Button label="Embed" variant="ghost" icon={<Icon icon={CodeBracketIcon} size="sm" />} isIconOnly={isNarrow} onClick={openEmbed} isDisabled={!scene} />
          <Button label="Save image" variant="ghost" icon={<Icon icon={ArrowDownTrayIcon} size="sm" />} isIconOnly={isNarrow} onClick={saveImage} isDisabled={!fieldVersion} />
        </HStack>
      </HStack>
    </LayoutHeader>
  );

  const main = (
    <VStack gap={3} style={{height: isNarrow ? 'auto' : '100%', minHeight: 0}}>
      <div className={isNarrow ? 'stage stage-narrow' : 'stage'}>{fieldView}</div>
    </VStack>
  );

  return (
    <>
      <Layout
        height={isNarrow ? 'auto' : 'fill'}
        style={isNarrow ? undefined : {height: '100dvh'}}
        header={header}
        footer={status}
        content={
          <LayoutContent padding={4}>
            {main}
            {isNarrow && panel}
          </LayoutContent>
        }
        end={
          isNarrow ? undefined : (
            <LayoutPanel hasDivider padding={0} width={340} label="Scene settings">
              {panel}
            </LayoutPanel>
          )
        }
      />
      <Dialog isOpen={embedOpen} onOpenChange={setEmbedOpen} width={560} padding={6}>
        <VStack gap={4}>
          <Heading level={2}>Embed this simulation</Heading>
          <Text>Paste this HTML into a page. The simulation solves when it scrolls into view.</Text>
          <TextArea label="Embed code" isLabelHidden value={embedCode} rows={4} />
          <HStack gap={2} hAlign="end">
            <Button label="Done" variant="ghost" onClick={() => setEmbedOpen(false)} />
            <Button
              label="Copy"
              variant="primary"
              onClick={async () => {
                await navigator.clipboard.writeText(embedCode).catch(() => {});
                showToast({body: 'Embed code copied.', uniqueID: 'embed'});
                setEmbedOpen(false);
              }}
            />
          </HStack>
        </VStack>
      </Dialog>
    </>
  );
}
