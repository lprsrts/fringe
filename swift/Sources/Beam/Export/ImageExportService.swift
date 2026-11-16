import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ExportError: LocalizedError {
    case invalidDimensions
    case nothingToExport
    case rasterGenerationFailed(String)
    case contextCreationFailed
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .invalidDimensions:
            return "Width and height must be between 1 and 16384 pixels."
        case .nothingToExport:
            return "There is no solved field to export yet."
        case .rasterGenerationFailed(let reason):
            return "Couldn't render the image: \(reason)"
        case .contextCreationFailed:
            return "Couldn't allocate an image of that size."
        case .encodingFailed:
            return "Couldn't encode the image as PNG."
        }
    }
}

public enum ImageExportService {
    /// Renders the field, draws the overlays over it and encodes the result as PNG.
    public static func pngData(for export: PNGExport) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try renderPNG(export)
        }.value
    }

    /// The same, on the calling thread.
    public static func renderPNG(_ export: PNGExport) throws -> Data {
        let width = export.width
        let height = export.height
        guard (1...16384).contains(width), (1...16384).contains(height) else {
            throw ExportError.invalidDimensions
        }
        guard let field = export.field else { throw ExportError.nothingToExport }
        let raster: CGImage
        do {
            raster = try field.render(viewJSON: export.viewJSON, width: width, height: height)
        } catch {
            throw ExportError.rasterGenerationFailed(error.localizedDescription)
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
        // Pixels outside the solved grid are transparent in the raster; an exported image
        // gets a black background instead.
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.draw(raster, in: CGRect(origin: .zero, size: size))
        VectorRenderer.drawOverlays(in: context, size: size, flipped: true, model: export.overlay)

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
