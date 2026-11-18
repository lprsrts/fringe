//! Solved fields on a regular grid, with sampling and display normalisation.

use std::sync::OnceLock;

use serde::Serialize;
use serde_json::{json, Value};

use crate::detectors::{self, FieldView, Reading};
use crate::geometry::{Body, BodyMaterial};
use crate::scene::{Scene, SourceKind};
use crate::types::{Rect, Vec2, C64};

use super::{Quality, SolverMeta};

/// Node (i, j) sits at (x0 + i·dx, y0 + j·dx); j = 0 is the bottom row. Arrays
/// over the grid are indexed j·nx + i.
#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
pub struct GridSpec {
    pub x0: f64,
    pub y0: f64,
    pub dx: f64,
    pub nx: usize,
    pub ny: usize,
}

impl GridSpec {
    #[inline]
    pub fn point(&self, i: usize, j: usize) -> Vec2 {
        Vec2::new(self.x0 + i as f64 * self.dx, self.y0 + j as f64 * self.dx)
    }

    #[inline]
    pub fn index(&self, i: usize, j: usize) -> usize {
        j * self.nx + i
    }

    pub fn len(&self) -> usize {
        self.nx * self.ny
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Nodes from r's lower-left corner at spacing dx, as many as fit in r.
    pub fn covering(r: Rect, dx: f64) -> GridSpec {
        let nx = (r.width() / dx + 1e-9).floor() as usize + 1;
        let ny = (r.height() / dx + 1e-9).floor() as usize + 1;
        GridSpec { x0: r.x_min, y0: r.y_min, dx, nx, ny }
    }

    /// The rectangle spanned by the nodes.
    pub fn rect(&self) -> Rect {
        Rect::new(
            self.x0,
            self.x0 + (self.nx.max(1) - 1) as f64 * self.dx,
            self.y0,
            self.y0 + (self.ny.max(1) - 1) as f64 * self.dx,
        )
    }
}

#[repr(u32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Part {
    Total = 0,
    Scattered = 1,
    Incident = 2,
}

impl Part {
    pub fn from_u32(v: u32) -> Option<Part> {
        match v {
            0 => Some(Part::Total),
            1 => Some(Part::Scattered),
            2 => Some(Part::Incident),
            _ => None,
        }
    }

    pub fn parse(s: &str) -> Option<Part> {
        match s {
            "total" => Some(Part::Total),
            "scattered" => Some(Part::Scattered),
            "incident" => Some(Part::Incident),
            _ => None,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Part::Total => "total",
            Part::Scattered => "scattered",
            Part::Incident => "incident",
        }
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct BodyInfo {
    pub element_id: String,
    pub name: String,
    pub pec: bool,
    /// Real index n and extinction k (n + ik); 0 for PEC.
    pub n: f64,
    pub k: f64,
    pub outline: Vec<[f64; 2]>,
}

impl BodyInfo {
    pub fn from_body(b: &Body, max_chord: f64) -> BodyInfo {
        let (pec, n, k) = match b.material {
            BodyMaterial::Pec => (true, 0.0, 0.0),
            BodyMaterial::Dielectric { n, .. } => (false, n.re, -n.im),
        };
        BodyInfo {
            element_id: b.element_id.clone(),
            name: b.name.clone(),
            pec,
            n,
            k,
            outline: b
                .contour
                .polyline(max_chord, 2f64.to_radians())
                .into_iter()
                .map(|p| p.to_array())
                .collect(),
        }
    }

    /// ε″ = 2nk for ε = (n − jk)².
    pub fn eps_imag(&self) -> f64 {
        if self.pec {
            0.0
        } else {
            2.0 * self.n * self.k
        }
    }
}

/// Solver diagnostics plus what the pipeline knows about the run.
#[derive(Clone, Debug, Serialize)]
pub struct SolveMeta {
    #[serde(flatten)]
    pub solver: SolverMeta,
    pub method: super::Method,
    pub quality: Quality,
    pub ppw: f64,
    /// "analytic" or "yee_matched".
    pub incident_kind: String,
    pub wall_s: f64,
    /// The solver's memory estimate for this run (an estimate of the peak, not
    /// a measurement).
    pub memory_mb: f64,
}

/// Display scales per part (indexed by `Part as usize`), over the grid with PEC
/// interiors and the discs around emitters left out.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Norms {
    pub p995: [f64; 3],
    pub max: [f64; 3],
}

pub struct FieldGrid {
    pub grid: GridSpec,
    pub total: Vec<C64>,
    pub incident: Vec<C64>,
    /// 0 = background, b + 1 = body b.
    pub region: Vec<u16>,
    pub bodies: Vec<BodyInfo>,
    pub scene: Scene,
    pub quality: Quality,
    pub meta: SolveMeta,
    pub norms: OnceLock<Norms>,
    /// The scene's detector readings, measured on first use.
    pub readings: OnceLock<Vec<Reading>>,
}

impl FieldGrid {
    #[inline]
    pub fn value(&self, part: Part, idx: usize) -> C64 {
        match part {
            Part::Total => self.total[idx],
            Part::Incident => self.incident[idx],
            Part::Scattered => self.total[idx] - self.incident[idx],
        }
    }

    #[inline]
    pub fn is_pec(&self, idx: usize) -> bool {
        let r = self.region[idx] as usize;
        r > 0 && self.bodies.get(r - 1).is_some_and(|b| b.pec)
    }

    /// Catmull–Rom bicubic interpolation of Re and Im (clamped at the grid
    /// edges); `None` outside the grid.
    pub fn sample(&self, part: Part, p: Vec2) -> Option<C64> {
        let g = &self.grid;
        let fx = (p.x - g.x0) / g.dx;
        let fy = (p.y - g.y0) / g.dx;
        let eps = 1e-9;
        if !(fx >= -eps && fy >= -eps && fx <= (g.nx - 1) as f64 + eps && fy <= (g.ny - 1) as f64 + eps) {
            return None;
        }
        Some(bicubic(g, fx, fy, |idx| self.value(part, idx)))
    }

    /// Region index of the node nearest to `p`.
    pub fn region_at(&self, p: Vec2) -> Option<u16> {
        let g = &self.grid;
        let i = ((p.x - g.x0) / g.dx).round();
        let j = ((p.y - g.y0) / g.dx).round();
        if i < 0.0 || j < 0.0 || i >= g.nx as f64 || j >= g.ny as f64 {
            return None;
        }
        Some(self.region[g.index(i as usize, j as usize)])
    }

    pub fn norms(&self) -> &Norms {
        self.norms.get_or_init(|| {
            let mut p995 = [0.0; 3];
            let mut max = [0.0; 3];
            let core = self.emitter_core_mask();
            for part in [Part::Total, Part::Scattered, Part::Incident] {
                let mut mags: Vec<f64> = (0..self.grid.len())
                    .filter(|&i| !self.is_pec(i) && !core.as_ref().is_some_and(|c| c[i]))
                    .map(|i| self.value(part, i).norm())
                    .collect();
                if mags.is_empty() {
                    continue;
                }
                let k = ((mags.len() - 1) as f64 * 0.995).round() as usize;
                let (_, v, _) = mags.select_nth_unstable_by(k, |a, b| a.total_cmp(b));
                p995[part as usize] = *v;
                max[part as usize] = mags.iter().copied().fold(0.0, f64::max);
            }
            Norms { p995, max }
        })
    }

    /// Nodes within a quarter background wavelength of an enabled line
    /// source, where its singular point would dominate any maximum or
    /// percentile; `None` without line sources.
    pub fn emitter_core_mask(&self) -> Option<Vec<bool>> {
        let emitters: Vec<Vec2> = self
            .scene
            .enabled_sources()
            .filter_map(|s| match s.kind {
                SourceKind::LineSource { x_um, y_um, .. } => Some(Vec2::new(x_um, y_um)),
                _ => None,
            })
            .collect();
        if emitters.is_empty() {
            return None;
        }
        let r = 0.25 * self.scene.wavelength_um / self.scene.background.n;
        let g = &self.grid;
        Some((0..g.len()).map(|i| emitters.iter().any(|e| e.dist(g.point(i % g.nx, i / g.nx)) < r)).collect())
    }

    /// The incident field scale: the sum of the enabled sources' amplitudes.
    pub fn incident_peak(&self) -> f64 {
        self.scene.incident_scale()
    }

    /// The field as the detector code sees it.
    pub fn view(&self) -> FieldView<'_> {
        FieldView { grid: &self.grid, total: &self.total, incident: &self.incident, wavelength_um: self.scene.wavelength_um }
    }

    /// Readings of the scene's enabled detectors, measured once per field (a
    /// large box detector takes a noticeable time).
    pub fn detector_readings(&self) -> &[Reading] {
        self.readings.get_or_init(|| detectors::measure_all(&self.view(), &self.scene.detectors))
    }

    /// The weighted sum `Σ wᵢ fieldᵢ` of fields solved on the same grid with the
    /// same bodies, such as the per-source fields of one scene (the solvers are
    /// linear, so this is the field with every source scaled by its weight).
    /// The scene is the first field's, with each source enabled when some field
    /// with a non-zero weight has it enabled. Detector readings are measured
    /// afresh on the sum.
    pub fn combine(fields: &[&FieldGrid], weights: &[C64]) -> Result<FieldGrid, String> {
        let Some(first) = fields.first() else { return Err("no fields to combine".into()) };
        if fields.len() != weights.len() {
            return Err(format!("{} fields but {} weights", fields.len(), weights.len()));
        }
        if let Some(w) = weights.iter().find(|w| !(w.re.is_finite() && w.im.is_finite())) {
            return Err(format!("weight {w} is not finite"));
        }
        for (i, f) in fields.iter().enumerate().skip(1) {
            if f.grid != first.grid || f.region != first.region || f.scene.wavelength_um != first.scene.wavelength_um {
                return Err(format!("field {i} is not on the same grid, with the same bodies, as field 0"));
            }
        }
        let sum = |part: fn(&FieldGrid) -> &[C64]| -> Vec<C64> {
            let mut out = vec![C64::new(0.0, 0.0); first.grid.len()];
            for (f, &w) in fields.iter().zip(weights) {
                if w != C64::new(0.0, 0.0) {
                    out.iter_mut().zip(part(f)).for_each(|(o, v)| *o += w * v);
                }
            }
            out
        };
        let mut scene = first.scene.clone();
        for s in &mut scene.sources {
            s.enabled = fields.iter().zip(weights).any(|(f, w)| {
                *w != C64::new(0.0, 0.0) && f.scene.sources.iter().any(|t| t.id == s.id && t.enabled)
            });
        }
        let mut meta = first.meta.clone();
        meta.wall_s = fields.iter().map(|f| f.meta.wall_s).sum();
        Ok(FieldGrid {
            grid: first.grid,
            total: sum(|f| &f.total),
            incident: sum(|f| &f.incident),
            region: first.region.clone(),
            bodies: first.bodies.clone(),
            scene,
            quality: first.quality,
            meta,
            norms: OnceLock::new(),
            readings: OnceLock::new(),
        })
    }

    pub fn pml_um(&self) -> f64 {
        self.scene.domain.pml_wl * self.scene.wavelength_um / self.scene.background.n
    }

    /// Grid, scene context, diagnostics, body outlines and detector readings.
    pub fn info_json(&self) -> Value {
        let g = &self.grid;
        let d = &self.scene.domain;
        json!({
            "grid": { "x0_um": g.x0, "y0_um": g.y0, "dx_um": g.dx, "nx": g.nx, "ny": g.ny },
            "domain": { "x_min_um": d.x_min_um, "x_max_um": d.x_max_um, "y_min_um": d.y_min_um, "y_max_um": d.y_max_um },
            "pml_um": self.pml_um(),
            "wavelength_um": self.scene.wavelength_um,
            "background_n": self.scene.background.n,
            "incident_peak": self.incident_peak(),
            "total_peak": self.norms().max[Part::Total as usize],
            "quality": self.quality,
            "method": self.meta.method,
            "meta": serde_json::to_value(&self.meta).unwrap_or(Value::Null),
            "bodies": serde_json::to_value(&self.bodies).unwrap_or(Value::Null),
            "detectors": serde_json::to_value(self.detector_readings()).unwrap_or(Value::Null),
        })
    }
}

/// Catmull–Rom weights for the samples at offsets −1, 0, 1, 2 from the cell start.
#[inline]
pub fn catmull_rom(t: f64) -> [f64; 4] {
    let t2 = t * t;
    let t3 = t2 * t;
    [
        0.5 * (-t3 + 2.0 * t2 - t),
        0.5 * (3.0 * t3 - 5.0 * t2 + 2.0),
        0.5 * (-3.0 * t3 + 4.0 * t2 + t),
        0.5 * (t3 - t2),
    ]
}

/// Bicubic interpolation at fractional node coordinates (fx, fy), clamping the
/// stencil at the edges.
#[inline]
pub fn bicubic(g: &GridSpec, fx: f64, fy: f64, value: impl Fn(usize) -> C64) -> C64 {
    let fx = fx.clamp(0.0, (g.nx - 1) as f64);
    let fy = fy.clamp(0.0, (g.ny - 1) as f64);
    let i0 = (fx.floor() as usize).min(g.nx.saturating_sub(2));
    let j0 = (fy.floor() as usize).min(g.ny.saturating_sub(2));
    let wx = catmull_rom(fx - i0 as f64);
    let wy = catmull_rom(fy - j0 as f64);
    let clamp = |v: isize, n: usize| v.clamp(0, n as isize - 1) as usize;
    let mut acc = C64::new(0.0, 0.0);
    for (b, wyb) in wy.iter().enumerate() {
        let j = clamp(j0 as isize + b as isize - 1, g.ny);
        let mut row = C64::new(0.0, 0.0);
        for (a, wxa) in wx.iter().enumerate() {
            let i = clamp(i0 as isize + a as isize - 1, g.nx);
            row += *wxa * value(j * g.nx + i);
        }
        acc += *wyb * row;
    }
    acc
}
