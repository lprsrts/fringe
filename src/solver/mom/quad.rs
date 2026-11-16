//! Panel quadrature (spec §5.3, "Integration rules").
//!
//! Every rule integrates on the exact curve parameter of the panel, with the
//! arclength Jacobian folded into the node weights:
//! - **self panel** (the field point is the panel's own collocation point): split
//!   at the midpoint and integrate each half with a Gauss–Legendre rule graded
//!   toward the split, `t = ½ ± ½ τ³`. The grading turns the logarithmic
//!   singularity of S_k (and of the N_b − N_i difference) into a smooth `τ² ln τ`
//!   integrand, so one rule serves every kernel and any density, including the
//!   incident traces of the right-hand side.
//! - **near pairs** (distance below two panel lengths): recursive bisection
//!   with 8-point Gauss–Legendre until each piece is shorter than half its
//!   distance to the field point (depth ≤ 6).
//! - **far pairs**: `far_quad` Gauss–Legendre points, precomputed per panel.

use std::sync::Arc;

use crate::special::quadrature::{gauss_legendre, GaussLegendre};
use crate::types::Vec2;

use super::panels::{Panel, Panels};

/// A pair is near when the field point is closer than this many panel lengths.
pub const NEAR_FACTOR: f64 = 2.0;
/// Bisection depth limit of the near rule.
pub const MAX_DEPTH: u32 = 6;
/// Points per half of the graded self-panel rule.
const SELF_POINTS: usize = 12;
/// Grading exponent of the self-panel rule.
const SELF_GRADE: i32 = 3;
/// Points of the near rule per accepted piece.
const NEAR_POINTS: usize = 8;

/// One quadrature node on a panel.
#[derive(Clone, Copy, Debug)]
pub struct Node {
    pub y: Vec2,
    /// Outward unit normal at y.
    pub n: Vec2,
    /// Weight including the arclength Jacobian.
    pub w: f64,
    /// Parameter on the panel, in [0, 1].
    pub t: f64,
    /// Index into the precomputed far nodes, or `usize::MAX`.
    pub far: usize,
}

pub struct Rules {
    near: Arc<GaussLegendre>,
    /// Graded half rule on [0, 1]: (offset from the split, weight).
    graded: Vec<(f64, f64)>,
    pub far: Arc<GaussLegendre>,
}

impl Rules {
    pub fn new(far_quad: usize) -> Rules {
        let gl = gauss_legendre(SELF_POINTS);
        let p = SELF_GRADE as f64;
        let graded = gl
            .on(0.0, 1.0)
            .map(|(tau, w)| (tau.powi(SELF_GRADE), w * p * tau.powi(SELF_GRADE - 1)))
            .collect();
        Rules { near: gauss_legendre(NEAR_POINTS), graded, far: gauss_legendre(far_quad.max(1)) }
    }

    pub fn far_per_panel(&self) -> usize {
        self.far.nodes.len()
    }
}

/// The far-rule nodes of every panel, `per` consecutive nodes per panel.
pub struct FarNodes {
    pub nodes: Vec<Node>,
    pub per: usize,
}

impl FarNodes {
    pub fn new(panels: &Panels, rules: &Rules) -> FarNodes {
        let per = rules.far_per_panel();
        let mut nodes = Vec::with_capacity(per * panels.panels.len());
        for (j, pj) in panels.panels.iter().enumerate() {
            for (k, (t, w)) in rules.far.on(0.0, 1.0).enumerate() {
                nodes.push(Node { y: pj.point(t), n: pj.normal_at(t), w: w * pj.len, t, far: j * per + k });
            }
        }
        FarNodes { nodes, per }
    }

    #[inline]
    pub fn of(&self, j: usize) -> &[Node] {
        &self.nodes[j * self.per..(j + 1) * self.per]
    }
}

#[inline]
pub fn is_near(panel: &Panel, x: Vec2) -> bool {
    panel.distance_bound(x) < NEAR_FACTOR * panel.len
}

/// Nodes of the graded self-panel rule about the midpoint t = ½.
pub fn self_nodes(panel: &Panel, rules: &Rules, f: &mut impl FnMut(&Node)) {
    for &(off, w) in &rules.graded {
        for sign in [-1.0, 1.0] {
            let t = 0.5 + sign * 0.5 * off;
            let node = Node { y: panel.point(t), n: panel.normal_at(t), w: 0.5 * w * panel.len, t, far: usize::MAX };
            f(&node);
        }
    }
}

/// Nodes of the adaptive near rule for field point `x`.
pub fn near_nodes(panel: &Panel, x: Vec2, rules: &Rules, f: &mut impl FnMut(&Node)) {
    let mut stack: [(f64, f64, u32); 2 * MAX_DEPTH as usize + 2] = [(0.0, 0.0, 0); 2 * MAX_DEPTH as usize + 2];
    let mut top = 1usize;
    stack[0] = (0.0, 1.0, 0);
    while top > 0 {
        top -= 1;
        let (a, b, depth) = stack[top];
        let sub_len = (b - a) * panel.len;
        let pm = panel.point(0.5 * (a + b));
        let dist = x.dist(pm) - 0.5 * sub_len;
        if depth >= MAX_DEPTH || sub_len < 0.5 * dist {
            for (t, w) in rules.near.on(a, b) {
                let node = Node { y: panel.point(t), n: panel.normal_at(t), w: w * panel.len, t, far: usize::MAX };
                f(&node);
            }
        } else {
            let m = 0.5 * (a + b);
            stack[top] = (m, b, depth + 1);
            stack[top + 1] = (a, m, depth + 1);
            top += 2;
        }
    }
}

/// Visits the nodes integrating panel `j` as seen from `x`: self, near or far.
#[inline]
pub fn visit(
    panels: &Panels,
    far: &FarNodes,
    rules: &Rules,
    j: usize,
    x: Vec2,
    self_panel: bool,
    f: &mut impl FnMut(&Node),
) {
    let pj = &panels.panels[j];
    if self_panel {
        self_nodes(pj, rules, f);
    } else if is_near(pj, x) {
        near_nodes(pj, x, rules, f);
    } else {
        for node in far.of(j) {
            f(node);
        }
    }
}
