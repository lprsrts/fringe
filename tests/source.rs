use std::f64::consts::PI;

use fringe_core::analytic::paraxial_gaussian;
use fringe_core::scene::examples;
use fringe_core::solver::GridSpec;
use fringe_core::source::yee::{dispersion_factor, yee_wavenumber};
use fringe_core::source::Incident;
use fringe_core::types::{Rect, Vec2, C64};

const K: f64 = 2.0 * PI; // λ = 1 µm, n_b = 1

fn beam(w0: f64, waist: Vec2, angle: f64, rect: Rect) -> Incident {
    Incident::gaussian(K, w0, waist, angle, 1.3, 0.4, rect)
}

/// Deterministic points in a rectangle.
fn points(r: Rect, n: usize, seed: u64) -> Vec<Vec2> {
    let mut s = seed;
    let mut next = move || {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        (s >> 11) as f64 / (1u64 << 53) as f64
    };
    (0..n).map(|_| Vec2::new(r.x_min + next() * r.width(), r.y_min + next() * r.height())).collect()
}

#[test]
fn waist_value_is_exact() {
    let inc = beam(3.0, Vec2::new(-6.0, 0.0), 0.0, Rect::new(-13.0, 21.0, -10.0, 10.0));
    let e = inc.eval(Vec2::new(-6.0, 0.0));
    let want = 1.3 * C64::new(0.4f64.cos(), 0.4f64.sin());
    assert!((e - want).norm() < 1e-14, "{e} vs {want}");
    assert!(inc.warnings.is_empty());
}

#[test]
fn grid_matches_pointwise() {
    let inc = beam(3.0, Vec2::new(-6.0, 0.0), 0.3, Rect::new(-13.0, 21.0, -10.0, 10.0));
    let g = GridSpec { x0: -12.0, y0: -9.0, dx: 0.37, nx: 87, ny: 49 };
    let grid = inc.eval_grid(&g);
    let mut worst = 0.0f64;
    for j in 0..g.ny {
        for i in 0..g.nx {
            worst = worst.max((grid[g.index(i, j)] - inc.eval(g.point(i, j))).norm());
        }
    }
    assert!(worst <= 1e-12 * 1.3, "{worst}");
}

#[test]
fn grid_is_fast_enough() {
    // 1M points with a few hundred components; about 60 ms on an M-series
    // Mac, checked loosely here so slow CI machines do not fail.
    let inc = beam(1.0, Vec2::new(0.0, 0.0), 0.0, Rect::new(-40.0, 40.0, -40.0, 40.0));
    let g = GridSpec { x0: -20.0, y0: -20.0, dx: 0.04, nx: 1000, ny: 1000 };
    let t = std::time::Instant::now();
    let v = inc.eval_grid(&g);
    let dt = t.elapsed().as_secs_f64();
    eprintln!("eval_grid 1M points, M = {}: {:.1} ms", inc.comps.len(), dt * 1e3);
    assert_eq!(v.len(), 1_000_000);
    assert!(dt < 1.0);
}

#[test]
fn waist_profile() {
    for (w0, tol) in [(3.0, 1e-9), (1.0, 2e-3)] {
        let inc = Incident::gaussian(K, w0, Vec2::ZERO, 0.0, 1.0, 0.0, Rect::new(-10.0, 10.0, -10.0, 10.0));
        let mut worst = 0.0f64;
        for k in 0..=120 {
            let eta = -3.0 * w0 + 6.0 * w0 * k as f64 / 120.0;
            let e = inc.eval(Vec2::new(0.0, eta));
            worst = worst.max((e - (-(eta * eta) / (w0 * w0)).exp()).norm());
        }
        assert!(worst <= tol, "w0 = {w0}: {worst:.2e}");
    }
}

#[test]
fn matches_brute_force_spectrum() {
    // Composite Simpson in κ over (−k, k) of the untruncated spectrum.
    let w0 = 3.0;
    let inc = Incident::gaussian(K, w0, Vec2::ZERO, 0.0, 1.0, 0.0, Rect::new(-12.0, 20.0, -9.0, 9.0));
    let n = 200_000;
    let h = 2.0 * K / n as f64;
    let field = |p: Vec2| {
        let mut s = C64::new(0.0, 0.0);
        for i in 0..=n {
            let kappa = -K + i as f64 * h;
            let w = if i == 0 || i == n { 1.0 } else if i % 2 == 1 { 4.0 } else { 2.0 };
            let kx = (K * K - kappa * kappa).max(0.0).sqrt();
            let a = (-(w0 * kappa).powi(2) / 4.0).exp();
            s += w * a * C64::new(0.0, -(kx * p.x + kappa * p.y)).exp();
        }
        s * h / 3.0
    };
    let norm = field(Vec2::ZERO);
    let mut worst = 0.0f64;
    for p in points(Rect::new(-12.0, 20.0, -9.0, 9.0), 50, 99) {
        worst = worst.max((inc.eval(p) - field(p) / norm).norm());
    }
    assert!(worst <= 1e-9, "{worst:.2e}");
}

#[test]
fn solves_helmholtz() {
    let inc = beam(1.0, Vec2::new(-2.0, 1.0), 0.5, Rect::new(-10.0, 10.0, -10.0, 10.0));
    let h = 1.0 / 50.0;
    let mut worst = 0.0f64;
    for p in points(Rect::new(-8.0, 8.0, -8.0, 8.0), 100, 7) {
        let f = |dx: f64, dy: f64| inc.eval(Vec2::new(p.x + dx * h, p.y + dy * h));
        let d2 = |a: C64, b: C64, c: C64, d: C64, e: C64| (-a + 16.0 * b - 30.0 * c + 16.0 * d - e) / (12.0 * h * h);
        let c = f(0.0, 0.0);
        let lap = d2(f(-2.0, 0.0), f(-1.0, 0.0), c, f(1.0, 0.0), f(2.0, 0.0))
            + d2(f(0.0, -2.0), f(0.0, -1.0), c, f(0.0, 1.0), f(0.0, 2.0));
        worst = worst.max((lap + K * K * c).norm());
    }
    assert!(worst <= 1e-5 * K * K * 1.3, "{worst:.2e}");
}

#[test]
fn gradient_matches_finite_differences() {
    let inc = beam(2.0, Vec2::new(0.0, 0.0), 0.2, Rect::new(-6.0, 6.0, -6.0, 6.0));
    let h = 1e-5;
    for p in points(Rect::new(-5.0, 5.0, -5.0, 5.0), 10, 3) {
        let (e, g) = inc.eval_grad(p);
        assert!((e - inc.eval(p)).norm() < 1e-14);
        let gx = (inc.eval(Vec2::new(p.x + h, p.y)) - inc.eval(Vec2::new(p.x - h, p.y))) / (2.0 * h);
        let gy = (inc.eval(Vec2::new(p.x, p.y + h)) - inc.eval(Vec2::new(p.x, p.y - h))) / (2.0 * h);
        assert!((gx - g[0]).norm() < 1e-7 && (gy - g[1]).norm() < 1e-7);
    }
}

#[test]
fn paraxial_limit() {
    let w0 = 10.0;
    let z_r = 0.5 * K * w0 * w0;
    let inc = Incident::gaussian(K, w0, Vec2::ZERO, 0.0, 1.0, 0.0, Rect::new(-z_r, z_r, -60.0, 60.0));
    let mut worst = 0.0f64;
    for a in 0..=10 {
        let xi = -z_r + 2.0 * z_r * a as f64 / 10.0;
        let w = w0 * (1.0 + (xi / z_r).powi(2)).sqrt();
        for b in 0..=10 {
            let eta = -2.0 * w + 4.0 * w * b as f64 / 10.0;
            let e = inc.eval(Vec2::new(xi, eta));
            worst = worst.max((e - paraxial_gaussian(1.0, K, w0, xi, eta)).norm());
        }
    }
    assert!(worst <= 3e-3, "{worst:.2e}");
}

#[test]
fn tilted_beam_is_rotated_beam() {
    let waist = Vec2::new(1.0, -2.0);
    let r = Rect::new(waist.x - 8.0, waist.x + 8.0, waist.y - 8.0, waist.y + 8.0);
    let theta = 30f64.to_radians();
    let tilted = beam(1.5, waist, theta, r);
    let straight = beam(1.5, waist, 0.0, r);
    assert_eq!(tilted.comps.len(), straight.comps.len());
    let mut worst = 0.0f64;
    for p in points(Rect::new(-5.0, 5.0, -6.0, 4.0), 50, 11) {
        let q = waist + (p - waist).rotate(-theta);
        worst = worst.max((tilted.eval(p) - straight.eval(q)).norm());
    }
    assert!(worst <= 1e-12 * 1.3, "{worst:.2e}");
}

#[test]
fn plane_wave_convention() {
    // e^{−jk(x cos θ + y sin θ)}: the phase decreases along the propagation direction.
    let inc = Incident::plane_wave(K, 0.0, 1.0, 0.0);
    let e = inc.eval(Vec2::new(0.25, 0.0));
    assert!((e - C64::new(0.0, -1.0)).norm() < 1e-14);
}

#[test]
fn yee_matched_components_solve_the_discrete_scheme() {
    let (eps_b, k0) = (1.0, K);
    let dx = 1.0 / 24.0;
    let dt = 1.0 / (24.0 / 0.6f64).ceil();
    let inc = beam(1.0, Vec2::ZERO, 0.4, Rect::new(-4.0, 4.0, -4.0, 4.0));
    let matched = inc.map_wavenumbers(|phi| yee_wavenumber(phi, eps_b, k0, dx, dt));
    for c in &matched.comps {
        let kt = (c.k[0] * c.k[0] + c.k[1] * c.k[1]).sqrt();
        let phi = c.k[1].atan2(c.k[0]);
        let lhs = eps_b * (0.5 * k0 * dt).sin().powi(2) / (dt * dt);
        let rhs = ((0.5 * kt * phi.cos() * dx).sin().powi(2) + (0.5 * kt * phi.sin() * dx).sin().powi(2)) / (dx * dx);
        assert!((lhs - rhs).abs() <= 1e-12 * lhs, "{lhs} vs {rhs}");
    }
    let field = |i: i64, j: i64, n: i64| {
        let p = Vec2::new(i as f64 * dx, j as f64 * dx);
        (matched.eval(p) * C64::new(0.0, k0 * n as f64 * dt).exp()).re
    };
    for (i, j, n) in [(3, 5, 7), (-10, 4, 2), (20, -13, 11), (0, 0, 0), (7, 7, 30)].iter().cycle().take(20).enumerate().map(|(s, &(i, j, n))| (i + s as i64, j - s as i64, n + s as i64)) {
        let lhs = eps_b * (field(i, j, n + 1) - 2.0 * field(i, j, n) + field(i, j, n - 1)) / (dt * dt);
        let rhs = (field(i + 1, j, n) + field(i - 1, j, n) + field(i, j + 1, n) + field(i, j - 1, n) - 4.0 * field(i, j, n)) / (dx * dx);
        assert!((lhs - rhs).abs() <= 1e-9 * k0 * k0 * 1.3, "{lhs} vs {rhs}");
    }
}

#[test]
fn dispersion_correction_makes_the_axis_exact() {
    let k0 = K;
    let dx = 1.0 / 20.0;
    let dt = 1.0 / (20.0 * 1.5 / 0.6f64).ceil();
    for (n, theta) in [(1.0, 0.0), (1.5, 0.3), (2.0, 1.1), (1.33, -0.7)] {
        let f = dispersion_factor(n, theta, k0, dx, dt);
        let kt = yee_wavenumber(theta, n * n * f, k0, dx, dt);
        assert!((kt - k0 * n).abs() <= 1e-12 * k0 * n, "n = {n}: {kt} vs {}", k0 * n);
    }
}

#[test]
fn default_scene_incident_is_accurate() {
    let s = examples::default();
    let outer = s.domain.rect().expand(1.0);
    let inc = Incident::from_scene(&s, outer);
    assert!(inc.warnings.is_empty());
    eprintln!("default scene: {} components", inc.comps.len());
    assert!(inc.comps.len() < 400);
}

/// Built directly (no validation), a beam whose waist is far from the domain
/// stops at the component cap with an accuracy warning instead of growing the
/// quadrature without bound.
#[test]
fn far_waist_is_capped() {
    use fringe_core::source::gaussian::MAX_COMPONENTS;
    let t = std::time::Instant::now();
    let inc = beam(0.1, Vec2::new(-10000.0, 0.0), 0.0, Rect::new(-6.0, 10.0, -4.5, 4.5));
    assert!(inc.comps.len() <= MAX_COMPONENTS, "{} components", inc.comps.len());
    assert!(!inc.warnings.is_empty());
    assert!(t.elapsed().as_secs_f64() < 5.0, "took {:.1} s", t.elapsed().as_secs_f64());
}
