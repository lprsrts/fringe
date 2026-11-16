//! Bessel and Hankel functions of integer order for the Green's function, the
//! incident-field checks and the Mie series.
//!
//! Three regimes, chosen by |z|:
//! - |z| ≤ 8: the ascending power series. The terms are bounded by I0(|z|) ≈ 430,
//!   so cancellation costs at most three digits.
//! - 8 < |z| ≤ 12 (complex) or 8 < x ≤ 20 (real): Miller's backward recurrence
//!   for J_n, normalised with `e^{jz} = J0 + 2 Σ jⁿ Jₙ` (or `1 = J0 + 2 Σ J_{2k}`
//!   for real x), and
//!   Neumann's series for Y0 and Y1 in terms of the J_n. Neither sum cancels
//!   badly, unlike the power series at these arguments (which loses ~1e−11 on Y0
//!   at x = 10).
//! - |z| > 12 (complex) or x > 20 (real): Hankel's asymptotic expansion
//!   truncated at its smallest term. At |z| = 12 its error is about 1e−12; at
//!   x = 20 the two real methods agree to 4e−16, so real arguments switch there
//!   (the Chebyshev tables are built from the same direct path). The phase χ = x − νπ/2 − π/4 is
//!   never formed: sin x and cos x are rotated by the exact cos(π/4), which keeps
//!   the argument reduction exact for large x.
//!
//! In the lower half plane J and Y grow like e^{|Im z|} while H⁽²⁾ = J − jY
//! decays, so below the switch H⁽²⁾ loses about e^{2|Im z|}·1e−16 relative
//! accuracy (2e−10 at |Im z| = 6); above it the expansion gives H⁽²⁾ directly.
//!
//! H = H⁽²⁾ throughout (outgoing waves under e^{+jωt}).

use std::f64::consts::{FRAC_1_SQRT_2, FRAC_2_PI, PI};

use crate::types::{C64, EULER_GAMMA, J};

const SERIES_MAX: f64 = 8.0;
const ASYMPTOTIC_MIN: f64 = 12.0;
/// The switch to Hankel's expansion for real arguments, shared by the direct
/// path and the Chebyshev table builder.
const ASYMPTOTIC_MIN_REAL: f64 = 20.0;
/// Room for Miller's recurrence below the asymptotic switch (start index ≤ 62).
const MILLER_BUF: usize = 64;

/// 1/k for k < 64, so the inner loops multiply instead of divide.
const INV: [f64; 64] = {
    let mut t = [0.0; 64];
    let mut k = 1;
    while k < 64 {
        t[k] = 1.0 / k as f64;
        k += 1;
    }
    t
};

/// J0, J1, Y0, Y1 at a real x > 0. This is the hot path of every background
/// kernel, so 8 < x < 64 is read from Chebyshev tables built once from the
/// direct methods below (about 25 ns instead of 100–250 ns).
pub fn j_y_01_real(x: f64) -> (f64, f64, f64, f64) {
    if x <= 0.0 {
        return (1.0, 0.0, f64::NEG_INFINITY, f64::NEG_INFINITY);
    }
    if x <= SERIES_MAX {
        series_real(x)
    } else if x < CHEB_HI {
        chebyshev_real(x)
    } else {
        asymptotic_real(x)
    }
}

/// [`j_y_01_real`] without the tables: series, Miller–Neumann or Hankel's
/// expansion by regime.
pub fn j_y_01_real_direct(x: f64) -> (f64, f64, f64, f64) {
    if x <= 0.0 {
        return (1.0, 0.0, f64::NEG_INFINITY, f64::NEG_INFINITY);
    }
    if x <= SERIES_MAX {
        series_real(x)
    } else if x <= ASYMPTOTIC_MIN_REAL {
        miller_neumann_real(x)
    } else {
        asymptotic_real(x)
    }
}

const CHEB_HI: f64 = 64.0;
/// Coefficients per unit interval; the functions oscillate like cos x, so the
/// coefficients fall like (1/4)ⁿ/n! and 14 reach 1e−17.
const CHEB_N: usize = 14;
const CHEB_INTERVALS: usize = (CHEB_HI - SERIES_MAX) as usize;

type ChebTable = Vec<[[f64; CHEB_N]; 4]>;

fn cheb_table() -> &'static ChebTable {
    static TABLE: std::sync::OnceLock<ChebTable> = std::sync::OnceLock::new();
    TABLE.get_or_init(|| {
        let nodes: Vec<f64> = (0..CHEB_N)
            .map(|k| (PI * (k as f64 + 0.5) / CHEB_N as f64).cos())
            .collect();
        (0..CHEB_INTERVALS)
            .map(|i| {
                let a = SERIES_MAX + i as f64;
                // The direct path: Miller–Neumann up to x = 20, Hankel's expansion beyond.
                let vals: Vec<[f64; 4]> = nodes
                    .iter()
                    .map(|u| {
                        let x = a + 0.5 * (u + 1.0);
                        let (j0, j1, y0, y1) = j_y_01_real_direct(x);
                        [j0, j1, y0, y1]
                    })
                    .collect();
                let mut c = [[0.0; CHEB_N]; 4];
                for (f, cf) in c.iter_mut().enumerate() {
                    for (j, cj) in cf.iter_mut().enumerate() {
                        let mut sum = 0.0;
                        for (k, v) in vals.iter().enumerate() {
                            sum += v[f] * (PI * j as f64 * (k as f64 + 0.5) / CHEB_N as f64).cos();
                        }
                        *cj = 2.0 * sum / CHEB_N as f64;
                    }
                    cf[0] *= 0.5;
                }
                c
            })
            .collect()
    })
}

#[inline]
fn chebyshev_real(x: f64) -> (f64, f64, f64, f64) {
    let t = x - SERIES_MAX;
    let i = (t as usize).min(CHEB_INTERVALS - 1);
    let u = 2.0 * (t - i as f64) - 1.0;
    let c = &cheb_table()[i];
    // Clenshaw's recurrence for the four series side by side.
    let mut b1 = [0.0f64; 4];
    let mut b2 = [0.0f64; 4];
    for j in (1..CHEB_N).rev() {
        for f in 0..4 {
            let b0 = 2.0 * u * b1[f] - b2[f] + c[f][j];
            b2[f] = b1[f];
            b1[f] = b0;
        }
    }
    let v = |f: usize| u * b1[f] - b2[f] + c[f][0];
    (v(0), v(1), v(2), v(3))
}

/// H0⁽²⁾ and H1⁽²⁾ for Re z > 0 and −Re z ≤ Im z ≤ 0. A real z takes the real path.
pub fn h2_01(z: C64) -> (C64, C64) {
    if z.im == 0.0 {
        let (j0, j1, y0, y1) = j_y_01_real(z.re);
        return (C64::new(j0, -y0), C64::new(j1, -y1));
    }
    if z.norm() > ASYMPTOTIC_MIN {
        let (h0, h1) = hankel2_asymptotic(z);
        return (h0, h1);
    }
    let (j0, j1, y0, y1) = j_y_01_complex(z);
    (j0 - J * y0, j1 - J * y1)
}

/// J0, J1, Y0, Y1 at a complex z (principal branch, Re z > 0).
pub fn j_y_01_complex(z: C64) -> (C64, C64, C64, C64) {
    let r = z.norm();
    if r <= SERIES_MAX {
        series_complex(z)
    } else if r <= ASYMPTOTIC_MIN {
        miller_neumann_complex(z)
    } else {
        j_y_asymptotic_complex(z)
    }
}

/// The ascending series for J0, J1, Y0, Y1 (exposed for regime-overlap tests).
pub fn series_complex(z: C64) -> (C64, C64, C64, C64) {
    let half = z * 0.5;
    let q = -half * half;
    let mut t = C64::new(1.0, 0.0); // qᵐ/(m!)²
    let mut j0 = C64::new(0.0, 0.0);
    let mut j1s = C64::new(0.0, 0.0);
    let mut y0s = C64::new(0.0, 0.0);
    let mut y1s = C64::new(0.0, 0.0);
    let mut h = 0.0; // harmonic number H_m
    let mut m = 0usize;
    loop {
        let tm1 = t * INV[m + 1]; // qᵐ/(m!(m+1)!)
        j0 += t;
        j1s += tm1;
        y0s -= t * h;
        y1s += tm1 * (2.0 * h + INV[m + 1]);
        m += 1;
        if m > 60 || (m > 2 && t.norm_sqr() < 1e-36 * j0.norm_sqr().max(1e-300)) {
            break;
        }
        h += INV[m];
        t = t * q * (INV[m] * INV[m]);
    }
    let j1 = half * j1s;
    let ln = half.ln() + EULER_GAMMA;
    let y0 = FRAC_2_PI * (ln * j0 + y0s);
    // Y1 = −2/(πz) + (2/π) ln(z/2) J1 − (1/π)(z/2) Σ (ψ(m+1) + ψ(m+2)) qᵐ/(m!(m+1)!),
    // with ψ(m+1) = H_m − γ, written here with the γ terms folded into `ln`.
    let y1 = -FRAC_2_PI / z + FRAC_2_PI * ln * j1 - half * y1s / PI;
    (j0, j1, y0, y1)
}

fn series_real(x: f64) -> (f64, f64, f64, f64) {
    let half = 0.5 * x;
    let q = -half * half;
    let mut t = 1.0;
    let (mut j0, mut j1s, mut y0s, mut y1s) = (0.0, 0.0, 0.0, 0.0);
    let mut h = 0.0;
    let mut m = 0usize;
    loop {
        let tm1 = t * INV[m + 1];
        j0 += t;
        j1s += tm1;
        y0s -= t * h;
        y1s += tm1 * (2.0 * h + INV[m + 1]);
        m += 1;
        if m > 60 || (m > 2 && t.abs() < 1e-18) {
            break;
        }
        h += INV[m];
        t = t * q * INV[m] * INV[m];
    }
    let j1 = half * j1s;
    let ln = half.ln() + EULER_GAMMA;
    let y0 = FRAC_2_PI * (ln * j0 + y0s);
    let y1 = -FRAC_2_PI / x + FRAC_2_PI * ln * j1 - half * y1s / PI;
    (j0, j1, y0, y1)
}

/// Where to start Miller's recurrence so that J_n is accurate up to n = `nmax`.
///
/// Beyond the turning point n ≈ |z|, Jₙ(z) decays roughly like
/// exp(−0.94 (n − |z|)^{3/2} / √|z|); starting 11.5 |z|^{1/3} + 10 past it puts
/// the start well below 1e−16 of the leading terms.
fn miller_start(nmax: usize, z_abs: f64) -> usize {
    let n = (nmax as f64).max(z_abs.ceil()) + (11.5 * z_abs.cbrt()).ceil() + 10.0;
    let n = n as usize;
    n + (n & 1) // even, so the last pair is complete
}

/// J_0..=J_nmax at a complex z by Miller's backward recurrence, normalised with
/// `e^{jz} = J0 + 2 Σ_{n≥1} jⁿ Jₙ`. In the lower half plane this sum grows like
/// the Jₙ themselves, so it does not cancel.
pub fn bessel_j_array(nmax: usize, z: C64) -> Vec<C64> {
    if z.norm() == 0.0 {
        let mut out = vec![C64::new(0.0, 0.0); nmax + 1];
        out[0] = C64::new(1.0, 0.0);
        return out;
    }
    let n_start = miller_start(nmax, z.norm());
    let mut f = vec![C64::new(0.0, 0.0); n_start + 2];
    // Values are kept within about 1e±100 so that complex division and norms
    // (which square their arguments) cannot overflow or underflow.
    f[n_start] = C64::new(1e-20, 0.0);
    let inv_z = 1.0 / z;
    for k in (1..=n_start).rev() {
        f[k - 1] = 2.0 * k as f64 * inv_z * f[k] - f[k + 1];
        if f[k - 1].norm() > 1e100 {
            for v in f[k - 1..].iter_mut() {
                *v *= 1e-100;
            }
        }
    }
    // Σ jⁿ fₙ with jⁿ cycling through 1, j, −1, −j.
    let mut s = f[0];
    let mut jn = C64::new(1.0, 0.0);
    for v in f.iter().take(n_start + 1).skip(1) {
        jn *= J;
        s += 2.0 * jn * v;
    }
    let s_abs = s.norm();
    let scale = (J * z).exp() * (s.conj() / s_abs) / s_abs;
    f.truncate(nmax + 1);
    f.iter_mut().for_each(|v| *v *= scale);
    f
}

/// Real version of [`bessel_j_array`], normalised with `1 = J0 + 2 Σ J_{2k}`.
pub fn bessel_j_array_real(nmax: usize, x: f64) -> Vec<f64> {
    if x == 0.0 {
        let mut out = vec![0.0; nmax + 1];
        out[0] = 1.0;
        return out;
    }
    let n_start = miller_start(nmax, x.abs());
    let mut f = vec![0.0f64; n_start + 2];
    f[n_start] = 1e-20;
    let inv_x = 1.0 / x;
    for k in (1..=n_start).rev() {
        f[k - 1] = 2.0 * k as f64 * inv_x * f[k] - f[k + 1];
        if f[k - 1].abs() > 1e100 {
            for v in f[k - 1..].iter_mut() {
                *v *= 1e-100;
            }
        }
    }
    let s: f64 = f[0] + 2.0 * f.iter().skip(2).step_by(2).sum::<f64>();
    let scale = 1.0 / s;
    f.truncate(nmax + 1);
    f.iter_mut().for_each(|v| *v *= scale);
    f
}

/// Neumann's series:
/// Y0 = (2/π)(ln(z/2) + γ) J0 − (4/π) Σ_{k≥1} (−1)ᵏ J_{2k}/k, and its derivative
/// Y1 = −Y0′ = (2/π)(ln(z/2) + γ) J1 − (2/π) J0/z + (2/π) Σ_{k≥1} (−1)ᵏ (J_{2k−1} − J_{2k+1})/k.
fn miller_neumann_complex(z: C64) -> (C64, C64, C64, C64) {
    let n = miller_start(0, z.norm()).min(MILLER_BUF - 2);
    let mut f = [C64::new(0.0, 0.0); MILLER_BUF];
    f[n] = C64::new(1e-20, 0.0);
    let inv_z = 1.0 / z;
    for k in (1..=n).rev() {
        f[k - 1] = 2.0 * k as f64 * inv_z * f[k] - f[k + 1];
    }
    let mut s = f[0];
    let mut jn = C64::new(1.0, 0.0);
    for v in f.iter().take(n + 1).skip(1) {
        jn *= J;
        s += 2.0 * jn * v;
    }
    let s_abs = s.norm();
    let scale = (J * z).exp() * (s.conj() / s_abs) / s_abs;
    let mut s0 = C64::new(0.0, 0.0);
    let mut s1 = C64::new(0.0, 0.0);
    let mut k = 1;
    while 2 * k < n {
        let sign = if k % 2 == 0 { INV[k] } else { -INV[k] };
        s0 += sign * f[2 * k];
        s1 += sign * (f[2 * k - 1] - f[2 * k + 1]);
        k += 1;
    }
    let (j0, j1) = (f[0] * scale, f[1] * scale);
    let (s0, s1) = (s0 * scale, s1 * scale);
    let ln = (z * 0.5).ln() + EULER_GAMMA;
    let y0 = FRAC_2_PI * ln * j0 - 2.0 * FRAC_2_PI * s0;
    let y1 = FRAC_2_PI * ln * j1 - FRAC_2_PI * j0 / z + FRAC_2_PI * s1;
    (j0, j1, y0, y1)
}

pub fn miller_neumann_real(x: f64) -> (f64, f64, f64, f64) {
    let n = miller_start(0, x).min(MILLER_BUF - 2);
    let mut f = [0.0f64; MILLER_BUF];
    f[n] = 1e-20;
    let inv_x = 1.0 / x;
    for k in (1..=n).rev() {
        f[k - 1] = 2.0 * k as f64 * inv_x * f[k] - f[k + 1];
    }
    let mut norm = f[0];
    let mut s0 = 0.0;
    let mut s1 = 0.0;
    let mut k = 1;
    while 2 * k <= n {
        norm += 2.0 * f[2 * k];
        let sign = if k % 2 == 0 { INV[k] } else { -INV[k] };
        s0 += sign * f[2 * k];
        s1 += sign * (f[2 * k - 1] - f[2 * k + 1]);
        k += 1;
    }
    let scale = 1.0 / norm;
    let (j0, j1) = (f[0] * scale, f[1] * scale);
    let ln = (0.5 * x).ln() + EULER_GAMMA;
    let y0 = FRAC_2_PI * ln * j0 - 2.0 * FRAC_2_PI * s0 * scale;
    let y1 = FRAC_2_PI * ln * j1 - FRAC_2_PI * j0 / x + FRAC_2_PI * s1 * scale;
    (j0, j1, y0, y1)
}

/// Hankel's expansion: the sums Σ (∓j)ᵏ a_k(ν)/zᵏ for ν = 0 and 1, truncated at
/// the smallest term, with a_k(ν) = (4ν² − 1)(4ν² − 9)…(4ν² − (2k−1)²)/(k! 8ᵏ).
/// Returns the sums for H⁽²⁾ (sign −j) or H⁽¹⁾ (sign +j).
fn hankel_sums(z: C64, sign: C64) -> (C64, C64) {
    let mut out = [C64::new(0.0, 0.0); 2];
    for (nu, o) in out.iter_mut().enumerate() {
        let mu = 4.0 * (nu * nu) as f64;
        let mut term = C64::new(1.0, 0.0);
        let mut sum = term;
        let mut prev = f64::INFINITY;
        let step = sign * 0.125 / z;
        for k in 1..=30 {
            let odd = (2 * k - 1) as f64;
            let next = term * step * ((mu - odd * odd) * INV[k]);
            let size = next.norm();
            if size >= prev || size < 1e-17 * sum.norm() {
                if size < prev {
                    sum += next;
                }
                break;
            }
            prev = size;
            term = next;
            sum += term;
        }
        *o = sum;
    }
    (out[0], out[1])
}

/// e^{jπ/4} and e^{j3π/4}: the phase shifts of H0⁽²⁾ and H1⁽²⁾ relative to e^{−jz}.
const ROT_0: C64 = C64::new(FRAC_1_SQRT_2, FRAC_1_SQRT_2);
const ROT_1: C64 = C64::new(-FRAC_1_SQRT_2, FRAC_1_SQRT_2);

/// H0⁽²⁾, H1⁽²⁾ from Hankel's expansion (exposed for regime-overlap tests).
pub fn hankel2_asymptotic(z: C64) -> (C64, C64) {
    let (s0, s1) = hankel_sums(z, -J);
    let pre = (2.0 / (PI * z)).sqrt();
    // H_ν⁽²⁾ ≈ √(2/(πz)) e^{−j(z − νπ/2 − π/4)} Σ (−j)ᵏ a_k(ν)/zᵏ
    let e = (-J * z).exp();
    (pre * e * ROT_0 * s0, pre * e * ROT_1 * s1)
}

fn j_y_asymptotic_complex(z: C64) -> (C64, C64, C64, C64) {
    let (s0m, s1m) = hankel_sums(z, -J);
    let (s0p, s1p) = hankel_sums(z, J);
    let pre = (2.0 / (PI * z)).sqrt();
    let (em, ep) = ((-J * z).exp(), (J * z).exp());
    let h2_0 = pre * em * ROT_0 * s0m;
    let h2_1 = pre * em * ROT_1 * s1m;
    let h1_0 = pre * ep * ROT_0.conj() * s0p;
    let h1_1 = pre * ep * ROT_1.conj() * s1p;
    let j0 = 0.5 * (h1_0 + h2_0);
    let j1 = 0.5 * (h1_1 + h2_1);
    let y0 = (h1_0 - h2_0) / (2.0 * J);
    let y1 = (h1_1 - h2_1) / (2.0 * J);
    (j0, j1, y0, y1)
}

/// J0, J1, Y0, Y1 from Hankel's expansion at real x (exposed for overlap tests).
pub fn asymptotic_real(x: f64) -> (f64, f64, f64, f64) {
    // With P − jQ the expansion sum for H⁽²⁾: J = √(2/πx)(P cos χ − Q sin χ),
    // Y = √(2/πx)(P sin χ + Q cos χ), χ = x − νπ/2 − π/4.
    let mut pq = [(0.0, 0.0); 2];
    for (nu, o) in pq.iter_mut().enumerate() {
        let mu = 4.0 * (nu * nu) as f64;
        let mut p = 1.0;
        let mut q = 0.0;
        let mut term = 1.0; // a_k / x^k with the sign pattern folded in below
        let mut prev = f64::INFINITY;
        let inv8x = 0.125 / x;
        for k in 1..=30 {
            let odd = (2 * k - 1) as f64;
            let next = term * (mu - odd * odd) * INV[k] * inv8x;
            if next.abs() >= prev || next.abs() < 1e-17 {
                if next.abs() < prev {
                    add_pq(&mut p, &mut q, k, next);
                }
                break;
            }
            prev = next.abs();
            term = next;
            add_pq(&mut p, &mut q, k, term);
        }
        *o = (p, q);
    }
    let pre = (FRAC_2_PI / x).sqrt();
    // sin and cos of χ0 = x − π/4 and χ1 = x − 3π/4 from those of x.
    let (sx, cx) = x.sin_cos();
    let (s0, c0) = (FRAC_1_SQRT_2 * (sx - cx), FRAC_1_SQRT_2 * (cx + sx));
    let (s1, c1) = (-FRAC_1_SQRT_2 * (sx + cx), FRAC_1_SQRT_2 * (sx - cx));
    let (p0, q0) = pq[0];
    let (p1, q1) = pq[1];
    (
        pre * (p0 * c0 - q0 * s0),
        pre * (p1 * c1 - q1 * s1),
        pre * (p0 * s0 + q0 * c0),
        pre * (p1 * s1 + q1 * c1),
    )
}

/// (−j)ᵏ splits the terms into P (even k, sign (−1)^{k/2}) and Q (odd k, with
/// P − jQ = Σ (−j)ᵏ a_k/xᵏ, so Q gets (−1)^{(k−1)/2}).
#[inline]
fn add_pq(p: &mut f64, q: &mut f64, k: usize, t: f64) {
    match k % 4 {
        0 => *p += t,
        1 => *q += t,
        2 => *p -= t,
        _ => *q -= t,
    }
}

/// H_0⁽²⁾..=H_nmax⁽²⁾ at real x > 0: J from Miller's recurrence, Y by forward
/// recurrence from Y0 and Y1 (stable for Y).
pub fn hankel2_array(nmax: usize, x: f64) -> Vec<C64> {
    let jn = bessel_j_array_real(nmax.max(1), x);
    let (_, _, y0, y1) = j_y_01_real(x);
    let mut y = vec![0.0; nmax.max(1) + 1];
    y[0] = y0;
    y[1] = y1;
    for n in 1..nmax {
        y[n + 1] = 2.0 * n as f64 / x * y[n] - y[n - 1];
    }
    (0..=nmax).map(|n| C64::new(jn[n], -y[n])).collect()
}

/// Derivatives Z_n′ = Z_{n−1} − (n/z) Z_n (and Z_0′ = −Z_1) of a J or H⁽²⁾ array
/// Z_0..=Z_N, for n = 0..=N.
pub fn bessel_deriv(z_n: &[C64], z: C64) -> Vec<C64> {
    let n = z_n.len();
    if n < 2 {
        return vec![C64::new(0.0, 0.0); n];
    }
    let mut out = Vec::with_capacity(n);
    out.push(-z_n[1]);
    for k in 1..n {
        out.push(z_n[k - 1] - k as f64 / z * z_n[k]);
    }
    out
}
