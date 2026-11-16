import Foundation
import CBeamCore

public enum OpticalElementType: Int, CaseIterable, Identifiable, Codable, Sendable {
    case thinLens = 0
    case curvedMirror = 1
    case flatMirror = 2
    case dielectricInterface = 3
    case gaussianAperture = 4

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .thinLens: return "Thin Lens"
        case .curvedMirror: return "Curved Mirror"
        case .flatMirror: return "Flat Mirror"
        case .dielectricInterface: return "Dielectric Interface"
        case .gaussianAperture: return "Gaussian Aperture"
        }
    }

    public var symbol: String {
        switch self {
        case .thinLens: return "oval.portrait"
        case .curvedMirror: return "circle.lefthalf.filled"
        case .flatMirror: return "rectangle.portrait"
        case .dielectricInterface: return "rectangle.split.2x1"
        case .gaussianAperture: return "camera.aperture"
        }
    }

    public var cType: COpticalElementType {
        switch self {
        case .thinLens: return ELEMENT_THIN_LENS
        case .curvedMirror: return ELEMENT_CURVED_MIRROR
        case .flatMirror: return ELEMENT_FLAT_MIRROR
        case .dielectricInterface: return ELEMENT_DIELECTRIC_INTERFACE
        case .gaussianAperture: return ELEMENT_GAUSSIAN_APERTURE
        }
    }

    /// A new element of this type at `z`.
    public func makeElement(at z: Double) -> PlacedElementModel {
        switch self {
        case .thinLens:
            return PlacedElementModel(z: z, type: self, param1: 0.100, name: "Lens")  // f = +100 mm
        case .curvedMirror:
            return PlacedElementModel(z: z, type: self, param1: 0.200, name: "Mirror")  // R = 200 mm
        case .flatMirror:
            return PlacedElementModel(z: z, type: self, param1: 0.0, name: "Flat Mirror")
        case .dielectricInterface:
            return PlacedElementModel(z: z, type: self, param1: 1.0, param2: 1.5168, name: "Interface")  // air to BK7
        case .gaussianAperture:
            return PlacedElementModel(z: z, type: self, param1: 0.0008, name: "Aperture")  // 0.8 mm
        }
    }
}

/// An optical element at a fixed position on the axis.
public struct PlacedElementModel: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// Axial position, in metres.
    public var z: Double
    public var type: OpticalElementType
    /// Focal length, radius of curvature, n1 or aperture radius, depending on `type`.
    public var param1: Double
    /// n2 for a dielectric interface; unused otherwise.
    public var param2: Double
    public var isEnabled: Bool
    public var name: String

    public init(
        id: UUID = UUID(),
        z: Double,
        type: OpticalElementType,
        param1: Double,
        param2: Double = 1.0,
        isEnabled: Bool = true,
        name: String = ""
    ) {
        self.id = id
        self.z = z
        self.type = type
        self.param1 = param1
        self.param2 = param2
        self.isEnabled = isEnabled
        self.name = name.isEmpty ? type.displayName : name
    }

    public var cPlacedElement: CPlacedElement {
        CPlacedElement(
            z: z,
            element_type: type.cType,
            param1: param1,
            param2: param2
        )
    }
}

public enum ColormapOption: Int, CaseIterable, Identifiable, Sendable {
    case viridis = 0
    case inferno = 1
    case plasma = 2
    case turbo = 3
    case laserGlow = 4
    case asympton = 5

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .viridis: return "Viridis"
        case .inferno: return "Inferno"
        case .plasma: return "Plasma"
        case .turbo: return "Turbo"
        case .laserGlow: return "Laser Glow"
        case .asympton: return "Asympton"
        }
    }

    public var cColormap: CColormap {
        switch self {
        case .viridis: return COLORMAP_VIRIDIS
        case .inferno: return COLORMAP_INFERNO
        case .plasma: return COLORMAP_PLASMA
        case .turbo: return COLORMAP_TURBO
        case .laserGlow: return COLORMAP_LASER_GLOW
        case .asympton: return COLORMAP_ASYMPTON
        }
    }

    public var fileTag: String {
        switch self {
        case .laserGlow: return "laser-glow"
        default: return displayName.lowercased()
        }
    }
}

/// Source beam. All lengths in metres, power in watts.
public struct BeamParameters: Equatable, Sendable {
    public var wavelength: Double = 632.8e-9  // He-Ne
    public var w0: Double = 0.5e-3  // waist radius
    public var z0: Double = 0.0  // waist position
    public var refractiveIndex: Double = 1.0
    public var power: Double = 1.0

    public init() {}

    public var cParams: CBeamParams {
        CBeamParams(
            wavelength: wavelength,
            w0: w0,
            z0: z0,
            refractive_index: refractiveIndex,
            power: power
        )
    }

    public var rayleighRange: Double {
        BeamBridge.rayleighRange(w0: w0, wavelength: wavelength, refractiveIndex: refractiveIndex)
    }

    /// Far-field divergence half-angle θ = λ / (π n w0), in radians.
    public var divergenceHalfAngle: Double {
        guard w0 > 0, wavelength > 0, refractiveIndex >= 1.0 else { return 0.0 }
        return wavelength / (Double.pi * refractiveIndex * w0)
    }
}

public struct RenderStyleModel: Equatable, Sendable {
    public var colormap: ColormapOption = .viridis
    public var gamma: Double = 1.0
    public var showWavefrontComposite: Bool = true
    public var fringeModulation: Double = 0.35

    /// Master switch for every vector overlay, in the preview and in exports.
    public var showOverlays: Bool = true
    public var showEnvelope: Bool = true
    public var showWavefrontArcs: Bool = true
    public var showElementGlyphs: Bool = true
    public var showRayleighMarkers: Bool = true
    public var showCenterline: Bool = true
    public var showMetadataWatermark: Bool = true

    public init() {}

    public var cStyle: CRenderStyle {
        CRenderStyle(
            colormap: colormap.cColormap,
            gamma: gamma,
            show_wavefront_composite: showWavefrontComposite,
            fringe_modulation: fringeModulation
        )
    }
}

/// The region of the (z, x) plane an image shows, in metres.
public struct FrameWindow: Equatable, Sendable {
    public var zMin: Double
    public var zMax: Double
    /// Half-height; x = 0 is the vertical centre.
    public var xMax: Double

    public var spanZ: Double { zMax - zMin }
    public var centerZ: Double { (zMin + zMax) / 2.0 }
}

/// Visible region of the (z, x) plane, in metres, before zoom and pan, as seen at 16:9.
public struct FramingModel: Equatable, Sendable {
    public static let zoomRange: ClosedRange<Double> = 0.2...20.0

    /// Stored ranges describe the window at 16:9. Other aspects widen or narrow the axial span
    /// in proportion, so metres per pixel along z and x keep their ratio and the beam keeps its shape.
    public static let referenceAspect = 16.0 / 9.0

    public var zMin: Double = -0.5
    public var zMax: Double = 0.5
    public var xMax: Double = 1.5e-3
    public var zoomScale: Double = 1.0
    public var panZ: Double = 0.0

    public init() {}

    public var centerZ: Double { (zMin + zMax) / 2.0 + panZ }

    /// Half-height of the visible window after zoom.
    public var effectiveXMax: Double {
        xMax / max(0.01, zoomScale)
    }

    /// How much wider the axial span is in an image `aspect` (width over height) wide than at 16:9.
    public static func axialStretch(aspect: Double) -> Double {
        guard aspect.isFinite, aspect > 0 else { return 1.0 }
        return aspect / referenceAspect
    }

    /// What an image `aspect` (width over height) wide shows, after zoom and pan.
    public func window(aspect: Double) -> FrameWindow {
        let span = (zMax - zMin) * Self.axialStretch(aspect: aspect) / max(0.01, zoomScale)
        return FrameWindow(zMin: centerZ - span / 2.0, zMax: centerZ + span / 2.0, xMax: effectiveXMax)
    }

    /// Zooms by `factor`, keeping the z at `anchor` (0 = left edge, 1 = right edge) of an
    /// image `aspect` wide in place.
    public mutating func zoom(by factor: Double, anchor: Double = 0.5, aspect: Double) {
        let before = window(aspect: aspect)
        let anchorZ = before.zMin + anchor * before.spanZ
        zoomScale = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, zoomScale * factor))
        let span = window(aspect: aspect).spanZ
        panZ = anchorZ + (0.5 - anchor) * span - (zMin + zMax) / 2.0
    }

    /// Makes an image `aspect` wide show exactly `start...end`, without changing the transverse scale.
    public mutating func setVisibleRange(start: Double, end: Double, aspect: Double) {
        guard end > start else { return }
        let center = (start + end) / 2.0
        let span = (end - start) / Self.axialStretch(aspect: aspect)
        xMax = effectiveXMax
        zMin = center - span / 2.0
        zMax = center + span / 2.0
        zoomScale = 1.0
        panZ = 0.0
    }
}

/// Everything the user edits. Undo snapshots this whole value.
public struct BeamScene: Equatable, Sendable {
    public var beam = BeamParameters()
    public var elements: [PlacedElementModel] = []
    public var style = RenderStyleModel()
    public var framing = FramingModel()
    public var output = OutputFormat()

    public init() {}

    /// The part of the scene the raster depends on. Overlay toggles and names are left out,
    /// so changing them redraws the overlays without re-rendering the field.
    public struct RasterInputs: Equatable {
        struct Element: Equatable {
            var z: Double
            var type: OpticalElementType
            var param1: Double
            var param2: Double
        }

        var beam: BeamParameters
        var elements: [Element]
        var colormap: ColormapOption
        var gamma: Double
        var showWavefrontComposite: Bool
        var fringeModulation: Double
        var zMin: Double
        var zMax: Double
        var xMax: Double
        var aspect: OutputAspect
    }

    /// What the image shows when the output follows a canvas `windowAspect` wide.
    public func window(windowAspect: Double) -> FrameWindow {
        framing.window(aspect: output.pixelAspect(windowAspect: windowAspect))
    }

    public func rasterInputs(windowAspect: Double) -> RasterInputs {
        let window = window(windowAspect: windowAspect)
        return RasterInputs(
            beam: beam,
            elements: activeElements.map { .init(z: $0.z, type: $0.type, param1: $0.param1, param2: $0.param2) },
            colormap: style.colormap,
            gamma: style.gamma,
            showWavefrontComposite: style.showWavefrontComposite,
            fringeModulation: style.fringeModulation,
            zMin: window.zMin,
            zMax: window.zMax,
            xMax: window.xMax,
            aspect: output.aspect
        )
    }

    /// Enabled elements in axial order, as the core expects them.
    public var activeElements: [PlacedElementModel] {
        elements.filter(\.isEnabled).sorted { $0.z < $1.z }
    }

    public subscript(element id: UUID) -> PlacedElementModel? {
        get { elements.first { $0.id == id } }
        set {
            guard let index = elements.firstIndex(where: { $0.id == id }) else { return }
            if let newValue {
                elements[index] = newValue
            } else {
                elements.remove(at: index)
            }
        }
    }

    /// Sorts by z, keeping the current order for equal positions so rows don't swap.
    public mutating func sortElements() {
        elements = elements.enumerated()
            .sorted { ($0.element.z, $0.offset) < ($1.element.z, $1.offset) }
            .map(\.element)
    }

    /// Fits the view to the waist and all elements in an image `aspect` wide, and resets zoom and pan.
    public mutating func zoomToFit(aspect: Double) {
        let zR = max(1e-4, beam.rayleighRange)
        let minZ: Double
        let maxZ: Double

        if let minElemZ = elements.map(\.z).min(), let maxElemZ = elements.map(\.z).max() {
            minZ = min(beam.z0 - 0.5 * zR, minElemZ - 0.1 * zR)
            maxZ = max(beam.z0 + 1.0 * zR, maxElemZ + 0.3 * zR)
        } else {
            minZ = beam.z0 - 1.5 * zR
            maxZ = beam.z0 + 1.5 * zR
        }

        let peakWaist = max(
            BeamBridge.waistAt(w0: beam.w0, z: minZ - beam.z0, zR: zR),
            BeamBridge.waistAt(w0: beam.w0, z: maxZ - beam.z0, zR: zR)
        )

        // Narrower than 16:9 the axial range would be cut off, so the whole window grows to keep the shape.
        let grow = max(1.0, 1.0 / FramingModel.axialStretch(aspect: aspect))
        let center = (minZ + maxZ) / 2.0
        framing.zMin = center - (center - minZ) * grow
        framing.zMax = center + (maxZ - center) * grow
        framing.xMax = max(1e-4, peakWaist * 2.2) * grow
        framing.panZ = 0.0
        framing.zoomScale = 1.0
    }
}
