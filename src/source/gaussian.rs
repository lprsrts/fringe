//! Gaussian beam as an angular spectrum of propagating plane waves (spec §4.2).
//!
//! In the beam frame (ξ along the axis, η across it, origin at the waist):
//! `E(ξ, η) = C ∫ cos α · exp(−(k w0 sin α)²/4) · exp(−j k (ξ cos α + η sin α)) dα`
//! over |α| ≤ α_max. This is the Fourier integral of `exp(−η²/w0²)` with
//! κ = k sin α; the cos α Jacobian removes the endpoint singularity at κ = ±k.
//! Evanescent components are left out, so the result solves the Helmholtz
//! equation exactly; for w0 < λ/2 that band limit widens the realised waist.

use crate::special::gauss_legendre;
use crate::types::{cis, Rect, Vec2, C64};

use super::PlaneComponent;

/// Quadrature nodes are accepted when doubling-and-a-half them changes the field
/// at the probes by less than this (relative to the amplitude).
const ACCEPT_TOL: f64 = 1e-10;

/// Most plane waves a beam may have. The scenes in the examples need about a
/// hundred; the count grows with the distance from the waist to the far corner
/// of the domain, and validation rejects a waist that would need more.
pub const MAX_COMPONENTS: usize = 4096;

/// Largest spectral angle kept: beyond sin α = 12.2/(k w0) the spectrum is
/// below 1e−16.
fn alpha_max(k: f64, w0: f64) -> f64 {
    (12.2 / (k * w0)).min(1.0).asin().min(std::f64::consts::FRAC_PI_2)
}

/// The first quadrature size tried for a beam that must be accurate out to
/// `r_max` from its waist (not clamped).
pub fn nodes_needed(k: f64, w0: f64, r_max: f64) -> f64 {
    (0.6 * k * r_max * alpha_max(k, w0)).ceil() + 24.0
}

/// The largest `r_max` for which [`nodes_needed`] stays within
/// [`MAX_COMPONENTS`].
pub fn max_reach(k: f64, w0: f64) -> f64 {
    (MAX_COMPONENTS as f64 - 25.0) / (0.6 * k * alpha_max(k, w0))
}

pub fn components(
    k: f64,
    w0: f64,
    waist: Vec2,
    theta: f64,
    amplitude: f64,
    phase: f64,
    accurate_in: Rect,
) -> (Vec<PlaneComponent>, Vec<String>) {
    let alpha_max = alpha_max(k, w0);
    let r_max = accurate_in
        .corners()
        .iter()
        .map(|c| c.dist(waist))
        .fold(0.0, f64::max);
    let probes = probe_points(waist, theta, r_max);
    // Start low enough that one refinement fits under the cap.
    let mut m = (nodes_needed(k, w0, r_max).min(1e9) as usize).clamp(32, MAX_COMPONENTS * 2 / 3);
    let mut warnings = Vec::new();
    let mut comps = build(k, w0, theta, amplitude, phase, alpha_max, m);
    for attempt in 0..=6 {
        let m_next = ((1.5 * m as f64).ceil() as usize).min(MAX_COMPONENTS);
        let finer = build(k, w0, theta, amplitude, phase, alpha_max, m_next);
        let diff = probes
            .iter()
            .map(|&p| (eval(&comps, waist, p) - eval(&finer, waist, p)).norm())
            .fold(0.0, f64::max);
        if diff <= ACCEPT_TOL * amplitude {
            break;
        }
        if attempt == 6 || m_next == MAX_COMPONENTS {
            warnings.push(format!(
                "the Gaussian beam's angular spectrum is only accurate to {:.1e} of its amplitude over this domain",
                diff / amplitude
            ));
            comps = finer;
            break;
        }
        m = m_next;
        comps = finer;
    }
    (comps, warnings)
}

fn build(k: f64, w0: f64, theta: f64, amplitude: f64, phase: f64, alpha_max: f64, m: usize) -> Vec<PlaneComponent> {
    let gl = gauss_legendre(m);
    let mut comps: Vec<PlaneComponent> = gl
        .on(-alpha_max, alpha_max)
        .map(|(a, w)| {
            let s = k * w0 * a.sin();
            let weight = w * a.cos() * (-0.25 * s * s).exp();
            let dir = theta + a;
            PlaneComponent { k: [k * dir.cos(), k * dir.sin()], c: C64::new(weight, 0.0) }
        })
        .collect();
    // Normalise so that the field at the waist centre is exactly A e^{jφ0}.
    let total: f64 = comps.iter().map(|c| c.c.re).sum();
    let scale = amplitude * cis(phase) / total;
    comps.iter_mut().for_each(|c| c.c *= scale);
    comps
}

fn eval(comps: &[PlaneComponent], origin: Vec2, p: Vec2) -> C64 {
    let d = p - origin;
    comps.iter().map(|m| m.c * cis(-(m.k[0] * d.x + m.k[1] * d.y))).sum()
}

/// 32 probes in the disk of radius `r_max` about the waist, which covers the
/// accurate-in rectangle: the waist, 8 directions at 3 radii, and 7 fixed
/// pseudo-random points. They are laid out in the beam frame, so a rotated beam
/// gets the same quadrature (the spec's rectangle-based probes did not).
fn probe_points(waist: Vec2, theta: f64, r_max: f64) -> Vec<Vec2> {
    let mut ps = vec![waist];
    for k in 0..8 {
        let dir = Vec2::from_angle(theta + k as f64 * std::f64::consts::FRAC_PI_4 + 0.1);
        for f in [1.0, 0.75, 0.5] {
            ps.push(waist + dir * (f * r_max));
        }
    }
    let mut state: u64 = 0x2545_f491_4f6c_dd1d;
    let mut next = || {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        (state >> 11) as f64 / (1u64 << 53) as f64
    };
    for _ in 0..7 {
        let r = r_max * next().sqrt();
        let a = theta + 2.0 * std::f64::consts::PI * next();
        ps.push(waist + Vec2::from_angle(a) * r);
    }
    ps
}
