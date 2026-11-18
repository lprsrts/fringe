//! FDTD validation: the FDTD column of the case table, the
//! solver's capability checks, cancel latency and performance.

mod common;

use std::time::{Duration, Instant};

use fringe_core::analytic::cases::case_scene;
use fringe_core::job::Job;
use fringe_core::problem::compile;
use fringe_core::scene::{examples, Material, Shape};
use fringe_core::solver::context::STATE_CANCELLED;
use fringe_core::solver::{fdtd, solve, solver_for, FdtdSolver, Method, Quality, SolveContext, Solver, Stage};

use common::assert_case;

fn fdtd(id: &str) {
    assert_case(id, Method::Fdtd, Quality::Final);
}

// Fast cases.

#[test]
fn mie_pec() {
    fdtd("mie_pec");
}

#[test]
fn mie_pec_37() {
    fdtd("mie_pec_37");
}

#[test]
fn mie_diel() {
    fdtd("mie_diel");
}

#[test]
fn mie_lossy() {
    fdtd("mie_lossy");
}

#[test]
fn slab_airy_0() {
    fdtd("slab_airy_0");
}

#[test]
fn mirror_0() {
    fdtd("mirror_0");
}

/// The mirror face between node lines: the PEC surface must not snap to the
/// node line inside the conductor.
#[test]
fn mirror_off_grid() {
    fdtd("mirror_off_grid");
}

#[test]
fn balance() {
    fdtd("balance");
}

#[test]
fn free_beam() {
    fdtd("free_beam");
}

#[test]
fn transparent() {
    fdtd("transparent");
}

// Slow cases.

#[test]
#[ignore]
fn mie_high_index() {
    fdtd("mie_high_index");
}

#[test]
#[ignore]
fn slab_airy_30() {
    fdtd("slab_airy_30");
}

#[test]
#[ignore]
fn slab_lossy() {
    fdtd("slab_lossy");
}

#[test]
#[ignore]
fn mirror_25() {
    fdtd("mirror_25");
}

#[test]
#[ignore]
fn fdtd_subpixel_order() {
    fdtd("fdtd_subpixel_order");
}

#[test]
#[ignore]
fn pml_hygiene() {
    fdtd("pml_hygiene");
}

// Checks and estimates.

#[test]
fn thin_pec_is_rejected() {
    let mut s = case_scene("mirror_0").unwrap();
    s.solver.method = Method::Fdtd;
    if let Shape::Mirror { thickness_um, .. } = &mut s.elements[0].shape {
        *thickness_um = 0.06;
    }
    let p = compile(&s, Quality::Preview).unwrap();
    let issues = FdtdSolver.check(&p);
    let e = issues.iter().find(|i| i.code == "fdtd_thin_pec").expect("thin PEC error");
    assert!(e.is_error() && e.message.contains("thinner than the FDTD cell"), "{e:?}");
    assert_eq!(e.quality, Some(Quality::Preview));
    let err = solve(&s, Quality::Preview, &SolveContext::new()).err().expect("solve must fail");
    assert_eq!(err.code(), "unsupported");
}

#[test]
fn too_large_and_slow_convergence_warnings() {
    let mut s = examples::example("talbot").unwrap();
    s.solver.method = Method::Fdtd;
    s.solver.fdtd.preview_ppw = Some(80.0);
    let p = compile(&s, Quality::Preview).unwrap();
    let issues = FdtdSolver.check(&p);
    assert!(issues.iter().any(|i| i.code == "too_large" && i.is_error()), "{issues:?}");
    assert!(issues.iter().any(|i| i.code == "fdtd_slow_convergence" && !i.is_error()), "{issues:?}");
    let p = compile(&examples::default(), Quality::Final).unwrap();
    assert!(FdtdSolver.check(&p).is_empty());
}

#[test]
fn estimate_is_consistent() {
    let p = compile(&examples::default(), Quality::Preview).unwrap();
    let e = solver_for(Method::Fdtd).estimate(&p);
    let [nx, ny] = e.grid.unwrap();
    assert_eq!(e.unknowns, (nx * ny) as u64);
    assert!(e.seconds > 0.0 && e.memory_mb > 0.0);
    // Scenes that may ring are estimated between the typical run and the cap.
    for name in ["waveguide", "nanojet"] {
        let mut s = examples::example(name).unwrap();
        s.solver.method = Method::Fdtd;
        let p = compile(&s, Quality::Final).unwrap();
        let typical = fdtd::grid::min_periods(&p) as f64 + 6.0;
        let cap = (fdtd::grid::max_periods(&p) + 2) as f64;
        let est = FdtdSolver::estimated_periods(&p);
        assert!(est > 1.5 * typical && est < cap, "{name}: {est} periods ({typical}..{cap})");
    }
    let p = compile(&examples::default(), Quality::Final).unwrap();
    assert_eq!(FdtdSolver::estimated_periods(&p), fdtd::grid::min_periods(&p) as f64 + 6.0);
}

/// A run too short to compare two probe periods reports no residual and a
/// warning without Δ.
#[test]
fn single_period_run_has_no_residual() {
    let mut s = case_scene("mie_diel").unwrap();
    s.solver.method = Method::Fdtd;
    s.solver.fdtd.max_periods = Some(1);
    let f = solve(&s, Quality::Preview, &SolveContext::new()).unwrap();
    let m = &f.meta.solver;
    assert!(!m.converged && m.residual.is_none(), "{m:?}");
    assert_eq!(m.periods, Some(3.0));
    let w = m.warnings.iter().find(|w| w.starts_with("not fully settled")).expect("settle warning");
    assert!(w.starts_with("not fully settled after 3 periods"), "{w}");
}

/// The scattered field vanishes without bodies, and the Yee-matched incident
/// field is what the pipeline reports.
#[test]
fn output_grid_is_the_interior() {
    let s = case_scene("free_beam").unwrap();
    let f = solve(&s, Quality::Preview, &SolveContext::new()).unwrap();
    assert_eq!(f.meta.incident_kind, "yee_matched");
    let d = s.domain.rect();
    let g = f.grid;
    assert!((g.x0 - d.x_min).abs() < 1e-12 && (g.y0 - d.y_min).abs() < 1e-12);
    assert!(g.x0 + (g.nx - 1) as f64 * g.dx <= d.x_max + 1e-9);
    assert!(g.x0 + g.nx as f64 * g.dx > d.x_max - 1e-9);
    assert!(f.meta.solver.converged);
}

#[test]
fn cancel_latency() {
    let mut s = examples::default();
    s.solver.method = Method::Fdtd;
    s.solver.fdtd.final_ppw = Some(40.0);
    let job = Job::spawn(s, Quality::Final);
    let t = Instant::now();
    while job.poll().stage != Stage::Solve as u32 {
        assert!(t.elapsed() < Duration::from_secs(60), "never reached the solve stage");
        std::thread::sleep(Duration::from_millis(2));
    }
    std::thread::sleep(Duration::from_millis(100));
    let t = Instant::now();
    job.cancel();
    while job.poll().state != STATE_CANCELLED {
        assert!(t.elapsed() < Duration::from_secs(5), "never cancelled: {:?}", job.poll());
        std::thread::sleep(Duration::from_millis(1));
    }
    let ms = t.elapsed().as_secs_f64() * 1e3;
    eprintln!("FDTD cancel latency {ms:.1} ms");
    assert!(ms <= 100.0, "cancel took {ms:.1} ms");
}

fn perf() -> bool {
    std::env::var("FRINGE_PERF").is_ok_and(|v| v == "1")
}

/// Default scene timings against the estimate (release build; asserted with
/// FRINGE_PERF=1). Each quality runs three times and the fastest counts, so other
/// load on the machine does not decide the result; run with --test-threads=1.
#[test]
#[ignore]
fn default_scene_performance() {
    for q in [Quality::Preview, Quality::Final] {
        let s = examples::default();
        let p = compile(&s, q).unwrap();
        let est = solver_for(Method::Fdtd).estimate(&p);
        let mut secs = f64::INFINITY;
        let mut f = None;
        for _ in 0..3 {
            let t = Instant::now();
            f = Some(solve(&s, q, &SolveContext::new()).unwrap());
            secs = secs.min(t.elapsed().as_secs_f64());
        }
        let f = f.unwrap();
        eprintln!(
            "default {} (best of 3): {:.3} s (estimate {:.3} s, {}), periods {:?}, converged {}, residual {:?}, timings {:?}",
            q.name(),
            secs,
            est.seconds,
            est.detail,
            f.meta.solver.periods,
            f.meta.solver.converged,
            f.meta.solver.residual,
            f.meta.solver.timings
        );
        if perf() {
            let limit = if q == Quality::Preview { 1.5 } else { 12.0 };
            assert!(secs <= limit, "{} took {secs:.2} s", q.name());
            let ratio = est.seconds / secs;
            assert!((0.5..=2.0).contains(&ratio), "estimate {:.3} s vs measured {secs:.3} s", est.seconds);
        }
    }
}

#[test]
fn materials_are_dielectric_or_pec() {
    // A guard that the case scenes keep the materials these tests assume.
    let s = case_scene("mie_lossy").unwrap();
    assert!(matches!(s.elements[0].material, Material::Dielectric { .. }));
}

/// `estimate()` against the measured time (best of three) on every example at
/// both qualities, forced to FDTD; asserted within 2× with FRINGE_PERF=1.
#[test]
#[ignore]
fn estimate_calibration() {
    let mut worst: f64 = 1.0;
    for info in examples::EXAMPLES.iter() {
        let mut s = examples::example(info.name).unwrap();
        s.solver.method = Method::Fdtd;
        for q in [Quality::Preview, Quality::Final] {
            let p = compile(&s, q).unwrap();
            if FdtdSolver.check(&p).iter().any(|i| i.is_error()) {
                eprintln!("{:16} {:7}: rejected by check()", info.name, q.name());
                continue;
            }
            let est = fringe_core::solver::estimate(&p);
            let mut secs = f64::INFINITY;
            let mut periods = None;
            for _ in 0..3 {
                let t = Instant::now();
                let f = solve(&s, q, &SolveContext::new()).unwrap();
                secs = secs.min(t.elapsed().as_secs_f64());
                periods = f.meta.solver.periods;
            }
            let ratio = est.seconds / secs;
            eprintln!(
                "{:16} {:7}: {secs:8.3} s, estimate {:8.3} s (×{ratio:.2}), periods {periods:?}, estimated {:.0}",
                info.name,
                q.name(),
                est.seconds,
                FdtdSolver::estimated_periods(&p)
            );
            if secs > 0.05 {
                worst = worst.max(ratio.max(1.0 / ratio));
            }
        }
    }
    eprintln!("worst estimate/measured ratio {worst:.2}");
    if perf() {
        assert!(worst <= 2.0, "worst ratio {worst:.2}");
    }
}

/// A PEC face 0.3 Δ past a node line: the node 0.3 Δ in front of it is PEC
/// (nearest node line, not the next one inside), the node 1.3 Δ in front is
/// free, and its H edge to the PEC node is shortened to the true surface.
#[test]
fn pec_surface_snaps_to_the_nearest_node_line() {
    use fringe_core::solver::fdtd::grid::Layout;
    use fringe_core::solver::fdtd::materials::{body_media, pec_edges, rasterize, NodeMat};
    use fringe_core::types::C64;
    use std::sync::atomic::AtomicBool;
    let mut s = case_scene("mirror_0").unwrap();
    s.solver.method = Method::Fdtd;
    let p0 = compile(&s, Quality::Final).unwrap();
    let dx = Layout::new(&p0).dx;
    s.elements[0].x_um += 0.3 * dx;
    let p = compile(&s, Quality::Final).unwrap();
    let l = Layout::new(&p);
    let raster = rasterize(&p, &l, C64::new(1.0, 0.0), &body_media(&p, |_| 1.0), &AtomicBool::new(false)).unwrap();
    let face = s.elements[0].x_um;
    let j = ((0.0 - l.y0) / l.dx).round() as usize;
    let node = |x: f64| j * l.nx + ((x - l.x0) / l.dx).round() as usize;
    let mat = |idx: usize| raster.nodes.iter().find(|n| n.0 == idx).map(|n| n.1.clone());
    let (snapped, free) = (node(face - 0.3 * dx), node(face - 1.3 * dx));
    assert_eq!(mat(snapped), Some(NodeMat::Pec));
    assert_eq!(mat(free), None);
    let edges = pec_edges(&p, &l, &raster);
    let e = edges.iter().find(|e| e.free == free && !e.hx).expect("an Hy edge from the free node");
    assert!((e.len - 1.3 * dx).abs() < 1e-9 * dx, "edge length {} Δ", e.len / dx);
}

/// A field that overflows is a numerical error, not a NaN result. Validation
/// keeps amplitudes below 1e30; this bypasses it.
#[test]
fn non_finite_field_is_an_error() {
    use fringe_core::problem::compile_unchecked;
    use fringe_core::scene::SourceKind;
    use fringe_core::solver::SolveError;
    let mut s = case_scene("mie_pec").unwrap();
    s.solver.method = Method::Fdtd;
    if let SourceKind::PlaneWave { amplitude, .. } = &mut s.sources[0].kind {
        *amplitude = 1e40;
    }
    let p = compile_unchecked(&s, Quality::Preview);
    let t = Instant::now();
    match FdtdSolver.solve(&p, &SolveContext::new()) {
        Err(SolveError::Numerical(m)) => assert!(m.contains("infinite or NaN"), "{m}"),
        Err(e) => panic!("wrong error {e}"),
        Ok(_) => panic!("an overflowing run returned a result"),
    }
    assert!(t.elapsed().as_secs_f64() < 5.0, "the run went on after the field overflowed");
}

// Dispersive materials.

#[test]
fn mie_silver() {
    fdtd("mie_silver");
}

#[test]
fn mie_gold() {
    fdtd("mie_gold");
}

#[test]
fn mie_silver_plasmon() {
    fdtd("mie_silver_plasmon");
}

#[test]
fn bk7_plain() {
    fdtd("bk7_plain");
}

// Line sources.

#[test]
fn line_free() {
    fdtd("line_free");
}

#[test]
fn line_pec() {
    fdtd("line_pec");
}

#[test]
fn line_diel() {
    fdtd("line_diel");
}

#[test]
fn line_plane_diel() {
    fdtd("line_plane_diel");
}

// Detectors.

#[test]
fn detector_plane() {
    fdtd("detector_plane");
}

#[test]
fn slab_power() {
    fdtd("slab_power");
}

#[test]
fn slab_lossy_power() {
    fdtd("slab_lossy_power");
}
