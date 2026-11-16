//! Boundary segments: straight lines and circular arcs, parametrised by t ∈ [0, 1]
//! uniformly in arclength.

use std::f64::consts::{FRAC_PI_2, PI, TAU};

use crate::types::{Rect, Vec2};

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Segment {
    Line { a: Vec2, b: Vec2 },
    /// Angles in radians; `sweep > 0` runs counter-clockwise.
    Arc { center: Vec2, radius: f64, start: f64, sweep: f64 },
}

impl Segment {
    pub fn length(&self) -> f64 {
        match *self {
            Segment::Line { a, b } => a.dist(b),
            Segment::Arc { radius, sweep, .. } => radius * sweep.abs(),
        }
    }

    pub fn point(&self, t: f64) -> Vec2 {
        match *self {
            Segment::Line { a, b } => a.lerp(b, t),
            Segment::Arc { center, radius, start, sweep } => center + Vec2::from_angle(start + t * sweep) * radius,
        }
    }

    pub fn start(&self) -> Vec2 {
        self.point(0.0)
    }

    pub fn end(&self) -> Vec2 {
        self.point(1.0)
    }

    /// Unit tangent in the direction of increasing t.
    pub fn tangent(&self, t: f64) -> Vec2 {
        match *self {
            Segment::Line { a, b } => (b - a).normalized(),
            Segment::Arc { start, sweep, .. } => Vec2::from_angle(start + t * sweep).perp() * sweep.signum(),
        }
    }

    /// Signed curvature: positive when the tangent turns left (CCW arc).
    pub fn curvature(&self) -> f64 {
        match *self {
            Segment::Line { .. } => 0.0,
            Segment::Arc { radius, sweep, .. } => sweep.signum() / radius,
        }
    }

    /// The parameter, point and distance of the closest point on the segment to `p`.
    pub fn closest(&self, p: Vec2) -> (f64, Vec2, f64) {
        match *self {
            Segment::Line { a, b } => {
                let d = b - a;
                let l2 = d.norm_sqr();
                let t = if l2 > 0.0 { ((p - a).dot(d) / l2).clamp(0.0, 1.0) } else { 0.0 };
                let q = a.lerp(b, t);
                (t, q, p.dist(q))
            }
            Segment::Arc { center, .. } => {
                let mut best = {
                    let q = self.point(0.0);
                    (0.0, q, p.dist(q))
                };
                let q1 = self.point(1.0);
                let d1 = p.dist(q1);
                if d1 < best.2 {
                    best = (1.0, q1, d1);
                }
                let v = p - center;
                if v.norm() > 0.0 {
                    if let Some(t) = self.arc_param(v.angle()) {
                        let q = self.point(t);
                        let d = p.dist(q);
                        if d < best.2 {
                            best = (t, q, d);
                        }
                    }
                }
                best
            }
        }
    }

    /// For an arc, the parameter at which it passes polar angle `theta` about its
    /// centre, if it does.
    pub fn arc_param(&self, theta: f64) -> Option<f64> {
        match *self {
            Segment::Line { .. } => None,
            Segment::Arc { start, sweep, .. } => {
                if sweep == 0.0 {
                    return None;
                }
                let u = ((theta - start) * sweep.signum()).rem_euclid(TAU);
                let span = sweep.abs();
                const EPS: f64 = 1e-12;
                if u <= span + EPS {
                    Some((u / span).min(1.0))
                } else if u >= TAU - EPS {
                    Some(0.0)
                } else {
                    None
                }
            }
        }
    }

    /// Distances `t` in `(0, t_max]` at which the ray `p + t·dir` (`dir` a unit
    /// vector) meets the segment, smallest first.
    pub fn ray_hits(&self, p: Vec2, dir: Vec2, t_max: f64) -> Vec<f64> {
        let mut out = Vec::new();
        match *self {
            Segment::Line { a, b } => {
                let e = b - a;
                let den = dir.cross(e);
                if den != 0.0 {
                    let w = a - p;
                    let t = w.cross(e) / den;
                    let s = w.cross(dir) / den;
                    if t > 0.0 && t <= t_max && (0.0..=1.0).contains(&s) {
                        out.push(t);
                    }
                }
            }
            Segment::Arc { center, radius, .. } => {
                let w = p - center;
                let b = dir.dot(w);
                let disc = b * b - (w.norm_sqr() - radius * radius);
                if disc >= 0.0 {
                    let r = disc.sqrt();
                    for t in [-b - r, -b + r] {
                        if t > 0.0 && t <= t_max {
                            let q = p + dir * t - center;
                            if self.arc_param(q.y.atan2(q.x)).is_some() {
                                out.push(t);
                            }
                        }
                    }
                }
            }
        }
        out
    }

    /// The piece of the segment between parameters `t0` and `t1`.
    pub fn sub(&self, t0: f64, t1: f64) -> Segment {
        match *self {
            Segment::Line { a, b } => Segment::Line { a: a.lerp(b, t0), b: a.lerp(b, t1) },
            Segment::Arc { center, radius, start, sweep } => Segment::Arc {
                center,
                radius,
                start: start + t0 * sweep,
                sweep: (t1 - t0) * sweep,
            },
        }
    }

    pub fn bbox(&self) -> Rect {
        match *self {
            Segment::Line { a, b } => Rect::from_points([a, b]),
            Segment::Arc { center, radius, .. } => {
                let mut r = Rect::from_points([self.point(0.0), self.point(1.0)]);
                for k in 0..4 {
                    let theta = k as f64 * FRAC_PI_2;
                    if self.arc_param(theta).is_some() {
                        r = r.include(center + Vec2::from_angle(theta) * radius);
                    }
                }
                r
            }
        }
    }

    /// Parameters splitting the segment into pieces that are monotone in y, in order.
    /// Lines have none; arcs split where the tangent is horizontal.
    pub fn y_turns(&self) -> Vec<f64> {
        match *self {
            Segment::Line { .. } => Vec::new(),
            Segment::Arc { .. } => {
                // Arcs sweep less than a full turn, so each turning angle occurs once at most.
                let mut ts: Vec<f64> = [FRAC_PI_2, -FRAC_PI_2]
                    .iter()
                    .filter_map(|&theta| self.arc_param(theta))
                    .filter(|&t| t > 1e-12 && t < 1.0 - 1e-12)
                    .collect();
                ts.sort_by(|a, b| a.partial_cmp(b).unwrap());
                ts.dedup_by(|a, b| (*a - *b).abs() < 1e-12);
                ts
            }
        }
    }

    /// Number of times the ray from `p` toward +x crosses this segment, using the
    /// half-open rule (an endpoint counts when it is the lower end of a piece), so
    /// shared vertices are counted exactly once around a closed contour.
    pub fn crossings(&self, p: Vec2) -> u32 {
        match *self {
            Segment::Line { a, b } => line_crossing(a, b, p) as u32,
            Segment::Arc { center, radius, start, sweep } => {
                let mut ts = vec![0.0];
                ts.extend(self.y_turns());
                ts.push(1.0);
                let mut count = 0;
                for w in ts.windows(2) {
                    let (t0, t1) = (w[0], w[1]);
                    let a = self.point(t0);
                    let b = self.point(t1);
                    if (a.y > p.y) == (b.y > p.y) {
                        continue;
                    }
                    // Monotone piece straddles p.y: find the crossing angle on it.
                    let s = ((p.y - center.y) / radius).clamp(-1.0, 1.0);
                    let th_a = start + t0 * sweep;
                    let th_b = start + t1 * sweep;
                    let mid = 0.5 * (th_a + th_b);
                    // On a monotone piece cos(θ) has a fixed sign, given by the midpoint.
                    let c = (1.0 - s * s).max(0.0).sqrt() * mid.cos().signum();
                    let x = center.x + radius * c;
                    if x > p.x {
                        count += 1;
                    }
                }
                count
            }
        }
    }
}

#[inline]
fn line_crossing(a: Vec2, b: Vec2, p: Vec2) -> bool {
    if (a.y > p.y) == (b.y > p.y) {
        return false;
    }
    let x = a.x + (p.y - a.y) * (b.x - a.x) / (b.y - a.y);
    x > p.x
}

/// Arc on the circle about `center`, from point `from` to point `to`, passing
/// through `via` (all three on the circle).
pub fn arc_through(center: Vec2, from: Vec2, via: Vec2, to: Vec2) -> Segment {
    let radius = center.dist(from);
    let a0 = (from - center).angle();
    let am = (via - center).angle();
    let a1 = (to - center).angle();
    let wrap = |a: f64| {
        let mut r = a.rem_euclid(TAU);
        if r > PI {
            r -= TAU;
        }
        r
    };
    let sweep = wrap(am - a0) + wrap(a1 - am);
    Segment::Arc { center, radius, start: a0, sweep }
}
