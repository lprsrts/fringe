//! Distances and intersections between segments and between bodies.

use crate::types::Vec2;

use super::body::{Body, Contour};
use super::curve::Segment;

/// Smallest distance between two bodies: 0 if their boundaries cross or one
/// contains the other.
pub fn min_gap(a: &Body, b: &Body) -> f64 {
    contour_gap(&a.contour, &b.contour)
}

pub fn contour_gap(a: &Contour, b: &Contour) -> f64 {
    let (Some(sa), Some(sb)) = (a.segments.first(), b.segments.first()) else {
        return f64::INFINITY;
    };
    if a.inside(sb.start()) || b.inside(sa.start()) {
        return 0.0;
    }
    let mut best = f64::INFINITY;
    for s in &a.segments {
        for t in &b.segments {
            if s.bbox().distance(&t.bbox()) >= best {
                continue;
            }
            best = best.min(segment_distance(s, t));
            if best == 0.0 {
                return 0.0;
            }
        }
    }
    best
}

/// Distance between two segments, 0 if they intersect.
///
/// The minimum is either at an endpoint of one segment (handled by the exact
/// point–segment distance) or at an interior pair where the connecting vector is
/// normal to both curves; for an arc that means it is radial, which gives the
/// candidate points below.
pub fn segment_distance(s: &Segment, t: &Segment) -> f64 {
    if segments_intersect(s, t) {
        return 0.0;
    }
    let mut d = s
        .closest(t.start())
        .2
        .min(s.closest(t.end()).2)
        .min(t.closest(s.start()).2)
        .min(t.closest(s.end()).2);
    match (*s, *t) {
        (Segment::Line { .. }, Segment::Line { .. }) => {}
        (Segment::Line { a, b }, arc @ Segment::Arc { .. }) | (arc @ Segment::Arc { .. }, Segment::Line { a, b }) => {
            d = d.min(line_arc_interior(a, b, &arc));
        }
        (Segment::Arc { center: c1, radius: r1, .. }, Segment::Arc { center: c2, radius: r2, .. }) => {
            let u = c2 - c1;
            if u.norm() > 0.0 {
                let u = u.normalized();
                for s1 in [1.0, -1.0] {
                    let p = c1 + u * (s1 * r1);
                    if s.arc_param((p - c1).angle()).is_none() {
                        continue;
                    }
                    for s2 in [1.0, -1.0] {
                        let q = c2 + u * (s2 * r2);
                        if t.arc_param((q - c2).angle()).is_some() {
                            d = d.min(p.dist(q));
                        }
                    }
                }
            }
        }
    }
    d
}

fn line_arc_interior(a: Vec2, b: Vec2, arc: &Segment) -> f64 {
    let Segment::Arc { center, radius, .. } = *arc else {
        return f64::INFINITY;
    };
    let dir = (b - a).normalized();
    let n = dir.perp();
    let mut d = f64::INFINITY;
    for s in [1.0, -1.0] {
        let p = center + n * (s * radius);
        if arc.arc_param((p - center).angle()).is_none() {
            continue;
        }
        let along = (p - a).dot(dir);
        if along >= 0.0 && along <= a.dist(b) {
            d = d.min((p - a).cross(dir).abs());
        }
    }
    d
}

/// Whether two segments share a point.
pub fn segments_intersect(s: &Segment, t: &Segment) -> bool {
    if !s.bbox().intersects(&t.bbox()) {
        return false;
    }
    match (*s, *t) {
        (Segment::Line { a, b }, Segment::Line { a: c, b: d }) => lines_intersect(a, b, c, d),
        (Segment::Line { a, b }, arc @ Segment::Arc { .. }) | (arc @ Segment::Arc { .. }, Segment::Line { a, b }) => {
            line_arc_intersect(a, b, &arc)
        }
        (Segment::Arc { center: c1, radius: r1, .. }, Segment::Arc { center: c2, radius: r2, .. }) => {
            let dv = c2 - c1;
            let dist = dv.norm();
            if dist == 0.0 {
                // Concentric: they touch only if on the same circle with overlapping spans.
                return (r1 - r2).abs() < 1e-12
                    && (s.arc_param((t.start() - c1).angle()).is_some()
                        || t.arc_param((s.start() - c2).angle()).is_some());
            }
            if dist > r1 + r2 || dist < (r1 - r2).abs() {
                return false;
            }
            let x = (dist * dist + r1 * r1 - r2 * r2) / (2.0 * dist);
            let h = (r1 * r1 - x * x).max(0.0).sqrt();
            let u = dv / dist;
            let base = c1 + u * x;
            [base + u.perp() * h, base - u.perp() * h].iter().any(|&p| {
                s.arc_param((p - c1).angle()).is_some() && t.arc_param((p - c2).angle()).is_some()
            })
        }
    }
}

fn orient(a: Vec2, b: Vec2, c: Vec2) -> f64 {
    (b - a).cross(c - a)
}

fn on_segment(a: Vec2, b: Vec2, p: Vec2) -> bool {
    p.x >= a.x.min(b.x) - 1e-15
        && p.x <= a.x.max(b.x) + 1e-15
        && p.y >= a.y.min(b.y) - 1e-15
        && p.y <= a.y.max(b.y) + 1e-15
}

pub fn lines_intersect(a: Vec2, b: Vec2, c: Vec2, d: Vec2) -> bool {
    let d1 = orient(c, d, a);
    let d2 = orient(c, d, b);
    let d3 = orient(a, b, c);
    let d4 = orient(a, b, d);
    if ((d1 > 0.0 && d2 < 0.0) || (d1 < 0.0 && d2 > 0.0)) && ((d3 > 0.0 && d4 < 0.0) || (d3 < 0.0 && d4 > 0.0)) {
        return true;
    }
    (d1 == 0.0 && on_segment(c, d, a))
        || (d2 == 0.0 && on_segment(c, d, b))
        || (d3 == 0.0 && on_segment(a, b, c))
        || (d4 == 0.0 && on_segment(a, b, d))
}

fn line_arc_intersect(a: Vec2, b: Vec2, arc: &Segment) -> bool {
    let Segment::Arc { center, radius, .. } = *arc else {
        return false;
    };
    let d = b - a;
    let f = a - center;
    let qa = d.norm_sqr();
    if qa == 0.0 {
        return false;
    }
    let qb = 2.0 * f.dot(d);
    let qc = f.norm_sqr() - radius * radius;
    let disc = qb * qb - 4.0 * qa * qc;
    if disc < 0.0 {
        return false;
    }
    let sq = disc.sqrt();
    [(-qb - sq) / (2.0 * qa), (-qb + sq) / (2.0 * qa)].iter().any(|&u| {
        (-1e-12..=1.0 + 1e-12).contains(&u) && arc.arc_param((a + d * u - center).angle()).is_some()
    })
}

/// Whether a closed polygon given by its vertices crosses itself (non-adjacent
/// edges meet, or adjacent edges fold back onto each other).
pub fn polygon_self_intersects(v: &[Vec2]) -> bool {
    let n = v.len();
    if n < 3 {
        return false;
    }
    for i in 0..n {
        let (a, b) = (v[i], v[(i + 1) % n]);
        for j in i + 1..n {
            let (c, d) = (v[j], v[(j + 1) % n]);
            let adjacent = j == i + 1 || (i == 0 && j == n - 1);
            if adjacent {
                // Adjacent edges share a vertex; they only overlap if collinear and folding back.
                let shared = if j == i + 1 { b } else { a };
                let other1 = if j == i + 1 { a } else { b };
                let other2 = if j == i + 1 { d } else { c };
                let u = other1 - shared;
                let w = other2 - shared;
                if u.cross(w).abs() <= 1e-15 * u.norm() * w.norm() && u.dot(w) > 0.0 {
                    return true;
                }
                continue;
            }
            if lines_intersect(a, b, c, d) {
                return true;
            }
        }
    }
    false
}
