import AppKit
import CoreGraphics
import Foundation

/// The colour legend: the colormap and what its ends mean.
public struct Legend: Sendable {
    public var lut: [UInt8]
    public var title: String
    public var low: String
    public var middle: String?
    public var high: String

    public init(lut: [UInt8], display: DisplaySettings) {
        self.lut = lut
        let q = display.quantity
        let incident = display.normalization == .incident
        let fixed = display.normalization == .fixed
        let s = SceneFormat.fixed(display.normalizationValue, 2)
        switch q {
        case .intensity, .magnitude:
            if let db = display.logDb, display.usesLogScale {
                title = "\(q.symbol), dB"
                low = "−\(SceneFormat.fixed(db, 0))"
                high = "0"
            } else {
                title = q.symbol + (incident ? (q == .intensity ? " / A²" : " / A") : "")
                low = "0"
                if incident {
                    high = "1"
                } else if fixed {
                    high = q == .intensity ? "\(s)² A²" : "\(s) A"
                } else {
                    high = "max"
                }
            }
            middle = nil
        case .real:
            title = "Re E" + (incident ? " / A" : "")
            let edge = incident ? "1" : (fixed ? "\(s) A" : "max")
            low = "−" + edge
            middle = "0"
            high = "+" + edge
        case .phase:
            title = "∠E"
            low = "−180°"
            middle = "0°"
            high = "180°"
        }
    }
}

/// Everything the vector overlays need, as a value that can go to another thread.
public struct OverlayModel: Sendable {
    /// The plane rectangle the image covers.
    public var viewRect: RectUm
    /// The domain interior; the PML lies around it.
    public var interior: RectUm
    public var pmlUm: Double
    public var outlines: SceneOutlines?
    public var source: Source
    /// Paraxial focus points, [x, y] in µm.
    public var focusPoints: [[Double]]
    public var display: DisplaySettings
    public var caption: String?
    public var legend: Legend?
    public var selectedID: String?
    /// Preview only: the move handle on the selection and the beam's handles.
    public var showsHandles: Bool
    /// Element anchors, [x, y] in µm, for the move handle.
    public var anchors: [String: [Double]]
    /// Bodies of the scene the field was solved for, whose conductors are filled; nil
    /// fills the conductors of `outlines`.
    public var conductors: SceneOutlines? = nil
}

/// Draws the vector overlays (outlines, source glyph, focus marks, PML hatch, scale bar,
/// caption and legend) over the rendered field. The canvas and the exported PNG both draw
/// through `drawOverlays`.
public enum VectorRenderer {
    /// Draws every enabled overlay into `context`, using a top-left origin.
    ///
    /// Pass `flipped: true` for a bitmap context, whose origin is at the bottom left. A SwiftUI
    /// canvas context already has a top-left origin. Line widths and text scale with the image
    /// height, so a 4K export looks like the preview, only sharper.
    ///
    /// On screen the image is often only a few hundred points high, where text at export
    /// proportion would be unreadable, so the preview passes a `minimumTextScale` of 1.
    public static func drawOverlays(
        in context: CGContext,
        size: CGSize,
        flipped: Bool,
        model: OverlayModel,
        minimumTextScale: CGFloat = 0
    ) {
        let display = model.display
        guard size.width > 0, size.height > 0 else { return }

        let scale = size.height / 720.0
        let painter = OverlayPainter(
            context: context,
            bounds: CGRect(origin: .zero, size: size),
            scale: scale,
            textScale: max(scale, minimumTextScale),
            map: PlaneMapping(viewRect: model.viewRect, bounds: CGRect(origin: .zero, size: size)),
            model: model
        )

        context.saveGState()
        if flipped {
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1.0, y: -1.0)
        }
        // Text is drawn through AppKit, which needs to know the context is y-down.
        let previousNSContext = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer {
            NSGraphicsContext.current = previousNSContext
            context.restoreGState()
        }
        context.clip(to: CGRect(origin: .zero, size: size))

        // Conductors are solid whatever the overlays: the field inside them is zero, and a
        // vector fill gives them the exact outline the raster cannot.
        painter.fillConductors()
        guard display.showOverlays else { return }

        if display.showPML { painter.drawPML() }
        if display.showOutlines { painter.drawOutlines() }
        if display.showParaxialFocus { painter.drawFocusPoints() }
        if display.showSourceGlyph { painter.drawSource() }
        if display.showCaption { painter.drawCaption() }
        let legendTop = display.showLegend ? painter.drawLegend() : nil
        if display.showScaleBar { painter.drawScaleBar(above: legendTop) }
    }

    /// A 1-2-5 × 10ⁿ length close to `target`.
    public static func niceLength(_ target: Double) -> Double {
        guard target > 0, target.isFinite else { return 1 }
        let exponent = floor(log10(target))
        let base = pow(10, exponent)
        let mantissa = target / base
        let nice: Double = mantissa < 1.5 ? 1 : (mantissa < 3.5 ? 2 : (mantissa < 7.5 ? 5 : 10))
        return nice * base
    }

    /// Where the beam glyph's angle handle sits, in µm, for a Gaussian beam.
    public static func angleHandle(source: Source, viewRect: RectUm) -> (x: Double, y: Double) {
        let length = beamArrowLength(source: source, viewRect: viewRect)
        let a = source.angleDeg * .pi / 180
        return (source.waistXUm + length * cos(a), source.waistYUm + length * sin(a))
    }

    static func beamArrowLength(source: Source, viewRect: RectUm) -> Double {
        max(2.5 * source.waistUm, 0.12 * viewRect.width)
    }

    /// The same grey the core uses for conductors.
    static let conductorColor = CGColor(srgbRed: 128.0 / 255, green: 128.0 / 255, blue: 128.0 / 255, alpha: 1)

    static let beamColor = CGColor(red: 0.35, green: 0.9, blue: 1.0, alpha: 0.95)
}

/// One pass of overlay drawing into a y-down context.
private struct OverlayPainter {
    let context: CGContext
    let bounds: CGRect
    /// Multiplier for line widths, dash lengths and offsets.
    let scale: CGFloat
    /// Multiplier for font sizes and the spacing between lines of text.
    let textScale: CGFloat
    let map: PlaneMapping
    let model: OverlayModel

    private var margin: CGFloat { 20 * scale }

    private func stroke(_ path: CGPath, color: CGColor, width: CGFloat, dash: [CGFloat] = [], fixedWidth: Bool = false) {
        context.saveGState()
        context.addPath(path)
        context.setStrokeColor(color)
        // A fixed-width line keeps fixed dashes; scaled dashes on it close up in a
        // small image. Dashes get butt caps, since round caps eat into the gaps.
        context.setLineWidth(fixedWidth ? width : width * scale)
        context.setLineDash(phase: 0, lengths: dash.map { fixedWidth ? $0 : $0 * scale })
        context.setLineCap(dash.isEmpty ? .round : .butt)
        context.setLineJoin(.round)
        context.strokePath()
        context.restoreGState()
    }

    private func fill(_ path: CGPath, color: CGColor, evenOdd: Bool = false) {
        context.saveGState()
        context.addPath(path)
        context.setFillColor(color)
        context.fillPath(using: evenOdd ? .evenOdd : .winding)
        context.restoreGState()
    }

    private func line(from a: CGPoint, to b: CGPoint) -> CGPath {
        let path = CGMutablePath()
        path.move(to: a)
        path.addLine(to: b)
        return path
    }

    private func attributes(size: CGFloat, weight: NSFont.Weight, color: NSColor) -> [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.7)
        shadow.shadowBlurRadius = 3 * textScale
        shadow.shadowOffset = .zero
        return [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size * textScale, weight: weight),
            .foregroundColor: color,
            .shadow: shadow,
        ]
    }

    private func textSize(_ string: String, size: CGFloat, weight: NSFont.Weight = .regular) -> CGSize {
        (string as NSString).size(withAttributes: attributes(size: size, weight: weight, color: .white))
    }

    /// Draws `string` with its top-left corner at `point`, or anchored by `alignment`.
    private func text(
        _ string: String,
        at point: CGPoint,
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        color: NSColor = NSColor(calibratedWhite: 1, alpha: 0.9),
        alignment: (x: CGFloat, y: CGFloat) = (0, 0)
    ) {
        let attrs = attributes(size: size, weight: weight, color: color)
        let measured = (string as NSString).size(withAttributes: attrs)
        let origin = CGPoint(x: point.x - alignment.x * measured.width, y: point.y - alignment.y * measured.height)
        (string as NSString).draw(at: origin, withAttributes: attrs)
    }

    /// A soft dark backing so labels stay legible over light colormaps.
    private func plate(_ rect: CGRect) {
        let r = rect.insetBy(dx: -6 * textScale, dy: -4 * textScale)
        fill(CGPath(roundedRect: r, cornerWidth: 6 * textScale, cornerHeight: 6 * textScale, transform: nil),
             color: CGColor(gray: 0, alpha: 0.38))
    }

    // MARK: PML

    func drawPML() {
        let interior = map.rect(model.interior)
        let outer = map.rect(model.interior.insetBy(-model.pmlUm))
        let band = CGMutablePath()
        band.addRect(outer)
        band.addRect(interior)
        fill(band, color: CGColor(gray: 0.08, alpha: 0.55), evenOdd: true)

        context.saveGState()
        context.addPath(band)
        context.clip(using: .evenOdd)
        let hatch = CGMutablePath()
        let step = 8 * scale
        var x = outer.minX - outer.height
        while x < outer.maxX {
            hatch.move(to: CGPoint(x: x, y: outer.maxY))
            hatch.addLine(to: CGPoint(x: x + outer.height, y: outer.minY))
            x += step
        }
        stroke(hatch, color: CGColor(gray: 1, alpha: 0.18), width: 1)
        context.restoreGState()

        stroke(CGPath(rect: interior, transform: nil), color: CGColor(gray: 1, alpha: 0.45), width: 1, dash: [4, 4])
        text("PML", at: CGPoint(x: outer.minX + 4 * scale, y: outer.minY + 2 * scale), size: 9, color: NSColor(calibratedWhite: 1, alpha: 0.6))
    }

    // MARK: Bodies

    private func path(_ outline: [[Double]]) -> CGPath {
        let path = CGMutablePath()
        let points = outline.map { map.point($0) }
        guard let first = points.first else { return path }
        path.move(to: first)
        for p in points.dropFirst() { path.addLine(to: p) }
        path.closeSubpath()
        return path
    }

    func fillConductors() {
        guard let outlines = model.conductors ?? model.outlines else { return }
        for body in outlines.bodies where body.pec && body.enabled {
            fill(path(body.outline), color: VectorRenderer.conductorColor)
        }
    }

    func drawOutlines() {
        guard let outlines = model.outlines else { return }
        // Disabled elements are not part of the solve: a dashed outline only.
        for body in outlines.bodies where body.elementId != model.selectedID {
            stroke(path(body.outline), color: CGColor(gray: 1, alpha: body.enabled ? 0.6 : 0.5), width: 1.5,
                   dash: body.enabled ? [] : [5, 4])
        }
        guard let selected = model.selectedID else { return }
        let accent = NSColor.controlAccentColor.cgColor
        for body in outlines.bodies(of: selected) {
            // Fixed width on screen, so the selection reads the same at any size.
            stroke(path(body.outline), color: accent, width: 2.5, dash: body.enabled ? [] : [6, 4], fixedWidth: true)
        }
        if model.showsHandles, let anchor = model.anchors[selected] {
            let p = map.point(anchor)
            let r: CGFloat = 5
            let handle = CGPath(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r), transform: nil)
            fill(handle, color: accent)
            stroke(handle, color: CGColor(gray: 1, alpha: 0.9), width: 1.5, fixedWidth: true)
        }
    }

    func drawFocusPoints() {
        let color = CGColor(gray: 1, alpha: 0.75)
        for f in model.focusPoints {
            let p = map.point(f)
            let r = 7 * scale
            let cross = CGMutablePath()
            cross.move(to: CGPoint(x: p.x - r, y: p.y))
            cross.addLine(to: CGPoint(x: p.x + r, y: p.y))
            cross.move(to: CGPoint(x: p.x, y: p.y - r))
            cross.addLine(to: CGPoint(x: p.x, y: p.y + r))
            stroke(cross, color: color, width: 1.2, dash: [2, 2])
            text("f", at: CGPoint(x: p.x + r + 2 * scale, y: p.y - r - 2 * scale), size: 9, weight: .semibold,
                 color: NSColor(calibratedWhite: 1, alpha: 0.75), alignment: (0, 0.5))
        }
    }

    // MARK: Source

    func drawSource() {
        let source = model.source
        let a = source.angleDeg * .pi / 180
        let dir = (x: cos(a), y: sin(a))
        let color = VectorRenderer.beamColor

        switch source.kind {
        case .gaussianBeam:
            let waist = map.point(x: source.waistXUm, y: source.waistYUm)
            let w0 = source.waistUm
            let normal = (x: -dir.y, y: dir.x)
            // The waist: a bar ±w0 across the axis with end ticks.
            let top = map.point(x: source.waistXUm + w0 * normal.x, y: source.waistYUm + w0 * normal.y)
            let bottom = map.point(x: source.waistXUm - w0 * normal.x, y: source.waistYUm - w0 * normal.y)
            let bar = CGMutablePath()
            bar.move(to: top)
            bar.addLine(to: bottom)
            let tick = 5 * scale
            let along = CGVector(dx: CGFloat(dir.x) * tick, dy: -CGFloat(dir.y) * tick)
            for end in [top, bottom] {
                bar.move(to: CGPoint(x: end.x - along.dx, y: end.y - along.dy))
                bar.addLine(to: CGPoint(x: end.x + along.dx, y: end.y + along.dy))
            }
            stroke(bar, color: color, width: 1.5)

            // The axis arrow from the waist.
            let handle = VectorRenderer.angleHandle(source: source, viewRect: model.viewRect)
            let tip = map.point(x: handle.x, y: handle.y)
            drawArrow(from: waist, to: tip, color: color)
            let r: CGFloat = 4 * max(1, scale)
            fill(CGPath(ellipseIn: CGRect(x: waist.x - r, y: waist.y - r, width: 2 * r, height: 2 * r), transform: nil), color: color)
            if model.showsHandles {
                let h = CGPath(ellipseIn: CGRect(x: tip.x - 4.5, y: tip.y - 4.5, width: 9, height: 9), transform: nil)
                fill(h, color: CGColor(gray: 0.1, alpha: 0.8))
                stroke(h, color: color, width: 1.5, fixedWidth: true)
            }
            text("w₀", at: CGPoint(x: top.x + 6 * scale, y: top.y), size: 9, weight: .semibold,
                 color: NSColor(cgColor: color) ?? .cyan, alignment: (0, 1))

        case .planeWave:
            // A k-arrow inside the upstream edge of the domain.
            let interior = model.interior
            let extent = 0.5 * interior.width * abs(dir.x) + 0.5 * interior.height * abs(dir.y)
            let length = 0.05 * (interior.width + interior.height)
            let back = extent - 0.03 * (interior.width + interior.height)
            let start = (x: interior.centerX - dir.x * back, y: interior.centerY - dir.y * back)
            let normal = (x: -dir.y, y: dir.x)
            let spread = 0.18 * min(interior.width, interior.height)
            for offset in [-spread, 0, spread] {
                let s = map.point(x: start.x + normal.x * offset, y: start.y + normal.y * offset)
                let e = map.point(x: start.x + normal.x * offset + dir.x * length, y: start.y + normal.y * offset + dir.y * length)
                drawArrow(from: s, to: e, color: offset == 0 ? color : color.copy(alpha: 0.5) ?? color)
                if offset == 0 {
                    text("k", at: CGPoint(x: e.x + 4 * scale, y: e.y), size: 10, weight: .semibold,
                         color: NSColor(cgColor: color) ?? .cyan, alignment: (0, 1))
                }
            }
        }
    }

    private func drawArrow(from a: CGPoint, to b: CGPoint, color: CGColor) {
        stroke(line(from: a, to: b), color: color, width: 1.5)
        let dx = b.x - a.x
        let dy = b.y - a.y
        let len = max(1e-6, (dx * dx + dy * dy).squareRoot())
        let ux = dx / len
        let uy = dy / len
        let head = 7 * scale
        let wing = 3.5 * scale
        let path = CGMutablePath()
        path.move(to: b)
        path.addLine(to: CGPoint(x: b.x - ux * head - uy * wing, y: b.y - uy * head + ux * wing))
        path.addLine(to: CGPoint(x: b.x - ux * head + uy * wing, y: b.y - uy * head - ux * wing))
        path.closeSubpath()
        fill(path, color: color)
    }

    // MARK: Scale bar, caption, legend

    func drawScaleBar(above legendTop: CGFloat?) {
        let length = VectorRenderer.niceLength(0.15 * model.viewRect.width)
        let width = CGFloat(length) * map.scale
        guard width > 4 else { return }
        let right = bounds.maxX - margin
        let y = (legendTop.map { $0 - 20 * textScale } ?? bounds.maxY - margin)
        let label = length >= 1 ? "\(SceneFormat.fixed(length, 0)) µm" : "\(SceneFormat.fixed(length * 1000, 0)) nm"
        let labelSize = textSize(label, size: 10, weight: .medium)
        plate(CGRect(x: right - width, y: y - 6 * scale - labelSize.height, width: width, height: labelSize.height + 6 * scale + 4 * scale))
        let bar = CGMutablePath()
        bar.move(to: CGPoint(x: right - width, y: y))
        bar.addLine(to: CGPoint(x: right, y: y))
        let tick = 4 * scale
        bar.move(to: CGPoint(x: right - width, y: y - tick))
        bar.addLine(to: CGPoint(x: right - width, y: y + tick))
        bar.move(to: CGPoint(x: right, y: y - tick))
        bar.addLine(to: CGPoint(x: right, y: y + tick))
        stroke(bar, color: CGColor(gray: 0, alpha: 0.5), width: 4)
        stroke(bar, color: CGColor(gray: 1, alpha: 0.9), width: 1.5)
        text(label, at: CGPoint(x: right - width / 2, y: y - 6 * scale), size: 10, weight: .medium, alignment: (0.5, 1))
    }

    func drawCaption() {
        guard let caption = model.caption else { return }
        let size = textSize(caption, size: 10, weight: .medium)
        plate(CGRect(x: bounds.minX + margin, y: bounds.maxY - margin - size.height, width: size.width, height: size.height))
        text(caption, at: CGPoint(x: bounds.minX + margin, y: bounds.maxY - margin), size: 10, weight: .medium,
             color: NSColor(calibratedWhite: 1, alpha: 0.85), alignment: (0, 1))
    }

    /// Draws the colour bar at the bottom right and returns the top of what it drew.
    func drawLegend() -> CGFloat? {
        guard let legend = model.legend, legend.lut.count >= 1024,
              let provider = CGDataProvider(data: Data(legend.lut) as CFData),
              let strip = CGImage(
                width: 256, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 1024,
                space: BeamBridge.colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              ) else { return nil }
        let labelHeight = textSize("0", size: 9).height
        let width = 150 * textScale
        let height = 8 * textScale
        let right = bounds.maxX - margin
        let bottom = bounds.maxY - margin - labelHeight - 2 * textScale
        let rect = CGRect(x: right - width, y: bottom - height, width: width, height: height)
        let titleHeight = textSize(legend.title, size: 9, weight: .semibold).height
        plate(CGRect(x: rect.minX, y: rect.minY - 3 * textScale - titleHeight, width: width,
                     height: titleHeight + 3 * textScale + height + 2 * textScale + labelHeight))

        context.saveGState()
        context.interpolationQuality = .high
        context.draw(strip, in: rect)
        context.restoreGState()
        stroke(CGPath(rect: rect, transform: nil), color: CGColor(gray: 1, alpha: 0.5), width: 0.75)

        let labelY = rect.maxY + 2 * textScale
        text(legend.low, at: CGPoint(x: rect.minX, y: labelY), size: 9)
        if let middle = legend.middle {
            text(middle, at: CGPoint(x: rect.midX, y: labelY), size: 9, alignment: (0.5, 0))
        }
        text(legend.high, at: CGPoint(x: rect.maxX, y: labelY), size: 9, alignment: (1, 0))
        text(legend.title, at: CGPoint(x: rect.minX, y: rect.minY - 3 * textScale), size: 9, weight: .semibold, alignment: (0, 1))
        return rect.minY - 3 * textScale - labelHeight
    }
}
