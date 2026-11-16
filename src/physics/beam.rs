//! Closed-form TEM00 Gaussian beam.

use super::complex::Complex;
use std::f64::consts::PI;

/// A TEM00 Gaussian beam travelling along +z. All lengths are in metres.
#[derive(Clone, Copy, Debug, PartialEq)]
#[repr(C)]
pub struct GaussianBeam {
    /// Vacuum wavelength.
    pub wavelength: f64,
    /// Waist radius at the 1/e^2 intensity point.
    pub w0: f64,
    /// Axial position of the waist.
    pub z0: f64,
    /// Refractive index of the medium, at least 1.
    pub refractive_index: f64,
    /// Total power in watts.
    pub power: f64,
}

impl Default for GaussianBeam {
    /// A 1 W He-Ne beam (632.8 nm) with a 0.5 mm waist at z = 0, in air.
    fn default() -> Self {
        Self {
            wavelength: 632.8e-9,
            w0: 0.5e-3,
            z0: 0.0,
            refractive_index: 1.0,
            power: 1.0,
        }
    }
}

impl GaussianBeam {
    /// Validating constructor. Rejects non-finite values, `wavelength <= 0`,
    /// `w0 <= 0`, `n < 1` and negative power.
    pub fn new(
        wavelength: f64,
        w0: f64,
        z0: f64,
        refractive_index: f64,
        power: f64,
    ) -> Result<Self, &'static str> {
        if !wavelength.is_finite() || wavelength <= 0.0 {
            return Err("wavelength must be positive and finite");
        }
        if !w0.is_finite() || w0 <= 0.0 {
            return Err("waist radius w0 must be positive and finite");
        }
        if !z0.is_finite() {
            return Err("waist position z0 must be finite");
        }
        if !refractive_index.is_finite() || refractive_index < 1.0 {
            return Err("refractive index must be finite and >= 1");
        }
        if !power.is_finite() || power < 0.0 {
            return Err("power must be finite and non-negative");
        }
        Ok(Self {
            wavelength,
            w0,
            z0,
            refractive_index,
            power,
        })
    }

    /// Recover the beam whose complex parameter at `z` is `q`.
    ///
    /// `q(z) = (z - z0) + i*z_R`, so `z0 = z - Re q` and `w0 = sqrt(Im q * lambda / (pi*n))`.
    /// Returns `None` if `Im q <= 0` (not a physical beam) or any input is out of range.
    pub fn from_q_at(
        q: Complex,
        z: f64,
        wavelength: f64,
        refractive_index: f64,
        power: f64,
    ) -> Option<Self> {
        if !z.is_finite()
            || !q.re.is_finite()
            || !q.im.is_finite()
            || q.im <= 0.0
            || !wavelength.is_finite()
            || wavelength <= 0.0
            || !refractive_index.is_finite()
            || refractive_index < 1.0
            || !power.is_finite()
            || power < 0.0
        {
            return None;
        }
        let z_r = q.im;
        let z0 = z - q.re;
        let w0_sq = z_r * wavelength / (PI * refractive_index);
        if !w0_sq.is_finite() || w0_sq <= 0.0 {
            return None;
        }
        let w0 = w0_sq.sqrt();
        Some(Self {
            wavelength,
            w0,
            z0,
            refractive_index,
            power,
        })
    }

    /// Wavenumber in the medium, `k = 2*pi*n / lambda`.
    #[inline]
    pub fn wavenumber(&self) -> f64 {
        2.0 * PI * self.refractive_index / self.wavelength
    }

    /// `z_R = pi*n*w0^2 / lambda`.
    #[inline]
    pub fn rayleigh_range(&self) -> f64 {
        PI * self.refractive_index * self.w0 * self.w0 / self.wavelength
    }

    /// Far-field half-angle divergence in radians, `lambda / (pi*n*w0)`.
    #[inline]
    pub fn divergence_half_angle(&self) -> f64 {
        self.wavelength / (PI * self.refractive_index * self.w0)
    }

    /// Whether the divergence is small enough (<= 0.5 rad) for the paraxial
    /// formulas here to be trusted.
    #[inline]
    pub fn is_paraxial_valid(&self) -> bool {
        self.divergence_half_angle() <= 0.5
    }

    /// Beam radius `w(z) = w0 * sqrt(1 + ((z - z0)/z_R)^2)`.
    #[inline]
    pub fn waist_at(&self, z: f64) -> f64 {
        let dz = z - self.z0;
        let z_r = self.rayleigh_range();
        self.w0 * (1.0 + (dz / z_r) * (dz / z_r)).sqrt()
    }

    /// Wavefront curvature `1/R(z) = (z - z0) / ((z - z0)^2 + z_R^2)`.
    ///
    /// Prefer this over [`radius_of_curvature`](Self::radius_of_curvature): it is
    /// finite everywhere and simply 0 at the waist.
    #[inline]
    pub fn curvature_at(&self, z: f64) -> f64 {
        if z.is_infinite() {
            return 0.0;
        }
        let dz = z - self.z0;
        let z_r = self.rayleigh_range();
        dz / (dz * dz + z_r * z_r)
    }

    /// Wavefront radius `R(z) = (z - z0) + z_R^2 / (z - z0)`, or `None` at the
    /// waist where the wavefront is flat.
    #[inline]
    pub fn radius_of_curvature(&self, z: f64) -> Option<f64> {
        let dz = z - self.z0;
        if dz.abs() < 1e-15 {
            None
        } else {
            let z_r = self.rayleigh_range();
            Some(dz + (z_r * z_r) / dz)
        }
    }

    /// Gouy phase `atan((z - z0) / z_R)`.
    #[inline]
    pub fn gouy_phase(&self, z: f64) -> f64 {
        let dz = z - self.z0;
        let z_r = self.rayleigh_range();
        (dz / z_r).atan()
    }

    /// Complex beam parameter `q(z) = (z - z0) + i*z_R`.
    #[inline]
    pub fn q_at(&self, z: f64) -> Complex {
        Complex::new(z - self.z0, self.rayleigh_range())
    }

    /// On-axis intensity at the waist, `2P / (pi*w0^2)`, in W/m^2.
    #[inline]
    pub fn peak_intensity(&self) -> f64 {
        2.0 * self.power / (PI * self.w0 * self.w0)
    }

    /// Intensity `I0 * (w0/w(z))^2 * exp(-2r^2 / w(z)^2)`. Integrates to `power`
    /// over every transverse plane.
    #[inline]
    pub fn intensity_at(&self, r: f64, z: f64) -> f64 {
        let w_z = self.waist_at(z);
        let ratio = self.w0 / w_z;
        let i0 = self.peak_intensity();
        let exponent = -2.0 * (r * r) / (w_z * w_z);
        i0 * ratio * ratio * exponent.exp()
    }

    /// Field `(amplitude, phase)`, with amplitude `sqrt(I)` and phase
    /// `k*z - psi(z) + k*r^2 / (2R(z))`.
    #[inline]
    pub fn electric_field_at(&self, r: f64, z: f64) -> (f64, f64) {
        let intensity = self.intensity_at(r, z);
        let amplitude = intensity.sqrt();

        let k = self.wavenumber();
        let psi = self.gouy_phase(z);
        let kappa = self.curvature_at(z);
        let phase = k * z - psi + 0.5 * k * r * r * kappa;

        (amplitude, phase)
    }

    /// Field as a complex number, `amplitude * exp(i*phase)`.
    #[inline]
    pub fn complex_field_at(&self, r: f64, z: f64) -> Complex {
        let (amp, phase) = self.electric_field_at(r, z);
        Complex::new(amp * phase.cos(), amp * phase.sin())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn he_ne_reference_values() {
        let beam = GaussianBeam {
            wavelength: 632.8e-9,
            w0: 0.5e-3,
            z0: 0.0,
            refractive_index: 1.0,
            power: 1.0,
        };

        let z_r = beam.rayleigh_range();
        assert!((z_r - 1.2411475).abs() < 1e-6, "z_R was {}", z_r);

        let w_zr = beam.waist_at(z_r);
        let expected_w_zr = (2.0f64).sqrt() * beam.w0;
        assert!((w_zr - 7.0710678e-4).abs() < 1e-9);
        assert!((w_zr - expected_w_zr).abs() < 1e-12);

        let r_zr = beam.radius_of_curvature(z_r).unwrap();
        assert!((r_zr - 2.4822951).abs() < 1e-6);
        assert!((r_zr - 2.0 * z_r).abs() < 1e-12);

        let psi_zr = beam.gouy_phase(z_r);
        assert!((psi_zr - PI / 4.0).abs() < 1e-12);

        assert_eq!(beam.curvature_at(0.0), 0.0);
        assert!(beam.radius_of_curvature(0.0).is_none());
    }

    #[test]
    fn power_is_conserved_along_z() {
        let beam = GaussianBeam::default();
        let z_values = [0.0, beam.rayleigh_range(), 5.0 * beam.rayleigh_range()];

        // Trapezoidal 2*pi * int_0^r_max I(r, z) r dr; r_max is well beyond w(5 z_R).
        let r_max = 30.0 * beam.w0;
        let n_steps = 10000;
        let dr = r_max / n_steps as f64;

        for &z in &z_values {
            let mut integral = 0.0;
            for i in 0..n_steps {
                let r1 = i as f64 * dr;
                let r2 = (i + 1) as f64 * dr;
                let val1 = beam.intensity_at(r1, z) * r1;
                let val2 = beam.intensity_at(r2, z) * r2;
                integral += 0.5 * (val1 + val2) * dr;
            }
            let calculated_power = 2.0 * PI * integral;
            let relative_error = (calculated_power - beam.power).abs() / beam.power;
            assert!(
                relative_error < 1e-5,
                "Power at z={} was {} (expected {}), rel error {}",
                z,
                calculated_power,
                beam.power,
                relative_error
            );
        }
    }

    #[test]
    fn from_q_at_round_trips() {
        let original = GaussianBeam {
            wavelength: 532.0e-9,
            w0: 0.2e-3,
            z0: 0.15,
            refractive_index: 1.0,
            power: 2.5,
        };

        let z_query = 0.45;
        let q = original.q_at(z_query);
        let reconstructed = GaussianBeam::from_q_at(
            q,
            z_query,
            original.wavelength,
            original.refractive_index,
            original.power,
        )
        .unwrap();

        assert!((reconstructed.w0 - original.w0).abs() < 1e-12);
        assert!((reconstructed.z0 - original.z0).abs() < 1e-12);
        assert_eq!(reconstructed.wavelength, original.wavelength);
        assert_eq!(reconstructed.power, original.power);
    }
}
