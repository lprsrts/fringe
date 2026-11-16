//! Reflection of any incident field by an infinite PEC plane x = x_plane.

use crate::source::Incident;
use crate::types::{Vec2, C64};

/// Total field in front of a PEC plane at x = `x_plane`: Ez is odd about it.
pub fn pec_plane_image(inc: &Incident, x_plane: f64, p: Vec2) -> C64 {
    inc.eval(p) - inc.eval(Vec2::new(2.0 * x_plane - p.x, p.y))
}
