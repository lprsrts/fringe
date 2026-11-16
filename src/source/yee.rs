//! Numerical dispersion of the 2D Yee scheme, for the FDTD's matched incident
//! field (spec §4.3). Normalised units: c = 1, so ω = k0 and time is in µm.

use crate::types::C64;

/// The wavenumber k̃ at which a plane wave travelling at `angle` is an exact
/// discrete solution of the Yee scheme in a medium `eps_b`:
/// `ε_b sin²(ωΔt/2)/Δt² = [sin²(k̃ cos φ Δ/2) + sin²(k̃ sin φ Δ/2)]/Δ²`.
/// Newton's method from `ω √ε_b`; NaN if the step violates the Courant limit.
pub fn yee_wavenumber(angle: f64, eps_b: f64, omega: f64, dx: f64, dt: f64) -> f64 {
    let target = eps_b * (0.5 * omega * dt).sin().powi(2) / (dt * dt);
    let (c, s) = (angle.cos(), angle.sin());
    let h = 0.5 * dx;
    let mut k = omega * eps_b.sqrt();
    for _ in 0..60 {
        let f = ((k * c * h).sin().powi(2) + (k * s * h).sin().powi(2)) / (dx * dx) - target;
        // d/dk sin²(a k) = a sin(2 a k)
        let df = (c * h * (2.0 * k * c * h).sin() + s * h * (2.0 * k * s * h).sin()) / (dx * dx);
        let step = f / df;
        k -= step;
        if !k.is_finite() {
            return f64::NAN;
        }
        if step.abs() < 1e-14 * k.abs() {
            return k;
        }
    }
    let f = ((k * c * h).sin().powi(2) + (k * s * h).sin().powi(2)) / (dx * dx) - target;
    if f.abs() < 1e-10 * target {
        k
    } else {
        f64::NAN
    }
}

/// `F(n, θ)` such that the medium with ε·F has the exact phase velocity along θ
/// on the grid: `F = (Δt²/(n² sin²(ωΔt/2))) · [sin²(k0 n cos θ Δ/2) + sin²(k0 n sin θ Δ/2)]/Δ²`.
/// Components at an angle α from θ keep an error of order (kΔ)² sin²(2α)/48.
pub fn dispersion_factor(n: f64, axis_angle: f64, k0: f64, dx: f64, dt: f64) -> f64 {
    let h = 0.5 * dx;
    let num = (k0 * n * axis_angle.cos() * h).sin().powi(2) + (k0 * n * axis_angle.sin() * h).sin().powi(2);
    dt * dt / (n * n * (0.5 * k0 * dt).sin().powi(2)) * num / (dx * dx)
}

/// `ε · F(Re n, θ_axis)` with n = √ε (Re n > 0).
pub fn dispersion_corrected_eps(eps: C64, axis_angle: f64, k0: f64, dx: f64, dt: f64) -> C64 {
    let n = eps.sqrt().re;
    eps * dispersion_factor(n, axis_angle, k0, dx, dt)
}
