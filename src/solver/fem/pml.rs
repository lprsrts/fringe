//! Complex coordinate stretching for the FEM PML (e^{jωt} convention).
//!
//! `s_x(x) = 1 − j σ(d_x)/k_b` with `σ(d) = σ0 (d/L)²`, `σ0 = 3 ln(1/R0)/(2L)`, where
//! d is the depth into the PML (0 in the interior) and L the PML thickness, so a
//! normally incident wave is attenuated by R0 on its round trip. Same along y.
//! The weak form uses `Λ = diag(s_y/s_x, s_x/s_y)` and `s = s_x s_y`.

use crate::types::{Rect, Vec2, C64};

#[derive(Clone, Copy, Debug)]
pub struct Pml {
    pub interior: Rect,
    pub thickness: f64,
    pub sigma0: f64,
    pub k_b: f64,
}

/// Material tensor factors at one point.
#[derive(Clone, Copy, Debug)]
pub struct Stretch {
    pub lxx: C64,
    pub lyy: C64,
    pub s: C64,
}

impl Stretch {
    pub const IDENTITY: Stretch = Stretch { lxx: C64::new(1.0, 0.0), lyy: C64::new(1.0, 0.0), s: C64::new(1.0, 0.0) };
}

impl Pml {
    pub fn new(interior: Rect, thickness: f64, reflection: f64, k_b: f64) -> Pml {
        let sigma0 = if thickness > 0.0 { 3.0 * (1.0 / reflection).ln() / (2.0 * thickness) } else { 0.0 };
        Pml { interior, thickness, sigma0, k_b }
    }

    #[inline]
    fn s1(&self, d: f64) -> C64 {
        if d <= 0.0 {
            return C64::new(1.0, 0.0);
        }
        let r = d / self.thickness;
        C64::new(1.0, -self.sigma0 * r * r / self.k_b)
    }

    /// True if `p` lies in the PML (strictly outside the interior).
    #[inline]
    pub fn contains(&self, p: Vec2) -> bool {
        !self.interior.contains(p)
    }

    #[inline]
    pub fn at(&self, p: Vec2) -> Stretch {
        let r = &self.interior;
        let dx = (r.x_min - p.x).max(p.x - r.x_max).max(0.0);
        let dy = (r.y_min - p.y).max(p.y - r.y_max).max(0.0);
        if dx == 0.0 && dy == 0.0 {
            return Stretch::IDENTITY;
        }
        let sx = self.s1(dx);
        let sy = self.s1(dy);
        Stretch { lxx: sy / sx, lyy: sx / sy, s: sx * sy }
    }
}
