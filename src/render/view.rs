//! Display parameters and rendering a field to RGBA.

use std::f64::consts::PI;

use rayon::prelude::*;
use serde::{Deserialize, Serialize};

use crate::solver::field::catmull_rom;
use crate::solver::{FieldGrid, Part};
use crate::types::{Vec2, C64};

use super::colormap::Colormap;
use super::RenderError;

pub const MAX_DIMENSION: u32 = 16384;
/// Colormap entries used for rendering.
pub const LUT_SIZE: usize = 1024;

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq, Default)]
#[serde(rename_all = "snake_case")]
pub enum Quantity {
    #[default]
    Intensity,
    Magnitude,
    Real,
    Phase,
}

impl Quantity {
    pub fn default_colormap(self) -> Colormap {
        match self {
            Quantity::Intensity | Quantity::Magnitude => Colormap::Inferno,
            Quantity::Real => Colormap::RdBu,
            Quantity::Phase => Colormap::Twilight,
        }
    }

    pub fn parse(s: &str) -> Option<Quantity> {
        match s {
            "intensity" => Some(Quantity::Intensity),
            "magnitude" => Some(Quantity::Magnitude),
            "real" => Some(Quantity::Real),
            "phase" => Some(Quantity::Phase),
            _ => None,
        }
    }
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq, Default)]
#[serde(rename_all = "snake_case")]
pub enum PartName {
    #[default]
    Total,
    Scattered,
    Incident,
}

impl From<PartName> for Part {
    fn from(p: PartName) -> Part {
        match p {
            PartName::Total => Part::Total,
            PartName::Scattered => Part::Scattered,
            PartName::Incident => Part::Incident,
        }
    }
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq, Default)]
#[serde(rename_all = "snake_case")]
pub enum NormMode {
    /// The 99.5th percentile of |E| of the displayed part.
    #[default]
    Auto,
    /// The source amplitude.
    Incident,
    /// `value`.
    Fixed,
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq)]
#[serde(default, deny_unknown_fields)]
pub struct Normalization {
    pub mode: NormMode,
    pub value: f64,
}

impl Default for Normalization {
    fn default() -> Self {
        Self { mode: NormMode::Auto, value: 1.0 }
    }
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ViewRect {
    pub x_min_um: f64,
    pub x_max_um: f64,
    pub y_min_um: f64,
    pub y_max_um: f64,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(default, deny_unknown_fields)]
pub struct View {
    pub quantity: Quantity,
    pub part: PartName,
    /// φ in Re(E e^{jφ}) and arg(E e^{jφ}).
    pub phase_deg: f64,
    pub colormap: String,
    pub gamma: f64,
    pub normalization: Normalization,
    /// Intensity and magnitude only: dB range below the scale maximum.
    pub log_db: Option<f64>,
    /// Phase only: brightness ∝ min(1, |E|/scale)^0.5.
    pub phase_weighted: bool,
    /// `None`: the field grid's extent.
    pub view_um: Option<ViewRect>,
    pub outside_rgba: [u8; 4],
    /// `None`: PEC cells are drawn like any other.
    pub pec_rgba: Option<[u8; 4]>,
    /// Anti-aliased body outlines (white, 60 % alpha, 1.5 px); for the CLI.
    pub outlines: bool,
}

impl Default for View {
    fn default() -> Self {
        Self {
            quantity: Quantity::Intensity,
            part: PartName::Total,
            phase_deg: 0.0,
            colormap: "inferno".into(),
            gamma: 1.0,
            normalization: Normalization::default(),
            log_db: None,
            phase_weighted: false,
            view_um: None,
            outside_rgba: [0, 0, 0, 0],
            pec_rgba: Some([128, 128, 128, 255]),
            outlines: false,
        }
    }
}

impl View {
    pub fn parse(json: &str) -> Result<View, RenderError> {
        if json.trim().is_empty() {
            return Ok(View::default());
        }
        serde_json::from_str(json).map_err(|e| RenderError::View(e.to_string()))
    }
}

/// `e^{jφ}` for φ in degrees, with φ reduced modulo 360 first so that φ and
/// φ + 360 give identical bits, and multiples of 90° exact.
pub fn phase_factor(phase_deg: f64) -> C64 {
    let d = phase_deg.rem_euclid(360.0);
    let q = (d / 90.0).floor();
    let r = (d - 90.0 * q).to_radians();
    let (s, c) = r.sin_cos();
    match q as i32 {
        0 => C64::new(c, s),
        1 => C64::new(-s, c),
        2 => C64::new(-c, -s),
        _ => C64::new(s, -c),
    }
}

/// The scale S that maps the displayed quantity to [0, 1]. It does not
/// depend on φ, so an animated phase never flickers.
pub fn scale(field: &FieldGrid, view: &View) -> f64 {
    let part: Part = view.part.into();
    let s = match view.normalization.mode {
        NormMode::Auto => field.norms().p995[part as usize],
        NormMode::Incident => field.incident_peak(),
        NormMode::Fixed => view.normalization.value,
    };
    if s.is_finite() && s > 0.0 {
        s
    } else {
        1.0
    }
}

/// Renders `view` of `field` as sRGB RGBA8 into `out` (row 0 = top, max y).
pub fn render_rgba(field: &FieldGrid, view: &View, width: u32, height: u32, out: &mut [u8]) -> Result<(), RenderError> {
    if width == 0 || height == 0 || width > MAX_DIMENSION || height > MAX_DIMENSION {
        return Err(RenderError::InvalidDimensions { width, height });
    }
    let need = width as usize * height as usize * 4;
    if out.len() < need {
        return Err(RenderError::BufferTooSmall { need, got: out.len() });
    }
    let colormap: Colormap = view.colormap.parse().map_err(RenderError::View)?;
    let gamma = if view.gamma.is_finite() && view.gamma > 0.0 { view.gamma } else { 1.0 };
    let lambda_nm = field.scene.wavelength_um * 1000.0;
    let lut = colormap.lut(lambda_nm, LUT_SIZE);
    let g = field.grid;
    let rect = match view.view_um {
        Some(r) => r,
        None => {
            let r = g.rect();
            ViewRect { x_min_um: r.x_min, x_max_um: r.x_max, y_min_um: r.y_min, y_max_um: r.y_max }
        }
    };
    let s = scale(field, view);
    let rot = phase_factor(view.phase_deg);
    let part: Part = view.part.into();
    let scattered: Vec<C64>;
    let values: &[C64] = match part {
        Part::Total => &field.total,
        Part::Incident => &field.incident,
        Part::Scattered => {
            scattered = field.total.par_iter().zip(&field.incident).map(|(t, i)| t - i).collect();
            &scattered
        }
    };
    let pec_rgba = view.pec_rgba;
    let any_pec = pec_rgba.is_some() && field.bodies.iter().any(|b| b.pec);
    let (w, h) = (width as usize, height as usize);
    let py = (rect.y_max_um - rect.y_min_um) / h as f64;
    let last_y = (g.ny - 1) as f64;

    // Per-column stencils: first index and Catmull–Rom weights, or None outside.
    let columns = column_stencils(&g, &rect, w);

    let lut_at = |t: f64| lut[((t * LUT_SIZE as f64) as usize).min(LUT_SIZE - 1)];
    let frame = Frame { field, g, rect, py, last_y, columns: &columns, values, any_pec, pec_rgba, outside: view.outside_rgba };
    let out = &mut out[..need];

    // The gamma and log decisions are made here, once, and each combination gets its own
    // monomorphised pixel loop: with them inside the per-pixel closure LLVM evaluated
    // `powf` speculatively for every pixel even at gamma 1. The arithmetic per pixel is
    // the same as before, so the output is bit-identical.
    let transfer = Transfer::of(view, gamma);
    let lin = |v: f64| v.clamp(0.0, 1.0).clamp(0.0, 1.0);
    let gam = |v: f64| v.clamp(0.0, 1.0).powf(gamma).clamp(0.0, 1.0);
    let (factor, db) = match transfer {
        Transfer::Log { factor, db } => (factor, db),
        _ => (1.0, 1.0),
    };
    let logt = |v: f64| (if v > 0.0 { 1.0 + factor * v.log10() / db } else { 0.0 }).clamp(0.0, 1.0);
    let ss = s * s;
    match (view.quantity, transfer) {
        (Quantity::Intensity, Transfer::Linear) => frame.shade(out, w, |e| lut_at(lin(e.norm_sqr() / ss))),
        (Quantity::Intensity, Transfer::Gamma) => frame.shade(out, w, |e| lut_at(gam(e.norm_sqr() / ss))),
        (Quantity::Intensity, Transfer::Log { .. }) => frame.shade(out, w, |e| lut_at(logt(e.norm_sqr() / ss))),
        (Quantity::Magnitude, Transfer::Linear) => frame.shade(out, w, |e| lut_at(lin(e.norm() / s))),
        (Quantity::Magnitude, Transfer::Gamma) => frame.shade(out, w, |e| lut_at(gam(e.norm() / s))),
        (Quantity::Magnitude, Transfer::Log { .. }) => frame.shade(out, w, |e| lut_at(logt(e.norm() / s))),
        (Quantity::Real, _) if gamma == 1.0 => frame.shade(out, w, |e| {
            let v = (e * rot).re / s;
            let m = v.abs().min(1.0);
            lut_at(0.5 + 0.5 * m.copysign(v))
        }),
        (Quantity::Real, _) => frame.shade(out, w, |e| {
            let v = (e * rot).re / s;
            let m = v.abs().min(1.0);
            lut_at(0.5 + 0.5 * m.powf(gamma).copysign(v))
        }),
        (Quantity::Phase, _) if view.phase_weighted => frame.shade(out, w, |e| {
            let z = e * rot;
            let mut c = lut_at((z.arg() + PI) / (2.0 * PI));
            let b = (z.norm() / s).min(1.0).sqrt();
            for ch in c.iter_mut().take(3) {
                *ch = (*ch as f64 * b).round() as u8;
            }
            c
        }),
        (Quantity::Phase, _) => frame.shade(out, w, |e| lut_at(((e * rot).arg() + PI) / (2.0 * PI))),
    }

    if view.outlines {
        draw_outlines(field, &rect, w, h, &mut out[..need]);
    }
    Ok(())
}

/// How intensity and magnitude map to [0, 1] before the colormap.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Transfer {
    Linear,
    Gamma,
    /// `factor` 10 for intensity, 20 for magnitude; `db` the range.
    Log { factor: f64, db: f64 },
}

impl Transfer {
    pub fn of(view: &View, gamma: f64) -> Transfer {
        if let Some(db) = view.log_db.filter(|d| *d > 0.0) {
            let factor = if view.quantity == Quantity::Intensity { 10.0 } else { 20.0 };
            Transfer::Log { factor, db }
        } else if gamma == 1.0 {
            Transfer::Linear
        } else {
            Transfer::Gamma
        }
    }
}

/// A column's or row's stencil: first index, Catmull–Rom weights and the position.
pub type Stencil = Option<(usize, [f64; 4], f64)>;

/// What every pixel loop of [`render_rgba`] shares.
struct Frame<'a> {
    field: &'a FieldGrid,
    g: crate::solver::GridSpec,
    rect: ViewRect,
    py: f64,
    last_y: f64,
    columns: &'a [Stencil],
    values: &'a [C64],
    any_pec: bool,
    pec_rgba: Option<[u8; 4]>,
    outside: [u8; 4],
}

impl Frame<'_> {
    /// Resamples the field at every pixel and colours it with `shade`.
    #[inline(always)]
    fn shade<F: Fn(C64) -> [u8; 4] + Sync>(&self, out: &mut [u8], w: usize, shade: F) {
        let g = self.g;
        out.par_chunks_mut(w * 4).enumerate().for_each(|(row, line)| {
            let y = self.rect.y_max_um - (row as f64 + 0.5) * self.py;
            let fy = (y - g.y0) / g.dx;
            if !(fy >= -EDGE && fy <= self.last_y + EDGE) {
                for px in line.as_chunks_mut::<4>().0 {
                    px.copy_from_slice(&self.outside);
                }
                return;
            }
            let fy = fy.clamp(0.0, self.last_y);
            let j0 = (fy.floor() as usize).min(g.ny.saturating_sub(2));
            let wy = catmull_rom(fy - j0 as f64);
            let rows: [usize; 4] = std::array::from_fn(|b| (j0 as isize + b as isize - 1).clamp(0, g.ny as isize - 1) as usize);
            let jn = fy.round() as usize;
            for (col, pxl) in self.columns.iter().zip(line.as_chunks_mut::<4>().0) {
                let Some((i0, wx, fx)) = *col else {
                    pxl.copy_from_slice(&self.outside);
                    continue;
                };
                if self.any_pec {
                    let idx = jn * g.nx + fx.round() as usize;
                    if self.field.is_pec(idx) {
                        pxl.copy_from_slice(&self.pec_rgba.unwrap());
                        continue;
                    }
                }
                let mut e = C64::new(0.0, 0.0);
                for (b, &r) in rows.iter().enumerate() {
                    let base = r * g.nx;
                    let mut acc = C64::new(0.0, 0.0);
                    for (a, wa) in wx.iter().enumerate() {
                        let i = (i0 as isize + a as isize - 1).clamp(0, g.nx as isize - 1) as usize;
                        acc += self.values[base + i] * *wa;
                    }
                    e += acc * wy[b];
                }
                pxl.copy_from_slice(&shade(e));
            }
        });
    }
}

/// Edge tolerance of the outside test, in cells.
pub const EDGE: f64 = 1e-9;

/// The column stencils of a `width`-pixel view of `rect` on grid `g`, exactly as
/// [`render_rgba`] computes them (also used by the GPU viewport for parity).
pub fn column_stencils(g: &crate::solver::GridSpec, rect: &ViewRect, width: usize) -> Vec<Stencil> {
    let px = (rect.x_max_um - rect.x_min_um) / width as f64;
    let last_x = (g.nx - 1) as f64;
    (0..width)
        .map(|i| {
            let x = rect.x_min_um + (i as f64 + 0.5) * px;
            let fx = (x - g.x0) / g.dx;
            (fx >= -EDGE && fx <= last_x + EDGE).then(|| {
                let fx = fx.clamp(0.0, last_x);
                let i0 = (fx.floor() as usize).min(g.nx.saturating_sub(2));
                (i0, catmull_rom(fx - i0 as f64), fx)
            })
        })
        .collect()
}

/// The displayed part as interleaved f32 (re, im), row-major with row 0 at y0, computed
/// in f64 (scattered = total − incident) and rounded once.
pub fn part_f32(field: &FieldGrid, part: Part, out: &mut [f32]) -> Result<(), RenderError> {
    let n = field.grid.len();
    if out.len() < 2 * n {
        return Err(RenderError::BufferTooSmall { need: 2 * n, got: out.len() });
    }
    out[..2 * n].par_chunks_mut(2 * 4096).enumerate().for_each(|(k, chunk)| {
        let base = k * 4096;
        for (j, pair) in chunk.as_chunks_mut::<2>().0.iter_mut().enumerate() {
            let v = field.value(part, base + j);
            *pair = [v.re as f32, v.im as f32];
        }
    });
    Ok(())
}

/// The LUT [`render_rgba`] colours with: [`LUT_SIZE`] sRGB RGBA8 entries.
pub fn render_lut(colormap: Colormap, wavelength_um: f64, n: usize) -> Vec<[u8; 4]> {
    colormap.lut(wavelength_um * 1000.0, n)
}

/// Body outlines in white at 60 % alpha, 1.5 px wide, with distance-based
/// anti-aliasing, a small ring at each enabled emitter (line source) and the
/// enabled detectors. Coverage is the maximum over segments, so joints are not blended twice.
fn draw_outlines(field: &FieldGrid, rect: &ViewRect, w: usize, h: usize, out: &mut [u8]) {
    let sx = w as f64 / (rect.x_max_um - rect.x_min_um);
    let sy = h as f64 / (rect.y_max_um - rect.y_min_um);
    let to_px = |p: [f64; 2]| Vec2::new((p[0] - rect.x_min_um) * sx, (rect.y_max_um - p[1]) * sy);
    let mut cover = vec![0f32; w * h];
    const HALF: f64 = 0.75;
    let mut segment = |a: Vec2, b: Vec2| {
        let x0 = (a.x.min(b.x) - 2.0).floor().max(0.0) as usize;
        let x1 = ((a.x.max(b.x) + 2.0).ceil().max(0.0) as usize).min(w);
        let y0 = (a.y.min(b.y) - 2.0).floor().max(0.0) as usize;
        let y1 = ((a.y.max(b.y) + 2.0).ceil().max(0.0) as usize).min(h);
        let d = b - a;
        let l2 = d.norm_sqr();
        for y in y0..y1 {
            for x in x0..x1 {
                let p = Vec2::new(x as f64 + 0.5, y as f64 + 0.5);
                let t = if l2 > 0.0 { ((p - a).dot(d) / l2).clamp(0.0, 1.0) } else { 0.0 };
                let dist = p.dist(a + d * t);
                let c = (HALF + 0.5 - dist).clamp(0.0, 1.0) as f32;
                let slot = &mut cover[y * w + x];
                *slot = slot.max(c);
            }
        }
    };
    for body in &field.bodies {
        let n = body.outline.len();
        for k in 0..n {
            segment(to_px(body.outline[k]), to_px(body.outline[(k + 1) % n]));
        }
    }
    const RING_PX: f64 = 5.0;
    const RING_SIDES: usize = 24;
    for s in field.scene.enabled_sources() {
        if let crate::scene::SourceKind::LineSource { x_um, y_um, .. } = s.kind {
            let c = to_px([x_um, y_um]);
            if !(c.x.is_finite() && c.y.is_finite()) || c.x < -RING_PX || c.y < -RING_PX || c.x > w as f64 + RING_PX || c.y > h as f64 + RING_PX {
                continue;
            }
            let at = |k: usize| c + Vec2::from_angle(2.0 * PI * k as f64 / RING_SIDES as f64) * RING_PX;
            for k in 0..RING_SIDES {
                segment(at(k), at(k + 1));
            }
        }
    }
    // Enabled detectors: a box's rectangle, a line with a short tick from its
    // middle towards the side its flux counts positive.
    const TICK_PX: f64 = 6.0;
    for d in field.scene.detectors.iter().filter(|d| d.enabled) {
        let pts: Vec<Vec2> = crate::detectors::outline(&d.shape).into_iter().map(to_px).collect();
        if pts.iter().any(|p| !(p.x.is_finite() && p.y.is_finite())) {
            continue;
        }
        if let [a, b] = pts[..] {
            segment(a, b);
            let n = crate::detectors::line_normal(a, b);
            // Pixel y grows downwards, which reverses the turn: the scene's
            // normal is the opposite of the one computed in pixels.
            let mid = (a + b) * 0.5;
            segment(mid, mid - n * TICK_PX);
        } else {
            for k in 0..pts.len() {
                segment(pts[k], pts[(k + 1) % pts.len()]);
            }
        }
    }
    for (c, px) in cover.iter().zip(out.as_chunks_mut::<4>().0) {
        if *c <= 0.0 {
            continue;
        }
        let a = 0.6 * *c as f64;
        let dst_a = px[3] as f64 / 255.0;
        let out_a = a + dst_a * (1.0 - a);
        for ch in px.iter_mut().take(3) {
            let v = (255.0 * a + *ch as f64 * dst_a * (1.0 - a)) / out_a.max(1e-12);
            *ch = v.round().clamp(0.0, 255.0) as u8;
        }
        px[3] = (out_a * 255.0).round() as u8;
    }
}
