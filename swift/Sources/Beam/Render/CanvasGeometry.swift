import CoreGraphics
import Foundation

/// Where the image sits in the canvas area, and how view points map to the plane in µm.
/// y points up in the plane and down in the view.
public struct CanvasGeometry: Equatable {
    public static let padding: CGFloat = 24

    public var container: CGSize
    public var aspect: OutputAspect
    /// The plane rectangle the image shows.
    public var viewRect: RectUm

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

    /// Points per micrometre.
    public var scale: CGFloat {
        guard viewRect.width > 0 else { return 1 }
        return imageRect.width / CGFloat(viewRect.width)
    }

    public func viewPoint(x: Double, y: Double) -> CGPoint {
        PlaneMapping(viewRect: viewRect, bounds: imageRect).point(x: x, y: y)
    }

    public func planePoint(_ point: CGPoint) -> (x: Double, y: Double) {
        let rect = imageRect
        guard rect.width > 0, rect.height > 0 else { return (viewRect.centerX, viewRect.centerY) }
        return (
            viewRect.xMin + Double((point.x - rect.minX) / rect.width) * viewRect.width,
            viewRect.yMax - Double((point.y - rect.minY) / rect.height) * viewRect.height
        )
    }

    /// The view rectangle a plane rectangle occupies.
    public func viewRect(for plane: RectUm) -> CGRect {
        PlaneMapping(viewRect: viewRect, bounds: imageRect).rect(plane)
    }

    /// Plane displacement for a view translation (y flipped).
    public func planeDelta(_ translation: CGSize) -> (dx: Double, dy: Double) {
        let s = Double(scale)
        guard s > 0 else { return (0, 0) }
        return (Double(translation.width) / s, -Double(translation.height) / s)
    }

    public func micrometres(forPoints points: CGFloat) -> Double {
        let s = scale
        return s > 0 ? Double(points / s) : 0
    }
}

/// Maps a plane rectangle onto a y-down drawing rectangle.
public struct PlaneMapping: Sendable {
    public var viewRect: RectUm
    public var bounds: CGRect

    public func point(x: Double, y: Double) -> CGPoint {
        CGPoint(
            x: bounds.minX + CGFloat((x - viewRect.xMin) / viewRect.width) * bounds.width,
            y: bounds.minY + CGFloat((viewRect.yMax - y) / viewRect.height) * bounds.height
        )
    }

    public func point(_ p: [Double]) -> CGPoint {
        p.count == 2 ? point(x: p[0], y: p[1]) : .zero
    }

    public func rect(_ plane: RectUm) -> CGRect {
        let a = point(x: plane.xMin, y: plane.yMax)
        let b = point(x: plane.xMax, y: plane.yMin)
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    /// Points per micrometre.
    public var scale: CGFloat {
        viewRect.width > 0 ? bounds.width / CGFloat(viewRect.width) : 1
    }
}
