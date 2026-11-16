//! Panels: every body contour cut into exact sub-curves (spec §5.3).
//!
//! A segment of length ℓ becomes ⌈ℓ/h⌉ equal panels with `h = λ_loc/ppw`
//! (`λ_loc = λ0/max(n_b, Re n_i)` for a dielectric, `λ_b` for PEC). With corner
//! grading, the panel next to a corner (tangent turn > 15°) is replaced by
//! geometric sub-panels of lengths L/2, L/4, L/8, L/8, the smallest at the
//! corner. Collocation is at each panel's parametric midpoint on the true curve.
//!
//! Panels on the same smooth piece of a contour are linked to their neighbours;
//! the link is cut at corners. The links drive the density reconstruction used
//! by the field evaluation.

use crate::geometry::{Body, BodyMaterial, Segment};
use crate::problem::Problem;
use crate::scene::PecFormulation;
use crate::types::{Rect, Vec2, C64, J};

/// Tangent turn above which a contour vertex is a corner.
pub const CORNER_TURN_RAD: f64 = 15.0 * std::f64::consts::PI / 180.0;

#[derive(Clone, Debug)]
pub struct Panel {
    /// The exact piece of the contour, parametrised uniformly in arclength.
    pub seg: Segment,
    pub len: f64,
    /// Collocation point (parametric midpoint) and outward normal there.
    pub mid: Vec2,
    pub normal: Vec2,
    pub body: usize,
    /// Index within its body.
    pub local: usize,
    /// Neighbours (global indices) on the same smooth piece; `None` across a corner.
    pub prev: Option<usize>,
    pub next: Option<usize>,
    /// Contour segment this panel lies on, and its parameter range there.
    pub segment: usize,
    pub t0: f64,
    pub t1: f64,
}

impl Panel {
    #[inline]
    pub fn point(&self, t: f64) -> Vec2 {
        self.seg.point(t)
    }

    #[inline]
    pub fn normal_at(&self, t: f64) -> Vec2 {
        let tg = self.seg.tangent(t);
        Vec2::new(tg.y, -tg.x)
    }

    /// Lower bound on the distance from `x` to any point of the panel (a curve of
    /// length L lies within L/2 of its midpoint).
    #[inline]
    pub fn distance_bound(&self, x: Vec2) -> f64 {
        (x.dist(self.mid) - 0.5 * self.len).max(0.0)
    }
}

/// How a PEC body's rows are formed.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum PecRows {
    Efie,
    /// MFIE + β·EFIE.
    Cfie { beta: C64 },
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Medium {
    Dielectric { k_i: C64 },
    Pec(PecRows),
}

#[derive(Clone, Debug)]
pub struct BodyPanels {
    /// Global index of the first panel and the panel count.
    pub first: usize,
    pub count: usize,
    pub medium: Medium,
    /// Offset of the scattered trace u_s in the unknown vector (dielectric only).
    pub u_off: Option<usize>,
    /// Offset of q_s (dielectric) or the total q (PEC).
    pub q_off: usize,
    pub bbox: Rect,
    pub max_len: f64,
    /// Global index of the first panel of every contour segment, plus one past
    /// the last panel at the end.
    pub seg_first: Vec<usize>,
}

impl BodyPanels {
    pub fn range(&self) -> std::ops::Range<usize> {
        self.first..self.first + self.count
    }

    pub fn is_dielectric(&self) -> bool {
        matches!(self.medium, Medium::Dielectric { .. })
    }
}

#[derive(Clone, Debug)]
pub struct Panels {
    pub panels: Vec<Panel>,
    pub bodies: Vec<BodyPanels>,
    pub n_unknowns: usize,
}

/// Target panel length on a body.
pub fn panel_length(p: &Problem, body: &Body) -> f64 {
    let lambda_loc = match body.material {
        BodyMaterial::Pec => p.lambda_b(),
        BodyMaterial::Dielectric { n, .. } => p.lambda0 / p.n_b.max(n.re),
    };
    lambda_loc / p.settings.ppw
}

/// EFIE or CFIE for one PEC body (spec §5.3: `auto` uses the EFIE below a
/// nominal thickness of 0.45 λ_b, where no interior resonance exists at k_b).
pub fn pec_rows(p: &Problem, body: &Body) -> PecRows {
    let s = &p.settings.mom;
    let cfie = PecRows::Cfie { beta: J * p.k_b * s.cfie_beta_scale };
    match s.pec_formulation {
        PecFormulation::Efie => PecRows::Efie,
        PecFormulation::Cfie => cfie,
        PecFormulation::Auto => {
            let t = body
                .nominal_thickness_um
                .unwrap_or_else(|| body.bbox.width().min(body.bbox.height()));
            if t < 0.45 * p.lambda_b() {
                PecRows::Efie
            } else {
                cfie
            }
        }
    }
}

/// Parameter breakpoints of one segment: `n` equal pieces, graded toward the ends
/// that are corners.
fn breakpoints(n: usize, grade_start: bool, grade_end: bool) -> Vec<f64> {
    let nf = n as f64;
    let mut t: Vec<f64> = (0..=n).map(|k| k as f64 / nf).collect();
    if grade_start {
        t.extend([0.125 / nf, 0.25 / nf, 0.5 / nf]);
    }
    if grade_end {
        t.extend([1.0 - 0.5 / nf, 1.0 - 0.25 / nf, 1.0 - 0.125 / nf]);
    }
    t.sort_by(|a, b| a.total_cmp(b));
    t.dedup_by(|a, b| (*a - *b).abs() < 1e-12);
    t
}

/// Cuts every body of `p` into panels and lays out the unknowns.
pub fn panelize(p: &Problem) -> Panels {
    let grading = p.settings.mom.corner_grading;
    let mut panels: Vec<Panel> = Vec::new();
    let mut bodies = Vec::with_capacity(p.bodies.len());
    let mut offset = 0usize;
    for (b, body) in p.bodies.iter().enumerate() {
        let h = panel_length(p, body);
        let segs = &body.contour.segments;
        let nseg = segs.len();
        let corners = body.contour.corners(CORNER_TURN_RAD);
        let is_corner = |v: usize| corners.contains(&(v % nseg));
        let first = panels.len();
        let mut seg_first = Vec::with_capacity(nseg + 1);
        // Whether the link between a panel and its predecessor is cut.
        let mut cut_before: Vec<bool> = Vec::new();
        for (si, seg) in segs.iter().enumerate() {
            seg_first.push(panels.len());
            let n = ((seg.length() / h) - 1e-9).ceil().max(1.0) as usize;
            let (gs, ge) = (grading && is_corner(si), grading && is_corner(si + 1));
            let t = breakpoints(n, gs, ge);
            for k in 0..t.len() - 1 {
                let (t0, t1) = (t[k], t[k + 1]);
                let sub = seg.sub(t0, t1);
                let tg = sub.tangent(0.5);
                panels.push(Panel {
                    seg: sub,
                    len: sub.length(),
                    mid: sub.point(0.5),
                    normal: Vec2::new(tg.y, -tg.x),
                    body: b,
                    local: panels.len() - first,
                    prev: None,
                    next: None,
                    segment: si,
                    t0,
                    t1,
                });
                cut_before.push(k == 0 && is_corner(si));
            }
        }
        seg_first.push(panels.len());
        let count = panels.len() - first;
        for (l, &cut) in cut_before.iter().enumerate() {
            let g = first + l;
            if !cut {
                let prev = first + (l + count - 1) % count;
                if prev != g {
                    panels[g].prev = Some(prev);
                    panels[prev].next = Some(g);
                }
            }
        }
        let max_len = panels[first..].iter().map(|q| q.len).fold(0.0, f64::max);
        let (medium, u_off, q_off) = match body.material {
            BodyMaterial::Dielectric { n, .. } => {
                let m = Medium::Dielectric { k_i: p.k0 * n };
                let r = (m, Some(offset), offset + count);
                offset += 2 * count;
                r
            }
            BodyMaterial::Pec => {
                let r = (Medium::Pec(pec_rows(p, body)), None, offset);
                offset += count;
                r
            }
        };
        bodies.push(BodyPanels { first, count, medium, u_off, q_off, bbox: body.bbox, max_len, seg_first });
    }
    Panels { panels, bodies, n_unknowns: offset }
}

impl Panels {
    /// The panel of body `b` containing parameter `t` of contour segment `seg`.
    pub fn panel_at(&self, b: usize, seg: usize, t: f64) -> usize {
        let bp = &self.bodies[b];
        let (lo, hi) = (bp.seg_first[seg], bp.seg_first[seg + 1]);
        let slice = &self.panels[lo..hi];
        let k = slice.partition_point(|q| q.t1 < t);
        lo + k.min(slice.len() - 1)
    }

    /// Reconstruction of a panel density at parameter `t` of panel `j` from the
    /// panel values: quadratic through the neighbouring midpoints on the same
    /// smooth piece, linear (extrapolated) beside a corner, constant if isolated.
    /// Returns (panel, weight) pairs; unused slots have weight 0.
    #[inline]
    pub fn recon(&self, j: usize, t: f64) -> [(usize, f64); 3] {
        let pj = &self.panels[j];
        let s = (t - 0.5) * pj.len;
        match (pj.prev, pj.next) {
            (Some(a), Some(c)) => {
                let sp = -0.5 * (pj.len + self.panels[a].len);
                let sn = 0.5 * (pj.len + self.panels[c].len);
                let wp = s * (s - sn) / (sp * (sp - sn));
                let w0 = (s - sp) * (s - sn) / (sp * sn);
                let wn = s * (s - sp) / (sn * (sn - sp));
                [(a, wp), (j, w0), (c, wn)]
            }
            (None, Some(c)) => {
                let sn = 0.5 * (pj.len + self.panels[c].len);
                [(j, 1.0 - s / sn), (c, s / sn), (j, 0.0)]
            }
            (Some(a), None) => {
                let sp = -0.5 * (pj.len + self.panels[a].len);
                [(j, 1.0 - s / sp), (a, s / sp), (j, 0.0)]
            }
            (None, None) => [(j, 1.0), (j, 0.0), (j, 0.0)],
        }
    }
}
