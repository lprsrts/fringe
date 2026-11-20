//! MoM solver validation (the MoM column of the case table) and solver-specific checks.
//!
//! Fast cases run in `cargo test`; slow ones with `cargo test --release -- --ignored`.
//! Performance assertions run only with `FRINGE_PERF=1`.

mod common;

use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};

use fringe_core::analytic::cases::{self, case_scene, field_error, reference, Status};
use fringe_core::analytic::metrics::flux_balance;
use fringe_core::problem::compile;
use fringe_core::scene::examples::{example, EXAMPLES};
use fringe_core::scene::{Material, PecFormulation, Scene, Shape};
use fringe_core::solver::mom::panels::{panelize, pec_rows, PecRows};
use fringe_core::solver::{solve, solver_for, FieldGrid, Method, Part, Quality, SolveContext};
use fringe_core::types::C64;

use common::assert_case;

fn mom_scene(id: &str, ppw: Option<f64>) -> Scene {
    let mut s = case_scene(id).unwrap();
    s.solver.method = Method::Mom;
    s.solver.mom.final_ppw = ppw;
    s
}

fn perf() -> bool {
    std::env::var("FRINGE_PERF").is_ok_and(|v| v == "1")
}

/// How long a cancel may take: 0.2 s, or 0.5 s on shared CI runners, which are
/// slower and noisier than a developer machine.
fn cancel_bound() -> f64 {
    if std::env::var_os("CI").is_some() { 0.5 } else { 0.2 }
}

// Validation cases, fast.

#[test]
fn mie_pec() {
    assert_case("mie_pec", Method::Mom, Quality::Final);
}

#[test]
fn mie_pec_37() {
    assert_case("mie_pec_37", Method::Mom, Quality::Final);
}

#[test]
fn mie_pec_resonance() {
    assert_case("mie_pec_resonance", Method::Mom, Quality::Final);
}

#[test]
fn mie_diel() {
    assert_case("mie_diel", Method::Mom, Quality::Final);
}

#[test]
fn mie_lossy() {
    assert_case("mie_lossy", Method::Mom, Quality::Final);
}

#[test]
fn slab_airy_0() {
    assert_case("slab_airy_0", Method::Mom, Quality::Final);
}

#[test]
fn mirror_0() {
    assert_case("mirror_0", Method::Mom, Quality::Final);
}

#[test]
fn mirror_off_grid() {
    assert_case("mirror_off_grid", Method::Mom, Quality::Final);
}

#[test]
fn mom_self() {
    assert_case("mom_self", Method::Mom, Quality::Final);
}

#[test]
fn free_beam() {
    assert_case("free_beam", Method::Mom, Quality::Final);
}

#[test]
fn transparent() {
    let r = assert_case("transparent", Method::Mom, Quality::Final);
    // The scattered-trace formulation makes a body with ε = ε_b exactly invisible.
    assert_eq!(r.error, Some(0.0));
}

/// The `balance` case, and the shared metric itself on the exact Mie field
/// sampled on the same grid (what the solver error is measured against).
#[test]
fn balance() {
    assert_case("balance", Method::Mom, Quality::Final);
    let mut f = solve(&mom_scene("balance", None), Quality::Final, &SolveContext::new()).unwrap();
    let rect = f.scene.domain.rect().expand(-0.5);
    let exact_field = reference("balance", &f.scene).unwrap();
    let g = f.grid;
    for idx in 0..g.len() {
        f.total[idx] = exact_field(g.point(idx % g.nx, idx / g.nx));
    }
    let exact = flux_balance(&f, rect).residual();
    eprintln!("balance of the exact field: {exact:.3e}");
    assert!(exact <= 1e-3, "flux_balance of the exact Mie field {exact}");
}

// Validation cases, slow.

#[test]
#[ignore]
fn mie_high_index() {
    assert_case("mie_high_index", Method::Mom, Quality::Final);
}

#[test]
#[ignore]
fn slab_airy_30() {
    assert_case("slab_airy_30", Method::Mom, Quality::Final);
}

#[test]
#[ignore]
fn slab_lossy() {
    assert_case("slab_lossy", Method::Mom, Quality::Final);
}

#[test]
#[ignore]
fn mirror_25() {
    assert_case("mirror_25", Method::Mom, Quality::Final);
}

// Solver-specific checks.

/// The reconstructed-density discretisation converges at third order or better
/// on a smooth body.
#[test]
fn convergence_order() {
    let err = |ppw| {
        let f = solve(&mom_scene("mie_diel", Some(ppw)), Quality::Final, &SolveContext::new()).unwrap();
        field_error("mie_diel", &f)
    };
    let (e8, e16) = (err(8.0), err(16.0));
    let order = (e8 / e16).log2();
    eprintln!("mie_diel: {e8:.3e} at 8 ppw, {e16:.3e} at 16 ppw, order {order:.2}");
    assert!(order >= 3.0, "observed order {order}");
}

/// Both PEC formulations agree away from resonance, and `auto` picks the EFIE
/// only for thin bodies.
#[test]
fn pec_formulations() {
    let mut fields = Vec::new();
    for form in [PecFormulation::Efie, PecFormulation::Cfie] {
        let mut s = mom_scene("mie_pec", None);
        s.solver.mom.pec_formulation = form;
        let f = solve(&s, Quality::Final, &SolveContext::new()).unwrap();
        assert!(field_error("mie_pec", &f) < 5e-3);
        fields.push(f);
    }
    let d: f64 = fields[0].total.iter().zip(&fields[1].total).map(|(a, b)| (a - b).norm()).fold(0.0, f64::max);
    assert!(d < 1e-3, "EFIE and CFIE differ by {d}");

    let p = compile(&mom_scene("mirror_0", None), Quality::Final).unwrap();
    assert!(matches!(pec_rows(&p, &p.bodies[0]), PecRows::Cfie { .. }), "0.5 µm mirror uses the CFIE");
    let mut s = mom_scene("mirror_0", None);
    if let Shape::Mirror { thickness_um, .. } = &mut s.elements[0].shape {
        *thickness_um = 0.3;
    }
    let p = compile(&s, Quality::Final).unwrap();
    assert_eq!(pec_rows(&p, &p.bodies[0]), PecRows::Efie, "0.3 µm mirror uses the EFIE");
}

/// Panels respect the target length, corners are graded and the unknowns are
/// laid out per body.
#[test]
fn panelisation() {
    let p = compile(&mom_scene("slab_airy_0", None), Quality::Final).unwrap();
    let pan = panelize(&p);
    let h = 1.0 / 1.5 / 16.0;
    assert!(pan.panels.iter().all(|q| q.len <= h * (1.0 + 1e-9)));
    // Each of the 4 corners has two L/8 sub-panels on each side.
    let tiny = pan.panels.iter().filter(|q| q.len < 0.2 * h).count();
    assert_eq!(tiny, 16);
    assert_eq!(pan.n_unknowns, 2 * pan.panels.len());
    // Collocation points lie on the contour, with unit outward normals.
    let body = &p.bodies[0];
    for q in &pan.panels {
        assert!(body.contour.closest(q.mid).3 < 1e-12);
        assert!((q.normal.norm() - 1.0).abs() < 1e-12);
        assert!(!body.inside(q.mid + q.normal * 1e-6));
        assert!(body.inside(q.mid - q.normal * 1e-6));
    }
    // A circle has no corners: every panel has both neighbours.
    let p = compile(&mom_scene("mie_diel", None), Quality::Final).unwrap();
    let pan = panelize(&p);
    assert!(pan.panels.iter().all(|q| q.prev.is_some() && q.next.is_some()));
}

/// `check()` blocks systems above `max_unknowns` and warns about small gaps.
#[test]
fn check_issues() {
    let mut s = mom_scene("slab_airy_0", None);
    s.solver.mom.preview_ppw = Some(60.0);
    let p = compile(&s, Quality::Preview).unwrap();
    let issues = solver_for(Method::Mom).check(&p);
    assert!(issues.iter().any(|i| i.code == "too_large" && i.is_error()), "{issues:?}");
    let err = solve(&s, Quality::Preview, &SolveContext::new()).err().unwrap();
    assert_eq!(err.code(), "too_large");

    let mut s = example("double_slit").unwrap();
    s.solver.method = Method::Mom;
    let p = compile(&s, Quality::Final).unwrap();
    assert!(solver_for(Method::Mom).check(&p).is_empty());

    // Two cylinders 0.1 µm apart: closer than two preview panels.
    let mut s = example("mie_pec").unwrap();
    s.solver.method = Method::Mom;
    let mut second = s.elements[0].clone();
    second.id = "second".into();
    second.x_um = 2.1;
    s.elements.push(second);
    let p = compile(&s, Quality::Preview).unwrap();
    let issues = solver_for(Method::Mom).check(&p);
    assert!(issues.iter().any(|i| i.code == "mom_small_gap" && !i.is_error()), "{issues:?}");
}

/// A dielectric and a PEC body: the field does not depend on the order in which
/// the bodies are listed.
#[test]
fn body_order_does_not_matter() {
    let mut s = example("mie_dielectric").unwrap();
    s.solver.method = Method::Mom;
    let mut second = s.elements[0].clone();
    second.id = "second".into();
    second.material = Material::Pec;
    second.x_um = 3.0;
    second.shape = Shape::Cylinder { radius_um: 0.6 };
    s.elements.push(second);
    let a = solve(&s, Quality::Preview, &SolveContext::new()).unwrap();
    s.elements.reverse();
    let b = solve(&s, Quality::Preview, &SolveContext::new()).unwrap();
    let d: f64 = (0..a.grid.len())
        .filter(|&i| !a.is_pec(i))
        .map(|i| (a.value(Part::Total, i) - b.value(Part::Total, i)).norm())
        .fold(0.0, f64::max);
    assert!(d < 1e-9, "fields differ by {d}");
}

/// Cancelling during each stage of a mid-sized solve returns within 200 ms
/// (the delays land in the fill, the LU and the sampling).
#[test]
fn cancel_latency() {
    let scene = mom_scene("slab_airy_0", None);
    for delay_ms in [20u64, 150, 400, 900] {
        let ctx = SolveContext::new();
        let flag = ctx.cancel_flag();
        let progress = ctx.progress();
        let s = scene.clone();
        // A dedicated pool, as a job has, so other tests' work on the global pool
        // does not delay the cancelled tasks.
        let pool = rayon::ThreadPoolBuilder::new().num_threads(4).build().unwrap();
        let handle = std::thread::spawn(move || pool.install(|| solve(&s, Quality::Final, &ctx).map(|_| ())));
        std::thread::sleep(Duration::from_millis(delay_ms));
        let t = Instant::now();
        flag.store(true, Ordering::Relaxed);
        let stage = progress.snapshot().stage;
        let r = handle.join().unwrap();
        let latency = t.elapsed().as_secs_f64();
        eprintln!(
            "cancel after {delay_ms} ms in stage {stage}: {:?} in {:.1} ms",
            r.as_ref().err().map(|e| e.code()),
            latency * 1e3
        );
        assert!(latency < cancel_bound(), "cancel after {delay_ms} ms took {latency:.3} s");
    }
}

/// The far-field Bessel fast path agrees with the shared implementation.
#[test]
fn fast_bessel_matches_shared() {
    use fringe_core::solver::mom::evaluate::j_y_01_fast;
    use fringe_core::special::j_y_01_real;
    let mut x = 1e-3;
    while x < 2000.0 {
        let a = j_y_01_fast(x);
        let b = j_y_01_real(x);
        let scale = (2.0 / (std::f64::consts::PI * x)).sqrt().min(1.0);
        for (u, v) in [(a.0, b.0), (a.1, b.1), (a.2, b.2), (a.3, b.3)] {
            assert!((u - v).abs() <= 1e-11 * scale.max(v.abs()), "x = {x}: {u} vs {v}");
        }
        x *= 1.013;
    }
}

/// The interruptible blocked LU agrees with the shared faer LU.
#[test]
fn block_lu_matches_dense_lu() {
    use fringe_core::linalg::{DenseLu, DenseMatrix};
    use fringe_core::solver::mom::lu::{norm1, BlockLu};
    let mut rng = common::Rng(0x9e37_79b9_7f4a_7c15);
    for n in [1usize, 7, 64, 65, 200, 517] {
        let mut a = DenseMatrix::zeros(n);
        for v in a.data.iter_mut() {
            *v = C64::new(rng.range(-1.0, 1.0), rng.range(-1.0, 1.0));
        }
        let b: Vec<C64> = (0..n).map(|_| C64::new(rng.range(-1.0, 1.0), rng.range(-1.0, 1.0))).collect();
        let nrm = norm1(n, &a.data);
        let ours = BlockLu::factor(n, a.data.clone(), &SolveContext::new(), |_| {}).unwrap();
        let theirs = DenseLu::factor(a.clone());
        let x = ours.solve(&b);
        let r: f64 = a.matvec(&x).iter().zip(&b).map(|(u, v)| (u - v).norm()).fold(0.0, f64::max);
        assert!(r < 1e-9, "n = {n}: residual {r}");
        let xt = ours.solve_transpose(&b);
        let xt_ref = theirs.solve_transpose(&b);
        let d: f64 = xt.iter().zip(&xt_ref).map(|(u, v)| (u - v).norm()).fold(0.0, f64::max);
        assert!(d < 1e-8, "n = {n}: transpose solve differs by {d}");
        let (c1, c2) = (ours.cond1_estimate(nrm, &SolveContext::new()).unwrap(), theirs.cond1_estimate(nrm));
        assert!((c1 / c2 - 1.0).abs() < 1e-6, "n = {n}: cond {c1} vs {c2}");
    }
}

/// Every example solves with MoM at preview quality.
#[test]
fn examples_preview() {
    for info in EXAMPLES.iter() {
        let mut s = example(info.name).unwrap();
        s.solver.method = Method::Mom;
        let t = Instant::now();
        let f = solve(&s, Quality::Preview, &SolveContext::new()).unwrap_or_else(|e| panic!("{}: {e}", info.name));
        let secs = t.elapsed().as_secs_f64();
        eprintln!("{:14} {:5} unknowns {:.3} s", info.name, f.meta.solver.unknowns, secs);
        assert!(f.total.iter().all(|v| v.re.is_finite() && v.im.is_finite()), "{}: non-finite field", info.name);
        assert!(f.meta.solver.warnings.is_empty(), "{}: {:?}", info.name, f.meta.solver.warnings);
    }
}

/// Serialises the two timing tests. Run them with `--test-threads=1` as well,
/// since the other ignored tests in this binary would share the cores.
static PERF_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// Best of three timed solves (the first also warms the thread pool), so that
/// other processes' load does not masquerade as estimate error.
fn timed_solve(s: &Scene, q: Quality) -> (FieldGrid, f64) {
    let mut best = f64::INFINITY;
    let mut out = None;
    for _ in 0..3 {
        let t = Instant::now();
        let f = solve(s, q, &SolveContext::new()).unwrap();
        best = best.min(t.elapsed().as_secs_f64());
        out = Some(f);
    }
    (out.unwrap(), best)
}

/// Default scene: preview ≤ 1.5 s and final ≤ 12 s, with the
/// estimate within 2× of the measured time (best of three; asserted with
/// FRINGE_PERF=1).
#[test]
#[ignore]
fn performance_default_scene() {
    let _serial = PERF_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let mut s = example("lens").unwrap();
    s.solver.method = Method::Mom;
    for (q, budget) in [(Quality::Preview, 1.5), (Quality::Final, 12.0)] {
        let p = compile(&s, q).unwrap();
        let est = solver_for(Method::Mom).estimate(&p);
        let (f, secs) = timed_solve(&s, q);
        let ratio = est.seconds / secs;
        eprintln!(
            "default {}: {} unknowns, {secs:.3} s (estimate {:.3} s, ratio {ratio:.2}; memory estimate {:.0} MB) {:?}",
            q.name(),
            f.meta.solver.unknowns,
            est.seconds,
            est.memory_mb,
            f.meta.solver.timings
        );
        if perf() {
            assert!(secs <= budget, "{} took {secs:.2} s", q.name());
            assert!((0.5..=2.0).contains(&ratio), "estimate off by {ratio:.2}×");
        }
    }
}

/// Every MoM case of the tolerance table in one run (what `fringe-cli validate
/// --solver mom --slow` prints).
#[test]
#[ignore]
fn all_cases_report() {
    for c in cases::CASES.iter().filter(|c| c.mom.is_some()) {
        let r = cases::run_case(c.id, Method::Mom, Quality::Final).unwrap();
        eprintln!("{:20} {:?} error {:?} tol {:?} {}", c.id, r.status, r.error, r.tolerance, r.detail);
        assert_eq!(r.status, Status::Pass, "{}", c.id);
    }
}

/// Corners, sharp apexes, combs and thin bodies: 12 against 24 panels per λ and
/// the lossless energy balance.
#[test]
#[ignore]
fn shapes_converge() {
    use fringe_core::analytic::metrics::{rel_l2, resample};
    let base = example("prism").unwrap();
    let mk = |shape: Shape, material: Material, rot: f64| {
        let mut s = base.clone();
        s.solver.method = Method::Mom;
        s.elements[0].shape = shape;
        s.elements[0].material = material;
        s.elements[0].rotation_deg = rot;
        s
    };
    let glass = Material::Dielectric { n: 1.5, k: 0.0 };
    let scenes = vec![
        ("prism", mk(Shape::Prism { base_um: 8.0, apex_deg: 60.0 }, glass.clone(), 0.0)),
        ("sharp prism", mk(Shape::Prism { base_um: 2.0, apex_deg: 20.0 }, Material::Dielectric { n: 3.0, k: 0.0 }, 20.0)),
        ("wedge", mk(Shape::Wedge { thick_um: 2.0, thin_um: 0.5, height_um: 6.0 }, glass.clone(), 0.0)),
        ("comb grating", mk(Shape::Grating { period_um: 1.0, fill_factor: 0.3, depth_um: 0.5, count: 6, substrate_um: 0.5 }, glass.clone(), 0.0)),
        ("pec comb", mk(Shape::Grating { period_um: 1.0, fill_factor: 0.3, depth_um: 0.5, count: 6, substrate_um: 0.5 }, Material::Pec, 0.0)),
        ("thin pec", mk(Shape::Slab { thickness_um: 0.05, height_um: 6.0 }, Material::Pec, 30.0)),
        ("thin glass", mk(Shape::Slab { thickness_um: 0.05, height_um: 6.0 }, Material::Dielectric { n: 2.0, k: 0.0 }, 30.0)),
        ("polygon", mk(Shape::Polygon { vertices_um: vec![[-2.0, -2.0], [2.0, -1.0], [0.0, 0.0], [1.5, 2.0], [-1.5, 1.0]] }, glass.clone(), 0.0)),
        ("pec lens", mk(Shape::Lens { r1_um: Some(6.0), r2_um: Some(-6.0), center_thickness_um: 2.0, aperture_um: 6.0 }, Material::Pec, 0.0)),
    ];
    for (name, s) in scenes {
        let issues: Vec<_> = fringe_core::scene::validate(&s).into_iter().filter(|i| i.is_error()).collect();
        assert!(issues.is_empty(), "{name}: {issues:?}");
        let run = |ppw: f64| {
            let mut s = s.clone();
            s.solver.mom.final_ppw = Some(ppw);
            solve(&s, Quality::Final, &SolveContext::new()).unwrap()
        };
        let (a, b) = (run(12.0), run(24.0));
        let a_on_b: Vec<C64> =
            resample(&a, Part::Total, &b.grid).into_iter().map(|v| v.unwrap_or(C64::new(f64::NAN, 0.0))).collect();
        let mask: Vec<bool> = (0..b.grid.len()).map(|i| !b.is_pec(i)).collect();
        let e = rel_l2(&a_on_b, &b.total, Some(&mask));
        let fb = flux_balance(&b, b.scene.domain.rect().expand(-0.5));
        eprintln!(
            "{name:12}: 12 vs 24 ppw {e:.2e}; balance {:.2e}; cond {:.1e}; N {}",
            fb.residual(),
            b.meta.solver.cond_estimate.unwrap(),
            b.meta.solver.unknowns
        );
        assert!(e <= 2e-3 && fb.residual() <= 2e-3, "{name}");
    }
}

/// `estimate()` within 2× of the measured time on every example at
/// both qualities (best of three; asserted with FRINGE_PERF=1).
#[test]
#[ignore]
fn estimate_calibration() {
    let _serial = PERF_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let mut worst = 1.0f64;
    for info in EXAMPLES.iter() {
        let mut s = example(info.name).unwrap();
        s.solver.method = Method::Mom;
        for q in [Quality::Preview, Quality::Final] {
            let p = compile(&s, q).unwrap();
            let est = solver_for(Method::Mom).estimate(&p);
            let (f, secs) = timed_solve(&s, q);
            let ratio = est.seconds / secs;
            eprintln!(
                "{:14} {:7} N {:5} estimate {:6.3} s measured {:6.3} s ratio {ratio:.2}",
                info.name,
                q.name(),
                f.meta.solver.unknowns,
                est.seconds,
                secs
            );
            if secs > 0.02 {
                worst = worst.max(ratio.max(1.0 / ratio));
            }
        }
    }
    eprintln!("worst ratio {worst:.2}");
    if perf() {
        assert!(worst <= 2.0);
    }
}

// Dispersive materials.

#[test]
fn mie_silver() {
    assert_case("mie_silver", Method::Mom, Quality::Final);
}

#[test]
fn mie_gold() {
    assert_case("mie_gold", Method::Mom, Quality::Final);
}

#[test]
fn mie_silver_plasmon() {
    assert_case("mie_silver_plasmon", Method::Mom, Quality::Final);
}

#[test]
fn bk7_plain() {
    assert_case("bk7_plain", Method::Mom, Quality::Final);
}

// Line sources.

#[test]
fn line_free() {
    assert_case("line_free", Method::Mom, Quality::Final);
}

#[test]
fn line_pec() {
    assert_case("line_pec", Method::Mom, Quality::Final);
}

#[test]
fn line_diel() {
    assert_case("line_diel", Method::Mom, Quality::Final);
}

#[test]
fn line_plane_diel() {
    assert_case("line_plane_diel", Method::Mom, Quality::Final);
}

// Detectors.

#[test]
fn detector_plane() {
    assert_case("detector_plane", Method::Mom, Quality::Final);
}

#[test]
fn slab_power() {
    assert_case("slab_power", Method::Mom, Quality::Final);
}

#[test]
fn slab_lossy_power() {
    assert_case("slab_lossy_power", Method::Mom, Quality::Final);
}
