//! Error norms, masks and derived measurements used by the validation cases.

use rayon::prelude::*;

use crate::geometry::Body;
use crate::solver::{FieldGrid, GridSpec, Part};
use crate::types::{Rect, Vec2, C64};

/// ‖a − b‖₂ / ‖b‖₂ over the points where `mask` is true (all points without one).
pub fn rel_l2(a: &[C64], b: &[C64], mask: Option<&[bool]>) -> f64 {
    assert_eq!(a.len(), b.len());
    let (mut num, mut den) = (0.0, 0.0);
    for i in 0..a.len() {
        if mask.is_some_and(|m| !m[i]) {
            continue;
        }
        num += (a[i] - b[i]).norm_sqr();
        den += b[i].norm_sqr();
    }
    if den == 0.0 {
        if num == 0.0 {
            0.0
        } else {
            f64::INFINITY
        }
    } else {
        (num / den).sqrt()
    }
}

/// `part` of `field` sampled (bicubic) at every node of `g`; `None` outside it.
pub fn resample(field: &FieldGrid, part: Part, g: &GridSpec) -> Vec<Option<C64>> {
    (0..g.len())
        .into_par_iter()
        .map(|idx| field.sample(part, g.point(idx % g.nx, idx / g.nx)))
        .collect()
}

/// Nodes of `g` within `width` of any body boundary.
pub fn interface_band(g: &GridSpec, bodies: &[Body], width: f64) -> Vec<bool> {
    (0..g.len())
        .into_par_iter()
        .map(|idx| {
            let p = g.point(idx % g.nx, idx / g.nx);
            bodies
                .iter()
                .any(|b| b.bbox.distance_to(p) < width && b.contour.closest(p).3 < width)
        })
        .collect()
}

/// Nodes of `g` inside a PEC body.
pub fn pec_mask(g: &GridSpec, bodies: &[Body]) -> Vec<bool> {
    (0..g.len())
        .into_par_iter()
        .map(|idx| {
            let p = g.point(idx % g.nx, idx / g.nx);
            bodies.iter().any(|b| b.is_pec() && b.inside(p))
        })
        .collect()
}

/// Position and value of the maximum of |E_total|² along the line y = `y` for x in
/// [x_from, x_to], sampled at the grid spacing and refined with a parabola through
/// the three samples around the maximum.
pub fn focal_peak(field: &FieldGrid, y: f64, x_from: f64, x_to: f64) -> Option<(f64, f64)> {
    let dx = field.grid.dx;
    let n = ((x_to - x_from) / dx).floor() as usize + 1;
    let samples: Vec<(f64, f64)> = (0..n)
        .filter_map(|i| {
            let x = x_from + i as f64 * dx;
            field.sample(Part::Total, Vec2::new(x, y)).map(|e| (x, e.norm_sqr()))
        })
        .collect();
    let (k, &(xk, vk)) = samples.iter().enumerate().max_by(|a, b| a.1 .1.total_cmp(&b.1 .1))?;
    if k == 0 || k + 1 >= samples.len() {
        return Some((xk, vk));
    }
    let (y0, y1, y2) = (samples[k - 1].1, vk, samples[k + 1].1);
    let den = y0 - 2.0 * y1 + y2;
    if den >= 0.0 {
        return Some((xk, vk));
    }
    let off = 0.5 * (y0 - y2) / den;
    let peak = y1 - 0.25 * (y0 - y2) * off;
    Some((xk + off * dx, peak))
}

/// Energy balance on a rectangle (snapped inward to grid nodes):
/// `Im ∮ E* ∂_n E dl` (net inflow) against `k0² ∫ ε″ |E|² dA` (absorption).
#[derive(Clone, Copy, Debug)]
pub struct FluxBalance {
    pub inflow: f64,
    pub absorbed: f64,
    /// `∮ |Im(E_s* ∂_n E_s)| dl`, a scale for lossless scenes where both are ~0.
    pub scattered_flux: f64,
}

impl FluxBalance {
    /// |inflow − absorbed| relative to the absorption, or to the scattered flux
    /// when nothing absorbs.
    pub fn residual(&self) -> f64 {
        let scale = if self.absorbed.abs() > 0.0 { self.absorbed.abs() } else { self.scattered_flux };
        (self.inflow - self.absorbed).abs() / scale
    }
}

/// See [`FluxBalance`]. ∂_n E uses 4th-order central differences, the contour
/// integral composite Simpson along each edge and the area integral the 2D
/// trapezoidal rule.
pub fn flux_balance(field: &FieldGrid, rect: Rect) -> FluxBalance {
    let g = &field.grid;
    let h = g.dx;
    let i0 = ((rect.x_min - g.x0) / h).ceil().max(2.0) as usize;
    let i1 = (((rect.x_max - g.x0) / h).floor() as usize).min(g.nx - 3);
    let j0 = ((rect.y_min - g.y0) / h).ceil().max(2.0) as usize;
    let j1 = (((rect.y_max - g.y0) / h).floor() as usize).min(g.ny - 3);
    let k0 = 2.0 * std::f64::consts::PI / field.scene.wavelength_um;
    let tot = |i: usize, j: usize| field.total[g.index(i, j)];
    let sca = |i: usize, j: usize| field.value(Part::Scattered, g.index(i, j));
    let d4 = |f: &dyn Fn(isize) -> C64| (-f(2) + 8.0 * f(1) - 8.0 * f(-1) + f(-2)) / (12.0 * h);

    // Each edge: a list of (value E, outward derivative) at its nodes.
    let mut inflow = 0.0;
    let mut scat = 0.0;
    let mut edge = |pts: Vec<(usize, usize)>, dir: (isize, isize)| {
        let vals: Vec<(f64, f64)> = pts
            .iter()
            .map(|&(i, j)| {
                let at = |s: isize, f: &dyn Fn(usize, usize) -> C64| {
                    f((i as isize + s * dir.0) as usize, (j as isize + s * dir.1) as usize)
                };
                let dn = d4(&|s| at(s, &tot));
                let dns = d4(&|s| at(s, &sca));
                ((tot(i, j).conj() * dn).im, (sca(i, j).conj() * dns).im.abs())
            })
            .collect();
        inflow += simpson(&vals.iter().map(|v| v.0).collect::<Vec<_>>(), h);
        scat += simpson(&vals.iter().map(|v| v.1).collect::<Vec<_>>(), h);
    };
    edge((i0..=i1).map(|i| (i, j0)).collect(), (0, -1));
    edge((i0..=i1).map(|i| (i, j1)).collect(), (0, 1));
    edge((j0..=j1).map(|j| (i0, j)).collect(), (-1, 0));
    edge((j0..=j1).map(|j| (i1, j)).collect(), (1, 0));

    let mut absorbed = 0.0;
    for j in j0..=j1 {
        for i in i0..=i1 {
            let idx = g.index(i, j);
            let r = field.region[idx] as usize;
            if r == 0 {
                continue;
            }
            let eps_im = field.bodies[r - 1].eps_imag();
            if eps_im == 0.0 {
                continue;
            }
            let w = if i == i0 || i == i1 { 0.5 } else { 1.0 } * if j == j0 || j == j1 { 0.5 } else { 1.0 };
            absorbed += w * eps_im * field.total[idx].norm_sqr();
        }
    }
    FluxBalance { inflow, absorbed: k0 * k0 * absorbed * h * h, scattered_flux: scat }
}

/// Composite Simpson on equally spaced samples; an odd number of intervals ends
/// with Simpson's 3/8 rule on the last three.
pub fn simpson(v: &[f64], h: f64) -> f64 {
    let n = v.len();
    match n {
        0 | 1 => 0.0,
        2 => 0.5 * h * (v[0] + v[1]),
        3 => h / 3.0 * (v[0] + 4.0 * v[1] + v[2]),
        _ => {
            let intervals = n - 1;
            let (simpson_end, tail) = if intervals % 2 == 0 { (n, false) } else { (n - 3, true) };
            let mut s = 0.0;
            let mut k = 0;
            while k + 2 < simpson_end {
                s += h / 3.0 * (v[k] + 4.0 * v[k + 1] + v[k + 2]);
                k += 2;
            }
            if tail {
                let m = n - 4;
                s += 3.0 * h / 8.0 * (v[m] + 3.0 * v[m + 1] + 3.0 * v[m + 2] + v[m + 3]);
            }
            s
        }
    }
}

/// Convergence order from errors e1, e2 at resolutions h1, h2.
pub fn observed_order(e1: f64, e2: f64, h1: f64, h2: f64) -> f64 {
    (e1 / e2).ln() / (h1 / h2).ln()
}
