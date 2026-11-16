//! Full-wave 2D electromagnetics (Ez polarisation) for optical scenes: a lens, a
//! slit, a grating, solved with FDTD, FEM or MoM and rendered to images.

pub mod geometry;
pub mod linalg;
pub mod scene;
pub mod solver;
pub mod types;

pub use scene::{parse_scene, Scene};
pub use solver::{Method, Quality};
pub use types::{Rect, Vec2, C64};
