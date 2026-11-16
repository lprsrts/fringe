use std::time::Instant;

use beam_core::linalg::{gemm, DenseLu, DenseMatrix, SparseBuilder, SparseLu, C64};

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
    for j in 0..n {
        for i in 0..n {
            aty[j] += a_copy.get(i, j) * y[i];
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
