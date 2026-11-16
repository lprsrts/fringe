use beam_core::{
    AbcdMatrix, Complex, ComplexAbcdMatrix, GaussianBeam, OpticalElement, OpticalTrain,
};
use std::f64::consts::{FRAC_PI_2, FRAC_PI_4, PI};

#[track_caller]
fn assert_close(actual: f64, expected: f64, rel_tol: f64) {
    let scale = expected.abs().max(f64::MIN_POSITIVE);
    let err = (actual - expected).abs() / scale;
    assert!(
        err <= rel_tol,
        "got {actual:e}, expected {expected:e} (relative error {err:e})"
    );
}

#[track_caller]
fn assert_complex_close(actual: Complex, expected: Complex, tol: f64) {
    let err = (actual - expected).norm();
    assert!(
        err <= tol * expected.norm().max(1.0),
        "got {actual:?}, expected {expected:?}"
    );
}

fn beam(wavelength: f64, w0: f64) -> GaussianBeam {
    GaussianBeam::new(wavelength, w0, 0.0, 1.0, 1.0).unwrap()
}

fn train(elements: impl IntoIterator<Item = (f64, OpticalElement)>) -> OpticalTrain {
    let mut t = OpticalTrain::new();
    for (z, e) in elements {
        t.add_element(z, e);
    }
    t
}

fn lens(focal_length: f64) -> OpticalElement {
    OpticalElement::ThinLens { focal_length }
}

fn interface(n1: f64, n2: f64, radius: Option<f64>) -> OpticalElement {
    OpticalElement::DielectricInterface { n1, n2, radius }
}

/// Midpoint-rule integral of `2*pi*r*I(r, z)` out to six beam radii.
fn transverse_power(beam: &GaussianBeam, z: f64) -> f64 {
    let r_max = 6.0 * beam.waist_at(z);
    let steps = 4000;
    let dr = r_max / steps as f64;
    (0..steps)
        .map(|i| {
            let r = (i as f64 + 0.5) * dr;
            2.0 * PI * r * beam.intensity_at(r, z) * dr
        })
        .sum()
}

#[test]
fn he_ne_reference_values() {
    let b = beam(632.8e-9, 0.5e-3);
    let z_r = b.rayleigh_range();

    assert_close(z_r, 1.241_147_5, 1e-7);
    assert_close(b.waist_at(z_r), 7.071_067_8e-4, 1e-8);
    assert_close(b.radius_of_curvature(z_r).unwrap(), 2.482_295_1, 1e-7);
    assert_close(b.gouy_phase(z_r), FRAC_PI_4, 1e-12);
    assert_close(b.divergence_half_angle(), 632.8e-9 / (PI * 0.5e-3), 1e-12);
    assert_close(b.wavenumber(), 2.0 * PI / 632.8e-9, 1e-12);
    assert!(b.is_paraxial_valid());
}

#[test]
fn default_beam_is_the_he_ne_reference() {
    assert_eq!(GaussianBeam::default(), beam(632.8e-9, 0.5e-3));
}

#[test]
fn waist_grows_by_sqrt2_at_rayleigh_range() {
    let z0 = 0.25;
    let b = GaussianBeam::new(632.8e-9, 0.5e-3, z0, 1.0, 1.0).unwrap();
    let z_r = b.rayleigh_range();

    assert_eq!(b.waist_at(z0), b.w0);
    assert_close(b.waist_at(z0 + z_r), 2f64.sqrt() * b.w0, 1e-12);
    assert_close(b.waist_at(z0 - z_r), 2f64.sqrt() * b.w0, 1e-12);
    assert_close(b.waist_at(z0 + 2.0 * z_r), 5f64.sqrt() * b.w0, 1e-12);
}

#[test]
fn beam_is_symmetric_about_the_waist() {
    let z0 = 2.7;
    let b = GaussianBeam::new(632.8e-9, 0.4e-3, z0, 1.0, 2.5).unwrap();
    for dz in [1e-6, 0.1, 0.75, 10.0] {
        assert_close(b.waist_at(z0 + dz), b.waist_at(z0 - dz), 1e-12);
        assert!((b.curvature_at(z0 + dz) + b.curvature_at(z0 - dz)).abs() < 1e-12);
        assert!((b.gouy_phase(z0 + dz) + b.gouy_phase(z0 - dz)).abs() < 1e-12);
    }
}

#[test]
fn far_field_approaches_the_asymptotic_cone() {
    let b = GaussianBeam::default();
    let z = 1e6 * b.rayleigh_range();

    assert_close(b.waist_at(z), b.divergence_half_angle() * z, 1e-10);
    assert_close(b.curvature_at(z), 1.0 / z, 1e-10);
    assert!((b.gouy_phase(z) - FRAC_PI_2).abs() < 1e-5);
}

#[test]
fn rayleigh_range_scales_with_waist_wavelength_and_index() {
    let (lambda, w0) = (532e-9, 0.4e-3);
    let base = beam(lambda, w0).rayleigh_range();

    assert_close(base, PI * w0 * w0 / lambda, 1e-12);
    assert_close(beam(lambda, 2.0 * w0).rayleigh_range(), 4.0 * base, 1e-12);
    assert_close(beam(lambda / 2.0, w0).rayleigh_range(), 2.0 * base, 1e-12);

    let n = 1.5168;
    let in_glass = GaussianBeam::new(lambda, w0, 0.0, n, 1.0).unwrap();
    assert_close(in_glass.rayleigh_range(), n * base, 1e-12);
    assert_close(in_glass.wavenumber(), n * 2.0 * PI / lambda, 1e-12);
}

#[test]
fn wavefront_is_flat_at_the_waist() {
    let b = GaussianBeam::new(632.8e-9, 0.5e-3, 0.3, 1.0, 1.0).unwrap();
    assert_eq!(b.curvature_at(0.3), 0.0);
    assert!(b.radius_of_curvature(0.3).is_none());
    assert_eq!(b.gouy_phase(0.3), 0.0);
}

#[test]
fn curvature_peaks_at_rayleigh_range() {
    let b = GaussianBeam::default();
    let z_r = b.rayleigh_range();
    let peak = b.curvature_at(z_r);

    assert_close(peak, 1.0 / (2.0 * z_r), 1e-12);
    assert!(b.curvature_at(0.9 * z_r) < peak);
    assert!(b.curvature_at(1.1 * z_r) < peak);
    assert_close(b.curvature_at(-z_r), -peak, 1e-12);
}

#[test]
fn radius_of_curvature_is_reciprocal_of_curvature() {
    let b = GaussianBeam::new(1064e-9, 0.6e-3, -0.2, 1.0, 1.0).unwrap();
    for z in [-3.0, -0.5, 0.1, 0.8, 50.0] {
        let r = b.radius_of_curvature(z).unwrap();
        assert_close(1.0 / r, b.curvature_at(z), 1e-12);
    }
}

#[test]
fn curvature_at_infinity_is_zero() {
    let b = GaussianBeam::default();
    assert_eq!(b.curvature_at(f64::INFINITY), 0.0);
    assert_eq!(b.curvature_at(f64::NEG_INFINITY), 0.0);
}

#[test]
fn gouy_phase_spans_pi_and_increases_monotonically() {
    let b = GaussianBeam::default();
    let z_r = b.rayleigh_range();

    assert_close(b.gouy_phase(-z_r), -FRAC_PI_4, 1e-12);
    assert!((b.gouy_phase(1e9 * z_r) - FRAC_PI_2).abs() < 1e-8);
    assert!((b.gouy_phase(-1e9 * z_r) + FRAC_PI_2).abs() < 1e-8);

    let samples: Vec<f64> = (-40..=40)
        .map(|i| b.gouy_phase(i as f64 * 0.1 * z_r))
        .collect();
    assert!(samples.windows(2).all(|w| w[1] > w[0]));
}

#[test]
fn inverse_q_holds_curvature_and_spot_size() {
    // 1/q = 1/R - i*lambda / (pi*n*w^2)
    let b = GaussianBeam::new(1064e-9, 0.6e-3, 0.1, 1.3, 5.0).unwrap();
    let z_r = b.rayleigh_range();
    for z in [0.0, 0.1, 0.1 + z_r, 0.1 - 2.0 * z_r, 1.5] {
        let q = b.q_at(z);
        assert_eq!(q, Complex::new(z - b.z0, z_r));

        let inv = q.inv().unwrap();
        let w = b.waist_at(z);
        assert!((inv.re - b.curvature_at(z)).abs() < 1e-10);
        assert_close(
            inv.im,
            -b.wavelength / (PI * b.refractive_index * w * w),
            1e-12,
        );
    }
}

#[test]
fn from_q_at_round_trips() {
    let original = GaussianBeam::new(532e-9, 0.2e-3, 0.15, 1.45, 2.5).unwrap();
    for z in [-1.0, 0.15, 0.45, 20.0] {
        let q = original.q_at(z);
        let back = GaussianBeam::from_q_at(q, z, 532e-9, 1.45, 2.5).unwrap();
        assert_close(back.w0, original.w0, 1e-12);
        assert!((back.z0 - original.z0).abs() < 1e-12);
        assert_eq!(back.wavelength, original.wavelength);
        assert_eq!(back.refractive_index, original.refractive_index);
        assert_eq!(back.power, original.power);
    }
}

#[test]
fn from_q_at_rejects_unphysical_input() {
    let (lambda, n, p) = (632.8e-9, 1.0, 1.0);
    let q = Complex::new(0.0, 1.24);
    let nan = f64::NAN;
    let inf = f64::INFINITY;

    for bad_q in [
        Complex::new(nan, 1.0),
        Complex::new(0.0, nan),
        Complex::new(inf, 1.0),
        Complex::new(0.0, inf),
        Complex::new(0.0, 0.0),
        Complex::new(0.0, -1.0),
    ] {
        assert!(
            GaussianBeam::from_q_at(bad_q, 0.0, lambda, n, p).is_none(),
            "{bad_q:?}"
        );
    }
    assert!(GaussianBeam::from_q_at(q, nan, lambda, n, p).is_none());
    assert!(GaussianBeam::from_q_at(q, inf, lambda, n, p).is_none());
    assert!(GaussianBeam::from_q_at(q, 0.0, nan, n, p).is_none());
    assert!(GaussianBeam::from_q_at(q, 0.0, 0.0, n, p).is_none());
    assert!(GaussianBeam::from_q_at(q, 0.0, lambda, nan, p).is_none());
    assert!(GaussianBeam::from_q_at(q, 0.0, lambda, 0.5, p).is_none());
    assert!(GaussianBeam::from_q_at(q, 0.0, lambda, n, nan).is_none());
    assert!(GaussianBeam::from_q_at(q, 0.0, lambda, n, -1.0).is_none());
}

#[test]
fn new_rejects_invalid_parameters() {
    let ok = [632.8e-9, 0.5e-3, 0.0, 1.0, 1.0];
    let bad: [&[f64]; 5] = [
        &[f64::NAN, f64::INFINITY, 0.0, -1e-6],
        &[f64::NAN, f64::INFINITY, 0.0, -1.0],
        &[f64::NAN, f64::INFINITY, f64::NEG_INFINITY],
        &[f64::NAN, f64::INFINITY, 0.999, 0.5, -1.0],
        &[f64::NAN, f64::INFINITY, -0.1],
    ];
    for (i, values) in bad.iter().enumerate() {
        for &v in *values {
            let mut p = ok;
            p[i] = v;
            assert!(
                GaussianBeam::new(p[0], p[1], p[2], p[3], p[4]).is_err(),
                "parameter {i} = {v} was accepted"
            );
        }
    }
    assert!(GaussianBeam::new(ok[0], ok[1], ok[2], ok[3], 0.0).is_ok());
    assert!(GaussianBeam::new(ok[0], ok[1], -5.0, ok[3], ok[4]).is_ok());
}

#[test]
fn tight_focus_is_flagged_non_paraxial() {
    let b = beam(500e-9, 100e-9);
    assert!(b.divergence_half_angle() > 0.5);
    assert!(!b.is_paraxial_valid());
    assert!(!beam(1064e-9, 0.2e-6).is_paraxial_valid());
}

#[test]
fn picometre_waist_stays_finite() {
    let b = beam(632.8e-9, 1e-12);
    let z_r = b.rayleigh_range();
    assert!(z_r.is_finite() && z_r > 0.0);
    assert!(!b.is_paraxial_valid());
    for z in [0.0, 1e-9, 1.0, 1e3] {
        assert!(b.waist_at(z).is_finite());
        assert!(b.curvature_at(z).is_finite());
        assert!(b.gouy_phase(z).is_finite());
    }
}

#[test]
fn wide_waists_stay_collimated() {
    let metre = beam(532e-9, 1.0);
    assert!(metre.rayleigh_range() > 5.9e6);
    assert!(metre.waist_at(1000.0) - 1.0 < 1e-6);
    assert!(metre.curvature_at(1000.0).abs() < 1e-10);
    assert!(metre.divergence_half_angle() < 2e-7);

    let kilometre = beam(632.8e-9, 1000.0);
    assert!(kilometre.rayleigh_range() > 1e12);
    assert!((kilometre.waist_at(10_000.0) - 1000.0).abs() < 1e-3);
    assert!(kilometre.is_paraxial_valid());
}

#[test]
fn extreme_wavelengths_give_finite_results() {
    for lambda in [1e-9, 100e-9, 100e-6, 1.0] {
        let b = beam(lambda, 0.5e-3);
        assert_close(b.wavenumber(), 2.0 * PI / lambda, 1e-12);
        assert_close(b.rayleigh_range(), PI * 0.25e-6 / lambda, 1e-12);
        assert!(b.waist_at(10.0).is_finite());
    }
}

#[test]
fn peak_intensity_matches_closed_form() {
    let b = GaussianBeam::new(632.8e-9, 0.4e-3, 0.0, 1.0, 2.5).unwrap();
    let i0 = 2.0 * 2.5 / (PI * 0.4e-3 * 0.4e-3);
    assert_close(b.peak_intensity(), i0, 1e-12);
    assert_close(b.intensity_at(0.0, 0.0), i0, 1e-12);

    let z_r = b.rayleigh_range();
    assert_close(b.intensity_at(0.0, z_r), i0 / 2.0, 1e-12);
    assert_close(b.intensity_at(0.0, -2.0 * z_r), i0 / 5.0, 1e-12);
}

#[test]
fn intensity_falls_to_one_over_e_squared_at_beam_radius() {
    let b = GaussianBeam::default();
    for z in [0.0, 0.5, b.rayleigh_range(), -3.0] {
        let w = b.waist_at(z);
        let on_axis = b.intensity_at(0.0, z);
        assert_close(b.intensity_at(w, z), on_axis * (-2f64).exp(), 1e-12);
        assert_close(
            b.intensity_at(w / 2f64.sqrt(), z),
            on_axis * (-1f64).exp(),
            1e-12,
        );
        assert_close(b.intensity_at(2.0 * w, z), on_axis * (-8f64).exp(), 1e-12);
    }
}

#[test]
fn power_is_conserved_across_transverse_planes() {
    let b = GaussianBeam::new(532e-9, 0.6e-3, 0.0, 1.0, PI).unwrap();
    let z_r = b.rayleigh_range();
    for z in [0.0, z_r, -3.0 * z_r, 5.0 * z_r] {
        assert_close(transverse_power(&b, z), PI, 1e-6);
    }
}

#[test]
fn zero_power_beam_is_dark() {
    let b = GaussianBeam::new(632.8e-9, 0.5e-3, 0.0, 1.0, 0.0).unwrap();
    assert_eq!(b.peak_intensity(), 0.0);
    assert_eq!(b.intensity_at(0.0, 0.3), 0.0);
}

#[test]
fn field_amplitude_squares_to_intensity() {
    let b = GaussianBeam::default();
    for (r, z) in [(0.0, 0.0), (0.3e-3, 0.5), (1e-3, -2.0)] {
        let field = b.complex_field_at(r, z);
        assert_close(field.norm_sq(), b.intensity_at(r, z), 1e-10);
        let (amp, phase) = b.electric_field_at(r, z);
        assert_complex_close(field, Complex::new(phase.cos(), phase.sin()) * amp, 1e-12);
    }
}

#[test]
fn phase_is_independent_of_radius_at_the_waist() {
    let b = GaussianBeam::default();
    for r in [0.0, 1e-4, 1e-3, 1e-2] {
        assert_eq!(b.electric_field_at(r, 0.0).1, 0.0);
    }
}

#[test]
fn radial_phase_changes_sign_across_the_waist() {
    let b = GaussianBeam::default();
    let z_r = b.rayleigh_range();
    let r = 0.5 * b.w0;
    let radial_phase = |z: f64| b.electric_field_at(r, z).1 - b.electric_field_at(0.0, z).1;

    let after = radial_phase(z_r);
    let before = radial_phase(-z_r);
    assert!(after > 0.0, "diverging wavefront should lag off axis");
    assert!(before < 0.0);
    assert!((after + before).abs() < 1e-12);
    assert_close(after, 0.5 * b.wavenumber() * r * r / (2.0 * z_r), 1e-9);
}

#[test]
fn phase_is_continuous_through_the_waist() {
    let b = GaussianBeam::default();
    let k = b.wavenumber();
    for eps in [1e-3, 1e-6, 1e-9] {
        let at = |z: f64| b.electric_field_at(1e-4, z).1;
        assert!((at(eps) - at(0.0)).abs() < 2.0 * k * eps);
        assert!((at(-eps) - at(0.0)).abs() < 2.0 * k * eps);
    }
}

#[test]
fn complex_arithmetic() {
    let a = Complex::new(3.0, 4.0);
    let b = Complex::new(1.0, -2.0);

    assert_eq!(a + b, Complex::new(4.0, 2.0));
    assert_eq!(a - b, Complex::new(2.0, 6.0));
    assert_eq!(a * b, Complex::new(11.0, -2.0));
    assert_eq!(-a, Complex::new(-3.0, -4.0));
    assert_eq!(a.conj(), Complex::new(3.0, -4.0));
    assert_eq!(a.norm_sq(), 25.0);
    assert_eq!(a.norm(), 5.0);

    let mut c = a;
    c += b;
    c -= b;
    c *= Complex::I;
    assert_eq!(c, Complex::new(-4.0, 3.0));
}

#[test]
fn complex_scalar_operations() {
    let a = Complex::new(2.0, 3.0);
    assert_eq!(a + 5.0, Complex::new(7.0, 3.0));
    assert_eq!(a - 1.0, Complex::new(1.0, 3.0));
    assert_eq!(a * 2.0, Complex::new(4.0, 6.0));
    assert_eq!(3.0 * a, Complex::new(6.0, 9.0));
    assert_eq!(a / 2.0, Complex::new(1.0, 1.5));
    assert_eq!(Complex::from_real(2.0), Complex::new(2.0, 0.0));
    assert_eq!(Complex::from_imag(2.0), Complex::new(0.0, 2.0));
}

#[test]
fn complex_arg_and_exp() {
    assert_close(Complex::new(-1.0, 0.0).arg(), PI, 1e-15);
    assert_close(Complex::new(0.0, -1.0).arg(), -FRAC_PI_2, 1e-15);
    assert_complex_close(Complex::new(0.0, PI).exp(), Complex::new(-1.0, 0.0), 1e-15);
    assert_complex_close(
        Complex::new(1.0, FRAC_PI_2).exp(),
        Complex::new(0.0, std::f64::consts::E),
        1e-15,
    );
}

#[test]
fn complex_inverse_and_division() {
    let a = Complex::new(3.0, 4.0);
    let b = Complex::new(1.0, 2.0);

    assert_complex_close(a * a.inv().unwrap(), Complex::ONE, 1e-15);
    assert_complex_close(a.div(b).unwrap(), a * b.inv().unwrap(), 1e-15);
    assert_complex_close(a / b, Complex::new(2.2, -0.4), 1e-15);
}

#[test]
fn complex_division_by_zero_is_none() {
    let a = Complex::new(1.0, 2.0);
    for z in [Complex::ZERO, Complex::new(1e-16, 1e-16)] {
        assert!(z.inv().is_none());
        assert!(a.div(z).is_none());
        let q = a / z;
        assert!(q.re.is_nan() && q.im.is_nan());
    }
    assert!(Complex::new(f64::NAN, 0.0).inv().is_none());
}

#[test]
fn complex_division_overflow_is_none_not_nan() {
    // The cross terms overflow to inf - inf.
    let a = Complex::new(1e200, 1e200);
    let b = Complex::new(1e200, -1e200);
    assert!(a.div(b).is_none());
}

#[test]
fn complex_infinity_inverts_to_zero() {
    let finite = Complex::new(3.0, 4.0);
    for inf in [
        Complex::new(f64::INFINITY, 0.0),
        Complex::new(0.0, f64::INFINITY),
        Complex::new(f64::INFINITY, f64::INFINITY),
    ] {
        assert_eq!(inf.inv(), Some(Complex::ZERO));
        assert_eq!(finite.div(inf), Some(Complex::ZERO));
        assert_eq!(finite / inf, Complex::ZERO);
        assert_eq!(inf.div(inf), None);
    }
}

#[test]
fn matrix_product_follows_element_order() {
    let drift = AbcdMatrix::free_space(1.5);
    let thin = AbcdMatrix::thin_lens(0.1);

    assert_eq!(AbcdMatrix::IDENTITY * drift, drift);
    assert_eq!(drift * AbcdMatrix::IDENTITY, drift);

    // Lens first, then drift: [[1, d], [0, 1]] * [[1, 0], [-1/f, 1]].
    let system = drift * thin;
    assert_close(system.a, 1.0 - 15.0, 1e-12);
    assert_close(system.b, 1.5, 1e-12);
    assert_close(system.c, -10.0, 1e-12);
    assert_close(system.d, 1.0, 1e-12);

    assert_eq!(drift.mul(&thin), system);
    assert_ne!(thin * drift, system);
}

#[test]
fn free_space_composes_additively() {
    let total = AbcdMatrix::free_space(0.65) * AbcdMatrix::free_space(0.35);
    assert_eq!(total, AbcdMatrix::free_space(1.0));

    let q = Complex::new(0.1, 1.5);
    assert_complex_close(AbcdMatrix::free_space(0.35).transform_q(q), q + 0.35, 1e-15);
}

#[test]
fn system_matrix_matches_sequential_q_transforms() {
    let elements = [
        AbcdMatrix::free_space(0.2),
        AbcdMatrix::thin_lens(0.15),
        AbcdMatrix::free_space(0.4),
        AbcdMatrix::curved_mirror(-0.8),
        AbcdMatrix::free_space(0.1),
    ];
    let q0 = Complex::new(-0.05, 0.3);

    let mut q = q0;
    let mut system = AbcdMatrix::IDENTITY;
    for m in &elements {
        q = m.transform_q(q);
        system = m * system;
    }
    assert_complex_close(system.transform_q(q0), q, 1e-12);
}

#[test]
fn determinants() {
    for m in [
        AbcdMatrix::free_space(0.5),
        AbcdMatrix::thin_lens(0.1),
        AbcdMatrix::thin_lens(-0.02),
        AbcdMatrix::curved_mirror(0.3),
        AbcdMatrix::flat_mirror(),
    ] {
        assert_close(m.det(), 1.0, 1e-15);
    }
    assert_close(
        AbcdMatrix::dielectric_interface(1.0, 1.5, None).det(),
        1.0 / 1.5,
        1e-15,
    );
    assert_close(
        AbcdMatrix::dielectric_interface(1.0, 1.5, Some(0.05)).det(),
        1.0 / 1.5,
        1e-15,
    );
}

#[test]
fn many_element_cascade_keeps_unit_determinant() {
    let mut system = AbcdMatrix::IDENTITY;
    for i in 0..200 {
        let f = if i % 2 == 0 { 0.08 } else { -0.06 };
        system = AbcdMatrix::free_space(0.1) * AbcdMatrix::thin_lens(f) * system;
    }
    assert!((system.det() - 1.0).abs() < 1e-6, "det = {}", system.det());
}

#[test]
fn flat_mirror_is_identity() {
    assert_eq!(AbcdMatrix::flat_mirror(), AbcdMatrix::IDENTITY);
}

#[test]
fn curved_mirror_acts_like_lens_of_half_radius() {
    let r = 0.5;
    assert_close(
        AbcdMatrix::curved_mirror(r).c,
        AbcdMatrix::thin_lens(r / 2.0).c,
        1e-15,
    );

    let b = GaussianBeam::default();
    let via_mirror = train([(0.3, OpticalElement::CurvedMirror { radius: r })])
        .beam_at(&b, 0.6)
        .unwrap();
    let via_lens = train([(0.3, lens(r / 2.0))]).beam_at(&b, 0.6).unwrap();
    assert_close(via_mirror.w0, via_lens.w0, 1e-12);
    assert_close(via_mirror.z0, via_lens.z0, 1e-12);
}

#[test]
fn infinite_focal_length_is_identity() {
    for f in [f64::INFINITY, f64::NEG_INFINITY] {
        let m = AbcdMatrix::thin_lens(f);
        assert_eq!(m.c, 0.0);
        assert_eq!(m.det(), 1.0);
    }
    assert!(AbcdMatrix::thin_lens(1e15).c.abs() < 1e-14);

    let b = GaussianBeam::default();
    for f in [f64::INFINITY, 1e15] {
        let out = train([(0.2, lens(f))]).beam_at(&b, 0.5).unwrap();
        assert_close(out.w0, b.w0, 1e-9);
        assert!((out.z0 - b.z0).abs() < 1e-9);
    }
}

#[test]
fn flat_interface_scales_q_by_index_ratio() {
    let q = Complex::new(0.3, 1.2);
    let q2 = AbcdMatrix::dielectric_interface(1.0, 1.5, None).transform_q(q);
    assert_complex_close(q2, q * 1.5, 1e-15);

    // A near-zero radius is treated as flat rather than dividing by it.
    assert_eq!(
        AbcdMatrix::dielectric_interface(1.0, 1.5, Some(1e-16)),
        AbcdMatrix::dielectric_interface(1.0, 1.5, None)
    );
}

#[test]
fn matched_index_interface_is_identity() {
    let n = 1.52;
    assert_eq!(
        AbcdMatrix::dielectric_interface(n, n, None),
        AbcdMatrix::IDENTITY
    );
    assert_eq!(
        AbcdMatrix::dielectric_interface(n, n, Some(0.05)),
        AbcdMatrix::IDENTITY
    );

    let b = GaussianBeam::new(632.8e-9, 0.5e-3, 0.0, n, 1.0).unwrap();
    let out = train([(0.1, interface(n, n, Some(0.02)))])
        .beam_at(&b, 0.5)
        .unwrap();
    assert_eq!(out.refractive_index, n);
    assert_close(out.w0, b.w0, 1e-12);
    assert!((out.z0 - b.z0).abs() < 1e-12);
}

#[test]
fn two_curved_surfaces_make_a_thin_lens() {
    // Lensmaker: 1/f = (n - 1)(1/R1 - 1/R2) = 0.5 * (10 + 10), so f = 0.1.
    let b = GaussianBeam::default();
    let biconvex = train([
        (0.3, interface(1.0, 1.5, Some(0.1))),
        (0.3, interface(1.5, 1.0, Some(-0.1))),
    ]);
    let thin = train([(0.3, lens(0.1))]);
    for z in [0.3, 0.4, 1.0] {
        let a = biconvex.beam_at(&b, z).unwrap();
        let t = thin.beam_at(&b, z).unwrap();
        assert_eq!(a.refractive_index, 1.0);
        assert_close(a.w0, t.w0, 1e-9);
        assert_close(a.z0, t.z0, 1e-9);
    }
}

#[test]
fn gaussian_aperture_matrix_has_imaginary_c() {
    let (wa, lambda, n) = (0.3e-3, 632.8e-9, 1.2);
    let m: ComplexAbcdMatrix = AbcdMatrix::gaussian_aperture(wa, lambda, n);
    assert_eq!(m, ComplexAbcdMatrix::gaussian_aperture(wa, lambda, n));
    assert_eq!(m.a, Complex::ONE);
    assert_eq!(m.b, Complex::ZERO);
    assert_eq!(m.d, Complex::ONE);
    assert_eq!(m.c.re, 0.0);
    assert_close(m.c.im, -lambda / (PI * n * wa * wa), 1e-15);
}

#[test]
fn gaussian_aperture_narrows_beam() {
    // 1/w2^2 = 1/w1^2 + 1/wa^2
    let lambda = 500e-9;
    let w1 = 1e-3;
    for wa in [0.8e-3, 0.25e-3, 2e-6] {
        let q1 = Complex::new(0.0, PI * w1 * w1 / lambda);
        let q2 = AbcdMatrix::gaussian_aperture(wa, lambda, 1.0).transform_q(q1);
        let w2 = (-lambda / (PI * q2.inv().unwrap().im)).sqrt();
        assert_close(w2, (1.0 / (w1 * w1) + 1.0 / (wa * wa)).powf(-0.5), 1e-10);
        assert!(w2 < wa);
    }
}

#[test]
fn complex_and_real_matrices_compose() {
    let drift = AbcdMatrix::free_space(0.5);
    let ap = ComplexAbcdMatrix::gaussian_aperture(0.5e-3, 632.8e-9, 1.0);
    let q = Complex::new(0.0, 1.2);

    let expected = drift.to_complex().transform_q(ap.transform_q(q));
    assert_complex_close((drift * ap).transform_q(q), expected, 1e-12);
    assert_complex_close((drift.to_complex() * ap).transform_q(q), expected, 1e-12);
    assert_eq!(ComplexAbcdMatrix::from(drift), drift.to_complex());

    let expected = ap.transform_q(drift.transform_q(q));
    assert_complex_close((ap * drift).transform_q(q), expected, 1e-12);
    assert_complex_close(
        drift.to_complex().transform_q(q),
        drift.transform_q(q),
        1e-15,
    );
    assert_eq!(ComplexAbcdMatrix::IDENTITY * ap, ap);
}

#[test]
fn singular_transform_is_an_error() {
    let singular = AbcdMatrix::new(1.0, 0.0, 1.0, 0.0);
    let q = Complex::ZERO;

    assert!(singular.try_transform_q(q).is_err());
    let nan = singular.transform_q(q);
    assert!(nan.re.is_nan() && nan.im.is_nan());

    let singular = singular.to_complex();
    assert!(singular.try_transform_q(q).is_err());
    let nan = singular.transform_q(q);
    assert!(nan.re.is_nan() && nan.im.is_nan());
}

#[test]
fn refraction_transform_works_on_reduced_q() {
    // With reduced parameters a flat interface is the identity and the index
    // change is carried by q/n alone.
    let q = Complex::new(0.2, 0.9);
    let out = AbcdMatrix::IDENTITY.transform_q_refraction(q, 1.0, 1.5);
    assert_complex_close(out, q * 1.5, 1e-15);

    // A drift of physical length d in index n has reduced matrix [[1, d/n], [0, 1]].
    let (n, d) = (1.5, 0.3);
    let out = AbcdMatrix::free_space(d / n).transform_q_refraction(q, n, n);
    assert_complex_close(out, q + d, 1e-15);

    let out = ComplexAbcdMatrix::IDENTITY.transform_q_refraction(q, 1.0, 1.5);
    assert_complex_close(out, q * 1.5, 1e-15);
}

#[test]
fn refraction_transform_rejects_bad_indices() {
    let q = Complex::new(0.0, 1.0);
    for (n1, n2) in [
        (0.0, 1.0),
        (1.0, -1.0),
        (f64::NAN, 1.0),
        (1.0, f64::INFINITY),
    ] {
        assert!(AbcdMatrix::IDENTITY
            .try_transform_q_refraction(q, n1, n2)
            .is_err());
        assert!(ComplexAbcdMatrix::IDENTITY
            .try_transform_q_refraction(q, n1, n2)
            .is_err());
        assert!(AbcdMatrix::IDENTITY
            .transform_q_refraction(q, n1, n2)
            .re
            .is_nan());
        assert!(ComplexAbcdMatrix::IDENTITY
            .transform_q_refraction(q, n1, n2)
            .re
            .is_nan());
    }
}

#[test]
fn add_element_keeps_train_sorted() {
    let mut t = OpticalTrain::new();
    t.add_element(1.0, lens(0.1));
    t.add_element(0.5, lens(0.2));
    t.add_element(0.5, OpticalElement::FlatMirror);
    t.add_element(-0.2, lens(0.3));

    let zs: Vec<f64> = t.elements().iter().map(|e| e.z).collect();
    assert_eq!(zs, [-0.2, 0.5, 0.5, 1.0]);
    // Ties keep insertion order.
    assert_eq!(t.elements()[1].element, lens(0.2));
    assert_eq!(t.elements()[2].element, OpticalElement::FlatMirror);

    assert_eq!(t.elements_up_to(-1.0).len(), 0);
    assert_eq!(t.elements_up_to(0.5).len(), 3);
    assert_eq!(t.elements_up_to(10.0).len(), 4);
}

#[test]
fn sort_restores_order_after_direct_edits() {
    let mut t = train([(0.5, lens(0.1)), (1.0, lens(-0.05))]);
    t.elements[1].z = 0.2;
    t.sort();
    assert_eq!(t.elements()[0].z, 0.2);
    assert_eq!(t.elements()[0].element, lens(-0.05));
}

#[test]
fn empty_train_returns_input_beam() {
    let b = GaussianBeam::new(532e-9, 0.3e-3, 0.4, 1.2, 3.0).unwrap();
    let t = OpticalTrain::new();
    for z in [-5.0, 0.0, 0.4, 10.0] {
        assert_eq!(t.beam_at(&b, z).unwrap(), b);
    }
}

#[test]
fn beam_before_first_element_is_untouched() {
    let b = GaussianBeam::default();
    let t = train([
        (0.5, lens(0.1)),
        (0.8, OpticalElement::GaussianAperture { radius: 1e-4 }),
    ]);
    assert_eq!(t.beam_at(&b, 0.499).unwrap(), b);
}

#[test]
fn beam_at_rejects_non_finite_z() {
    let t = train([(0.5, lens(0.1))]);
    for z in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
        assert!(t.beam_at(&GaussianBeam::default(), z).is_err());
    }
}

#[test]
fn thin_lens_matches_self_focusing_formula() {
    // S. A. Self, Appl. Opt. 22, 658 (1983). Includes a waist behind the
    // lens (d1 < 0) and a diverging lens with a virtual output waist.
    let (lambda, w01) = (1064e-9, 1e-3);
    let b = beam(lambda, w01);
    let z_r = b.rayleigh_range();

    for (d1, f) in [
        (0.3, 0.2),
        (0.2, 0.2),
        (0.05, 0.2),
        (1.5, 0.2),
        (-0.3, 0.2),
        (0.2, -0.1),
    ] {
        let denom = (d1 - f) * (d1 - f) + z_r * z_r;
        let d2 = f + (d1 - f) * f * f / denom;
        let w02 = w01 * f.abs() / denom.sqrt();

        let out = train([(d1, lens(f))]).beam_at(&b, d1 + 0.5).unwrap();
        assert!(
            (out.z0 - (d1 + d2)).abs() < 1e-9,
            "d1={d1} f={f}: z0={}",
            out.z0
        );
        assert_close(out.w0, w02, 1e-9);
    }
}

#[test]
fn self_formula_reference_vector() {
    let b = beam(1064e-9, 1e-3);
    let out = train([(0.3, lens(0.2))]).beam_at(&b, 0.5).unwrap();
    assert!((out.z0 - 0.3 - 0.200_458_3).abs() < 1e-6);
    assert!((out.w0 * 1e6 - 67.6975).abs() < 1e-3);
}

#[test]
fn waist_at_front_focal_plane_images_to_back_focal_plane() {
    let (lambda, w01) = (632.8e-9, 0.5e-3);
    let b = beam(lambda, w01);
    for f in [0.1, 0.25, 10e-6] {
        let out = train([(f, lens(f))]).beam_at(&b, 2.0 * f).unwrap();
        assert!((out.z0 - 2.0 * f).abs() < 1e-9);
        assert_close(out.w0, f * lambda / (PI * w01), 1e-9);
    }
    let out = train([(0.1, lens(0.1))]).beam_at(&b, 0.2).unwrap();
    assert!((out.w0 * 1e6 - 40.2853).abs() < 1e-3);
}

#[test]
fn lens_keeps_spot_size_and_adds_curvature() {
    let b = GaussianBeam::default();
    let (z, f) = (0.7, 0.25);
    let out = train([(z, lens(f))]).beam_at(&b, z).unwrap();
    assert_close(out.waist_at(z), b.waist_at(z), 1e-12);
    assert_close(out.curvature_at(z), b.curvature_at(z) - 1.0 / f, 1e-12);
    assert_eq!(out.power, b.power);
}

#[test]
fn keplerian_telescope_magnifies_waist() {
    // Input waist at the front focal plane of L1 lands, magnified by f2/f1,
    // at the back focal plane of L2.
    let (f1, f2) = (0.05, 0.15);
    let b = beam(532e-9, 0.2e-3);
    let t = train([(f1, lens(f1)), (2.0 * f1 + f2, lens(f2))]);
    let out = t.beam_at(&b, 2.0 * (f1 + f2) + 0.1).unwrap();
    assert_close(out.w0, b.w0 * f2 / f1, 1e-9);
    assert!((out.z0 - 2.0 * (f1 + f2)).abs() < 1e-9);
}

#[test]
fn relay_lens_guide_reproduces_beam_after_many_lenses() {
    // Lenses of focal length f spaced 2f: every second lens re-images the waist
    // unchanged, 2f further on.
    let f = 0.1;
    let b = beam(532e-9, 0.3e-3);
    let t = train((0..50).map(|k| (f + 2.0 * f * k as f64, lens(f))));
    assert_eq!(t.elements().len(), 50);

    let out = t.beam_at(&b, 100.0 * f + 0.05).unwrap();
    assert_close(out.w0, b.w0, 1e-9);
    assert!((out.z0 - 100.0 * f).abs() < 1e-9);

    let mid = t.beam_at(&b, 2.0 * f + 0.01).unwrap();
    assert_close(mid.w0, f * 532e-9 / (PI * b.w0), 1e-9);
}

#[test]
fn symmetric_cavity_eigenmode_repeats_every_round_trip() {
    // Two mirrors of radius R, L apart, unfolded into a mirror every L. The
    // eigenmode waist sits midway with z_R = sqrt(L(2R - L)) / 2.
    let (r, l, lambda): (f64, f64, f64) = (1.0, 0.5, 1064e-9);
    let z_r = (l * (2.0 * r - l)).sqrt() / 2.0;
    let w0 = (z_r * lambda / PI).sqrt();
    let b = beam(lambda, w0);

    let t = train((0..20).map(|k| {
        (
            l / 2.0 + l * k as f64,
            OpticalElement::CurvedMirror { radius: r },
        )
    }));
    for passes in [1, 7, 20] {
        let z = l * passes as f64;
        let out = t.beam_at(&b, z).unwrap();
        assert_close(out.w0, w0, 1e-9);
        assert!(
            (out.z0 - z).abs() < 1e-9,
            "after {passes} passes z0 = {}",
            out.z0
        );
    }

    // Stability: |(A + D) / 2| <= 1 for the round trip.
    let half = AbcdMatrix::free_space(l) * AbcdMatrix::curved_mirror(r);
    let round_trip = half * half;
    assert!(((round_trip.a + round_trip.d) / 2.0).abs() <= 1.0);
}

#[test]
fn interface_scales_rayleigh_range_and_keeps_spot_size() {
    let b = GaussianBeam::new(1064e-9, 1e-3, 0.0, 1.0, 3.0).unwrap();
    let t = train([(0.4, interface(1.0, 1.5, None))]);

    let at_interface = t.beam_at(&b, 0.4).unwrap();
    assert_eq!(at_interface.refractive_index, 1.5);
    assert_eq!(at_interface.power, 3.0);
    assert_close(
        at_interface.rayleigh_range(),
        1.5 * b.rayleigh_range(),
        1e-12,
    );
    assert_close(at_interface.w0, b.w0, 1e-12);
    assert_close(at_interface.waist_at(0.4), b.waist_at(0.4), 1e-12);
}

#[test]
fn high_index_contrast_interface() {
    let b = GaussianBeam::default();
    let out = train([(0.1, interface(1.0, 1000.0, None))])
        .beam_at(&b, 0.1)
        .unwrap();
    assert_eq!(out.refractive_index, 1000.0);
    assert_close(out.w0, b.w0, 1e-12);
    assert_close(out.rayleigh_range(), 1000.0 * b.rayleigh_range(), 1e-12);
}

#[test]
fn glass_slab_shifts_waist_downstream() {
    // A slab of thickness t and index n moves the apparent waist by t(1 - 1/n).
    let (n, start, thickness) = (1.5, 0.3, 0.2);
    let b = beam(532e-9, 0.5e-3);
    let t = train([
        (0.2, OpticalElement::FlatMirror),
        (start, interface(1.0, n, None)),
        (start + thickness, interface(n, 1.0, None)),
    ]);

    let inside = t.beam_at(&b, start + 0.1).unwrap();
    assert_eq!(inside.refractive_index, n);
    assert_close(inside.w0, b.w0, 1e-12);

    let out = t.beam_at(&b, 0.7).unwrap();
    assert_eq!(out.refractive_index, 1.0);
    assert_eq!(out.power, b.power);
    assert_close(out.w0, b.w0, 1e-12);
    assert!((out.z0 - thickness * (1.0 - 1.0 / n)).abs() < 1e-12);
}

#[test]
fn gaussian_aperture_in_train_narrows_beam_and_drops_power() {
    let b = GaussianBeam::new(532e-9, 1e-3, 0.0, 1.0, 10.0).unwrap();
    for (z, wa) in [(0.0, 0.8e-3), (0.5, 0.8e-3), (2.0, 0.25e-3), (0.0, 2e-6)] {
        let out = train([(z, OpticalElement::GaussianAperture { radius: wa })])
            .beam_at(&b, z)
            .unwrap();
        let w1 = b.waist_at(z);
        let w2 = out.waist_at(z);

        assert_close(1.0 / (w2 * w2), 1.0 / (w1 * w1) + 1.0 / (wa * wa), 1e-9);
        // The C element is purely imaginary, so the wavefront curvature is untouched.
        assert!((out.curvature_at(z) - b.curvature_at(z)).abs() < 1e-9);
        assert_close(out.power, 10.0 * wa * wa / (w1 * w1 + wa * wa), 1e-9);
    }
    let reference = train([(0.0, OpticalElement::GaussianAperture { radius: 0.8e-3 })])
        .beam_at(&beam(532e-9, 1e-3), 0.0)
        .unwrap();
    assert!((reference.w0 * 1e3 - 0.624_695).abs() < 1e-5);
}

#[test]
fn hard_aperture_clips_power_only() {
    let b = GaussianBeam::new(632.8e-9, 0.5e-3, 0.0, 1.0, 2.0).unwrap();
    let z = 0.8;
    let w = b.waist_at(z);
    let clipped = |radius: f64| {
        train([(z, OpticalElement::HardAperture { radius })])
            .beam_at(&b, 1.5)
            .unwrap()
    };

    let out = clipped(w);
    assert_close(out.power, 2.0 * (1.0 - (-2f64).exp()), 1e-12);
    assert_close(out.w0, b.w0, 1e-12);
    assert!((out.z0 - b.z0).abs() < 1e-12);

    assert_close(clipped(100.0 * w).power, 2.0, 1e-12);
    assert!(clipped(1e-3 * w).power < 1e-5);
    assert_eq!(clipped(0.0).power, 0.0);
}

#[test]
fn sharp_focus_propagates_but_degenerate_lens_errors() {
    let b = GaussianBeam::default();
    for f in [1e-6, 1.5e-3] {
        let out = train([(0.1, lens(f))]).beam_at(&b, 0.1 + f).unwrap();
        assert!(out.w0.is_finite() && out.w0 > 0.0);
        assert!(out.divergence_half_angle() > 0.1);
    }
    let diverging = train([(0.1, lens(-0.001))]).beam_at(&b, 0.5).unwrap();
    assert!(diverging.w0 > 0.0 && diverging.z0 < 0.1);

    assert!(train([(0.1, lens(1e-18))]).beam_at(&b, 0.2).is_err());
}

#[test]
fn near_zero_rayleigh_range_errors_instead_of_panicking() {
    // z_R ~ 3e-16 m, so 1/q is effectively real at the lens and C*q + D vanishes.
    let b = GaussianBeam::new(1e-6, 1e-11, 0.0, 1.0, 1.0).unwrap();
    let result = train([(1.0, lens(1.0))]).beam_at(&b, 1.5);
    assert!(result.is_err());
}

#[test]
fn hundred_element_cascade_stays_finite() {
    let b = GaussianBeam::default();
    let mut t = OpticalTrain::new();
    for i in 1..=100 {
        let z = i as f64 * 0.02;
        let element = match i % 5 {
            0 => lens(0.15),
            1 => OpticalElement::CurvedMirror { radius: 0.5 },
            2 => interface(1.0, 1.5, None),
            3 => interface(1.5, 1.0, Some(-0.4)),
            _ => OpticalElement::GaussianAperture { radius: 1.2e-3 },
        };
        t.add_element(z, element);
    }
    assert_eq!(t.elements().len(), 100);

    for z in [0.5, 1.01, 2.05] {
        let out = t.beam_at(&b, z).unwrap();
        assert!(out.w0.is_finite() && out.w0 > 0.0);
        assert!(out.z0.is_finite());
        assert!(out.power > 0.0 && out.power < b.power);
        assert_eq!(out.refractive_index, 1.0);
    }
}

#[test]
fn power_is_conserved_after_lenses() {
    let b = GaussianBeam::new(532e-9, 0.4e-3, 0.0, 1.0, 3.0).unwrap();
    let t = train([(0.15, lens(0.15)), (0.45, lens(0.15)), (0.75, lens(0.15))]);
    for z in [0.0, 0.3, 0.6, 0.9] {
        let out = t.beam_at(&b, z).unwrap();
        assert_eq!(out.power, 3.0);
        assert_close(transverse_power(&out, z), 3.0, 1e-6);
    }
}
