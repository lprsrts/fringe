import Foundation
import CoreGraphics
import CBeamCore

/// Swift wrappers for the `beam_core` C functions.
public enum BeamBridge {
    /// The colormap tables are sRGB, so the raster and the exported PNG are tagged as such
    /// and look the same on a wide-gamut display as in the preview.
    public static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Renders the intensity in the (z, x) plane into a `CGImage`.
    /// Returns nil for empty or overflowing dimensions, or if the core rejects the input.
    public static func renderRaster(
        params: CBeamParams,
        elements: [CPlacedElement] = [],
        style: CRenderStyle,
        zMin: Double,
        zMax: Double,
        xMax: Double,
        width: Int,
        height: Int
    ) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        guard let uWidth = UInt32(exactly: width),
              let uHeight = UInt32(exactly: height) else {
            return nil
        }

        let bytesPerPixel = 4
        let (bytesPerRow, overflow0) = width.multipliedReportingOverflow(by: bytesPerPixel)
        guard !overflow0 else { return nil }
        let (totalPixels, overflow1) = width.multipliedReportingOverflow(by: height)
        guard !overflow1 else { return nil }
        let (bufferSize, overflow2) = totalPixels.multipliedReportingOverflow(by: bytesPerPixel)
        guard !overflow2, let uBufferSize = UInt32(exactly: bufferSize) else { return nil }

        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        var beamCopy = params
        var styleCopy = style

        let success: Bool
        if elements.isEmpty {
            success = beam_render_longitudinal_rgba(
                &beamCopy,
                nil,
                0,
                &styleCopy,
                zMin,
                zMax,
                xMax,
                uWidth,
                uHeight,
                buffer,
                uBufferSize
            )
        } else {
            guard let uElementCount = UInt32(exactly: elements.count) else {
                buffer.deallocate()
                return nil
            }
            success = elements.withUnsafeBufferPointer { elemPtr in
                beam_render_longitudinal_rgba(
                    &beamCopy,
                    elemPtr.baseAddress,
                    uElementCount,
                    &styleCopy,
                    zMin,
                    zMax,
                    xMax,
                    uWidth,
                    uHeight,
                    buffer,
                    uBufferSize
                )
            }
        }

        guard success else {
            buffer.deallocate()
            return nil
        }

        // The image takes ownership of the buffer and frees it when released.
        guard let provider = CGDataProvider(
            dataInfo: nil,
            data: buffer,
            size: bufferSize,
            releaseData: { _, data, _ in
                UnsafeMutableRawPointer(mutating: data).deallocate()
            }
        ) else {
            buffer.deallocate()
            return nil
        }

        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: Self.colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    /// Rayleigh range z_R = π n w0² / λ, in metres.
    public static func rayleighRange(w0: Double, wavelength: Double, refractiveIndex: Double = 1.0) -> Double {
        beam_calc_rayleigh_range(w0, wavelength, refractiveIndex)
    }

    /// Beam radius w(z) = w0 √(1 + (z/z_R)²).
    public static func waistAt(w0: Double, z: Double, zR: Double) -> Double {
        beam_calc_waist_at_z(w0, z, zR)
    }

    /// Wavefront curvature κ(z) = z / (z² + z_R²), i.e. 1/R(z).
    public static func curvatureAt(z: Double, zR: Double) -> Double {
        beam_calc_curvature_at_z(z, zR)
    }
}
