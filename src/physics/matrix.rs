//! Paraxial ray transfer (ABCD) matrices and the `q` transformation law
//! `q2 = (A*q1 + B) / (C*q1 + D)`.

use super::complex::Complex;
use std::f64::consts::PI;
use std::ops::Mul;

/// Real 2x2 ray transfer matrix `[[a, b], [c, d]]`.
#[derive(Clone, Copy, Debug, PartialEq)]
#[repr(C)]
pub struct AbcdMatrix {
    pub a: f64,
    pub b: f64,
    pub c: f64,
    pub d: f64,
}

impl AbcdMatrix {
    pub const IDENTITY: Self = Self {
        a: 1.0,
        b: 0.0,
        c: 0.0,
        d: 1.0,
    };

    #[inline]
    pub const fn new(a: f64, b: f64, c: f64, d: f64) -> Self {
        Self { a, b, c, d }
    }

    /// Propagation over distance `d`: `[[1, d], [0, 1]]`.
    #[inline]
    pub fn free_space(d: f64) -> Self {
        Self {
            a: 1.0,
            b: d,
            c: 0.0,
            d: 1.0,
        }
    }

    /// Thin lens, `f > 0` converging: `[[1, 0], [-1/f, 1]]`.
    #[inline]
    pub fn thin_lens(f: f64) -> Self {
        Self {
            a: 1.0,
            b: 0.0,
            c: -1.0 / f,
            d: 1.0,
        }
    }

    /// Spherical mirror, `r > 0` concave (focal length `r/2`): `[[1, 0], [-2/r, 1]]`.
    #[inline]
    pub fn curved_mirror(r: f64) -> Self {
        Self {
            a: 1.0,
            b: 0.0,
            c: -2.0 / r,
            d: 1.0,
        }
    }

    /// Flat mirror. The optical axis is treated as unfolded, so this is the identity.
    #[inline]
    pub fn flat_mirror() -> Self {
        Self::IDENTITY
    }

    /// Refraction from index `n1` into `n2`: `[[1, 0], [(n1 - n2) / (n2*R), n1/n2]]`.
    ///
    /// `radius` is the surface curvature, positive when its centre lies in medium 2;
    /// `None` (or ~0) means a flat surface.
    #[inline]
    pub fn dielectric_interface(n1: f64, n2: f64, radius: Option<f64>) -> Self {
        let c = match radius {
            Some(r) if r.abs() > 1e-15 => (n1 - n2) / (n2 * r),
            _ => 0.0,
        };
        Self {
            a: 1.0,
            b: 0.0,
            c,
            d: n1 / n2,
        }
    }

    /// Same as [`ComplexAbcdMatrix::gaussian_aperture`]; the C element is imaginary,
    /// so the result cannot be a real matrix.
    #[inline]
    pub fn gaussian_aperture(wa: f64, lambda: f64, n: f64) -> ComplexAbcdMatrix {
        ComplexAbcdMatrix::gaussian_aperture(wa, lambda, n)
    }

    /// `ad - bc`. Equals `n1/n2` for a single interface and 1 for everything else here.
    #[inline]
    pub fn det(&self) -> f64 {
        self.a * self.d - self.b * self.c
    }

    /// `self * rhs`. For a system, the first element the beam meets goes rightmost.
    #[inline]
    pub fn mul(&self, rhs: &Self) -> Self {
        Self {
            a: self.a * rhs.a + self.b * rhs.c,
            b: self.a * rhs.b + self.b * rhs.d,
            c: self.c * rhs.a + self.d * rhs.c,
            d: self.c * rhs.b + self.d * rhs.d,
        }
    }

    /// Apply the matrix to `q`, failing if the denominator vanishes.
    pub fn try_transform_q(&self, q1: Complex) -> Result<Complex, String> {
        let num = Complex::new(self.a * q1.re + self.b, self.a * q1.im);
        let den = Complex::new(self.c * q1.re + self.d, self.c * q1.im);
        num.div(den)
            .ok_or_else(|| "Singularity in q transformation".to_string())
    }

    /// Like [`try_transform_q`](Self::try_transform_q) but returns NaN on a singular denominator.
    #[inline]
    pub fn transform_q(&self, q1: Complex) -> Complex {
        self.try_transform_q(q1)
            .unwrap_or(Complex::new(f64::NAN, f64::NAN))
    }

    /// Transform the reduced parameter `q/n` across a change of medium:
    /// `q2 = n2 * (A*(q1/n1) + B) / (C*(q1/n1) + D)`.
    pub fn try_transform_q_refraction(
        &self,
        q1: Complex,
        n1: f64,
        n2: f64,
    ) -> Result<Complex, String> {
        if !n1.is_finite() || n1 <= 0.0 || !n2.is_finite() || n2 <= 0.0 {
            return Err("refractive indices must be positive and finite".to_string());
        }
        let q1_reduced = q1 / n1;
        let num = Complex::new(self.a * q1_reduced.re + self.b, self.a * q1_reduced.im);
        let den = Complex::new(self.c * q1_reduced.re + self.d, self.c * q1_reduced.im);
        let q2_reduced = num
            .div(den)
            .ok_or_else(|| "Singularity in q transformation across interface".to_string())?;
        Ok(q2_reduced * n2)
    }

    /// Like [`try_transform_q_refraction`](Self::try_transform_q_refraction) but returns NaN on failure.
    #[inline]
    pub fn transform_q_refraction(&self, q1: Complex, n1: f64, n2: f64) -> Complex {
        self.try_transform_q_refraction(q1, n1, n2)
            .unwrap_or(Complex::new(f64::NAN, f64::NAN))
    }

    #[inline]
    pub fn to_complex(&self) -> ComplexAbcdMatrix {
        ComplexAbcdMatrix {
            a: Complex::from_real(self.a),
            b: Complex::from_real(self.b),
            c: Complex::from_real(self.c),
            d: Complex::from_real(self.d),
        }
    }
}

impl Mul for AbcdMatrix {
    type Output = Self;
    #[inline]
    fn mul(self, rhs: Self) -> Self::Output {
        AbcdMatrix::mul(&self, &rhs)
    }
}

impl Mul<&AbcdMatrix> for AbcdMatrix {
    type Output = Self;
    #[inline]
    fn mul(self, rhs: &AbcdMatrix) -> Self::Output {
        AbcdMatrix::mul(&self, rhs)
    }
}

impl Mul<AbcdMatrix> for &AbcdMatrix {
    type Output = AbcdMatrix;
    #[inline]
    fn mul(self, rhs: AbcdMatrix) -> Self::Output {
        AbcdMatrix::mul(self, &rhs)
    }
}

impl Mul<&AbcdMatrix> for &AbcdMatrix {
    type Output = AbcdMatrix;
    #[inline]
    fn mul(self, rhs: &AbcdMatrix) -> Self::Output {
        AbcdMatrix::mul(self, rhs)
    }
}

/// ABCD matrix with complex entries, needed for Gaussian apertures.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ComplexAbcdMatrix {
    pub a: Complex,
    pub b: Complex,
    pub c: Complex,
    pub d: Complex,
}

impl ComplexAbcdMatrix {
    pub const IDENTITY: Self = Self {
        a: Complex::ONE,
        b: Complex::ZERO,
        c: Complex::ZERO,
        d: Complex::ONE,
    };

    pub const fn new(a: Complex, b: Complex, c: Complex, d: Complex) -> Self {
        Self { a, b, c, d }
    }

    /// Gaussian aperture with amplitude transmission `exp(-r^2 / wa^2)`:
    /// `[[1, 0], [-i*lambda / (pi*n*wa^2), 1]]`.
    ///
    /// The beam radius after it obeys `1/w2^2 = 1/w1^2 + 1/wa^2`.
    pub fn gaussian_aperture(wa: f64, lambda: f64, n: f64) -> Self {
        let c_imag = -lambda / (PI * n * wa * wa);
        Self {
            a: Complex::ONE,
            b: Complex::ZERO,
            c: Complex::from_imag(c_imag),
            d: Complex::ONE,
        }
    }

    pub fn mul(&self, rhs: &Self) -> Self {
        Self {
            a: self.a * rhs.a + self.b * rhs.c,
            b: self.a * rhs.b + self.b * rhs.d,
            c: self.c * rhs.a + self.d * rhs.c,
            d: self.c * rhs.b + self.d * rhs.d,
        }
    }

    /// Apply the matrix to `q`, failing if the denominator vanishes.
    pub fn try_transform_q(&self, q1: Complex) -> Result<Complex, String> {
        let num = self.a * q1 + self.b;
        let den = self.c * q1 + self.d;
        num.div(den)
            .ok_or_else(|| "Singularity in q transformation".to_string())
    }

    /// Like [`try_transform_q`](Self::try_transform_q) but returns NaN on a singular denominator.
    #[inline]
    pub fn transform_q(&self, q1: Complex) -> Complex {
        self.try_transform_q(q1)
            .unwrap_or(Complex::new(f64::NAN, f64::NAN))
    }

    /// Complex counterpart of [`AbcdMatrix::try_transform_q_refraction`].
    pub fn try_transform_q_refraction(
        &self,
        q1: Complex,
        n1: f64,
        n2: f64,
    ) -> Result<Complex, String> {
        if !n1.is_finite() || n1 <= 0.0 || !n2.is_finite() || n2 <= 0.0 {
            return Err("refractive indices must be positive and finite".to_string());
        }
        let q1_reduced = q1 / n1;
        let num = self.a * q1_reduced + self.b;
        let den = self.c * q1_reduced + self.d;
        let q2_reduced = num
            .div(den)
            .ok_or_else(|| "Singularity in q transformation across interface".to_string())?;
        Ok(q2_reduced * n2)
    }

    /// Like [`try_transform_q_refraction`](Self::try_transform_q_refraction) but returns NaN on failure.
    #[inline]
    pub fn transform_q_refraction(&self, q1: Complex, n1: f64, n2: f64) -> Complex {
        self.try_transform_q_refraction(q1, n1, n2)
            .unwrap_or(Complex::new(f64::NAN, f64::NAN))
    }
}

impl From<AbcdMatrix> for ComplexAbcdMatrix {
    #[inline]
    fn from(m: AbcdMatrix) -> Self {
        m.to_complex()
    }
}

impl Mul for ComplexAbcdMatrix {
    type Output = Self;
    #[inline]
    fn mul(self, rhs: Self) -> Self::Output {
        ComplexAbcdMatrix::mul(&self, &rhs)
    }
}

impl Mul<&ComplexAbcdMatrix> for ComplexAbcdMatrix {
    type Output = Self;
    #[inline]
    fn mul(self, rhs: &ComplexAbcdMatrix) -> Self::Output {
        ComplexAbcdMatrix::mul(&self, rhs)
    }
}

impl Mul<ComplexAbcdMatrix> for &ComplexAbcdMatrix {
    type Output = ComplexAbcdMatrix;
    #[inline]
    fn mul(self, rhs: ComplexAbcdMatrix) -> Self::Output {
        ComplexAbcdMatrix::mul(self, &rhs)
    }
}

impl Mul<&ComplexAbcdMatrix> for &ComplexAbcdMatrix {
    type Output = ComplexAbcdMatrix;
    #[inline]
    fn mul(self, rhs: &ComplexAbcdMatrix) -> Self::Output {
        ComplexAbcdMatrix::mul(self, rhs)
    }
}

impl Mul<AbcdMatrix> for ComplexAbcdMatrix {
    type Output = Self;
    #[inline]
    fn mul(self, rhs: AbcdMatrix) -> Self::Output {
        ComplexAbcdMatrix::mul(&self, &rhs.to_complex())
    }
}

impl Mul<ComplexAbcdMatrix> for AbcdMatrix {
    type Output = ComplexAbcdMatrix;
    #[inline]
    fn mul(self, rhs: ComplexAbcdMatrix) -> Self::Output {
        ComplexAbcdMatrix::mul(&self.to_complex(), &rhs)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identity_and_product() {
        let id = AbcdMatrix::IDENTITY;
        let drift = AbcdMatrix::free_space(1.5);
        let lens = AbcdMatrix::thin_lens(0.1);

        assert_eq!(id * drift, drift);
        assert_eq!(drift * id, drift);

        // [[1, d], [0, 1]] * [[1, 0], [-1/f, 1]] = [[1 - d/f, d], [-1/f, 1]]
        let combined = drift * lens;
        assert!((combined.a - (1.0 - 1.5 / 0.1)).abs() < 1e-12);
        assert!((combined.b - 1.5).abs() < 1e-12);
        assert!((combined.c - (-10.0)).abs() < 1e-12);
        assert!((combined.d - 1.0).abs() < 1e-12);
        assert!((combined.det() - 1.0).abs() < 1e-12);
    }

    #[test]
    fn waist_at_front_focal_plane_images_to_back_focal_plane() {
        let lambda = 632.8e-9;
        let w01 = 0.5e-3;
        let f = 0.1;
        let z_r1 = PI * w01 * w01 / lambda;

        let q_waist = Complex::new(0.0, z_r1);
        let q_at_lens = AbcdMatrix::free_space(f).transform_q(q_waist);
        assert!((q_at_lens.re - f).abs() < 1e-12);

        let q_after_lens = AbcdMatrix::thin_lens(f).transform_q(q_at_lens);
        let q_at_waist2 = AbcdMatrix::free_space(f).transform_q(q_after_lens);

        // The new waist sits exactly at the back focal plane.
        assert!(
            q_at_waist2.re.abs() < 1e-12,
            "Re(q) was {}, expected 0",
            q_at_waist2.re
        );

        // ...with radius f*lambda / (pi*w01).
        let z_r2 = q_at_waist2.im;
        let w02 = (z_r2 * lambda / PI).sqrt();
        let expected_w02 = f * lambda / (PI * w01);
        assert!(
            (w02 - expected_w02).abs() < 1e-12,
            "w02 was {}, expected {}",
            w02,
            expected_w02
        );
        assert!((w02 * 1e6 - 40.2853).abs() < 1e-3);
    }

    #[test]
    fn flat_interface_scales_rayleigh_range() {
        let n1 = 1.0;
        let n2 = 1.5;
        let lambda = 1064.0e-9;
        let w0 = 1.0e-3;
        let z_r1 = PI * n1 * w0 * w0 / lambda;

        let q1 = Complex::new(0.0, z_r1);
        let interface = AbcdMatrix::dielectric_interface(n1, n2, None);
        let q2 = interface.transform_q(q1);

        assert_eq!(q2.re, 0.0);
        let expected_zr2 = (n2 / n1) * z_r1;
        assert!((q2.im - expected_zr2).abs() < 1e-12);
    }

    #[test]
    fn gaussian_aperture_narrows_beam() {
        let lambda = 532.0e-9;
        let n = 1.0;
        let w1 = 1.0e-3;
        let wa = 0.8e-3;

        let z_r1 = PI * n * w1 * w1 / lambda;
        let q1 = Complex::new(0.0, z_r1);

        let ap = AbcdMatrix::gaussian_aperture(wa, lambda, n);
        let q2 = ap.transform_q(q1);

        // Im(1/q) = -lambda / (pi*n*w^2)
        let inv_q2 = q2.inv().unwrap();
        let w2 = (-lambda / (PI * n * inv_q2.im)).sqrt();

        let expected_w2 = (1.0 / (w1 * w1) + 1.0 / (wa * wa)).powf(-0.5);
        assert!(
            (w2 - expected_w2).abs() < 1e-12,
            "w2 was {}, expected {}",
            w2,
            expected_w2
        );
        assert!((w2 * 1e3 - 0.624695).abs() < 1e-5);
    }
}
