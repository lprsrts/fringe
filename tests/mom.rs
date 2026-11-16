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

#[test]
fn fast_bessel_matches_shared() {
    use beam_core::solver::mom::evaluate::j_y_01_fast;
    use beam_core::special::j_y_01_real;
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

#[test]
#[ignore]
fn explore_timing() {
    use beam_core::problem::compile;
    use beam_core::scene::examples::example;
    use beam_core::solver::solver_for;
    let names = ["lens", "nanojet", "mie_pec", "mie_dielectric", "double_slit", "talbot", "prism", "mirror", "waveguide", "slab"];
    let mut scenes: Vec<(String, beam_core::scene::Scene)> = names.iter().map(|n| (n.to_string(), example(n).unwrap())).collect();
    scenes.push(("slab_airy_0".into(), case_scene("slab_airy_0").unwrap()));
    for (name, mut s) in scenes {
        s.solver.method = Method::Mom;
        for q in [Quality::Preview, Quality::Final] {
            let p = match compile(&s, q) { Ok(p) => p, Err(e) => { eprintln!("{name}: {e:?}"); continue } };
            let est = solver_for(Method::Mom).estimate(&p);
            let t = std::time::Instant::now();
            match solve(&s, q, &SolveContext::new()) {
                Ok(f) => eprintln!(
                    "{name:14} {:7} N {:5} est {:6.3} s meas {:6.3} s  {:?}",
                    q.name(), est.unknowns, est.seconds, t.elapsed().as_secs_f64(),
                    f.meta.solver.timings.iter().map(|(k, v)| format!("{k} {v:.3}")).collect::<Vec<_>>()
                ),
                Err(e) => eprintln!("{name} {}: {e}", q.name()),
            }
        }
    }
}

#[test]
fn block_lu_matches_dense_lu() {
    use beam_core::linalg::{DenseLu, DenseMatrix};
    use beam_core::solver::mom::lu::{norm1, BlockLu};
    use beam_core::types::C64;
    let mut rng = common::Rng(0x9e3779b97f4a7c15);
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
        let (c1, c2) = (ours.cond1_estimate(nrm), theirs.cond1_estimate(nrm));
        assert!((c1 / c2 - 1.0).abs() < 1e-6, "n = {n}: cond {c1} vs {c2}");
    }
}

#[test]
#[ignore]
fn explore_lu_speed() {
    use beam_core::linalg::{DenseLu, DenseMatrix};
    use beam_core::solver::mom::lu::BlockLu;
    use beam_core::types::C64;
    let mut rng = common::Rng(7);
    for n in [1000usize, 2640, 4000] {
        let mut a = DenseMatrix::zeros(n);
        for v in a.data.iter_mut() {
            *v = C64::new(rng.range(-1.0, 1.0), rng.range(-1.0, 1.0));
        }
        let t = std::time::Instant::now();
        let _ = DenseLu::factor(a.clone());
        let t1 = t.elapsed().as_secs_f64();
        let t = std::time::Instant::now();
        let _ = BlockLu::factor(n, a.data, &SolveContext::new(), |_| {}).unwrap();
        eprintln!("n {n}: faer {t1:.3} s, blocked {:.3} s", t.elapsed().as_secs_f64());
    }
}

/// Cancelling during each stage of a mid-sized solve returns within 200 ms.
#[test]
fn cancel_latency() {
    use std::sync::atomic::Ordering;
    use std::time::{Duration, Instant};
    let scene = mom_scene("slab_airy_0", None, None);
    for delay_ms in [20u64, 150, 400, 900] {
        let ctx = SolveContext::new();
        let flag = ctx.cancel_flag();
        let s = scene.clone();
        let handle = std::thread::spawn(move || solve(&s, Quality::Final, &ctx).map(|_| ()));
        std::thread::sleep(Duration::from_millis(delay_ms));
        let t = Instant::now();
        flag.store(true, Ordering::Relaxed);
        let r = handle.join().unwrap();
        let latency = t.elapsed().as_secs_f64();
        eprintln!("cancel after {delay_ms} ms: {:?} in {:.1} ms", r.as_ref().err().map(|e| e.code()), latency * 1e3);
        assert!(latency < 0.2, "cancel after {delay_ms} ms took {latency:.3} s");
    }
}
