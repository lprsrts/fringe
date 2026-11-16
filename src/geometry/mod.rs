//! Element geometry: boundary segments, closed contours and bodies.

pub mod body;
pub mod curve;
pub mod intersect;
pub mod shapes;

pub use body::{signed_area, Body, BodyMaterial, Contour};
pub use curve::Segment;
pub use intersect::{
    contour_gap, min_gap, polygon_min_width, polygon_self_intersects, segment_distance, segments_intersect,
    MAX_POLYGON_VERTICES,
};
pub use shapes::{bodies_from_scene, element_bodies, lens_surface_x, local_contours, mirror_surface_x};
