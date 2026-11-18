//! Analytic reference solutions, comparison metrics and the validation cases.

pub mod cases;
pub mod image;
pub mod line;
pub mod metrics;
pub mod mie;
pub mod paraxial;
pub mod slab;

pub use image::pec_plane_image;
pub use line::LineCylinder;
pub use mie::MieCylinder;
pub use paraxial::paraxial_gaussian;
pub use slab::AirySlab;
