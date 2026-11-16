import CoreGraphics
import Foundation

/// Where the image sits in the canvas area, and how view points map to the (z, x) plane.
public struct CanvasGeometry: Equatable {
    public static let padding: CGFloat = 24
    /// Horizontal distance from a glyph, in points, that still counts as a hit.
    public static let hitTolerance: CGFloat = 6

    public var container: CGSize
    public var aspect: OutputAspect
    public var framing: FramingModel

    public var imageRect: CGRect {
        guard let ratio = aspect.ratio else {
            return CGRect(origin: .zero, size: container)
        }
        let available = CGSize(
            width: max(1, container.width - 2 * Self.padding),
            height: max(1, container.height - 2 * Self.padding)
        )
        let size: CGSize
        if available.width / available.height > CGFloat(ratio) {
            size = CGSize(width: available.height * CGFloat(ratio), height: available.height)
        } else {
            size = CGSize(width: available.width, height: available.width / CGFloat(ratio))
        }
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    public func viewX(forZ z: Double) -> CGFloat {
        VectorRenderer.mapZToX(z: z, zMin: framing.effectiveZMin, zMax: framing.effectiveZMax, bounds: imageRect)
    }

    public func z(forViewX x: CGFloat) -> Double {
        let rect = imageRect
        guard rect.width > 0 else { return framing.centerZ }
        return framing.effectiveZMin + Double((x - rect.minX) / rect.width) * framing.effectiveSpanZ
    }

    /// Change in z for a horizontal movement of `dx` points.
    public func deltaZ(forDeltaX dx: CGFloat) -> Double {
        let width = imageRect.width
        guard width > 0 else { return 0 }
        return Double(dx / width) * framing.effectiveSpanZ
    }

    /// The enabled element whose glyph is nearest to `point`, if any is within reach.
    public func hitTestElement(at point: CGPoint, in elements: [PlacedElementModel]) -> UUID? {
        let rect = imageRect
        guard rect.contains(point) else { return nil }
        return elements
            .filter { $0.isEnabled }
            .map { (id: $0.id, distance: abs(viewX(forZ: $0.z) - point.x)) }
            .filter { $0.distance <= Self.hitTolerance }
            .min { $0.distance < $1.distance }?
            .id
    }
}
