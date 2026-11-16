import Foundation

// A Codable mirror of the core's scene JSON, schema version 2.
//
// Lengths are micrometres and angles degrees. Keys are spelled out in `CodingKeys`
// so the JSON matches the core exactly. Optional settings are written as `null`
// rather than left out, and every field the core defaults is decoded with the
// same default, so a minimal hand-written scene opens.
//
// This file has no SwiftUI or AppKit dependency: the schema self-test and the
// command-line harness compile it on its own.

public enum SolverMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case fdtd
    case fem
    case mom

    public var id: String { rawValue }

    /// "FDTD", "FEM", "MoM".
    public var title: String {
        switch self {
        case .fdtd: return "FDTD"
        case .fem: return "FEM"
        case .mom: return "MoM"
        }
    }

    public var explainer: String {
        switch self {
        case .fdtd: return "Time domain on a grid; staircased corners, slow to settle on sharp resonances."
        case .fem: return "Frequency domain on a mesh; accurate curved interfaces."
        case .mom: return "Boundary integrals; exact radiation, needs separate bodies."
        }
    }

    /// What the resolution setting counts.
    public var ppwNoun: String {
        switch self {
        case .fdtd: return "cells"
        case .fem: return "nodes"
        case .mom: return "panels"
        }
    }

    /// What the unknowns of a solve are called.
    public var unknownsNoun: String {
        switch self {
        case .fdtd: return "cells"
        case .fem: return "DOFs"
        case .mom: return "unknowns"
        }
    }

    /// Defaults from the core's table, for showing what an empty override means.
    public func defaultPPW(final: Bool) -> Double {
        switch self {
        case .fdtd: return final ? 24 : 10
        case .fem: return final ? 15 : 9
        case .mom: return final ? 16 : 8
        }
    }
}

public struct SimScene: Codable, Equatable, Sendable {
    public static let schemaVersion = 2

    public var version: Int = SimScene.schemaVersion
    /// Vacuum wavelength λ0.
    public var wavelengthUm: Double = 1.0
    public var background = Background()
    /// Only "ez" exists in this version.
    public var polarization: String = "ez"
    public var source = Source()
    public var elements: [Element] = []
    public var domain = Domain()
    public var solver = SolverSettings()

    public init() {}

    enum CodingKeys: String, CodingKey {
        case version
        case wavelengthUm = "wavelength_um"
        case background
        case polarization
        case source
        case elements
        case domain
        case solver
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        wavelengthUm = try c.decode(Double.self, forKey: .wavelengthUm)
        background = try c.decode(Background.self, forKey: .background)
        polarization = try c.decodeIfPresent(String.self, forKey: .polarization) ?? "ez"
        source = try c.decode(Source.self, forKey: .source)
        elements = try c.decodeIfPresent([Element].self, forKey: .elements) ?? []
        domain = try c.decode(Domain.self, forKey: .domain)
        solver = try c.decodeIfPresent(SolverSettings.self, forKey: .solver) ?? SolverSettings()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(wavelengthUm, forKey: .wavelengthUm)
        try c.encode(background, forKey: .background)
        try c.encode(polarization, forKey: .polarization)
        try c.encode(source, forKey: .source)
        try c.encode(elements, forKey: .elements)
        try c.encode(domain, forKey: .domain)
        try c.encode(solver, forKey: .solver)
    }

    // MARK: Derived

    /// Wavelength in the background medium, λ_b = λ0 / n_b.
    public var lambdaB: Double {
        background.n > 0 ? wavelengthUm / background.n : wavelengthUm
    }

    public subscript(element id: String) -> Element? {
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

    public func elementIndex(_ id: String) -> Int? {
        elements.firstIndex { $0.id == id }
    }

    /// The scene without what does not change the solution (element names), as sorted-key
    /// JSON. Two scenes with the same revision give the same field.
    public var physicsRevision: Data {
        var copy = self
        for i in copy.elements.indices {
            copy.elements[i].name = ""
        }
        return (try? SimScene.jsonEncoder.encode(copy)) ?? Data()
    }

    public static var jsonEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }

    public func jsonString(pretty: Bool = false) -> String {
        let encoder = SimScene.jsonEncoder
        if pretty {
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        }
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    public static func decode(json: String) throws -> SimScene {
        try JSONDecoder().decode(SimScene.self, from: Data(json.utf8))
    }
}

public struct Background: Codable, Equatable, Sendable {
    /// Real refractive index of the surrounding medium, 1…4.
    public var n: Double = 1.0

    public init(n: Double = 1.0) {
        self.n = n
    }

    enum CodingKeys: String, CodingKey {
        case n
    }
}

// MARK: - Source

public enum SourceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case gaussianBeam = "gaussian_beam"
    case planeWave = "plane_wave"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .gaussianBeam: return "Gaussian Beam"
        case .planeWave: return "Plane Wave"
        }
    }
}

/// The incident field. Both kinds share one struct so switching kind in the inspector keeps
/// the angle, amplitude and phase; the waist fields are written only for a Gaussian beam.
public struct Source: Codable, Equatable, Sendable {
    public var kind: SourceKind = .gaussianBeam
    /// w0: the 1/e field radius (1/e² intensity radius) in the background medium.
    public var waistUm: Double = 3.0
    /// Waist centre, as if no elements were present.
    public var waistXUm: Double = -6.0
    public var waistYUm: Double = 0.0
    /// Propagation direction, counter-clockwise from +x.
    public var angleDeg: Double = 0.0
    public var amplitude: Double = 1.0
    public var phaseDeg: Double = 0.0

    public init() {}

    enum CodingKeys: String, CodingKey {
        case type
        case waistUm = "waist_um"
        case waistXUm = "waist_x_um"
        case waistYUm = "waist_y_um"
        case angleDeg = "angle_deg"
        case amplitude
        case phaseDeg = "phase_deg"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(SourceKind.self, forKey: .type)
        amplitude = try c.decodeIfPresent(Double.self, forKey: .amplitude) ?? 1.0
        phaseDeg = try c.decodeIfPresent(Double.self, forKey: .phaseDeg) ?? 0.0
        switch kind {
        case .planeWave:
            angleDeg = try c.decode(Double.self, forKey: .angleDeg)
        case .gaussianBeam:
            waistUm = try c.decode(Double.self, forKey: .waistUm)
            waistXUm = try c.decode(Double.self, forKey: .waistXUm)
            waistYUm = try c.decode(Double.self, forKey: .waistYUm)
            angleDeg = try c.decodeIfPresent(Double.self, forKey: .angleDeg) ?? 0.0
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .type)
        if kind == .gaussianBeam {
            try c.encode(waistUm, forKey: .waistUm)
            try c.encode(waistXUm, forKey: .waistXUm)
            try c.encode(waistYUm, forKey: .waistYUm)
        }
        try c.encode(angleDeg, forKey: .angleDeg)
        try c.encode(amplitude, forKey: .amplitude)
        try c.encode(phaseDeg, forKey: .phaseDeg)
    }

    /// Equal when the JSON is equal: a plane wave's hidden waist values do not count.
    public static func == (a: Source, b: Source) -> Bool {
        guard a.kind == b.kind, a.angleDeg == b.angleDeg, a.amplitude == b.amplitude, a.phaseDeg == b.phaseDeg else {
            return false
        }
        return a.kind == .planeWave
            || (a.waistUm == b.waistUm && a.waistXUm == b.waistXUm && a.waistYUm == b.waistYUm)
    }
}

// MARK: - Material

public enum MaterialKind: String, Codable, CaseIterable, Sendable {
    case dielectric
    case pec
}

/// A dielectric `n + ik` (k ≥ 0 absorbs) or a perfect electric conductor. Switching to PEC
/// keeps n and k, so switching back restores them.
public struct Material: Codable, Equatable, Sendable {
    public var kind: MaterialKind = .dielectric
    public var n: Double = 1.5
    public var k: Double = 0.0

    public init(kind: MaterialKind = .dielectric, n: Double = 1.5, k: Double = 0.0) {
        self.kind = kind
        self.n = n
        self.k = k
    }

    public static let pec = Material(kind: .pec)

    public static func glass(_ n: Double, k: Double = 0) -> Material {
        Material(kind: .dielectric, n: n, k: k)
    }

    public var isPEC: Bool { kind == .pec }

    enum CodingKeys: String, CodingKey {
        case type
        case n
        case k
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(MaterialKind.self, forKey: .type)
        if kind == .dielectric {
            n = try c.decode(Double.self, forKey: .n)
            k = try c.decodeIfPresent(Double.self, forKey: .k) ?? 0.0
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .type)
        if kind == .dielectric {
            try c.encode(n, forKey: .n)
            try c.encode(k, forKey: .k)
        }
    }

    public static func == (a: Material, b: Material) -> Bool {
        a.kind == b.kind && (a.kind == .pec || (a.n == b.n && a.k == b.k))
    }

    /// "$n$ 1.50", "$n$ 1.50 + 0.050$\mathrm{i}$" or "PEC", for `MathText`: the index as it is
    /// entered, n + ik.
    public var badge: String {
        switch kind {
        case .pec:
            return "PEC"
        case .dielectric:
            let n = "$n$ " + SceneFormat.fixed(self.n, 2)
            return k > 0 ? n + " + \(SceneFormat.fixed(k, 3))" + #"$\mathrm{i}$"# : n
        }
    }
}

/// A named material with its index near 633 nm.
public struct MaterialPreset: Identifiable, Hashable, Sendable {
    public var name: String
    public var n: Double

    public var id: String { name }

    public static let all: [MaterialPreset] = [
        MaterialPreset(name: "BK7", n: 1.5168),
        MaterialPreset(name: "Fused Silica", n: 1.457),
        MaterialPreset(name: "PMMA", n: 1.49),
        MaterialPreset(name: "Si₃N₄", n: 2.02),
        MaterialPreset(name: "Sapphire", n: 1.766),
        MaterialPreset(name: "Water", n: 1.333),
    ]

    /// The preset whose index `material` has, if any.
    public static func matching(_ material: Material) -> MaterialPreset? {
        guard material.kind == .dielectric, material.k == 0 else { return nil }
        return all.first { abs($0.n - material.n) < 1e-9 }
    }
}

// MARK: - Element

public struct Element: Codable, Equatable, Identifiable, Sendable {
    /// Unique within the scene; `UUID().uuidString` for elements made in the app.
    public var id: String
    public var name: String
    public var enabled: Bool = true
    public var material: Material
    /// Anchor; where it sits on the shape depends on the shape.
    public var xUm: Double
    public var yUm: Double
    /// Counter-clockwise about the anchor; local +x is the element's optical axis.
    public var rotationDeg: Double = 0
    public var shape: Shape

    public init(
        id: String = UUID().uuidString,
        name: String,
        enabled: Bool = true,
        material: Material,
        xUm: Double,
        yUm: Double,
        rotationDeg: Double = 0,
        shape: Shape
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.material = material
        self.xUm = xUm
        self.yUm = yUm
        self.rotationDeg = rotationDeg
        self.shape = shape
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case enabled
        case material
        case xUm = "x_um"
        case yUm = "y_um"
        case rotationDeg = "rotation_deg"
        case shape
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        material = try c.decode(Material.self, forKey: .material)
        xUm = try c.decode(Double.self, forKey: .xUm)
        yUm = try c.decode(Double.self, forKey: .yUm)
        rotationDeg = try c.decodeIfPresent(Double.self, forKey: .rotationDeg) ?? 0
        shape = try c.decode(Shape.self, forKey: .shape)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(material, forKey: .material)
        try c.encode(xUm, forKey: .xUm)
        try c.encode(yUm, forKey: .yUm)
        try c.encode(rotationDeg, forKey: .rotationDeg)
        try c.encode(shape, forKey: .shape)
    }

    public var kind: ShapeKind { shape.kind }

    /// The name, or the kind's name when it is empty.
    public var displayName: String {
        name.isEmpty ? kind.title : name
    }

    /// Mirrors and slits are always PEC.
    public var requiresPEC: Bool { kind.requiresPEC }
}

// MARK: - Shapes

public enum ShapeKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case lens
    case slab
    case wedge
    case prism
    case cylinder
    case waveguide
    case grating
    case polygon
    case mirror
    case slits

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .lens: return "Lens"
        case .slab: return "Slab"
        case .wedge: return "Wedge"
        case .prism: return "Prism"
        case .mirror: return "Mirror"
        case .slits: return "Slits"
        case .grating: return "Grating"
        case .cylinder: return "Cylinder"
        case .waveguide: return "Waveguide"
        case .polygon: return "Polygon"
        }
    }

    public var symbol: String {
        switch self {
        case .lens: return "oval.portrait"
        case .slab: return "rectangle.portrait"
        case .wedge: return "triangle.righthalf.filled"
        case .prism: return "triangle"
        case .mirror: return "circle.lefthalf.filled"
        case .slits: return "line.3.horizontal"
        case .grating: return "square.split.1x2"
        case .cylinder: return "circle"
        case .waveguide: return "rectangle"
        case .polygon: return "pentagon"
        }
    }

    public var requiresPEC: Bool { self == .mirror || self == .slits }

    /// Shapes that are usually glass, then shapes that are usually metal.
    public static let refractive: [ShapeKind] = [.lens, .slab, .wedge, .prism, .cylinder, .waveguide, .grating, .polygon]
    public static let opaque: [ShapeKind] = [.mirror, .slits]

    /// A new element of this kind centred on `center`.
    public func makeElement(at center: (x: Double, y: Double)) -> Element {
        let glass = Material.glass(1.5)
        let shape: Shape
        var material = glass
        switch self {
        case .lens:
            shape = .lens(Lens())
        case .slab:
            shape = .slab(Slab())
        case .wedge:
            shape = .wedge(Wedge())
        case .prism:
            shape = .prism(Prism())
            material = .glass(1.5168)
        case .mirror:
            shape = .mirror(Mirror())
            material = .pec
        case .slits:
            shape = .slits(Slits())
            material = .pec
        case .grating:
            shape = .grating(Grating())
        case .cylinder:
            shape = .cylinder(Cylinder())
            material = .glass(1.6)
        case .waveguide:
            shape = .waveguide(Waveguide())
            material = .glass(2.0)
        case .polygon:
            shape = .polygon(Polygon())
        }
        return Element(name: title, material: material, xUm: center.x, yUm: center.y, shape: shape)
    }
}

public struct Lens: Equatable, Sendable {
    /// Optics sign convention: R > 0 has its centre of curvature on +x. nil is flat.
    public var r1Um: Double? = 12
    public var r2Um: Double? = -12
    public var centerThicknessUm: Double = 3
    public var apertureUm: Double = 10
}

public struct Slab: Equatable, Sendable {
    public var thicknessUm: Double = 2
    public var heightUm: Double = 12
}

public struct Wedge: Equatable, Sendable {
    public var thickUm: Double = 3
    public var thinUm: Double = 1
    public var heightUm: Double = 10
}

public struct Prism: Equatable, Sendable {
    public var baseUm: Double = 8
    public var apexDeg: Double = 60
}

public struct Mirror: Equatable, Sendable {
    public var apertureUm: Double = 12
    public var thicknessUm: Double = 0.5
    /// R > 0 is concave toward −x; nil is flat.
    public var radiusUm: Double?
}

public struct Slits: Equatable, Sendable {
    public var count: Int = 2
    public var slitWidthUm: Double = 1
    public var pitchUm: Double = 4
    public var screenHeightUm: Double = 16
    public var thicknessUm: Double = 0.5
}

public struct Grating: Equatable, Sendable {
    public var periodUm: Double = 2
    public var fillFactor: Double = 0.5
    public var depthUm: Double = 1
    public var count: Int = 7
    public var substrateUm: Double = 0
}

public struct Cylinder: Equatable, Sendable {
    public var radiusUm: Double = 1.5
}

public struct Waveguide: Equatable, Sendable {
    public var widthUm: Double = 0.8
    public var lengthUm: Double = 12
}

public struct Polygon: Equatable, Sendable {
    /// Local vertices; the core normalises them to counter-clockwise.
    public var verticesUm: [[Double]] = [[-2, -2], [2, -2], [0, 2]]
}

public enum Shape: Equatable, Sendable {
    case lens(Lens)
    case slab(Slab)
    case wedge(Wedge)
    case prism(Prism)
    case mirror(Mirror)
    case slits(Slits)
    case grating(Grating)
    case cylinder(Cylinder)
    case waveguide(Waveguide)
    case polygon(Polygon)

    public var kind: ShapeKind {
        switch self {
        case .lens: return .lens
        case .slab: return .slab
        case .wedge: return .wedge
        case .prism: return .prism
        case .mirror: return .mirror
        case .slits: return .slits
        case .grating: return .grating
        case .cylinder: return .cylinder
        case .waveguide: return .waveguide
        case .polygon: return .polygon
        }
    }

    // Accessors for inspector bindings. An element never changes kind, so the getters'
    // defaults are never seen; they keep a stale binding from crashing.

    public var lens: Lens {
        get { if case .lens(let v) = self { return v } else { return Lens() } }
        set { self = .lens(newValue) }
    }

    public var slab: Slab {
        get { if case .slab(let v) = self { return v } else { return Slab() } }
        set { self = .slab(newValue) }
    }

    public var wedge: Wedge {
        get { if case .wedge(let v) = self { return v } else { return Wedge() } }
        set { self = .wedge(newValue) }
    }

    public var prism: Prism {
        get { if case .prism(let v) = self { return v } else { return Prism() } }
        set { self = .prism(newValue) }
    }

    public var mirror: Mirror {
        get { if case .mirror(let v) = self { return v } else { return Mirror() } }
        set { self = .mirror(newValue) }
    }

    public var slits: Slits {
        get { if case .slits(let v) = self { return v } else { return Slits() } }
        set { self = .slits(newValue) }
    }

    public var grating: Grating {
        get { if case .grating(let v) = self { return v } else { return Grating() } }
        set { self = .grating(newValue) }
    }

    public var cylinder: Cylinder {
        get { if case .cylinder(let v) = self { return v } else { return Cylinder() } }
        set { self = .cylinder(newValue) }
    }

    public var waveguide: Waveguide {
        get { if case .waveguide(let v) = self { return v } else { return Waveguide() } }
        set { self = .waveguide(newValue) }
    }

    public var polygon: Polygon {
        get { if case .polygon(let v) = self { return v } else { return Polygon() } }
        set { self = .polygon(newValue) }
    }
}

extension Shape: Codable {
    enum CodingKeys: String, CodingKey {
        case kind
        case r1Um = "r1_um"
        case r2Um = "r2_um"
        case centerThicknessUm = "center_thickness_um"
        case apertureUm = "aperture_um"
        case thicknessUm = "thickness_um"
        case heightUm = "height_um"
        case thickUm = "thick_um"
        case thinUm = "thin_um"
        case baseUm = "base_um"
        case apexDeg = "apex_deg"
        case radiusUm = "radius_um"
        case count
        case slitWidthUm = "slit_width_um"
        case pitchUm = "pitch_um"
        case screenHeightUm = "screen_height_um"
        case periodUm = "period_um"
        case fillFactor = "fill_factor"
        case depthUm = "depth_um"
        case substrateUm = "substrate_um"
        case widthUm = "width_um"
        case lengthUm = "length_um"
        case verticesUm = "vertices_um"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(ShapeKind.self, forKey: .kind)
        func d(_ key: CodingKeys) throws -> Double { try c.decode(Double.self, forKey: key) }
        func opt(_ key: CodingKeys) throws -> Double? { try c.decodeIfPresent(Double.self, forKey: key) }
        switch kind {
        case .lens:
            self = .lens(Lens(
                r1Um: try opt(.r1Um),
                r2Um: try opt(.r2Um),
                centerThicknessUm: try d(.centerThicknessUm),
                apertureUm: try d(.apertureUm)
            ))
        case .slab:
            self = .slab(Slab(thicknessUm: try d(.thicknessUm), heightUm: try d(.heightUm)))
        case .wedge:
            self = .wedge(Wedge(thickUm: try d(.thickUm), thinUm: try d(.thinUm), heightUm: try d(.heightUm)))
        case .prism:
            self = .prism(Prism(baseUm: try d(.baseUm), apexDeg: try d(.apexDeg)))
        case .mirror:
            self = .mirror(Mirror(apertureUm: try d(.apertureUm), thicknessUm: try d(.thicknessUm), radiusUm: try opt(.radiusUm)))
        case .slits:
            self = .slits(Slits(
                count: try c.decode(Int.self, forKey: .count),
                slitWidthUm: try d(.slitWidthUm),
                pitchUm: try d(.pitchUm),
                screenHeightUm: try d(.screenHeightUm),
                thicknessUm: try d(.thicknessUm)
            ))
        case .grating:
            self = .grating(Grating(
                periodUm: try d(.periodUm),
                fillFactor: try d(.fillFactor),
                depthUm: try d(.depthUm),
                count: try c.decode(Int.self, forKey: .count),
                substrateUm: try opt(.substrateUm) ?? 0
            ))
        case .cylinder:
            self = .cylinder(Cylinder(radiusUm: try d(.radiusUm)))
        case .waveguide:
            self = .waveguide(Waveguide(widthUm: try d(.widthUm), lengthUm: try d(.lengthUm)))
        case .polygon:
            self = .polygon(Polygon(verticesUm: try c.decode([[Double]].self, forKey: .verticesUm)))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        switch self {
        case .lens(let s):
            // Optionals are written as null so the JSON says "flat" explicitly.
            try c.encode(s.r1Um, forKey: .r1Um)
            try c.encode(s.r2Um, forKey: .r2Um)
            try c.encode(s.centerThicknessUm, forKey: .centerThicknessUm)
            try c.encode(s.apertureUm, forKey: .apertureUm)
        case .slab(let s):
            try c.encode(s.thicknessUm, forKey: .thicknessUm)
            try c.encode(s.heightUm, forKey: .heightUm)
        case .wedge(let s):
            try c.encode(s.thickUm, forKey: .thickUm)
            try c.encode(s.thinUm, forKey: .thinUm)
            try c.encode(s.heightUm, forKey: .heightUm)
        case .prism(let s):
            try c.encode(s.baseUm, forKey: .baseUm)
            try c.encode(s.apexDeg, forKey: .apexDeg)
        case .mirror(let s):
            try c.encode(s.apertureUm, forKey: .apertureUm)
            try c.encode(s.thicknessUm, forKey: .thicknessUm)
            try c.encode(s.radiusUm, forKey: .radiusUm)
        case .slits(let s):
            try c.encode(s.count, forKey: .count)
            try c.encode(s.slitWidthUm, forKey: .slitWidthUm)
            try c.encode(s.pitchUm, forKey: .pitchUm)
            try c.encode(s.screenHeightUm, forKey: .screenHeightUm)
            try c.encode(s.thicknessUm, forKey: .thicknessUm)
        case .grating(let s):
            try c.encode(s.periodUm, forKey: .periodUm)
            try c.encode(s.fillFactor, forKey: .fillFactor)
            try c.encode(s.depthUm, forKey: .depthUm)
            try c.encode(s.count, forKey: .count)
            try c.encode(s.substrateUm, forKey: .substrateUm)
        case .cylinder(let s):
            try c.encode(s.radiusUm, forKey: .radiusUm)
        case .waveguide(let s):
            try c.encode(s.widthUm, forKey: .widthUm)
            try c.encode(s.lengthUm, forKey: .lengthUm)
        case .polygon(let s):
            try c.encode(s.verticesUm, forKey: .verticesUm)
        }
    }
}

// MARK: - Domain

/// The interior rectangle the image shows; the absorbing layer (PML) lies outside it.
public struct Domain: Codable, Equatable, Sendable {
    public var xMinUm: Double = -12
    public var xMaxUm: Double = 20
    public var yMinUm: Double = -9
    public var yMaxUm: Double = 9
    /// PML thickness in background wavelengths, 0.5…4.
    public var pmlWl: Double = 1

    public init() {}

    public init(x: ClosedRange<Double>, y: ClosedRange<Double>, pmlWl: Double = 1) {
        xMinUm = x.lowerBound
        xMaxUm = x.upperBound
        yMinUm = y.lowerBound
        yMaxUm = y.upperBound
        self.pmlWl = pmlWl
    }

    enum CodingKeys: String, CodingKey {
        case xMinUm = "x_min_um"
        case xMaxUm = "x_max_um"
        case yMinUm = "y_min_um"
        case yMaxUm = "y_max_um"
        case pmlWl = "pml_wl"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        xMinUm = try c.decode(Double.self, forKey: .xMinUm)
        xMaxUm = try c.decode(Double.self, forKey: .xMaxUm)
        yMinUm = try c.decode(Double.self, forKey: .yMinUm)
        yMaxUm = try c.decode(Double.self, forKey: .yMaxUm)
        pmlWl = try c.decodeIfPresent(Double.self, forKey: .pmlWl) ?? 1
    }

    public var width: Double { xMaxUm - xMinUm }
    public var height: Double { yMaxUm - yMinUm }
    public var centerX: Double { (xMinUm + xMaxUm) / 2 }
    public var centerY: Double { (yMinUm + yMaxUm) / 2 }
    public var aspect: Double { height > 0 ? width / height : 1 }

    public var rect: RectUm {
        RectUm(xMin: xMinUm, xMax: xMaxUm, yMin: yMinUm, yMax: yMaxUm)
    }

    /// Sets the centre and size, keeping the PML.
    public mutating func set(centerX: Double, centerY: Double, width: Double, height: Double) {
        xMinUm = centerX - width / 2
        xMaxUm = centerX + width / 2
        yMinUm = centerY - height / 2
        yMaxUm = centerY + height / 2
    }

    public mutating func set(_ rect: RectUm) {
        xMinUm = rect.xMin
        xMaxUm = rect.xMax
        yMinUm = rect.yMin
        yMaxUm = rect.yMax
    }

    /// The shape lock: height = width / aspect, about the centre.
    public mutating func applyAspect(_ aspect: Double) {
        guard aspect.isFinite, aspect > 0 else { return }
        set(centerX: centerX, centerY: centerY, width: width, height: width / aspect)
    }
}

/// An axis-aligned rectangle in micrometres.
public struct RectUm: Codable, Equatable, Sendable {
    public var xMin: Double
    public var xMax: Double
    public var yMin: Double
    public var yMax: Double

    public init(xMin: Double, xMax: Double, yMin: Double, yMax: Double) {
        self.xMin = xMin
        self.xMax = xMax
        self.yMin = yMin
        self.yMax = yMax
    }

    enum CodingKeys: String, CodingKey {
        case xMin = "x_min_um"
        case xMax = "x_max_um"
        case yMin = "y_min_um"
        case yMax = "y_max_um"
    }

    public var width: Double { xMax - xMin }
    public var height: Double { yMax - yMin }
    public var centerX: Double { (xMin + xMax) / 2 }
    public var centerY: Double { (yMin + yMax) / 2 }

    public func insetBy(_ d: Double) -> RectUm {
        RectUm(xMin: xMin + d, xMax: xMax - d, yMin: yMin + d, yMax: yMax - d)
    }

    public func union(_ o: RectUm) -> RectUm {
        RectUm(xMin: min(xMin, o.xMin), xMax: max(xMax, o.xMax), yMin: min(yMin, o.yMin), yMax: max(yMax, o.yMax))
    }

    public func contains(x: Double, y: Double) -> Bool {
        x >= xMin && x <= xMax && y >= yMin && y <= yMax
    }

    /// A rectangle `width` wide and `width / aspect` high about the same centre, or grown
    /// in one direction so it covers this one at that aspect.
    public func grown(toAspect aspect: Double) -> RectUm {
        guard aspect > 0, width > 0, height > 0 else { return self }
        var w = width
        var h = height
        if w / h > aspect { h = w / aspect } else { w = h * aspect }
        return RectUm(xMin: centerX - w / 2, xMax: centerX + w / 2, yMin: centerY - h / 2, yMax: centerY + h / 2)
    }
}

// MARK: - Solver settings

public enum PecFormulation: String, Codable, CaseIterable, Sendable {
    case auto
    case cfie
    case efie

    public var title: String {
        switch self {
        case .auto: return "Automatic"
        case .cfie: return "CFIE"
        case .efie: return "EFIE"
        }
    }
}

public struct SolverSettings: Codable, Equatable, Sendable {
    public var method: SolverMethod = .fdtd
    public var fdtd = FdtdSettings()
    public var fem = FemSettings()
    public var mom = MomSettings()
    public var output = OutputSampling()
    public var memoryLimitMb: Double?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case method
        case fdtd
        case fem
        case mom
        case output
        case memoryLimitMb = "memory_limit_mb"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        method = try c.decodeIfPresent(SolverMethod.self, forKey: .method) ?? .fdtd
        fdtd = try c.decodeIfPresent(FdtdSettings.self, forKey: .fdtd) ?? FdtdSettings()
        fem = try c.decodeIfPresent(FemSettings.self, forKey: .fem) ?? FemSettings()
        mom = try c.decodeIfPresent(MomSettings.self, forKey: .mom) ?? MomSettings()
        output = try c.decodeIfPresent(OutputSampling.self, forKey: .output) ?? OutputSampling()
        memoryLimitMb = try c.decodeIfPresent(Double.self, forKey: .memoryLimitMb)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(method, forKey: .method)
        try c.encode(fdtd, forKey: .fdtd)
        try c.encode(fem, forKey: .fem)
        try c.encode(mom, forKey: .mom)
        try c.encode(output, forKey: .output)
        try c.encode(memoryLimitMb, forKey: .memoryLimitMb)
    }

    /// The per-quality resolution override of the chosen method, nil for the default.
    public func ppwOverride(final: Bool) -> Double? {
        switch method {
        case .fdtd: return final ? fdtd.finalPpw : fdtd.previewPpw
        case .fem: return final ? fem.finalPpw : fem.previewPpw
        case .mom: return final ? mom.finalPpw : mom.previewPpw
        }
    }

    /// Resolution the chosen method uses at a quality.
    public func ppw(final: Bool) -> Double {
        ppwOverride(final: final) ?? method.defaultPPW(final: final)
    }
}

public struct FdtdSettings: Codable, Equatable, Sendable {
    public var previewPpw: Double?
    public var finalPpw: Double?
    public var courant: Double = 0.6
    public var maxPeriods: Int?
    public var steadyTol: Double?
    public var subpixel = true
    public var dispersionCorrection = true

    public init() {}

    enum CodingKeys: String, CodingKey {
        case previewPpw = "preview_ppw"
        case finalPpw = "final_ppw"
        case courant
        case maxPeriods = "max_periods"
        case steadyTol = "steady_tol"
        case subpixel
        case dispersionCorrection = "dispersion_correction"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        previewPpw = try c.decodeIfPresent(Double.self, forKey: .previewPpw)
        finalPpw = try c.decodeIfPresent(Double.self, forKey: .finalPpw)
        courant = try c.decodeIfPresent(Double.self, forKey: .courant) ?? 0.6
        maxPeriods = try c.decodeIfPresent(Int.self, forKey: .maxPeriods)
        steadyTol = try c.decodeIfPresent(Double.self, forKey: .steadyTol)
        subpixel = try c.decodeIfPresent(Bool.self, forKey: .subpixel) ?? true
        dispersionCorrection = try c.decodeIfPresent(Bool.self, forKey: .dispersionCorrection) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(previewPpw, forKey: .previewPpw)
        try c.encode(finalPpw, forKey: .finalPpw)
        try c.encode(courant, forKey: .courant)
        try c.encode(maxPeriods, forKey: .maxPeriods)
        try c.encode(steadyTol, forKey: .steadyTol)
        try c.encode(subpixel, forKey: .subpixel)
        try c.encode(dispersionCorrection, forKey: .dispersionCorrection)
    }
}

public struct FemSettings: Codable, Equatable, Sendable {
    public var previewPpw: Double?
    public var finalPpw: Double?
    public var order = 3
    public var pmlReflection = 1e-6

    public init() {}

    enum CodingKeys: String, CodingKey {
        case previewPpw = "preview_ppw"
        case finalPpw = "final_ppw"
        case order
        case pmlReflection = "pml_reflection"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        previewPpw = try c.decodeIfPresent(Double.self, forKey: .previewPpw)
        finalPpw = try c.decodeIfPresent(Double.self, forKey: .finalPpw)
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 3
        pmlReflection = try c.decodeIfPresent(Double.self, forKey: .pmlReflection) ?? 1e-6
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(previewPpw, forKey: .previewPpw)
        try c.encode(finalPpw, forKey: .finalPpw)
        try c.encode(order, forKey: .order)
        try c.encode(pmlReflection, forKey: .pmlReflection)
    }
}

public struct MomSettings: Codable, Equatable, Sendable {
    public var previewPpw: Double?
    public var finalPpw: Double?
    public var pecFormulation: PecFormulation = .auto
    public var cfieBetaScale = 1.0
    public var cornerGrading = true

    public init() {}

    enum CodingKeys: String, CodingKey {
        case previewPpw = "preview_ppw"
        case finalPpw = "final_ppw"
        case pecFormulation = "pec_formulation"
        case cfieBetaScale = "cfie_beta_scale"
        case cornerGrading = "corner_grading"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        previewPpw = try c.decodeIfPresent(Double.self, forKey: .previewPpw)
        finalPpw = try c.decodeIfPresent(Double.self, forKey: .finalPpw)
        pecFormulation = try c.decodeIfPresent(PecFormulation.self, forKey: .pecFormulation) ?? .auto
        cfieBetaScale = try c.decodeIfPresent(Double.self, forKey: .cfieBetaScale) ?? 1
        cornerGrading = try c.decodeIfPresent(Bool.self, forKey: .cornerGrading) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(previewPpw, forKey: .previewPpw)
        try c.encode(finalPpw, forKey: .finalPpw)
        try c.encode(pecFormulation, forKey: .pecFormulation)
        try c.encode(cfieBetaScale, forKey: .cfieBetaScale)
        try c.encode(cornerGrading, forKey: .cornerGrading)
    }
}

public struct OutputSampling: Codable, Equatable, Sendable {
    public var previewPpw: Double?
    public var finalPpw: Double?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case previewPpw = "preview_ppw"
        case finalPpw = "final_ppw"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        previewPpw = try c.decodeIfPresent(Double.self, forKey: .previewPpw)
        finalPpw = try c.decodeIfPresent(Double.self, forKey: .finalPpw)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(previewPpw, forKey: .previewPpw)
        try c.encode(finalPpw, forKey: .finalPpw)
    }
}

// MARK: - Formatting

/// Fixed-precision readouts (estimates, captions, preset names, the legend) with the
/// user's decimal separator, like every other number in the window.
public enum SceneFormat {
    public static func fixed(_ value: Double, _ digits: Int, locale: Locale = .current) -> String {
        let s = Format.number(value, digits: digits...digits, locale: locale)
        // No "−0.00".
        if s.hasPrefix("−"), !s.dropFirst().contains(where: { $0.isNumber && $0 != "0" }) {
            return String(s.dropFirst())
        }
        return s
    }

    /// "153k", "1.2M".
    public static func count(_ value: Double) -> String {
        if value >= 1e6 { return "\(fixed(value / 1e6, value >= 1e7 ? 0 : 1))M" }
        if value >= 1e3 { return "\(fixed(value / 1e3, 0))k" }
        return fixed(value, 0)
    }

    /// "0.2 s", "6 s", "2 min".
    public static func seconds(_ s: Double) -> String {
        guard s.isFinite else { return "—" }
        if s < 10 { return "\(fixed(s, 1)) s" }
        if s < 120 { return "\(fixed(s, 0)) s" }
        return "\(fixed(s / 60, 0)) min"
    }

    /// "40 MB", "1.2 GB".
    public static func megabytes(_ mb: Double) -> String {
        guard mb.isFinite else { return "—" }
        if mb >= 1024 { return "\(fixed(mb / 1024, 1)) GB" }
        return "\(fixed(max(mb, 1), 0)) MB"
    }
}
