// Progressive preview: while the scene is being edited, solve a draft at a
// resolution sized to a time budget; once edits stop, refine in the background
// (cancellable) up to the preview and, when it is cheap enough, the final
// resolution.
//
// Resolution is lowered globally (points per wavelength), not per region: a
// wave field is global, so a local change alters the solution everywhere and
// a patchwork of resolutions would show seams and wrong interference.
//
// Cost model: the check's estimate for the full preview (or final), times a
// per-method correction learned from measured solve times, scaled by
// (ppw / estimate ppw)^slope with the slope also learned (CostModel).

import type {CheckReport, Quality, SolveMeta} from './solver';

/**
 * Phones and small machines: they heat up and throttle under sustained load,
 * and iOS kills pages that use too much memory. There the preview skips the
 * background final-quality solve, waits longer before refining, and leaves
 * the CPU idle between drafts for as long as a draft took.
 */
export const LOW_POWER =
  typeof matchMedia === 'function' && matchMedia('(pointer: coarse)').matches
    ? true
    : (typeof navigator !== 'undefined' ? navigator.hardwareConcurrency ?? 8 : 8) <= 4;

/** Wall time a draft solve aims for while editing, in seconds. */
export const DRAFT_BUDGET_S = 0.1;
/** How long edits must pause before refining starts, in ms. */
export const REFINE_DELAY_MS = LOW_POWER ? 400 : 150;
/** Slowest full preview that is solved without a draft first. */
const SKIP_DRAFT_S = DRAFT_BUDGET_S * 1.6;
/** Background refinements to the final resolution only when about this fast… */
const FINAL_MAX_S = 6;
/** …and this small (wasm has a 4 GB address space and two workers). */
const FINAL_MAX_MB = 1200;
/** The solver refuses resolutions below this. */
const MIN_PPW = 4;
/**
 * Drafts keep at least this share of the preview resolution: coarser ones are
 * visibly blocky and dispersive, and the overlay already shows each edit at
 * once, so the field may take a little longer instead.
 */
const MIN_FRACTION = 0.65;
const DEFAULT_OUTPUT_PPW = 6;

/**
 * Starting guesses for how solve time grows with resolution, t ∝ ppw^slope,
 * measured in the browser on the examples: FDTD cells × steps less its fixed
 * PML and settling work; FEM's sparse factorisation; MoM's panel solve plus
 * output sampling (which drafts coarsen along with the panels). Each method's
 * slope is then learned from the draft and refinement solves of each scene.
 */
const SLOPE: Record<string, number> = {fdtd: 2.3, fem: 2.7, mom: 1.6};
const SLOPE_RANGE: [number, number] = [0.5, 3.5];

export type Stage = 'draft' | 'refine' | 'preview' | 'final';

export interface Step {
  stage: Stage;
  quality: Quality;
  /** Override for the method's preview_ppw; null keeps the solver's own choice. */
  ppw: number | null;
  /** Predicted wall time, for the status bar. */
  predicted_s: number;
}

export interface Plan {
  /** Solved right away on the active worker. */
  first: Step;
  /** Solved one after another in the background once edits pause. */
  refine: Step[];
}

const ema = (old: number | undefined, obs: number) => (old === undefined ? obs : 0.5 * old + 0.5 * obs);

/**
 * Learns, per method, how measured solve time relates to the check's estimate
 * (a log-space correction per quality) and how it scales with resolution (a
 * log-log slope from pairs of solves of the same scene at different ppw).
 */
export class CostModel {
  private logRatio = new Map<string, number>();
  private slopes = new Map<string, number>();
  private last = new Map<string, {estimate_s: number; logR: number; logT: number}>();

  slope(method: string): number {
    return this.slopes.get(method) ?? SLOPE[method] ?? 2.5;
  }

  private ratio(method: string, quality: Quality): number {
    const k = this.logRatio.get(`${method}:${quality}`) ?? this.logRatio.get(`${method}:preview`);
    return k === undefined ? 1 : Math.exp(k);
  }

  predict(method: string, quality: Quality, estimate_s: number, ppw: number, estimatePpw: number): number {
    return estimate_s * this.ratio(method, quality) * Math.pow(ppw / estimatePpw, this.slope(method));
  }

  /** Learns from a finished solve, given the check's estimate (time and ppw) for its quality. */
  observe(method: string, quality: Quality, estimate_s: number, estimatePpw: number, meta: SolveMeta) {
    const ppw = meta.ppw ?? estimatePpw;
    if (meta.cold || !(estimate_s > 0) || !(meta.wall_s > 0.002) || !(ppw > 0)) return;
    const logR = Math.log(ppw / estimatePpw);
    const logT = Math.log(meta.wall_s);
    if (quality === 'preview') {
      // Same estimate means the same scene: the pair gives the scaling slope.
      const prev = this.last.get(method);
      if (prev && prev.estimate_s === estimate_s && Math.abs(logR - prev.logR) > 0.15) {
        const obs = (logT - prev.logT) / (logR - prev.logR);
        const clamped = Math.min(SLOPE_RANGE[1], Math.max(SLOPE_RANGE[0], obs));
        this.slopes.set(method, ema(this.slopes.get(method) ?? SLOPE[method], clamped));
      }
      this.last.set(method, {estimate_s, logR, logT});
    }
    const key = `${method}:${quality}`;
    const obs = logT - Math.log(estimate_s) - this.slope(method) * logR;
    this.logRatio.set(key, ema(this.logRatio.get(key), obs));
  }
}

/** Plans the draft and the refinement ladder for a scene from its check report. */
export function plan(report: CheckReport, method: string, cost: CostModel): Plan {
  const full: Step = {stage: 'preview', quality: 'preview', ppw: null, predicted_s: 0};
  const est = report.estimates?.preview;
  if (!est || !(est.seconds > 0) || !est.ppw) return {first: full, refine: []};
  const P = est.ppw;
  const e = cost.slope(method);
  const fullS = cost.predict(method, 'preview', est.seconds, P, P);
  full.predicted_s = fullS;

  const refine: Step[] = [];
  let first = full;
  if (fullS > SKIP_DRAFT_S) {
    const r = Math.pow(DRAFT_BUDGET_S / fullS, 1 / e);
    const ppw = Math.max(MIN_PPW, MIN_FRACTION * P, Math.floor(P * r * 10) / 10);
    const draftS = cost.predict(method, 'preview', est.seconds, ppw, P);
    // A draft only pays when it is clearly faster than the full preview.
    if (ppw < 0.85 * P && draftS < 0.6 * fullS) {
      first = {stage: 'draft', quality: 'preview', ppw, predicted_s: draftS};
      // One step in between when the full preview takes long enough to wait on.
      const mid = Math.floor(Math.sqrt(ppw * P) * 10) / 10;
      if (fullS > 0.8 && mid > ppw * 1.15 && mid < P * 0.9) {
        refine.push({stage: 'refine', quality: 'preview', ppw: mid, predicted_s: cost.predict(method, 'preview', est.seconds, mid, P)});
      }
      refine.push(full);
    }
  }

  const fin = LOW_POWER ? null : report.estimates?.final;
  if (fin && fin.seconds > 0 && fin.ppw && fin.memory_mb <= FINAL_MAX_MB) {
    const finS = cost.predict(method, 'final', fin.seconds, fin.ppw, fin.ppw);
    if (finS <= FINAL_MAX_S) refine.push({stage: 'final', quality: 'final', ppw: null, predicted_s: finS});
  }
  return {first, refine};
}

/** `scene` with the step's resolution override applied (the solver reads `solver.<method>.preview_ppw`). */
export function sceneForStep(scene: object, method: string, step: Step, fullPpw: number | null): string {
  if (step.ppw === null) return JSON.stringify(scene);
  const solver = {...(((scene as {solver?: unknown}).solver as Record<string, unknown>) ?? {})};
  solver[method] = {...((solver[method] as Record<string, unknown>) ?? {}), preview_ppw: step.ppw};
  if (fullPpw) {
    const output = {...((solver.output as Record<string, unknown>) ?? {})};
    const base = (output.preview_ppw as number | undefined) ?? DEFAULT_OUTPUT_PPW;
    output.preview_ppw = Math.max(MIN_PPW, Math.floor(base * Math.min(1, step.ppw / fullPpw) * 10) / 10);
    solver.output = output;
  }
  return JSON.stringify({...scene, solver});
}
