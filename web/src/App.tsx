import {Fragment, useCallback, useEffect, useMemo, useRef, useState} from 'react';
import {Button} from '@astryxdesign/core/Button';
import {Collapsible} from '@astryxdesign/core/Collapsible';
import {Dialog} from '@astryxdesign/core/Dialog';
import {Divider} from '@astryxdesign/core/Divider';
import {DropdownMenu, type DropdownMenuOption} from '@astryxdesign/core/DropdownMenu';
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
import {
  ArrowDownTrayIcon,
  ArrowTopRightOnSquareIcon,
  CodeBracketIcon,
  DocumentDuplicateIcon,
  EllipsisHorizontalIcon,
  EyeIcon,
  EyeSlashIcon,
  HomeIcon,
  LinkIcon,
  PlusIcon,
  TrashIcon,
} from '@heroicons/react/24/outline';
import {ExclamationTriangleIcon, InformationCircleIcon, XCircleIcon} from '@heroicons/react/20/solid';

import {DetectorBar} from './DetectorBar';
import {FieldCanvas, type PuzzleOverlayState} from './FieldCanvas';
import {Inspector} from './Inspector';
import {groupIssues} from './issues';
import {PanelSection} from './PanelSection';
import {decompress, pageUrl, readLink, writeLink} from './link';
import {
  allCases,
  bitsEqual,
  canAddPalettePart,
  caseWeights,
  composePuzzleScene,
  computePuzzleLiveValue,
  designSignature,
  detectorDisplayName,
  extractDesign,
  formatPuzzleValue,
  goalDetectorIds,
  inputLetters,
  loadProgress,
  lockedIds,
  resolvePaletteMaterial,
  saveProgress,
  startingParts,
  type ProgressMap,
} from './puzzle';
import {PuzzleBrowser} from './PuzzleBrowser';
import {PuzzlePanel} from './PuzzlePanel';
import {PuzzleResultsBar} from './PuzzleResultsBar';
import {
  fitDomain,
  formatReadingBadge,
  indexOf,
  listOf,
  makeDetector,
  makeElement,
  makeItem,
  makeSource,
  objectOf,
  OPAQUE_SHAPES,
  parseScene,
  physicsSignature,
  REFRACTIVE_SHAPES,
  round,
  sameItem,
  scaleShape,
  SHAPE_TITLES,
  titleOf,
  uniqueId,
  type Item,
  type Json,
  type Scene,
} from './scene';
import {
  Restarted,
  Solver,
  type DetectorReading,
  type Example,
  type Issue,
  type MaterialPreset,
  type Puzzle,
  type PuzzleCheckReport,
  type PuzzleEvaluation,
  type PuzzleSummary,
  type CheckReport,
  type SceneOutlines,
  type SolveMeta,
} from './solver';
import {CostModel, LOW_POWER, plan, REFINE_DELAY_MS, sceneForStep, type Stage, type Step} from './progressive';

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

/**
 * The time a solve is expected to take, for its hang timeout. Drafts and
 * refine steps are predicted from the full preview's estimate by a power law
 * in resolution. MoM breaks that on scenes with many small parts, since every
 * part keeps a minimum of panels however coarse the draft, so a healthy MoM
 * draft could run far past its timeout and be killed as hung. For MoM, expect
 * at least the full preview's estimate, capped so a truly hung worker is still
 * caught within a few minutes. Other methods follow the power law well.
 */
const MOM_TIMEOUT_BASIS_CAP_S = 10;
function timeoutBasis(method: string, predicted_s: number, report: CheckReport): number | undefined {
  const est = report.estimates?.preview?.seconds ?? 0;
  const floor = method === 'mom' ? Math.min(est, MOM_TIMEOUT_BASIS_CAP_S) : 0;
  return Math.max(predicted_s, floor) || undefined;
}

const fmtTime = (s: number) => (s < 1 ? `${Math.round(s * 1000)} ms` : `${s.toFixed(1)} s`);
const initialLink = readLink();

function scrolledIntoView() {
  return new Promise<void>((resolve) => {
    let reported = false;
    const io = new IntersectionObserver((entries) => {
      reported = true;
      if (entries.some((e) => e.isIntersecting)) {
        io.disconnect();
        resolve();
      }
    });
    io.observe(document.documentElement);
    setTimeout(() => {
      if (!reported) {
        io.disconnect();
        resolve();
      }
    }, 2000);
  });
}

/** Resolves after the next paint (or 50 ms when the page is hidden and frames stop). */
function nextFrame(): Promise<void> {
  return new Promise((resolve) => {
    const done = setTimeout(resolve, 50);
    requestAnimationFrame(() =>
      setTimeout(() => {
        clearTimeout(done);
        resolve();
      }, 0),
    );
  });
}

export function App() {
  const solver = useMemo(() => new Solver(), []);
  const showToast = useToast();
  const isNarrow = useMediaQuery('(max-width: 860px)');

  // ---- top-level mode & catalog state
  const [mode, setMode] = useState<'simulator' | 'puzzles'>(initialLink.puzzle ? 'puzzles' : 'simulator');
  const [examples, setExamples] = useState<Example[]>([]);
  const [presets, setPresets] = useState<MaterialPreset[]>([]);
  const [puzzleList, setPuzzleList] = useState<PuzzleSummary[]>([]);
  const [progress, setProgress] = useState<ProgressMap>(() => loadProgress());

  // ---- simulator state (preserved while visiting puzzles)
  const [example, setExample] = useState<string | null>(null);
  const [simScene, setSimScene] = useState<Scene | null>(null);
  const [simMethod, setSimMethod] = useState(initialLink.method);
  const [simSelected, setSimSelected] = useState<Item | null>(null);
  const [sceneText, setSceneText] = useState('');

  // ---- puzzle state
  const [activePuzzle, setActivePuzzle] = useState<Puzzle | null>(null);
  const [puzzleScene, setPuzzleScene] = useState<Scene | null>(null);
  const [puzzleBits, setPuzzleBits] = useState<boolean[]>([]);
  const [puzzleSelected, setPuzzleSelected] = useState<Item | null>(null);
  const [puzzleRuleCheck, setPuzzleRuleCheck] = useState<PuzzleCheckReport | null>(null);
  const [puzzleEval, setPuzzleEval] = useState<PuzzleEvaluation | null>(null);
  const [evaluatedDesignSig, setEvaluatedDesignSig] = useState<string | null>(null);
  const [checkingPuzzle, setCheckingPuzzle] = useState(false);
  const [revealCase, setRevealCase] = useState<number | null>(null);
  const revealTimers = useRef<ReturnType<typeof setTimeout>[]>([]);

  // ---- shared display & solver state
  const [quantity, setQuantity] = useState(initialLink.quantity ?? 'intensity');
  const [colormap, setColormap] = useState(initialLink.colormap);
  const [animate, setAnimate] = useState(initialLink.animate);

  const [outlines, setOutlines] = useState<SceneOutlines | null>(null);
  const [fieldVersion, setFieldVersion] = useState(0);
  const [meta, setMeta] = useState<SolveMeta | null>(null);
  const [readings, setReadings] = useState<DetectorReading[]>([]);
  const [issues, setIssues] = useState<Issue[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [solvingSince, setSolvingSince] = useState<number | null>(null);
  const [now, setNow] = useState(0);
  const [embedOpen, setEmbedOpen] = useState(false);
  const [embedCode, setEmbedCode] = useState('');
  const exampleScenes = useRef(new Map<string, string>());
  const puzzleCache = useRef(new Map<string, Puzzle>());

  const isInPuzzle = mode === 'puzzles' && activePuzzle !== null && puzzleScene !== null;
  const activeScene = isInPuzzle ? puzzleScene : mode === 'simulator' ? simScene : null;
  const selected = isInPuzzle ? puzzleSelected : simSelected;
  const setSelected = isInPuzzle ? setPuzzleSelected : setSimSelected;

  const effectiveMethod = isInPuzzle
    ? activePuzzle.scoring.method
    : simMethod || simScene?.solver.method || 'fdtd';

  // Fit domain to container aspect in Simulator desktop/embed only; puzzles keep exact domain.
  const [aspect, setAspect] = useState<number | null>(null);
  const aspectTimer = useRef<ReturnType<typeof setTimeout>>(undefined);
  const reportAspect = useCallback((a: number) => {
    clearTimeout(aspectTimer.current);
    aspectTimer.current = setTimeout(() => setAspect((old) => (old && Math.abs(old - a) / a < 0.02 ? old : a)), 200);
  }, []);
  const fills = initialLink.embed || !isNarrow;
  const solveScene = useMemo(() => {
    if (!activeScene) return null;
    if (isInPuzzle || !aspect || !fills) return activeScene;
    return {...activeScene, domain: {...activeScene.domain, ...fitDomain(activeScene.domain, aspect)}};
  }, [activeScene, isInPuzzle, aspect, fills]);

  const currentDesignSig = useMemo(
    () => (isInPuzzle && activePuzzle && puzzleScene ? designSignature(activePuzzle, puzzleScene) : null),
    [isInPuzzle, activePuzzle, puzzleScene],
  );
  const isPuzzleCheckCurrent =
    isInPuzzle && puzzleEval !== null && evaluatedDesignSig !== null && evaluatedDesignSig === currentDesignSig;
  const allSourcesOff = useMemo(
    () => !!activeScene && activeScene.sources.every((s) => s.enabled === false),
    [activeScene],
  );
  const isDarkPuzzleCase = isInPuzzle && (activePuzzle.inputs?.length ?? 0) > 0 && allSourcesOff;

  // ---- cancel reveal helper
  const clearRevealTimers = useCallback(() => {
    for (const t of revealTimers.current) clearTimeout(t);
    revealTimers.current = [];
  }, []);

  const skipReveal = useCallback(() => {
    clearRevealTimers();
    setRevealCase(null);
  }, [clearRevealTimers]);

  // ---- solving queue: coalesces rapid drags into at most one queued solve
  const latest = useRef({
    scene: solveScene,
    method: effectiveMethod,
    isDark: isDarkPuzzleCase,
    checkCurrent: isPuzzleCheckCurrent,
  });
  latest.current = {
    scene: solveScene,
    method: effectiveMethod,
    isDark: isDarkPuzzleCase,
    checkCurrent: isPuzzleCheckCurrent,
  };
  const busy = useRef(false);
  const dirty = useRef(false);
  /** Automatic restarts since the last good solve, so a scene that always hangs stops retrying. */
  const restarts = useRef(0);
  // ---- progressive preview: a draft sized to a time budget while editing,
  // then cancellable background refinement once edits pause (see progressive.ts).
  const cost = useRef(new CostModel());
  const solveGen = useRef(0);
  const checkingRef = useRef(false);
  checkingRef.current = checkingPuzzle;
  const pendingRefine = useRef<{gen: number; scene: Scene; method: string; report: CheckReport; steps: Step[]} | null>(null);
  const refineTimer = useRef<ReturnType<typeof setTimeout>>(undefined);
  const [stage, setStage] = useState<Stage | null>(null);
  // physicsSignature of the scene the shown field was solved for.
  const [fieldSig, setFieldSig] = useState<string | null>(null);
  const [refining, setRefining] = useState<Step | null>(null);

  const cancelRefine = useCallback(() => {
    solveGen.current++;
    clearTimeout(refineTimer.current);
    pendingRefine.current = null;
    setRefining(null);
    solver.cancelRefine();
  }, [solver]);

  const learn = (method: string, step: Step, report: CheckReport, result: SolveMeta) => {
    const est = step.quality === 'final' ? report.estimates?.final : report.estimates?.preview;
    if (est) cost.current.observe(method, step.quality, est.seconds, est.ppw, result);
  };

  const runRefine = useCallback(async () => {
    const job = pendingRefine.current;
    pendingRefine.current = null;
    if (!job) return;
    const {gen, scene, method, report, steps} = job;
    const fullPpw = report.estimates?.preview?.ppw ?? null;
    for (const [n, step] of steps.entries()) {
      if (solveGen.current !== gen || busy.current || checkingRef.current || latest.current.checkCurrent) break;
      if (document.hidden) {
        // No refining in a background tab; resume when it is shown again.
        pendingRefine.current = {...job, steps: steps.slice(n)};
        break;
      }
      setRefining(step);
      let result: SolveMeta;
      try {
        result = await solver.refine(
          sceneForStep(scene, method, step, fullPpw),
          method,
          step.quality,
          timeoutBasis(method, step.predicted_s, report) ?? step.predicted_s,
        );
      } catch {
        // Cancelled by an edit, or this resolution failed: keep what is shown.
        break;
      }
      if (solveGen.current !== gen) break;
      learn(method, step, report, result);
      setMeta(result);
      setReadings(result.readings ?? []);
      setStage(step.stage);
      setFieldSig(physicsSignature(scene));
      setFieldVersion((v) => v + 1);
    }
    if (solveGen.current === gen) setRefining(null);
  }, [solver]);

  useEffect(() => {
    const onVisible = () => {
      if (!document.hidden && pendingRefine.current && !busy.current) runRefine();
    };
    document.addEventListener('visibilitychange', onVisible);
    return () => document.removeEventListener('visibilitychange', onVisible);
  }, [runRefine]);

  /** Solves the latest scene; returns the solve's wall time in seconds (0 when nothing was solved). */
  const runSolve = useCallback(async (): Promise<number> => {
    const {scene: s, method: m, isDark, checkCurrent} = latest.current;
    if (!s || checkCurrent) return 0;
    if (isDark) {
      setIssues([]);
      setReadings([]);
      setError(null);
      return 0;
    }
    const report = await solver.check(JSON.stringify({...s, solver: {...s.solver, method: m}}));
    setIssues(report.issues);
    if (!report.ok) return 0;
    const {first, refine} = plan(report, m, cost.current);
    const result = await solver.solve(
      sceneForStep(s, m, first, report.estimates?.preview?.ppw ?? null),
      m,
      timeoutBasis(m, first.predicted_s, report),
    );
    learn(m, first, report, result);
    setMeta(result);
    setReadings(result.readings ?? []);
    setStage(first.stage);
    setFieldSig(physicsSignature(s));
    setError(null);
    setFieldVersion((v) => v + 1);
    pendingRefine.current = refine.length ? {gen: solveGen.current, scene: s, method: m, report, steps: refine} : null;
    return result.wall_s;
  }, [solver]);

  const requestSolve = useCallback(async () => {
    cancelRefine();
    if (busy.current) {
      dirty.current = true;
      return;
    }
    busy.current = true;
    setSolvingSince(performance.now());
    let ok = false;
    try {
      do {
        dirty.current = false;
        const wall_s = await runSolve();
        // Let the canvas post its render of this field before the next solve
        // takes the worker, or the drawn field lags a whole solve behind. On
        // low-power devices also rest as long as the solve took, so a long
        // drag runs the CPU at about half duty instead of flat out.
        if (dirty.current) {
          await nextFrame();
          if (LOW_POWER && wall_s > 0) await new Promise((r) => setTimeout(r, Math.min(500, wall_s * 1000)));
        }
      } while (dirty.current);
      ok = true;
      restarts.current = 0;
    } catch (e) {
      // A hung or crashed worker was replaced; onReset solves again.
      if (!(e instanceof Restarted && e.retry)) setError((e as Error).message);
    } finally {
      busy.current = false;
      setSolvingSince(null);
    }
    if (ok && pendingRefine.current) refineTimer.current = setTimeout(runRefine, REFINE_DELAY_MS);
  }, [runSolve, runRefine, cancelRefine]);

  const requestSolveRef = useRef(requestSolve);
  requestSolveRef.current = requestSolve;

  const stop = () => {
    dirty.current = false;
    cancelRefine();
    clearRevealTimers();
    setRevealCase(null);
    setCheckingPuzzle(false);
    setEvaluatedDesignSig(null);
    solver.reset('Stopped.');
  };

  useEffect(() => {
    solver.onReset = (reason, retry) => {
      busy.current = false;
      if (retry) {
        // A worker hung or crashed (or the browser killed it): solve the
        // current scene again on the fresh one, a few times at most.
        if (restarts.current++ < 3) setTimeout(() => requestSolveRef.current(), 200);
        else setError(`${reason} It keeps stopping on this scene; try a smaller domain or a coarser preview.`);
      }
      solveGen.current++;
      pendingRefine.current = null;
      setRefining(null);
      setStage(null);
      setSolvingSince(null);
      setCheckingPuzzle(false);
      setFieldVersion(0);
      setMeta(null);
      setReadings([]);
      setEvaluatedDesignSig(null);
    };
  }, [solver]);

  // Elapsed timer during slow solves / checks.
  useEffect(() => {
    if (solvingSince === null) return;
    const t = setInterval(() => setNow(performance.now()), 100);
    return () => clearInterval(t);
  }, [solvingSince]);
  const elapsed = solvingSince === null ? 0 : Math.max(0, now - solvingSince) / 1000;

  // ---- exact outlines (fast, independent of solves)
  const outlineSig = useMemo(() => (solveScene ? JSON.stringify(solveScene) : null), [solveScene]);
  useEffect(() => {
    if (!outlineSig) {
      setOutlines(null);
      return;
    }
    let cancelled = false;
    solver
      .outlines(outlineSig)
      .then((res) => {
        if (!cancelled) setOutlines(res);
      })
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, [solver, outlineSig]);

  // ---- simulator & puzzle solving triggers
  // In Simulator mode: re-solve ONLY when physics (everything except detectors) or method changes.
  const physSig = useMemo(() => (solveScene ? physicsSignature(solveScene) : null), [solveScene]);
  useEffect(() => {
    if (!solveScene || !physSig) return;
    if (isInPuzzle && isPuzzleCheckCurrent) return;
    if (checkingPuzzle) return;
    requestSolve();
  }, [physSig, effectiveMethod, isInPuzzle, isPuzzleCheckCurrent, checkingPuzzle, requestSolve]);

  // Re-measure detectors immediately on the existing field when only detectors change!
  const simDetectorsJson = useMemo(
    () => (mode === 'simulator' && simScene ? JSON.stringify(simScene.detectors) : null),
    [mode, simScene],
  );
  useEffect(() => {
    if (mode !== 'simulator' || !simDetectorsJson || !fieldVersion) return;
    let cancelled = false;
    solver
      .measureDetectors(simDetectorsJson)
      .then((r) => {
        if (!cancelled) setReadings(r);
      })
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, [solver, mode, simDetectorsJson, fieldVersion]);

  // Live rule check in puzzle mode (instant amber out-of-region feedback without solving).
  useEffect(() => {
    if (!isInPuzzle || !activePuzzle || !currentDesignSig) {
      setPuzzleRuleCheck(null);
      return;
    }
    let cancelled = false;
    solver
      .puzzleCheck(activePuzzle.id, currentDesignSig)
      .then((rep) => {
        if (!cancelled) setPuzzleRuleCheck(rep);
      })
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, [solver, isInPuzzle, activePuzzle, currentDesignSig]);

  // Persist player's puzzle design in localStorage.
  useEffect(() => {
    if (!isInPuzzle || !activePuzzle || !puzzleScene) return;
    const design = extractDesign(activePuzzle, puzzleScene);
    const t = setTimeout(() => {
      setProgress((prev) => {
        const cur = prev[activePuzzle.id] ?? {stars: 0};
        if (JSON.stringify(cur.design) === JSON.stringify(design)) return prev;
        const next: ProgressMap = {...prev, [activePuzzle.id]: {...cur, design}};
        saveProgress(next);
        return next;
      });
    }, 400);
    return () => clearTimeout(t);
  }, [isInPuzzle, activePuzzle, puzzleScene]);

  // ---- loading examples & puzzles
  const loadExample = useCallback(
    async (name: string) => {
      let text = exampleScenes.current.get(name);
      if (!text) {
        text = await solver.example(name);
        exampleScenes.current.set(name, text);
      }
      setSimScene(parseScene(text));
      setExample(name);
      setSimSelected(null);
      setSceneText('');
    },
    [solver],
  );

  const selectCheckedCase = useCallback(
    async (puzzle: Puzzle, evaluation: PuzzleEvaluation, bits: boolean[]) => {
      const weights = caseWeights(puzzle, evaluation.sources, bits);
      const res = await solver.selectPuzzleCase(weights);
      setMeta(res);
      setStage(null);
      setFieldSig('checked');
      setReadings(res.readings ?? []);
      setIssues([]);
      setError(null);
      setFieldVersion((v) => v + 1);
    },
    [solver],
  );

  const runPuzzleEvaluation = useCallback(
    async (puzzle: Puzzle, design: Json[], targetBits: boolean[], animateReveal: boolean) => {
      clearRevealTimers();
      setRevealCase(null);
      cancelRefine();
      setCheckingPuzzle(true);
      setSolvingSince(performance.now());
      setError(null);
      try {
        const designJson = JSON.stringify(design);
        const ev = await solver.puzzleEvaluate(puzzle.id, designJson);
        setPuzzleEval(ev);
        setEvaluatedDesignSig(designJson);

        if (ev.valid) {
          // Record best score & stars in localStorage.
          if (ev.passed && ev.score !== null) {
            setProgress((prev) => {
              const cur = prev[puzzle.id] ?? {stars: 0};
              const bestScore = cur.bestScore !== undefined ? Math.max(cur.bestScore, ev.score!) : ev.score!;
              const stars = Math.max(cur.stars, ev.stars);
              const next: ProgressMap = {...prev, [puzzle.id]: {...cur, bestScore, stars, design}};
              saveProgress(next);
              return next;
            });
          }

          const cases = allCases(puzzle.inputs);
          if (animateReveal && cases.length > 1) {
            // Play case-by-case reveal across every truth-table row, ending on targetBits.
            const stepMs = 460;
            cases.forEach((caseBits, k) => {
              const timer = setTimeout(() => {
                setRevealCase(k);
                selectCheckedCase(puzzle, ev, caseBits).catch(() => {});
              }, k * stepMs);
              revealTimers.current.push(timer);
            });
            const endTimer = setTimeout(() => {
              setRevealCase(null);
              selectCheckedCase(puzzle, ev, targetBits).catch(() => {});
            }, cases.length * stepMs + 220);
            revealTimers.current.push(endTimer);
          } else {
            await selectCheckedCase(puzzle, ev, targetBits);
          }
        }
      } catch (e) {
        setError((e as Error).message);
      } finally {
        setCheckingPuzzle(false);
        setSolvingSince(null);
      }
    },
    [solver, clearRevealTimers, selectCheckedCase, cancelRefine],
  );

  const openPuzzle = useCallback(
    async (
      id: string,
      opts?: {loadReference?: boolean; initialDesign?: Json[]; initialBits?: boolean[]; autoCheck?: boolean},
    ) => {
      clearRevealTimers();
      setRevealCase(null);
      setPuzzleEval(null);
      setEvaluatedDesignSig(null);
      setPuzzleRuleCheck(null);
      setIssues([]);
      setReadings([]);
      setMeta(null);
      setFieldVersion(0);
      setError(null);
      setNotice(null);
      if (busy.current) {
        dirty.current = false;
        solver.reset('Switched to puzzle.');
      } else {
        await solver.clearPuzzleFields().catch(() => {});
      }

      let p = puzzleCache.current.get(id);
      if (!p) {
        p = await solver.puzzle(id);
        puzzleCache.current.set(id, p);
      }
      const saved = loadProgress()[id]?.design;
      const design = opts?.initialDesign
        ? structuredClone(opts.initialDesign)
        : opts?.loadReference
          ? structuredClone(p.reference)
          : saved
            ? structuredClone(saved)
            : startingParts(p);
      const nInputs = p.inputs?.length ?? 0;
      const bits =
        opts?.initialBits && opts.initialBits.length === nInputs
          ? opts.initialBits
          : Array.from({length: nInputs}, () => true);

      const composed = composePuzzleScene(p, design, bits);
      setMode('puzzles');
      setActivePuzzle(p);
      setPuzzleBits(bits);
      setPuzzleScene(composed);
      const locked = lockedIds(p);
      const firstIdx = composed.elements.findIndex((e) => !locked.has(String(e.id)));
      setPuzzleSelected(firstIdx >= 0 ? makeItem('element', composed.elements, firstIdx) : null);

      if (opts?.loadReference || opts?.autoCheck) {
        // Trigger full check right away so truth-table toggles switch instantaneously.
        await runPuzzleEvaluation(p, design, bits, Boolean(opts?.loadReference));
      }
    },
    [solver, clearRevealTimers, runPuzzleEvaluation],
  );

  // Apply a parsed URL hash state (used both on initial boot and external hashchange).
  const applyLink = useCallback(
    async (
      target: ReturnType<typeof readLink>,
      exList: Example[],
      puzList: PuzzleSummary[],
      isInitial: boolean,
    ) => {
      setSimMethod(target.method);
      if (target.quantity) setQuantity(target.quantity);
      if (target.colormap) setColormap(target.colormap);
      setAnimate(target.animate);

      if (target.puzzle) {
        if (isInitial) loadExample('lens').catch(() => {});
        if (target.puzzle === 'list') {
          skipReveal();
          setMode('puzzles');
          setActivePuzzle(null);
          setPuzzleScene(null);
          return;
        }
        if (!puzList.some((p) => p.id === target.puzzle)) {
          setNotice(`There is no puzzle "${target.puzzle}".`);
          setMode('puzzles');
          setActivePuzzle(null);
          return;
        }
        let initialDesign: Json[] | undefined;
        if (target.design) {
          try {
            const parsed = JSON.parse(await decompress(target.design));
            if (Array.isArray(parsed)) initialDesign = parsed as Json[];
          } catch (e) {
            setNotice(`The link's design couldn't be read (${(e as Error).message}).`);
          }
        }
        await openPuzzle(target.puzzle, {
          loadReference: target.ref,
          initialDesign,
          initialBits: target.bits ?? undefined,
          autoCheck: Boolean(initialDesign),
        });
        return;
      }

      skipReveal();
      setMode('simulator');
      if (target.scene) {
        try {
          setSimScene(parseScene(await decompress(target.scene)));
          setExample(null);
          setSimSelected(null);
          return;
        } catch (e) {
          setNotice(`The link's scene couldn't be used (${(e as Error).message}), so this is the lens example.`);
        }
      }
      await loadExample(exList.some((e) => e.name === target.example) ? target.example! : 'lens');
    },
    [loadExample, openPuzzle, skipReveal],
  );

  // Initial boot: load catalogs + handle URL hash (#ex, #s, #p, #d, #ref, #b).
  const catalogsRef = useRef<{examples: Example[]; puzzles: PuzzleSummary[]}>({examples: [], puzzles: []});
  useEffect(() => {
    (async () => {
      if (initialLink.embed && window.self !== window.top) await scrolledIntoView();
      const [exList, matPresets, puzList] = await Promise.all([
        solver.examples(),
        solver.materialPresets(),
        solver.puzzles(),
      ]);
      catalogsRef.current = {examples: exList, puzzles: puzList};
      setExamples(exList);
      setPresets(matPresets);
      setPuzzleList(puzList);
      await applyLink(initialLink, exList, puzList, true);
    })().catch((e) => setError((e as Error).message));
  }, [solver, applyLink]);

  // External hash changes (typed URL or back/forward navigation) switch in place
  // without reloading the page or restarting the WASM worker.
  useEffect(() => {
    const onHash = () => {
      const {examples: exList, puzzles: puzList} = catalogsRef.current;
      if (exList.length === 0 && puzList.length === 0) return;
      applyLink(readLink(location.hash), exList, puzList, false).catch((e) => setError((e as Error).message));
    };
    window.addEventListener('hashchange', onHash);
    return () => window.removeEventListener('hashchange', onHash);
  }, [applyLink]);

  // Keep URL hash shareable.
  useEffect(() => {
    if (initialLink.embed) return;
    if (mode === 'simulator' && !simScene) return;
    const t = setTimeout(async () => {
      let hash: string;
      if (mode === 'puzzles') {
        if (!activePuzzle || !puzzleScene) {
          hash = await writeLink({puzzle: 'list', quantity, colormap, animate});
        } else {
          const design = extractDesign(activePuzzle, puzzleScene);
          const isDefault = JSON.stringify(design) === JSON.stringify(startingParts(activePuzzle));
          hash = await writeLink({
            puzzle: activePuzzle.id,
            designJson: isDefault ? null : JSON.stringify(design),
            bits: puzzleBits,
            quantity,
            colormap,
            animate,
          });
        }
      } else {
        hash = await writeLink({
          example,
          sceneJson: JSON.stringify(simScene),
          method: simMethod,
          quantity,
          colormap,
          animate,
        });
      }
      history.replaceState(null, '', `#${hash}`);
    }, 300);
    return () => clearTimeout(t);
  }, [mode, simScene, example, simMethod, activePuzzle, puzzleScene, puzzleBits, quantity, colormap, animate]);

  // ---- editing helpers (Simulator & Puzzle)
  const editSim = useCallback((change: (draft: Scene) => void) => {
    setSimScene((s) => {
      if (!s) return s;
      const draft = structuredClone(s);
      change(draft);
      return draft;
    });
    setExample(null);
    setNotice(null);
  }, []);

  const editPuzzle = useCallback(
    (change: (draft: Scene) => void) => {
      skipReveal();
      setPuzzleScene((s) => {
        if (!s) return s;
        const draft = structuredClone(s);
        change(draft);
        return draft;
      });
      setNotice(null);
    },
    [skipReveal],
  );

  const editActive = isInPuzzle ? editPuzzle : editSim;

  // ---- Simulator build actions (add / duplicate / delete)
  const addSimElement = (kind: string) => {
    if (!simScene) return;
    let added: Json | null = null;
    editSim((draft) => {
      added = makeElement(kind, draft);
      draft.elements.push(added);
    });
    if (added) setSimSelected({kind: 'element', index: simScene.elements.length, id: String((added as Json).id)});
  };

  const addSimSource = (type: 'gaussian_beam' | 'plane_wave' | 'line_source') => {
    if (!simScene) return;
    let added: Json | null = null;
    editSim((draft) => {
      added = makeSource(type, draft);
      draft.sources.push(added);
    });
    if (added) setSimSelected({kind: 'source', index: simScene.sources.length, id: String((added as Json).id)});
  };

  const addSimDetector = (kind: 'line' | 'box') => {
    if (!simScene) return;
    let added: Json | null = null;
    editSim((draft) => {
      added = makeDetector(kind, draft);
      draft.detectors.push(added);
    });
    if (added) setSimSelected({kind: 'detector', index: simScene.detectors.length, id: String((added as Json).id)});
  };

  const duplicateItem = (item: Item) => {
    if (!activeScene) return;
    const orig = objectOf(activeScene, item);
    if (!orig) return;
    const copy = structuredClone(orig);
    const prefix = item.kind === 'element' ? String((orig.shape as Json)?.kind ?? 'part') : item.kind;
    copy.id = uniqueId(activeScene, prefix);
    if (typeof copy.x_um === 'number') copy.x_um = round(Number(copy.x_um) + 0.5, 2);
    if (typeof copy.y_um === 'number') copy.y_um = round(Number(copy.y_um) - 0.5, 2);
    if (typeof copy.waist_x_um === 'number') copy.waist_y_um = round(Number(copy.waist_y_um) - 1, 2);
    if (item.kind === 'detector') {
      const s = copy.shape as Json;
      if (s.kind === 'line') {
        s.x1_um = round(Number(s.x1_um) + 0.5, 2);
        s.x2_um = round(Number(s.x2_um) + 0.5, 2);
      } else if (s.kind === 'box') {
        s.x_um = round(Number(s.x_um) + 0.5, 2);
      }
    }
    const nextIdx = listOf(activeScene, item.kind).length;
    editActive((draft) => {
      listOf(draft, item.kind).push(copy);
    });
    setSelected({kind: item.kind, index: nextIdx, id: String(copy.id)});
  };

  const deleteItem = (item: Item) => {
    if (!activeScene) return;
    if (isInPuzzle && activePuzzle) {
      if (item.kind !== 'element' || lockedIds(activePuzzle).has(item.id)) return;
    } else if (item.kind === 'source' && activeScene.sources.length <= 1) {
      showToast({body: 'A scene needs at least one source.', type: 'error', uniqueID: 'last-source'});
      return;
    }
    editActive((draft) => {
      const idx = indexOf(draft, item);
      if (idx >= 0) listOf(draft, item.kind).splice(idx, 1);
    });
    if (sameItem(selected, item)) setSelected(null);
  };

  // ---- Puzzle actions
  const addPuzzlePart = async (paletteIndex: number) => {
    if (!activePuzzle || !puzzleScene) return;
    const design = extractDesign(activePuzzle, puzzleScene);
    if (!canAddPalettePart(activePuzzle, design, paletteIndex, presets)) return;
    const entry = activePuzzle.rules.palette[paletteIndex];
    const matName = entry.materials?.[0];
    const material = matName ? resolvePaletteMaterial(activePuzzle, matName, presets) ?? undefined : undefined;
    const [rx0, rx1, ry0, ry1] = activePuzzle.rules.region;
    let el = makeElement(entry.kind, puzzleScene, {material, box: activePuzzle.rules.region});

    // Fit cleanly inside 90% of rules.region using exact WASM outlines (mirrors Swift `fitted`).
    const margin = 0.05 * Math.min(rx1 - rx0, ry1 - ry0);
    const tx0 = rx0 + margin, tx1 = rx1 - margin, ty0 = ry0 + margin, ty1 = ry1 - margin;
    const tw = Math.max(0.05, tx1 - tx0), th = Math.max(0.05, ty1 - ty0);
    for (let step = 0; step < 5; step++) {
      try {
        const probe = {...puzzleScene, elements: [el]};
        const out = await solver.outlines(JSON.stringify(probe));
        const pts = out.bodies.flatMap((b) => b.outline);
        if (pts.length === 0) break;
        const minX = Math.min(...pts.map((p) => p[0])), maxX = Math.max(...pts.map((p) => p[0]));
        const minY = Math.min(...pts.map((p) => p[1])), maxY = Math.max(...pts.map((p) => p[1]));
        const bw = maxX - minX, bh = maxY - minY;
        const factor = Math.min(tw / Math.max(1e-6, bw), th / Math.max(1e-6, bh));
        if (factor >= 1) {
          el.x_um = round(Number(el.x_um) + (rx0 + rx1) / 2 - (minX + maxX) / 2, 2);
          const dy = Math.max(ty0 - minY, Math.min(0, ty1 - maxY));
          el.y_um = round(Number(el.y_um) + dy, 2);
          break;
        }
        el = {...el, shape: scaleShape(el.shape as Json, factor * 0.96)};
      } catch {
        break;
      }
    }

    const nextIdx = puzzleScene.elements.length;
    editPuzzle((draft) => {
      draft.elements.push(el);
    });
    setPuzzleSelected({kind: 'element', index: nextIdx, id: String(el.id)});
  };

  const setPuzzleCaseBits = useCallback(
    async (nextBits: boolean[]) => {
      if (!activePuzzle || !puzzleScene) return;
      skipReveal();
      setPuzzleBits(nextBits);
      const inputs = activePuzzle.inputs ?? [];
      setPuzzleScene((prev) => {
        if (!prev) return prev;
        const draft = structuredClone(prev);
        for (let i = 0; i < inputs.length; i++) {
          const src = draft.sources.find((s) => s.id === inputs[i]);
          if (src) src.enabled = nextBits[i] ?? false;
        }
        return draft;
      });
      if (isPuzzleCheckCurrent && puzzleEval?.valid) {
        try {
          await selectCheckedCase(activePuzzle, puzzleEval, nextBits);
        } catch (e) {
          setError((e as Error).message);
        }
      }
    },
    [activePuzzle, puzzleScene, isPuzzleCheckCurrent, puzzleEval, skipReveal, selectCheckedCase],
  );

  const togglePuzzleInput = (i: number, on: boolean) => {
    const next = [...puzzleBits];
    next[i] = on;
    setPuzzleCaseBits(next);
  };

  const handlePuzzleCheck = useCallback(() => {
    if (!activePuzzle || !puzzleScene || checkingPuzzle) return;
    runPuzzleEvaluation(activePuzzle, extractDesign(activePuzzle, puzzleScene), puzzleBits, true);
  }, [activePuzzle, puzzleScene, checkingPuzzle, puzzleBits, runPuzzleEvaluation]);

  const handlePuzzleReset = () => {
    if (!activePuzzle) return;
    skipReveal();
    setPuzzleEval(null);
    setEvaluatedDesignSig(null);
    solver.clearPuzzleFields().catch(() => {});
    const parts = startingParts(activePuzzle);
    const nInputs = activePuzzle.inputs?.length ?? 0;
    const bits = Array.from({length: nInputs}, () => true);
    setPuzzleBits(bits);
    const composed = composePuzzleScene(activePuzzle, parts, bits);
    setPuzzleScene(composed);
    const locked = lockedIds(activePuzzle);
    const firstIdx = composed.elements.findIndex((e) => !locked.has(String(e.id)));
    setPuzzleSelected(firstIdx >= 0 ? makeItem('element', composed.elements, firstIdx) : null);
  };

  const handleLoadReference = () => {
    if (!activePuzzle) return;
    openPuzzle(activePuzzle.id, {loadReference: true});
  };

  // Keyboard shortcuts for puzzle mode (⌘/Ctrl+Enter to Check, Space/Esc to skip reveal, 1–4 toggle inputs).
  useEffect(() => {
    if (!isInPuzzle) return;
    const onKey = (e: KeyboardEvent) => {
      const target = e.target as HTMLElement | null;
      const inInput = target && ['INPUT', 'TEXTAREA', 'SELECT'].includes(target.tagName);
      if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') {
        e.preventDefault();
        handlePuzzleCheck();
        return;
      }
      if (revealCase !== null && (e.key === ' ' || e.key === 'Escape')) {
        e.preventDefault();
        skipReveal();
        return;
      }
      if (!inInput && !e.metaKey && !e.ctrlKey && !e.altKey && /^[1-4]$/.test(e.key)) {
        const idx = Number(e.key) - 1;
        if (idx < (activePuzzle?.inputs?.length ?? 0)) {
          e.preventDefault();
          togglePuzzleInput(idx, !puzzleBits[idx]);
        }
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [isInPuzzle, revealCase, activePuzzle, puzzleBits, handlePuzzleCheck, skipReveal]);

  // ---- view & overlays
  const exampleInfo = examples.find((e) => e.name === example);
  const view = useMemo(
    () => ({
      quantity,
      colormap:
        colormap ||
        (!isInPuzzle && exampleInfo && exampleInfo.quantity === quantity ? exampleInfo.colormap : DEFAULT_COLORMAP[quantity]),
    }),
    [quantity, colormap, exampleInfo, isInPuzzle],
  );
  const canAnimate = quantity === 'real' || quantity === 'phase';

  const puzzleOverlay = useMemo<PuzzleOverlayState | null>(() => {
    if (!isInPuzzle || !activePuzzle || !puzzleScene) return null;
    const sourceLabels: Record<string, string> = {};
    const letters = inputLetters(activePuzzle.inputs);
    (activePuzzle.inputs ?? []).forEach((id, i) => {
      sourceLabels[id] = letters[i];
    });
    for (const src of puzzleScene.sources) {
      const sid = String(src.id);
      if (!sourceLabels[sid] && src.enabled !== false && typeof src.name === 'string' && src.name.trim()) {
        sourceLabels[sid] = src.name;
      }
    }
    const outIds =
      isPuzzleCheckCurrent && puzzleEval?.valid
        ? new Set<string>()
        : new Set(puzzleRuleCheck?.out_of_region_ids ?? []);
    return {
      region: activePuzzle.rules.region,
      lockedIds: lockedIds(activePuzzle),
      sourceLabels,
      outOfRegionIds: outIds,
    };
  }, [isInPuzzle, activePuzzle, puzzleScene, isPuzzleCheckCurrent, puzzleEval, puzzleRuleCheck]);

  // Floating detector labels on the canvas.
  const detectorLabels = useMemo<Record<string, string>>(() => {
    if (!activeScene) return {};
    const out: Record<string, string> = {};
    const readingMap = new Map(readings.map((r) => [r.id, r]));
    const peak = meta?.incident_peak ?? 1;

    if (isInPuzzle && activePuzzle) {
      const goalIds = new Set(goalDetectorIds(activePuzzle));
      const cases = allCases(activePuzzle.inputs);
      const shownIdx = revealCase !== null ? revealCase : cases.findIndex((c) => bitsEqual(c, puzzleBits));
      const checkedCase = isPuzzleCheckCurrent && puzzleEval?.valid ? puzzleEval.cases[Math.max(0, shownIdx)] : null;
      for (const det of activeScene.detectors) {
        if (det.enabled === false) continue;
        const id = String(det.id);
        const name = detectorDisplayName(activePuzzle, id);
        if (goalIds.has(id)) {
          if (checkedCase && revealCase === null) {
            const o = checkedCase.outputs.find((x) => x.detector === id);
            out[id] = o?.value !== null && o?.value !== undefined ? `${name} ${formatPuzzleValue(activePuzzle, o.value)}` : name;
          } else {
            const r = readingMap.get(id);
            const live = r ? computePuzzleLiveValue(activePuzzle, r, allSourcesOff) : allSourcesOff ? 0 : null;
            out[id] = live !== null ? `${name} ≈ ${formatPuzzleValue(activePuzzle, live)}` : name;
          }
        } else {
          out[id] = name;
        }
      }
      return out;
    }

    for (const det of activeScene.detectors) {
      if (det.enabled === false) continue;
      const id = String(det.id);
      const name = typeof det.name === 'string' && det.name.trim() ? det.name : 'Detector';
      const r = readingMap.get(id);
      out[id] = r ? `${name} ${formatReadingBadge(r, readings, peak)}` : name;
    }
    return out;
  }, [activeScene, readings, meta, isInPuzzle, activePuzzle, revealCase, puzzleBits, isPuzzleCheckCurrent, puzzleEval, allSourcesOff]);

  // ---- share, embed, save image
  const currentLink = async (embed = false) => {
    if (isInPuzzle && activePuzzle && puzzleScene) {
      const design = extractDesign(activePuzzle, puzzleScene);
      const isDefault = JSON.stringify(design) === JSON.stringify(startingParts(activePuzzle));
      return `${pageUrl()}#${await writeLink({
        puzzle: activePuzzle.id,
        designJson: isDefault ? null : JSON.stringify(design),
        bits: puzzleBits,
        quantity,
        colormap,
        animate,
      })}`;
    }
    return `${pageUrl()}#${await writeLink({
      example,
      sceneJson: JSON.stringify(simScene),
      method: simMethod,
      quantity,
      colormap,
      animate,
      embed,
    })}`;
  };

  const share = async () => {
    const url = await currentLink();
    if (navigator.share && matchMedia('(pointer: coarse)').matches) {
      navigator.share({title: 'Fringe', url}).catch(() => {});
      return;
    }
    try {
      await navigator.clipboard.writeText(url);
      showToast({
        body: isInPuzzle
          ? 'Link copied. It opens this puzzle with your current design.'
          : 'Link copied. It opens this scene exactly as it is now.',
        uniqueID: 'share',
      });
    } catch {
      showToast({body: "Couldn't copy the link; it's in the address bar.", type: 'error', uniqueID: 'share'});
    }
  };

  const openEmbed = async () => {
    if (!simScene) return;
    const src = await currentLink(true);
    const d = simScene.domain;
    const height = Math.round((640 * (d.y_max_um - d.y_min_um)) / (d.x_max_um - d.x_min_um));
    const attr = (s: string) => s.replace(/&/g, '&amp;').replace(/"/g, '&quot;');
    setEmbedCode(
      `<iframe src="${attr(src)}" width="640" height="${height}" style="border:0;border-radius:8px" loading="lazy" title="Fringe simulation"></iframe>`,
    );
    setEmbedOpen(true);
  };

  const saveImage = () => {
    const field = document.querySelector<HTMLCanvasElement>('canvas.field');
    if (!field) return;
    // The field is rendered without outlines (the overlay draws them), so add them here.
    const canvas = document.createElement('canvas');
    canvas.width = field.width;
    canvas.height = field.height;
    const g = canvas.getContext('2d')!;
    g.drawImage(field, 0, 0);
    const d = solveScene?.domain;
    if (outlines && d) {
      const sx = canvas.width / (d.x_max_um - d.x_min_um);
      const sy = canvas.height / (d.y_max_um - d.y_min_um);
      g.strokeStyle = 'rgba(255,255,255,0.6)';
      g.lineWidth = 1.5 * (window.devicePixelRatio > 1 ? 2 : 1);
      g.lineJoin = 'round';
      for (const b of outlines.bodies) {
        if (!b.enabled || b.outline.length < 2) continue;
        g.beginPath();
        b.outline.forEach(([x, y], i) => {
          const px = (x - d.x_min_um) * sx;
          const py = (d.y_max_um - y) * sy;
          if (i) g.lineTo(px, py);
          else g.moveTo(px, py);
        });
        g.closePath();
        g.stroke();
      }
    }
    canvas.toBlob((blob) => {
      if (!blob) return;
      const a = document.createElement('a');
      a.href = URL.createObjectURL(blob);
      a.download = `fringe-${isInPuzzle ? activePuzzle.id : example ?? 'scene'}.png`;
      a.click();
      setTimeout(() => URL.revokeObjectURL(a.href), 1000);
    });
  };

  // ---- simulator build dropdown items
  const elementMenuItems: DropdownMenuOption[] = [
    {
      type: 'section',
      title: 'Refractive',
      items: REFRACTIVE_SHAPES.map((k) => ({id: k, label: SHAPE_TITLES[k], onClick: () => addSimElement(k)})),
    },
    {type: 'divider'},
    {
      type: 'section',
      title: 'Conductive (PEC)',
      items: OPAQUE_SHAPES.map((k) => ({id: k, label: SHAPE_TITLES[k], onClick: () => addSimElement(k)})),
    },
  ];
  const sourceMenuItems: DropdownMenuOption[] = [
    {id: 'gaussian_beam', label: 'Gaussian beam', onClick: () => addSimSource('gaussian_beam')},
    {id: 'plane_wave', label: 'Plane wave', onClick: () => addSimSource('plane_wave')},
    {id: 'line_source', label: 'Point emitter', onClick: () => addSimSource('line_source')},
  ];
  const detectorMenuItems: DropdownMenuOption[] = [
    {id: 'line', label: 'Line detector (flux)', onClick: () => addSimDetector('line')},
    {id: 'box', label: 'Box detector (|E|²)', onClick: () => addSimDetector('box')},
  ];
  // Phones: one Add menu with every part, so the bar fits a single row.
  const addMenuItems: DropdownMenuOption[] = [
    {
      type: 'section',
      title: 'Elements · refractive',
      items: REFRACTIVE_SHAPES.map((k) => ({id: `el-${k}`, label: SHAPE_TITLES[k], onClick: () => addSimElement(k)})),
    },
    {
      type: 'section',
      title: 'Elements · conductive (PEC)',
      items: OPAQUE_SHAPES.map((k) => ({id: `el-${k}`, label: SHAPE_TITLES[k], onClick: () => addSimElement(k)})),
    },
    {type: 'divider'},
    {
      type: 'section',
      title: 'Sources',
      items: [
        {id: 'src-gaussian_beam', label: 'Gaussian beam', onClick: () => addSimSource('gaussian_beam')},
        {id: 'src-plane_wave', label: 'Plane wave', onClick: () => addSimSource('plane_wave')},
        {id: 'src-line_source', label: 'Point emitter', onClick: () => addSimSource('line_source')},
      ],
    },
    {type: 'divider'},
    {
      type: 'section',
      title: 'Detectors',
      items: [
        {id: 'det-line', label: 'Line detector (flux)', onClick: () => addSimDetector('line')},
        {id: 'det-box', label: 'Box detector (|E|²)', onClick: () => addSimDetector('box')},
      ],
    },
  ];

  // ---- status bar
  const solvingLong = solvingSince !== null && elapsed > 0.35;
  // Wavelength advice only where the wavelength can be changed.
  const issueMessages = groupIssues(issues, isInPuzzle ? undefined : activeScene?.wavelength_um);
  const hasBlockingIssue = issues.some((i) => i.severity === 'error');
  // MoM puts every part's boundary into one dense matrix, so a scene with many
  // separate parts (a photonic crystal, say) is slow with it and quick with FEM.
  const momParts =
    effectiveMethod === 'mom' && activeScene ? activeScene.elements.filter((e) => e.enabled !== false).length : 0;
  const slowHint =
    momParts > 20 ? `MoM is slow with many separate parts (${momParts} here); FEM or FDTD solves this scene faster.` : null;
  const messages: {severity: 'error' | 'warning' | 'info'; text: string}[] = [
    ...(error ? [{severity: 'error' as const, text: error}] : []),
    ...(notice ? [{severity: 'warning' as const, text: notice}] : []),
    ...issueMessages,
    ...(slowHint && !hasBlockingIssue ? [{severity: 'info' as const, text: slowHint}] : []),
  ];
  // What is shown; the solve in progress goes in its own slot so the facts
  // never reflow while a solve starts, refines or ends.
  const statusParts =
    mode === 'puzzles' && !activePuzzle
      ? [`${puzzleList.length} puzzles`]
      : isDarkPuzzleCase && !isPuzzleCheckCurrent
        ? ['All inputs off']
        : meta
          ? [
              METHOD_LABEL[meta.method] ?? meta.method,
              // Phones keep the facts to one row; the grid size is the least useful.
              ...(isNarrow ? [] : [`${meta.nx} × ${meta.ny} grid`]),
              ...(stage === 'draft' || stage === 'refine'
                ? [`Draft, ${Number(meta.ppw.toFixed(1))} per λ`]
                : stage === 'final'
                  ? ['Final quality']
                  : []),
              `Solved in ${fmtTime(meta.wall_s)}`,
            ]
          : [
              !activeScene
                ? 'Loading the solver…'
                : solvingSince === null && (hasBlockingIssue || error)
                  ? 'Not solved'
                  : 'Solving…',
            ];
  const activity = solvingLong
    ? `${checkingPuzzle ? 'Checking puzzle…' : `Solving with ${METHOD_LABEL[effectiveMethod]}…`} ${fmtTime(elapsed)}`
    : refining
      ? refining.stage === 'final'
        ? 'Refining to final…'
        : 'Refining…'
      : null;
  const MESSAGE_ICON = {error: XCircleIcon, warning: ExclamationTriangleIcon, info: InformationCircleIcon};
  const status = (
    <LayoutFooter hasDivider padding={0} label="Status">
      <div className="statusbar">
        <span className="statusbar-solve">
          {statusParts.map((part, n) => (
            <Fragment key={n}>
              {n > 0 && <Divider orientation="vertical" />}
              <Text type="supporting" hasTabularNumbers>
                {part}
              </Text>
            </Fragment>
          ))}
        </span>
        <span className="statusbar-tail">
          <span className="statusbar-activity" aria-live="polite">
            {solvingLong && <Spinner size="sm" />}
            {activity && (
              <Text type="supporting" color="secondary" hasTabularNumbers>
                {activity}
              </Text>
            )}
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
        </span>
      </div>
    </LayoutFooter>
  );

  // ---- canvas
  const canvasLabel = isInPuzzle
    ? 'The puzzle field. Drag your parts inside the dashed region; arrow keys move and R rotates.'
    : 'The solved field. Drag an element, source or detector to move it; arrow keys move and R rotates.';
  const fieldView = solveScene && (
    <FieldCanvas
      solver={solver}
      scene={solveScene}
      outlines={outlines}
      fieldVersion={fieldVersion}
      darkCase={isDarkPuzzleCase && !isPuzzleCheckCurrent}
      view={view}
      animate={animate && canAnimate}
      selected={selected}
      onSelect={setSelected}
      onEdit={editActive}
      onDelete={deleteItem}
      detectorLabels={detectorLabels}
      readingsStale={solvingSince !== null}
      fieldStale={!!fieldVersion && !isPuzzleCheckCurrent && fieldSig !== physSig}
      puzzleOverlay={puzzleOverlay}
      label={canvasLabel}
      fitHeight={fills}
      onAspect={isInPuzzle ? undefined : reportAspect}
      readOnly={initialLink.embed}
    />
  );

  // ---- embed mode
  if (initialLink.embed) {
    const blocking = error ?? issueMessages.find((i) => i.severity === 'error')?.text ?? null;
    const full = new URLSearchParams(location.hash.slice(1));
    full.delete('embed');
    return (
      <div className="embed">
        {fieldView}
        {!fieldVersion && (
          <div className="embed-wait">
            {blocking ? (
              <div className="embed-message" role="alert">
                <Text type="supporting" color="inherit">
                  {blocking}
                </Text>
              </div>
            ) : (
              <Spinner size="lg" label="Solving…" />
            )}
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

  // ---- simulator right panel
  const renderObjectList = (title: string, kind: Item['kind'], list: Json[]) => (
    <VStack gap={1}>
      <Text type="supporting" weight="semibold" color="secondary">
        {title}
      </Text>
      {list.length === 0 ? (
        <Text type="supporting" color="secondary">
          None
        </Text>
      ) : (
        list.map((o, idx) => {
          const item = makeItem(kind, list, idx);
          const isSel = sameItem(simSelected, item);
          const enabled = o.enabled !== false;
          const canDel = kind !== 'source' || list.length > 1;
          return (
            <div
              key={String(o.id ?? idx)}
              className={`obj-row${isSel ? ' obj-row-selected' : ''}${enabled ? '' : ' obj-row-disabled'}`}
              onClick={() => setSimSelected(item)}
            >
              <span className="obj-row-name">
                <Text type="supporting" weight={isSel ? 'semibold' : undefined} color={enabled ? 'primary' : 'secondary'}>
                  {titleOf(simScene!, item)}
                </Text>
              </span>
              <HStack gap={0}>
                <Button
                  label={enabled ? 'Disable' : 'Enable'}
                  size="sm"
                  variant="ghost"
                  isIconOnly
                  tooltip={enabled ? 'Hide / disable' : 'Show / enable'}
                  icon={<Icon icon={enabled ? EyeIcon : EyeSlashIcon} size="sm" />}
                  onClick={(e) => {
                    e.stopPropagation();
                    editSim((draft) => {
                      const target = objectOf(draft, item);
                      if (target) target.enabled = target.enabled === false;
                    });
                  }}
                />
                {canDel && (
                  <Button
                    label="Delete"
                    size="sm"
                    variant="ghost"
                    isIconOnly
                    tooltip="Delete"
                    icon={<Icon icon={TrashIcon} size="sm" />}
                    onClick={(e) => {
                      e.stopPropagation();
                      deleteItem(item);
                    }}
                  />
                )}
              </HStack>
            </div>
          );
        })
      )}
    </VStack>
  );

  const simPanel = simScene && (
    <VStack gap={0}>
      <PanelSection id="sim.scene" title="Scene">
        <Selector
          label="Example"
          value={example ?? ''}
          onChange={(v) => {
            if (!v) return;
            setNotice(null);
            loadExample(v);
          }}
          options={[
            ...(example ? [] : [{value: '', label: 'Custom scene'}]),
            ...examples.map((e) => ({value: e.name, label: e.title})),
          ]}
        />
        <Slider
          label={`Wavelength · ${simScene.wavelength_um} µm`}
          value={simScene.wavelength_um}
          min={0.3}
          max={3}
          step={0.01}
          onChange={(v: number) => editSim((s) => void (s.wavelength_um = v))}
        />
        <NumberInput
          label="Background index"
          value={simScene.background.n}
          min={1}
          max={5}
          step={0.01}
          onChange={(v) => editSim((s) => void (s.background.n = v))}
        />
      </PanelSection>
      <Divider />
      <PanelSection id="sim.objects" title="Objects" gap={3}>
        {renderObjectList('Sources', 'source', simScene.sources)}
        {renderObjectList('Elements', 'element', simScene.elements)}
        {renderObjectList('Detectors', 'detector', simScene.detectors)}
      </PanelSection>
      <Divider />
      {simSelected ? (
        <Inspector
          scene={simScene}
          item={simSelected}
          presets={presets}
          readings={readings}
          incidentPeak={meta?.incident_peak ?? 1}
          solverMethod={effectiveMethod}
          canDuplicate={true}
          canDelete={simSelected.kind !== 'source' || simScene.sources.length > 1}
          onEdit={editSim}
          onSwitchSolver={setSimMethod}
          onDuplicate={() => duplicateItem(simSelected)}
          onDelete={() => deleteItem(simSelected)}
          onClose={() => setSimSelected(null)}
        />
      ) : (
        <Section variant="transparent" padding={4}>
          <Text type="supporting">Select an element, source or detector to edit it, or drag it on the canvas.</Text>
        </Section>
      )}
      <Divider />
      <PanelSection id="sim.solver" title="Solver" defaultIsOpen={!isNarrow}>
        <SegmentedControl label="Solver" value={effectiveMethod} onChange={setSimMethod}>
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
      </PanelSection>
      <Divider />
      <PanelSection id="sim.display" title="Display" defaultIsOpen={!isNarrow}>
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
      </PanelSection>
      <Divider />
      <Section variant="transparent" padding={4}>
        <Collapsible trigger={<Heading level={3}>Scene JSON</Heading>} defaultIsOpen={false}>
          <VStack gap={3} style={{paddingTop: 12}}>
            <TextArea
              label="Scene JSON"
              isLabelHidden
              description="The format the Mac app and fringe-cli read and write."
              value={sceneText || JSON.stringify(simScene, null, 2)}
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
                    setSimScene(parseScene(sceneText));
                    setExample(null);
                    setSimSelected(null);
                    setSceneText('');
                  } catch (e) {
                    showToast({body: `That scene can't be used: ${(e as Error).message}`, type: 'error', uniqueID: 'json'});
                  }
                }}
              />
              {sceneText && <Button label="Revert" size="sm" variant="ghost" onClick={() => setSceneText('')} />}
            </HStack>
          </VStack>
        </Collapsible>
      </Section>
    </VStack>
  );

  // ---- puzzle right panel
  const puzzlePanel = isInPuzzle && activePuzzle && puzzleScene && (
    <PuzzlePanel
      puzzle={activePuzzle}
      puzzles={puzzleList}
      progress={progress[activePuzzle.id]}
      scene={puzzleScene}
      presets={presets}
      selected={puzzleSelected}
      ruleCheck={puzzleRuleCheck}
      evaluation={puzzleEval}
      checkCurrent={isPuzzleCheckCurrent}
      checking={checkingPuzzle}
      quantity={quantity}
      colormap={colormap}
      animate={animate}
      canAnimate={canAnimate}
      quantities={QUANTITIES}
      colormaps={COLORMAPS}
      onBackToBrowser={() => {
        skipReveal();
        setActivePuzzle(null);
        setPuzzleScene(null);
        setPuzzleEval(null);
        setEvaluatedDesignSig(null);
        solver.clearPuzzleFields().catch(() => {});
      }}
      onOpenPuzzle={(id) => openPuzzle(id)}
      onCheck={handlePuzzleCheck}
      onReset={handlePuzzleReset}
      onLoadReference={handleLoadReference}
      onAddPart={addPuzzlePart}
      onSelect={setPuzzleSelected}
      onEdit={editPuzzle}
      onDuplicate={duplicateItem}
      onDelete={deleteItem}
      onQuantity={setQuantity}
      onColormap={setColormap}
      onAnimate={setAnimate}
    />
  );

  // ---- header
  const header = (
    <LayoutHeader hasDivider>
      <HStack gap={2} vAlign="center" hAlign="between" style={{flexWrap: 'wrap'}}>
        <HStack gap={2} vAlign="center">
          {!isNarrow && (
            <Button label="Fringe home" href="/" variant="ghost" isIconOnly icon={<Icon icon={HomeIcon} size="sm" />} tooltip="Fringe home" />
          )}
          <Heading level={1}>{isNarrow ? 'Fringe' : 'Fringe Web'}</Heading>
          <SegmentedControl
            label="Mode"
            value={mode}
            onChange={(next) => {
              const target = next as 'simulator' | 'puzzles';
              if (target === mode) return;
              skipReveal();
              setError(null);
              setNotice(null);
              setIssues([]);
              if (busy.current) {
                dirty.current = false;
                solver.reset('Switched mode.');
              }
              setMode(target);
              if (target === 'simulator') {
                setEvaluatedDesignSig(null);
                setFieldVersion(0);
                setReadings([]);
                solver.clearPuzzleFields().catch(() => {});
                if (!simScene) loadExample('lens').catch(() => {});
              }
            }}
          >
            <SegmentedControlItem value="simulator" label="Simulator" />
            <SegmentedControlItem value="puzzles" label="Puzzles" />
          </SegmentedControl>
        </HStack>
        {isNarrow ? (
          <DropdownMenu
            button={{label: 'More', variant: 'ghost', isIconOnly: true, icon: <Icon icon={EllipsisHorizontalIcon} size="sm" />}}
            items={[
              ...(activeScene ? [{id: 'share', label: 'Share link', icon: LinkIcon, onClick: share}] : []),
              ...(mode === 'simulator' && simScene ? [{id: 'embed', label: 'Embed', icon: CodeBracketIcon, onClick: openEmbed}] : []),
              ...(activeScene
                ? [{id: 'save', label: 'Save image', icon: ArrowDownTrayIcon, onClick: saveImage, isDisabled: !fieldVersion}]
                : []),
              {id: 'home', label: 'Fringe home', icon: HomeIcon, href: '/'},
            ]}
          />
        ) : (
          <HStack gap={1}>
            {activeScene && (
              <Button label="Share" variant="ghost" icon={<Icon icon={LinkIcon} size="sm" />} isIconOnly={isNarrow} onClick={share} />
            )}
            {mode === 'simulator' && simScene && (
              <Button label="Embed" variant="ghost" icon={<Icon icon={CodeBracketIcon} size="sm" />} isIconOnly={isNarrow} onClick={openEmbed} />
            )}
            {activeScene && (
              <Button
                label="Save image"
                variant="ghost"
                icon={<Icon icon={ArrowDownTrayIcon} size="sm" />}
                isIconOnly={isNarrow}
                onClick={saveImage}
                isDisabled={!fieldVersion}
              />
            )}
          </HStack>
        )}
      </HStack>
    </LayoutHeader>
  );

  // ---- main column content
  const simBuildBar = mode === 'simulator' && simScene && (
    <div className="build-bar" role="toolbar" aria-label="Add optical parts">
      {/* One wrapping row. The edit buttons are always there (disabled without a
          selection), so selecting never adds a row and shifts the canvas. */}
      {isNarrow ? (
        <DropdownMenu
          button={{label: 'Add', size: 'sm', variant: 'secondary', icon: <Icon icon={PlusIcon} size="sm" />}}
          items={addMenuItems}
          menuMaxHeight={480}
        />
      ) : (
        <>
          <DropdownMenu
            button={{label: 'Element', size: 'sm', variant: 'secondary', icon: <Icon icon={PlusIcon} size="sm" />}}
            items={elementMenuItems}
            menuMaxHeight={480}
          />
          <DropdownMenu
            button={{label: 'Source', size: 'sm', variant: 'secondary', icon: <Icon icon={PlusIcon} size="sm" />}}
            items={sourceMenuItems}
          />
          <DropdownMenu
            button={{label: 'Detector', size: 'sm', variant: 'secondary', icon: <Icon icon={PlusIcon} size="sm" />}}
            items={detectorMenuItems}
          />
        </>
      )}
      <div className="build-bar-edit">
        <Button
          label="Duplicate"
          size="sm"
          variant="ghost"
          icon={<Icon icon={DocumentDuplicateIcon} size="sm" />}
          isIconOnly={isNarrow}
          isDisabled={!simSelected}
          onClick={() => simSelected && duplicateItem(simSelected)}
        />
        <Button
          label="Delete"
          size="sm"
          variant="ghost"
          icon={<Icon icon={TrashIcon} size="sm" />}
          isIconOnly={isNarrow}
          isDisabled={!simSelected || (simSelected.kind === 'source' && simScene.sources.length <= 1)}
          onClick={() => simSelected && deleteItem(simSelected)}
        />
      </div>
    </div>
  );

  const mainContent =
    mode === 'puzzles' && !activePuzzle ? (
      <PuzzleBrowser
        puzzles={puzzleList}
        progress={progress}
        onOpen={(id, loadRef) => openPuzzle(id, {loadReference: loadRef})}
      />
    ) : (
      <VStack gap={3} style={{height: isNarrow ? 'auto' : '100%', minHeight: 0}}>
        {simBuildBar}
        <div className={isNarrow ? 'stage stage-narrow' : 'stage'}>{fieldView}</div>
        {mode === 'simulator' && simScene && (
          <DetectorBar
            scene={simScene}
            readings={readings}
            incidentPeak={meta?.incident_peak ?? 1}
            stale={solvingSince !== null}
            selected={simSelected}
            onSelect={setSimSelected}
          />
        )}
        {isInPuzzle && activePuzzle && (
          <PuzzleResultsBar
            puzzle={activePuzzle}
            bits={puzzleBits}
            readings={readings}
            readingsStale={solvingSince !== null}
            allSourcesOff={allSourcesOff}
            evaluation={puzzleEval}
            checkCurrent={isPuzzleCheckCurrent}
            checking={checkingPuzzle}
            revealCase={revealCase}
            onToggleInput={togglePuzzleInput}
            onSelectCase={setPuzzleCaseBits}
            onCheck={handlePuzzleCheck}
            onSkipReveal={skipReveal}
          />
        )}
      </VStack>
    );

  const sidePanel = mode === 'simulator' ? simPanel : puzzlePanel;

  return (
    <>
      <Layout
        height={isNarrow ? 'auto' : 'fill'}
        style={isNarrow ? undefined : {height: '100dvh'}}
        header={header}
        footer={status}
        content={
          <LayoutContent padding={4}>
            {mainContent}
            {isNarrow && <div className="narrow-panel">{sidePanel}</div>}
          </LayoutContent>
        }
        end={
          isNarrow || !sidePanel ? undefined : (
            <LayoutPanel hasDivider padding={0} width={356} label={mode === 'puzzles' ? 'Puzzle' : 'Scene settings'}>
              {sidePanel}
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
