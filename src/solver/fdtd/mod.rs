//! Finite-difference time-domain solver (spec §5.1). Stub until wave 2.

use crate::problem::Problem;

use super::{stub_output, Estimate, Issue, Method, SolveContext, SolveError, Solver, SolverOutput};

pub struct FdtdSolver;

impl Solver for FdtdSolver {
    fn method(&self) -> Method {
        Method::Fdtd
    }

    fn check(&self, _p: &Problem) -> Vec<Issue> {
        Vec::new()
    }

    fn estimate(&self, p: &Problem) -> Estimate {
        let s = &p.settings;
        let dx = p.lambda0 / (s.ppw * p.n_max);
        let npml = ((p.pml_um / dx).ceil() as usize).max(s.fdtd.min_pml_cells);
        let nx = (p.interior.width() / dx).floor() as usize + 1 + 2 * npml;
        let ny = (p.interior.height() / dx).floor() as usize + 1 + 2 * npml;
        let cells = (nx * ny) as u64;
        let steps_per_period = (s.ppw * p.n_max / s.fdtd.courant).ceil();
        let periods = 4.0 + 3.0 * p.outer().diag() * p.n_max / p.lambda0;
        Estimate {
            unknowns: cells,
            memory_mb: cells as f64 * 24.0 / 1e6,
            seconds: cells as f64 * steps_per_period * periods * 1.5e-10,
            grid: Some([nx, ny]),
            detail: format!("{}k cells · {} steps/period", cells / 1000, steps_per_period),
        }
    }

    fn solve(&self, p: &Problem, _ctx: &SolveContext) -> Result<SolverOutput, SolveError> {
        Ok(stub_output(p, Method::Fdtd))
    }
}
