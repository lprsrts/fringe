// Puzzle composition, rule helpers, scoring formatting, truth-table building,
// and localStorage progress persistence. Mirrors Swift's Puzzle+Rules and
// PuzzleReport so the browser and Mac app agree on every number.
import type {DetectorReading, MaterialPreset, PaletteEntry, Puzzle, PuzzleEvaluation} from './solver';
import {formatFixed, formatSig, humanize, readingIncident, readingTotal, sameMaterial, type Json, type Scene} from './scene';

export const CHAPTERS: {id: string; title: string; subtitle: string}[] = [
  {id: 'steering', title: 'Steering light', subtitle: 'Focus, reflect and split beams with lenses, mirrors and slabs.'},
  {id: 'interference', title: 'Interference', subtitle: 'Cancel, trap and guide waves by matching their phase.'},
  {id: 'logic', title: 'Logic with light', subtitle: 'Build NOT, OR, AND, XOR, NAND and a binary half adder from glass.'},
  {id: 'metals', title: 'Metals and emitters', subtitle: 'Shape emission and shadow with dispersive gold, silver and aluminium.'},
];

export const PUZZLE_FLOOR = 1e-6;

export function lockedIds(puzzle: Puzzle): Set<string> {
  return new Set(puzzle.rules.locked ?? []);
}

export function startingParts(puzzle: Puzzle): Json[] {
  const locked = lockedIds(puzzle);
  const elements = (puzzle.scene.elements as Json[] | undefined) ?? [];
  return structuredClone(elements.filter((e) => !locked.has(String(e.id))));
}

export function inputLetters(inputs: string[] | undefined): string[] {
  const n = inputs?.length ?? 0;
  return Array.from({length: n}, (_, i) => String.fromCharCode(65 + Math.min(i, 25)));
}

export function allCases(inputs: string[] | undefined): boolean[][] {
  const n = inputs?.length ?? 0;
  if (n === 0) return [[]];
  return Array.from({length: 1 << n}, (_, k) =>
    Array.from({length: n}, (_, i) => ((k >> (n - 1 - i)) & 1) === 1),
  );
}

export function bitsEqual(a: boolean[], b: boolean[]): boolean {
  return a.length === b.length && a.every((v, i) => v === b[i]);
}

/** Composes the puzzle scene with the player's design and active input bits,
 * using the puzzle's scoring solver and preview_ppw so live preview matches Check. */
export function composePuzzleScene(puzzle: Puzzle, design: Json[], bits?: boolean[]): Scene {
  const scene = structuredClone(puzzle.scene) as Scene;
  if (!Array.isArray(scene.detectors)) scene.detectors = [];
  if (!Array.isArray(scene.elements)) scene.elements = [];
  const locked = lockedIds(puzzle);

  const used = new Array<boolean>(design.length).fill(false);
  const elements: Json[] = [];
  for (const el of scene.elements) {
    const idx = design.findIndex((d, k) => !used[k] && d.id === el.id);
    if (idx >= 0) used[idx] = true;
    if (locked.has(String(el.id))) {
      elements.push(el);
    } else if (idx >= 0) {
      elements.push(structuredClone(design[idx]));
    }
  }
  for (let k = 0; k < design.length; k++) {
    if (!used[k]) elements.push(structuredClone(design[k]));
  }
  scene.elements = elements;

  const inputs = puzzle.inputs ?? [];
  for (let i = 0; i < inputs.length; i++) {
    const src = scene.sources.find((s) => s.id === inputs[i]);
    if (src) src.enabled = bits && i < bits.length ? bits[i] : true;
  }

  const method = puzzle.scoring.method;
  scene.solver = {...scene.solver, method};
  const mSettings = (scene.solver[method] as Json | undefined) ?? {};
  scene.solver[method] = {...mSettings, preview_ppw: puzzle.scoring.ppw};
  return scene;
}

export function extractDesign(puzzle: Puzzle, scene: Scene): Json[] {
  const locked = lockedIds(puzzle);
  return scene.elements.filter((e) => !locked.has(String(e.id)));
}

/** Deterministic signature of the player's design (independent of input switches). */
export function designSignature(puzzle: Puzzle, scene: Scene): string {
  return JSON.stringify(extractDesign(puzzle, scene));
}

export function resolvePaletteMaterial(puzzle: Puzzle, name: string, presets: MaterialPreset[]): Json | null {
  if (name === 'pec') return {type: 'pec'};
  const own = puzzle.rules.materials?.[name];
  if (own) {
    const {name: _n, ...mat} = own;
    return structuredClone(mat);
  }
  const preset = presets.find((p) => p.id === name);
  return preset ? structuredClone(preset.material) : null;
}

export function paletteMaterialTitle(puzzle: Puzzle, name: string, presets: MaterialPreset[]): string {
  if (name === 'pec') return 'PEC';
  const own = puzzle.rules.materials?.[name];
  if (own?.name) return own.name;
  if (own) return humanize(name.replace(/-/g, ' '));
  return presets.find((p) => p.id === name)?.name ?? humanize(name);
}

/** How many enabled player elements are assigned to each palette entry. */
export function paletteUsage(puzzle: Puzzle, design: Json[], presets: MaterialPreset[]): number[] {
  const entries = puzzle.rules.palette;
  const used = new Array<number>(entries.length).fill(0);
  for (const el of design) {
    if (el.enabled === false) continue;
    const kind = String((el.shape as Json | undefined)?.kind ?? '');
    const mat = el.material as Json | undefined;
    const fits: number[] = [];
    for (let i = 0; i < entries.length; i++) {
      const entry = entries[i];
      if (entry.kind !== kind) continue;
      const mats = entry.materials ?? [];
      if (mats.length === 0 || mats.some((m) => sameMaterial(mat, resolvePaletteMaterial(puzzle, m, presets) ?? undefined))) {
        fits.push(i);
      }
    }
    const target = fits.find((i) => entries[i].max === undefined || used[i] < entries[i].max!) ?? fits[0];
    if (target !== undefined) used[target] += 1;
  }
  return used;
}

export function enabledDesignCount(design: Json[]): number {
  return design.filter((e) => e.enabled !== false).length;
}

export function canAddPalettePart(puzzle: Puzzle, design: Json[], entryIndex: number, presets: MaterialPreset[]): boolean {
  const entry = puzzle.rules.palette[entryIndex];
  if (!entry) return false;
  if (puzzle.rules.max_elements !== undefined && enabledDesignCount(design) >= puzzle.rules.max_elements) return false;
  const usage = paletteUsage(puzzle, design, presets);
  if (entry.max !== undefined && usage[entryIndex] >= entry.max) return false;
  return true;
}

/** Allowed material names for an element of `kind` in `puzzle`. Empty means any. */
export function allowedMaterialsForKind(puzzle: Puzzle, kind: string): string[] | null {
  const entries = puzzle.rules.palette.filter((e) => e.kind === kind);
  if (entries.length === 0) return [];
  if (entries.some((e) => !e.materials || e.materials.length === 0)) return null;
  const set = new Set<string>();
  for (const e of entries) for (const m of e.materials ?? []) set.add(m);
  return [...set];
}

export function paletteEntryLabel(puzzle: Puzzle, entry: PaletteEntry, presets: MaterialPreset[]): string {
  const mats = entry.materials ?? [];
  if (mats.length === 0) return 'Any material';
  return mats.map((m) => paletteMaterialTitle(puzzle, m, presets)).join(' / ');
}

// ---- Scoring display

export interface ScoreScale {
  label: string;
  unit: 'dB' | '%' | '×' | '';
}

export function puzzleScoreScale(puzzle: Puzzle): ScoreScale {
  const g = puzzle.goal;
  switch (g.type) {
    case 'truth_table':
      return {label: 'contrast', unit: 'dB'};
    case 'minimize':
      return {label: 'suppression', unit: 'dB'};
    case 'target':
      return {label: 'balanced power', unit: '%'};
    case 'maximize': {
      const det = (puzzle.scene.detectors as Json[] | undefined)?.find((d) => d.id === g.detector);
      const isBox = (det?.shape as Json | undefined)?.kind === 'box';
      return isBox ? {label: 'intensity', unit: '×'} : {label: 'power', unit: '%'};
    }
    default:
      return {label: 'score', unit: ''};
  }
}

export function formatScore(scale: ScoreScale, value: number | null | undefined): string {
  if (value === null || value === undefined || !Number.isFinite(value)) return '—';
  if (scale.unit === 'dB') return `${formatFixed(value, 1)} dB`;
  if (scale.unit === '%') return `${formatFixed(value, 1)}%`;
  if (scale.unit === '×') return `${formatFixed(value, 2)}×`;
  return formatSig(value);
}

export function formatThreshold(scale: ScoreScale, value: number): string {
  const n = Number.isInteger(value) ? String(value) : formatFixed(value, 1);
  if (scale.unit === 'dB') return `${n} dB`;
  return `${n}${scale.unit}`;
}

export function puzzleValueStyle(puzzle: Puzzle): 'ratio' | 'percent' | 'factor' {
  if (puzzle.goal.type === 'truth_table') return 'ratio';
  if (puzzle.goal.type === 'maximize' && puzzleScoreScale(puzzle).unit === '×') return 'factor';
  return 'percent';
}

export function formatPuzzleValue(puzzle: Puzzle, value: number | null | undefined): string {
  if (value === null || value === undefined || !Number.isFinite(value)) return '—';
  const style = puzzleValueStyle(puzzle);
  if (style === 'ratio') return formatSig(value);
  if (style === 'factor') return `${formatFixed(value, 2)}×`;
  const p = value * 100;
  if (Math.abs(p) >= 1e-4 && Math.abs(p) < 1) {
    const decimals = Math.min(4, 1 - Math.floor(Math.log10(Math.abs(p))));
    return `${formatFixed(p, decimals)}%`;
  }
  return `${formatFixed(p, 1)}%`;
}

export function detectorDisplayName(puzzle: Puzzle, id: string): string {
  const det = (puzzle.scene.detectors as Json[] | undefined)?.find((d) => d.id === id);
  if (det && typeof det.name === 'string' && det.name.trim()) return det.name;
  return id;
}

export function goalDetectorIds(puzzle: Puzzle): string[] {
  const g = puzzle.goal;
  if (g.type === 'truth_table') return (g.outputs ?? []).map((o) => o.detector);
  if (g.type === 'maximize') return g.detector ? [g.detector] : [];
  return g.detectors ?? [];
}

export function puzzleTaskLine(puzzle: Puzzle): string {
  if (puzzle.goal.text?.trim()) return puzzle.goal.text.trim();
  return puzzle.title;
}

export function puzzlePassLine(puzzle: Puzzle): string {
  const scale = puzzleScoreScale(puzzle);
  let line = `Pass: ${scale.label} of at least ${formatThreshold(scale, puzzle.goal.pass)}`;
  if (puzzle.goal.type === 'target' && puzzle.goal.tolerance !== undefined) {
    line += `, split within ${Math.round(puzzle.goal.tolerance * 100)} points`;
  }
  return line;
}

export function puzzleStarsLine(puzzle: Puzzle): string {
  const scale = puzzleScoreScale(puzzle);
  const [a, b, c] = puzzle.stars.map((v) => (Number.isInteger(v) ? String(v) : formatFixed(v, 1)));
  const unit = scale.unit === 'dB' ? ' dB' : scale.unit;
  return `Stars at ${a}, ${b} and ${c}${unit}`;
}

/** Live detector value relative to the puzzle's reference, before a Check. */
export function computePuzzleLiveValue(
  puzzle: Puzzle,
  reading: DetectorReading,
  allSourcesOff: boolean,
): number | null {
  if (allSourcesOff) return 0;
  const g = puzzle.goal;
  const isLine = reading.kind === 'line';
  let raw: number;
  let inc: number;
  if (isLine) {
    raw = g.type === 'minimize' && (g.quantity ?? 'scattered') === 'scattered' ? reading.flux.scattered : reading.flux.total;
    inc = reading.flux.incident;
  } else {
    raw = reading.total.mean;
    inc = reading.incident.mean;
  }
  const ref = g.reference ?? 'source';
  let denom: number | null = null;
  if (typeof ref === 'number') denom = ref;
  else if (ref === 'incident') denom = inc;
  else denom = isLine ? puzzle.reference_power : puzzle.reference_intensity;
  if (denom === null || !Number.isFinite(denom) || denom <= 0) return null;
  const v = raw / denom;
  return Number.isFinite(v) ? v : null;
}

export interface TruthRow {
  caseIndex: number;
  bits: boolean[];
  cells: {
    detector: string;
    target: boolean;
    value: number | null;
    passes: boolean | null;
    decisive: boolean;
  }[];
  passes: boolean | null;
}

export function buildTruthRows(puzzle: Puzzle, evaluation: PuzzleEvaluation | null): TruthRow[] {
  const cases = allCases(puzzle.inputs);
  const outputs = puzzle.goal.outputs ?? [];
  const validEval = evaluation?.valid ? evaluation : null;
  const passRatio = 10 ** ((validEval?.pass ?? puzzle.goal.pass) / 10);

  // Per output: find weakest 1 and strongest 0 so we know which rows pass and which decide contrast.
  const stats = outputs.map((o, j) => {
    let minOne = Infinity, minOneIdx = -1;
    let maxZero = -Infinity, maxZeroIdx = -1;
    if (validEval) {
      validEval.cases.forEach((c, k) => {
        const val = c.outputs[j]?.value;
        if (val === null || val === undefined || !Number.isFinite(val)) return;
        const on = o.bits[k] === 1;
        if (on && val < minOne) { minOne = val; minOneIdx = k; }
        if (!on && val > maxZero) { maxZero = val; maxZeroIdx = k; }
      });
    }
    return {minOne, minOneIdx, maxZero, maxZeroIdx};
  });

  return cases.map((bits, k) => {
    const evCase = validEval?.cases[k];
    const cells = outputs.map((o, j) => {
      const target = o.bits[k] === 1;
      const val = evCase?.outputs[j]?.value ?? null;
      const st = stats[j];
      let passes: boolean | null = null;
      if (val !== null && Number.isFinite(val) && Number.isFinite(st.minOne) && Number.isFinite(st.maxZero)) {
        const vFloor = Math.max(val, PUZZLE_FLOOR);
        passes = target
          ? vFloor / Math.max(st.maxZero, PUZZLE_FLOOR) >= passRatio
          : Math.max(st.minOne, PUZZLE_FLOOR) / vFloor >= passRatio;
      }
      const decisive = (target && st.minOneIdx === k) || (!target && st.maxZeroIdx === k);
      return {detector: o.detector, target, value: val, passes, decisive};
    });
    const verdicts = cells.map((c) => c.passes).filter((v): v is boolean => v !== null);
    const passes = verdicts.length === cells.length && cells.length > 0 ? verdicts.every(Boolean) : null;
    return {caseIndex: k, bits, cells, passes};
  });
}

/** Weight vector for `selectPuzzleCase` given input bits and evaluation's `sources` order. */
export function caseWeights(puzzle: Puzzle, sources: string[], bits: boolean[]): number[] {
  const inputs = puzzle.inputs ?? [];
  return sources.map((id) => {
    const idx = inputs.indexOf(id);
    if (idx < 0) return 1;
    return bits[idx] ? 1 : 0;
  });
}

// ---- Local progress persistence

export interface PuzzleProgress {
  bestScore?: number;
  stars: number;
  design?: Json[];
}

export type ProgressMap = Record<string, PuzzleProgress>;

const STORAGE_KEY = 'fringe.web.puzzles.v1';

export function loadProgress(): ProgressMap {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return {};
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === 'object' ? (parsed as ProgressMap) : {};
  } catch {
    return {};
  }
}

export function saveProgress(map: ProgressMap) {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(map));
  } catch {
    // Ignore quota or private-mode errors.
  }
}

export {readingIncident, readingTotal};
