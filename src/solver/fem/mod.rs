//! Finite-element solver (spec §5.2). Stub until wave 2.

use crate::geometry::BodyMaterial;
use crate::problem::Problem;

use super::{stub_output, Estimate, Issue, Method, SolveContext, SolveError, Solver, SolverOutput};

pub struct FemSolver;

impl Solver for FemSolver {
    fn method(&self) -> Method {
        Method::Fem
    }

    fn check(&self, _p: &Problem) -> Vec<Issue> {
        Vec::new()
    }

    fn estimate(&self, p: &Problem) -> Estimate {
        let s = &p.settings;
        let order = s.fem.order as f64;
        // Nodes of a P_p mesh with edge h: about p² · 2/√3 per h² of area.
        let h_b = order * p.lambda_b() / s.ppw;
        let mut dofs = p.outer().width() * p.outer().height() / (h_b * h_b);
        for b in &p.bodies {
            if let BodyMaterial::Dielectric { n, .. } = b.material {
                let area = b.contour.area().abs();
                let ratio = (n.re / p.n_b).powi(2);
                dofs += area / (h_b * h_b) * (ratio - 1.0);
            }
        }
        let dofs = (dofs * order * order * 2.0 / 3f64.sqrt()) as u64;
        let d = dofs.max(1) as f64;
        Estimate {
            unknowns: dofs,
            memory_mb: 0.25e-3 * d * d.log2(),
            seconds: 2e-7 * d.powf(1.4),
            grid: None,
            detail: format!("{}k DOFs · P{}", dofs / 1000, s.fem.order),
        }
    }

    fn solve(&self, p: &Problem, _ctx: &SolveContext) -> Result<SolverOutput, SolveError> {
        Ok(stub_output(p, Method::Fem))
    }
}
