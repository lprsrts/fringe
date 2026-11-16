//! FEM solver validation (spec §5.2, §9.2 FEM column) and mesh quality.
//!
//! Fast cases run in `cargo test`; slow ones with `cargo test --release -- --ignored`.
//! The performance test asserts only with `BEAM_PERF=1` (release build).

mod common;

use std::time::Instant;

use beam_core::analytic::cases::{self, case_scene, reference, Status};
use beam_core::analytic::metrics::flux_balance;
use beam_core::problem::compile;
use beam_core::scene::{examples, Scene};
use beam_core::solver::fem::mesh_report;
use beam_core::solver::{solve, solver_for, Method, Part, Quality, SolveContext, SolveError};
use common::assert_case;

const FEM: Method = Method::Fem;

fn fem_case(id: &str) {
    let r = assert_case(id, FEM, Quality::Final);
    assert_eq!(r.status, Status::Pass, "{id}: {r:?}");
}

#[test]
fn fem_mie_pec() {
    fem_case("mie_pec");
}

#[test]
fn fem_mie_pec_37() {
    fem_case("mie_pec_37");
}

#[test]
fn fem_mie_diel() {
    fem_case("mie_diel");
}

#[test]
fn fem_mie_lossy() {
    fem_case("mie_lossy");
}

#[test]
fn fem_slab_airy_0() {
    fem_case("slab_airy_0");
}

#[test]
fn fem_mirror_0() {
    fem_case("mirror_0");
}

#[test]
fn fem_free_beam() {
    fem_case("free_beam");
}

#[test]
fn fem_transparent() {
    fem_case("transparent");
}

#[test]
#[ignore]
fn fem_mie_high_index() {
    fem_case("mie_high_index");
}

#[test]
#[ignore]
fn fem_slab_airy_30() {
    fem_case("slab_airy_30");
}

#[test]
#[ignore]
fn fem_slab_lossy() {
    fem_case("slab_lossy");
}

#[test]
#[ignore]
fn fem_mirror_25() {
    fem_case("mirror_25");
}

#[test]
#[ignore]
fn fem_order_observed() {
    fem_case("fem_order");
}

#[test]
#[ignore]
fn fem_pml_hygiene() {
    fem_case("pml_hygiene");
}

/// The `balance` case. With the default final output sampling (12 per λ) the
/// shared metric itself is off by ~1.7e-2 even for the exact Mie field (its
/// absorption integral uses a staircase of grid nodes inside the cylinder), so
/// the FEM run is checked against the metric applied to the exact field on the
/// same grid, and the case bound is checked at a finer output sampling where the
/// metric is accurate enough.
#[test]
fn fem_balance() {
    let r = cases::run_case("balance", FEM, Quality::Final).unwrap();
    eprintln!("balance (case runner): {:?} {:?} {}", r.error, r.status, r.detail);

    let tol = cases::spec("balance").unwrap().fem.unwrap();
    for (oppw, require_bound) in [(12.0, false), (48.0, true)] {
        let mut s = case_scene("balance").unwrap();
        s.solver.method = FEM;
        s.solver.output.final_ppw = Some(oppw);
        let mut f = solve(&s, Quality::Final, &SolveContext::new()).unwrap();
        let rect = f.scene.domain.rect().expand(-0.5);
        let fem = flux_balance(&f, rect);
        let exact_fn = reference("balance", &f.scene).unwrap();
        let g = f.grid;
        f.total = (0..g.len()).map(|i| exact_fn(g.point(i % g.nx, i / g.nx))).collect();
        let exact = flux_balance(&f, rect);
        eprintln!(
            "output ppw {oppw}: FEM residual {:.3e} (inflow {:.5}, absorbed {:.5}); exact field {:.3e}",
            fem.residual(),
            fem.inflow,
            fem.absorbed,
            exact.residual()
        );
        let scale = exact.absorbed.abs();
        assert!((fem.inflow - exact.inflow).abs() / scale < 1e-3, "inflow differs from the exact field's");
        assert!((fem.absorbed - exact.absorbed).abs() / scale < 1e-3, "absorption differs from the exact field's");
        if require_bound {
            assert!(fem.residual() <= tol, "balance {:.3e} > {tol:.1e}", fem.residual());
        }
    }
}

/// P2 elements also work (not the default).
#[test]
fn fem_p2_mie_diel() {
    let mut s = case_scene("mie_diel").unwrap();
    s.solver.method = FEM;
    s.solver.fem.order = 2;
    let f = solve(&s, Quality::Final, &SolveContext::new()).unwrap();
    let e = cases::field_error("mie_diel", &f);
    eprintln!("P2 mie_diel error {e:.3e}");
    assert!(e < 1.5e-2, "P2 error {e}");
}

fn mesh_scenes() -> Vec<(String, Scene)> {
    let mut out: Vec<(String, Scene)> = examples::EXAMPLES.iter().map(|e| (e.name.to_string(), examples::example(e.name).unwrap())).collect();
    for id in ["mie_pec", "mie_diel", "mie_high_index", "slab_airy_0", "mirror_0", "free_beam"] {
        out.push((id.to_string(), case_scene(id).unwrap()));
    }
    out
}

/// Every triangle of every example and case mesh has all angles ≥ 18°; arc edges
/// lie on their arcs; dielectric triangles cover the bodies' areas.
#[test]
fn fem_mesh_quality() {
    for (name, mut s) in mesh_scenes() {
        s.solver.method = FEM;
        for q in [Quality::Preview, Quality::Final] {
            let p = compile(&s, q).unwrap();
            let m = mesh_report(&p).unwrap();
            let diel_area: f64 = p
                .bodies
                .iter()
                .filter(|b| !b.is_pec())
                .map(|b| b.contour.area().abs())
                .sum();
            eprintln!(
                "{name} {}: {} vertices (+{} refined), {} triangles, min angle {:.2}°, {} unknowns (est {:.0})",
                q.name(),
                m.vertices,
                m.refined_vertices,
                m.triangles,
                m.min_angle_deg,
                m.free_dofs,
                m.estimated_dofs
            );
            assert!(m.min_angle_deg >= 18.0, "{name} {}: min angle {}", q.name(), m.min_angle_deg);
            assert!(m.warnings.is_empty(), "{name}: {:?}", m.warnings);
            assert!(m.max_arc_error < 1e-9, "{name}: arc error {}", m.max_arc_error);
            // Chords cut arcs, so the straight-sided area differs slightly.
            assert!(
                (m.dielectric_area - diel_area).abs() <= 1e-2 * diel_area.max(1.0),
                "{name}: dielectric area {} vs {}",
                m.dielectric_area,
                diel_area
            );
            let est = m.estimated_dofs;
            assert!(est / (m.dofs as f64) < 1.25 && (m.dofs as f64) / est < 1.25, "{name}: DOF estimate {est} vs {}", m.dofs);
        }
    }
}

/// Every example solves with FEM at preview quality to a finite field.
#[test]
fn fem_examples_preview() {
    for name in examples::EXAMPLES.iter().map(|e| e.name) {
        let mut s = examples::example(name).unwrap();
        s.solver.method = FEM;
        let f = solve(&s, Quality::Preview, &SolveContext::new()).unwrap_or_else(|e| panic!("{name}: {e}"));
        assert!(f.meta.solver.warnings.is_empty(), "{name}: {:?}", f.meta.solver.warnings);
        assert!((0..f.grid.len()).all(|i| {
            let v = f.value(Part::Scattered, i);
            v.re.is_finite() && v.im.is_finite()
        }));
    }
}

/// A cancelled context stops the solve before the factorisation.
#[test]
fn fem_cancel() {
    let mut s = examples::default();
    s.solver.method = FEM;
    let ctx = SolveContext::new();
    ctx.cancel_flag().store(true, std::sync::atomic::Ordering::SeqCst);
    let t = Instant::now();
    let r = solve(&s, Quality::Final, &ctx);
    assert!(matches!(r, Err(SolveError::Cancelled)), "{:?}", r.err());
    assert!(t.elapsed().as_secs_f64() < 0.2);
}

/// Too many unknowns is a final-only capability error.
#[test]
fn fem_check_too_large() {
    let mut s = examples::default();
    s.solver.method = FEM;
    s.solver.fem.final_ppw = Some(60.0);
    let p = compile(&s, Quality::Final).unwrap();
    let issues = solver_for(FEM).check(&p);
    assert!(issues.iter().any(|i| i.code == "too_large" && i.quality == Some(Quality::Final)), "{issues:?}");
    let p = compile(&s, Quality::Preview).unwrap();
    assert!(solver_for(FEM).check(&p).is_empty());
}

/// Default scene: preview ≤ 1.5 s, final ≤ 12 s and the time estimate within 2×.
/// Asserted with BEAM_PERF=1 in a release build.
#[test]
#[ignore]
fn fem_perf_default_scene() {
    let assert_perf = std::env::var("BEAM_PERF").as_deref() == Ok("1");
    let mut s = examples::default();
    s.solver.method = FEM;
    // Warm up the thread pool and allocator.
    solve(&s, Quality::Preview, &SolveContext::new()).unwrap();
    for (q, limit) in [(Quality::Preview, 1.5), (Quality::Final, 12.0)] {
        let p = compile(&s, q).unwrap();
        let est = solver_for(FEM).estimate(&p);
        let t = Instant::now();
        let f = solve(&s, q, &SolveContext::new()).unwrap();
        let dt = t.elapsed().as_secs_f64();
        eprintln!(
            "default {}: {dt:.2} s (estimate {:.2} s, {:.0} MB), {} unknowns (estimate {}), timings {:?}",
            q.name(),
            est.seconds,
            est.memory_mb,
            f.meta.solver.unknowns,
            est.unknowns,
            f.meta.solver.timings
        );
        if assert_perf {
            assert!(dt <= limit, "{} took {dt:.2} s > {limit} s", q.name());
            assert!(est.seconds / dt <= 2.0 && dt / est.seconds <= 2.0, "estimate {:.2} s vs {dt:.2} s", est.seconds);
        }
    }
}
