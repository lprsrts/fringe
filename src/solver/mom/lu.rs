//! Interruptible dense LU with partial pivoting (right-looking, blocked).
//!
//! The shared `linalg::DenseLu` factors in one uninterruptible faer call, which
//! for the largest MoM systems runs for tens of seconds. This factorisation
//! checks the cancel flag between trailing-update chunks of a few tens of
//! milliseconds, so a MoM solve cancels within the 200 ms budget at any size.
//! The trailing update, which is almost all of the work, goes through
//! `linalg::gemm` (faer, parallel); panels, pivoting and triangular solves are
//! done here.

use rayon::prelude::*;

use crate::linalg::gemm;
use crate::solver::{SolveContext, SolveError};
use crate::types::C64;

/// Panel width.
const NB: usize = 64;
/// Column chunk of the trailing update between cancellation checks.
const CW: usize = 384;
/// Below this many element updates a step runs sequentially.
const PAR_MIN: usize = 1 << 15;

const ZERO: C64 = C64::new(0.0, 0.0);

/// `PA = LU` in place: L unit lower (below the diagonal), U upper; `piv[k]` is
/// the row swapped with row k at step k.
pub struct BlockLu {
    n: usize,
    a: Vec<C64>,
    piv: Vec<usize>,
}

#[inline]
fn cabs1(z: C64) -> f64 {
    z.re.abs() + z.im.abs()
}

/// Largest column sum of |a_ij| of a column-major n × n matrix.
pub fn norm1(n: usize, a: &[C64]) -> f64 {
    a.par_chunks(n.max(1)).map(|c| c.iter().map(|v| v.norm()).sum::<f64>()).reduce(|| 0.0, f64::max)
}

impl BlockLu {
    /// Factors the column-major `a` (n × n). `progress` gets the fraction of the
    /// flops done. A zero pivot does not fail; the solves then return non-finite
    /// values.
    pub fn factor(n: usize, mut a: Vec<C64>, ctx: &SolveContext, progress: impl Fn(f64)) -> Result<BlockLu, SolveError> {
        assert_eq!(a.len(), n * n);
        let mut piv: Vec<usize> = (0..n).collect();
        let total = (n as f64).powi(3).max(1.0);
        for k0 in (0..n).step_by(NB) {
            let k1 = (k0 + NB).min(n);
            let kb = k1 - k0;
            factor_panel(n, &mut a, &mut piv, k0, k1);

            // The panel's row swaps on every other column.
            let swaps = &piv[k0..k1];
            let apply = |col: &mut [C64]| {
                for (k, &p) in (k0..k1).zip(swaps) {
                    if p != k {
                        col.swap(k, p);
                    }
                }
            };
            a[..k0 * n].par_chunks_mut(n).for_each(apply);
            a[k1 * n..].par_chunks_mut(n).for_each(apply);

            let m = n - k1;
            if m == 0 {
                break;
            }
            let (left, right) = a.split_at_mut(k1 * n);
            // U12 = L11⁻¹ A12.
            right.par_chunks_mut(n).for_each(|col| {
                for k in k0..k1 {
                    let x = col[k];
                    if x != ZERO {
                        let l = &left[k * n..(k + 1) * n];
                        for r in k + 1..k1 {
                            col[r] -= l[r] * x;
                        }
                    }
                }
            });
            // A22 −= L21 U12, in column chunks.
            let mut l21 = vec![ZERO; m * kb];
            for (jj, k) in (k0..k1).enumerate() {
                l21[jj * m..(jj + 1) * m].copy_from_slice(&left[k * n + k1..(k + 1) * n]);
            }
            let mut u = vec![ZERO; kb * CW.min(m)];
            let mut tmp = vec![ZERO; m * CW.min(m)];
            for c0 in (0..m).step_by(CW) {
                ctx.checkpoint()?;
                let w = CW.min(m - c0);
                for cc in 0..w {
                    let col = &right[(c0 + cc) * n..(c0 + cc + 1) * n];
                    u[cc * kb..(cc + 1) * kb].copy_from_slice(&col[k0..k1]);
                }
                gemm(m, w, kb, &l21, &u[..kb * w], &mut tmp[..m * w]);
                right[c0 * n..(c0 + w) * n].par_chunks_mut(n).zip(tmp[..m * w].par_chunks(m)).for_each(|(col, t)| {
                    for (x, y) in col[k1..].iter_mut().zip(t) {
                        *x -= y;
                    }
                });
            }
            let rest = (m as f64).powi(3);
            progress(1.0 - rest / total);
        }
        Ok(BlockLu { n, a, piv })
    }

    pub fn n(&self) -> usize {
        self.n
    }

    /// Solves `A x = b`.
    pub fn solve(&self, b: &[C64]) -> Vec<C64> {
        let n = self.n;
        let a = &self.a;
        let mut x = b.to_vec();
        for k in 0..n {
            let p = self.piv[k];
            if p != k {
                x.swap(k, p);
            }
        }
        for k in 0..n {
            let xk = x[k];
            if xk != ZERO {
                let col = &a[k * n..(k + 1) * n];
                for r in k + 1..n {
                    x[r] -= col[r] * xk;
                }
            }
        }
        for k in (0..n).rev() {
            let col = &a[k * n..(k + 1) * n];
            x[k] /= col[k];
            let xk = x[k];
            if xk != ZERO {
                for r in 0..k {
                    x[r] -= col[r] * xk;
                }
            }
        }
        x
    }

    /// Solves `Aᵀ x = b` (transpose, not conjugate transpose): `Uᵀ Lᵀ P x = b`.
    pub fn solve_transpose(&self, b: &[C64]) -> Vec<C64> {
        let n = self.n;
        let a = &self.a;
        let mut x = b.to_vec();
        for k in 0..n {
            let col = &a[k * n..(k + 1) * n];
            let mut s = x[k];
            for r in 0..k {
                s -= col[r] * x[r];
            }
            x[k] = s / col[k];
        }
        for k in (0..n).rev() {
            let col = &a[k * n..(k + 1) * n];
            let mut s = x[k];
            for r in k + 1..n {
                s -= col[r] * x[r];
            }
            x[k] = s;
        }
        for k in (0..n).rev() {
            let p = self.piv[k];
            if p != k {
                x.swap(k, p);
            }
        }
        x
    }

    /// Estimate of `‖A‖₁ ‖A⁻¹‖₁` given `‖A‖₁`: Hager's method as refined by
    /// Higham (LAPACK's zlacon), the same algorithm as `linalg::DenseLu`.
    pub fn cond1_estimate(&self, a_norm1: f64, ctx: &SolveContext) -> Result<f64, SolveError> {
        let n = self.n;
        if n == 0 {
            return Ok(0.0);
        }
        let norm1 = |v: &[C64]| v.iter().map(|z| z.norm()).sum::<f64>();
        let mut x = vec![C64::new(1.0 / n as f64, 0.0); n];
        let mut est = 0.0f64;
        let mut last_j = usize::MAX;
        for iter in 0..5 {
            ctx.checkpoint()?;
            let y = self.solve(&x);
            let y_norm = norm1(&y);
            if !y_norm.is_finite() {
                return Ok(f64::INFINITY);
            }
            if iter > 0 && y_norm <= est {
                break;
            }
            est = y_norm;
            let conj_xi: Vec<C64> = y
                .iter()
                .map(|z| {
                    let a = z.norm();
                    if a > 0.0 {
                        (z / a).conj()
                    } else {
                        C64::new(1.0, 0.0)
                    }
                })
                .collect();
            // z = A⁻ᴴ ξ = conj(A⁻ᵀ conj(ξ))
            ctx.checkpoint()?;
            let z: Vec<C64> = self.solve_transpose(&conj_xi).into_iter().map(|v| v.conj()).collect();
            let (j, zmax) = z.iter().enumerate().map(|(i, v)| (i, v.norm())).fold((0, -1.0), |a, b| if b.1 > a.1 { b } else { a });
            let ztx: f64 = z.iter().zip(&x).map(|(a, b)| (a.conj() * b).re).sum();
            if iter > 0 && (zmax <= ztx || j == last_j) {
                break;
            }
            last_j = j;
            x.iter_mut().for_each(|v| *v = ZERO);
            x[j] = C64::new(1.0, 0.0);
        }
        let alt: Vec<C64> = (0..n)
            .map(|i| {
                let s = if i % 2 == 0 { 1.0 } else { -1.0 };
                C64::new(s * (1.0 + i as f64 / (n.max(2) - 1) as f64), 0.0)
            })
            .collect();
        ctx.checkpoint()?;
        let alt_est = 2.0 * norm1(&self.solve(&alt)) / (3.0 * n as f64);
        Ok(est.max(alt_est) * a_norm1)
    }
}

/// Unblocked LU of the panel `k0..k1` (all rows below k0), with its row swaps
/// applied inside the panel only.
fn factor_panel(n: usize, a: &mut [C64], piv: &mut [usize], k0: usize, k1: usize) {
    for k in k0..k1 {
        let col = &a[k * n..(k + 1) * n];
        let mut p = k;
        let mut best = -1.0;
        for (r, v) in col.iter().enumerate().skip(k) {
            let m = cabs1(*v);
            if m > best {
                best = m;
                p = r;
            }
        }
        piv[k] = p;
        if p != k {
            for c in k0..k1 {
                a.swap(c * n + k, c * n + p);
            }
        }
        let d = a[k * n + k];
        if d != ZERO {
            let inv = 1.0 / d;
            for v in &mut a[k * n + k + 1..(k + 1) * n] {
                *v *= inv;
            }
        }
        if k + 1 == k1 {
            continue;
        }
        let (left, right) = a.split_at_mut((k + 1) * n);
        let l = &left[k * n + k + 1..(k + 1) * n];
        let cols = &mut right[..(k1 - k - 1) * n];
        let update = |c: &mut [C64]| {
            let u = c[k];
            if u != ZERO {
                for (x, lv) in c[k + 1..].iter_mut().zip(l) {
                    *x -= lv * u;
                }
            }
        };
        if l.len() * (k1 - k - 1) >= PAR_MIN {
            cols.par_chunks_mut(n).for_each(update);
        } else {
            cols.chunks_mut(n).for_each(update);
        }
    }
}
