//! Detector readings, measured from a solved field on its grid.
//!
//! A line detector gives the time-averaged power flux through a segment, per
//! unit length in z. With E along z, Faraday's law gives
//! `H = (j / (ω µ0)) (∂y E, −∂x E)`, and with η0 = 1 (so ω µ0 = k0) the
//! Poynting vector `½ Re(E × H*)` is
//!
//! ```text
//! S = −Im(E* ∇E) / (2 k0)
//! ```
//!
//! A plane wave `A e^{−j k0 n_b x}` carries `n_b A² / 2` per µm along +x. The
//! flux counts positive along the normal to the right of p1 → p2, i.e. the
//! direction p1 → p2 turned by −90°. Total, incident and scattered fluxes are
//! reported separately; flux is quadratic in E, so the total is not the sum of
//! the other two.
//!
//! A box detector gives the mean, integral and largest sample of |E|² over its
//! rectangle, for the total and the incident field.
//!
//! Everything works on a [`FieldView`] (a grid and two value slices), so a field
//! combined from several solves can be measured the same way as one solve.
//! Values and gradients come from a local degree-7 Lagrange polynomial through
//! the 8 × 8 nodes around each sample point. A plane wave's flux is then off by
//! at most 0.15 % at 6 nodes per wavelength (the preview output grid) and 1e−5
//! at 12 (final); a cubic interpolant with central differences is off by
//! several per cent at 6.

use serde::Serialize;

use crate::analytic::metrics::simpson;
use crate::scene::{Detector, DetectorShape};
use crate::solver::GridSpec;
use crate::types::{Rect, Vec2, C64};

/// A field on a grid: the total and incident values at every node (indexed
/// `j·nx + i`), and the vacuum wavelength they oscillate at.
#[derive(Clone, Copy)]
pub struct FieldView<'a> {
    pub grid: &'a GridSpec,
    pub total: &'a [C64],
    pub incident: &'a [C64],
    pub wavelength_um: f64,
}

/// Power flux through a line detector, per µm in z (η0 = 1 units).
#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
pub struct Flux {
    pub total: f64,
    pub incident: f64,
    pub scattered: f64,
}

/// |E|² statistics over a box detector.
#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
pub struct Intensity {
    pub mean: f64,
    /// The mean times the box area, in µm².
    pub integral: f64,
    /// The largest sample.
    pub max: f64,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Measurement {
    Line {
        length_um: f64,
        /// Unit normal along which the flux counts positive.
        normal: [f64; 2],
        flux: Flux,
    },
    Box {
        area_um2: f64,
        total: Intensity,
        incident: Intensity,
    },
}

#[derive(Clone, Debug, PartialEq)]
pub struct Reading {
    pub id: String,
    pub name: String,
    pub measurement: Measurement,
}

impl Reading {
    /// `{"id", "name", "kind", …}` with the measurement's keys. A box also
    /// gets `mean_intensity` and `integral`, each `{"total", "incident"}`,
    /// beside its `total` and `incident` statistics, the shape the app reads.
    pub fn to_json(&self) -> serde_json::Value {
        let mut v = serde_json::json!({ "id": self.id, "name": self.name });
        let (Ok(serde_json::Value::Object(m)), serde_json::Value::Object(o)) = (serde_json::to_value(&self.measurement), &mut v)
        else {
            return v;
        };
        o.extend(m);
        if let Measurement::Box { total, incident, .. } = &self.measurement {
            o.insert("mean_intensity".into(), serde_json::json!({ "total": total.mean, "incident": incident.mean }));
            o.insert("integral".into(), serde_json::json!({ "total": total.integral, "incident": incident.integral }));
        }
        v
    }
}

impl Serialize for Reading {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        self.to_json().serialize(s)
    }
}

impl Measurement {
    pub fn flux(&self) -> Option<Flux> {
        match self {
            Measurement::Line { flux, .. } => Some(*flux),
            Measurement::Box { .. } => None,
        }
    }
}

/// The unit normal of a line detector: p1 → p2 turned by −90°.
pub fn line_normal(p1: Vec2, p2: Vec2) -> Vec2 {
    let d = p2 - p1;
    let len = d.dot(d).sqrt();
    if len > 0.0 {
        // + 0.0 turns −0.0 into 0.0, which would otherwise print as "-0.0".
        Vec2::new(d.y / len + 0.0, -d.x / len + 0.0)
    } else {
        Vec2::new(0.0, 0.0)
    }
}

/// The rectangle of a box detector.
pub fn box_rect(x: f64, y: f64, width: f64, height: f64) -> Rect {
    Rect::new(x - 0.5 * width, x + 0.5 * width, y - 0.5 * height, y + 0.5 * height)
}

/// Points of a detector's outline for drawing: the two end points of a line,
/// the four corners (counter-clockwise from the lower left) of a box.
pub fn outline(shape: &DetectorShape) -> Vec<[f64; 2]> {
    match *shape {
        DetectorShape::Line { x1_um, y1_um, x2_um, y2_um } => vec![[x1_um, y1_um], [x2_um, y2_um]],
        DetectorShape::Box { x_um, y_um, width_um, height_um } => {
            let r = box_rect(x_um, y_um, width_um, height_um);
            vec![[r.x_min, r.y_min], [r.x_max, r.y_min], [r.x_max, r.y_max], [r.x_min, r.y_max]]
        }
    }
}

/// Readings of the enabled detectors, in scene order.
pub fn measure_all(view: &FieldView, detectors: &[Detector]) -> Vec<Reading> {
    detectors
        .iter()
        .filter(|d| d.enabled)
        .map(|d| Reading { id: d.id.clone(), name: d.name.clone(), measurement: measure(view, &d.shape) })
        .collect()
}

/// Samples per grid spacing along a line and across a box.
const SAMPLES_PER_DX: f64 = 2.0;

pub fn measure(view: &FieldView, shape: &DetectorShape) -> Measurement {
    match *shape {
        DetectorShape::Line { x1_um, y1_um, x2_um, y2_um } => {
            let (p1, p2) = (Vec2::new(x1_um, y1_um), Vec2::new(x2_um, y2_um));
            let length = p1.dist(p2);
            let normal = line_normal(p1, p2);
            Measurement::Line { length_um: length, normal: normal.to_array(), flux: line_flux(view, p1, p2) }
        }
        DetectorShape::Box { x_um, y_um, width_um, height_um } => {
            let r = box_rect(x_um, y_um, width_um, height_um);
            let (total, incident) = box_intensity(view, r);
            Measurement::Box { area_um2: r.width() * r.height(), total, incident }
        }
    }
}

/// Flux through the segment p1–p2 (positive along [`line_normal`]): Simpson's
/// rule over samples at most half a grid spacing apart.
pub fn line_flux(view: &FieldView, p1: Vec2, p2: Vec2) -> Flux {
    let length = p1.dist(p2);
    let n_hat = line_normal(p1, p2);
    let k0 = 2.0 * std::f64::consts::PI / view.wavelength_um;
    // An even count keeps the rule plain Simpson, symmetric in p1 and p2.
    let intervals = ((length * SAMPLES_PER_DX / view.grid.dx / 2.0).ceil() as usize).max(1) * 2;
    let h = length / intervals as f64;
    let (mut st, mut si, mut ss) = (Vec::with_capacity(intervals + 1), Vec::new(), Vec::new());
    let s = |e: C64, g: [C64; 2]| -(e.conj() * (g[0] * n_hat.x + g[1] * n_hat.y)).im / (2.0 * k0);
    for k in 0..=intervals {
        let p = p1 + (p2 - p1) * (k as f64 / intervals as f64);
        let st_ = Stencil::at(view.grid, p);
        let (et, gt) = st_.value_grad(view.total);
        let (ei, gi) = st_.value_grad(view.incident);
        st.push(s(et, gt));
        si.push(s(ei, gi));
        ss.push(s(et - ei, [gt[0] - gi[0], gt[1] - gi[1]]));
    }
    Flux { total: simpson(&st, h), incident: simpson(&si, h), scattered: simpson(&ss, h) }
}

/// The value of `values` (one per grid node) at `p`, by the same local
/// interpolation the detectors use.
pub fn value_at(grid: &GridSpec, values: &[C64], p: Vec2) -> C64 {
    Stencil::at(grid, p).value(values)
}

/// |E|² of the total and incident field over `r`: the midpoint rule on cells
/// at most half a grid spacing wide (at least 4 across).
pub fn box_intensity(view: &FieldView, r: Rect) -> (Intensity, Intensity) {
    let cells = |len: f64| ((len * SAMPLES_PER_DX / view.grid.dx).ceil() as usize).max(4);
    let (nx, ny) = (cells(r.width()), cells(r.height()));
    let (hx, hy) = (r.width() / nx as f64, r.height() / ny as f64);
    let (mut sum_t, mut sum_i, mut max_t, mut max_i) = (0.0, 0.0, 0.0f64, 0.0f64);
    for j in 0..ny {
        for i in 0..nx {
            let p = Vec2::new(r.x_min + (i as f64 + 0.5) * hx, r.y_min + (j as f64 + 0.5) * hy);
            let st = Stencil::at(view.grid, p);
            let t = st.value(view.total).norm_sqr();
            let inc = st.value(view.incident).norm_sqr();
            sum_t += t;
            sum_i += inc;
            max_t = max_t.max(t);
            max_i = max_i.max(inc);
        }
    }
    let n = (nx * ny) as f64;
    let area = r.width() * r.height();
    let stats = |sum: f64, max: f64| Intensity { mean: sum / n, integral: sum / n * area, max };
    (stats(sum_t, max_t), stats(sum_i, max_i))
}

/// Nodes of the local interpolant along each axis.
const ORDER: usize = 8;

/// Lagrange weights (value and derivative) for one point: the up to 8 × 8
/// nodes nearest to it, shifted inward at the grid edges.
struct Stencil {
    i0: usize,
    j0: usize,
    nx: usize,
    wx: [f64; ORDER],
    dwx: [f64; ORDER],
    wy: [f64; ORDER],
    dwy: [f64; ORDER],
    mx: usize,
    my: usize,
    dx: f64,
}

impl Stencil {
    fn at(g: &GridSpec, p: Vec2) -> Stencil {
        // Points just outside the node rectangle (a detector on the domain edge
        // when the grid stops short of it) are moved onto it.
        let fx = ((p.x - g.x0) / g.dx).clamp(0.0, (g.nx - 1) as f64);
        let fy = ((p.y - g.y0) / g.dx).clamp(0.0, (g.ny - 1) as f64);
        let (i0, mx) = start(fx, g.nx);
        let (j0, my) = start(fy, g.ny);
        let (wx, dwx) = lagrange(fx - i0 as f64, mx);
        let (wy, dwy) = lagrange(fy - j0 as f64, my);
        Stencil { i0, j0, nx: g.nx, wx, dwx, wy, dwy, mx, my, dx: g.dx }
    }

    fn value(&self, v: &[C64]) -> C64 {
        let mut acc = C64::new(0.0, 0.0);
        for b in 0..self.my {
            let row = (self.j0 + b) * self.nx + self.i0;
            let mut r = C64::new(0.0, 0.0);
            for a in 0..self.mx {
                r += self.wx[a] * v[row + a];
            }
            acc += self.wy[b] * r;
        }
        acc
    }

    /// The value and its gradient (per µm).
    fn value_grad(&self, v: &[C64]) -> (C64, [C64; 2]) {
        let zero = C64::new(0.0, 0.0);
        let (mut e, mut ex, mut ey) = (zero, zero, zero);
        for b in 0..self.my {
            let row = (self.j0 + b) * self.nx + self.i0;
            let (mut r, mut rd) = (zero, zero);
            for a in 0..self.mx {
                r += self.wx[a] * v[row + a];
                rd += self.dwx[a] * v[row + a];
            }
            e += self.wy[b] * r;
            ex += self.wy[b] * rd;
            ey += self.dwy[b] * r;
        }
        (e, [ex / self.dx, ey / self.dx])
    }
}

/// First node and node count of the stencil around fractional index `f` on
/// an axis of `n` nodes.
fn start(f: f64, n: usize) -> (usize, usize) {
    let m = ORDER.min(n);
    let i0 = (f.floor() as isize - (m as isize / 2 - 1)).clamp(0, (n - m) as isize);
    (i0 as usize, m)
}

/// Lagrange basis weights and their derivatives at `t` for nodes 0..m.
fn lagrange(t: f64, m: usize) -> ([f64; ORDER], [f64; ORDER]) {
    let mut w = [0.0; ORDER];
    let mut dw = [0.0; ORDER];
    for k in 0..m {
        let mut den = 1.0;
        for l in (0..m).filter(|&l| l != k) {
            den *= k as f64 - l as f64;
        }
        let mut prod = 1.0;
        for l in (0..m).filter(|&l| l != k) {
            prod *= t - l as f64;
        }
        w[k] = prod / den;
        let mut d = 0.0;
        for skip in (0..m).filter(|&l| l != k) {
            let mut p = 1.0;
            for l in (0..m).filter(|&l| l != k && l != skip) {
                p *= t - l as f64;
            }
            d += p;
        }
        dw[k] = d / den;
    }
    (w, dw)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lagrange_reproduces_polynomials_of_degree_seven() {
        let f = |x: f64| 1.0 - 2.0 * x + 0.5 * x.powi(3) - 0.1 * x.powi(5) + 0.01 * x.powi(7);
        let df = |x: f64| -2.0 + 1.5 * x * x - 0.5 * x.powi(4) + 0.07 * x.powi(6);
        for t in [0.0, 0.3, 3.5, 6.9] {
            let (w, dw) = lagrange(t, ORDER);
            let v: f64 = (0..ORDER).map(|k| w[k] * f(k as f64)).sum();
            let d: f64 = (0..ORDER).map(|k| dw[k] * f(k as f64)).sum();
            assert!((v - f(t)).abs() < 1e-9 * f(t).abs().max(1.0), "{t}: {v} vs {}", f(t));
            assert!((d - df(t)).abs() < 1e-9 * df(t).abs().max(1.0), "{t}: {d} vs {}", df(t));
        }
    }

    #[test]
    fn stencils_stay_on_small_grids() {
        assert_eq!(start(0.2, 3), (0, 3));
        assert_eq!(start(9.9, 10), (2, 8));
        assert_eq!(start(4.5, 10), (1, 8));
    }
}
