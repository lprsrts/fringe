//! Dispersive media: the auxiliary differential equations (ADE) of the
//! Lorentz–Drude poles.
//!
//! Each pole adds a polarisation current J to Ampère's law,
//! `ε∞ ∂_t E + Σ J = ∇×H`, driven by the total field E = E_s + E_inc:
//!
//! - Drude, first order: `∂_t J + γ J = ωp² E`, discretised with the
//!   trapezoidal rule at integer steps:
//!   `J^{n+1}(1 + γΔt/2) = J^n (1 − γΔt/2) + (ωp²Δt/2)(E^{n+1} + E^n)`.
//! - Lorentz, second order: `∂_t² J + γ ∂_t J + ω0² J = Δε ω0² ∂_t E`, by the
//!   bilinear transform `∂_t → K (z − 1)/(z + 1)`, K = 2/Δt:
//!   `J^{n+1} d0 = (2K² − 2ω0²) J^n − (K² − γK + ω0²) J^{n−1} + Δε ω0² K (E^{n+1} − E^{n−1})`
//!   with `d0 = K² + γK + ω0²`. The bilinear transform keeps a stable pole
//!   stable for any Δt, which matters for glass: BK7's ultraviolet pole sits at
//!   ω0Δt ≈ 3 at preview resolution, where central differences diverge.
//!
//! The Drude update is the same transform of its first-order equation.
//! Ampère's law takes `(J^{n+1} + J^n)/2`, centred with `(E^{n+1} − E^n)/Δt`.
//! Both updates are implicit in E^{n+1} only through a scalar per node, so the
//! E update stays explicit and the poles add no stability limit.
//!
//! Against `(E^{n+1} − E^n)/Δt`, the discrete poles respond as the continuous
//! ones at the warped frequency Ω = (2/Δt) tan(ωΔt/2). The coefficients are
//! built from parameters pre-warped by r = Ω/ω (every frequency, γ, ωp and ω0,
//! times r), so at the solve frequency the discrete ε equals the model's ε
//! exactly; the axis dispersion factor F then scales it as a whole.

use crate::scene::materials::HC_EV_UM;
use crate::scene::Pole;

/// One pole's update `J^{n+1} = p1 J^n + p2 J^{n−1} + q E^{n+1} + qn E^n + qm E^{n−1}`
/// (total fields).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PoleCoef {
    pub p1: f64,
    pub p2: f64,
    pub q: f64,
    pub qn: f64,
    pub qm: f64,
}

impl PoleCoef {
    /// The same pole with its strength scaled by `s` (a fill fraction, the
    /// dispersion factor).
    pub fn scaled(self, s: f64) -> PoleCoef {
        PoleCoef { q: self.q * s, qn: self.qn * s, qm: self.qm * s, ..self }
    }
}

/// Angular frequency (normalised units, rad/µm) of a photon energy in eV.
pub fn ev_to_omega(ev: f64) -> f64 {
    ev * 2.0 * std::f64::consts::PI / HC_EV_UM
}

/// Update coefficients of `pole` for time step `dt` at drive frequency `omega`
/// (normalised units), pre-warped as described in the module docs.
pub fn pole_coef(pole: &Pole, omega: f64, dt: f64) -> PoleCoef {
    let th = 0.5 * omega * dt;
    let r = th.tan() / th;
    match *pole {
        Pole::Drude { plasma_ev, gamma_ev } => {
            let wp = ev_to_omega(plasma_ev) * r;
            let g = ev_to_omega(gamma_ev) * r;
            let d = 1.0 + 0.5 * g * dt;
            let beta = wp * wp * dt / (2.0 * d);
            PoleCoef { p1: (1.0 - 0.5 * g * dt) / d, p2: 0.0, q: beta, qn: beta, qm: 0.0 }
        }
        Pole::Lorentz { strength, resonance_ev, gamma_ev } => {
            let w0 = ev_to_omega(resonance_ev) * r;
            let s = strength * w0 * w0;
            let g = ev_to_omega(gamma_ev) * r;
            let k = 2.0 / dt;
            let d0 = k * k + g * k + w0 * w0;
            let q = s * k / d0;
            PoleCoef {
                p1: (2.0 * k * k - 2.0 * w0 * w0) / d0,
                p2: -(k * k - g * k + w0 * w0) / d0,
                q,
                qn: 0.0,
                qm: -q,
            }
        }
    }
}

/// Whether the pole update is stable on its own: the roots of
/// `z² − p1 z − p2` lie in the closed unit disc.
pub fn is_stable(c: &PoleCoef) -> bool {
    let disc = crate::types::C64::new(c.p1 * c.p1 + 4.0 * c.p2, 0.0).sqrt();
    [(c.p1 + disc) * 0.5, (c.p1 - disc) * 0.5].iter().all(|z| z.norm() <= 1.0 + 1e-12)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::C64;

    /// The discrete susceptibility of a pole at z = e^{jωΔt}: J = χ_J E with
    /// `J (z − p1 − p2/z) = (q z + qn + qm/z) E`, seen by Ampère's law as
    /// `ε contribution = (Δt/2)(z + 1)/(z − 1) · χ_J`.
    fn discrete_eps(c: &PoleCoef, omega: f64, dt: f64) -> C64 {
        let z = C64::from_polar(1.0, omega * dt);
        let chi_j = (c.q * z + c.qn + c.qm / z) / (z - c.p1 - c.p2 / z);
        0.5 * dt * (z + 1.0) / (z - 1.0) * chi_j
    }

    #[test]
    fn discrete_poles_match_the_model_at_the_drive_frequency() {
        let poles = [
            Pole::Drude { plasma_ev: 7.87, gamma_ev: 0.053 },
            Pole::Drude { plasma_ev: 9.0, gamma_ev: 0.0 },
            Pole::Lorentz { strength: 11.4, resonance_ev: 0.415, gamma_ev: 0.241 },
            Pole::Lorentz { strength: 1.04, resonance_ev: 16.0, gamma_ev: 0.0 },
            Pole::Lorentz { strength: 0.6, resonance_ev: 2.9, gamma_ev: 0.87 },
        ];
        let lambda0 = 0.5;
        let omega = 2.0 * std::f64::consts::PI / lambda0;
        let w_ev = HC_EV_UM / lambda0;
        for steps in [12.0, 40.0, 80.0, 200.0] {
            let dt = lambda0 / steps;
            for p in &poles {
                let want = p.eps(w_ev);
                let got = discrete_eps(&pole_coef(p, omega, dt), omega, dt);
                let c = pole_coef(p, omega, dt);
                assert!((got - want).norm() < 1e-9 * want.norm(), "{p:?} at {steps} steps: {got} vs {want}");
                assert!(is_stable(&c), "{p:?} at {steps} steps: {c:?}");
            }
        }
    }
}
