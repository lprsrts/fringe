use std::f64::consts::PI;

use beam_core::analytic::{pec_plane_image, AirySlab, MieCylinder};
use beam_core::geometry::BodyMaterial;
use beam_core::source::Incident;
use beam_core::types::{Rect, Vec2, C64};

const K0: f64 = 2.0 * PI;

fn mie(material: BodyMaterial, r: f64, angle: f64) -> MieCylinder {
    MieCylinder::new(Vec2::new(0.3, -0.2), r, material, 1.0, K0, angle, 1.0, 0.25)
}

#[test]
fn mie_pec_field_vanishes_on_the_surface() {
    for (r, angle) in [(1.0, 0.0), (0.4, 0.7), (2.5, -1.2)] {
        let m = mie(BodyMaterial::Pec, r, angle);
        for k in 0..36 {
            let phi = 2.0 * PI * k as f64 / 36.0;
            let (e, _) = m.series_at(r, phi, false);
            assert!(e.norm() <= 1e-10, "r = {r}, φ = {phi}: |E| = {:.2e}", e.norm());
            // And through the public evaluator just outside.
            let p = m.center + Vec2::from_angle(phi) * r;
            assert!(m.total(p).norm() <= 1e-10);
        }
    }
}

#[test]
fn mie_dielectric_is_continuous() {
    for (n, k, r) in [(1.5, 0.0, 1.0), (1.5, 0.05, 1.0), (3.5, 0.0, 0.5), (2.0, 0.3, 1.7)] {
        let m = mie(BodyMaterial::dielectric(n, k), r, 0.3);
        for s in 0..24 {
            let phi = 2.0 * PI * s as f64 / 24.0;
            let (eo, do_) = m.series_at(r, phi, false);
            let (ei, di) = m.series_at(r, phi, true);
            let scale = eo.norm().max(1.0);
            assert!((eo - ei).norm() <= 1e-9 * scale, "n = {n}: E {eo} vs {ei}");
            assert!((do_ - di).norm() <= 1e-9 * K0 * scale, "n = {n}: dE {do_} vs {di}");
        }
    }
}

#[test]
fn mie_matched_index_does_not_scatter() {
    let m = mie(BodyMaterial::dielectric(1.0, 0.0), 1.0, 0.0);
    for c in &m.c {
        assert!(c.norm() <= 1e-14, "{c}");
    }
    let p = Vec2::new(2.0, 1.0);
    assert!(m.scattered(p).norm() <= 1e-14);
}

#[test]
fn mie_optical_theorem() {
    for material in [BodyMaterial::Pec, BodyMaterial::dielectric(1.5, 0.0), BodyMaterial::dielectric(3.5, 0.0)] {
        for r in [0.2, 1.0, 3.0] {
            let m = mie(material, r, 0.0);
            let (ext, sca) = (m.extinction_width(), m.scattering_width());
            assert!(((ext - sca) / sca).abs() <= 1e-8, "{material:?} r = {r}: {ext} vs {sca}");
        }
    }
    // With loss, extinction exceeds scattering.
    let m = mie(BodyMaterial::dielectric(1.5, 0.05), 1.0, 0.0);
    assert!(m.extinction_width() > m.scattering_width());
}

#[test]
fn mie_echo_width_integrates_to_scattering_width() {
    let m = mie(BodyMaterial::dielectric(1.5, 0.0), 1.0, 0.4);
    let n = 720;
    let integral: f64 = (0..n).map(|k| m.echo_width(2.0 * PI * k as f64 / n as f64)).sum::<f64>() / n as f64;
    assert!((integral / m.scattering_width() - 1.0).abs() < 1e-10);
}

#[test]
fn mie_far_field_is_outgoing() {
    // e^{jωt}: the scattered phase falls with ρ, like e^{−jkρ}.
    let m = mie(BodyMaterial::Pec, 1.0, 0.0);
    let dir = Vec2::from_angle(0.5);
    let a = m.scattered(m.center + dir * 40.0);
    let b = m.scattered(m.center + dir * 40.05);
    let dphase = (b / a).arg();
    assert!((dphase + K0 * 0.05).abs() < 0.01, "{dphase}");
}

#[test]
fn airy_lossless_conserves_energy() {
    let slab = AirySlab { x_front: -1.5, thickness: 3.0, n_slab: C64::new(1.5, 0.0), n_b: 1.0, k0: K0 };
    for k in 0..20 {
        let ky = K0 * 0.99 * k as f64 / 20.0;
        let (r, t) = slab.rt(ky);
        assert!((r.norm_sqr() + t.norm_sqr() - 1.0).abs() <= 1e-12, "k_y = {ky}");
    }
}

#[test]
fn airy_low_index_slab_takes_the_decaying_branch() {
    // Slab index below the background with k_y past the slab's light line: the
    // wave inside is evanescent. A +0.0 imaginary part must not pick the growing
    // root (which overflows to NaN for a thick slab).
    let k_y = K0 * 1.5 * 0.95;
    for d in [3.0, 60.0] {
        let slab = AirySlab { x_front: 0.0, thickness: d, n_slab: C64::new(1.0, 0.0), n_b: 1.5, k0: K0 };
        let c = slab.coefficients(k_y);
        assert!(c.k2x.im < 0.0, "d = {d}: k2x = {}", c.k2x);
        assert!(c.r.is_finite() && c.t.is_finite(), "d = {d}: r = {}, t = {}", c.r, c.t);
        // Frustrated total reflection between two lossless half-spaces conserves energy.
        assert!((c.r.norm_sqr() + c.t.norm_sqr() - 1.0).abs() < 1e-12, "d = {d}: |r| = {}", c.r.norm());
        let neg = AirySlab { n_slab: C64::new(1.0, -0.0), ..slab };
        let cn = neg.coefficients(k_y);
        assert!((c.r - cn.r).norm() < 1e-12 && (c.t - cn.t).norm() < 1e-12, "d = {d}");
    }
    let thick = AirySlab { x_front: 0.0, thickness: 60.0, n_slab: C64::new(1.0, 0.0), n_b: 1.5, k0: K0 };
    let (r, t) = thick.rt(k_y);
    assert!((r.norm() - 1.0).abs() < 1e-12 && t.norm() < 1e-100, "r = {r}, t = {t}");
}

#[test]
fn airy_thin_slab_is_invisible() {
    let slab = AirySlab { x_front: 0.0, thickness: 0.0, n_slab: C64::new(1.5, -0.1), n_b: 1.0, k0: K0 };
    let (r, t) = slab.rt(2.0);
    assert!(r.norm() < 1e-15 && (t - 1.0).norm() < 1e-15);
}

#[test]
fn airy_field_is_continuous_at_faces() {
    let slab = AirySlab { x_front: -1.5, thickness: 3.0, n_slab: C64::new(1.5, -0.05), n_b: 1.0, k0: K0 };
    let inc = Incident::gaussian(K0, 2.5, Vec2::new(-1.5, 0.0), 0.3, 1.0, 0.0, Rect::new(-6.0, 6.0, -14.0, 14.0));
    for y in [-3.0, 0.0, 1.7] {
        for x in [-1.5, 1.5] {
            let a = slab.field(&inc, Vec2::new(x - 1e-9, y));
            let b = slab.field(&inc, Vec2::new(x + 1e-9, y));
            assert!((a - b).norm() < 1e-7, "x = {x}, y = {y}: {a} vs {b}");
        }
    }
}

#[test]
fn image_vanishes_on_the_plane() {
    let inc = Incident::gaussian(K0, 2.5, Vec2::new(-3.0, 0.0), 0.4, 1.0, 0.0, Rect::new(-11.0, 7.0, -15.0, 15.0));
    for k in 0..20 {
        let y = -10.0 + k as f64;
        assert!(pec_plane_image(&inc, 4.0, Vec2::new(4.0, y)).norm() < 1e-14);
    }
}

#[test]
fn fitted_order_recovers_a_power_law() {
    use beam_core::analytic::metrics::fitted_order;
    let h = [1.0 / 12.0, 1.0 / 16.0, 1.0 / 20.0, 1.0 / 24.0, 1.0 / 30.0];
    let e: Vec<f64> = h.iter().map(|h: &f64| 3.0 * h.powf(2.2)).collect();
    assert!((fitted_order(&h, &e) - 2.2).abs() < 1e-12);
}
