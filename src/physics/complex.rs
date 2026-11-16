//! Minimal complex arithmetic, enough for `q` parameters and ABCD matrices.

use std::ops::{Add, AddAssign, Div, Mul, MulAssign, Neg, Sub, SubAssign};

/// A complex number `re + i*im`.
#[derive(Clone, Copy, Debug, PartialEq)]
#[repr(C)]
pub struct Complex {
    pub re: f64,
    pub im: f64,
}

impl Complex {
    pub const ZERO: Self = Self::new(0.0, 0.0);
    pub const ONE: Self = Self::new(1.0, 0.0);
    pub const I: Self = Self::new(0.0, 1.0);

    #[inline]
    pub const fn new(re: f64, im: f64) -> Self {
        Self { re, im }
    }

    #[inline]
    pub const fn from_real(re: f64) -> Self {
        Self { re, im: 0.0 }
    }

    #[inline]
    pub const fn from_imag(im: f64) -> Self {
        Self { re: 0.0, im }
    }

    #[inline]
    pub fn conj(self) -> Self {
        Self::new(self.re, -self.im)
    }

    /// `re^2 + im^2`.
    #[inline]
    pub fn norm_sq(self) -> f64 {
        self.re * self.re + self.im * self.im
    }

    /// Modulus `|z|`.
    #[inline]
    pub fn norm(self) -> f64 {
        self.norm_sq().sqrt()
    }

    /// Argument in radians, in `(-pi, pi]`.
    #[inline]
    pub fn arg(self) -> f64 {
        self.im.atan2(self.re)
    }

    /// `1 / z`, or `None` if `|z|^2 < 1e-30` or the result would not be finite.
    /// An infinite `z` gives zero.
    #[inline]
    pub fn inv(self) -> Option<Self> {
        if self.re.is_infinite() || self.im.is_infinite() {
            return Some(Self::new(0.0, 0.0));
        }
        let nsq = self.norm_sq();
        if nsq < 1e-30 || nsq.is_nan() {
            None
        } else {
            let re = self.re / nsq;
            let im = -self.im / nsq;
            if re.is_finite() && im.is_finite() {
                Some(Self::new(re, im))
            } else {
                None
            }
        }
    }

    /// `self / rhs`, or `None` if `|rhs|^2 < 1e-30` or the result would not be finite.
    ///
    /// Shadows the `Div` operator on purpose: callers that care about singular
    /// denominators use this, the operator returns NaN instead.
    #[allow(clippy::should_implement_trait)]
    #[inline]
    pub fn div(self, rhs: Self) -> Option<Self> {
        if rhs.re.is_infinite() || rhs.im.is_infinite() {
            if self.re.is_finite() && self.im.is_finite() {
                return Some(Self::new(0.0, 0.0));
            }
            return None;
        }
        let dsq = rhs.norm_sq();
        if dsq < 1e-30 || dsq.is_nan() {
            None
        } else {
            let re = (self.re * rhs.re + self.im * rhs.im) / dsq;
            let im = (self.im * rhs.re - self.re * rhs.im) / dsq;
            if re.is_finite() && im.is_finite() {
                Some(Self::new(re, im))
            } else {
                None
            }
        }
    }

    /// `e^z`.
    #[inline]
    pub fn exp(self) -> Self {
        let r = self.re.exp();
        Self::new(r * self.im.cos(), r * self.im.sin())
    }
}

impl Add for Complex {
    type Output = Self;
    #[inline]
    fn add(self, rhs: Self) -> Self::Output {
        Self::new(self.re + rhs.re, self.im + rhs.im)
    }
}

impl Add<f64> for Complex {
    type Output = Self;
    #[inline]
    fn add(self, rhs: f64) -> Self::Output {
        Self::new(self.re + rhs, self.im)
    }
}

impl AddAssign for Complex {
    #[inline]
    fn add_assign(&mut self, rhs: Self) {
        self.re += rhs.re;
        self.im += rhs.im;
    }
}

impl Sub for Complex {
    type Output = Self;
    #[inline]
    fn sub(self, rhs: Self) -> Self::Output {
        Self::new(self.re - rhs.re, self.im - rhs.im)
    }
}

impl Sub<f64> for Complex {
    type Output = Self;
    #[inline]
    fn sub(self, rhs: f64) -> Self::Output {
        Self::new(self.re - rhs, self.im)
    }
}

impl SubAssign for Complex {
    #[inline]
    fn sub_assign(&mut self, rhs: Self) {
        self.re -= rhs.re;
        self.im -= rhs.im;
    }
}

impl Mul for Complex {
    type Output = Self;
    #[inline]
    fn mul(self, rhs: Self) -> Self::Output {
        Self::new(
            self.re * rhs.re - self.im * rhs.im,
            self.re * rhs.im + self.im * rhs.re,
        )
    }
}

impl Mul<f64> for Complex {
    type Output = Self;
    #[inline]
    fn mul(self, rhs: f64) -> Self::Output {
        Self::new(self.re * rhs, self.im * rhs)
    }
}

impl Mul<Complex> for f64 {
    type Output = Complex;
    #[inline]
    fn mul(self, rhs: Complex) -> Self::Output {
        Complex::new(self * rhs.re, self * rhs.im)
    }
}

impl MulAssign for Complex {
    #[inline]
    fn mul_assign(&mut self, rhs: Self) {
        *self = *self * rhs;
    }
}

impl Div<f64> for Complex {
    type Output = Self;
    #[inline]
    fn div(self, rhs: f64) -> Self::Output {
        Self::new(self.re / rhs, self.im / rhs)
    }
}

impl Div<Complex> for Complex {
    type Output = Self;
    #[inline]
    fn div(self, rhs: Complex) -> Self::Output {
        self.div(rhs).unwrap_or(Self::new(f64::NAN, f64::NAN))
    }
}

impl Neg for Complex {
    type Output = Self;
    #[inline]
    fn neg(self) -> Self::Output {
        Self::new(-self.re, -self.im)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn arithmetic() {
        let a = Complex::new(3.0, 4.0);
        let b = Complex::new(1.0, -2.0);

        assert_eq!(a + b, Complex::new(4.0, 2.0));
        assert_eq!(a - b, Complex::new(2.0, 6.0));
        assert_eq!(a * b, Complex::new(11.0, -2.0));
        assert_eq!(-a, Complex::new(-3.0, -4.0));
        assert_eq!(a.conj(), Complex::new(3.0, -4.0));
        assert!((a.norm_sq() - 25.0).abs() < 1e-12);
        assert!((a.norm() - 5.0).abs() < 1e-12);
    }

    #[test]
    fn inverse_and_division() {
        let a = Complex::new(3.0, 4.0);
        let inv = a.inv().unwrap();
        let prod = a * inv;
        assert!((prod.re - 1.0).abs() < 1e-12);
        assert!(prod.im.abs() < 1e-12);

        let b = Complex::new(1.0, 2.0);
        let div = a.div(b).unwrap();
        let expected_div = a * b.inv().unwrap();
        assert!((div.re - expected_div.re).abs() < 1e-12);
        assert!((div.im - expected_div.im).abs() < 1e-12);
    }

    #[test]
    fn singular_division_returns_none() {
        let a = Complex::new(1.0, 2.0);
        let zero = Complex::new(0.0, 0.0);
        assert!(zero.inv().is_none());
        assert!(a.div(zero).is_none());

        let near_zero = Complex::new(1e-16, 1e-16);
        assert!(near_zero.inv().is_none());
        assert!(a.div(near_zero).is_none());

        // The intermediate products overflow to inf - inf; that must not leak out as Some(NaN).
        let big1 = Complex::new(1e200, 1e200);
        let big2 = Complex::new(1e200, -1e200);
        assert!(big1.div(big2).is_none());
    }

    #[test]
    fn scalar_operations() {
        let a = Complex::new(2.0, 3.0);
        assert_eq!(a + 5.0, Complex::new(7.0, 3.0));
        assert_eq!(a - 1.0, Complex::new(1.0, 3.0));
        assert_eq!(a * 2.0, Complex::new(4.0, 6.0));
        assert_eq!(3.0 * a, Complex::new(6.0, 9.0));
        assert_eq!(a / 2.0, Complex::new(1.0, 1.5));
    }
}
