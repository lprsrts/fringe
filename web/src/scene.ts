// The parts of the scene format (the JSON the Mac app and fringe-cli share)
// that the page edits directly. Everything else passes through untouched.
import type {DetectorReading, MaterialPreset} from './solver';

export type Json = Record<string, unknown>;

export interface Domain {
  x_min_um: number;
  x_max_um: number;
  y_min_um: number;
  y_max_um: number;
}

export interface Scene extends Json {
  version?: number;
  wavelength_um: number;
  background: {n: number} & Json;
  sources: Json[];
  elements: Json[];
  detectors: Json[];
  domain: Domain & Json;
  solver: {method: string} & Json;
}

/** The most memory a solve may plan for in the browser. A scene can raise its
 * own limit (solver.memory_limit_mb), which the native app allows; here it is
 * capped, so a link can't ask for a multi-gigabyte solve. */
export const MAX_MEMORY_MB = 1024;

const isObject = (v: unknown): v is Json => typeof v === 'object' && v !== null && !Array.isArray(v);
const isNumber = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v);

/**
 * Parses scene JSON and checks the shape the page relies on before it is used
 * (the core's own check runs on every solve and reports the rest). Throws an
 * Error saying what is wrong. Clamps the memory limit to MAX_MEMORY_MB.
 */
export function parseScene(text: string): Scene {
  const v: unknown = JSON.parse(text);
  const fail = (what: string): never => {
    throw new Error(`not a Fringe scene: ${what}`);
  };
  if (!isObject(v)) fail('expected a JSON object');
  const s = v as Json;
  if (!isNumber(s.wavelength_um) || s.wavelength_um <= 0) fail('wavelength_um must be a positive number');
  if (!isObject(s.background) || !isNumber(s.background.n)) fail('background.n must be a number');
  if (s.detectors === undefined) s.detectors = [];
  if (s.elements === undefined) s.elements = [];
  for (const key of ['sources', 'elements', 'detectors']) {
    if (!Array.isArray(s[key]) || !(s[key] as unknown[]).every(isObject)) fail(`${key} must be a list of objects`);
  }
  const d = s.domain;
  if (!isObject(d) || ![d.x_min_um, d.x_max_um, d.y_min_um, d.y_max_um].every(isNumber)) {
    fail('domain needs x_min_um, x_max_um, y_min_um and y_max_um');
  }
  const dom = d as unknown as Domain;
  if (!(dom.x_max_um > dom.x_min_um && dom.y_max_um > dom.y_min_um)) fail('the domain is empty');
  if (!isObject(s.solver) || !['fdtd', 'mom', 'fem'].includes(String(s.solver.method))) {
    fail('solver.method must be fdtd, mom or fem');
  }
  const solver = s.solver as Json;
  if (isNumber(solver.memory_limit_mb) && solver.memory_limit_mb > MAX_MEMORY_MB) solver.memory_limit_mb = MAX_MEMORY_MB;
  return s as Scene;
}

/** Something on the field that can be selected, inspected and moved. */
export interface Item {
  kind: 'element' | 'source' | 'detector';
  index: number;
  id: string;
}

export function listOf(scene: Scene, kind: Item['kind']): Json[] {
  return kind === 'element' ? scene.elements : kind === 'source' ? scene.sources : scene.detectors;
}

export function objectOf(scene: Scene, item: Item): Json | undefined {
  const list = listOf(scene, item.kind);
  if (item.id) {
    const byId = list.find((o) => o.id === item.id);
    if (byId) return byId;
  }
  return list[item.index];
}

export function indexOf(scene: Scene, item: Item): number {
  const list = listOf(scene, item.kind);
  if (item.id) {
    const i = list.findIndex((o) => o.id === item.id);
    if (i >= 0) return i;
  }
  return item.index >= 0 && item.index < list.length ? item.index : -1;
}

export function makeItem(kind: Item['kind'], list: Json[], index: number): Item {
  return {kind, index, id: String(list[index]?.id ?? '')};
}

export const sameItem = (a: Item | null, b: Item | null) =>
  !!a && !!b && a.kind === b.kind && (a.id && b.id ? a.id === b.id : a.index === b.index);

export function positionKeys(item: Item, o: Json): [string, string] | null {
  if (item.kind === 'element') return typeof o.x_um === 'number' ? ['x_um', 'y_um'] : null;
  if (item.kind === 'source') {
    if (typeof o.waist_x_um === 'number') return ['waist_x_um', 'waist_y_um'];
    if (typeof o.x_um === 'number') return ['x_um', 'y_um'];
    return null;
  }
  const shape = o.shape as Json | undefined;
  if (shape?.kind === 'box') return ['x_um', 'y_um'];
  return null;
}

/** Rough half-size of an element or source in µm, fallback when outlines aren't loaded yet. */
export function reachOf(scene: Scene, item: Item): number {
  const o = objectOf(scene, item);
  if (!o) return 0.5;
  if (item.kind === 'source') return Math.max(0.6, Number(o.waist_um ?? 0.6));
  const s = (o.shape ?? {}) as Record<string, number>;
  const kind = (o.shape as Json | undefined)?.kind;
  const r =
    s.radius_um && kind === 'cylinder' ? s.radius_um
    : s.aperture_um ? s.aperture_um / 2
    : s.screen_height_um ? s.screen_height_um / 2
    : s.base_um ? s.base_um / 2
    : s.length_um ? s.length_um / 2
    : s.period_um && s.count ? (s.period_um * s.count) / 2
    : s.thickness_um && s.height_um ? Math.max(s.thickness_um, s.height_um) / 2
    : s.width_um && s.height_um ? Math.max(s.width_um, s.height_um) / 2
    : 1;
  return Math.max(r, 0.4);
}

/** Half-width and half-height of an item's footprint in µm (unrotated fallback). */
export function extentOf(scene: Scene, item: Item): {hx: number; hy: number} {
  const o = objectOf(scene, item);
  if (!o) return {hx: 0.5, hy: 0.5};
  if (item.kind === 'source') {
    const w = Number(o.waist_um ?? 0.5);
    return {hx: 0.5, hy: Math.max(w, 0.5)};
  }
  const s = (o.shape ?? {}) as Record<string, number>;
  const kind = (o.shape as Json | undefined)?.kind;
  let e = {hx: 1, hy: 1};
  if (kind === 'cylinder') e = {hx: s.radius_um, hy: s.radius_um};
  else if (kind === 'lens') e = {hx: s.center_thickness_um / 2 + 0.3, hy: s.aperture_um / 2};
  else if (kind === 'slab') e = {hx: s.thickness_um / 2, hy: s.height_um / 2};
  else if (kind === 'wedge') e = {hx: Math.max(s.thick_um, s.thin_um) / 2, hy: s.height_um / 2};
  else if (kind === 'slits') e = {hx: s.thickness_um / 2, hy: s.screen_height_um / 2};
  else if (kind === 'prism') e = {hx: s.base_um / 2, hy: s.base_um / 2};
  else if (kind === 'mirror') e = {hx: s.thickness_um + (s.aperture_um ** 2) / (8 * Math.abs(s.radius_um || 1e9)), hy: s.aperture_um / 2};
  else if (kind === 'waveguide') e = {hx: s.length_um / 2, hy: s.width_um / 2};
  else if (kind === 'grating') e = {hx: (s.depth_um + (s.substrate_um || 0)) / 2, hy: (s.period_um * s.count) / 2};
  else if (s.width_um && s.height_um) e = {hx: s.width_um / 2, hy: s.height_um / 2};
  else if (s.radius_um) e = {hx: s.radius_um, hy: s.radius_um};
  return {hx: Math.max(e.hx || 0.3, 0.3), hy: Math.max(e.hy || 0.3, 0.3)};
}

export function titleOf(scene: Scene, item: Item): string {
  const o = objectOf(scene, item);
  if (!o) return 'Item';
  if (typeof o.name === 'string' && o.name.trim()) return o.name;
  if (item.kind === 'source') return SOURCE_TYPES[String(o.type)] ?? 'Source';
  if (item.kind === 'detector') {
    const k = String((o.shape as Json | undefined)?.kind ?? 'line');
    return k === 'box' ? 'Box detector' : 'Line detector';
  }
  return SHAPE_TITLES[String((o.shape as Json | undefined)?.kind ?? '')] ?? humanize(String((o.shape as Json | undefined)?.kind ?? 'element'));
}

export const SOURCE_TYPES: Record<string, string> = {
  gaussian_beam: 'Gaussian beam',
  plane_wave: 'Plane wave',
  line_source: 'Point emitter',
};

export const SHAPE_TITLES: Record<string, string> = {
  lens: 'Lens',
  slab: 'Slab',
  wedge: 'Wedge',
  prism: 'Prism',
  cylinder: 'Cylinder',
  waveguide: 'Waveguide',
  grating: 'Grating',
  mirror: 'Mirror',
  slits: 'Slits',
  polygon: 'Polygon',
};

export const REFRACTIVE_SHAPES = ['lens', 'slab', 'wedge', 'prism', 'cylinder', 'waveguide', 'grating'] as const;
export const OPAQUE_SHAPES = ['mirror', 'slits'] as const;
export const PEC_ONLY_SHAPES = new Set<string>(['mirror', 'slits']);

/** A label for a scene key: "center_thickness_um" → "Center thickness" with unit "µm". */
export function labelOf(key: string): {label: string; unit: string} {
  let unit = '';
  let k = key;
  if (k.endsWith('_um')) { unit = 'µm'; k = k.slice(0, -3); }
  else if (k.endsWith('_deg')) { unit = '°'; k = k.slice(0, -4); }
  else if (k.endsWith('_wl')) { unit = 'λ'; k = k.slice(0, -3); }
  const special: Record<string, string> = {
    x: 'X', y: 'Y', x1: 'Start X', y1: 'Start Y', x2: 'End X', y2: 'End Y',
    waist_x: 'Waist X', waist_y: 'Waist Y', r1: 'Front radius', r2: 'Back radius',
    n: 'Refractive index n', k: 'Absorption k', apex: 'Apex angle',
  };
  return {label: special[k] ?? humanize(k), unit};
}

export function humanize(s: string) {
  const t = s.replace(/_/g, ' ');
  return t.charAt(0).toUpperCase() + t.slice(1);
}

/** Numeric fields of an object, in their order in the scene. */
export function numericKeys(o: Json, skip: string[] = []): string[] {
  return Object.keys(o).filter((k) => typeof o[k] === 'number' && !skip.includes(k));
}

/** Unique id with prefix (`slab-1`, `slab-2`, …) not used anywhere in the scene. */
export function uniqueId(scene: Scene, prefix: string): string {
  const used = new Set<string>();
  for (const list of [scene.elements, scene.sources, scene.detectors]) {
    for (const o of list) if (typeof o.id === 'string') used.add(o.id);
  }
  for (let n = 1; ; n++) {
    const id = `${prefix}-${n}`;
    if (!used.has(id)) return id;
  }
}

/** Scale all linear dimensions of a shape by `factor` (angles and counts kept). */
export function scaleShape(shape: Json, factor: number): Json {
  const s = structuredClone(shape);
  const f = (k: string) => {
    if (typeof s[k] === 'number') s[k] = round((s[k] as number) * factor, 3);
  };
  switch (s.kind) {
    case 'lens':
      f('r1_um'); f('r2_um'); f('center_thickness_um'); f('aperture_um');
      break;
    case 'slab':
      f('thickness_um'); f('height_um');
      break;
    case 'wedge':
      f('thick_um'); f('thin_um'); f('height_um');
      break;
    case 'prism':
      f('base_um');
      break;
    case 'mirror':
      f('aperture_um'); f('thickness_um'); f('radius_um');
      break;
    case 'slits':
      f('slit_width_um'); f('pitch_um'); f('screen_height_um'); f('thickness_um');
      break;
    case 'grating':
      f('period_um'); f('depth_um'); f('substrate_um');
      break;
    case 'cylinder':
      f('radius_um');
      break;
    case 'waveguide':
      f('width_um'); f('length_um');
      break;
    case 'polygon':
      if (Array.isArray(s.vertices_um)) {
        s.vertices_um = (s.vertices_um as [number, number][]).map(([x, y]) => [round(x * factor, 3), round(y * factor, 3)]);
      }
      break;
  }
  return s;
}

/** Creates a default element of `kind` centred on `(cx, cy)`, sized to fit a
 * domain or puzzle region. Matches `ShapeKind.makeElement` in Swift. */
export function makeElement(
  kind: string,
  scene: Scene,
  opts?: {x?: number; y?: number; material?: Json; box?: [number, number, number, number]},
): Json {
  const d = scene.domain;
  const [x0, x1, y0, y1] = opts?.box ?? [d.x_min_um, d.x_max_um, d.y_min_um, d.y_max_um];
  const cx = opts?.x ?? round((x0 + x1) / 2, 2);
  const cy = opts?.y ?? round((y0 + y1) / 2, 2);
  const span = Math.min(x1 - x0, y1 - y0);

  let shape: Json;
  let material: Json = {type: 'dielectric', n: 1.5, k: 0};
  switch (kind) {
    case 'lens':
      shape = {kind: 'lens', r1_um: 12, r2_um: -12, center_thickness_um: 3, aperture_um: 10};
      break;
    case 'slab':
      shape = {kind: 'slab', thickness_um: 1.5, height_um: 8};
      break;
    case 'wedge':
      shape = {kind: 'wedge', thick_um: 3, thin_um: 1, height_um: 10};
      break;
    case 'prism':
      shape = {kind: 'prism', base_um: 8, apex_deg: 60};
      material = {type: 'dielectric', n: 1.5168, k: 0};
      break;
    case 'mirror':
      shape = {kind: 'mirror', aperture_um: 10, thickness_um: 0.5, radius_um: null};
      material = {type: 'pec'};
      break;
    case 'slits':
      shape = {kind: 'slits', count: 2, slit_width_um: 1, pitch_um: 4, screen_height_um: 14, thickness_um: 0.5};
      material = {type: 'pec'};
      break;
    case 'grating':
      shape = {kind: 'grating', period_um: 2, fill_factor: 0.5, depth_um: 1, count: 5, substrate_um: 0};
      break;
    case 'cylinder':
      shape = {kind: 'cylinder', radius_um: 1.5};
      material = {type: 'dielectric', n: 1.6, k: 0};
      break;
    case 'waveguide':
      shape = {kind: 'waveguide', width_um: 0.8, length_um: 10};
      material = {type: 'dielectric', n: 2.0, k: 0};
      break;
    case 'polygon':
      shape = {kind: 'polygon', vertices_um: [[-2, -2], [2, -2], [0, 2]]};
      break;
    default:
      shape = {kind: 'slab', thickness_um: 1.5, height_um: 6};
  }

  // Scale down when the target box is smaller than the default 18 µm scene.
  const roughSize = Math.max(
    Number(shape.aperture_um ?? 0),
    Number(shape.height_um ?? 0),
    Number(shape.screen_height_um ?? 0),
    Number(shape.base_um ?? 0),
    Number(shape.length_um ?? 0),
    Number(shape.radius_um ?? 0) * 2,
    shape.period_um && shape.count ? Number(shape.period_um) * Number(shape.count) : 0,
  );
  const maxFit = span * 0.55;
  if (roughSize > maxFit && maxFit > 0.2) {
    shape = scaleShape(shape, maxFit / roughSize);
  }

  // Nudge slightly if another element sits at the exact same anchor.
  const lambdaB = scene.wavelength_um / Math.max(0.1, scene.background.n);
  let y = cy;
  const stacked = scene.elements.filter((e) => Math.abs(Number(e.x_um) - cx) < 1e-6 && Math.abs(Number(e.y_um) - cy) < 1e-6).length;
  if (stacked > 0) y = round(Math.max(y0 + 0.2 * (y1 - y0), cy - stacked * lambdaB), 2);

  return {
    id: uniqueId(scene, kind),
    name: SHAPE_TITLES[kind] ?? humanize(kind),
    enabled: true,
    material: opts?.material ? structuredClone(opts.material) : material,
    x_um: cx,
    y_um: y,
    rotation_deg: 0,
    shape,
  };
}

/** Creates a new source with sensible defaults for the current domain. */
export function makeSource(type: 'gaussian_beam' | 'plane_wave' | 'line_source', scene: Scene): Json {
  const d = scene.domain;
  const w = d.x_max_um - d.x_min_um;
  const h = d.y_max_um - d.y_min_um;
  const cx = (d.x_min_um + d.x_max_um) / 2;
  const cy = (d.y_min_um + d.y_max_um) / 2;
  const prefix = type === 'gaussian_beam' ? 'beam' : type === 'plane_wave' ? 'wave' : 'emitter';
  const id = uniqueId(scene, prefix);
  if (type === 'plane_wave') {
    return {id, name: 'Plane wave', enabled: true, type, angle_deg: 0, amplitude: 1, phase_deg: 0};
  }
  if (type === 'line_source') {
    return {id, name: 'Emitter', enabled: true, type, x_um: round(cx - 0.25 * w, 2), y_um: round(cy, 2), amplitude: 1, phase_deg: 0};
  }
  const waist = round(Math.max(0.5, Math.min(3, h * 0.16)), 2);
  return {
    id,
    name: 'Gaussian beam',
    enabled: true,
    type,
    waist_um: waist,
    waist_x_um: round(cx - 0.25 * w, 2),
    waist_y_um: round(cy, 2),
    angle_deg: 0,
    amplitude: 1,
    phase_deg: 0,
  };
}

/** Creates a new line or box detector inside the current domain. */
export function makeDetector(kind: 'line' | 'box', scene: Scene): Json {
  const d = scene.domain;
  const w = d.x_max_um - d.x_min_um;
  const h = d.y_max_um - d.y_min_um;
  const cx = (d.x_min_um + d.x_max_um) / 2;
  const cy = (d.y_min_um + d.y_max_um) / 2;
  const id = uniqueId(scene, kind === 'line' ? 'detector' : 'box');
  if (kind === 'box') {
    const side = round(Math.max(0.3, Math.min(2, Math.min(w, h) * 0.14)), 2);
    return {
      id,
      name: 'Box',
      enabled: true,
      shape: {kind: 'box', x_um: round(cx + 0.25 * w, 2), y_um: round(cy, 2), width_um: side, height_um: side},
    };
  }
  // Bottom to top so the normal (start → end turned −90°) points along +x.
  const half = round(Math.max(0.5, Math.min(4, h * 0.25)), 2);
  const x = round(cx + 0.3 * w, 2);
  return {
    id,
    name: 'Detector',
    enabled: true,
    shape: {kind: 'line', x1_um: x, y1_um: round(cy - half, 2), x2_um: x, y2_um: round(cy + half, 2)},
  };
}

/** Swaps a line detector's endpoints, reversing its positive flux normal. */
export function flipLineDetector(det: Json) {
  const s = det.shape as Json | undefined;
  if (s?.kind !== 'line') return;
  const {x1_um, y1_um, x2_um, y2_um} = s;
  s.x1_um = x2_um;
  s.y1_um = y2_um;
  s.x2_um = x1_um;
  s.y2_um = y1_um;
}

/** Converts a detector between line and box around the same centre. */
export function convertDetectorKind(det: Json, kind: 'line' | 'box', lambdaB: number) {
  const s = det.shape as Json | undefined;
  if (!s || s.kind === kind) return;
  if (s.kind === 'line' && kind === 'box') {
    const x1 = Number(s.x1_um), y1 = Number(s.y1_um), x2 = Number(s.x2_um), y2 = Number(s.y2_um);
    const len = Math.hypot(x2 - x1, y2 - y1);
    det.shape = {
      kind: 'box',
      x_um: round((x1 + x2) / 2, 2),
      y_um: round((y1 + y2) / 2, 2),
      width_um: round(Math.max(len, lambdaB / 2), 2),
      height_um: round(Math.max(lambdaB / 2, 0.3), 2),
    };
  } else if (s.kind === 'box' && kind === 'line') {
    const cx = Number(s.x_um), cy = Number(s.y_um), h = Math.max(Number(s.height_um), lambdaB / 2);
    det.shape = {
      kind: 'line',
      x1_um: round(cx, 2),
      y1_um: round(cy - h / 2, 2),
      x2_um: round(cx, 2),
      y2_um: round(cy + h / 2, 2),
    };
  }
}

export function detectorCenter(det: Json): {x: number; y: number} {
  const s = det.shape as Json;
  if (s.kind === 'line') {
    return {x: (Number(s.x1_um) + Number(s.x2_um)) / 2, y: (Number(s.y1_um) + Number(s.y2_um)) / 2};
  }
  return {x: Number(s.x_um), y: Number(s.y_um)};
}

export function detectorNormal(det: Json): [number, number] | null {
  const s = det.shape as Json;
  if (s.kind !== 'line') return null;
  const dx = Number(s.x2_um) - Number(s.x1_um);
  const dy = Number(s.y2_um) - Number(s.y1_um);
  const len = Math.hypot(dx, dy);
  if (len <= 1e-9) return null;
  return [dy / len, -dx / len];
}

/** Moves a detector by (dx, dy) in µm, clamped inside domain `d`. */
export function shiftDetector(det: Json, dx: number, dy: number, d: Domain) {
  const s = det.shape as Json;
  if (s.kind === 'line') {
    const x1 = Number(s.x1_um), y1 = Number(s.y1_um), x2 = Number(s.x2_um), y2 = Number(s.y2_um);
    const minX = Math.min(x1, x2), maxX = Math.max(x1, x2);
    const minY = Math.min(y1, y2), maxY = Math.max(y1, y2);
    const cx = Math.max(d.x_min_um - minX, Math.min(d.x_max_um - maxX, dx));
    const cy = Math.max(d.y_min_um - minY, Math.min(d.y_max_um - maxY, dy));
    s.x1_um = round(x1 + cx, 2);
    s.y1_um = round(y1 + cy, 2);
    s.x2_um = round(x2 + cx, 2);
    s.y2_um = round(y2 + cy, 2);
  } else if (s.kind === 'box') {
    const hw = Number(s.width_um) / 2, hh = Number(s.height_um) / 2;
    s.x_um = round(Math.max(d.x_min_um + hw, Math.min(d.x_max_um - hw, Number(s.x_um) + dx)), 2);
    s.y_um = round(Math.max(d.y_min_um + hh, Math.min(d.y_max_um - hh, Number(s.y_um) + dy)), 2);
  }
}

/** Scene signature without detectors, so editing detectors doesn't re-solve. */
export function physicsSignature(scene: Scene): string {
  const {detectors: _detectors, ...rest} = scene;
  return JSON.stringify(rest);
}

/** True when two materials are identical as far as the solver is concerned. */
export function sameMaterial(a: Json | undefined, b: Json | undefined): boolean {
  if (!a || !b || a.type !== b.type) return false;
  if (a.type === 'pec') return true;
  if (a.type === 'dielectric') {
    return Math.abs(Number(a.n) - Number(b.n)) <= 1e-9 && Math.abs(Number(a.k ?? 0) - Number(b.k ?? 0)) <= 1e-9;
  }
  if (a.type === 'dispersive') {
    if (Math.abs(Number(a.eps_inf) - Number(b.eps_inf)) > 1e-9) return false;
    const pa = (a.poles as Json[] | undefined) ?? [];
    const pb = (b.poles as Json[] | undefined) ?? [];
    return pa.length === pb.length && JSON.stringify(pa) === JSON.stringify(pb);
  }
  return JSON.stringify(a) === JSON.stringify(b);
}

export function materialKey(m: Json | undefined, presets: MaterialPreset[]): string {
  if (!m) return 'dielectric';
  if (m.type === 'pec') return 'pec';
  if (m.type === 'dielectric') return 'dielectric';
  if (m.type === 'dispersive') {
    if (typeof m.preset === 'string' && presets.some((p) => p.id === m.preset)) return `preset:${m.preset}`;
    const match = presets.find((p) => sameMaterial(m, p.material));
    if (match) return `preset:${match.id}`;
    return 'dispersive-custom';
  }
  return 'dielectric';
}

// ---- Detector reading formatting (mirrors AppState+Readings.swift)

export function readingTotal(r: DetectorReading): number {
  return r.kind === 'line' ? r.flux.total : r.total.mean;
}

export function readingIncident(r: DetectorReading): number {
  return r.kind === 'line' ? r.flux.incident : r.incident.mean;
}

export function meaningfulRatio(r: DetectorReading, all: DetectorReading[], incidentPeak: number): number | null {
  const inc = readingIncident(r);
  const tot = readingTotal(r);
  if (!Number.isFinite(inc) || !Number.isFinite(tot) || inc === 0) return null;
  const largest = all.reduce((m, x) => (x.kind === r.kind ? Math.max(m, Math.abs(readingIncident(x))) : m), 0);
  const a2 = Math.max(1e-300, incidentPeak * incidentPeak);
  if (Math.abs(inc) <= 1e-6 * largest || Math.abs(inc) <= 1e-12 * a2) return null;
  return tot / inc;
}

export function formatSig(v: number): string {
  if (!Number.isFinite(v)) return '—';
  if (Math.abs(v) < 5e-7) return '0';
  const decimals = Math.min(6, Math.max(0, 2 - Math.floor(Math.log10(Math.abs(v)))));
  const s = v.toFixed(decimals).replace(/\.?0+$/, '');
  return s === '-0' ? '0' : s;
}

export function formatFixed(v: number, digits = 2): string {
  if (!Number.isFinite(v)) return '—';
  const s = v.toFixed(digits);
  return /^-[0.]+$/.test(s) ? s.slice(1) : s;
}

export function formatReadingBadge(r: DetectorReading, all: DetectorReading[], incidentPeak: number): string {
  const ratio = meaningfulRatio(r, all, incidentPeak);
  const a2 = Math.max(1e-300, incidentPeak * incidentPeak);
  if (r.kind === 'line') {
    if (ratio !== null) return `${formatFixed(ratio, 2)}×`;
    return `${formatFixed(r.flux.total / a2, 2)} A²·µm`;
  }
  if (ratio !== null) return `${formatFixed(ratio, 2)}×`;
  return `${formatFixed(r.total.mean / a2, 2)} A²`;
}

/**
 * The domain grown on its short side, about its centre, to the shape (width ÷
 * height) of the space it is shown in, so the field fills that space instead
 * of leaving bars. It never shrinks, and grows each side at most `maxGrow`
 * times, so a tall window can't make a solve much more expensive.
 */
export function fitDomain(d: Domain, aspect: number, maxGrow = 2): Domain {
  const w = d.x_max_um - d.x_min_um;
  const h = d.y_max_um - d.y_min_um;
  const cx = (d.x_min_um + d.x_max_um) / 2;
  const cy = (d.y_min_um + d.y_max_um) / 2;
  if (w / h < aspect) {
    const nw = Math.min(h * aspect, w * maxGrow);
    return {...d, x_min_um: round(cx - nw / 2), x_max_um: round(cx + nw / 2)};
  }
  const nh = Math.min(w / aspect, h * maxGrow);
  return {...d, y_min_um: round(cy - nh / 2), y_max_um: round(cy + nh / 2)};
}

export const round = (v: number, digits = 3) => Number(v.toFixed(digits));
