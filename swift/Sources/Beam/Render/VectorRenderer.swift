import AppKit
import CoreGraphics
import Foundation

/// Just enough complex arithmetic for the q-parameter.
public struct OpticsComplex: Equatable {
    public var r: Double
    public var i: Double

    public init(_ r: Double, _ i: Double) {
        self.r = r
        self.i = i
    }

    public static func + (lhs: OpticsComplex, rhs: Double) -> OpticsComplex {
        OpticsComplex(lhs.r + rhs, lhs.i)
    }

    public var normSq: Double {
        r * r + i * i
    }

    public var inv: OpticsComplex? {
        let n = normSq
        guard n > 1e-30 else { return nil }
        return OpticsComplex(r / n, -i / n)
    }
}

/// Draws the vector overlays (envelope, wavefronts, element glyphs, labels) on top of the
/// raster. The preview and the exported PNG both draw through `drawOverlays`.
public enum VectorRenderer {
    /// Beam radius w, radius of curvature R and curvature κ = 1/R at z, after every enabled
    /// element upstream of z.
    public static func evaluateBeam(
        at z: Double,
        beam: BeamParameters,
        elements: [PlacedElementModel]
    ) -> (w: Double, R: Double, kappa: Double) {
        let res = evaluateBeamWithIndex(at: z, beam: beam, elements: elements)
        return (res.w, res.R, res.kappa)
    }

    /// Same as `evaluateBeam`, plus the refractive index of the medium at z.
    ///
    /// Propagates the complex beam parameter q through each element with its ABCD matrix,
    /// following `OpticalTrain::beam_at` in the core. Mirrors are unfolded, so a curved mirror
    /// acts as a lens with f = R/2.
    public static func evaluateBeamWithIndex(
        at z: Double,
        beam: BeamParameters,
        elements: [PlacedElementModel]
    ) -> (w: Double, R: Double, kappa: Double, n: Double) {
        let zR0 = beam.rayleighRange

        let active = elements
            .filter { $0.isEnabled && $0.z <= z }
            .sorted { $0.z < $1.z }

        guard let first = active.first else {
            let zRel = z - beam.z0
            let w = BeamBridge.waistAt(w0: beam.w0, z: zRel, zR: zR0)
            let kappa = BeamBridge.curvatureAt(z: zRel, zR: zR0)
            let R = abs(kappa) > 1e-12 ? (1.0 / kappa) : (zRel >= 0 ? 1e12 : -1e12)
            return (w, R, kappa, beam.refractiveIndex)
        }

        // Seed q at the first element rather than at the waist. Starting at the waist and only
        // drifting forwards would skip the drift to an element upstream of the waist.
        var currentN = beam.refractiveIndex
        var currentZ = first.z
        var currentQ = OpticsComplex(first.z - beam.z0, zR0)

        for elem in active {
            let dz = elem.z - currentZ
            if dz > 0 {
                currentQ = currentQ + dz
                currentZ = elem.z
            }

            switch elem.type {
            case .thinLens:
                let f = elem.param1
                if abs(f) > 1e-12, let invQ = currentQ.inv {
                    let invQAfter = OpticsComplex(invQ.r - 1.0 / f, invQ.i)
                    if let qAfter = invQAfter.inv {
                        currentQ = qAfter
                    }
                }
            case .curvedMirror:
                let radius = elem.param1
                if abs(radius) > 1e-12, let invQ = currentQ.inv {
                    let invQAfter = OpticsComplex(invQ.r - 2.0 / radius, invQ.i)
                    if let qAfter = invQAfter.inv {
                        currentQ = qAfter
                    }
                }
            case .flatMirror:
                break
            case .dielectricInterface:
                let n1 = max(1.0, elem.param1)
                let n2 = max(1.0, elem.param2)
                currentQ = OpticsComplex(currentQ.r * (n2 / n1), currentQ.i * (n2 / n1))
                currentN = n2
            case .gaussianAperture:
                let wa = max(1e-6, elem.param1)
                if let invQ = currentQ.inv {
                    // A Gaussian amplitude mask exp(-x²/wa²) adds -i·2/(k wa²) to 1/q.
                    let k = 2.0 * Double.pi * currentN / beam.wavelength
                    let invQAfter = OpticsComplex(invQ.r, invQ.i - 2.0 / (k * wa * wa))
                    if let qAfter = invQAfter.inv {
                        currentQ = qAfter
                    }
                }
            }
        }

        let finalDz = z - currentZ
        if finalDz != 0 {
            currentQ = currentQ + finalDz
        }

        // 1/q = 1/R - i λ / (π n w²)
        let qNorm = currentQ.normSq
        guard currentQ.i > 1e-25, qNorm > 1e-25 else {
            return (beam.w0, 1e12, 0.0, currentN)
        }

        let invQi = -currentQ.i / qNorm
        let w = sqrt(max(1e-12, beam.wavelength / (Double.pi * currentN * (-invQi))))

        let kappa = currentQ.r / qNorm
        let R = abs(kappa) > 1e-12 ? (1.0 / kappa) : (currentQ.r >= 0 ? 1e12 : -1e12)

        return (w, R, kappa, currentN)
    }

    // These three must match VISUAL_REF_WAVELENGTH, VISUAL_FRINGES_PER_ZR and
    // VISUAL_CURVATURE_GAIN in src/render/grid.rs, or the drawn wavefronts will not line up
    // with the fringes in the raster.
    public static let visualRefWavelength: Double = 632.8e-9
    public static let visualFringesPerZR: Double = 10.0
    public static let visualCurvatureGain: Double = 2.0

    /// Axial wavenumber of the drawn fringes, in rad/m. Mirrors `visual_wavefront_wavenumber` in
    /// the core: real optical fringes are far too fine to see, so the fringe spacing is tied to
    /// the Rayleigh range instead and does not change with zoom.
    public static func visualWavenumber(beam: BeamParameters, localN: Double) -> Double {
        let zrRef = Double.pi * max(1.0, beam.refractiveIndex) * beam.w0 * beam.w0 / visualRefWavelength
        let wlScale = min(4.0, max(0.25, visualRefWavelength / max(1e-18, beam.wavelength)))
        let nScale = localN / max(1.0, beam.refractiveIndex)
        return (visualFringesPerZR * Double.pi / max(1e-18, zrRef)) * wlScale * nScale
    }

    /// Beam radius w, axial sagitta of the drawn wavefront at x = ±w (metres), and curvature κ at z.
    ///
    /// The wavefront through (z_c, 0) is the parabola z(x) = z_c - sagitta · (x / w)².
    public static func wavefrontSagitta(
        at z: Double,
        beam: BeamParameters,
        elements: [PlacedElementModel]
    ) -> (w: Double, sagitta: Double, kappa: Double) {
        let (w, _, kappa, localN) = evaluateBeamWithIndex(at: z, beam: beam, elements: elements)
        let kLocal = 2.0 * Double.pi * localN / max(1e-18, beam.wavelength)
        let kVis = visualWavenumber(beam: beam, localN: localN)
        guard kVis > 1e-18 else { return (w, 0.0, kappa) }
        let transversePhaseAtWaist = visualCurvatureGain * 0.5 * kLocal * w * w * kappa
        let sagitta = transversePhaseAtWaist / kVis
        return (w, sagitta, kappa)
    }

    /// Axial position z to horizontal view coordinate.
    public static func mapZToX(
        z: Double,
        zMin: Double,
        zMax: Double,
        bounds: CGRect
    ) -> CGFloat {
        let span = max(1e-6, zMax - zMin)
        let normalized = (z - zMin) / span
        return bounds.minX + CGFloat(normalized) * bounds.width
    }

    /// Transverse position x to vertical view coordinate; x = 0 is the vertical centre.
    public static func mapXToY(
        x: Double,
        xMax: Double,
        bounds: CGRect
    ) -> CGFloat {
        let safeXMax = max(1e-9, xMax)
        let normalized = x / safeXMax
        return bounds.midY - CGFloat(normalized) * (bounds.height / 2.0)
    }

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
        beam: BeamParameters,
        elements: [PlacedElementModel],
        style: RenderStyleModel,
        framing: FramingModel,
        selectedID: UUID? = nil,
        minimumTextScale: CGFloat = 0
    ) {
        guard style.showOverlays, size.width > 0, size.height > 0 else { return }

        let scale = size.height / 720.0
        let painter = OverlayPainter(
            context: context,
            bounds: CGRect(origin: .zero, size: size),
            scale: scale,
            textScale: max(scale, minimumTextScale),
            beam: beam,
            elements: elements,
            framing: framing
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

        if style.showCenterline { painter.drawAxis() }
        if style.showWavefrontArcs { painter.drawWavefronts() }
        if style.showEnvelope { painter.drawEnvelope() }
        if style.showRayleighMarkers { painter.drawRayleighMarkers() }
        if style.showElementGlyphs { painter.drawElements(selectedID: selectedID) }
        if style.showMetadataWatermark { painter.drawCaption(colormap: style.colormap) }
    }

    static func glyphLabel(_ elem: PlacedElementModel) -> String {
        switch elem.type {
        case .thinLens:
            return String(format: "f = %+.0f mm", elem.param1 * 1000)
        case .curvedMirror:
            return String(format: "R = %+.0f mm", elem.param1 * 1000)
        case .flatMirror:
            return "Flat mirror"
        case .dielectricInterface:
            return String(format: "n = %.2f → %.2f", elem.param1, elem.param2)
        case .gaussianAperture:
            return String(format: "wₐ = %.2f mm", elem.param1 * 1000)
        }
    }
}

/// One pass of overlay drawing into a y-down context.
private struct OverlayPainter {
    let context: CGContext
    let bounds: CGRect
    /// Multiplier for line widths, dash lengths and offsets.
    let scale: CGFloat
    /// Multiplier for font sizes and the spacing between lines of text.
    let textScale: CGFloat
    let beam: BeamParameters
    let elements: [PlacedElementModel]
    let framing: FramingModel

    private var zMin: Double { framing.effectiveZMin }
    private var zMax: Double { framing.effectiveZMax }
    private var xMax: Double { framing.effectiveXMax }

    private func px(_ z: Double) -> CGFloat {
        VectorRenderer.mapZToX(z: z, zMin: zMin, zMax: zMax, bounds: bounds)
    }

    private func py(_ x: Double) -> CGFloat {
        VectorRenderer.mapXToY(x: x, xMax: xMax, bounds: bounds)
    }

    private func stroke(
        _ path: CGPath,
        color: CGColor,
        width: CGFloat,
        dash: [CGFloat] = [],
        round: Bool = false
    ) {
        context.saveGState()
        context.addPath(path)
        context.setStrokeColor(color)
        context.setLineWidth(width * scale)
        context.setLineDash(phase: 0, lengths: dash.map { $0 * scale })
        if round {
            context.setLineCap(.round)
            context.setLineJoin(.round)
        }
        context.strokePath()
        context.restoreGState()
    }

    private func fill(_ path: CGPath, color: CGColor) {
        context.saveGState()
        context.addPath(path)
        context.setFillColor(color)
        context.fillPath()
        context.restoreGState()
    }

    private func line(from a: CGPoint, to b: CGPoint) -> CGPath {
        let path = CGMutablePath()
        path.move(to: a)
        path.addLine(to: b)
        return path
    }

    private func text(
        _ string: String,
        at point: CGPoint,
        size: CGFloat,
        weight: NSFont.Weight,
        color: NSColor,
        alignBottom: Bool = false
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size * textScale, weight: weight),
            .foregroundColor: color,
        ]
        let string = string as NSString
        let height = string.size(withAttributes: attributes).height
        string.draw(at: CGPoint(x: point.x, y: alignBottom ? point.y - height : point.y), withAttributes: attributes)
    }

    func drawAxis() {
        stroke(
            line(from: CGPoint(x: bounds.minX, y: bounds.midY), to: CGPoint(x: bounds.maxX, y: bounds.midY)),
            color: CGColor(red: 1, green: 1, blue: 1, alpha: 0.22),
            width: 1.0,
            dash: [4, 4]
        )
    }

    func drawWavefronts(count: Int = 14) {
        let path = CGMutablePath()
        let step = (zMax - zMin) / Double(count + 1)
        for i in 1...count {
            let z = zMin + Double(i) * step
            let (w, sagitta, kappa) = VectorRenderer.wavefrontSagitta(at: z, beam: beam, elements: elements)
            let top = py(w)
            let bottom = py(-w)
            if abs(kappa) < 1e-9 || abs(sagitta) < 1e-12 {
                path.move(to: CGPoint(x: px(z), y: top))
                path.addLine(to: CGPoint(x: px(z), y: bottom))
            } else {
                // A quadratic Bézier with end points at z - sagitta and control point at z + sagitta
                // has its apex at (z, 0) and is exactly the parabola z - sagitta · (x / w)².
                path.move(to: CGPoint(x: px(z - sagitta), y: top))
                path.addQuadCurve(
                    to: CGPoint(x: px(z - sagitta), y: bottom),
                    control: CGPoint(x: px(z + sagitta), y: bounds.midY)
                )
            }
        }
        stroke(path, color: CGColor(red: 0.95, green: 0.85, blue: 0.3, alpha: 0.38), width: 1.0, dash: [3, 3])
    }

    func drawEnvelope(samples: Int = 240) {
        let dz = (zMax - zMin) / Double(samples - 1)
        var upper: [CGPoint] = []
        var lower: [CGPoint] = []
        upper.reserveCapacity(samples)
        lower.reserveCapacity(samples)
        for i in 0..<samples {
            let z = zMin + Double(i) * dz
            let w = VectorRenderer.evaluateBeam(at: z, beam: beam, elements: elements).w
            upper.append(CGPoint(x: px(z), y: py(w)))
            lower.append(CGPoint(x: px(z), y: py(-w)))
        }

        let region = CGMutablePath()
        region.addLines(between: upper + lower.reversed())
        region.closeSubpath()
        fill(region, color: CGColor(red: 0.0, green: 0.85, blue: 1.0, alpha: 0.04))

        let edges = CGMutablePath()
        edges.addLines(between: upper)
        edges.addLines(between: lower)
        stroke(edges, color: CGColor(red: 0.0, green: 0.85, blue: 1.0, alpha: 0.78), width: 1.5, round: true)
    }

    func drawRayleighMarkers() {
        let zR = beam.rayleighRange
        let markers = [
            (z: beam.z0 - zR, label: "z₀ − z_R", isWaist: false),
            (z: beam.z0, label: "w₀", isWaist: true),
            (z: beam.z0 + zR, label: "z₀ + z_R", isWaist: false),
        ]
        for marker in markers where marker.z >= zMin && marker.z <= zMax {
            let x = px(marker.z)
            stroke(
                line(from: CGPoint(x: x, y: bounds.minY + 20 * scale), to: CGPoint(x: x, y: bounds.maxY - 20 * scale)),
                color: marker.isWaist
                    ? CGColor(red: 1, green: 1, blue: 1, alpha: 0.6)
                    : CGColor(red: 1, green: 0.9, blue: 0.2, alpha: 0.45),
                width: marker.isWaist ? 1.5 : 1.0,
                dash: marker.isWaist ? [6, 3] : [2, 4]
            )
            text(
                marker.label,
                at: CGPoint(x: x + 4 * scale, y: bounds.minY + 28 * scale),
                size: 9,
                weight: marker.isWaist ? .semibold : .regular,
                color: marker.isWaist
                    ? NSColor(calibratedWhite: 1, alpha: 0.95)
                    : NSColor(calibratedRed: 1, green: 0.9, blue: 0.2, alpha: 0.75)
            )
        }
    }

    func drawElements(selectedID: UUID?) {
        for elem in elements where elem.isEnabled && elem.z >= zMin && elem.z <= zMax {
            let x = px(elem.z)
            if elem.id == selectedID {
                drawSelection(at: x)
            }
            drawGlyph(elem, at: x)
        }
    }

    private var glyphTop: CGFloat { bounds.midY - bounds.height * 0.38 }
    private var glyphBottom: CGFloat { bounds.midY + bounds.height * 0.38 }

    /// Preview only: a fixed 2 pt outline, so it does not depend on the image scale.
    private func drawSelection(at x: CGFloat) {
        let pad = 14 * scale
        let rect = CGRect(x: x - pad, y: glyphTop - pad, width: 2 * pad, height: glyphBottom - glyphTop + 2 * pad)
        context.saveGState()
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil))
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(2)
        context.strokePath()
        context.restoreGState()
    }

    private func drawGlyph(_ elem: PlacedElementModel, at x: CGFloat) {
        let top = glyphTop
        let bottom = glyphBottom
        let label = VectorRenderer.glyphLabel(elem)
        let labelPoint = CGPoint(x: x + 6 * scale, y: top - 8 * scale)

        switch elem.type {
        case .thinLens:
            let bulge = (elem.param1 >= 0 ? 8.0 : -8.0) * scale
            let lens = CGMutablePath()
            lens.move(to: CGPoint(x: x, y: top))
            lens.addQuadCurve(to: CGPoint(x: x, y: bottom), control: CGPoint(x: x + bulge, y: bounds.midY))
            lens.addQuadCurve(to: CGPoint(x: x, y: top), control: CGPoint(x: x - bulge, y: bounds.midY))
            lens.closeSubpath()
            fill(lens, color: CGColor(red: 0.3, green: 0.7, blue: 1.0, alpha: 0.2))
            stroke(lens, color: CGColor(red: 0.0, green: 0.85, blue: 1.0, alpha: 1.0), width: 1.5)
            stroke(
                line(from: CGPoint(x: x, y: top - 10 * scale), to: CGPoint(x: x, y: bottom + 10 * scale)),
                color: CGColor(red: 0.0, green: 0.85, blue: 1.0, alpha: 0.4),
                width: 1.0,
                dash: [2, 2]
            )
            text(label, at: labelPoint, size: 9, weight: .semibold, color: .cyan, alignBottom: true)

        case .curvedMirror:
            let bulge = (elem.param1 >= 0 ? 12.0 : -12.0) * scale
            let mirror = CGMutablePath()
            mirror.move(to: CGPoint(x: x, y: top))
            mirror.addQuadCurve(to: CGPoint(x: x, y: bottom), control: CGPoint(x: x + bulge, y: bounds.midY))
            stroke(mirror, color: CGColor(red: 1.0, green: 0.6, blue: 0.1, alpha: 1.0), width: 2.0)

            let hatches = CGMutablePath()
            let hatchCount = 10
            for h in 0...hatchCount {
                let y = top + CGFloat(h) * (bottom - top) / CGFloat(hatchCount)
                hatches.move(to: CGPoint(x: x + 2 * scale, y: y))
                hatches.addLine(to: CGPoint(x: x + 10 * scale, y: y + 6 * scale))
            }
            stroke(hatches, color: CGColor(red: 1.0, green: 0.6, blue: 0.1, alpha: 0.5), width: 1.0)
            text(label, at: labelPoint, size: 9, weight: .semibold, color: .orange, alignBottom: true)

        case .flatMirror:
            stroke(
                line(from: CGPoint(x: x, y: top), to: CGPoint(x: x, y: bottom)),
                color: CGColor(red: 1.0, green: 0.6, blue: 0.1, alpha: 1.0),
                width: 2.5
            )
            text(label, at: labelPoint, size: 9, weight: .semibold, color: .orange, alignBottom: true)

        case .dielectricInterface:
            stroke(
                line(from: CGPoint(x: x, y: bounds.minY), to: CGPoint(x: x, y: bounds.maxY)),
                color: CGColor(red: 0.4, green: 0.95, blue: 0.8, alpha: 1.0),
                width: 1.5,
                dash: [4, 2]
            )
            text(label, at: labelPoint, size: 9, weight: .semibold, color: .systemMint, alignBottom: true)

        case .gaussianAperture:
            let clearHalfHeight = 25 * scale
            let blades = CGMutablePath()
            blades.move(to: CGPoint(x: x, y: bounds.minY))
            blades.addLine(to: CGPoint(x: x, y: bounds.midY - clearHalfHeight))
            blades.move(to: CGPoint(x: x, y: bounds.midY + clearHalfHeight))
            blades.addLine(to: CGPoint(x: x, y: bounds.maxY))
            stroke(blades, color: CGColor(red: 1.0, green: 0.25, blue: 0.25, alpha: 1.0), width: 3.0)
            text(label, at: labelPoint, size: 9, weight: .semibold, color: .systemRed, alignBottom: true)
        }
    }

    func drawCaption(colormap: ColormapOption) {
        let margin = 20 * scale
        let origin = CGPoint(x: bounds.minX + margin, y: bounds.maxY - margin - 36 * textScale)
        let title = String(format: "λ = %.0f nm, w₀ = %.3f mm", beam.wavelength * 1e9, beam.w0 * 1000)
        // The other labels use a decimal point whatever the locale, so this one does too.
        let zR = Format.length(beam.rayleighRange, locale: Locale(identifier: "en_US_POSIX"))
        let subtitle = "z_R = \(zR) · \(colormap.displayName)"
        text(title, at: origin, size: 11, weight: .semibold, color: NSColor(calibratedWhite: 1, alpha: 0.85))
        text(
            subtitle,
            at: CGPoint(x: origin.x, y: origin.y + 16 * textScale),
            size: 9,
            weight: .regular,
            color: NSColor(calibratedWhite: 1, alpha: 0.55)
        )
    }
}
