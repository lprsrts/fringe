//! Rasterisation of the bodies onto the Ez nodes (spec §5.1 "Materials").
//!
//! Each Ez node gets ε averaged over its dual cell `[x ± Δ/2] × [y ± Δ/2]`.
//! Nodes farther than 0.75 Δ from every boundary are pure (one material);
//! the rest are supersampled ss × ss with `Body::inside`. The average is the
//! arithmetic mean of the (dispersion-corrected) complex ε over the non-PEC
//! samples. A node is PEC when its PEC fill is ≥ ½. Because Ez is tangential to
//! every interface, this arithmetic average is the second-order smoothing.

use std::sync::atomic::{AtomicBool, Ordering};

use rayon::prelude::*;

use crate::geometry::{Body, BodyMaterial};
use crate::problem::Problem;
use crate::types::{Rect, Vec2, C64};

use super::grid::Layout;

/// Material of a non-background node.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum NodeMat {
    Pec,
    /// Averaged (dispersion-corrected) ε = ε′ − jε″.
    Medium(C64),
}

/// Non-background nodes, sorted by full-grid index.
pub struct Raster {
    pub nodes: Vec<(usize, NodeMat)>,
}

/// Effective ε of each body (dispersion-corrected when enabled); `None` for PEC.
pub fn body_eps(p: &Problem, correct: impl Fn(C64) -> C64) -> Vec<Option<C64>> {
    p.bodies
        .iter()
        .map(|b| match b.material {
            BodyMaterial::Pec => None,
            BodyMaterial::Dielectric { eps, .. } => Some(correct(eps)),
        })
        .collect()
}

/// Classifies every Ez node near or inside a body. `None` if cancelled.
pub fn rasterize(
    p: &Problem,
    l: &Layout,
    eps_bg: C64,
    eps_body: &[Option<C64>],
    cancel: &AtomicBool,
) -> Option<Raster> {
    let dx = l.dx;
    let ss = p.settings.fdtd.supersample.max(1);
    let subpixel = p.settings.fdtd.subpixel;
    // Bodies' boxes grown by one cell; nodes outside all of them are background.
    let boxes: Vec<Rect> = p.bodies.iter().map(|b| b.bbox.expand(dx)).collect();
    let rows: Vec<Vec<(usize, NodeMat)>> = (0..l.ny)
        .into_par_iter()
        .map(|jj| {
            let mut out = Vec::new();
            if cancel.load(Ordering::Relaxed) {
                return out;
            }
            let y = l.y0 + jj as f64 * dx;
            let cands: Vec<usize> = (0..p.bodies.len()).filter(|&b| y >= boxes[b].y_min && y <= boxes[b].y_max).collect();
            if cands.is_empty() {
                return out;
            }
            let x_lo = cands.iter().map(|&b| boxes[b].x_min).fold(f64::INFINITY, f64::min);
            let x_hi = cands.iter().map(|&b| boxes[b].x_max).fold(f64::NEG_INFINITY, f64::max);
            let i0 = ((x_lo - l.x0) / dx).floor().max(1.0) as usize;
            let i1 = (((x_hi - l.x0) / dx).ceil().max(0.0) as usize).min(l.nx.saturating_sub(2));
            let mut near: Vec<usize> = Vec::with_capacity(cands.len());
            for ii in i0..=i1 {
                let pt = Vec2::new(l.x0 + ii as f64 * dx, y);
                near.clear();
                near.extend(cands.iter().copied().filter(|&b| boxes[b].contains(pt)));
                if near.is_empty() {
                    continue;
                }
                let m = if subpixel {
                    classify_subpixel(&p.bodies, &near, pt, dx, ss, eps_bg, eps_body)
                } else {
                    near.iter()
                        .find(|&&b| p.bodies[b].inside(pt))
                        .map(|&b| eps_body[b].map_or(NodeMat::Pec, NodeMat::Medium))
                };
                if let Some(m) = m {
                    if let NodeMat::Medium(e) = m {
                        if (e - eps_bg).norm() <= 1e-12 {
                            continue;
                        }
                    }
                    out.push((jj * l.nx + ii, m));
                }
            }
            out
        })
        .collect();
    if cancel.load(Ordering::Relaxed) {
        return None;
    }
    Some(Raster { nodes: rows.into_iter().flatten().collect() })
}

/// Material of the node at `pt` with dual-cell averaging; `None` for background.
fn classify_subpixel(
    bodies: &[Body],
    near: &[usize],
    pt: Vec2,
    dx: f64,
    ss: usize,
    eps_bg: C64,
    eps_body: &[Option<C64>],
) -> Option<NodeMat> {
    let pure_limit = 0.75 * dx;
    let mut inside_of = None;
    let mut mixed = false;
    for &b in near {
        let body = &bodies[b];
        let d = body.contour.closest(pt).3;
        if d <= pure_limit {
            mixed = true;
            break;
        }
        if body.contour.inside(pt) {
            inside_of = Some(b);
        }
    }
    if !mixed {
        return inside_of.map(|b| eps_body[b].map_or(NodeMat::Pec, NodeMat::Medium));
    }
    let mut pec = 0usize;
    let mut sum = C64::new(0.0, 0.0);
    let mut any_body = false;
    let h = dx / ss as f64;
    for sj in 0..ss {
        let y = pt.y - 0.5 * dx + (sj as f64 + 0.5) * h;
        for si in 0..ss {
            let x = pt.x - 0.5 * dx + (si as f64 + 0.5) * h;
            let q = Vec2::new(x, y);
            match near.iter().find(|&&b| bodies[b].inside(q)) {
                Some(&b) => {
                    any_body = true;
                    match eps_body[b] {
                        None => pec += 1,
                        Some(e) => sum += e,
                    }
                }
                None => sum += eps_bg,
            }
        }
    }
    if !any_body {
        return None;
    }
    let total = ss * ss;
    if pec as f64 >= (0.5 - 1e-9) * total as f64 {
        return Some(NodeMat::Pec);
    }
    Some(NodeMat::Medium(sum / (total - pec) as f64))
}
