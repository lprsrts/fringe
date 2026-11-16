//! TM (Ez) scattering of a plane wave by a circular cylinder: PEC or a
//! homogeneous dielectric with complex index (spec §5b).
//!
//! With the plane wave `A e^{jφ0} e^{−jk_b(x cos θ + y sin θ)}` and local polar
//! coordinates (ρ, φ) about the centre c, ψ = φ − θ and the phase factor
//! `P = e^{−jk_b(c_x cos θ + c_y sin θ)}`:
//! - incident: `A e^{jφ0} P Σ (−j)ⁿ Jₙ(k_b ρ) e^{jnψ}`;
//! - scattered: `A e^{jφ0} P Σ (−j)ⁿ cₙ Hₙ(k_b ρ) e^{jnψ}` with
//!   `cₙ = −Jₙ(x)/Hₙ(x)` (PEC, x = k_b a) or
//!   `cₙ = [m Jₙ(x) Jₙ′(mx) − Jₙ′(x) Jₙ(mx)] / [Hₙ′(x) Jₙ(mx) − m Hₙ(x) Jₙ′(mx)]`,
//!   m = (n − jk)/n_b;
//! - inside a dielectric: `A e^{jφ0} P Σ (−j)ⁿ bₙ Jₙ(m k_b ρ) e^{jnψ}` with
//!   `bₙ = (Jₙ(x) + cₙ Hₙ(x)) / Jₙ(mx)`.
//!
//! cₙ and bₙ are even in n, so the sums run over n ≥ 0 with cos(nψ).

use crate::geometry::BodyMaterial;
use crate::special::{bessel_deriv, bessel_j_array, hankel2_array};
use crate::types::{cis, Vec2, C64};

pub struct MieCylinder {
    pub center: Vec2,
    pub radius: f64,
    pub k_b: f64,
    pub angle: f64,
    pub amplitude: f64,
    pub phase: f64,
    /// Relative index (n − jk)/n_b, `None` for PEC.
    pub m: Option<C64>,
    /// Scattering coefficients cₙ, n = 0..=N.
    pub c: Vec<C64>,
    /// Interior coefficients bₙ (dielectric only).
    pub b: Vec<C64>,
}

impl MieCylinder {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        center: Vec2,
        radius: f64,
        material: BodyMaterial,
        n_b: f64,
        k0: f64,
        angle: f64,
        amplitude: f64,
        phase: f64,
    ) -> MieCylinder {
        let k_b = k0 * n_b;
        let x = k_b * radius;
        let m = match material {
            BodyMaterial::Pec => None,
            BodyMaterial::Dielectric { n, .. } => Some(n / n_b),
        };
        let big_x = match m {
            Some(m) => x.max(m.norm() * x),
            None => x,
        };
        let n_max = (big_x + 4.0 * big_x.cbrt() + 10.0).ceil() as usize;
        let xc = C64::new(x, 0.0);
        let jx = bessel_j_array(n_max + 1, xc);
        let hx = hankel2_array(n_max + 1, x);
        let (c, b) = match m {
            None => ((0..=n_max).map(|n| -jx[n] / hx[n]).collect(), Vec::new()),
            Some(m) => {
                let mx = m * x;
                let jmx = bessel_j_array(n_max + 1, mx);
                let djx = bessel_deriv(&jx, xc);
                let dhx = bessel_deriv(&hx, xc);
                let djmx = bessel_deriv(&jmx, mx);
                let mut c = Vec::with_capacity(n_max + 1);
                let mut b = Vec::with_capacity(n_max + 1);
                for n in 0..=n_max {
                    // Written with the log-derivative Jₙ′(mx)/Jₙ(mx) so a tiny Jₙ(mx)
                    // at high order cannot underflow the ratio.
                    let d = djmx[n] / jmx[n];
                    let cn = (m * jx[n] * d - djx[n]) / (dhx[n] - m * hx[n] * d);
                    c.push(cn);
                    b.push((jx[n] + cn * hx[n]) / jmx[n]);
                }
                (c, b)
            }
        };
        MieCylinder { center, radius, k_b, angle, amplitude, phase, m, c, b }
    }

    fn prefactor(&self) -> C64 {
        let d = Vec2::from_angle(self.angle);
        self.amplitude * cis(self.phase) * cis(-self.k_b * self.center.dot(d))
    }

    pub fn incident(&self, p: Vec2) -> C64 {
        let d = Vec2::from_angle(self.angle);
        self.amplitude * cis(self.phase) * cis(-self.k_b * p.dot(d))
    }

    /// Scattered field (total − incident). Inside a PEC cylinder this is −incident.
    pub fn scattered(&self, p: Vec2) -> C64 {
        let v = p - self.center;
        let rho = v.norm();
        if rho < self.radius {
            return self.total(p) - self.incident(p);
        }
        let psi = v.angle() - self.angle;
        let n_max = self.c.len() - 1;
        let h = hankel2_array(n_max, self.k_b * rho);
        let mut sum = C64::new(0.0, 0.0);
        let mut mj = C64::new(1.0, 0.0); // (−j)ⁿ
        for n in 0..=n_max {
            let w = if n == 0 { 1.0 } else { 2.0 * (n as f64 * psi).cos() };
            sum += mj * self.c[n] * h[n] * w;
            mj *= C64::new(0.0, -1.0);
        }
        self.prefactor() * sum
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
        let psi = v.angle() - self.angle;
        let n_max = self.b.len() - 1;
        let jn = bessel_j_array(n_max, m * self.k_b * rho);
        let mut sum = C64::new(0.0, 0.0);
        let mut mj = C64::new(1.0, 0.0);
        for n in 0..=n_max {
            let w = if n == 0 { 1.0 } else { 2.0 * (n as f64 * psi).cos() };
            sum += mj * self.b[n] * jn[n] * w;
            mj *= C64::new(0.0, -1.0);
        }
        self.prefactor() * sum
    }

    /// Total field and its radial derivative from the exterior (`interior = false`)
    /// or interior series at polar coordinates (ρ, φ) about the centre, at any ρ.
    /// Used to check the boundary conditions at ρ = a.
    pub fn series_at(&self, rho: f64, phi: f64, interior: bool) -> (C64, C64) {
        let psi = phi - self.angle;
        let pre = self.prefactor();
        let mut e = C64::new(0.0, 0.0);
        let mut de = C64::new(0.0, 0.0);
        let mut mj = C64::new(1.0, 0.0);
        if interior {
            let Some(m) = self.m else {
                return (e, de);
            };
            let n_max = self.b.len() - 1;
            let k = m * self.k_b;
            let jn = bessel_j_array(n_max + 1, k * rho);
            let djn = bessel_deriv(&jn, k * rho);
            for n in 0..=n_max {
                let w = if n == 0 { 1.0 } else { 2.0 * (n as f64 * psi).cos() };
                e += mj * self.b[n] * jn[n] * w;
                de += mj * self.b[n] * k * djn[n] * w;
                mj *= C64::new(0.0, -1.0);
            }
        } else {
            let n_max = self.c.len() - 1;
            let x = self.k_b * rho;
            let xc = C64::new(x, 0.0);
            let jn = bessel_j_array(n_max + 1, xc);
            let hn = hankel2_array(n_max + 1, x);
            let djn = bessel_deriv(&jn, xc);
            let dhn = bessel_deriv(&hn, xc);
            for n in 0..=n_max {
                let w = if n == 0 { 1.0 } else { 2.0 * (n as f64 * psi).cos() };
                e += mj * (jn[n] + self.c[n] * hn[n]) * w;
                de += mj * self.k_b * (djn[n] + self.c[n] * dhn[n]) * w;
                mj *= C64::new(0.0, -1.0);
            }
        }
        (pre * e, pre * de)
    }

    /// Bistatic echo width σ(φ) = lim 2πρ |E_s|²/|E_inc|² = (4/k_b) |Σ cₙ e^{jnψ}|².
    pub fn echo_width(&self, phi: f64) -> f64 {
        let psi = phi - self.angle;
        let f: C64 = self
            .c
            .iter()
            .enumerate()
            .map(|(n, &c)| if n == 0 { c } else { 2.0 * c * (n as f64 * psi).cos() })
            .sum();
        4.0 / self.k_b * f.norm_sqr()
    }

    /// Scattering width (4/k_b) Σ_{n=−N}^{N} |cₙ|².
    pub fn scattering_width(&self) -> f64 {
        let s: f64 = self
            .c
            .iter()
            .enumerate()
            .map(|(n, c)| if n == 0 { c.norm_sqr() } else { 2.0 * c.norm_sqr() })
            .sum();
        4.0 / self.k_b * s
    }

    /// Extinction width from the optical theorem, −(4/k_b) Re Σ_{n=−N}^{N} cₙ.
    pub fn extinction_width(&self) -> f64 {
        let s: f64 = self
            .c
            .iter()
            .enumerate()
            .map(|(n, c)| if n == 0 { c.re } else { 2.0 * c.re })
            .sum();
        -4.0 / self.k_b * s
    }
}
