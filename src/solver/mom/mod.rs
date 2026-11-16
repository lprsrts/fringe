//! Method-of-moments (boundary integral) solver (spec §5.3).
//!
//! Pulse basis with midpoint collocation on exact curved panels
//! ([`panels`]); the dielectric Müller system and the PEC EFIE/CFIE written for
//! scattered traces ([`system`]); singular, near and far quadrature
//! ([`quad`]); dense LU; and the field from the boundary representations
//! ([`evaluate`]). There is no PML: the Green's function radiates exactly.

pub mod evaluate;
pub mod panels;
pub mod quad;
pub mod system;

use std::time::Instant;

use crate::geometry::min_gap;
use crate::linalg::DenseLu;
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
    pub const FILL_NODE: f64 = 6e-9;
    /// Per n³ of the dense LU.
    pub const LU: f64 = 2.5e-10;
    /// Per field point × far node.
    pub const EVAL_NODE: f64 = 6e-9;
    /// Fixed overhead.
    pub const BASE: f64 = 0.01;
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
    // Points inside dielectric bodies cost two kernels per node.
    let interior_area: f64 = p.bodies.iter().filter(|b| !b.is_pec()).map(|b| b.contour.area().abs()).sum();
    let pts = g.len() as f64 + interior_area / (g.dx * g.dx);
    Work { unknowns: panels.n_unknowns, fill_nodes: fill, lu: n * n * n, eval_nodes: pts * np * far_q, grid_points: g.len() }
}

fn seconds(w: &Work) -> (f64, f64, f64) {
    (w.fill_nodes * cost::FILL_NODE, w.lu * cost::LU, w.eval_nodes * cost::EVAL_NODE)
}

fn memory_mb(w: &Work) -> f64 {
    let n = w.unknowns as f64;
    // The matrix (×1.2 for the LU workspace, spec §5.3) plus the grid arrays.
    16.0 * n * n / 1e6 * 1.2 + w.grid_points as f64 * 64.0 / 1e6
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
            let norm1 = mat.norm1();
            let lu = DenseLu::factor(mat);
            ctx.checkpoint()?;
            let x = lu.solve(&rhs);
            let c = lu.cond1_estimate(norm1);
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
