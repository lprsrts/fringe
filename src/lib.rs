//! Full-wave 2D electromagnetics (Ez polarisation) for optical scenes: a lens, a
//! slit, a grating, solved with FDTD, FEM or MoM and rendered to images.

pub mod analytic;
pub mod check;
pub mod detectors;
pub mod ffi;
pub mod geometry;
pub mod job;
pub mod linalg;
pub mod problem;
pub mod render;
pub mod scene;
pub mod solver;
pub mod source;
pub mod special;
pub mod types;

pub use check::{check, CheckReport};
pub use scene::{parse_scene, Scene};
pub use solver::{solve, FieldGrid, Method, Quality};
pub use types::{Rect, Vec2, C64};
