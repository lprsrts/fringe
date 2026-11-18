//! A line source next to a circular cylinder (PEC or homogeneous dielectric),
//! the exact series by Graf's addition theorem.
//!
//! With the source at distance d from the centre c, at polar angle φ_s, and
//! ψ = φ − φ_s about c, Graf's theorem for ρ < d gives
//! `H0⁽²⁾(k_b |r − s|) = Σₙ Hₙ⁽²⁾(k_b d) Jₙ(k_b ρ) e^{jnψ}`: the incident field
//! is a sum of cylindrical harmonics, each of which the cylinder answers with
//! the Mie coefficients of [`super::mie::coefficients`]:
//! - scattered (ρ ≥ a): `C Σ cₙ Hₙ(k_b d) Hₙ(k_b ρ) e^{jnψ}`;
//! - interior (ρ < a): `C Σ bₙ Hₙ(k_b d) Jₙ(m k_b ρ) e^{jnψ}`,
//!
//! where C is the source's coefficient. Every factor is even in n, so the sums
//! run over n ≥ 0 with cos(nψ). The terms fall like (a/d)ⁿ(a/ρ)ⁿ, so the
//! source must not be too close to the surface (d ≥ 1.2 a keeps the orders
//! below about 200, where the Bessel products stay inside f64's range).

use crate::geometry::BodyMaterial;
use crate::source::line_source_norm;
use crate::special::{bessel_j_array, h2_01, hankel2_array};
use crate::types::{cis, Vec2, C64};

use super::mie::{coefficients, Coefficients};

pub struct LineCylinder {
    pub center: Vec2,
    pub radius: f64,
    pub k_b: f64,
    pub source: Vec2,
    /// `A e^{jφ0} / |H0⁽²⁾(2π)|`.
    pub coef: C64,
    /// Relative index (n − jk)/n_b, `None` for PEC.
    pub m: Option<C64>,
    /// cₙ Hₙ(k_b d), n = 0..=N.
    pub scat: Vec<C64>,
    /// bₙ Hₙ(k_b d) (dielectric only).
    pub interior: Vec<C64>,
    phi_s: f64,
}

/// Largest order computed.
const MAX_ORDER: usize = 400;

impl LineCylinder {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        center: Vec2,
        radius: f64,
        material: BodyMaterial,
        n_b: f64,
        k0: f64,
        source: Vec2,
        amplitude: f64,
        phase: f64,
    ) -> LineCylinder {
        let k_b = k0 * n_b;
        let x = k_b * radius;
        let m = match material {
            BodyMaterial::Pec => None,
            BodyMaterial::Dielectric { n, .. } => Some(n / n_b),
        };
        let v = source - center;
        let d = v.norm();
        // Orders until (a/d)ⁿ reaches 1e−17, past the turning points.
        let big_x = m.map_or(x, |m| x.max(m.norm() * x));
        let geometric = (-17.0 * std::f64::consts::LN_10 / (radius / d).ln()).ceil();
        let cap = ((big_x + 6.0 * big_x.cbrt() + 10.0).max(geometric + big_x) as usize).min(MAX_ORDER);
        let Coefficients { c, b, jx, hx } = coefficients(x, m, cap);
        let hd = hankel2_array(cap, k_b * d);
        // Cut where the scattered, incident and interior terms at ρ = a are
        // all below 1e−17 (relative to the source coefficient), or where
        // the Bessel values leave f64's range.
        let mut n_max = cap;
        for n in 0..=cap {
            let interior = if b.is_empty() { C64::new(0.0, 0.0) } else { (jx[n] + c[n] * hx[n]) * hd[n] };
            let terms = [hd[n] * jx[n], c[n] * hd[n] * hx[n], interior];
            if terms.iter().any(|t| !t.re.is_finite() || !t.im.is_finite()) {
                n_max = n.saturating_sub(1);
                break;
            }
            if n as f64 > big_x && terms.iter().all(|t| t.norm() < 1e-17) {
                n_max = n;
                break;
            }
        }
        let scat = (0..=n_max).map(|n| c[n] * hd[n]).collect();
        let interior = if b.is_empty() { Vec::new() } else { (0..=n_max).map(|n| b[n] * hd[n]).collect() };
        LineCylinder {
            center,
            radius,
            k_b,
            source,
            coef: amplitude * cis(phase) / line_source_norm(),
            m,
            scat,
            interior,
            phi_s: v.angle(),
        }
    }

    pub fn incident(&self, p: Vec2) -> C64 {
        let r = p.dist(self.source).max(1e-12);
        self.coef * h2_01(C64::new(self.k_b * r, 0.0)).0
    }

    /// Scattered field (total − incident). Inside a PEC cylinder this is −incident.
    pub fn scattered(&self, p: Vec2) -> C64 {
        let v = p - self.center;
        let rho = v.norm();
        if rho < self.radius {
            return self.total(p) - self.incident(p);
        }
        let psi = v.angle() - self.phi_s;
        let h = hankel2_array(self.scat.len() - 1, self.k_b * rho);
        let sum: C64 = self
            .scat
            .iter()
            .zip(&h)
            .enumerate()
            .map(|(n, (s, h))| s * h * if n == 0 { 1.0 } else { 2.0 * (n as f64 * psi).cos() })
            .sum();
        self.coef * sum
    }

    pub fn total(&self, p: Vec2) -> C64 {
        let v = p - self.center;
        let rho = v.norm();
        if rho >= self.radius {
            return self.incident(p) + self.scattered(p);
        }
        let Some(m) = self.m else {
            return C64::new(0.0, 0.0);
        };
        let psi = v.angle() - self.phi_s;
        let jn = bessel_j_array(self.interior.len() - 1, m * self.k_b * rho);
        let sum: C64 = self
            .interior
            .iter()
            .zip(&jn)
            .enumerate()
            .map(|(n, (b, j))| b * j * if n == 0 { 1.0 } else { 2.0 * (n as f64 * psi).cos() })
            .sum();
        self.coef * sum
    }
}
