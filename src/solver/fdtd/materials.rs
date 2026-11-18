//! Rasterisation of the bodies onto the Ez nodes.
//!
//! Each Ez node gets ε averaged over its dual cell `[x ± Δ/2] × [y ± Δ/2]`.
//! Nodes farther than 0.75 Δ from every boundary are pure (one material);
//! the rest are supersampled ss × ss with `Body::inside`. The average is the
//! arithmetic mean of the (dispersion-corrected) complex ε over the non-PEC
//! samples. Because Ez is tangential to every interface, this arithmetic
//! average is the second-order smoothing.
//!
//! A node that sees a dispersive body gets ε(ω) = constant + Σ f_b χ_b(ω): the
//! average of every sample's instantaneous part (ε of plain media, ε∞ of
//! dispersive ones) plus each dispersive body's poles scaled by its fill
//! fraction f_b. ε is linear in ε∞ and the pole strengths, so this is the same
//! arithmetic average of ε(ω).
//!
//! With sub-pixel smoothing on, a node is PEC when it lies inside a PEC body or
//! within Δ/2 of one, so the staircase surface is the node line nearest to the
//! true surface. [`pec_edges`] then lists the H edges between a PEC node and a
//! free one with the distance from the free node to the true surface along the
//! edge, which the solver uses to place Ez = 0 on the true surface (a conformal
//! update). That distance is always more than Δ/2, which keeps the time step
//! stable without reducing it.

use std::sync::atomic::{AtomicBool, Ordering};

use rayon::prelude::*;

use crate::geometry::{Body, BodyMaterial};
use crate::problem::Problem;
use crate::scene::Material;
use crate::types::{Rect, Vec2, C64};

use super::grid::Layout;

/// Material of a non-background node.
#[derive(Clone, Debug, PartialEq)]
pub enum NodeMat {
    Pec,
    /// Averaged (dispersion-corrected) ε = ε′ − jε″.
    Medium(C64),
    /// A node in or next to a dispersive body: the averaged instantaneous ε
    /// (dispersion-corrected, ε′ − jε″) and the fill fraction of each
    /// dispersive body.
    Dispersive { constant: C64, parts: Vec<(usize, f64)> },
}

/// Non-background nodes, sorted by full-grid index.
pub struct Raster {
    pub nodes: Vec<(usize, NodeMat)>,
}

/// A body's medium as the grid sees it (dispersion-corrected when enabled).
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum BodyMedium {
    Pec,
    Plain(C64),
    /// ε∞ (scaled by the same correction factor as the poles).
    Dispersive { eps_inf: f64 },
}

/// The medium of each body. `factor(eps)` is the dispersion correction for a
/// medium with ε at the solve frequency (1 when disabled); a dispersive body's
/// ε∞ and poles are scaled by the factor of its ε at λ0, so its ε(ω) is
/// corrected as a whole.
pub fn body_media(p: &Problem, factor: impl Fn(C64) -> f64) -> Vec<BodyMedium> {
    p.bodies
        .iter()
        .map(|b| match (b.material, &p.scene.elements[b.element_index].material) {
            (BodyMaterial::Pec, _) => BodyMedium::Pec,
            (BodyMaterial::Dielectric { eps, .. }, Material::Dispersive { eps_inf, .. }) => {
                BodyMedium::Dispersive { eps_inf: eps_inf * factor(eps) }
            }
            (BodyMaterial::Dielectric { eps, .. }, _) => BodyMedium::Plain(eps * factor(eps)),
        })
        .collect()
}

/// Classifies every Ez node near or inside a body. `None` if cancelled.
pub fn rasterize(
    p: &Problem,
    l: &Layout,
    eps_bg: C64,
    media: &[BodyMedium],
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
                    classify_subpixel(&p.bodies, &near, pt, dx, ss, eps_bg, media)
                } else {
                    near.iter().find(|&&b| p.bodies[b].inside(pt)).map(|&b| pure(media, b))
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

/// A node inside body `b` only.
fn pure(media: &[BodyMedium], b: usize) -> NodeMat {
    match media[b] {
        BodyMedium::Pec => NodeMat::Pec,
        BodyMedium::Plain(e) => NodeMat::Medium(e),
        BodyMedium::Dispersive { eps_inf } => NodeMat::Dispersive { constant: C64::new(eps_inf, 0.0), parts: vec![(b, 1.0)] },
    }
}

/// Material of the node at `pt` with dual-cell averaging; `None` for background.
fn classify_subpixel(
    bodies: &[Body],
    near: &[usize],
    pt: Vec2,
    dx: f64,
    ss: usize,
    eps_bg: C64,
    media: &[BodyMedium],
) -> Option<NodeMat> {
    let pure_limit = 0.75 * dx;
    let mut inside_of = None;
    let mut mixed = false;
    for &b in near {
        let body = &bodies[b];
        let d = body.contour.closest(pt).3;
        // The PEC surface snaps to the nearest node line.
        if body.is_pec() && (d <= 0.5 * dx || body.contour.inside(pt)) {
            return Some(NodeMat::Pec);
        }
        if d <= pure_limit {
            mixed = true;
        } else if body.contour.inside(pt) {
            inside_of = Some(b);
        }
    }
    if !mixed {
        return inside_of.map(|b| pure(media, b));
    }
    let mut pec = 0usize;
    let mut sum = C64::new(0.0, 0.0);
    // Samples per dispersive body.
    let mut disp: Vec<(usize, usize)> = Vec::new();
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
                    match media[b] {
                        BodyMedium::Pec => pec += 1,
                        BodyMedium::Plain(e) => sum += e,
                        BodyMedium::Dispersive { eps_inf } => {
                            sum += eps_inf;
                            match disp.iter_mut().find(|d| d.0 == b) {
                                Some(d) => d.1 += 1,
                                None => disp.push((b, 1)),
                            }
                        }
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
    if pec == total {
        // Outside every PEC body and more than Δ/2 from it, so this cannot
        // happen for a sensible ss; treat the node as background.
        return Some(NodeMat::Medium(eps_bg));
    }
    let free = (total - pec) as f64;
    if disp.is_empty() {
        Some(NodeMat::Medium(sum / free))
    } else {
        Some(NodeMat::Dispersive { constant: sum / free, parts: disp.into_iter().map(|(b, k)| (b, k as f64 / free)).collect() })
    }
}

/// An H edge between a free Ez node and a PEC one.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PecEdge {
    /// Full-grid index of the H component (`Hy` for an x edge, `Hx` for a y edge).
    pub h: usize,
    /// True for an `Hx` edge (along y).
    pub hx: bool,
    /// Full-grid index of the free Ez node.
    pub free: usize,
    /// The H correction is `sign · (Δt/Δ)(Δ/len − 1) · Ez_total(free)`.
    pub sign: f64,
    /// Distance from the free node to the PEC surface along the edge, in
    /// [Δ/2, 3Δ/2].
    pub len: f64,
}

/// The edges between PEC and free nodes, with the free node's distance to the
/// true PEC surface along each. Empty when there is no PEC body.
pub fn pec_edges(p: &Problem, l: &Layout, raster: &Raster) -> Vec<PecEdge> {
    let pec_bodies: Vec<&Body> = p.bodies.iter().filter(|b| b.is_pec()).collect();
    if pec_bodies.is_empty() {
        return Vec::new();
    }
    let (nx, ny, dx) = (l.nx, l.ny, l.dx);
    let is_pec = |idx: usize| {
        raster.nodes.binary_search_by_key(&idx, |n| n.0).is_ok_and(|k| raster.nodes[k].1 == NodeMat::Pec)
    };
    let reach = 1.5 * dx;
    let mut out = Vec::new();
    for (idx, m) in &raster.nodes {
        let idx = *idx;
        if *m != NodeMat::Pec {
            continue;
        }
        let (i, j) = (idx % nx, idx / nx);
        // (di, dj): from the PEC node to its free neighbour.
        for (di, dj) in [(-1i64, 0i64), (1, 0), (0, -1), (0, 1)] {
            let (fi, fj) = (i as i64 + di, j as i64 + dj);
            if fi < 1 || fj < 1 || fi > nx as i64 - 2 || fj > ny as i64 - 2 {
                continue;
            }
            let (fi, fj) = (fi as usize, fj as usize);
            let free = fj * nx + fi;
            if is_pec(free) {
                continue;
            }
            let a = l.point(fi, fj);
            let dir = Vec2::new(-di as f64, -dj as f64);
            let hit = pec_bodies
                .iter()
                .filter(|b| b.bbox.expand(reach).contains(a))
                .filter_map(|b| b.contour.ray_hit(a, dir, reach))
                .fold(reach, f64::min);
            let len = hit.clamp(0.5 * dx, reach);
            let (h, hx, sign) = match (di, dj) {
                (-1, 0) => (free, false, -1.0),
                (1, 0) => (idx, false, 1.0),
                (0, -1) => (free, true, 1.0),
                _ => (idx, true, -1.0),
            };
            out.push(PecEdge { h, hx, free, sign, len });
        }
    }
    out
}
