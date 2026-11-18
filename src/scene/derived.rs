//! Quantities derived from the scene for the inspector. These are
//! paraxial or textbook estimates for orientation, not solver output.

use std::f64::consts::PI;

use serde_json::{json, Value};

use crate::types::Vec2;

use super::types::*;

/// Thick-lens paraxial focal length, back focal length and focus point for a lens
/// with relative index `n_rel`. `None` when the lens has no power.
pub struct LensParaxial {
    pub focal_um: f64,
    pub back_focal_um: f64,
    pub focus: Vec2,
}

/// A dispersive material uses Re n at the vacuum wavelength `lambda0`.
pub fn lens_paraxial(e: &Element, n_b: f64, lambda0: f64) -> Option<LensParaxial> {
    let Shape::Lens { r1_um, r2_um, center_thickness_um: t, .. } = e.shape else {
        return None;
    };
    let n = e.material.index_at(lambda0)?.re;
    let n_rel = n / n_b;
    let c1 = r1_um.map_or(0.0, |r| 1.0 / r);
    let c2 = r2_um.map_or(0.0, |r| 1.0 / r);
    let power = (n_rel - 1.0) * (c1 - c2 + (n_rel - 1.0) * t * c1 * c2 / n_rel);
    if power == 0.0 || !power.is_finite() {
        return None;
    }
    let f = 1.0 / power;
    let bfl = f * (1.0 - (n_rel - 1.0) * t * c1 / n_rel);
    let rot = e.rotation_deg.to_radians();
    let axis = Vec2::from_angle(rot);
    let back_vertex = Vec2::new(e.x_um, e.y_um) + axis * (0.5 * t);
    Some(LensParaxial { focal_um: f, back_focal_um: bfl, focus: back_vertex + axis * bfl })
}

pub fn derived(scene: &Scene) -> Value {
    let lambda0 = scene.wavelength_um;
    let n_b = scene.background.n;
    let lambda_b = lambda0 / n_b;
    let n_max = scene
        .elements
        .iter()
        .filter(|e| e.enabled)
        .filter_map(|e| e.material.index_at(lambda0).map(|n| n.norm()))
        .fold(n_b, f64::max);

    let source_derived = |k: &SourceKind| match *k {
        SourceKind::GaussianBeam { waist_um: w0, .. } => json!({
            "rayleigh_range_um": PI * w0 * w0 * n_b / lambda0,
            // atan of the paraxial λ/(π n w0): the same for wide beams, and
            // below 90° for the sub-wavelength waists where the paraxial value
            // would exceed it.
            "divergence_deg": (lambda0 / (PI * n_b * w0)).atan().to_degrees(),
        }),
        SourceKind::PlaneWave { .. } | SourceKind::LineSource { .. } => json!({}),
    };
    let sources: Vec<Value> = scene
        .sources
        .iter()
        .map(|s| {
            let mut v = source_derived(&s.kind);
            if let Value::Object(o) = &mut v {
                o.insert("id".into(), json!(s.id));
            }
            v
        })
        .collect();
    // `source` describes the first enabled source, as in version 2.
    let source = scene.enabled_sources().next().map_or(json!({}), |s| source_derived(&s.kind));

    let elements: Vec<Value> = scene.elements.iter().map(|e| element_derived(e, scene, lambda_b)).collect();

    json!({
        "lambda_b_um": lambda_b,
        "lambda_min_um": lambda0 / n_max,
        "source": source,
        "sources": sources,
        "elements": elements,
    })
}

fn element_derived(e: &Element, scene: &Scene, lambda_b: f64) -> Value {
    let n_b = scene.background.n;
    let lambda0 = scene.wavelength_um;
    let index = e.material.index_at(lambda0);
    let n = index.map(|n| n.re);
    let mut out = json!({ "id": e.id });
    // The material at the scene wavelength (what the solvers use): n + ik and
    // ε1 + iε2 in the optics convention (k, ε2 ≥ 0 absorb). `eps_re` and
    // `eps_im` repeat ε1 and ε2 under the names the app reads.
    if let (Some(nc), Some(eps), Value::Object(o)) = (index, e.material.eps_at(lambda0), &mut out) {
        o.insert(
            "material".into(),
            json!({
                "n": nc.re, "k": -nc.im, "eps1": eps.re, "eps2": -eps.im,
                "eps_re": eps.re, "eps_im": -eps.im, "dispersive": e.material.is_dispersive(),
            }),
        );
    }
    let body = match e.shape {
        Shape::Lens { r1_um, r2_um, center_thickness_um: t, aperture_um: d } => {
            let h = 0.5 * d;
            let edge = crate::geometry::lens_surface_x(0.5 * t, r2_um, h) - crate::geometry::lens_surface_x(-0.5 * t, r1_um, h);
            match lens_paraxial(e, n_b, lambda0) {
                Some(p) => json!({ "lens": {
                    "paraxial_focal_um": p.focal_um,
                    "back_focal_um": p.back_focal_um,
                    "edge_thickness_um": edge,
                    "paraxial_focus_um": [p.focus.x, p.focus.y],
                }}),
                None => json!({ "lens": {
                    "paraxial_focal_um": null, "back_focal_um": null,
                    "edge_thickness_um": edge, "paraxial_focus_um": null,
                }}),
            }
        }
        Shape::Mirror { radius_um, .. } => json!({ "mirror": { "focal_um": radius_um.map(|r| 0.5 * r) } }),
        Shape::Grating { period_um, .. } => {
            // Orders for the first beam's incidence (normal incidence without one).
            let beam = scene.first_beam().and_then(|s| s.kind.angle_deg()).unwrap_or(e.rotation_deg);
            let theta_i = (beam - e.rotation_deg).to_radians();
            let mut orders = Vec::new();
            let m_max = (2.0 * period_um / lambda_b).ceil() as i64 + 1;
            for m in -m_max..=m_max {
                let s = theta_i.sin() + m as f64 * lambda_b / period_um;
                if s.abs() <= 1.0 {
                    orders.push(json!({ "m": m, "angle_deg": s.asin().to_degrees() }));
                }
            }
            json!({ "grating": { "orders": orders } })
        }
        Shape::Slits { slit_width_um, pitch_um, count, .. } => {
            let r = lambda_b / slit_width_um;
            json!({ "slits": {
                "single_slit_null_deg": if r <= 1.0 { Some(r.asin().to_degrees()) } else { None },
                "fringe_spacing_deg": if count > 1 { Some((lambda_b / pitch_um).to_degrees()) } else { None },
            }})
        }
        Shape::Cylinder { radius_um } => {
            json!({ "cylinder": { "size_parameter": 2.0 * PI / lambda_b * radius_um } })
        }
        Shape::Waveguide { width_um, .. } => match n {
            Some(n) if n > n_b => {
                let v = PI * width_um / lambda0 * (n * n - n_b * n_b).sqrt();
                json!({ "waveguide": { "v_number": v, "guided_modes": (2.0 * v / PI).ceil() as i64 } })
            }
            _ => json!({ "waveguide": { "v_number": 0.0, "guided_modes": 0 } }),
        },
        Shape::Prism { apex_deg, .. } => {
            let a = apex_deg.to_radians();
            let dev = n.and_then(|n| {
                let s = n / n_b * (0.5 * a).sin();
                (s <= 1.0).then(|| (2.0 * s.asin() - a).to_degrees())
            });
            json!({ "prism": { "min_deviation_deg": dev } })
        }
        _ => json!({}),
    };
    if let (Value::Object(o), Value::Object(b)) = (&mut out, body) {
        o.extend(b);
    }
    out
}
