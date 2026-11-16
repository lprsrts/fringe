//! The boundary-integral system, written for the scattered traces.
//!
//! The unknowns of a dielectric body are the scattered traces
//! `u_s = E_s|_C` and `q_s = ∂_n E_s|_C` (the total traces minus the incident
//! ones); a PEC body keeps the total `q = ∂_n E|_C`. Substituting
//! `u = u_inc + u_s`, `q = q_inc + q_s` into the Müller equations and
//! using Green's identity for the incident field (`D_b u_inc − S_b q_inc = 0`
//! outside a body) gives, for a dielectric body A:
//!
//! ```text
//! u_s + (D_i − D_b) u_s + (S_b − S_i) q_s − Σ_{B≠A} (D_b u_sB − S_b q_sB) = −[(D_i − D_b) u_inc + (S_b − S_i) q_inc]
//! q_s + (K′_b − K′_i) q_s − (N_b − N_i) u_s − Σ_{B≠A} (N_b u_sB − K′_b q_sB) = −[(K′_b − K′_i) q_inc − (N_b − N_i) u_inc]
//! ```
//!
//! with `u_sB = 0` and `q_sB = q_B` for a PEC body B. The operator matrix is
//! the usual Müller one; only the right-hand side moves. The incident traces
//! enter through the same quadrature as the matrix, sampled exactly at the
//! nodes, so a body with `ε = ε_b` has an exactly zero right-hand side and
//! exactly zero scattered field. PEC rows are unchanged: EFIE `S_b q + … = u_inc`, MFIE
//! `q/2 + K′_b q + … = q_inc`, CFIE = MFIE + β·EFIE.
//!
//! **Discretisation.** The unknowns are the densities at the panel collocation
//! points (the panel midpoints), collocated there. Instead of a pulse
//! (piecewise-constant) density, each source panel integrates the quadratic
//! interpolant through its own and its two neighbours' midpoint values on the
//! same smooth piece of the contour (linear beside a corner); see
//! [`Panels::recon`]. The operators, quadrature and unknown count are those of
//! a pulse scheme, but the error falls like h³–h⁴ instead of h²: on
//! `mie_diel` at 16 panels per λ the field error drops from 4.7e-3 (pulses) to
//! 1.1e-4.
//!
//! Every row has the same two-row pattern for a source panel with kernel K
//! (`G_b − G_i` on a dielectric body's own panels, `G_b` otherwise):
//! row "u" (dielectric) or EFIE (PEC): `−∂_{n_y}K · u + K · q`;
//! row "q" (dielectric) or MFIE (PEC): `−∂_{n_x}∂_{n_y}K · u + ∂_{n_x}K · q`.

use std::sync::atomic::{AtomicUsize, Ordering};

use rayon::prelude::*;

use crate::linalg::DenseMatrix;
use crate::problem::Problem;
use crate::solver::{SolveContext, SolveError};
use crate::special::greens::{kernels, radial, radial_diff};
use crate::special::quadrature::gauss_legendre;
use crate::types::{Vec2, C64};

use super::panels::{Medium, Panels, PecRows};
use super::quad::{visit, FarNodes, Rules};

/// Points per panel at which the incident traces are sampled for interpolation.
pub const SAMPLES: usize = 8;

/// The incident field's traces on the panels: exact at collocation points and
/// far nodes, and by barycentric interpolation from `SAMPLES` Gauss–Legendre
/// samples anywhere else on a panel.
pub struct IncidentTraces {
    /// (u_inc, q_inc) at each collocation point.
    pub colloc: Vec<(C64, C64)>,
    /// (u_inc, q_inc) at each far node.
    pub far: Vec<(C64, C64)>,
    samples: Vec<[(C64, C64); SAMPLES]>,
    nodes: [f64; SAMPLES],
    bary: [f64; SAMPLES],
}

impl IncidentTraces {
    pub fn new(p: &Problem, panels: &Panels, far: &FarNodes) -> IncidentTraces {
        let gl = gauss_legendre(SAMPLES);
        let mut nodes = [0.0; SAMPLES];
        for (k, (t, _)) in gl.on(0.0, 1.0).enumerate() {
            nodes[k] = t;
        }
        let mut bary = [0.0; SAMPLES];
        for k in 0..SAMPLES {
            let mut prod = 1.0;
            for m in 0..SAMPLES {
                if m != k {
                    prod *= nodes[k] - nodes[m];
                }
            }
            bary[k] = 1.0 / prod;
        }
        let trace = |y: Vec2, n: Vec2| {
            let (e, g) = p.incident.eval_grad(y);
            (e, g[0] * n.x + g[1] * n.y)
        };
        let colloc = panels.panels.par_iter().map(|q| trace(q.mid, q.normal)).collect();
        let farv = far.nodes.par_iter().map(|nd| trace(nd.y, nd.n)).collect();
        let samples = panels
            .panels
            .par_iter()
            .map(|q| {
                let mut s = [(C64::new(0.0, 0.0), C64::new(0.0, 0.0)); SAMPLES];
                for (k, v) in s.iter_mut().enumerate() {
                    *v = trace(q.point(nodes[k]), q.normal_at(nodes[k]));
                }
                s
            })
            .collect();
        IncidentTraces { colloc, far: farv, samples, nodes, bary }
    }

    /// (u_inc, q_inc) at parameter t of panel j.
    #[inline]
    pub fn at(&self, j: usize, t: f64) -> (C64, C64) {
        let s = &self.samples[j];
        let mut num_u = C64::new(0.0, 0.0);
        let mut num_q = C64::new(0.0, 0.0);
        let mut den = 0.0;
        for ((&node, &b), &(u, q)) in self.nodes.iter().zip(&self.bary).zip(s) {
            let d = t - node;
            if d == 0.0 {
                return (u, q);
            }
            let c = b / d;
            num_u += u * c;
            num_q += q * c;
            den += c;
        }
        (num_u / den, num_q / den)
    }

    /// The traces at a quadrature node of panel j.
    #[inline]
    pub fn at_node(&self, j: usize, t: f64, far: usize) -> (C64, C64) {
        if far != usize::MAX {
            self.far[far]
        } else {
            self.at(j, t)
        }
    }
}

/// Raw pointer to the column-major matrix, written by rows from parallel tasks.
/// Each task writes only its own rows, so the writes never alias.
#[derive(Clone, Copy)]
struct MatPtr(*mut C64);
unsafe impl Send for MatPtr {}
unsafe impl Sync for MatPtr {}

impl MatPtr {
    #[inline]
    fn at(self, k: usize) -> *mut C64 {
        // SAFETY: callers stay within the allocation.
        unsafe { self.0.add(k) }
    }
}

/// The incident right-hand-side terms integrated over one source panel.
#[derive(Default, Clone, Copy)]
struct Sums {
    rhs_u: C64,
    rhs_q: C64,
}

/// Fills the matrix and right-hand side. Rows are computed in parallel blocks,
/// with a cancellation check per block.
pub fn assemble(
    p: &Problem,
    panels: &Panels,
    far: &FarNodes,
    rules: &Rules,
    inc: &IncidentTraces,
    ctx: &SolveContext,
) -> Result<(DenseMatrix, Vec<C64>), SolveError> {
    let n = panels.n_unknowns;
    let mut mat = DenseMatrix::zeros(n);
    let mut rhs = vec![C64::new(0.0, 0.0); n];
    let ptr = MatPtr(mat.data.as_mut_ptr());
    let rhs_ptr = MatPtr(rhs.as_mut_ptr());
    let k_b = C64::new(p.k_b, 0.0);
    let np = panels.panels.len();
    let done = AtomicUsize::new(0);
    const BLOCK: usize = 8;

    (0..np.div_ceil(BLOCK)).into_par_iter().try_for_each(|blk| {
        if ctx.is_cancelled() {
            return Err(SolveError::Cancelled);
        }
        let mut row_a = vec![C64::new(0.0, 0.0); n];
        let mut row_b = vec![C64::new(0.0, 0.0); n];
        for i in blk * BLOCK..((blk + 1) * BLOCK).min(np) {
            row_a.iter_mut().for_each(|v| *v = C64::new(0.0, 0.0));
            row_b.iter_mut().for_each(|v| *v = C64::new(0.0, 0.0));
            let pi = &panels.panels[i];
            let a = &panels.bodies[pi.body];
            let (x, n_x) = (pi.mid, pi.normal);
            let mut rhs_a = C64::new(0.0, 0.0);
            let mut rhs_b = C64::new(0.0, 0.0);
            for (bi, bp) in panels.bodies.iter().enumerate() {
                // The difference kernel on a dielectric body's own panels.
                let k_i = match (bi == pi.body, a.medium) {
                    (true, Medium::Dielectric { k_i }) => Some(k_i),
                    _ => None,
                };
                let diel_b = bp.is_dielectric();
                for j in bp.range() {
                    let mut s = Sums::default();
                    let mut f = |nd: &super::quad::Node| {
                        let r = x.dist(nd.y);
                        let rad = match k_i {
                            Some(k_i) => radial_diff(k_b, k_i, r),
                            None => radial(k_b, r),
                        };
                        let kk = kernels(&rad, x, nd.y, n_x, nd.n);
                        let w = nd.w;
                        if k_i.is_some() {
                            let (ui, qi) = inc.at_node(j, nd.t, nd.far);
                            s.rhs_u += w * (-kk.dn_y * ui + kk.g * qi);
                            s.rhs_q += w * (-kk.dn_xy * ui + kk.dn_x * qi);
                        }
                        for (k, wk) in panels.recon(j, nd.t) {
                            if wk == 0.0 {
                                continue;
                            }
                            let local = k - bp.first;
                            let ww = w * wk;
                            let qc = bp.q_off + local;
                            row_a[qc] += ww * kk.g;
                            row_b[qc] += ww * kk.dn_x;
                            if diel_b {
                                let uc = bp.u_off.unwrap() + local;
                                row_a[uc] -= ww * kk.dn_y;
                                row_b[uc] -= ww * kk.dn_xy;
                            }
                        }
                    };
                    visit(panels, far, rules, j, x, j == i, &mut f);
                    rhs_a -= s.rhs_u;
                    rhs_b -= s.rhs_q;
                }
            }
            let local = i - a.first;
            let (ui, qi) = inc.colloc[i];
            // SAFETY: rows of panel i are written only by this task.
            unsafe {
                match a.medium {
                    Medium::Dielectric { .. } => {
                        let ru = a.u_off.unwrap() + local;
                        let rq = a.q_off + local;
                        row_a[ru] += 1.0;
                        row_b[rq] += 1.0;
                        for (c, (&va, &vb)) in row_a.iter().zip(&row_b).enumerate() {
                            *ptr.at(c * n + ru) = va;
                            *ptr.at(c * n + rq) = vb;
                        }
                        *rhs_ptr.at(ru) = rhs_a;
                        *rhs_ptr.at(rq) = rhs_b;
                    }
                    Medium::Pec(PecRows::Efie) => {
                        let r = a.q_off + local;
                        for (c, &va) in row_a.iter().enumerate() {
                            *ptr.at(c * n + r) = va;
                        }
                        *rhs_ptr.at(r) = ui;
                    }
                    Medium::Pec(PecRows::Cfie { beta }) => {
                        let r = a.q_off + local;
                        row_b[r] += 0.5;
                        for (c, (&va, &vb)) in row_a.iter().zip(&row_b).enumerate() {
                            *ptr.at(c * n + r) = vb + beta * va;
                        }
                        *rhs_ptr.at(r) = qi + beta * ui;
                    }
                }
            }
        }
        let d = done.fetch_add(BLOCK, Ordering::Relaxed) + BLOCK;
        ctx.report(d as f64 / np as f64);
        Ok(())
    })?;
    Ok((mat, rhs))
}
