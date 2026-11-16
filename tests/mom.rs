//! MoM solver validation (spec §9.2, MoM column) and solver-specific checks.

mod common;

use beam_core::analytic::cases::{case_scene, field_error, reference};
use beam_core::analytic::metrics::flux_balance;
use beam_core::solver::{solve, Method, Quality, SolveContext};

fn mom_scene(id: &str, ppw: Option<f64>, out_ppw: Option<f64>) -> beam_core::scene::Scene {
    let mut s = case_scene(id).unwrap();
    s.solver.method = Method::Mom;
    s.solver.mom.final_ppw = ppw;
    s.solver.output.final_ppw = out_ppw;
    s
}

#[test]
#[ignore]
fn explore() {
    for id in ["mie_diel", "mie_lossy"] {
        for ppw in [8.0, 12.0, 16.0, 24.0, 32.0] {
            let f = solve(&mom_scene(id, Some(ppw), None), Quality::Final, &SolveContext::new()).unwrap();
            let e = field_error(id, &f);
            eprintln!("{id} ppw {ppw}: err {e:.3e}  t {:?}", f.meta.solver.timings);
        }
    }
    for out in [12.0, 24.0, 48.0] {
        let mut f = solve(&mom_scene("balance", Some(16.0), Some(out)), Quality::Final, &SolveContext::new()).unwrap();
        let fb = flux_balance(&f, f.scene.domain.rect().expand(-0.5));
        let r = reference("balance", &f.scene).unwrap();
        let g = f.grid;
        for idx in 0..g.len() {
            f.total[idx] = r(g.point(idx % g.nx, idx / g.nx));
        }
        let fe = flux_balance(&f, f.scene.domain.rect().expand(-0.5));
        eprintln!("out {out}: mom residual {:.3e}  exact residual {:.3e}", fb.residual(), fe.residual());
    }
}
