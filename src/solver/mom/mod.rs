//! Method-of-moments (boundary integral) solver (spec §5.3). Stub until wave 2.

use crate::geometry::BodyMaterial;
use crate::problem::Problem;

use super::{stub_output, Estimate, Issue, Method, SolveContext, SolveError, Solver, SolverOutput};

pub struct MomSolver;

impl Solver for MomSolver {
    fn method(&self) -> Method {
        Method::Mom
    }

    fn check(&self, _p: &Problem) -> Vec<Issue> {
        Vec::new()
    }

    fn estimate(&self, p: &Problem) -> Estimate {
        let s = &p.settings;
        let mut n = 0.0;
        for b in &p.bodies {
            let (lambda_loc, per_panel) = match b.material {
                BodyMaterial::Pec => (p.lambda_b(), 1.0),
                BodyMaterial::Dielectric { n, .. } => (p.lambda0 / p.n_b.max(n.re), 2.0),
            };
            n += per_panel * (b.contour.length() / (lambda_loc / s.ppw)).ceil();
        }
        let out = p.output_grid().len() as f64;
        Estimate {
            unknowns: n as u64,
            memory_mb: 16.0 * n * n / 1e6 * 1.2,
            seconds: 2e-8 * n * n + 3e-11 * n * n * n + 5e-8 * n * out,
            grid: None,
            detail: format!("{} unknowns", n as u64),
        }
    }

    fn solve(&self, p: &Problem, _ctx: &SolveContext) -> Result<SolverOutput, SolveError> {
        Ok(stub_output(p, Method::Mom))
    }
}
