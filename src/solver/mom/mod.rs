//! Method-of-moments (boundary integral) solver.
//!
//! Midpoint collocation on exact curved panels ([`panels`]) with densities
//! interpolated between neighbouring panel values; the dielectric Müller system
//! and the PEC EFIE/CFIE written for scattered traces ([`system`]); singular,
//! near and far quadrature ([`quad`]); an interruptible dense LU ([`lu`]); and
//! the field from the boundary representations ([`evaluate`]). There is no PML:
//! the Green's function radiates exactly.
//!
//! Choices that differ from the textbook pulse-basis collocation scheme:
//! - densities on source panels are the quadratic interpolants of the panel
//!   values rather than pulses (third- to fourth-order instead of second-order
//!   convergence; needed for `mom_self` and margin on `mie_diel`);
//! - the dielectric unknowns are the scattered traces u_s, q_s rather than the
//!   total ones, so the incident field enters only through difference kernels
//!   (`transparent` is exactly zero);
//! - self panels use a τ³-graded Gauss–Legendre rule on each half instead of
//!   analytic log subtraction (it also covers the log-singular N_b − N_i);
//! - the dense LU is a blocked right-looking LU (trailing updates through
//!   `linalg::gemm`) so that cancelling takes effect within a few ms;
//! - the far-field sampling loop uses a private Hankel asymptotic for J0, Y0,
//!   J1, Y1 at x ≥ 64 ([`evaluate`]; tested to 1e-11 against
//!   `special::bessel::j_y_01_real`);
//! - the memory estimate is `7 MB + 1.5 · 16 N² B + 70 B per output point`,
//!   fitted to peak RSS (within about 20 %).

pub mod evaluate;
pub mod lu;
pub mod panels;
pub mod quad;
pub mod system;

use crate::time::Instant;

use crate::geometry::{min_gap, BodyMaterial};
use crate::problem::Problem;

use super::{Estimate, Issue, Method, SolveContext, SolveError, Solver, SolverMeta, SolverOutput, Stage};

use evaluate::{Densities, Evaluator};
use panels::{panelize, Panels};
use quad::{FarNodes, Rules};
use system::{assemble, IncidentTraces};

pub struct MomSolver;

/// Calibrated cost model (seconds per unit of work, wall clock on the pool).
mod cost {
    /// Per background kernel node of the matrix fill.
    pub const FILL_NODE: f64 = 1.5e-8;
    /// Per n³ of the dense LU.
    pub const LU: f64 = 5e-11;
    /// Per field point × far node.
    pub const EVAL_NODE: f64 = 4.5e-9;
    /// Fixed overhead.
    pub const BASE: f64 = 0.003;
}

/// Work counts of a solve, from the panelisation.
struct Work {
    unknowns: usize,
    fill_nodes: f64,
    lu: f64,
    eval_nodes: f64,
    grid_points: usize,
}

fn work(p: &Problem, panels: &Panels) -> Work {
    let far_q = p.settings.mom.far_quad.max(1) as f64;
    let np = panels.panels.len() as f64;
    // Rows × panels × far nodes, with a dielectric body's own block (difference
    // kernels) counted twice.
    let mut fill = 0.0;
    for a in &panels.bodies {
        let own = if a.is_dielectric() { 2.0 } else { 1.0 };
        let rows = a.count as f64;
        fill += rows * far_q * (np - rows + own * rows);
    }
    let g = p.output_grid();
    let n = panels.n_unknowns as f64;
    // A point inside a dielectric body costs about three exterior nodes per node
    // (two kernels, interpolated incident traces), nine when the body absorbs
    // (complex-argument Hankel functions).
    let interior: f64 = p
        .bodies
        .iter()
        .filter_map(|b| match b.material {
            BodyMaterial::Dielectric { n, .. } => Some(b.contour.area().abs() * if n.im != 0.0 { 8.0 } else { 2.0 }),
            BodyMaterial::Pec => None,
        })
        .sum();
    let pts = g.len() as f64 + interior / (g.dx * g.dx);
    Work { unknowns: panels.n_unknowns, fill_nodes: fill, lu: n * n * n, eval_nodes: pts * np * far_q, grid_points: g.len() }
}

fn seconds(w: &Work) -> (f64, f64, f64) {
    (w.fill_nodes * cost::FILL_NODE, w.lu * cost::LU, w.eval_nodes * cost::EVAL_NODE)
}

fn memory_mb(w: &Work) -> f64 {
    let n = w.unknowns as f64;
    // Calibrated against peak RSS: the process baseline, the dense matrix with
    // its LU workspace (1.5 × 16 N² bytes) and
    // about 70 bytes per output point for the field arrays.
    7.0 + 1.5 * 16.0 * n * n / 1e6 + 70.0 * w.grid_points as f64 / 1e6
}

impl Solver for MomSolver {
    fn method(&self) -> Method {
        Method::Mom
    }

    fn check(&self, p: &Problem) -> Vec<Issue> {
        let mut issues = Vec::new();
        let panels = panelize(p);
        let max = p.settings.mom.max_unknowns;
        if panels.n_unknowns > max {
            issues.push(Issue::error(
                "solver.mom",
                "too_large",
                format!(
                    "MoM {} needs {} unknowns, more than the {} allowed; lower the panels per wavelength or use FDTD or FEM",
                    p.quality.name(),
                    panels.n_unknowns,
                    max
                ),
            ));
        }
        for a in 0..p.bodies.len() {
            for b in a + 1..p.bodies.len() {
                let (ba, bb) = (&p.bodies[a], &p.bodies[b]);
                let l = 2.0 * panels.bodies[a].max_len.max(panels.bodies[b].max_len);
                if ba.bbox.distance(&bb.bbox) >= l || min_gap(ba, bb) >= l {
                    continue;
                }
                issues.push(Issue::warning(
                    format!("elements[{}]", bb.element_index),
                    "mom_small_gap",
                    format!(
                        "“{}” and “{}” are closer than two MoM panels: accuracy reduced near small gaps",
                        ba.name, bb.name
                    ),
                ));
            }
        }
        issues
    }

    fn estimate(&self, p: &Problem) -> Estimate {
        let panels = panelize(p);
        let w = work(p, &panels);
        let (fill, lu, eval) = seconds(&w);
        Estimate {
            unknowns: w.unknowns as u64,
            memory_mb: memory_mb(&w),
            seconds: cost::BASE + fill + lu + eval,
            grid: None,
            detail: format!("{} unknowns · {} panels · no PML needed", w.unknowns, panels.panels.len()),
        }
    }

    fn solve(&self, p: &Problem, ctx: &SolveContext) -> Result<SolverOutput, SolveError> {
        let mut timings = Vec::new();
        let mut warnings = Vec::new();
        let t = Instant::now();
        ctx.stage(Stage::Geometry, (0.02, 0.04));
        let panels = panelize(p);
        let w = work(p, &panels);
        let n = panels.n_unknowns;
        ctx.set_unknowns(n as u64);
        let (s_fill, s_lu, s_eval) = seconds(&w);
        let total = (s_fill + s_lu + s_eval).max(1e-9);
        let f_fill = 0.04 + 0.95 * s_fill / total;
        let f_lu = f_fill + 0.95 * s_lu / total;

        let rules = Rules::new(p.settings.mom.far_quad);
        let far = FarNodes::new(&panels, &rules);
        let inc = IncidentTraces::new(p, &panels, &far);
        timings.push(("panels".to_string(), t.elapsed().as_secs_f64()));
        ctx.checkpoint()?;

        let mut cond = None;
        let x = if n == 0 {
            Vec::new()
        } else {
            let t = Instant::now();
            ctx.stage(Stage::Assemble, (0.04, f_fill));
            let (mat, rhs) = assemble(p, &panels, &far, &rules, &inc, ctx)?;
            timings.push(("fill".to_string(), t.elapsed().as_secs_f64()));
            ctx.checkpoint()?;

            let t = Instant::now();
            ctx.stage(Stage::Solve, (f_fill, f_lu));
            let norm1 = lu::norm1(n, &mat.data);
            let lu = lu::BlockLu::factor(n, mat.data, ctx, |f| ctx.report(0.9 * f))?;
            ctx.checkpoint()?;
            let x = lu.solve(&rhs);
            let c = lu.cond1_estimate(norm1, ctx)?;
            timings.push(("lu".to_string(), t.elapsed().as_secs_f64()));
            cond = Some(c);
            if !x.iter().all(|v| v.re.is_finite() && v.im.is_finite()) {
                return Err(SolveError::Numerical("the MoM system is singular".into()));
            }
            if c > 1e8 {
                warnings.push(format!("MoM system is ill-conditioned (cond ≈ {c:.1e}); results may be inaccurate"));
            }
            x
        };
        ctx.checkpoint()?;

        let t = Instant::now();
        ctx.stage(Stage::Sample, (f_lu, 0.99));
        let dens = Densities::new(&panels, &far, &x);
        let ev = Evaluator { p, panels: &panels, far: &far, rules: &rules, inc: &inc, dens: &dens };
        let grid = p.output_grid();
        let scattered = ev.grid(&grid, ctx)?;
        timings.push(("sample".to_string(), t.elapsed().as_secs_f64()));

        Ok(SolverOutput {
            grid,
            scattered,
            incident: None,
            meta: SolverMeta {
                unknowns: n as u64,
                periods: None,
                converged: true,
                residual: None,
                cond_estimate: cond,
                timings,
                warnings,
            },
        })
    }
}
