//! Optical elements and propagation through a sequence of them.

use std::f64::consts::PI;

use super::beam::GaussianBeam;
use super::complex::Complex;
use super::matrix::{AbcdMatrix, ComplexAbcdMatrix};

/// A thin optical element. Lengths are in metres.
#[derive(Clone, Debug, PartialEq)]
pub enum OpticalElement {
    /// Thin lens; positive focal length converges.
    ThinLens { focal_length: f64 },
    /// Spherical mirror, positive radius concave (focal length `radius / 2`).
    CurvedMirror { radius: f64 },
    /// Flat mirror. A no-op, since the axis is drawn unfolded.
    FlatMirror,
    /// Boundary from index `n1` into `n2`, flat if `radius` is `None`.
    DielectricInterface {
        n1: f64,
        n2: f64,
        radius: Option<f64>,
    },
    /// Soft aperture with field transmission `exp(-r^2 / radius^2)`.
    GaussianAperture { radius: f64 },
    /// Circular hard-edged aperture. Attenuates power only; see [`OpticalTrain::beam_at`].
    HardAperture { radius: f64 },
}

/// An element at axial position `z`.
#[derive(Clone, Debug, PartialEq)]
pub struct PlacedElement {
    pub z: f64,
    pub element: OpticalElement,
}

impl PlacedElement {
    #[inline]
    pub const fn new(z: f64, element: OpticalElement) -> Self {
        Self { z, element }
    }
}

/// Elements along the axis, kept sorted by `z`.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct OpticalTrain {
    pub elements: Vec<PlacedElement>,
}

impl OpticalTrain {
    pub fn new() -> Self {
        Self {
            elements: Vec::new(),
        }
    }

    /// Insert an element at `z`, after any existing elements at the same position.
    pub fn add_element(&mut self, z: f64, element: OpticalElement) {
        let placed = PlacedElement::new(z, element);
        let idx = self.elements.partition_point(|e| e.z <= z);
        self.elements.insert(idx, placed);
    }

    /// Re-sort by `z`. Only needed after editing `elements` directly.
    pub fn sort(&mut self) {
        self.elements
            .sort_by(|a, b| a.z.partial_cmp(&b.z).unwrap_or(std::cmp::Ordering::Equal));
    }

    pub fn elements(&self) -> &[PlacedElement] {
        &self.elements
    }

    /// Elements with position `<= z`.
    pub fn elements_up_to(&self, z: f64) -> &[PlacedElement] {
        let idx = self.elements.partition_point(|e| e.z <= z);
        &self.elements[..idx]
    }

    /// The beam at `z` after `initial_beam` has passed through every element at or
    /// before `z`.
    ///
    /// The returned beam describes the field locally: its `w0` and `z0` are those of
    /// the virtual waist that reproduces `q(z)`, and `power` includes aperture losses.
    /// Elements must be sorted by position (see [`add_element`](Self::add_element)).
    pub fn beam_at(&self, initial_beam: &GaussianBeam, z: f64) -> Result<GaussianBeam, String> {
        if !z.is_finite() {
            return Err("z must be finite".to_string());
        }
        let active = self.elements_up_to(z);
        let Some(first) = active.first() else {
            return Ok(*initial_beam);
        };

        let wavelength = initial_beam.wavelength;
        let mut n = initial_beam.refractive_index;
        let mut power = initial_beam.power;
        let mut current_z = first.z;
        let mut q = initial_beam.q_at(current_z);

        for elem in active {
            let dz = elem.z - current_z;
            if dz > 0.0 {
                q = q + dz;
                current_z = elem.z;
            }

            match &elem.element {
                OpticalElement::ThinLens { focal_length } => {
                    q = AbcdMatrix::thin_lens(*focal_length).try_transform_q(q)?;
                }
                OpticalElement::CurvedMirror { radius } => {
                    q = AbcdMatrix::curved_mirror(*radius).try_transform_q(q)?;
                }
                OpticalElement::FlatMirror => {}
                OpticalElement::DielectricInterface { n1, n2, radius } => {
                    q = AbcdMatrix::dielectric_interface(*n1, *n2, *radius).try_transform_q(q)?;
                    n = *n2;
                }
                OpticalElement::GaussianAperture { radius } => {
                    let w_sq =
                        beam_radius_sq(q, wavelength, n).ok_or("Singular q before aperture")?;
                    q = ComplexAbcdMatrix::gaussian_aperture(*radius, wavelength, n)
                        .try_transform_q(q)?;

                    // Integrating exp(-2r^2/w^2) * exp(-2r^2/wa^2) against the
                    // unapertured profile gives a transmitted fraction wa^2 / (w^2 + wa^2).
                    let wa_sq = radius * radius;
                    if w_sq > 0.0 && wa_sq > 0.0 {
                        power *= wa_sq / (w_sq + wa_sq);
                    }
                }
                OpticalElement::HardAperture { radius } => {
                    // Only the power is clipped; q is left alone, so diffraction from the
                    // hard edge is ignored.
                    let w_sq = beam_radius_sq(q, wavelength, n).ok_or("Singular q at aperture")?;
                    if w_sq > 0.0 {
                        let transmitted = 1.0 - (-2.0 * radius * radius / w_sq).exp();
                        power *= transmitted.clamp(0.0, 1.0);
                    }
                }
            }
        }

        let dz = z - current_z;
        if dz > 0.0 {
            q = q + dz;
        }

        GaussianBeam::from_q_at(q, z, wavelength, n, power)
            .ok_or_else(|| format!("Non-physical beam at z={}: Im(q) <= 0", z))
    }
}

/// `w^2` from `Im(1/q) = -lambda / (pi*n*w^2)`. `None` if `q` is not invertible.
fn beam_radius_sq(q: Complex, wavelength: f64, n: f64) -> Option<f64> {
    let inv_q = q.inv()?;
    Some(-wavelength / (PI * n * inv_q.im))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_train_leaves_beam_unchanged() {
        let train = OpticalTrain::new();
        let beam = GaussianBeam::default();

        let propagated = train.beam_at(&beam, 0.5).unwrap();
        assert_eq!(propagated, beam);
    }

    #[test]
    fn thin_lens_matches_self_focusing_formula() {
        // S. A. Self, "Focusing of spherical Gaussian beams", Appl. Opt. 22 (1983).
        let lambda = 1064.0e-9;
        let w01 = 1.0e-3;
        let f = 0.2;
        let d1 = 0.3;

        let initial_beam = GaussianBeam {
            wavelength: lambda,
            w0: w01,
            z0: 0.0,
            refractive_index: 1.0,
            power: 1.0,
        };

        let mut train = OpticalTrain::new();
        train.add_element(d1, OpticalElement::ThinLens { focal_length: f });

        let z_r1 = PI * w01 * w01 / lambda;
        let d2 = f + (d1 - f) * f * f / ((d1 - f).powi(2) + z_r1.powi(2));
        let expected_waist_z = d1 + d2;
        let expected_w02 = w01 * f / ((d1 - f).powi(2) + z_r1.powi(2)).sqrt();

        assert!((d2 - 0.2004583).abs() < 1e-6);
        assert!((expected_w02 * 1e6 - 67.6975).abs() < 1e-3);

        let beam_after = train.beam_at(&initial_beam, expected_waist_z).unwrap();

        assert!(
            (beam_after.z0 - expected_waist_z).abs() < 1e-9,
            "Waist z was {}, expected {}",
            beam_after.z0,
            expected_waist_z
        );
        assert!(
            (beam_after.w0 - expected_w02).abs() < 1e-9,
            "Waist w0 was {}, expected {}",
            beam_after.w0,
            expected_w02
        );
    }

    #[test]
    fn flat_interface_scales_rayleigh_range() {
        let lambda = 1064.0e-9;
        let w0 = 1.0e-3;
        let initial_beam = GaussianBeam {
            wavelength: lambda,
            w0,
            z0: 0.0,
            refractive_index: 1.0,
            power: 2.0,
        };

        let mut train = OpticalTrain::new();
        train.add_element(
            0.5,
            OpticalElement::DielectricInterface {
                n1: 1.0,
                n2: 1.5,
                radius: None,
            },
        );

        let beam_in_medium2 = train.beam_at(&initial_beam, 0.5).unwrap();
        assert_eq!(beam_in_medium2.refractive_index, 1.5);
        let z_r1 = initial_beam.rayleigh_range();
        let z_r2 = beam_in_medium2.rayleigh_range();
        assert!((z_r2 - 1.5 * z_r1).abs() < 1e-9);
    }

    #[test]
    fn gaussian_aperture_narrows_and_attenuates() {
        let lambda = 532.0e-9;
        let w1 = 1.0e-3;
        let wa = 0.8e-3;
        let initial_beam = GaussianBeam {
            wavelength: lambda,
            w0: w1,
            z0: 0.0,
            refractive_index: 1.0,
            power: 10.0,
        };

        let mut train = OpticalTrain::new();
        train.add_element(0.0, OpticalElement::GaussianAperture { radius: wa });

        let beam_after = train.beam_at(&initial_beam, 0.0).unwrap();
        let expected_w = (1.0 / (w1 * w1) + 1.0 / (wa * wa)).powf(-0.5);
        assert!((beam_after.w0 - expected_w).abs() < 1e-9);

        let expected_power = 10.0 * (wa * wa) / (w1 * w1 + wa * wa);
        assert!((beam_after.power - expected_power).abs() < 1e-9);
    }
}
