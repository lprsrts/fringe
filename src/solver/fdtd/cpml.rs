//! Convolutional PML (Roden–Gedney, complex-frequency-shifted) coefficients.
//!
//! With d the depth into the PML and L = N_p Δ: `σ(d) = σ_max (d/L)³`,
//! `σ_max = 0.8 (m+1)/(√ε_b,u Δ)` with m = 3, κ = 1, `α(d) = 0.05 k_b (1 − d/L)`,
//! `b = exp(−(σ + α)Δt)` and `a = σ(b − 1)/(σ + α)` (0 where σ = 0).
//!
//! ψ storage covers only the PML strips. Along one axis with N nodes the strip
//! index k maps to the node index `I = k` for k < N_p (low side) and
//! `I = N − 1 − 2N_p + k` for k ≥ N_p (high side). For the half-integer (H)
//! positions the node index I stands for I + ½.

use super::grid::Layout;

const GRADING: f64 = 3.0;

/// Recursive-convolution coefficients along one axis for the 2 N_p strip
/// positions, with `a` already divided by Δ.
#[derive(Clone, Debug)]
pub struct Profile {
    pub b: Vec<f32>,
    pub a: Vec<f32>,
}

/// Strip index → node index along an axis of `n` nodes.
#[inline]
pub fn strip_node(k: usize, np: usize, n: usize) -> usize {
    if k < np {
        k
    } else {
        n - 1 - 2 * np + k
    }
}

/// Profiles for integer (E) and half-integer (H) positions along an axis of `n`
/// nodes.
pub fn profiles(l: &Layout, n: usize, eps_bu: f64, k_b: f64) -> (Profile, Profile) {
    let np = l.np;
    let len = np as f64 * l.dx;
    let sigma_max = 0.8 * (GRADING + 1.0) / (eps_bu.sqrt() * l.dx);
    let coef = |u: f64| -> (f32, f32) {
        // Depth into the PML of position u (in node units).
        let lo = np as f64 - u;
        let hi = u - (n - 1 - np) as f64;
        let d = (lo.max(hi).max(0.0) * l.dx).min(len);
        let x = d / len;
        let sigma = sigma_max * x.powf(GRADING);
        let alpha = 0.05 * k_b * (1.0 - x);
        let b = (-(sigma + alpha) * l.dt).exp();
        let a = if sigma > 0.0 { sigma * (b - 1.0) / (sigma + alpha) } else { 0.0 };
        (b as f32, (a / l.dx) as f32)
    };
    let mut e = Profile { b: vec![1.0; 2 * np], a: vec![0.0; 2 * np] };
    let mut h = e.clone();
    for k in 0..2 * np {
        let i = strip_node(k, np, n) as f64;
        (e.b[k], e.a[k]) = coef(i);
        (h.b[k], h.a[k]) = coef(i + 0.5);
    }
    (e, h)
}
