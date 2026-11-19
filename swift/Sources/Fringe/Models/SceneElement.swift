import Foundation

// Elements of the scene JSON: a shape, a material and a placement. Foundation only.

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

// MARK: - Names that say the material

extension Element {
    /// Sets the material and, when the name starts with the old material's word ("Glass
    /// cylinder", "PEC cylinder", "Silver cylinder"), swaps that word for the new one, so
    /// a gold cylinder is not still called "Glass cylinder". Other names are left alone.
    public mutating func setMaterial(_ new: Material) {
        let old = material
        material = new
        guard let oldWord = Self.materialWord(old),
              name.count > oldWord.count + 1,
              name.lowercased().hasPrefix(oldWord.lowercased() + " ") else { return }
        let newWord = Self.materialWord(new)
        guard newWord != oldWord else { return }
        let rest = String(name.dropFirst(oldWord.count + 1))
        if let newWord {
            name = newWord + " " + rest
        } else {
            name = rest.prefix(1).uppercased() + rest.dropFirst()
        }
    }

    /// "PEC", the preset's name ("Gold", "BK7"), or "Glass" for a lossless index above 1.
    static func materialWord(_ material: Material) -> String? {
        switch material.kind {
        case .pec:
            return "PEC"
        case .dispersive:
            return material.preset.map(MaterialLibrary.displayName(of:))
        case .dielectric:
            if let preset = MaterialPreset.matching(material) { return preset.name }
            return material.k == 0 && material.n > 1 ? "Glass" : nil
        }
    }

}
