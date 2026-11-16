import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ExportError: LocalizedError {
    case invalidDimensions
    case rasterGenerationFailed
    case contextCreationFailed
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .invalidDimensions:
            return "Width and height must be between 1 and 16384 pixels."
        case .rasterGenerationFailed:
            return "Could not render the image."
        case .contextCreationFailed:
            return "Could not allocate an image of that size."
        case .encodingFailed:
            return "Could not encode the image as PNG."
        }
    }
}

public enum ImageExportService {
    /// Renders the raster, draws the overlays over it and encodes the result as PNG.
    public static func pngData(for export: PNGExport) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try render(export)
        }.value
    }

    private static func render(_ export: PNGExport) throws -> Data {
        let width = export.width
        let height = export.height
        guard (1...16384).contains(width), (1...16384).contains(height) else {
            throw ExportError.invalidDimensions
        }

        guard let raster = BeamBridge.renderRaster(
            params: export.beam.cParams,
            elements: export.elements.filter(\.isEnabled).sorted { $0.z < $1.z }.map(\.cPlacedElement),
            style: export.style.cStyle,
            zMin: export.framing.effectiveZMin,
            zMax: export.framing.effectiveZMax,
            xMax: export.framing.effectiveXMax,
            width: width,
            height: height
        ) else {
            throw ExportError.rasterGenerationFailed
        }

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: BeamBridge.colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ExportError.contextCreationFailed
        }

        let size = CGSize(width: width, height: height)
        context.draw(raster, in: CGRect(origin: .zero, size: size))
        VectorRenderer.drawOverlays(
            in: context,
            size: size,
            flipped: true,
            beam: export.beam,
            elements: export.elements,
            style: export.style,
            framing: export.framing
        )

        guard let image = context.makeImage() else {
            throw ExportError.contextCreationFailed
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw ExportError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.encodingFailed
        }
        return data as Data
    }
}
