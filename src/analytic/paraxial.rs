//! The 2D paraxial Gaussian beam, used only to check the exact incident field in
//! its paraxial limit.

use crate::types::{C64, J};

/// `E = A √(j z_R/(ξ + j z_R)) exp(−jkξ − jkη²/(2(ξ + j z_R)))`, z_R = k w0²/2,
/// with ξ along the axis from the waist and η across it.
pub fn paraxial_gaussian(amplitude: f64, k: f64, w0: f64, xi: f64, eta: f64) -> C64 {
    let z_r = 0.5 * k * w0 * w0;
    let q = C64::new(xi, z_r);
    amplitude * (J * z_r / q).sqrt() * (-J * k * xi - J * k * eta * eta / (2.0 * q)).exp()
}
