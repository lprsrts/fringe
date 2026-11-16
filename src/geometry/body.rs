//! Closed contours and the bodies built from them.

use crate::types::{Rect, Vec2, C64};

use super::curve::Segment;

/// See [`Contour::polyline`].
pub const MAX_POLYLINE_PIECES: f64 = 4096.0;

/// A closed, continuous boundary traversed counter-clockwise (interior on the left).
#[derive(Clone, Debug, PartialEq)]
pub struct Contour {
    pub segments: Vec<Segment>,
}

impl Contour {
    pub fn new(segments: Vec<Segment>) -> Self {
        Self { segments }
    }

    /// Closed polygon through `vertices`, made counter-clockwise if it is not.
    pub fn polygon(vertices: &[Vec2]) -> Self {
        let mut v = vertices.to_vec();
        if signed_area(&v) < 0.0 {
            v.reverse();
        }
        let n = v.len();
        Self {
            segments: (0..n).map(|i| Segment::Line { a: v[i], b: v[(i + 1) % n] }).collect(),
        }
    }

    pub fn length(&self) -> f64 {
        self.segments.iter().map(|s| s.length()).sum()
    }

    /// Outward unit normal: the tangent turned clockwise.
    pub fn outward_normal(&self, seg: usize, t: f64) -> Vec2 {
        let tg = self.segments[seg].tangent(t);
        Vec2::new(tg.y, -tg.x)
    }

    /// Exact point-in-contour test by counting crossings of a ray toward +x.
    pub fn inside(&self, p: Vec2) -> bool {
        let n: u32 = self.segments.iter().map(|s| s.crossings(p)).sum();
        n % 2 == 1
    }

    /// Distance to the boundary, negative inside.
    pub fn signed_distance(&self, p: Vec2) -> f64 {
        let d = self.closest(p).3;
        if self.inside(p) {
            -d
        } else {
            d
        }
    }

    /// Segment index, parameter, point and distance of the closest boundary point.
    pub fn closest(&self, p: Vec2) -> (usize, f64, Vec2, f64) {
        let mut best = (0, 0.0, p, f64::INFINITY);
        for (i, s) in self.segments.iter().enumerate() {
            let (t, q, d) = s.closest(p);
            if d < best.3 {
                best = (i, t, q, d);
            }
        }
        best
    }

    /// Distance along the ray `p + t·dir` (`dir` a unit vector) to the first
    /// boundary crossing in `(0, t_max]`, if any.
    pub fn ray_hit(&self, p: Vec2, dir: Vec2, t_max: f64) -> Option<f64> {
        self.segments.iter().flat_map(|s| s.ray_hits(p, dir, t_max)).min_by(f64::total_cmp)
    }

    pub fn bbox(&self) -> Rect {
        self.segments.iter().fold(Rect::EMPTY, |r, s| r.union(&s.bbox()))
    }

    /// Points along the contour (the closing point is not repeated). Each segment is
    /// split into equal-parameter pieces no longer than `max_chord` and turning no
    /// more than `max_angle_rad`. The chord is raised if needed so that the
    /// length-based pieces number at most [`MAX_POLYLINE_PIECES`] per contour,
    /// which bounds the output for a huge body or a tiny wavelength.
    pub fn polyline(&self, max_chord: f64, max_angle_rad: f64) -> Vec<Vec2> {
        let max_chord = max_chord.max(self.length() / MAX_POLYLINE_PIECES);
        let mut out = Vec::new();
        for s in &self.segments {
            let mut n = 1usize;
            if max_chord > 0.0 && max_chord.is_finite() {
                n = n.max((s.length() / max_chord).ceil() as usize);
            }
            if let Segment::Arc { sweep, .. } = *s {
                if max_angle_rad > 0.0 {
                    n = n.max((sweep.abs() / max_angle_rad).ceil() as usize);
                }
            }
            for k in 0..n {
                out.push(s.point(k as f64 / n as f64));
            }
        }
        out
    }

    /// Indices of vertices (the start of segment i) where the tangent turns by more
    /// than `min_turn_rad`.
    pub fn corners(&self, min_turn_rad: f64) -> Vec<usize> {
        let n = self.segments.len();
        (0..n)
            .filter(|&i| {
                let prev = self.segments[(i + n - 1) % n].tangent(1.0);
                let next = self.segments[i].tangent(0.0);
                prev.cross(next).atan2(prev.dot(next)).abs() > min_turn_rad
            })
            .collect()
    }

    /// Area enclosed, positive for a counter-clockwise contour.
    pub fn area(&self) -> f64 {
        // Green's theorem: A = ½ ∮ (x dy − y dx). Exact for lines; for arcs the
        // integral has a closed form.
        let mut a = 0.0;
        for s in &self.segments {
            match *s {
                Segment::Line { a: p, b: q } => a += 0.5 * p.cross(q),
                Segment::Arc { center, radius, start, sweep } => {
                    let (t0, t1) = (start, start + sweep);
                    // ½ ∫ (x y' − y x') dθ with x = cx + r cos θ, y = cy + r sin θ.
                    a += 0.5
                        * (radius * radius * sweep
                            + radius * center.x * (t1.sin() - t0.sin())
                            - radius * center.y * (t1.cos() - t0.cos()));
                }
            }
        }
        a
    }
}

pub fn signed_area(v: &[Vec2]) -> f64 {
    let n = v.len();
    (0..n).map(|i| v[i].cross(v[(i + 1) % n])).sum::<f64>() * 0.5
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum BodyMaterial {
    Pec,
    /// `n` is the complex index n − jk (e^{jωt} convention) and `eps = n²`.
    Dielectric { n: C64, eps: C64 },
}

impl BodyMaterial {
    /// From the user's n + ik (k ≥ 0 absorbing).
    pub fn dielectric(n: f64, k: f64) -> Self {
        let nc = C64::new(n, -k);
        BodyMaterial::Dielectric { n: nc, eps: nc * nc }
    }
}

#[derive(Clone, Debug)]
pub struct Body {
    pub element_index: usize,
    pub element_id: String,
    pub name: String,
    pub material: BodyMaterial,
    pub contour: Contour,
    pub bbox: Rect,
    /// Thinnest designed dimension (screen or mirror thickness, bar width, 2r, …).
    pub nominal_thickness_um: Option<f64>,
}

impl Body {
    pub fn inside(&self, p: Vec2) -> bool {
        self.bbox.contains(p) && self.contour.inside(p)
    }

    /// Fraction of `cell` inside the body, by ss × ss midpoint sampling.
    pub fn area_fraction(&self, cell: Rect, ss: usize) -> f64 {
        if !self.bbox.intersects(&cell) {
            return 0.0;
        }
        let ss = ss.max(1);
        let mut hits = 0usize;
        for j in 0..ss {
            let y = cell.y_min + (j as f64 + 0.5) / ss as f64 * cell.height();
            for i in 0..ss {
                let x = cell.x_min + (i as f64 + 0.5) / ss as f64 * cell.width();
                if self.inside(Vec2::new(x, y)) {
                    hits += 1;
                }
            }
        }
        hits as f64 / (ss * ss) as f64
    }

    pub fn is_pec(&self) -> bool {
        matches!(self.material, BodyMaterial::Pec)
    }

    pub fn signed_distance(&self, p: Vec2) -> f64 {
        self.contour.signed_distance(p)
    }
}
