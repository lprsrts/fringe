// The page's side of the worker: typed calls, and replacing the worker (with
// its wasm instance and stored field) when a solve is stopped or crashes.

export interface Example {
  name: string;
  title: string;
  method: string;
  quantity: string;
  colormap: string;
}

export interface MaterialPreset {
  id: string;
  name: string;
  kind: 'metal' | 'glass';
  source: string;
  range_um: [number, number];
  material: Record<string, unknown>;
}

export interface BodyOutline {
  element_id: string;
  enabled: boolean;
  pec: boolean;
  outline: [number, number][];
}

export interface SceneOutlines {
  bodies: BodyOutline[];
  pml_um?: number;
}

export interface LineReading {
  id: string;
  name: string;
  kind: 'line';
  length_um: number;
  normal: [number, number];
  flux: {total: number; incident: number; scattered: number};
}

export interface BoxReading {
  id: string;
  name: string;
  kind: 'box';
  area_um2: number;
  total: {mean: number; integral: number; max: number};
  incident: {mean: number; integral: number; max: number};
  mean_intensity?: {total: number; incident: number};
  integral?: {total: number; incident: number};
}

export type DetectorReading = LineReading | BoxReading;

export interface Issue {
  path: string;
  code?: string;
  severity: 'error' | 'warning' | 'info';
  message: string;
}

export interface Estimate {
  method: string;
  ppw: number;
  seconds: number;
  memory_mb: number;
}

export interface CheckReport {
  ok: boolean;
  issues: Issue[];
  estimates?: {preview?: Estimate | null; final?: Estimate | null} | null;
}

export interface SolveMeta {
  method: string;
  quality: 'preview' | 'final';
  /** Resolution solved at: cells (FDTD), nodes (FEM) or panels (MoM) per wavelength. */
  ppw: number;
  nx: number;
  ny: number;
  wall_s: number;
  wasm_memory_mb: number;
  incident_peak: number;
  /** Set by the page: solved on a fresh worker, so slower than usual. */
  cold?: boolean;
  readings: DetectorReading[];
}

export interface PuzzleSummary {
  id: string;
  chapter: string;
  chapter_title: string;
  order: number;
  title: string;
  summary: string;
  goal_type: 'truth_table' | 'maximize' | 'minimize' | 'target';
  stars: [number, number, number];
}

export interface TruthOutput {
  detector: string;
  bits: number[];
}

export interface PuzzleGoal {
  type: 'truth_table' | 'maximize' | 'minimize' | 'target';
  text?: string;
  pass: number;
  reference?: 'source' | 'incident' | number;
  reference_source?: string;
  outputs?: TruthOutput[];
  detector?: string;
  detectors?: string[];
  quantity?: 'scattered' | 'flux' | 'intensity';
  ratio?: number;
  tolerance?: number;
}

export interface PaletteEntry {
  kind: string;
  materials?: string[];
  max?: number;
}

export interface NamedMaterial {
  name?: string;
  type: string;
  [key: string]: unknown;
}

export interface PuzzleRules {
  locked?: string[];
  region: [number, number, number, number];
  palette: PaletteEntry[];
  max_elements?: number;
  materials?: Record<string, NamedMaterial>;
}

export interface Puzzle {
  id: string;
  chapter: string;
  order: number;
  title: string;
  summary: string;
  hints?: string[];
  scene: Record<string, unknown>;
  inputs?: string[];
  goal: PuzzleGoal;
  rules: PuzzleRules;
  scoring: {method: string; ppw: number};
  stars: [number, number, number];
  reference: Record<string, unknown>[];
  reference_power: number | null;
  reference_intensity: number | null;
}

export interface PuzzleCheckReport {
  valid: boolean;
  issues: Issue[];
  out_of_region_ids: string[];
}

export interface PuzzleCaseOutput {
  detector: string;
  target: boolean | null;
  value: number | null;
}

export interface PuzzleCaseResult {
  bits: boolean[];
  weights: [number, number][];
  readings: DetectorReading[];
  outputs: PuzzleCaseOutput[];
}

export interface PuzzleMetric {
  label: string;
  unit: string;
  value: number | null;
  text: string;
  fraction?: number | null;
  share?: number | null;
  share_ok?: boolean;
}

export interface PuzzleEvaluation {
  puzzle: string;
  valid: boolean;
  issues: Issue[];
  goal_type: string;
  method: string;
  ppw: number;
  sources: string[];
  inputs: string[];
  cases: PuzzleCaseResult[];
  metric: PuzzleMetric | null;
  score: number | null;
  pass: number;
  passed: boolean;
  stars: number;
  star_thresholds: [number, number, number];
  wall_s: number;
  wasm_memory_mb: number;
}

type Pending = {resolve: (v: unknown) => void; reject: (e: Error) => void};

export type Quality = 'preview' | 'final';

/** A worker's first solves run baseline-compiled wasm, several times slower. */
const COLD_SOLVES = 2;
/** A refinement predicted to finish within this is left to finish (its result unused) rather than killed. */
const SOFT_CANCEL_S = 0.6;

/** Thrown by `refine` when a newer edit cancelled it; not an error to show. */
export class Cancelled extends Error {
  constructor() {
    super('Cancelled.');
  }
}

/** Pending calls of a worker that was replaced; `retry` when the page should solve again. */
export class Restarted extends Error {
  constructor(
    message: string,
    readonly retry: boolean,
  ) {
    super(message);
  }
}

const HUNG = 'The solver stopped responding and was restarted.';
/** Longest wait for a render, detector measurement or geometry call before the worker counts as hung. */
const CALL_TIMEOUT_MS = 15_000;
/**
 * A solve counts as hung after this many times its predicted time, and at
 * least 8 s (a phone's first solves run unoptimised wasm, several times
 * slower); 30 s when nothing was predicted.
 */
const SOLVE_TIMEOUT_FACTOR = 20;
const SOLVE_TIMEOUT_MIN_MS = 8_000;
const SOLVE_TIMEOUT_UNKNOWN_MS = 30_000;

export const solveTimeoutMs = (predicted_s?: number) =>
  predicted_s && predicted_s > 0
    ? Math.max(SOLVE_TIMEOUT_MIN_MS, predicted_s * 1000 * SOLVE_TIMEOUT_FACTOR)
    : SOLVE_TIMEOUT_UNKNOWN_MS;

/**
 * One worker with its wasm instance and stored field. `onFatal` runs when the
 * wasm trapped, the worker failed, or a call outlived its timeout: a worker
 * the browser killed (iOS does under memory pressure) never answers, and
 * without a timeout the page would wait on it for ever.
 */
class Lane {
  readonly worker: Worker;
  private nextId = 0;
  private pending = new Map<number, Pending & {timer?: ReturnType<typeof setTimeout>}>();
  private dead = false;
  /** Solves run so far: the first ones run before the engine has optimised the wasm. */
  solves = 0;

  constructor(private onFatal: (reason: string) => void) {
    this.worker = new Worker(new URL('./worker.ts', import.meta.url), {type: 'module'});
    this.worker.onmessage = ({data}) => {
      const p = this.pending.get(data.id);
      if (!p) return;
      this.pending.delete(data.id);
      clearTimeout(p.timer);
      if (data.ok) p.resolve(data.value);
      else {
        if (data.fatal) this.fail('The solver crashed and was restarted.');
        p.reject(new Error(data.error));
      }
    };
    this.worker.onerror = (e) => {
      e.preventDefault();
      this.fail(e.message || 'The solver failed to start.');
    };
    this.worker.onmessageerror = () => this.fail('The solver sent an unreadable reply and was restarted.');
  }

  private fail(reason: string) {
    if (this.dead) return;
    this.onFatal(reason);
  }

  /** `timeoutMs` 0 waits for ever (puzzle evaluations, whose length is unknown). */
  call<T>(op: string, args: unknown[], timeoutMs = CALL_TIMEOUT_MS): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      if (this.dead) return reject(new Cancelled());
      const id = this.nextId++;
      const timer = timeoutMs > 0 ? setTimeout(() => this.fail(HUNG), timeoutMs) : undefined;
      this.pending.set(id, {resolve: resolve as (v: unknown) => void, reject, timer});
      this.worker.postMessage({id, op, args});
    });
  }

  kill(err: Error) {
    this.dead = true;
    this.worker.terminate();
    for (const p of this.pending.values()) {
      clearTimeout(p.timer);
      p.reject(err);
    }
    this.pending.clear();
  }
}

interface RefineJob {
  lane: Lane;
  started: number;
  predicted_s: number;
  /** Superseded but left to finish: killing a worker costs a new wasm instance. */
  discarded: boolean;
}

/**
 * Three workers: a geometry one for field-free calls (outlines, checks), so
 * the overlay follows edits at once even while a solve runs; the active one
 * holds the displayed field; the spare one runs background refinement solves.
 * A finished refinement swaps active and spare, so the refined field becomes
 * the active one. Cancelling a refinement that is nearly done just discards
 * its result; a longer one is stopped by replacing the spare worker. Neither
 * disturbs the displayed field.
 */
export class Solver {
  private active!: Lane;
  /** Field-free work (outlines, checks, examples, puzzles), so it never waits behind a solve. */
  private geo!: Lane;
  private spare: Lane | null = null;
  private job: RefineJob | null = null;
  /** Called when the active worker was replaced, so the page knows the stored field is gone. */
  onReset: (reason: string, retry: boolean) => void = () => {};

  constructor() {
    this.active = this.lane();
    this.startGeo();
  }

  private startGeo() {
    const lane: Lane = new Lane((reason) => {
      if (lane !== this.geo) return;
      lane.kill(new Error(reason));
      this.startGeo();
    });
    this.geo = lane;
  }

  private lane(): Lane {
    const lane: Lane = new Lane((reason) => {
      if (lane === this.active) this.restart(reason, true);
      else if (lane === this.spare) this.replaceSpare();
    });
    return lane;
  }

  private replaceSpare() {
    this.spare?.kill(new Cancelled());
    this.spare = this.lane();
    this.job = null;
  }

  private restart(reason: string, retry: boolean) {
    this.active.kill(new Restarted(reason, retry));
    this.spare?.kill(new Cancelled());
    this.spare = null;
    this.job = null;
    this.active = this.lane();
    this.onReset(reason, retry);
  }

  /** Drops the field workers and everything in them (a Stop), and starts fresh ones. */
  reset(reason: string) {
    this.restart(reason, false);
  }

  /** Stops a running refinement; the displayed field stays. */
  cancelRefine() {
    const job = this.job;
    if (!job || job.discarded) return;
    const remaining_s = job.predicted_s - (performance.now() - job.started) / 1000;
    if (remaining_s < SOFT_CANCEL_S) job.discarded = true;
    else this.replaceSpare();
  }

  /**
   * Solves on the spare worker and, if not cancelled meanwhile, makes its field
   * the active one. Rejects with `Cancelled` when `cancelRefine` (or a reset)
   * stopped it.
   */
  async refine(scene: string, method: string, quality: Quality, predicted_s: number): Promise<SolveMeta> {
    this.cancelRefine();
    if (!this.spare) this.spare = this.lane();
    const lane = this.spare;
    const job: RefineJob = {lane, started: performance.now(), predicted_s, discarded: false};
    this.job = job;
    try {
      const meta = await this.solveOn(lane, scene, method, quality, predicted_s);
      if (job.discarded || lane !== this.spare) throw new Cancelled();
      this.spare = this.active;
      this.active = lane;
      return meta;
    } catch (e) {
      // Errors of a replaced or discarded job are just the cancellation.
      throw lane === this.spare && !job.discarded ? e : new Cancelled();
    } finally {
      if (this.job === job) this.job = null;
    }
  }

  private call<T>(op: string, ...args: unknown[]): Promise<T> {
    return this.active.call<T>(op, args);
  }

  private async solveOn(lane: Lane, scene: string, method: string, quality: Quality, predicted_s?: number): Promise<SolveMeta> {
    const meta = await lane.call<SolveMeta>('solve', [scene, method, quality], solveTimeoutMs(predicted_s));
    meta.cold = lane.solves++ < COLD_SOLVES;
    return meta;
  }

  private geoCall<T>(op: string, ...args: unknown[]): Promise<T> {
    return this.geo.call<T>(op, args);
  }

  examples = () => this.geoCall<Example[]>('examples');
  example = (name: string) => this.geoCall<string>('example', name);
  materialPresets = () => this.geoCall<MaterialPreset[]>('materialPresets');
  outlines = (scene: string) => this.geoCall<SceneOutlines>('outlines', scene);
  check = (scene: string) => this.geoCall<CheckReport>('check', scene);
  solve = (scene: string, method: string, predicted_s?: number) => this.solveOn(this.active, scene, method, 'preview', predicted_s);
  measureDetectors = (detectorsJson: string) => this.call<DetectorReading[]>('measureDetectors', detectorsJson);
  render = (view: string, width: number, height: number) => this.call<Uint8Array>('render', view, width, height);
  puzzles = () => this.geoCall<PuzzleSummary[]>('puzzles');
  puzzle = (id: string) => this.geoCall<Puzzle>('puzzle', id);
  puzzleCheck = (id: string, designJson: string) => this.geoCall<PuzzleCheckReport>('puzzleCheck', id, designJson);
  // The per-source fields live in the active worker; a refinement finishing
  // later would swap them away. An evaluation's length is unknown: no timeout.
  puzzleEvaluate = (id: string, designJson: string) => {
    this.cancelRefine();
    return this.active.call<PuzzleEvaluation>('puzzleEvaluate', [id, designJson], 0);
  };
  selectPuzzleCase = (weights: number[]) => this.call<SolveMeta>('selectPuzzleCase', weights);
  clearPuzzleFields = () => this.call<null>('clearPuzzleFields');
}
