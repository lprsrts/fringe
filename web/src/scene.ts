// The parts of the scene format (the JSON the Mac app and fringe-cli share)
// that the page edits directly. Everything else passes through untouched.

export type Json = Record<string, unknown>;

export interface Domain {
  x_min_um: number;
  x_max_um: number;
  y_min_um: number;
  y_max_um: number;
}

export interface Scene extends Json {
  wavelength_um: number;
  background: {n: number} & Json;
  sources: Json[];
  elements: Json[];
  detectors: Json[];
  domain: Domain & Json;
  solver: {method: string} & Json;
}

/** Something on the field that can be selected and dragged. */
export interface Item {
  kind: 'element' | 'source';
  index: number;
  /** Keys of its position in the scene object. */
  xKey: string;
  yKey: string;
}

export function itemsOf(scene: Scene): Item[] {
  const items: Item[] = [];
  scene.elements.forEach((e, index) => {
    if (typeof e.x_um === 'number') items.push({kind: 'element', index, xKey: 'x_um', yKey: 'y_um'});
  });
  scene.sources.forEach((s, index) => {
    if (typeof s.waist_x_um === 'number') items.push({kind: 'source', index, xKey: 'waist_x_um', yKey: 'waist_y_um'});
    else if (typeof s.x_um === 'number') items.push({kind: 'source', index, xKey: 'x_um', yKey: 'y_um'});
  });
  return items;
}

export const objectOf = (scene: Scene, item: Item) =>
  (item.kind === 'element' ? scene.elements : scene.sources)[item.index];

export const sameItem = (a: Item | null, b: Item | null) =>
  !!a && !!b && a.kind === b.kind && a.index === b.index;

/** Rough half-size of an element in µm, for picking it with the pointer. */
export function reachOf(scene: Scene, item: Item): number {
  const o = objectOf(scene, item);
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
    : s.width_um && s.height_um ? Math.max(s.width_um, s.height_um) / 2
    : 1;
  return Math.max(r, 0.4);
}

/** Half-width and half-height of an element's footprint in µm (unrotated), for its selection mark. */
export function extentOf(scene: Scene, item: Item): {hx: number; hy: number} {
  const o = objectOf(scene, item);
  if (item.kind === 'source') {
    const w = Number(o.waist_um ?? 0.5);
    return {hx: 0.5, hy: Math.max(w, 0.5)};
  }
  const s = (o.shape ?? {}) as Record<string, number>;
  const kind = (o.shape as Json | undefined)?.kind;
  let e = {hx: 1, hy: 1};
  if (kind === 'cylinder') e = {hx: s.radius_um, hy: s.radius_um};
  else if (kind === 'lens') e = {hx: s.center_thickness_um / 2 + 0.3, hy: s.aperture_um / 2};
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
  if (typeof o.name === 'string' && o.name) return o.name;
  if (item.kind === 'source') return SOURCE_TYPES[String(o.type)] ?? 'Source';
  return humanize(String((o.shape as Json | undefined)?.kind ?? 'element'));
}

const SOURCE_TYPES: Record<string, string> = {
  gaussian_beam: 'Gaussian beam',
  plane_wave: 'Plane wave',
  line_source: 'Point emitter',
};

/** A label for a scene key: "center_thickness_um" → "Center thickness" with unit "µm". */
export function labelOf(key: string): {label: string; unit: string} {
  let unit = '';
  let k = key;
  if (k.endsWith('_um')) { unit = 'µm'; k = k.slice(0, -3); }
  else if (k.endsWith('_deg')) { unit = '°'; k = k.slice(0, -4); }
  else if (k.endsWith('_wl')) { unit = 'λ'; k = k.slice(0, -3); }
  const special: Record<string, string> = {
    x: 'X', y: 'Y', waist_x: 'Waist X', waist_y: 'Waist Y', r1: 'Front radius', r2: 'Back radius',
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
