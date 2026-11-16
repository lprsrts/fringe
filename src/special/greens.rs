//! The 2D Helmholtz Green's function and its derivatives. This module is the
//! single source of truth for the conventions every solver uses.
//!
//! # Conventions
//!
//! - The plane is (x, y) in µm, x to the right, y up; angles are counter-clockwise
//!   from +x. The only field is E = E_z(x, y), a complex phasor; μ_r = 1.
//! - Time dependence `E(r, t) = Re{E(r) e^{+jωt}}`. A wave travelling along the
//!   unit vector ê is `e^{−j k ê·r}`; outgoing cylindrical waves are H⁽²⁾.
//! - `k0 = 2π/λ0`. A material with user index n + ik (k ≥ 0 absorbs) has
//!   `ε_r = (n − jk)²` and `k_i = k0 (n − jk)`, so Im k_i ≤ 0. The background has
//!   a real index n_b, `k_b = k0 n_b`, `ε_b = n_b²`.
//! - Green's function `G_k(R) = −(j/4) H0⁽²⁾(kR)`, solving `(∇² + k²) G = −δ`;
//!   near the source `G ≈ −(1/2π) ln R + const`.
//! - Radial derivatives: `g′(R) = (jk/4) H1⁽²⁾(kR)` and
//!   `g″(R) = (jk²/4) [H0⁽²⁾(kR) − H1⁽²⁾(kR)/(kR)]`.
//! - With field point x, source point y, `R = x − y`, `R̂ = R/|R|` and unit
//!   normals n_x, n_y:
//!   `∂_{n_y} G = −g′ (n_y·R̂)`, `∂_{n_x} G = g′ (n_x·R̂)` and
//!   `∂_{n_x} ∂_{n_y} G = −g″ (n_x·R̂)(n_y·R̂) + (g′/R)[(n_x·R̂)(n_y·R̂) − n_x·n_y]`.
//! - Plane-wave expansion: `e^{−jkρ cos(φ−θ)} = Σ_n (−j)ⁿ J_n(kρ) e^{jn(φ−θ)}`.
//! - Sign check: `∮ ∂_n G dl` over a small circle around the source is −1.
//! - Scattered-field formulation: `E_tot = E_inc + E_s`, with `E_inc` an exact
//!   background solution. `∇²E_s + k0² ε_r E_s = −k0² (ε_r − ε_b) E_inc`, and on
//!   PEC `E_s = −E_inc`.
//! - Energy: for a closed contour C around area A with outward normal,
//!   `Im ∮_C E* ∂_n E dl = k0² ∫_A ε″ |E|² dA` (ε = ε′ − jε″); zero when lossless.

use std::f64::consts::PI;

use crate::types::{Vec2, C64, EULER_GAMMA, J};

use super::bessel::h2_01;

/// G and its first two radial derivatives at distance R.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Radial {
    pub g: C64,
    pub dg: C64,
    pub d2g: C64,
}

/// `G_k(R)`, `g′(R)` and `g″(R)` for R > 0. A real k takes the real fast path.
pub fn radial(k: C64, r: f64) -> Radial {
    let z = k * r;
    let (h0, h1) = h2_01(z);
    Radial {
        g: -0.25 * J * h0,
        dg: 0.25 * J * k * h1,
        d2g: 0.25 * J * k * k * (h0 - h1 / z),
    }
}

/// `G_b − G_i` and its radial derivatives. For small `max(|k_b|, |k_i|)·R` the
/// logarithmic singularities cancel analytically and the difference is summed as
/// a series; otherwise it is the direct difference.
pub fn radial_diff(k_b: C64, k_i: C64, r: f64) -> Radial {
    if k_b.norm().max(k_i.norm()) * r < 1.0 {
        radial_diff_series(k_b, k_i, r)
    } else {
        let a = radial(k_b, r);
        let b = radial(k_i, r);
        Radial { g: a.g - b.g, dg: a.dg - b.dg, d2g: a.d2g - b.d2g }
    }
}

/// Series for `G_b − G_i = Σ_m R^{2m} (α_m ln R + β_m)`, with
/// `a_m = (−1)^m/(4^m (m!)²)`, `b_m = (−1)^{m+1} H_m/(4^m (m!)²)`,
/// `ℓ_k = ln(k/2) + γ`,
/// `α_m = −(1/2π) a_m (k_b^{2m} − k_i^{2m})` and
/// `β_m = −(1/2π) a_m (ℓ_b k_b^{2m} − ℓ_i k_i^{2m}) − (1/2π) b_m (k_b^{2m} − k_i^{2m}) − (j/4) a_m (k_b^{2m} − k_i^{2m})`.
pub fn radial_diff_series(k_b: C64, k_i: C64, r: f64) -> Radial {
    let lb = (k_b * 0.5).ln() + EULER_GAMMA;
    let li = (k_i * 0.5).ln() + EULER_GAMMA;
    let ln_r = r.ln();
    let kb2 = k_b * k_b;
    let ki2 = k_i * k_i;
    let inv2pi = 1.0 / (2.0 * PI);
    let mut g = C64::new(0.0, 0.0);
    let mut dg = C64::new(0.0, 0.0);
    let mut d2g = C64::new(0.0, 0.0);
    let mut pb = C64::new(1.0, 0.0); // k_b^{2m}
    let mut pi_ = C64::new(1.0, 0.0); // k_i^{2m}
    let mut am = 1.0; // a_m
    let mut hm = 0.0; // H_m
    let mut r2m = 1.0; // R^{2m}
    for m in 0..60usize {
        let diff = pb - pi_;
        let bm = -am * hm; // b_m = (−1)^{m+1} H_m / (4^m (m!)²) = −a_m H_m
        let alpha = -inv2pi * am * diff;
        let beta = -inv2pi * am * (lb * pb - li * pi_) - inv2pi * bm * diff - 0.25 * J * am * diff;
        let core = alpha * ln_r + beta;
        let mf = m as f64;
        let tg = r2m * core;
        g += tg;
        if m > 0 {
            dg += r2m / r * (2.0 * mf * core + alpha);
            d2g += r2m / (r * r) * (2.0 * mf * (2.0 * mf - 1.0) * core + (4.0 * mf - 1.0) * alpha);
        }
        if m > 1 && tg.norm() <= 1e-17 * g.norm() {
            break;
        }
        let next = (m + 1) as f64;
        am *= -1.0 / (4.0 * next * next);
        hm += 1.0 / next;
        pb *= kb2;
        pi_ *= ki2;
        r2m *= r * r;
    }
    Radial { g, dg, d2g }
}

/// The four kernel values a boundary-integral solver needs at one point pair.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Kernels {
    pub g: C64,
    /// `∂G/∂n_y`
    pub dn_y: C64,
    /// `∂G/∂n_x`
    pub dn_x: C64,
    /// `∂²G/∂n_x∂n_y`
    pub dn_xy: C64,
}

/// Combines radial values at `R = |x − y|` with the geometry.
pub fn kernels(rad: &Radial, x: Vec2, y: Vec2, n_x: Vec2, n_y: Vec2) -> Kernels {
    let d = x - y;
    let r = d.norm();
    let rh = d / r;
    let nxr = n_x.dot(rh);
    let nyr = n_y.dot(rh);
    Kernels {
        g: rad.g,
        dn_y: -rad.dg * nyr,
        dn_x: rad.dg * nxr,
        dn_xy: -rad.d2g * nxr * nyr + rad.dg / r * (nxr * nyr - n_x.dot(n_y)),
    }
}
