//! FEM solver validation and mesh quality.
//!
//! Fast cases run in `cargo test`; slow ones with `cargo test --release -- --ignored`.
//! The performance test asserts only with `FRINGE_PERF=1` (release build).

mod common;

use std::time::Instant;

use fringe_core::analytic::cases::{self, case_scene, Status};
use fringe_core::problem::compile;
use fringe_core::scene::examples;
use fringe_core::solver::{solve, solver_for, Method, Part, Quality, SolveContext, SolveError, Stage};
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
fn fem_mirror_off_grid() {
    fem_case("mirror_off_grid");
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

#[test]
fn fem_balance() {
    fem_case("balance");
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

/// Cancels from another thread as soon as the running solve enters `stage` and
/// returns the time from the cancel request to the solve returning.
fn cancel_latency_in(quality: Quality, stage: Stage) -> f64 {
    let mut s = examples::default();
    s.solver.method = FEM;
    let ctx = SolveContext::new();
    let progress = ctx.progress();
    let flag = ctx.cancel_flag();
    let watcher = std::thread::spawn(move || loop {
        let snap = progress.snapshot();
        if snap.stage == stage as u32 {
            flag.store(true, std::sync::atomic::Ordering::SeqCst);
            return Some(Instant::now());
        }
        if snap.stage > stage as u32 {
            return None;
        }
        std::hint::spin_loop();
    });
    let r = solve(&s, quality, &ctx);
    let done = Instant::now();
    let cancelled_at = watcher.join().unwrap().unwrap_or_else(|| panic!("the solve passed {stage:?} unseen"));
    assert!(matches!(r, Err(SolveError::Cancelled)), "{:?}", r.err());
    done.duration_since(cancelled_at).as_secs_f64()
}

/// Outside the LU a cancel takes effect within 200 ms (mesh and assembly
/// of the final default scene; sampling of the preview).
#[test]
fn fem_cancel_latency() {
    for (q, stage) in [(Quality::Final, Stage::Geometry), (Quality::Final, Stage::Assemble), (Quality::Preview, Stage::Sample)] {
        let dt = cancel_latency_in(q, stage);
        eprintln!("cancel in {stage:?} ({}): {:.1} ms", q.name(), dt * 1e3);
        assert!(dt <= 0.2, "cancel in {stage:?} took {dt:.3} s");
    }
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

/// A preview just over the memory limit runs at a lower resolution instead of
/// failing, and the check says so; an explicit preview resolution is kept.
#[test]
fn fem_preview_fits_memory_limit() {
    let mut s = examples::default();
    s.solver.method = FEM;
    s.domain.x_min_um = -30.0;
    s.domain.x_max_um = 40.0;
    s.domain.y_min_um = -9.0;
    s.domain.y_max_um = 8.5;
    let p = compile(&s, Quality::Preview).unwrap();
    let default = p.settings.ppw_lowered_from.expect("preview should be lowered");
    assert!(p.settings.ppw < default && p.settings.ppw >= 0.6 * default, "{}", p.settings.ppw);
    assert!(fringe_core::solver::estimate(&p).memory_mb <= p.settings.memory_limit_mb);
    let report = fringe_core::check::check(&s);
    assert!(report.ok, "{:?}", report.issues);
    assert!(report.issues.iter().any(|i| i.code == "preview_coarsened" && i.quality == Some(Quality::Preview)));

    s.solver.fem.preview_ppw = Some(default);
    let p = compile(&s, Quality::Preview).unwrap();
    assert_eq!((p.settings.ppw, p.settings.ppw_lowered_from), (default, None));
    assert!(!fringe_core::check::check(&s).ok);
}

/// Peak memory in MB of `fringe-cli solve` on the default scene with FEM at quality
/// `q`: the larger of the maximum resident set size and the peak memory footprint
/// that macOS `/usr/bin/time -l` reports (under memory pressure the resident size
/// drops as pages are compressed, while the footprint still counts them).
#[cfg(target_os = "macos")]
fn cli_peak_memory_mb(q: Quality) -> f64 {
    let scene = format!("{}/tests/fixtures/scenes/default.json", env!("CARGO_MANIFEST_DIR"));
    let png = format!("{}/fem-perf-{}.png", env!("CARGO_TARGET_TMPDIR"), q.name());
    let out = std::process::Command::new("/usr/bin/time")
        .args(["-l", env!("CARGO_BIN_EXE_fringe-cli"), "solve", &scene, "-o", &png, "--solver", "fem", "--quality", q.name(), "--quiet"])
        .output()
        .unwrap();
    assert!(out.status.success(), "fringe-cli failed: {}", String::from_utf8_lossy(&out.stderr));
    let err = String::from_utf8_lossy(&out.stderr);
    let bytes = |key: &str| -> Option<f64> {
        err.lines().find(|l| l.contains(key)).and_then(|l| l.split_whitespace().next()?.parse().ok())
    };
    let peak = bytes("maximum resident set size").expect("no rusage output").max(bytes("peak memory footprint").unwrap_or(0.0));
    peak / (1024.0 * 1024.0)
}

/// Default scene: preview ≤ 1.5 s, final ≤ 12 s, the time estimate within
/// 2×, and (macOS) peak memory ≤ 2 GB with the memory estimate within 2×.
/// Asserted with FRINGE_PERF=1 in a release build. Each quality runs three times
/// and the fastest run is compared, so that a busy machine measures the solver
/// rather than the contention.
#[test]
#[ignore]
fn fem_perf_default_scene() {
    let assert_perf = std::env::var("FRINGE_PERF").as_deref() == Ok("1");
    let mut s = examples::default();
    s.solver.method = FEM;
    // Warm up the thread pool and allocator.
    solve(&s, Quality::Preview, &SolveContext::new()).unwrap();
    for (q, limit) in [(Quality::Preview, 1.5), (Quality::Final, 12.0)] {
        let p = compile(&s, q).unwrap();
        let est = solver_for(FEM).estimate(&p);
        let mut runs = Vec::new();
        for _ in 0..3 {
            let t = Instant::now();
            let f = solve(&s, q, &SolveContext::new()).unwrap();
            runs.push(t.elapsed().as_secs_f64());
            eprintln!(
                "default {}: {:.2} s (estimate {:.2} s), {} unknowns (estimate {}), timings {:?}",
                q.name(),
                runs.last().unwrap(),
                est.seconds,
                f.meta.solver.unknowns,
                est.unknowns,
                f.meta.solver.timings
            );
        }
        let dt = runs.iter().cloned().fold(f64::INFINITY, f64::min);
        eprintln!("default {}: fastest {dt:.2} s of {runs:.2?}", q.name());
        if assert_perf {
            assert!(dt <= limit, "{} took {dt:.2} s > {limit} s", q.name());
            assert!(est.seconds / dt <= 2.0 && dt / est.seconds <= 2.0, "estimate {:.2} s vs {dt:.2} s", est.seconds);
        }
        #[cfg(target_os = "macos")]
        {
            let mb = cli_peak_memory_mb(q);
            eprintln!("default {}: peak memory {mb:.0} MB (estimate {:.0} MB)", q.name(), est.memory_mb);
            if assert_perf {
                assert!(mb <= 2048.0, "{} peak memory {mb:.0} MB > 2 GB", q.name());
                assert!(est.memory_mb / mb <= 2.0 && mb / est.memory_mb <= 2.0, "memory estimate {:.0} MB vs {mb:.0} MB", est.memory_mb);
            }
        }
    }
}

/// `pml_hygiene` must see a PML a thousand times weaker than the default:
/// with R0 = 1e−3 the two domains differ by more than the case's bound.
#[test]
#[ignore]
fn fem_pml_hygiene_detects_a_weak_pml() {
    use fringe_core::analytic::metrics::{rel_l2, resample};
    use fringe_core::scene::Domain;
    use fringe_core::types::C64;
    let mut small = case_scene("pml_hygiene").unwrap();
    small.solver.method = FEM;
    small.solver.fem.final_ppw = Some(cases::PML_HYGIENE_FEM_PPW);
    small.solver.fem.pml_reflection = 1e-3;
    let mut big = small.clone();
    big.domain = Domain { x_min_um: -8.0, x_max_um: 8.0, y_min_um: -8.0, y_max_um: 8.0, pml_wl: 1.0 };
    let a = solve(&small, Quality::Final, &SolveContext::new()).unwrap();
    let b = solve(&big, Quality::Final, &SolveContext::new()).unwrap();
    let b_on_a: Vec<C64> =
        resample(&b, Part::Total, &a.grid).into_iter().map(|v| v.unwrap_or(C64::new(f64::NAN, 0.0))).collect();
    let mask: Vec<bool> = (0..a.grid.len()).map(|i| !a.is_pec(i)).collect();
    let e = rel_l2(&a.total, &b_on_a, Some(&mask));
    let bound = cases::spec("pml_hygiene").unwrap().fem.unwrap();
    assert!(e > 2.0 * bound, "R0 = 1e-3 gives {e:.2e}, bound {bound:.1e}");
}

/// The estimate counts a polygon's vertices as mesh constraint points and the
/// output grid as memory.
#[test]
fn fem_estimate_counts_vertices_and_output() {
    use fringe_core::scene::Shape;
    let mut s = case_scene("mie_diel").unwrap();
    s.solver.method = FEM;
    let n = 2000;
    s.elements[0].shape = Shape::Polygon {
        vertices_um: (0..n)
            .map(|k| 2.0 * std::f64::consts::PI * k as f64 / n as f64)
            .map(|a| [a.cos(), a.sin()])
            .collect(),
    };
    let p = compile(&s, Quality::Preview).unwrap();
    let est = fringe_core::solver::estimate(&p);
    let f = solve(&s, Quality::Preview, &SolveContext::new()).unwrap();
    let ratio = est.unknowns as f64 / f.meta.solver.unknowns as f64;
    assert!((0.7..=1.5).contains(&ratio), "estimate {} vs {} unknowns", est.unknowns, f.meta.solver.unknowns);
    s.solver.output.preview_ppw = Some(80.0);
    let p = compile(&s, Quality::Preview).unwrap();
    let est_fine = fringe_core::solver::estimate(&p);
    let points = p.output_grid().len() as f64;
    assert!(est_fine.memory_mb - est.memory_mb > 60.0 * points / 1e6, "{} vs {} MB", est_fine.memory_mb, est.memory_mb);
}

// Dispersive materials.

#[test]
fn fem_mie_silver() {
    fem_case("mie_silver");
}

#[test]
fn fem_mie_gold() {
    fem_case("mie_gold");
}

#[test]
fn fem_mie_silver_plasmon() {
    fem_case("mie_silver_plasmon");
}

#[test]
fn fem_bk7_plain() {
    fem_case("bk7_plain");
}

// Line sources.

#[test]
fn fem_line_free() {
    fem_case("line_free");
}

#[test]
fn fem_line_pec() {
    fem_case("line_pec");
}

#[test]
fn fem_line_diel() {
    fem_case("line_diel");
}

#[test]
fn fem_line_plane_diel() {
    fem_case("line_plane_diel");
}

// Detectors.

#[test]
fn fem_detector_plane() {
    fem_case("detector_plane");
}

#[test]
fn fem_slab_power() {
    fem_case("slab_power");
}

#[test]
fn fem_slab_lossy_power() {
    fem_case("slab_lossy_power");
}
