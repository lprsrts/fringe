//! Small shared types: complex numbers, 2D vectors and rectangles.

use std::ops::{Add, AddAssign, Div, Mul, Neg, Sub, SubAssign};

use serde::{Deserialize, Serialize};

pub type C64 = num_complex::Complex64;

#[allow(clippy::approx_constant)] // std's EGAMMA is not stable yet
pub const EULER_GAMMA: f64 = 0.577_215_664_901_532_9;

/// The imaginary unit.
pub const J: C64 = C64::new(0.0, 1.0);

#[inline]
pub const fn c64(re: f64, im: f64) -> C64 {
    C64::new(re, im)
}

/// `e^{jθ}`.
#[inline]
pub fn cis(theta: f64) -> C64 {
    let (s, c) = theta.sin_cos();
    C64::new(c, s)
}

#[derive(Copy, Clone, Debug, PartialEq, Default, Serialize, Deserialize)]
pub struct Vec2 {
    pub x: f64,
    pub y: f64,
}

impl Vec2 {
    pub const ZERO: Vec2 = Vec2 { x: 0.0, y: 0.0 };

    #[inline]
    pub const fn new(x: f64, y: f64) -> Self {
        Self { x, y }
    }

    /// Unit vector at angle `theta` (radians, counter-clockwise from +x).
    #[inline]
    pub fn from_angle(theta: f64) -> Self {
        let (s, c) = theta.sin_cos();
        Self { x: c, y: s }
    }

    #[inline]
    pub fn dot(self, o: Vec2) -> f64 {
        self.x * o.x + self.y * o.y
    }

    /// z component of the 3D cross product.
    #[inline]
    pub fn cross(self, o: Vec2) -> f64 {
        self.x * o.y - self.y * o.x
    }

    #[inline]
    pub fn norm(self) -> f64 {
        self.x.hypot(self.y)
    }

    #[inline]
    pub fn norm_sqr(self) -> f64 {
        self.x * self.x + self.y * self.y
    }

    #[inline]
    pub fn normalized(self) -> Vec2 {
        let n = self.norm();
        if n > 0.0 {
            self / n
        } else {
            self
        }
    }

    /// Rotated counter-clockwise by `theta` radians.
    #[inline]
    pub fn rotate(self, theta: f64) -> Vec2 {
        let (s, c) = theta.sin_cos();
        Vec2::new(c * self.x - s * self.y, s * self.x + c * self.y)
    }

    /// Rotated by +90°.
    #[inline]
    pub fn perp(self) -> Vec2 {
        Vec2::new(-self.y, self.x)
    }

    #[inline]
    pub fn angle(self) -> f64 {
        self.y.atan2(self.x)
    }

    #[inline]
    pub fn dist(self, o: Vec2) -> f64 {
        (self - o).norm()
    }

    #[inline]
    pub fn lerp(self, o: Vec2, t: f64) -> Vec2 {
        self + (o - self) * t
    }

    #[inline]
    pub fn to_array(self) -> [f64; 2] {
        [self.x, self.y]
    }

    #[inline]
    pub fn is_finite(self) -> bool {
        self.x.is_finite() && self.y.is_finite()
    }
}

impl Add for Vec2 {
    type Output = Vec2;
    #[inline]
    fn add(self, o: Vec2) -> Vec2 {
        Vec2::new(self.x + o.x, self.y + o.y)
    }
}

impl Sub for Vec2 {
    type Output = Vec2;
    #[inline]
    fn sub(self, o: Vec2) -> Vec2 {
        Vec2::new(self.x - o.x, self.y - o.y)
    }
}

impl Mul<f64> for Vec2 {
    type Output = Vec2;
    #[inline]
    fn mul(self, s: f64) -> Vec2 {
        Vec2::new(self.x * s, self.y * s)
    }
}

impl Mul<Vec2> for f64 {
    type Output = Vec2;
    #[inline]
    fn mul(self, v: Vec2) -> Vec2 {
        v * self
    }
}

impl Div<f64> for Vec2 {
    type Output = Vec2;
    #[inline]
    fn div(self, s: f64) -> Vec2 {
        Vec2::new(self.x / s, self.y / s)
    }
}

impl Neg for Vec2 {
    type Output = Vec2;
    #[inline]
    fn neg(self) -> Vec2 {
        Vec2::new(-self.x, -self.y)
    }
}

impl AddAssign for Vec2 {
    #[inline]
    fn add_assign(&mut self, o: Vec2) {
        self.x += o.x;
        self.y += o.y;
    }
}

impl SubAssign for Vec2 {
    #[inline]
    fn sub_assign(&mut self, o: Vec2) {
        self.x -= o.x;
        self.y -= o.y;
    }
}

#[derive(Copy, Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Rect {
    pub x_min: f64,
    pub x_max: f64,
    pub y_min: f64,
    pub y_max: f64,
}

impl Rect {
    pub const fn new(x_min: f64, x_max: f64, y_min: f64, y_max: f64) -> Self {
        Self {
            x_min,
            x_max,
            y_min,
            y_max,
        }
    }

    /// The rectangle with no area that `union` treats as empty.
    pub const EMPTY: Rect = Rect {
        x_min: f64::INFINITY,
        x_max: f64::NEG_INFINITY,
        y_min: f64::INFINITY,
        y_max: f64::NEG_INFINITY,
    };

    pub fn from_points(ps: impl IntoIterator<Item = Vec2>) -> Rect {
        ps.into_iter().fold(Rect::EMPTY, |r, p| r.include(p))
    }

    #[inline]
    pub fn width(&self) -> f64 {
        self.x_max - self.x_min
    }

    #[inline]
    pub fn height(&self) -> f64 {
        self.y_max - self.y_min
    }

    #[inline]
    pub fn center(&self) -> Vec2 {
        Vec2::new(0.5 * (self.x_min + self.x_max), 0.5 * (self.y_min + self.y_max))
    }

    #[inline]
    pub fn diag(&self) -> f64 {
        self.width().hypot(self.height())
    }

    /// Closed containment.
    #[inline]
    pub fn contains(&self, p: Vec2) -> bool {
        p.x >= self.x_min && p.x <= self.x_max && p.y >= self.y_min && p.y <= self.y_max
    }

    pub fn contains_rect(&self, o: &Rect) -> bool {
        o.x_min >= self.x_min && o.x_max <= self.x_max && o.y_min >= self.y_min && o.y_max <= self.y_max
    }

    /// Grown by `d` on every side (shrunk for negative `d`).
    pub fn expand(&self, d: f64) -> Rect {
        Rect::new(self.x_min - d, self.x_max + d, self.y_min - d, self.y_max + d)
    }

    pub fn union(&self, o: &Rect) -> Rect {
        Rect::new(
            self.x_min.min(o.x_min),
            self.x_max.max(o.x_max),
            self.y_min.min(o.y_min),
            self.y_max.max(o.y_max),
        )
    }

    pub fn include(&self, p: Vec2) -> Rect {
        Rect::new(
            self.x_min.min(p.x),
            self.x_max.max(p.x),
            self.y_min.min(p.y),
            self.y_max.max(p.y),
        )
    }

    pub fn intersects(&self, o: &Rect) -> bool {
        self.x_min <= o.x_max && o.x_min <= self.x_max && self.y_min <= o.y_max && o.y_min <= self.y_max
    }

    /// Distance between the two rectangles, 0 if they overlap.
    pub fn distance(&self, o: &Rect) -> f64 {
        let dx = (o.x_min - self.x_max).max(self.x_min - o.x_max).max(0.0);
        let dy = (o.y_min - self.y_max).max(self.y_min - o.y_max).max(0.0);
        dx.hypot(dy)
    }

    /// Distance from `p` to the rectangle, 0 inside.
    pub fn distance_to(&self, p: Vec2) -> f64 {
        let dx = (self.x_min - p.x).max(p.x - self.x_max).max(0.0);
        let dy = (self.y_min - p.y).max(p.y - self.y_max).max(0.0);
        dx.hypot(dy)
    }

    pub fn corners(&self) -> [Vec2; 4] {
        [
            Vec2::new(self.x_min, self.y_min),
            Vec2::new(self.x_max, self.y_min),
            Vec2::new(self.x_max, self.y_max),
            Vec2::new(self.x_min, self.y_max),
        ]
    }

    pub fn is_finite(&self) -> bool {
        self.x_min.is_finite() && self.x_max.is_finite() && self.y_min.is_finite() && self.y_max.is_finite()
    }
}

/// Wraps an angle to (−π, π].
#[inline]
pub fn wrap_pi(a: f64) -> f64 {
    let two_pi = std::f64::consts::TAU;
    let mut r = a.rem_euclid(two_pi);
    if r > std::f64::consts::PI {
        r -= two_pi;
    }
    r
}
