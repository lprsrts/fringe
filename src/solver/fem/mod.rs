//! Finite-element solver: Lagrange P_p triangles (p = 2 or 3),
//! isoparametric along arcs, complex-stretch PML, sparse LU.
//!
//! The unknown is the scattered field E_s on the outer rectangle (interior + PML)
//! with E_s = 0 on its edge and E_s = −E_inc on PEC boundaries (PEC bodies are holes
//! in the mesh). The sparse LU factorisation cannot be interrupted: a cancel
//! request is honoured before and after it, not during it, and its entry in
//! `SolverMeta::timings` is labelled "factor (uninterruptible)". Everything else
//! (meshing, assembly chunks, sampling rows) checks the cancel flag.
//!
//! Files: `mesh.rs` (spade CDT and refinement), `element.rs` (reference element),
//! `pml.rs` (stretching), `assemble.rs` (DOFs and the sparse system), `sample.rs`
//! (evaluation on the output grid).

mod assemble;
mod element;
mod mesh;
mod pml;
mod sample;
#[cfg(test)]
mod tests;

use crate::time::Instant;

use crate::linalg::SparseLu;
use crate::problem::Problem;
use crate::types::C64;

use super::{Estimate, Issue, Method, Quality, SolveContext, SolveError, Solver, SolverMeta, SolverOutput, Stage};

pub struct FemSolver;

/// DOF limits per quality.
const MAX_DOFS_PREVIEW: f64 = 600e3;
const MAX_DOFS_FINAL: f64 = 2.5e6;

/// Calibration constants (release build, M-series, 8+ cores; measured on the
/// default scene: preview 50k unknowns ≈ 0.6–0.9 s and 480 MB peak, final 140k
/// unknowns ≈ 2.2–3.5 s and 1.7 GB peak).
/// Memory: C_MEM MB · N · log2(N) for N system unknowns.
const C_MEM: f64 = 6.5e-4;
/// Time: C_T s · N^1.4.
const C_T: f64 = 2.0e-7;

/// Estimated number of DOFs (all nodes) of the mesh `mesh::build` makes: about
/// p² · (2/√3)/h² per unit area plus the constraint points along contours. Every
/// segment gets at least one constraint point, so a polygon with many short
/// edges costs more than its perimeter suggests.
pub(crate) fn estimate_dofs(p: &Problem) -> f64 {
    let order = p.settings.fem.order.clamp(1, 3) as f64;
    let h_b = mesh::background_h(p, order);
    let per_area = |h: f64| order * order * 2.0 / 3f64.sqrt() / (h * h);
    let mut total = p.outer().width() * p.outer().height() * per_area(h_b);
    for (b, body) in p.bodies.iter().enumerate() {
        let area = body.contour.area().abs();
        total -= area * per_area(h_b);
        let h_in = mesh::body_h(p, b, order);
        if let Some(h) = h_in {
            total += area * per_area(h);
        }
        // Constraint points along the contour, as `mesh::build` places them.
        let h_bnd = h_in.map_or(h_b, |h| h.min(h_b));
        let points: f64 = body.contour.segments.iter().map(|s| (s.length() / h_bnd).ceil().max(1.0)).sum();
        total += order * order * points;
    }
    total.max(1.0)
}

/// Peak memory for `n` system unknowns: the factorisation plus, per output
/// point, the sampled field and the pipeline's total, incident and region
/// arrays (70 B, as for MoM).
fn memory_mb(p: &Problem, n: f64) -> f64 {
    C_MEM * n * n.max(2.0).log2() + 70.0 * p.output_grid().len() as f64 / 1e6
}

fn max_dofs(q: Quality) -> f64 {
    match q {
        Quality::Preview => MAX_DOFS_PREVIEW,
        Quality::Final => MAX_DOFS_FINAL,
    }
}

/// Estimated size of the global system: P3 face DOFs (2 per vertex, 2/9 of all)
/// are condensed out per element.
pub(crate) fn estimate_unknowns(p: &Problem) -> f64 {
    let d = estimate_dofs(p);
    if p.settings.fem.order >= 3 {
        d * 7.0 / 9.0
    } else {
        d
    }
}

impl Solver for FemSolver {
    fn method(&self) -> Method {
        Method::Fem
    }

    fn check(&self, p: &Problem) -> Vec<Issue> {
        let mut issues = Vec::new();
        let dofs = estimate_dofs(p);
        let limit = max_dofs(p.quality);
        if dofs > limit {
            issues.push(
                Issue::error(
                    "solver.fem",
                    "too_large",
                    format!(
                        "FEM {} needs about {:.0}k unknowns, more than the {:.0}k limit",
                        p.quality.name(),
                        dofs / 1e3,
                        limit / 1e3
                    ),
                )
                .for_quality(p.quality),
            );
        }
        issues
    }

    fn estimate(&self, p: &Problem) -> Estimate {
        let n = estimate_unknowns(p).max(2.0);
        Estimate {
            unknowns: n as u64,
            memory_mb: memory_mb(p, n),
            seconds: C_T * n.powf(1.4),
            grid: None,
            detail: format!("{}k unknowns · P{}", n as u64 / 1000, p.settings.fem.order),
        }
    }

    fn solve(&self, p: &Problem, ctx: &SolveContext) -> Result<SolverOutput, SolveError> {
        let order = p.settings.fem.order as usize;
        if !(2..=3).contains(&order) {
            return Err(SolveError::Unsupported(format!("FEM order {order} is not supported (2 or 3)")));
        }
        let mut timings = Vec::new();
        let mut t = Instant::now();
        let mut lap = |name: &str, timings: &mut Vec<(String, f64)>| {
            timings.push((name.to_string(), t.elapsed().as_secs_f64()));
            t = Instant::now();
        };

        ctx.stage(Stage::Geometry, (0.02, 0.10));
        let mesh = mesh::build(p, order)?;
        lap("mesh", &mut timings);
        ctx.checkpoint()?;
        let el = element::RefElement::new(order);
        let dofs = assemble::number_dofs(p, &mesh, &el);
        ctx.set_unknowns(dofs.n_free as u64);
        lap("dofs", &mut timings);
        ctx.checkpoint()?;
        // The estimate that let this solve start is a model; refuse the real
        // mesh if it is over the limits before factoring it.
        let n = dofs.n_free as f64;
        let need_mb = memory_mb(p, n);
        if need_mb > p.settings.memory_limit_mb {
            return Err(SolveError::TooLarge { need_mb, limit_mb: p.settings.memory_limit_mb });
        }
        if n > max_dofs(p.quality) {
            return Err(SolveError::Unsupported(format!(
                "the FEM {} mesh has {:.0}k unknowns, more than the {:.0}k limit",
                p.quality.name(),
                n / 1e3,
                max_dofs(p.quality) / 1e3
            )));
        }

        ctx.stage(Stage::Assemble, (0.10, 0.25));
        let mut sys = assemble::assemble(p, &mesh, &el, &dofs, ctx)?;
        lap("assemble", &mut timings);
        ctx.checkpoint()?;

        ctx.stage(Stage::Solve, (0.25, 0.92));
        let source_free = sys.rhs.iter().all(|v| v.re == 0.0 && v.im == 0.0)
            && dofs.dirichlet.iter().all(|d| d.is_none_or(|v| v.re == 0.0 && v.im == 0.0));
        let x = if source_free || dofs.n_free == 0 {
            // No source: the scattered field is exactly zero.
            vec![C64::new(0.0, 0.0); dofs.n_free]
        } else {
            let lu = SparseLu::factor(std::mem::take(&mut sys.matrix)).map_err(|e| SolveError::Numerical(format!("FEM factorisation: {e}")))?;
            // The factorisation cannot be interrupted; the label says so in the meta.
            lap("factor (uninterruptible)", &mut timings);
            ctx.checkpoint()?;
            lu.solve(&sys.rhs)
        };
        lap("solve", &mut timings);
        if x.iter().any(|v| !v.re.is_finite() || !v.im.is_finite()) {
            return Err(SolveError::Numerical("FEM solution is not finite".into()));
        }
        let mut u: Vec<C64> = (0..dofs.n)
            .map(|i| match (dofs.dirichlet[i], dofs.free[i]) {
                (Some(v), _) => v,
                (None, f) if (f as usize) < x.len() => x[f as usize],
                _ => C64::new(0.0, 0.0),
            })
            .collect();
        assemble::recover_faces(&el, &dofs, &sys.recovery, &mut u);
        ctx.checkpoint()?;

        ctx.stage(Stage::Sample, (0.92, 1.0));
        let grid = p.output_grid();
        let scattered = sample::sample(&mesh, &el, &dofs, &u, &grid, ctx);
        ctx.checkpoint()?;
        lap("sample", &mut timings);

        let mut warnings = mesh.warnings.clone();
        warnings.extend(p.incident.warnings.iter().cloned());
        Ok(SolverOutput {
            grid,
            scattered,
            incident: None,
            meta: SolverMeta {
                unknowns: dofs.n_free as u64,
                periods: None,
                converged: true,
                residual: None,
                cond_estimate: None,
                timings,
                warnings,
            },
        })
    }
}
