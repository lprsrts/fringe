//! Cross-solver agreement: the default lens scene against a
//! self-converged MoM reference, the double slit, and the energy balance of
//! the lossless lens. All slow; run with
//! `cargo test --release --test cross_solver -- --ignored --nocapture`.
//!
//! Every comparison is made on the reference's output grid. A solution on
//! another grid is sampled there (bicubic), so a coarse preview carries some
//! interpolation error on top of its discretisation error.

use std::sync::OnceLock;

use beam_core::analytic::metrics::{flux_balance, focal_peak, interface_band, rel_l2, resample};
use beam_core::geometry::bodies_from_scene;
use beam_core::scene::{examples, Scene};
use beam_core::solver::{solve, FieldGrid, Method, Part, Quality, SolveContext};
use beam_core::types::C64;

const ALL: [Method; 3] = [Method::Mom, Method::Fem, Method::Fdtd];

fn run(scene: &Scene, method: Method, quality: Quality, mom_ppw: Option<f64>) -> FieldGrid {
    let mut s = scene.clone();
    s.solver.method = method;
    if let Some(ppw) = mom_ppw {
        s.solver.mom.final_ppw = Some(ppw);
    }
    let t = std::time::Instant::now();
    let f = solve(&s, quality, &SolveContext::new()).unwrap_or_else(|e| panic!("{} {}: {e}", method.label(), quality.name()));
    eprintln!(
        "  solved {} {} in {:.2} s ({} unknowns){}",
        method.label(),
        quality.name(),
        t.elapsed().as_secs_f64(),
        f.meta.solver.unknowns,
        if f.meta.solver.warnings.is_empty() { String::new() } else { format!(", warnings {:?}", f.meta.solver.warnings) }
    );
    f
}

/// Relative L2 difference of `field` from `reference` on the reference grid,
/// over the points where `keep` holds, outside PEC, and (for an FDTD field)
/// farther than 2Δ from any interface, Δ being the FDTD cell.
fn difference(field: &FieldGrid, reference: &FieldGrid, keep: impl Fn(f64, f64) -> bool) -> f64 {
    let g = &reference.grid;
    let sampled = resample(field, Part::Total, g);
    let band = if field.meta.method == Method::Fdtd {
        interface_band(g, &bodies_from_scene(&reference.scene), 2.0 * field.grid.dx)
    } else {
        vec![false; g.len()]
    };
    let mask: Vec<bool> = (0..g.len())
        .map(|i| {
            let p = g.point(i % g.nx, i / g.nx);
            keep(p.x, p.y) && !reference.is_pec(i) && sampled[i].is_some() && !band[i]
        })
        .collect();
    let values: Vec<C64> = sampled.into_iter().map(|v| v.unwrap_or_default()).collect();
    rel_l2(&values, &reference.total, Some(&mask))
}

/// Focal peak of the lens: the maximum of |E|² on y = 0 for x in [0, 19].
fn focus(f: &FieldGrid) -> (f64, f64) {
    focal_peak(f, 0.0, 0.0, 19.0).expect("no focal peak")
}

fn lens() -> Scene {
    examples::example("lens").unwrap()
}

/// MoM at final quality with 20 panels per wavelength, after checking it
/// against 16 (spec: ≤ 2e-3). Shared by the lens tests.
fn lens_reference() -> &'static FieldGrid {
    static REFERENCE: OnceLock<FieldGrid> = OnceLock::new();
    REFERENCE.get_or_init(|| {
        let scene = lens();
        let coarse = run(&scene, Method::Mom, Quality::Final, Some(16.0));
        let fine = run(&scene, Method::Mom, Quality::Final, Some(20.0));
        let e = difference(&coarse, &fine, |_, _| true);
        eprintln!("lens reference: MoM 16 vs 20 ppw {e:.3e}");
        assert!(e <= 2e-3, "MoM self-convergence 16 vs 20 ppw: {e:.3e} > 2e-3");
        fine
    })
}

#[test]
#[ignore]
fn lens_final_against_the_mom_reference() {
    let reference = lens_reference();
    let (x_ref, peak_ref) = focus(reference);
    eprintln!("reference focus x = {x_ref:.3} µm, |E|² = {peak_ref:.4}");
    let mut failures = Vec::new();
    for (method, bound) in [(Method::Mom, None), (Method::Fem, Some(2e-2)), (Method::Fdtd, Some(6e-2))] {
        let f = run(&lens(), method, Quality::Final, None);
        let e = difference(&f, reference, |_, _| true);
        let (x, peak) = focus(&f);
        let dpeak = (peak - peak_ref).abs() / peak_ref;
        eprintln!(
            "lens {} final: difference {e:.3e} (bound {bound:?}), focus x = {x:.3} µm (Δ {:.3}), peak |E|² {peak:.4} (Δ {:.2} %)",
            method.label(),
            x - x_ref,
            100.0 * dpeak
        );
        if bound.is_some_and(|b| e > b) {
            failures.push(format!("{} difference {e:.3e} > {:.0e}", method.label(), bound.unwrap()));
        }
        if (x - x_ref).abs() > 0.25 {
            failures.push(format!("{} focus off by {:.3} µm", method.label(), x - x_ref));
        }
        if dpeak > 0.04 {
            failures.push(format!("{} peak |E|² off by {:.2} %", method.label(), 100.0 * dpeak));
        }
    }
    assert!(failures.is_empty(), "{failures:?}");
}

#[test]
#[ignore]
fn lens_previews_against_the_mom_reference() {
    let reference = lens_reference();
    let (x_ref, _) = focus(reference);
    let mut failures = Vec::new();
    for method in ALL {
        let f = run(&lens(), method, Quality::Preview, None);
        let e = difference(&f, reference, |_, _| true);
        let (x, _) = focus(&f);
        eprintln!("lens {} preview: difference {e:.3e}, focus x = {x:.3} µm (Δ {:.3})", method.label(), x - x_ref);
        if e > 0.15 {
            failures.push(format!("{} preview difference {e:.3e} > 0.15", method.label()));
        }
        if (x - x_ref).abs() > 1.0 {
            failures.push(format!("{} preview focus off by {:.3} µm", method.label(), x - x_ref));
        }
    }
    assert!(failures.is_empty(), "{failures:?}");
}

#[test]
#[ignore]
fn double_slit_against_mom() {
    let scene = examples::example("double_slit").unwrap();
    let reference = run(&scene, Method::Mom, Quality::Final, None);
    let mut failures = Vec::new();
    for (method, bound) in [(Method::Fem, 3e-2), (Method::Fdtd, 8e-2)] {
        let f = run(&scene, method, Quality::Final, None);
        let e = difference(&f, &reference, |x, _| x >= -4.0);
        eprintln!("double slit {} vs MoM on x ≥ −4: {e:.3e} (bound {bound:.0e})", method.label());
        if e > bound {
            failures.push(format!("{} {e:.3e} > {bound:.0e}", method.label()));
        }
    }
    assert!(failures.is_empty(), "{failures:?}");
}

/// `|Im ∮ E* ∂_n E| / ∮ |Im(E_s* ∂_n E_s)|` on the rectangle 0.5 µm inside the
/// interior: the lens absorbs nothing, so the net inflow must vanish.
#[test]
#[ignore]
fn lens_energy_balance() {
    let scene = lens();
    let mut failures = Vec::new();
    for (method, bound) in [(Method::Mom, 2e-3), (Method::Fem, 5e-3), (Method::Fdtd, 2e-2)] {
        let f = run(&scene, method, Quality::Final, None);
        let fb = flux_balance(&f, f.scene.domain.rect().expand(-0.5));
        let r = fb.residual();
        eprintln!(
            "lens {} balance: {r:.3e} (inflow {:.3e}, scattered flux {:.3e}, bound {bound:.0e})",
            method.label(),
            fb.inflow,
            fb.scattered_flux
        );
        if r > bound {
            failures.push(format!("{} {r:.3e} > {bound:.0e}", method.label()));
        }
    }
    assert!(failures.is_empty(), "{failures:?}");
}
