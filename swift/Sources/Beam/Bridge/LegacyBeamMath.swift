import Foundation

/// Paraxial Gaussian-beam formulas the v1 overlays still draw with. The core no
/// longer has them; this file goes when the overlays are rewritten for v2.
public enum LegacyBeamMath {
    /// Rayleigh range z_R = π n w0² / λ.
    public static func rayleighRange(w0: Double, wavelength: Double, refractiveIndex: Double = 1.0) -> Double {
        guard w0 > 0, wavelength > 0, refractiveIndex > 0 else { return 0 }
        return Double.pi * refractiveIndex * w0 * w0 / wavelength
    }

    /// Beam radius w(z) = w0 √(1 + (z/z_R)²).
    public static func waistAt(w0: Double, z: Double, zR: Double) -> Double {
        guard zR > 0 else { return w0 }
        return w0 * (1.0 + (z / zR) * (z / zR)).squareRoot()
    }

    /// Wavefront curvature κ(z) = z / (z² + z_R²), i.e. 1/R(z).
    public static func curvatureAt(z: Double, zR: Double) -> Double {
        let d = z * z + zR * zR
        return d > 0 ? z / d : 0
    }
}
