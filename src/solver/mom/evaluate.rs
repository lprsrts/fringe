//! The scattered field on the output grid (spec §5.3, "Field evaluation").
//!
//! - Outside every body: `E_s = Σ_B (D_b u_sB − S_b q_sB)` (u_sB = 0 and q_sB = q_B
//!   on PEC), the exterior representation of the scattered field.
//! - Inside dielectric A: `E_s = −D_i u_s + S_i q_s − (D_i − D_b) u_inc + (S_i − S_b) q_inc`
//!   over A's panels: the interior representation of E_tot minus the interior
//!   representation of E_inc with k_b, so a body with ε = ε_b gives exactly 0.
//! - Inside PEC: 0 (the pipeline zeroes it).
//! - Closer than L/4 to the boundary: the Taylor step `E_s ≈ u_s + d_n q_s` (E_s is
//!   C¹ across a dielectric interface because E_tot and E_inc are), or
//!   `E_s ≈ d_n q − E_inc` beside PEC.
//!
//! Densities are not used as pulses here: each node takes the panel values
//! reconstructed along the smooth piece of the contour ([`Panels::recon`]), which
//! removes the O(h) panel-edge artefacts of pulse densities near the boundary.

use std::sync::atomic::{AtomicUsize, Ordering};

use rayon::prelude::*;

use crate::problem::Problem;
use crate::solver::field::GridSpec;
use crate::solver::{SolveContext, SolveError};
use crate::special::greens::{radial, radial_diff_series, Radial};
use crate::types::{Vec2, C64};

use super::panels::{Medium, Panels};
use super::quad::{is_near, near_nodes, FarNodes, Node, Rules};
use super::system::IncidentTraces;

/// Solved panel densities: u_s (0 on PEC) and q_s (total q on PEC) per panel,
/// plus their reconstructions at the far nodes.
pub struct Densities {
    pub u: Vec<C64>,
    pub q: Vec<C64>,
    pub far_u: Vec<C64>,
    pub far_q: Vec<C64>,
}

impl Densities {
    pub fn new(panels: &Panels, far: &FarNodes, x: &[C64]) -> Densities {
        let np = panels.panels.len();
        let mut u = vec![C64::new(0.0, 0.0); np];
        let mut q = vec![C64::new(0.0, 0.0); np];
        for bp in &panels.bodies {
            for l in 0..bp.count {
                if let Some(uo) = bp.u_off {
                    u[bp.first + l] = x[uo + l];
                }
                q[bp.first + l] = x[bp.q_off + l];
            }
        }
        let mut d = Densities { u, q, far_u: Vec::new(), far_q: Vec::new() };
        let (fu, fq): (Vec<C64>, Vec<C64>) = far.nodes.iter().map(|nd| d.at(panels, nd.far / far.per, nd.t)).unzip();
        d.far_u = fu;
        d.far_q = fq;
        d
    }

    /// Reconstructed (u, q) at parameter t of panel j.
    #[inline]
    pub fn at(&self, panels: &Panels, j: usize, t: f64) -> (C64, C64) {
        let mut u = C64::new(0.0, 0.0);
        let mut q = C64::new(0.0, 0.0);
        for (k, w) in panels.recon(j, t) {
            if w != 0.0 {
                u += self.u[k] * w;
                q += self.q[k] * w;
            }
        }
        (u, q)
    }

    #[inline]
    fn at_node(&self, panels: &Panels, j: usize, nd: &Node) -> (C64, C64) {
        if nd.far != usize::MAX {
            (self.far_u[nd.far], self.far_q[nd.far])
        } else {
            self.at(panels, j, nd.t)
        }
    }
}

/// G and ∂G/∂n_y from radial values.
#[inline]
fn g_dny(rad: &Radial, x: Vec2, y: Vec2, n_y: Vec2, r: f64) -> (C64, C64) {
    let nyr = (n_y.x * (x.x - y.x) + n_y.y * (x.y - y.y)) / r;
    (rad.g, -rad.dg * nyr)
}

pub struct Evaluator<'a> {
    pub p: &'a Problem,
    pub panels: &'a Panels,
    pub far: &'a FarNodes,
    pub rules: &'a Rules,
    pub inc: &'a IncidentTraces,
    pub dens: &'a Densities,
}

impl Evaluator<'_> {
    /// E_s on the grid, rows in parallel with a cancellation check per row.
    pub fn grid(&self, g: &GridSpec, ctx: &SolveContext) -> Result<Vec<C64>, SolveError> {
        let mut out = vec![C64::new(0.0, 0.0); g.len()];
        let done = AtomicUsize::new(0);
        out.par_chunks_mut(g.nx.max(1)).enumerate().try_for_each(|(j, row)| {
            if ctx.is_cancelled() {
                return Err(SolveError::Cancelled);
            }
            for (i, v) in row.iter_mut().enumerate() {
                *v = self.point(g.point(i, j));
            }
            let d = done.fetch_add(1, Ordering::Relaxed) + 1;
            ctx.report(d as f64 / g.ny as f64);
            Ok(())
        })?;
        Ok(out)
    }

    /// E_s at one point.
    pub fn point(&self, x: Vec2) -> C64 {
        let p = self.p;
        let inside = p.body_at(x);
        if let Some(b) = inside {
            if p.bodies[b].is_pec() {
                return C64::new(0.0, 0.0);
            }
        }
        if let Some(v) = self.taylor(x, inside) {
            return v;
        }
        match inside {
            Some(a) => self.interior(x, a),
            None => self.exterior(x),
        }
    }

    /// The Taylor step when x is within a quarter panel of a boundary.
    fn taylor(&self, x: Vec2, inside: Option<usize>) -> Option<C64> {
        let mut best: Option<(usize, usize, f64, f64)> = None; // body, panel, t, signed d
        for (b, bp) in self.panels.bodies.iter().enumerate() {
            if bp.bbox.distance_to(x) > 0.25 * bp.max_len {
                continue;
            }
            let body = &self.p.bodies[b];
            let (seg, t, _, d) = body.contour.closest(x);
            let j = self.panels.panel_at(b, seg, t);
            let pj = &self.panels.panels[j];
            if d < 0.25 * pj.len && best.is_none_or(|bb| d < bb.3.abs()) {
                let tl = ((t - pj.t0) / (pj.t1 - pj.t0)).clamp(0.0, 1.0);
                let sd = if inside == Some(b) { -d } else { d };
                best = Some((b, j, tl, sd));
            }
        }
        let (b, j, t, dn) = best?;
        let (u, q) = self.dens.at(self.panels, j, t);
        Some(match self.panels.bodies[b].medium {
            Medium::Dielectric { .. } => u + q * dn,
            Medium::Pec(_) => q * dn - self.p.incident.eval(x),
        })
    }

    fn exterior(&self, x: Vec2) -> C64 {
        let k_b = C64::new(self.p.k_b, 0.0);
        let mut e = C64::new(0.0, 0.0);
        for bp in &self.panels.bodies {
            let all_far = bp.bbox.distance_to(x) > 2.5 * bp.max_len;
            for j in bp.range() {
                if !all_far && is_near(&self.panels.panels[j], x) {
                    near_nodes(&self.panels.panels[j], x, self.rules, &mut |nd: &Node| {
                        let r = x.dist(nd.y);
                        let (g, dny) = g_dny(&radial(k_b, r), x, nd.y, nd.n, r);
                        let (u, q) = self.dens.at(self.panels, j, nd.t);
                        e += nd.w * (dny * u - g * q);
                    });
                } else {
                    for nd in self.far.of(j) {
                        let r = x.dist(nd.y);
                        let (g, dny) = g_dny(&radial(k_b, r), x, nd.y, nd.n, r);
                        e += nd.w * (dny * self.dens.far_u[nd.far] - g * self.dens.far_q[nd.far]);
                    }
                }
            }
        }
        e
    }

    fn interior(&self, x: Vec2, a: usize) -> C64 {
        let bp = &self.panels.bodies[a];
        let Medium::Dielectric { k_i } = bp.medium else { return C64::new(0.0, 0.0) };
        let k_b = C64::new(self.p.k_b, 0.0);
        let kmax = k_i.norm().max(self.p.k_b);
        let all_far = bp.bbox.distance_to(x) > 2.5 * bp.max_len;
        let mut e = C64::new(0.0, 0.0);
        let mut add = |j: usize, nd: &Node| {
            let r = x.dist(nd.y);
            let ri = radial(k_i, r);
            let rd = if kmax * r < 1.0 {
                radial_diff_series(k_b, k_i, r)
            } else {
                let rb = radial(k_b, r);
                Radial { g: rb.g - ri.g, dg: rb.dg - ri.dg, d2g: rb.d2g - ri.d2g }
            };
            let (gi, dnyi) = g_dny(&ri, x, nd.y, nd.n, r);
            let (gd, dnyd) = g_dny(&rd, x, nd.y, nd.n, r);
            let (us, qs) = self.dens.at_node(self.panels, j, nd);
            let (ui, qi) = self.inc.at_node(j, nd.t, nd.far);
            e += nd.w * (-dnyi * us + gi * qs + dnyd * ui - gd * qi);
        };
        for j in bp.range() {
            if !all_far && is_near(&self.panels.panels[j], x) {
                near_nodes(&self.panels.panels[j], x, self.rules, &mut |nd: &Node| add(j, nd));
            } else {
                for nd in self.far.of(j) {
                    add(j, nd);
                }
            }
        }
        e
    }
}
