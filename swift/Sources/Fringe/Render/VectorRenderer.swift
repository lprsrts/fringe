import AppKit
import CoreGraphics
import Foundation

/// The colour legend: the colormap and what its ends mean. The labels may contain `$…$` math.
public struct Legend: Sendable, Equatable {
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
                title = "\(q.mathSymbol), dB"
                low = "−\(SceneFormat.fixed(db, 0))"
                high = "0"
            } else {
                title = q.mathSymbol + (incident ? (q == .intensity ? " / $A^2$" : " / $A$") : "")
                low = "0"
                if incident {
                    high = "1"
                } else if fixed {
                    high = q == .intensity ? "\(s)$^2\\,A^2$" : "\(s) $A$"
                } else {
                    high = "max"
                }
            }
            middle = nil
        case .real:
            title = q.mathSymbol + (incident ? " / $A$" : "")
            let edge = incident ? "1" : (fixed ? "\(s) $A$" : "max")
            low = "−" + edge
            middle = "0"
            high = "+" + edge
        case .phase:
            title = q.mathSymbol
            low = "−180°"
            middle = "0°"
            high = "180°"
        }
    }
}

/// The selected source, element or detector, drawn in the accent colour.
public enum OverlaySelection: Equatable, Sendable {
    case element(String)
    case source(String)
    case detector(String)
}

/// Everything the vector overlays need, as a value that can go to another thread.
public struct OverlayModel: Sendable, Equatable {
    /// The plane rectangle the image covers.
    public var viewRect: RectUm
    /// The domain interior; the PML lies around it.
    public var interior: RectUm
    public var pmlUm: Double
    public var outlines: SceneOutlines?
    /// Disabled ones are drawn dashed; the export leaves them out.
    public var sources: [Source]
    public var detectors: [Detector] = []
    /// The plate text beside each detector ("Output 0.82×"), by id.
    public var detectorLabels: [String: String] = [:]
    /// The readings belong to an older field: their plates are dimmed.
    public var readingsStale = false
    /// Paraxial focus points, [x, y] in µm.
    public var focusPoints: [[Double]]
    /// The element each focus point belongs to, in the same order (the canvas moves a
    /// dragged element's focus with it); not drawn, empty where unknown.
    public var focusIDs: [String] = []
    public var display: DisplaySettings
    public var caption: String?
    public var legend: Legend?
    public var selection: OverlaySelection?
    /// Preview only: the move handle on the selection and the beam's handles.
    public var showsHandles: Bool
    /// Element anchors, [x, y] in µm, for the move handle.
    public var anchors: [String: [Double]]
    /// Bodies of the scene the field was solved for, whose conductors are filled; nil
    /// fills the conductors of `outlines`.
    public var conductors: SceneOutlines? = nil
    /// The open puzzle's marks; nil in the simulator and in exports.
    public var puzzle: PuzzleOverlay? = nil

    /// The selected element's id, if an element is selected.
    var selectedElementID: String? {
        if case .element(let id) = selection { return id }
        return nil
    }
}

/// What a puzzle adds to the canvas: the region parts must stay in (dashed, with a veil
/// outside it), the puzzle's fixed bodies (hatched, with a padlock), letters for the input
/// sources and an amber outline on parts outside the region.
public struct PuzzleOverlay: Sendable, Equatable {
    public var region: RectUm?
    public var lockedIDs: Set<String>
    /// "A", "B" for inputs; other sources by name ("Bias").
    public var sourceLabels: [String: String]
    public var outOfRegionIDs: Set<String>
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
        minimumTextScale: CGFloat = 0,
        parts: OverlayParts = .all
    ) {
        PerfProbe.time("overlay.draw") { drawOverlaysBody(in: context, size: size, flipped: flipped, model: model, minimumTextScale: minimumTextScale, parts: parts) }
    }

    /// Which overlays to draw: the canvas keeps the scene (outlines, sources, detectors,
    /// selection) and the chrome (colour bar, scale bar, caption) in two layers that redraw
    /// on their own inputs; the export draws both in one pass.
    public enum OverlayParts: Sendable {
        case all
        case scene
        case chrome
    }

    private static func drawOverlaysBody(
        in context: CGContext,
        size: CGSize,
        flipped: Bool,
        model: OverlayModel,
        minimumTextScale: CGFloat,
        parts: OverlayParts
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

        if parts != .chrome {
            // Conductors are solid whatever the overlays: the field inside them is zero, and a
            // vector fill gives them the exact outline the raster cannot.
            painter.fillConductors()
        }
        guard display.showOverlays else { return }
        if parts != .chrome { drawScene(painter, display) }
        if parts != .scene { drawChrome(painter, display) }
    }

    private static func drawScene(_ painter: OverlayPainter, _ display: DisplaySettings) {
        let model = painter.model
        if display.showPML { painter.drawPML() }
        if model.puzzle != nil { painter.drawPuzzleRegion() }
        if display.showOutlines {
            painter.drawLockedBodies()
            painter.drawOutlines()
            painter.drawPadlocks()
        }
        if display.showParaxialFocus { painter.drawFocusPoints() }
        if display.showDetectors { painter.drawDetectors() }
        if display.showSourceGlyph { painter.drawSources() }
        if display.showDetectors, display.showReadings { painter.drawDetectorLabels() }
    }

    private static func drawChrome(_ painter: OverlayPainter, _ display: DisplaySettings) {
        // Bottom corners: the colour bar at the right, the scale bar over it (or at the left
        // when a detector runs through that spot), and the caption at the left, lifted over
        // whatever it would run into in a narrow image.
        let legend = display.showLegend ? painter.drawLegend() : nil
        var taken: [CGRect] = legend.map { [$0.plate] } ?? []
        if display.showScaleBar, let bar = painter.drawScaleBar(above: legend?.top, captionAbove: display.showCaption) {
            taken.append(bar)
        }
        if display.showCaption { painter.drawCaption(clearOf: taken) }
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
        return (source.xUm + length * cos(a), source.yUm + length * sin(a))
    }

    static func beamArrowLength(source: Source, viewRect: RectUm) -> Double {
        max(2.5 * source.waistUm, 0.12 * viewRect.width)
    }

    /// The same grey the core uses for conductors.
    static let conductorColor = CGColor(srgbRed: 128.0 / 255, green: 128.0 / 255, blue: 128.0 / 255, alpha: 1)

    static let beamColor = CGColor(red: 0.35, green: 0.9, blue: 1.0, alpha: 0.95)

    static let detectorColor = CGColor(srgbRed: 1, green: 0.76, blue: 0.29, alpha: 0.95)
    /// A part outside a puzzle's region.
    static let warningColor = CGColor(srgbRed: 1, green: 0.62, blue: 0.04, alpha: 1)

    /// Where a detector's handles sit, in µm: the two ends of a line, the four corners of a
    /// box (counter-clockwise from the lower left).
    public static func detectorHandles(_ detector: Detector) -> [(x: Double, y: Double)] {
        detector.points
    }
}

/// Typeset overlay labels, by text, size, weight, colour and scale.
enum OverlayTextCache {
    /// Off: every label is typeset afresh, as before the cache (the export check compares).
    nonisolated(unsafe) static var enabled = true
    nonisolated(unsafe) static let cache: NSCache<NSString, NSAttributedString> = {
        let c = NSCache<NSString, NSAttributedString>()
        c.countLimit = 512
        return c
    }()
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

    /// `string` with its `$…$` math typeset, in the overlay font and shadow. Cached: the
    /// same labels are typeset again on every redraw of the overlays.
    private func styled(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSAttributedString {
        guard OverlayTextCache.enabled else { return typeset(string, size: size, weight: weight, color: color) }
        let key = "\(string)\u{1}\(size)\u{1}\(weight.rawValue)\u{1}\(color.description)\u{1}\(textScale)" as NSString
        if let hit = OverlayTextCache.cache.object(forKey: key) {
            PerfProbe.count("overlay.textHit")
            return hit
        }
        let out = typeset(string, size: size, weight: weight, color: color)
        OverlayTextCache.cache.setObject(out, forKey: key)
        return out
    }

    private func typeset(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSAttributedString {
        let attrs = attributes(size: size, weight: weight, color: color)
        let out = NSMutableAttributedString(attributedString: MathTypesetter.attributed(string, font: attrs[.font] as! NSFont, color: color))
        out.addAttribute(.shadow, value: attrs[.shadow]!, range: NSRange(location: 0, length: out.length))
        return out
    }

    private func textSize(_ string: String, size: CGFloat, weight: NSFont.Weight = .regular) -> CGSize {
        styled(string, size: size, weight: weight, color: .white).size()
    }

    /// Draws `string`, with its `$…$` math typeset, with its top-left corner at `point`, or
    /// anchored by `alignment`.
    private func text(
        _ string: String,
        at point: CGPoint,
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        color: NSColor = NSColor(calibratedWhite: 1, alpha: 0.9),
        alignment: (x: CGFloat, y: CGFloat) = (0, 0)
    ) {
        let text = styled(string, size: size, weight: weight, color: color)
        let measured = text.size()
        let origin = CGPoint(x: point.x - alignment.x * measured.width, y: point.y - alignment.y * measured.height)
        text.draw(at: origin)
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

    // MARK: Puzzle

    /// The region parts must stay in: a dashed accent rectangle, and a veil over the rest of
    /// the domain so the eye goes to where the player can work.
    func drawPuzzleRegion() {
        guard let region = model.puzzle?.region else { return }
        let inner = map.rect(region)
        let outer = map.rect(model.interior)
        let veil = CGMutablePath()
        veil.addRect(outer)
        veil.addRect(inner)
        fill(veil, color: CGColor(gray: 0, alpha: 0.25), evenOdd: true)
        stroke(CGPath(rect: inner, transform: nil), color: CGColor(gray: 0, alpha: 0.45), width: 3.5, fixedWidth: true)
        stroke(CGPath(rect: inner, transform: nil), color: NSColor.controlAccentColor.cgColor, width: 1.5, dash: [6, 4], fixedWidth: true)
    }

    /// The puzzle's own bodies: a 45° hatch inside the outline and a padlock, so they read
    /// as fixed whatever the colormap.
    func drawLockedBodies() {
        guard let puzzle = model.puzzle, !puzzle.lockedIDs.isEmpty, let outlines = model.outlines else { return }
        for body in outlines.bodies where puzzle.lockedIDs.contains(body.elementId) {
            let outline = path(body.outline)
            let box = outline.boundingBoxOfPath
            guard box.width > 0, box.height > 0 else { continue }
            context.saveGState()
            context.addPath(outline)
            context.clip()
            let hatch = CGMutablePath()
            let step = 6 * max(1, textScale)
            var x = box.minX - box.height
            while x < box.maxX {
                hatch.move(to: CGPoint(x: x, y: box.maxY))
                hatch.addLine(to: CGPoint(x: x + box.height, y: box.minY))
                x += step
            }
            stroke(hatch, color: CGColor(gray: 1, alpha: 0.3), width: 1, fixedWidth: true)
            context.restoreGState()
        }
    }

    /// One padlock per fixed element, at the middle of all its bodies, over the outlines.
    func drawPadlocks() {
        guard let puzzle = model.puzzle, !puzzle.lockedIDs.isEmpty, let outlines = model.outlines else { return }
        for id in puzzle.lockedIDs.sorted() {
            let boxes = outlines.bodies(of: id).map { path($0.outline).boundingBoxOfPath }
            guard let first = boxes.first else { continue }
            let box = boxes.dropFirst().reduce(first) { $0.union($1) }
            padlock(at: CGPoint(x: box.midX, y: box.midY))
        }
    }

    /// A 10 pt padlock (drawn as a path: there are no SF Symbols in Core Graphics) on a
    /// dark disc.
    private func padlock(at c: CGPoint) {
        let s = 10 * max(1, textScale)
        fill(CGPath(ellipseIn: CGRect(x: c.x - s, y: c.y - s, width: 2 * s, height: 2 * s), transform: nil), color: CGColor(gray: 0, alpha: 0.55))
        let body = CGRect(x: c.x - 0.42 * s, y: c.y - 0.05 * s, width: 0.84 * s, height: 0.62 * s)
        let shackle = CGMutablePath()
        let r = 0.27 * s
        shackle.move(to: CGPoint(x: c.x - r, y: body.minY))
        shackle.addLine(to: CGPoint(x: c.x - r, y: body.minY - 0.18 * s))
        shackle.addArc(center: CGPoint(x: c.x, y: body.minY - 0.18 * s), radius: r, startAngle: .pi, endAngle: 0, clockwise: false)
        shackle.addLine(to: CGPoint(x: c.x + r, y: body.minY))
        let white = CGColor(gray: 1, alpha: 0.9)
        stroke(shackle, color: white, width: 0.13 * s, fixedWidth: true)
        fill(CGPath(roundedRect: body, cornerWidth: 0.1 * s, cornerHeight: 0.1 * s, transform: nil), color: white)
    }

    /// A source's letter ("A", "Bias") in a plate, centred on `p`.
    private func letterPlate(_ label: String, at p: CGPoint, color: NSColor) {
        let size = textSize(MathTypesetter.escaped(label), size: 11, weight: .bold)
        plate(CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height))
        text(MathTypesetter.escaped(label), at: p, size: 11, weight: .bold, color: color, alignment: (0.5, 0.5))
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
        let outside = model.puzzle?.outOfRegionIDs ?? []
        for body in outlines.bodies where body.elementId != model.selectedElementID {
            if outside.contains(body.elementId) {
                // Outside the puzzle's region: amber, so the problem shows before a Check.
                stroke(path(body.outline), color: CGColor(gray: 0, alpha: 0.5), width: 4, fixedWidth: true)
                stroke(path(body.outline), color: VectorRenderer.warningColor, width: 2, fixedWidth: true)
                continue
            }
            stroke(path(body.outline), color: CGColor(gray: 1, alpha: body.enabled ? 0.6 : 0.5), width: 1.5,
                   dash: body.enabled ? [] : [5, 4])
        }
        guard let selected = model.selectedElementID else { return }
        let accent = NSColor.controlAccentColor.cgColor
        for body in outlines.bodies(of: selected) {
            if outside.contains(selected) {
                stroke(path(body.outline), color: VectorRenderer.warningColor, width: 6, fixedWidth: true)
            }
            // Fixed width on screen, so the selection reads the same at any size.
            stroke(path(body.outline), color: accent, width: 2.5, dash: body.enabled ? [] : [6, 4], fixedWidth: true)
        }
        if model.showsHandles, model.puzzle?.lockedIDs.contains(selected) != true, let anchor = model.anchors[selected] {
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
            text("$f$", at: CGPoint(x: p.x + r + 2 * scale, y: p.y - r - 2 * scale), size: 9, weight: .semibold,
                 color: NSColor(calibratedWhite: 1, alpha: 0.75), alignment: (0, 0.5))
        }
    }

    // MARK: Sources

    func drawSources() {
        for source in model.sources {
            drawSource(source, selected: model.selection == .source(source.id))
        }
    }

    private func drawSource(_ source: Source, selected: Bool) {
        let a = source.angleDeg * .pi / 180
        let dir = (x: cos(a), y: sin(a))
        // A disabled source (canvas only) is dashed and faint.
        let base = VectorRenderer.beamColor
        let color = source.enabled ? base : (base.copy(alpha: 0.5) ?? base)
        let dash: [CGFloat] = source.enabled ? [] : [4, 3]
        let accent = NSColor.controlAccentColor.cgColor
        let labelColor = NSColor(cgColor: color) ?? .cyan
        // A puzzle's sources are fixed: no handles, and a letter plate instead of the name.
        let showsHandles = model.showsHandles && model.puzzle == nil
        let plateLabel = model.puzzle?.sourceLabels[source.id]
        let name = plateLabel == nil ? source.name : ""

        switch source.kind {
        case .gaussianBeam:
            let waist = map.point(x: source.xUm, y: source.yUm)
            let w0 = source.waistUm
            let normal = (x: -dir.y, y: dir.x)
            // The waist: a bar ±w0 across the axis with end ticks.
            let top = map.point(x: source.xUm + w0 * normal.x, y: source.yUm + w0 * normal.y)
            let bottom = map.point(x: source.xUm - w0 * normal.x, y: source.yUm - w0 * normal.y)
            let bar = CGMutablePath()
            bar.move(to: top)
            bar.addLine(to: bottom)
            let tick = 5 * scale
            let along = CGVector(dx: CGFloat(dir.x) * tick, dy: -CGFloat(dir.y) * tick)
            for end in [top, bottom] {
                bar.move(to: CGPoint(x: end.x - along.dx, y: end.y - along.dy))
                bar.addLine(to: CGPoint(x: end.x + along.dx, y: end.y + along.dy))
            }
            stroke(bar, color: color, width: 1.5, dash: dash)

            // The axis arrow from the waist.
            let handle = VectorRenderer.angleHandle(source: source, viewRect: model.viewRect)
            let tip = map.point(x: handle.x, y: handle.y)
            drawArrow(from: waist, to: tip, color: color, dash: dash)
            let r: CGFloat = 4 * max(1, scale)
            let dot = CGPath(ellipseIn: CGRect(x: waist.x - r, y: waist.y - r, width: 2 * r, height: 2 * r), transform: nil)
            fill(dot, color: color)
            if selected, showsHandles {
                ring(at: waist, radius: r + 3, color: accent)
            }
            if showsHandles {
                let h = CGPath(ellipseIn: CGRect(x: tip.x - 4.5, y: tip.y - 4.5, width: 9, height: 9), transform: nil)
                fill(h, color: CGColor(gray: 0.1, alpha: 0.8))
                stroke(h, color: selected ? accent : color, width: 1.5, fixedWidth: true)
            }
            // A puzzle's beams are fixed: their plate names them, and a w0 label would only
            // crowd it.
            if model.puzzle == nil {
                text("$w_0$", at: CGPoint(x: top.x + 6 * scale, y: top.y), size: 9, weight: .semibold,
                     color: labelColor, alignment: (0, 1))
            }
            if !name.isEmpty {
                text(MathTypesetter.escaped(name), at: CGPoint(x: bottom.x + 6 * scale, y: bottom.y), size: 9,
                     weight: .semibold, color: labelColor, alignment: (0, 0))
            }
            if let plateLabel {
                // Upstream of the waist on the beam's axis, where only this beam is.
                let back = 0.45 * VectorRenderer.beamArrowLength(source: source, viewRect: model.viewRect)
                // A beam entering at the domain's edge (NAND's bias) has no room upstream: the
                // plate stays just inside the domain.
                let inner = model.interior
                let margin = 0.04 * min(inner.width, inner.height)
                let px = min(max(source.xUm - back * dir.x, inner.xMin + margin), inner.xMax - margin)
                let py = min(max(source.yUm - back * dir.y, inner.yMin + margin), inner.yMax - margin)
                letterPlate(plateLabel, at: map.point(x: px, y: py), color: labelColor)
            }

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
                let c = offset == 0 ? (selected && showsHandles ? accent : color) : (color.copy(alpha: color.alpha * 0.5) ?? color)
                drawArrow(from: s, to: e, color: c, dash: dash)
                if offset == 0 {
                    let label = (plateLabel ?? name).isEmpty ? "$k$" : "$k$  " + MathTypesetter.escaped(plateLabel ?? name)
                    text(label, at: CGPoint(x: e.x + 4 * scale, y: e.y), size: 10, weight: .semibold,
                         color: labelColor, alignment: (0, 1))
                }
            }

        case .lineSource:
            // A dot radiating to both sides, like the emitter's symbol.
            let p = map.point(x: source.xUm, y: source.yUm)
            let r: CGFloat = 4 * max(1, scale)
            fill(CGPath(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r), transform: nil), color: color)
            for (i, radius) in ([9, 15] as [CGFloat]).enumerated() {
                let rr = radius * max(1, scale)
                let arcs = CGMutablePath()
                for centre in [0.0, CGFloat.pi] {
                    let start = centre - 0.75
                    arcs.move(to: CGPoint(x: p.x + rr * cos(start), y: p.y + rr * sin(start)))
                    arcs.addArc(center: p, radius: rr, startAngle: start, endAngle: centre + 0.75, clockwise: false)
                }
                let arcColor = color.copy(alpha: color.alpha * (i == 0 ? 0.85 : 0.55)) ?? color
                // A dark backing: the field is brightest right around an emitter.
                stroke(arcs, color: CGColor(gray: 0, alpha: 0.5), width: 3.5, dash: dash)
                stroke(arcs, color: arcColor, width: 1.5, dash: dash)
            }
            if selected, showsHandles {
                ring(at: p, radius: r + 3, color: accent)
            }
            if let plateLabel {
                letterPlate(plateLabel, at: CGPoint(x: p.x, y: p.y + 30 * max(1, scale)), color: labelColor)
            } else if !name.isEmpty {
                text(MathTypesetter.escaped(name), at: CGPoint(x: p.x, y: p.y + 16 * max(1, scale)), size: 9,
                     weight: .semibold, color: labelColor, alignment: (0.5, 0))
            }
        }
    }

    /// A selection ring around a source's point.
    private func ring(at p: CGPoint, radius: CGFloat, color: CGColor) {
        let path = CGPath(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: 2 * radius, height: 2 * radius), transform: nil)
        stroke(path, color: CGColor(gray: 0, alpha: 0.5), width: 4, fixedWidth: true)
        stroke(path, color: color, width: 2, fixedWidth: true)
    }

    // MARK: Detectors

    func drawDetectors() {
        let accent = NSColor.controlAccentColor.cgColor
        for detector in model.detectors {
            let selected = model.selection == .detector(detector.id)
            let base = selected ? accent : VectorRenderer.detectorColor
            let color = detector.enabled ? base : (base.copy(alpha: 0.5) ?? base)
            let dash: [CGFloat] = detector.enabled ? [] : [5, 4]
            switch detector.shape {
            case .line(let g):
                let a = map.point(x: g.x1Um, y: g.y1Um)
                let b = map.point(x: g.x2Um, y: g.y2Um)
                let path = CGMutablePath()
                path.move(to: a)
                path.addLine(to: b)
                // End ticks across the segment.
                let dx = b.x - a.x, dy = b.y - a.y
                let len = max(1e-6, hypot(dx, dy))
                let across = CGVector(dx: -dy / len * 3 * scale, dy: dx / len * 3 * scale)
                for end in [a, b] {
                    path.move(to: CGPoint(x: end.x - across.dx, y: end.y - across.dy))
                    path.addLine(to: CGPoint(x: end.x + across.dx, y: end.y + across.dy))
                }
                stroke(path, color: CGColor(gray: 0, alpha: 0.45), width: 4, dash: dash)
                stroke(path, color: color, width: 2, dash: dash)
                // The normal at the midpoint: start → end turned to the right, which in the
                // y-down view is (−dy, dx) of the view vector.
                if let angle = detector.normalAngleDeg {
                    let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                    let n = angle * .pi / 180
                    let arrow = 12 * scale
                    let tip = CGPoint(x: mid.x + CGFloat(cos(n)) * arrow, y: mid.y - CGFloat(sin(n)) * arrow)
                    drawArrow(from: mid, to: tip, color: color, head: 5, wing: 3)
                }
                if selected, model.showsHandles, model.puzzle == nil {
                    for p in [a, b] { handle(at: p, round: true) }
                }
            case .box:
                let corners = detector.points.map { map.point(x: $0.x, y: $0.y) }
                let path = CGMutablePath()
                path.addLines(between: corners)
                path.closeSubpath()
                fill(path, color: color.copy(alpha: 0.1) ?? color)
                stroke(path, color: CGColor(gray: 0, alpha: 0.4), width: 3.5, dash: dash)
                stroke(path, color: color, width: 1.5, dash: dash)
                if selected, model.showsHandles, model.puzzle == nil {
                    for p in corners { handle(at: p, round: false) }
                }
            }
        }
    }

    /// A drag handle on the selected detector, fixed in size on screen.
    private func handle(at p: CGPoint, round: Bool) {
        let r: CGFloat = 4.5
        let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
        let path = round ? CGPath(ellipseIn: rect, transform: nil) : CGPath(rect: rect, transform: nil)
        fill(path, color: NSColor.controlAccentColor.cgColor)
        stroke(path, color: CGColor(gray: 1, alpha: 0.9), width: 1.5, fixedWidth: true)
    }

    /// Each detector's name and reading in a plate: beside a line's end, by a box's upper
    /// right corner.
    func drawDetectorLabels() {
        let alpha: CGFloat = model.readingsStale ? 0.55 : 0.95
        for detector in model.detectors where detector.enabled {
            guard let label = model.detectorLabels[detector.id], !label.isEmpty else { continue }
            var anchor: CGPoint
            var alignment: (x: CGFloat, y: CGFloat)
            let size = textSize(label, size: 9.5, weight: .medium)
            switch detector.shape {
            case .line(let g):
                // Past the end that is higher on screen, so the plate does not cover the line.
                let a = map.point(x: g.x1Um, y: g.y1Um)
                let b = map.point(x: g.x2Um, y: g.y2Um)
                let top = a.y < b.y ? a : b
                let bottom = a.y < b.y ? b : a
                anchor = CGPoint(x: top.x + 6 * textScale, y: top.y - 6 * textScale)
                alignment = (0, 1)
                if anchor.y - size.height < 32 * textScale {
                    // No room above the line (the top strip holds the canvas's status
                    // badge): past the lower end instead.
                    anchor = CGPoint(x: bottom.x + 6 * textScale, y: bottom.y + 6 * textScale)
                    alignment = (0, 0)
                }
            case .box:
                let corners = detector.points.map { map.point(x: $0.x, y: $0.y) }
                let maxX = corners.map(\.x).max() ?? 0
                let minY = corners.map(\.y).min() ?? 0
                anchor = CGPoint(x: maxX + 6 * textScale, y: minY)
                alignment = (0, 1)
            }
            // Kept inside the image (a line near the right edge puts it past the edge).
            anchor.x = min(anchor.x, bounds.maxX - size.width - 8 * textScale)
            plate(CGRect(x: anchor.x - alignment.x * size.width, y: anchor.y - alignment.y * size.height,
                         width: size.width, height: size.height))
            text(label, at: anchor, size: 9.5, weight: .medium,
                 color: NSColor(srgbRed: 1, green: 0.86, blue: 0.6, alpha: alpha), alignment: alignment)
        }
    }

    private func drawArrow(from a: CGPoint, to b: CGPoint, color: CGColor, dash: [CGFloat] = [], head: CGFloat = 7, wing: CGFloat = 3.5) {
        stroke(line(from: a, to: b), color: color, width: 1.5, dash: dash)
        let dx = b.x - a.x
        let dy = b.y - a.y
        let len = max(1e-6, (dx * dx + dy * dy).squareRoot())
        let ux = dx / len
        let uy = dy / len
        let head = head * scale
        let wing = wing * scale
        let path = CGMutablePath()
        path.move(to: b)
        path.addLine(to: CGPoint(x: b.x - ux * head - uy * wing, y: b.y - uy * head + ux * wing))
        path.addLine(to: CGPoint(x: b.x - ux * head + uy * wing, y: b.y - uy * head - ux * wing))
        path.closeSubpath()
        fill(path, color: color)
    }

    // MARK: Scale bar, caption, legend

    /// Screen boxes of the enabled detectors, which the scale bar keeps clear of.
    private var detectorBoxes: [CGRect] {
        model.detectors.filter(\.enabled).map { detector in
            let points = detector.points.map { map.point(x: $0.x, y: $0.y) }
            let xs = points.map(\.x), ys = points.map(\.y)
            return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0),
                          height: (ys.max() ?? 0) - (ys.min() ?? 0)).insetBy(dx: -6 * scale, dy: -6 * scale)
        }
    }

    /// Draws the scale bar at the bottom right, over the colour bar; when a detector runs
    /// through that spot, at the bottom left instead (over the caption). Returns its box.
    @discardableResult
    func drawScaleBar(above legendTop: CGFloat?, captionAbove: Bool = false) -> CGRect? {
        let length = VectorRenderer.niceLength(0.15 * model.viewRect.width)
        let width = CGFloat(length) * map.scale
        guard width > 4 else { return nil }
        let label = length >= 1 ? "\(SceneFormat.fixed(length, 0)) µm" : "\(SceneFormat.fixed(length * 1000, 0)) nm"
        let labelSize = textSize(label, size: 10, weight: .medium)
        func box(right: CGFloat, y: CGFloat) -> CGRect {
            CGRect(x: right - width, y: y - 6 * scale - labelSize.height, width: width, height: labelSize.height + 6 * scale + 4 * scale)
        }
        var right = bounds.maxX - margin
        var y = (legendTop.map { $0 - 20 * textScale } ?? bounds.maxY - margin)
        if detectorBoxes.contains(where: { $0.intersects(box(right: right, y: y)) }) {
            let leftRight = bounds.minX + margin + width
            let leftY = bounds.maxY - margin - (captionAbove ? 26 * textScale : 0)
            if !detectorBoxes.contains(where: { $0.intersects(box(right: leftRight, y: leftY)) }) {
                right = leftRight
                y = leftY
            }
        }
        let rect = box(right: right, y: y)
        plate(rect)
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
        return rect
    }

    /// The caption at the bottom left, lifted over anything in `taken` it would overlap.
    func drawCaption(clearOf taken: [CGRect] = []) {
        guard let caption = model.caption else { return }
        let size = textSize(caption, size: 10, weight: .medium)
        let pad = 8 * textScale
        var rect = CGRect(x: bounds.minX + margin, y: bounds.maxY - margin - size.height, width: size.width, height: size.height)
        for _ in 0..<3 {
            let hits = taken.filter { $0.insetBy(dx: -pad, dy: -pad / 2).intersects(rect) }
            guard let top = hits.map(\.minY).min() else { break }
            rect.origin.y = top - pad - size.height
        }
        plate(rect)
        text(caption, at: CGPoint(x: rect.minX, y: rect.maxY), size: 10, weight: .medium,
             color: NSColor(calibratedWhite: 1, alpha: 0.85), alignment: (0, 1))
    }

    /// Draws the colour bar at the bottom right and returns the top of what it drew and its
    /// backing plate.
    func drawLegend() -> (top: CGFloat, plate: CGRect)? {
        guard let legend = model.legend, legend.lut.count >= 1024,
              let provider = CGDataProvider(data: Data(legend.lut) as CFData),
              let strip = CGImage(
                width: 256, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 1024,
                space: FringeBridge.colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              ) else { return nil }
        let labelHeight = textSize("0", size: 9).height
        let width = 150 * textScale
        let height = 8 * textScale
        let right = bounds.maxX - margin
        let bottom = bounds.maxY - margin - labelHeight - 2 * textScale
        let rect = CGRect(x: right - width, y: bottom - height, width: width, height: height)
        let titleHeight = textSize(legend.title, size: 9, weight: .semibold).height
        let plateRect = CGRect(x: rect.minX, y: rect.minY - 3 * textScale - titleHeight, width: width,
                               height: titleHeight + 3 * textScale + height + 2 * textScale + labelHeight)
        plate(plateRect)

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
        return (rect.minY - 3 * textScale - labelHeight, plateRect)
    }
}
