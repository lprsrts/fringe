//! Gaussian beam propagation through paraxial optical systems, and rendering of
//! the resulting intensity fields to RGBA buffers and PNG files.
//!
//! The C ABI used by the macOS app lives in [`ffi`].

pub mod ffi;
pub mod physics;
pub mod render;

pub use ffi::*;
pub use physics::{
    AbcdMatrix, Complex, ComplexAbcdMatrix, GaussianBeam, OpticalElement, OpticalTrain,
    PlacedElement,
};
pub use render::*;
