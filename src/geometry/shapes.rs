//! Element shapes (spec §3.2) as bodies in scene coordinates.
//!
//! Each shape is built in its local frame (anchor at the origin, optical axis
//! along +x) as counter-clockwise contours, then rotated about the anchor and
//! translated to it. The builders assume dimensions that passed validation; for
//! bad input they still return finite geometry rather than panicking.

use std::f64::consts::PI;

use crate::scene::{Element, Material, Scene, Shape};
use crate::types::Vec2;

use super::body::{Body, BodyMaterial, Contour};
use super::curve::Segment;

/// Bodies of every enabled element, in list order.
pub fn bodies_from_scene(scene: &Scene) -> Vec<Body> {
    scene
        .elements
        .iter()
        .enumerate()
        .filter(|(_, e)| e.enabled)
        .flat_map(|(i, e)| element_bodies(i, e))
        .collect()
}

/// The bodies one element is made of (several for slits and comb-less gratings).
pub fn element_bodies(index: usize, e: &Element) -> Vec<Body> {
    let material = match e.material {
        Material::Pec => BodyMaterial::Pec,
        Material::Dielectric { n, k } => BodyMaterial::dielectric(n, k),
    };
    let rot = e.rotation_deg.to_radians();
    let anchor = Vec2::new(e.x_um, e.y_um);
    local_contours(&e.shape)
        .into_iter()
        .map(|(c, thickness)| {
            let contour = place(&c, rot, anchor);
            Body {
                element_index: index,
                element_id: e.id.clone(),
                name: e.name.clone(),
                material,
                bbox: contour.bbox(),
                contour,
                nominal_thickness_um: thickness,
            }
        })
        .collect()
}

fn place(c: &Contour, rot: f64, anchor: Vec2) -> Contour {
    Contour::new(
        c.segments
            .iter()
            .map(|s| match *s {
                Segment::Line { a, b } => Segment::Line { a: a.rotate(rot) + anchor, b: b.rotate(rot) + anchor },
                Segment::Arc { center, radius, start, sweep } => Segment::Arc {
                    center: center.rotate(rot) + anchor,
                    radius,
                    start: start + rot,
                    sweep,
                },
            })
            .collect(),
    )
}

fn rect(x0: f64, x1: f64, y0: f64, y1: f64) -> Contour {
    Contour::polygon(&[Vec2::new(x0, y0), Vec2::new(x1, y0), Vec2::new(x1, y1), Vec2::new(x0, y1)])
}

/// A surface `x(y) = cx ± √(r² − y²)` between heights `y_from` and `y_to`, as an arc
/// (`right` picks the + branch) or a vertical line when `r` is `None`.
fn surface(cx: f64, r: Option<f64>, right: bool, x_flat: f64, y_from: f64, y_to: f64) -> Segment {
    match r {
        None => Segment::Line { a: Vec2::new(x_flat, y_from), b: Vec2::new(x_flat, y_to) },
        Some(r) => {
            let r = r.abs();
            let s0 = (y_from / r).clamp(-1.0, 1.0).asin();
            let s1 = (y_to / r).clamp(-1.0, 1.0).asin();
            let (start, sweep) = if right { (s0, s1 - s0) } else { (PI - s0, -(s1 - s0)) };
            Segment::Arc { center: Vec2::new(cx, 0.0), radius: r, start, sweep }
        }
    }
}

/// Front and back surfaces joined by straight top and bottom edges, for |y| ≤ h.
/// `front` runs top to bottom and `back` bottom to top.
fn two_surface_body(front: Segment, back: Segment) -> Contour {
    let fb = front.end();
    let bb = back.start();
    let bt = back.end();
    let ft = front.start();
    Contour::new(vec![
        Segment::Line { a: fb, b: bb },
        back,
        Segment::Line { a: bt, b: ft },
        front,
    ])
}

/// Lens surface `x(y) = x_vertex + R − sgn(R)√(R² − y²)`: the centre of curvature is
/// at `x_vertex + R`, and the surface is the circle's left branch when R > 0.
pub fn lens_surface_x(x_vertex: f64, r: Option<f64>, y: f64) -> f64 {
    match r {
        None => x_vertex,
        Some(r) => x_vertex + r - r.signum() * (r * r - y * y).max(0.0).sqrt(),
    }
}

/// Mirror front face `x(y) = −R + sgn(R)√(R² − y²)` (vertex at the origin).
pub fn mirror_surface_x(r: Option<f64>, y: f64) -> f64 {
    match r {
        None => 0.0,
        Some(r) => -r + r.signum() * (r * r - y * y).max(0.0).sqrt(),
    }
}

/// Local contours of a shape, each with its nominal thickness.
pub fn local_contours(shape: &Shape) -> Vec<(Contour, Option<f64>)> {
    match *shape {
        Shape::Lens { r1_um, r2_um, center_thickness_um: t, aperture_um: d } => {
            let h = 0.5 * d;
            let xf = -0.5 * t;
            let xb = 0.5 * t;
            let front = surface(xf + r1_um.unwrap_or(0.0), r1_um, r1_um.is_some_and(|r| r < 0.0), xf, h, -h);
            let back = surface(xb + r2_um.unwrap_or(0.0), r2_um, r2_um.is_some_and(|r| r < 0.0), xb, -h, h);
            let edge = lens_surface_x(xb, r2_um, h) - lens_surface_x(xf, r1_um, h);
            vec![(two_surface_body(front, back), Some(t.min(edge)))]
        }
        Shape::Slab { thickness_um: t, height_um: h } => {
            vec![(rect(-0.5 * t, 0.5 * t, -0.5 * h, 0.5 * h), Some(t.min(h)))]
        }
        Shape::Waveguide { width_um: w, length_um: l } => {
            vec![(rect(-0.5 * l, 0.5 * l, -0.5 * w, 0.5 * w), Some(w.min(l)))]
        }
        Shape::Wedge { thick_um: big, thin_um: small, height_um: h } => {
            let v = [
                Vec2::new(-0.5 * big, -0.5 * h),
                Vec2::new(0.5 * big, -0.5 * h),
                Vec2::new(-0.5 * big + small, 0.5 * h),
                Vec2::new(-0.5 * big, 0.5 * h),
            ];
            vec![(Contour::polygon(&v), Some(small.min(h)))]
        }
        Shape::Prism { base_um: b, apex_deg } => {
            let height = 0.5 * b / (0.5 * apex_deg.to_radians()).tan();
            let v = [
                Vec2::new(-0.5 * b, -height / 3.0),
                Vec2::new(0.5 * b, -height / 3.0),
                Vec2::new(0.0, 2.0 * height / 3.0),
            ];
            vec![(Contour::polygon(&v), Some(b.min(height)))]
        }
        Shape::Mirror { aperture_um: d, thickness_um: t, radius_um } => {
            let h = 0.5 * d;
            // Front centre at −R, back centre at −R + t; R > 0 uses the right branch.
            let right = radius_um.is_some_and(|r| r > 0.0);
            let cx = -radius_um.unwrap_or(0.0);
            let front = surface(cx, radius_um, right, 0.0, h, -h);
            let back = surface(cx + t, radius_um, right, t, -h, h);
            vec![(two_surface_body(front, back), Some(t))]
        }
        Shape::Slits { count, slit_width_um: w, pitch_um: p, screen_height_um: hs, thickness_um: t } => {
            let n = count.max(1) as usize;
            let centre = |k: usize| (k as f64 - 0.5 * (n as f64 - 1.0)) * p;
            let mut edges = vec![-0.5 * hs];
            for k in 0..n {
                edges.push(centre(k) - 0.5 * w);
                edges.push(centre(k) + 0.5 * w);
            }
            edges.push(0.5 * hs);
            edges
                .chunks(2)
                .map(|e| {
                    let (y0, y1) = (e[0], e[1]);
                    (rect(-0.5 * t, 0.5 * t, y0, y1), Some(t.min(y1 - y0)))
                })
                .collect()
        }
        Shape::Grating { period_um: period, fill_factor: f, depth_um: depth, count, substrate_um: s } => {
            let n = count.max(1) as usize;
            let bar = f * period;
            let centre = |k: usize| (k as f64 - 0.5 * (n as f64 - 1.0)) * period;
            let (x0, x1) = (-0.5 * depth, 0.5 * depth);
            if s > 0.0 {
                // One comb: substrate on +x with the bars standing on its front face.
                let half = 0.5 * n as f64 * period;
                let mut v = vec![Vec2::new(x1 + s, -half), Vec2::new(x1 + s, half), Vec2::new(x1, half)];
                for k in (0..n).rev() {
                    let yc = centre(k);
                    v.push(Vec2::new(x1, yc + 0.5 * bar));
                    v.push(Vec2::new(x0, yc + 0.5 * bar));
                    v.push(Vec2::new(x0, yc - 0.5 * bar));
                    v.push(Vec2::new(x1, yc - 0.5 * bar));
                }
                v.push(Vec2::new(x1, -half));
                let thin = bar.min(depth).min(s).min(period - bar);
                vec![(Contour::polygon(&v), Some(thin))]
            } else {
                (0..n)
                    .map(|k| {
                        let yc = centre(k);
                        (rect(x0, x1, yc - 0.5 * bar, yc + 0.5 * bar), Some(bar.min(depth)))
                    })
                    .collect()
            }
        }
        Shape::Cylinder { radius_um: r } => {
            let c = Contour::new(vec![
                Segment::Arc { center: Vec2::ZERO, radius: r, start: 0.0, sweep: PI },
                Segment::Arc { center: Vec2::ZERO, radius: r, start: PI, sweep: PI },
            ]);
            vec![(c, Some(2.0 * r))]
        }
        Shape::Polygon { ref vertices_um } => {
            let v: Vec<Vec2> = vertices_um.iter().map(|p| Vec2::new(p[0], p[1])).collect();
            if v.len() < 3 {
                return Vec::new();
            }
            vec![(Contour::polygon(&v), Some(super::intersect::polygon_min_width(&v)))]
        }
    }
}
