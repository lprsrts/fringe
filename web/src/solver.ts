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

/** Thrown by `refine` when a newer edit cancelled it; not an error to show. */
export class Cancelled extends Error {
  constructor() {
    super('Cancelled.');
  }
}

/** One worker with its wasm instance and stored field. */
class Lane {
  readonly worker: Worker;
  private nextId = 0;
  private pending = new Map<number, Pending>();
  /** Solves run so far: the first ones run before V8 has optimised the wasm. */
  solves = 0;

  constructor(onFatal: (reason: string) => void) {
    this.worker = new Worker(new URL('./worker.ts', import.meta.url), {type: 'module'});
    this.worker.onmessage = ({data}) => {
      const p = this.pending.get(data.id);
      if (!p) return;
      this.pending.delete(data.id);
      if (data.ok) p.resolve(data.value);
      else {
        if (data.fatal) onFatal('The solver crashed and was restarted.');
        p.reject(new Error(data.error));
      }
    };
    this.worker.onerror = (e) => {
      e.preventDefault();
      onFatal(e.message || 'The solver failed to start.');
    };
  }

  call<T>(op: string, ...args: unknown[]): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      const id = this.nextId++;
      this.pending.set(id, {resolve: resolve as (v: unknown) => void, reject});
      this.worker.postMessage({id, op, args});
    });
  }

  kill(err: Error) {
    this.worker.terminate();
    for (const p of this.pending.values()) p.reject(err);
    this.pending.clear();
  }
}

/**
 * Three workers: a geometry one for field-free calls (outlines, checks), so
 * the overlay follows edits at once even while a solve runs; the active one
 * holds the displayed field; the spare one runs background refinement solves. A finished
 * refinement swaps the two, so the refined field becomes the active one. A
 * refinement can be cancelled at any time by replacing the spare worker,
 * which never disturbs the displayed field.
 */
export class Solver {
  private active!: Lane;
  /** Field-free work (outlines, checks, examples, puzzles), so it never waits behind a solve. */
  private geo!: Lane;
  private spare: Lane | null = null;
  private refining = false;
  /** Called when the worker was replaced, so the page knows the stored field is gone. */
  onReset: (reason: string) => void = () => {};

  constructor() {
    this.active = this.lane();
    this.startGeo();
  }

  private startGeo() {
    const lane: Lane = new Lane(() => {
      if (lane === this.geo) {
        lane.kill(new Error('The geometry worker crashed and was restarted.'));
        this.startGeo();
      }
    });
    this.geo = lane;
  }

  private lane(): Lane {
    const lane: Lane = new Lane((reason) => {
      if (lane === this.active) this.reset(reason);
      else if (lane === this.spare) this.replaceSpare();
    });
    return lane;
  }

  private replaceSpare() {
    this.spare?.kill(new Cancelled());
    this.spare = this.lane();
    this.refining = false;
  }

  /** Drops both workers and everything in them, and starts fresh ones. */
  reset(reason: string) {
    this.active.kill(new Error(reason));
    this.spare?.kill(new Cancelled());
    this.spare = null;
    this.refining = false;
    this.active = this.lane();
    this.onReset(reason);
  }

  /** Stops a running refinement; the displayed field stays. */
  cancelRefine() {
    if (this.refining) this.replaceSpare();
  }

  /**
   * Solves on the spare worker and, if not cancelled meanwhile, makes its field
   * the active one. Rejects with `Cancelled` when `cancelRefine` (or a reset)
   * stopped it.
   */
  async refine(scene: string, method: string, quality: Quality): Promise<SolveMeta> {
    this.cancelRefine();
    if (!this.spare) this.spare = this.lane();
    const lane = this.spare;
    this.refining = true;
    try {
      const meta = await this.solveOn(lane, scene, method, quality);
      if (lane !== this.spare) throw new Cancelled();
      this.spare = this.active;
      this.active = lane;
      return meta;
    } catch (e) {
      // A replaced lane's errors are just the cancellation.
      throw lane === this.spare ? e : new Cancelled();
    } finally {
      if (lane === this.active || lane === this.spare) this.refining = false;
    }
  }

  private call<T>(op: string, ...args: unknown[]): Promise<T> {
    return this.active.call<T>(op, ...args);
  }

  private async solveOn(lane: Lane, scene: string, method: string, quality: Quality): Promise<SolveMeta> {
    const meta = await lane.call<SolveMeta>('solve', scene, method, quality);
    meta.cold = lane.solves++ < COLD_SOLVES;
    return meta;
  }

  private geoCall<T>(op: string, ...args: unknown[]): Promise<T> {
    return this.geo.call<T>(op, ...args);
  }

  examples = () => this.geoCall<Example[]>('examples');
  example = (name: string) => this.geoCall<string>('example', name);
  materialPresets = () => this.geoCall<MaterialPreset[]>('materialPresets');
  outlines = (scene: string) => this.geoCall<SceneOutlines>('outlines', scene);
  check = (scene: string) => this.geoCall<CheckReport>('check', scene);
  solve = (scene: string, method: string) => this.solveOn(this.active, scene, method, 'preview');
  measureDetectors = (detectorsJson: string) => this.call<DetectorReading[]>('measureDetectors', detectorsJson);
  render = (view: string, width: number, height: number) => this.call<Uint8Array>('render', view, width, height);
  puzzles = () => this.geoCall<PuzzleSummary[]>('puzzles');
  puzzle = (id: string) => this.geoCall<Puzzle>('puzzle', id);
  puzzleCheck = (id: string, designJson: string) => this.geoCall<PuzzleCheckReport>('puzzleCheck', id, designJson);
  // The per-source fields live in the active worker; a refinement finishing
  // later would swap them away.
  puzzleEvaluate = (id: string, designJson: string) => {
    this.cancelRefine();
    return this.call<PuzzleEvaluation>('puzzleEvaluate', id, designJson);
  };
  selectPuzzleCase = (weights: number[]) => this.call<SolveMeta>('selectPuzzleCase', weights);
  clearPuzzleFields = () => this.call<null>('clearPuzzleFields');
}
