//! FDTD validation (spec §5.1, §9.2): the FDTD column of the case table, the
//! solver's capability checks, cancel latency and performance.

mod common;

use std::time::{Duration, Instant};

use beam_core::analytic::cases::{self, case_scene, field_error, run_case};
use beam_core::job::Job;
use beam_core::problem::compile;
use beam_core::scene::{examples, Material, Shape};
use beam_core::solver::context::STATE_CANCELLED;
use beam_core::solver::{fdtd, solve, solver_for, FdtdSolver, Method, Quality, SolveContext, Solver, Stage};

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
    std::env::var("BEAM_PERF").is_ok_and(|v| v == "1")
}

/// Default scene timings against the estimate (release build; asserted with
/// BEAM_PERF=1). Each quality runs three times and the fastest counts, so other
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

/// Measured errors and run statistics for every FDTD case (diagnostic).
#[test]
#[ignore]
fn report_cases() {
    for c in cases::CASES.iter().filter(|c| c.fdtd.is_some()) {
        let r = run_case(c.id, Method::Fdtd, Quality::Final).unwrap();
        eprintln!("{:22} {:?} error {:?} tol {:?} {:.2} s {}", c.id, r.status, r.error, r.tolerance, r.seconds, r.detail);
    }
}

/// Errors of `mie_diel` at 12–30 ppw with and without subpixel smoothing
/// (diagnostic).
#[test]
#[ignore]
fn subpixel_errors() {
    for subpixel in [true, false] {
        for ppw in [12.0, 16.0, 20.0, 24.0, 30.0] {
            let mut s = case_scene("mie_diel").unwrap();
            s.solver.method = Method::Fdtd;
            s.solver.fdtd.final_ppw = Some(ppw);
            s.solver.fdtd.subpixel = subpixel;
            let f = solve(&s, Quality::Final, &SolveContext::new()).unwrap();
            eprintln!(
                "subpixel {subpixel} ppw {ppw}: error {:.3e}, periods {:?}",
                field_error("mie_diel", &f),
                f.meta.solver.periods
            );
        }
    }
}

#[test]
fn materials_are_dielectric_or_pec() {
    // A guard that the case scenes keep the materials these tests assume.
    let s = case_scene("mie_lossy").unwrap();
    assert!(matches!(s.elements[0].material, Material::Dielectric { .. }));
}

/// TM resonances of the `mie_high_index` cylinder near the drive (diagnostic).
#[test]
#[ignore]
fn high_index_resonances() {
    use beam_core::analytic::MieCylinder;
    use beam_core::geometry::BodyMaterial;
    use beam_core::types::Vec2;
    let k0 = 2.0 * std::f64::consts::PI;
    let nf = 4001;
    let mut curves: Vec<Vec<f64>> = vec![Vec::new(); 14];
    let fs: Vec<f64> = (0..nf).map(|i| 0.75 + 0.5 * i as f64 / (nf - 1) as f64).collect();
    for &f in &fs {
        let mie = MieCylinder::new(Vec2::ZERO, 0.5, BodyMaterial::dielectric(3.5, 0.0), 1.0, k0 * f, 0.0, 1.0, 0.0);
        for (n, c) in curves.iter_mut().enumerate() {
            c.push(mie.c.get(n).map_or(0.0, |v| v.norm()));
        }
    }
    for (n, c) in curves.iter().enumerate() {
        for i in 1..nf - 1 {
            if c[i] > c[i - 1] && c[i] >= c[i + 1] && c[i] > 0.5 {
                let half = c.iter().filter(|&&v| v > c[i] / 2f64.sqrt()).count() as f64 * (fs[1] - fs[0]);
                eprintln!("n {n}: peak at f/f0 = {:.5}, |c| = {:.3}, fwhm {:.2e}", fs[i], c[i], half);
            }
        }
    }
}

/// Estimated against measured time and periods over every example and some
/// cases, all forced to FDTD (diagnostic; resonant scenes such as `waveguide`
/// and `mie_high_index` at final quality are the least accurate).
#[test]
#[ignore]
fn estimate_calibration() {
    let mut scenes: Vec<(String, beam_core::Scene)> = examples::EXAMPLES
        .iter()
        .map(|e| (e.name.to_string(), examples::example(e.name).unwrap()))
        .collect();
    for id in ["mie_diel", "slab_airy_0", "mirror_0", "mie_high_index"] {
        scenes.push((id.to_string(), case_scene(id).unwrap()));
    }
    let mut worst: f64 = 1.0;
    for (name, mut s) in scenes {
        s.solver.method = Method::Fdtd;
        for q in [Quality::Preview, Quality::Final] {
            let p = compile(&s, q).unwrap();
            if !FdtdSolver.check(&p).iter().all(|i| !i.is_error()) {
                eprintln!("{name:16} {:7}: rejected by check()", q.name());
                continue;
            }
            let est = solver_for(Method::Fdtd).estimate(&p);
            let t = Instant::now();
            let f = solve(&s, q, &SolveContext::new()).unwrap();
            let secs = t.elapsed().as_secs_f64();
            let ratio = est.seconds / secs;
            worst = if (ratio.ln()).abs() > worst.ln().abs() { ratio } else { worst };
            eprintln!(
                "{name:16} {:7}: {:8.3} s, estimate {:8.3} s (×{ratio:.2}), periods {:?} est {:.0}, {}, converged {}",
                q.name(),
                secs,
                est.seconds,
                f.meta.solver.periods,
                FdtdSolver::estimated_periods(&p),
                est.detail,
                f.meta.solver.converged
            );
        }
    }
    eprintln!("worst estimate/measured ratio {worst:.2}");
}

/// Default scene: preview against final, and the focal peak of each
/// (diagnostic for the cross-solver bounds of spec §9.3).
#[test]
#[ignore]
fn preview_against_final() {
    use beam_core::analytic::metrics::{focal_peak, rel_l2, resample};
    use beam_core::solver::Part;
    use beam_core::C64;
    let s = examples::default();
    let pre = solve(&s, Quality::Preview, &SolveContext::new()).unwrap();
    let fin = solve(&s, Quality::Final, &SolveContext::new()).unwrap();
    let on_fin: Vec<C64> =
        resample(&pre, Part::Total, &fin.grid).into_iter().map(|v| v.unwrap_or(C64::new(0.0, 0.0))).collect();
    let mask: Vec<bool> = resample(&pre, Part::Total, &fin.grid).iter().map(|v| v.is_some()).collect();
    eprintln!("preview vs final rel L2: {:.3e}", rel_l2(&on_fin, &fin.total, Some(&mask)));
    eprintln!("focus preview {:?}, final {:?}", focal_peak(&pre, 0.0, 0.0, 19.0), focal_peak(&fin, 0.0, 0.0, 19.0));
}
