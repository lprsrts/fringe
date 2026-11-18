use std::time::Instant;

use fringe_core::linalg::{gemm, DenseLu, DenseMatrix, SparseBuilder, SparseLu, C64};

/// Deterministic xorshift values in [-1, 1).
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> f64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        (self.0 >> 11) as f64 / (1u64 << 52) as f64 - 1.0
    }

    fn c(&mut self) -> C64 {
        C64::new(self.next(), self.next())
    }
}

fn rel_residual_sparse(entries: &[(usize, usize, C64)], x: &[C64], b: &[C64]) -> f64 {
    let mut r = b.to_vec();
    for &(i, j, v) in entries {
        r[i] -= v * x[j];
    }
    let rn: f64 = r.iter().map(|v| v.norm_sqr()).sum::<f64>().sqrt();
    let bn: f64 = b.iter().map(|v| v.norm_sqr()).sum::<f64>().sqrt();
    rn / bn
}

#[test]
fn linalg_sparse_helmholtz_1e5() {
    // 5-point Helmholtz on a 317 × 317 grid with a lossy shift, so the matrix is
    // complex symmetric and indefinite like the FEM system.
    let m = 317usize;
    let n = m * m;
    let h = 1.0 / (m + 1) as f64;
    let k2 = C64::new((2.0 * std::f64::consts::PI * 8.0).powi(2), -50.0);
    let mut b = SparseBuilder::new(n);
    let mut entries = Vec::with_capacity(5 * n);
    let idx = |i: usize, j: usize| j * m + i;
    for j in 0..m {
        for i in 0..m {
            let p = idx(i, j);
            entries.push((p, p, C64::new(4.0 / (h * h), 0.0) - k2));
            if i > 0 {
                entries.push((p, idx(i - 1, j), C64::new(-1.0 / (h * h), 0.0)));
            }
            if i + 1 < m {
                entries.push((p, idx(i + 1, j), C64::new(-1.0 / (h * h), 0.0)));
            }
            if j > 0 {
                entries.push((p, idx(i, j - 1), C64::new(-1.0 / (h * h), 0.0)));
            }
            if j + 1 < m {
                entries.push((p, idx(i, j + 1), C64::new(-1.0 / (h * h), 0.0)));
            }
        }
    }
    // Feed the diagonal in two halves to check that duplicates are summed.
    for &(i, j, v) in &entries {
        if i == j {
            b.add(i, j, v * 0.5);
            b.add(i, j, v * 0.5);
        } else {
            b.add(i, j, v);
        }
    }
    let mut rng = Rng(0x9e3779b97f4a7c15);
    let rhs: Vec<C64> = (0..n).map(|_| rng.c()).collect();
    let t0 = Instant::now();
    let lu = SparseLu::factor(b).expect("factor");
    let t1 = Instant::now();
    let x = lu.solve(&rhs);
    let t2 = Instant::now();
    let res = rel_residual_sparse(&entries, &x, &rhs);
    eprintln!(
        "sparse LU n={n}: factor {:.3} s, solve {:.3} s, residual {res:.2e}",
        (t1 - t0).as_secs_f64(),
        (t2 - t1).as_secs_f64()
    );
    assert_eq!(lu.nnz_matrix(), entries.len());
    assert!(res <= 1e-10, "residual {res}");
}

#[test]
fn linalg_dense_lu_2000() {
    let n = 2000;
    let mut rng = Rng(12345);
    let mut a = DenseMatrix::zeros(n);
    for v in a.data.iter_mut() {
        *v = rng.c();
    }
    for i in 0..n {
        let d = a.get(i, i);
        a.set(i, i, d + C64::new(n as f64 * 0.05, 0.0));
    }
    let rhs: Vec<C64> = (0..n).map(|_| rng.c()).collect();
    let a_copy = a.clone();
    let norm1 = a.norm1();
    let t0 = Instant::now();
    let lu = DenseLu::factor(a);
    let t1 = Instant::now();
    let x = lu.solve(&rhs);
    let ax = a_copy.matvec(&x);
    let res: f64 = ax
        .iter()
        .zip(&rhs)
        .map(|(p, q)| (p - q).norm_sqr())
        .sum::<f64>()
        .sqrt()
        / rhs.iter().map(|v| v.norm_sqr()).sum::<f64>().sqrt();
    eprintln!(
        "dense LU n={n}: factor {:.3} s, residual {res:.2e}",
        (t1 - t0).as_secs_f64()
    );
    assert!(res < 1e-11, "residual {res}");

    // Transpose solve: Aᵀ y = rhs.
    let y = lu.solve_transpose(&rhs);
    let mut aty = vec![C64::new(0.0, 0.0); n];
    for (j, v) in aty.iter_mut().enumerate() {
        for (i, yi) in y.iter().enumerate() {
            *v += a_copy.get(i, j) * yi;
        }
    }
    let res_t: f64 = aty
        .iter()
        .zip(&rhs)
        .map(|(p, q)| (p - q).norm())
        .fold(0.0, f64::max);
    assert!(res_t < 1e-10, "transpose residual {res_t}");

    let cond = lu.cond1_estimate(norm1);
    assert!(cond.is_finite() && cond >= 1.0, "cond {cond}");
}

#[test]
fn linalg_cond_estimate_on_known_matrix() {
    // diag(1, …, 1, 1e-6): cond₁ = 1e6 exactly.
    let n = 50;
    let mut a = DenseMatrix::zeros(n);
    for i in 0..n {
        a.set(i, i, C64::new(1.0, 0.0));
    }
    a.set(n - 1, n - 1, C64::new(1e-6, 0.0));
    let norm = a.norm1();
    let cond = DenseLu::factor(a).cond1_estimate(norm);
    assert!((cond / 1e6 - 1.0).abs() < 1e-9, "cond {cond}");
}

#[test]
fn linalg_gemm_matches_naive() {
    let (m, n, k) = (37, 23, 300);
    let mut rng = Rng(777);
    let a: Vec<C64> = (0..m * k).map(|_| rng.c()).collect();
    let b: Vec<C64> = (0..k * n).map(|_| rng.c()).collect();
    let mut out = vec![C64::new(0.0, 0.0); m * n];
    gemm(m, n, k, &a, &b, &mut out);
    let mut max_err = 0.0f64;
    for j in 0..n {
        for i in 0..m {
            let mut s = C64::new(0.0, 0.0);
            for l in 0..k {
                s += a[l * m + i] * b[j * k + l];
            }
            max_err = max_err.max((s - out[j * m + i]).norm());
        }
    }
    assert!(max_err < 1e-12, "max error {max_err}");
}

mod bessel {
    use fringe_core::special::bessel::*;
    use fringe_core::types::{C64, J};
    use std::f64::consts::PI;


    fn load() -> Vec<(C64, [C64; 6])> {
        let text = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/bessel_ref.json")).unwrap();
        let v: serde_json::Value = serde_json::from_str(&text).unwrap();
        let c = |a: &serde_json::Value| C64::new(a[0].as_f64().unwrap(), a[1].as_f64().unwrap());
        v["points"]
            .as_array()
            .unwrap()
            .iter()
            .map(|p| (c(&p["z"]), [c(&p["j0"]), c(&p["j1"]), c(&p["y0"]), c(&p["y1"]), c(&p["h0"]), c(&p["h1"])]))
            .collect()
    }

    #[test]
    fn spec_reference_values() {
        let cases = [
            (1.0, [0.7651976865579666, 0.4400505857449335, 0.08825696421567696, -0.7812128213002887]),
            (10.0, [-0.2459357644513483, 0.04347274616886144, 0.05567116728359939, 0.24901542420695388]),
        ];
        for (x, want) in cases {
            let (j0, j1, y0, y1) = j_y_01_real(x);
            for (got, want) in [j0, j1, y0, y1].iter().zip(want) {
                assert!(((got - want) / want).abs() <= 1e-12, "x={x}: {got} vs {want}");
            }
        }
    }

    #[test]
    fn fixture_points() {
        let mut worst = 0.0f64;
        for (z, want) in load() {
            let got: [C64; 4] = if z.im == 0.0 {
                let (a, b, c, d) = j_y_01_real(z.re);
                [a.into(), b.into(), c.into(), d.into()]
            } else {
                let (a, b, c, d) = j_y_01_complex(z);
                [a, b, c, d]
            };
            let (h0, h1) = h2_01(z);
            let (hw0, hw1) = (want[4], want[5]);
            for (g, w) in got.iter().zip(want[..4].iter()) {
                let err = (g - w).norm() / w.norm().max(1.0);
                worst = worst.max(err);
                assert!(err <= 1e-10, "z={z}: {g} vs {w} ({err:.1e})");
            }
            for (g, w) in [(h0, hw0), (h1, hw1)] {
                let err = (g - w).norm() / w.norm();
                assert!(err <= 1e-10, "H at z={z}: {g} vs {w} ({err:.1e})");
            }
        }
        eprintln!("worst fixture error {worst:.2e}");
    }

    #[test]
    fn regime_overlap() {
        // The power series and Hankel's expansion agree where the switch happens.
        let mut worst = 0.0f64;
        for k in 0..=40 {
            let x = 10.0 + 4.0 * k as f64 / 40.0;
            let a = series_complex(C64::new(x, 0.0));
            let b = asymptotic_real(x);
            for (p, q) in [(a.0.re, b.0), (a.1.re, b.1), (a.2.re, b.2), (a.3.re, b.3)] {
                worst = worst.max((p - q).abs());
            }
            // Complex arguments: series against the asymptotic H⁽²⁾.
            let z = C64::new(x, -0.3 * x);
            let (j0, j1, y0, y1) = series_complex(z);
            let (h0, h1) = hankel2_asymptotic(z);
            let scale = j0.norm().max(1.0);
            worst = worst.max(((j0 - J * y0) - h0).norm() / scale);
            worst = worst.max(((j1 - J * y1) - h1).norm() / scale);
        }
        assert!(worst <= 1e-10, "{worst:.2e}");
    }

    #[test]
    fn real_miller_neumann_meets_hankel_at_the_switch() {
        // Real arguments switch from Miller–Neumann to Hankel's expansion at x = 20.
        let mut worst = 0.0f64;
        for k in 0..=80 {
            let x = 18.0 + 4.0 * k as f64 / 80.0;
            let a = miller_neumann_real(x);
            let b = asymptotic_real(x);
            for (p, q) in [(a.0, b.0), (a.1, b.1), (a.2, b.2), (a.3, b.3)] {
                worst = worst.max((p - q).abs());
            }
        }
        eprintln!("Miller–Neumann vs Hankel on [18, 22]: {worst:.2e}");
        assert!(worst <= 1e-14, "{worst:.2e}");
    }

    #[test]
    fn chebyshev_tables_match_direct_evaluation() {
        let mut worst = 0.0f64;
        for k in 0..=200_000 {
            let x = 8.0 + 56.0 * k as f64 / 200_000.0;
            let a = j_y_01_real(x);
            let b = j_y_01_real_direct(x);
            for (p, q) in [(a.0, b.0), (a.1, b.1), (a.2, b.2), (a.3, b.3)] {
                worst = worst.max((p - q).abs());
            }
        }
        eprintln!("table vs direct: {worst:.2e}");
        assert!(worst <= 1e-12, "{worst:.2e}");
    }

    #[test]
    fn wronskian() {
        let mut worst = 0.0f64;
        let n = 400;
        for k in 0..=n {
            let x = 1e-3 * (5e5f64).powf(k as f64 / n as f64);
            let (j0, j1, y0, y1) = j_y_01_real(x);
            let w = 2.0 / (PI * x);
            worst = worst.max(((j1 * y0 - j0 * y1) - w).abs() / w);
            // In the lower half plane J and Y grow like e^{|Im z|} while H⁽²⁾ decays,
            // so the J–Y form cancels catastrophically; J1 H0 − J0 H1 = −2j/(πz)
            // has no such cancellation.
            let z = C64::new(x, -0.1 * x);
            let (cj0, cj1, _, _) = j_y_01_complex(z);
            let (h0, h1) = h2_01(z);
            let wz = -2.0 * J / (PI * z);
            worst = worst.max(((cj1 * h0 - cj0 * h1) - wz).norm() / wz.norm());
        }
        assert!(worst <= 1e-10, "{worst:.2e}");
    }

    #[test]
    fn miller_arrays() {
        for z in [C64::new(0.5, 0.0), C64::new(3.0, -0.5), C64::new(10.0, 0.0), C64::new(25.0, -2.0), C64::new(40.0, -0.1)] {
            let n = 60;
            let jn = bessel_j_array(n, z);
            let (j0, j1, _, _) = j_y_01_complex(z);
            let scale = j0.norm().max(j1.norm()).max(1.0);
            assert!((jn[0] - j0).norm() <= 1e-12 * scale, "z = {z}: {} vs {j0}", jn[0]);
            assert!((jn[1] - j1).norm() <= 1e-12 * scale, "z = {z}: {} vs {j1}", jn[1]);
            for k in 1..n {
                let lhs = jn[k - 1] + jn[k + 1];
                let rhs = 2.0 * k as f64 / z * jn[k];
                assert!((lhs - rhs).norm() <= 1e-12 * scale.max(rhs.norm()), "z = {z}, n = {k}");
            }
        }
        // Hankel arrays: the recurrence and agreement with h2_01.
        for x in [0.3, 4.0, 15.0, 60.0] {
            let h = hankel2_array(30, x);
            let (h0, h1) = h2_01(C64::new(x, 0.0));
            assert!((h[0] - h0).norm() <= 1e-12 * h0.norm() && (h[1] - h1).norm() <= 1e-12 * h1.norm());
            for k in 1..30 {
                let lhs = h[k - 1] + h[k + 1];
                let rhs = 2.0 * k as f64 / x * h[k];
                assert!((lhs - rhs).norm() <= 1e-10 * rhs.norm().max(1.0), "x = {x}, n = {k}");
            }
        }
        // Derivatives: J0′ = −J1 and Jₙ′ from the array match finite differences.
        let z = C64::new(2.7, -0.2);
        let d = bessel_deriv(&bessel_j_array(10, z), z);
        let h = 1e-6;
        let jp = bessel_j_array(10, z + h);
        let jm = bessel_j_array(10, z - h);
        for k in 0..=10 {
            assert!(((jp[k] - jm[k]) / (2.0 * h) - d[k]).norm() < 1e-8, "n = {k}");
        }
    }
}

mod greens {
    use fringe_core::special::greens::*;
    use fringe_core::types::{Vec2, C64};
    use std::f64::consts::PI;

    #[test]
    fn small_circle_flux_is_minus_one() {
        // ∮ ∂_n G dl around the source, n pointing away from it: −1 for ∇²G + k²G = −δ.
        // The exact value is −1 − k² ∫ G dA over the disk, a relative correction of
        // about (kρ)² ln(kρ)/2: 1e−4 at kρ = 2π·10⁻³, so the radius is 1e−5 here.
        for k in [C64::new(2.0 * PI, 0.0), C64::new(3.0, -0.4)] {
            let rho = 1e-5;
            let n = 64;
            let mut s = C64::new(0.0, 0.0);
            for i in 0..n {
                let t = 2.0 * PI * i as f64 / n as f64;
                let nx = Vec2::from_angle(t);
                let x = nx * rho;
                let rad = radial(k, rho);
                let kv = kernels(&rad, x, Vec2::ZERO, nx, nx);
                s += kv.dn_x * rho * 2.0 * PI / n as f64;
            }
            assert!((s + 1.0).norm() <= 1e-6, "k = {k}: {s}");
        }
    }

    #[test]
    fn green_function_is_outgoing_and_log_singular() {
        let k = C64::new(2.0 * PI, 0.0);
        // Near the source G ≈ −(1/2π) ln R + const.
        let a = radial(k, 1e-6).g;
        let b = radial(k, 1e-5).g;
        assert!(((a - b).re - (-(1e-6f64).ln() + (1e-5f64).ln()) / (2.0 * PI)).abs() < 1e-6);
        // Far away the phase falls like e^{−jkR}.
        let g1 = radial(k, 50.0).g;
        let g2 = radial(k, 50.01).g;
        assert!(((g2 / g1).arg() + 2.0 * PI * 0.01).abs() < 1e-3);
    }

    #[test]
    fn derivatives_match_finite_differences() {
        for k in [C64::new(5.0, 0.0), C64::new(7.0, -1.0)] {
            for r in [0.05, 0.7, 3.0, 20.0] {
                let h = 1e-6 * r;
                let (a, b, c) = (radial(k, r - h), radial(k, r), radial(k, r + h));
                let dg = (c.g - a.g) / (2.0 * h);
                let d2g = (c.dg - a.dg) / (2.0 * h);
                assert!((dg - b.dg).norm() <= 1e-6 * b.dg.norm(), "k = {k}, r = {r}");
                assert!((d2g - b.d2g).norm() <= 1e-6 * b.d2g.norm(), "k = {k}, r = {r}");
            }
        }
    }

    #[test]
    fn difference_series_matches_direct() {
        let pairs = [
            (C64::new(2.0 * PI, 0.0), C64::new(3.0 * PI, 0.0)),
            (C64::new(2.0 * PI, 0.0), C64::new(1.5 * 2.0 * PI, -0.05 * 2.0 * PI)),
            (C64::new(1.0, 0.0), C64::new(3.5, -1.0)),
        ];
        let mut worst = 0.0f64;
        for (kb, ki) in pairs {
            let kmax = kb.norm().max(ki.norm());
            for s in 0..=10 {
                let r = (0.5 + 0.5 * s as f64 / 10.0) / kmax;
                let a = radial_diff_series(kb, ki, r);
                let (gb, gi) = (radial(kb, r), radial(ki, r));
                worst = worst.max((a.g - (gb.g - gi.g)).norm());
                worst = worst.max((a.dg - (gb.dg - gi.dg)).norm() * r);
                worst = worst.max((a.d2g - (gb.d2g - gi.d2g)).norm() * r * r);
            }
        }
        assert!(worst <= 1e-10, "{worst:.2e}");
        // At tiny R the series stays finite where the direct difference cancels.
        let d = radial_diff(C64::new(1.0, 0.0), C64::new(2.0, -0.1), 1e-9);
        assert!(d.g.is_finite() && d.dg.is_finite() && d.d2g.is_finite());
    }
}

mod quadrature {
    use fringe_core::special::{gauss_legendre, triangle_rule};

    #[test]
    fn gauss_legendre_exact_to_degree_2n_minus_1() {
        for n in [1, 2, 3, 5, 8, 16, 33, 64, 100] {
            let gl = gauss_legendre(n);
            for d in 0..2 * n {
                let got: f64 = gl.nodes.iter().zip(&gl.weights).map(|(x, w)| w * x.powi(d as i32)).sum();
                let want = if d % 2 == 1 { 0.0 } else { 2.0 / (d as f64 + 1.0) };
                assert!((got - want).abs() <= 1e-13, "n = {n}, degree {d}: {got} vs {want}");
            }
        }
    }

    #[test]
    fn triangle_rule_exact_for_monomials() {
        // ∫ ξ^a η^b over the reference triangle = a! b! / (a + b + 2)!
        let fact = |n: usize| (1..=n).map(|k| k as f64).product::<f64>();
        for degree in [1, 2, 4, 6, 8, 12] {
            let rule = triangle_rule(degree);
            for a in 0..=degree {
                for b in 0..=degree - a {
                    let got: f64 = rule
                        .points
                        .iter()
                        .zip(&rule.weights)
                        .map(|(p, w)| w * p[0].powi(a as i32) * p[1].powi(b as i32))
                        .sum();
                    let want = fact(a) * fact(b) / fact(a + b + 2);
                    assert!((got - want).abs() <= 1e-14, "degree {degree}: ξ^{a} η^{b}: {got} vs {want}");
                }
            }
        }
    }
}

/// H0⁽²⁾ and H1⁽²⁾ deep in the lower half plane, where a metal's interior
/// wavenumber k0(n − jk) with n ≪ k puts the Green's function, against
/// `H0⁽²⁾(z) = (2j/π) ∫₀^∞ e^{−jz cosh t} dt` and
/// `H1⁽²⁾(z) = −(2/π) ∫₀^∞ cosh t e^{−jz cosh t} dt` (Im z < 0). Below the
/// asymptotic switch the error grows like e^{2|Im z|}·1e−16 (9e−8 at z = −10j),
/// where H⁽²⁾ itself is already e^{−10} of its size near the source.
#[test]
fn hankel_in_the_lower_half_plane() {
    use fringe_core::special::bessel::h2_01;
    use std::f64::consts::PI;
    let j = C64::new(0.0, 1.0);
    let mut worst = 0.0f64;
    for &rho in &[0.3, 1.0, 3.0, 7.5, 10.0, 15.0, 25.0] {
        for &deg in &[-45.0f64, -60.0, -75.0, -85.0, -89.0, -90.0] {
            let z = C64::from_polar(rho, deg.to_radians());
            let (mut i0, mut i1) = (C64::new(0.0, 0.0), C64::new(0.0, 0.0));
            let h = 2e-4f64;
            let mut t = 0.0f64;
            while t < 14.0 {
                let w = if t == 0.0 { 0.5 * h } else { h };
                let e = (-j * z * t.cosh()).exp();
                i0 += w * e;
                i1 += w * t.cosh() * e;
                if e.norm() < 1e-20 {
                    break;
                }
                t += h;
            }
            let (h0, h1) = h2_01(z);
            let r0 = 2.0 * j / PI * i0;
            let r1 = -2.0 / PI * i1;
            let e = ((h0 - r0).norm() / r0.norm()).max((h1 - r1).norm() / r1.norm());
            worst = worst.max(e);
            assert!(e < 2e-7, "z = {z}: H0 {h0} vs {r0}, H1 {h1} vs {r1} ({e:.1e})");
        }
    }
    eprintln!("worst relative error {worst:.1e}");
}
