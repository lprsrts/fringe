//! Ez (s-polarised) transmission through a slab with faces normal to x, for any
//! incident field made of plane waves (spec §5b). Each component with k_x > 0 is
//! propagated with the Airy (Fabry–Perot) coefficients.

use crate::source::Incident;
use crate::types::{Vec2, C64, J};

pub struct AirySlab {
    pub x_front: f64,
    pub thickness: f64,
    /// Slab index n − jk.
    pub n_slab: C64,
    pub n_b: f64,
    pub k0: f64,
}

/// Coefficients for one transverse wavenumber.
#[derive(Clone, Copy, Debug)]
pub struct AiryCoefficients {
    pub r: C64,
    pub t: C64,
    /// Forward and backward amplitudes inside, referred to the front face.
    pub a: C64,
    pub b: C64,
    pub k_x: C64,
    pub k2x: C64,
}

impl AirySlab {
    pub fn coefficients(&self, k_y: f64) -> AiryCoefficients {
        let k_b = self.k0 * self.n_b;
        // Both normal wavenumbers take the branch with Im ≤ 0 (decaying along +x
        // under e^{-jk·r}). The principal sqrt picks Im ≥ 0 when the argument is a
        // negative real with +0.0 imaginary part (an evanescent component, or a
        // lossless slab built with C64::new(n, 0.0)), so the sign is forced here.
        // r and t are invariant under k2x → −k2x; this only avoids overflow.
        let mut k_x = C64::new(k_b * k_b - k_y * k_y, 0.0).sqrt();
        if k_x.im > 0.0 {
            k_x = -k_x;
        }
        let mut k2x = (self.k0 * self.k0 * self.n_slab * self.n_slab - k_y * k_y).sqrt();
        if k2x.im > 0.0 {
            k2x = -k2x;
        }
        let r12 = (k_x - k2x) / (k_x + k2x);
        let r23 = -r12;
        let t12 = 2.0 * k_x / (k_x + k2x);
        let t23 = 2.0 * k2x / (k2x + k_x);
        let beta = k2x * self.thickness;
        let e2 = (-2.0 * J * beta).exp();
        let den = 1.0 + r12 * r23 * e2;
        let r = (r12 + r23 * e2) / den;
        let t = t12 * t23 * (-J * beta).exp() / den;
        let a = t12 / den;
        let b = a * r23 * e2;
        AiryCoefficients { r, t, a, b, k_x, k2x }
    }

    /// Reflection and transmission for transverse wavenumber `k_y`.
    pub fn rt(&self, k_y: f64) -> (C64, C64) {
        let c = self.coefficients(k_y);
        (c.r, c.t)
    }

    /// Total field at `p`. Components with k_x ≤ 0 travel away from the slab and
    /// are added unchanged on the front side only.
    pub fn field(&self, inc: &Incident, p: Vec2) -> C64 {
        let xf = self.x_front;
        let xb = xf + self.thickness;
        let o = inc.origin;
        let mut e = C64::new(0.0, 0.0);
        for m in &inc.comps {
            let (kx, ky) = (m.k[0], m.k[1]);
            if kx <= 0.0 {
                if p.x < xf {
                    e += m.c * (-J * (kx * (p.x - o.x) + ky * (p.y - o.y))).exp();
                }
                continue;
            }
            let co = self.coefficients(ky);
            let pm = m.c * (-J * (kx * (xf - o.x) + ky * (p.y - o.y))).exp();
            if p.x < xf {
                e += pm * ((-J * kx * (p.x - xf)).exp() + co.r * (J * kx * (p.x - xf)).exp());
            } else if p.x <= xb {
                e += pm * (co.a * (-J * co.k2x * (p.x - xf)).exp() + co.b * (J * co.k2x * (p.x - xf)).exp());
            } else {
                e += pm * co.t * (-J * kx * (p.x - xb)).exp();
            }
        }
        e
    }
}
