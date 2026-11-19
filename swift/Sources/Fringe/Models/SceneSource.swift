import Foundation

// Sources of the scene JSON (schema version 3): Gaussian beams, plane waves and point
// emitters, all coherent at the scene wavelength. Foundation only, like `SimScene.swift`.

public enum SourceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case gaussianBeam = "gaussian_beam"
    case planeWave = "plane_wave"
    case lineSource = "line_source"

    public var id: String { rawValue }

    /// The kind as a form label or menu item: "Gaussian Beam", "Plane Wave", "Point Emitter".
    public var title: String {
        switch self {
        case .gaussianBeam: return "Gaussian Beam"
        case .planeWave: return "Plane Wave"
        case .lineSource: return "Point Emitter"
        }
    }

    /// The name a source of this kind shows when it has none.
    public var rowTitle: String {
        switch self {
        case .gaussianBeam: return "Gaussian Beam"
        case .planeWave: return "Plane Wave"
        case .lineSource: return "Emitter"
        }
    }

    public var symbol: String {
        switch self {
        case .gaussianBeam: return "light.beacon.max"
        case .planeWave: return "water.waves"
        case .lineSource: return "dot.radiowaves.left.and.right"
        }
    }

    /// The prefix of ids the app gives new sources of this kind ("beam-2", "emitter-3").
    public var idPrefix: String {
        switch self {
        case .gaussianBeam: return "beam"
        case .planeWave: return "wave"
        case .lineSource: return "emitter"
        }
    }

    /// Plane waves and beams travel along an angle; an emitter radiates in every direction.
    public var hasDirection: Bool { self != .lineSource }
}

/// One source. All kinds share one struct, so switching kind in the inspector keeps the
/// position, angle, amplitude and phase; only the keys of the current kind are written.
public struct Source: Codable, Equatable, Identifiable, Sendable {
    /// Unique among the sources; puzzles refer to sources by id.
    public var id: String
    public var name: String = ""
    public var enabled: Bool = true
    public var kind: SourceKind = .gaussianBeam
    /// w0: the 1/e field radius (1/e² intensity radius) in the background medium.
    public var waistUm: Double = 3.0
    /// Waist centre of a Gaussian beam (as if no elements were present); position of an
    /// emitter. Unused by a plane wave.
    public var xUm: Double = -6.0
    public var yUm: Double = 0.0
    /// Propagation direction, counter-clockwise from +x. Unused by an emitter.
    public var angleDeg: Double = 0.0
    public var amplitude: Double = 1.0
    public var phaseDeg: Double = 0.0

    public init(id: String, name: String = "", enabled: Bool = true, kind: SourceKind = .gaussianBeam) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.kind = kind
    }

    /// The name, or the kind's name when it is empty.
    public var displayName: String {
        name.isEmpty ? kind.rowTitle : name
    }

    enum CodingKeys: String, CodingKey {
        case type
        case id
        case name
        case enabled
        case waistUm = "waist_um"
        case waistXUm = "waist_x_um"
        case waistYUm = "waist_y_um"
        case xUm = "x_um"
        case yUm = "y_um"
        case angleDeg = "angle_deg"
        case amplitude
        case phaseDeg = "phase_deg"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(SourceKind.self, forKey: .type)
        // A version 2 source has no id; `SimScene` gives it the core's upgrade id.
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        amplitude = try c.decodeIfPresent(Double.self, forKey: .amplitude) ?? 1.0
        phaseDeg = try c.decodeIfPresent(Double.self, forKey: .phaseDeg) ?? 0.0
        switch kind {
        case .planeWave:
            angleDeg = try c.decode(Double.self, forKey: .angleDeg)
        case .gaussianBeam:
            waistUm = try c.decode(Double.self, forKey: .waistUm)
            xUm = try c.decode(Double.self, forKey: .waistXUm)
            yUm = try c.decode(Double.self, forKey: .waistYUm)
            angleDeg = try c.decodeIfPresent(Double.self, forKey: .angleDeg) ?? 0.0
        case .lineSource:
            xUm = try c.decode(Double.self, forKey: .xUm)
            yUm = try c.decode(Double.self, forKey: .yUm)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .type)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(enabled, forKey: .enabled)
        switch kind {
        case .gaussianBeam:
            try c.encode(waistUm, forKey: .waistUm)
            try c.encode(xUm, forKey: .waistXUm)
            try c.encode(yUm, forKey: .waistYUm)
            try c.encode(angleDeg, forKey: .angleDeg)
        case .planeWave:
            try c.encode(angleDeg, forKey: .angleDeg)
        case .lineSource:
            try c.encode(xUm, forKey: .xUm)
            try c.encode(yUm, forKey: .yUm)
        }
        try c.encode(amplitude, forKey: .amplitude)
        try c.encode(phaseDeg, forKey: .phaseDeg)
    }

    /// Equal when the JSON is equal: values the current kind does not write do not count.
    public static func == (a: Source, b: Source) -> Bool {
        guard a.id == b.id, a.name == b.name, a.enabled == b.enabled, a.kind == b.kind,
              a.amplitude == b.amplitude, a.phaseDeg == b.phaseDeg else {
            return false
        }
        switch a.kind {
        case .planeWave:
            return a.angleDeg == b.angleDeg
        case .gaussianBeam:
            return a.angleDeg == b.angleDeg && a.waistUm == b.waistUm && a.xUm == b.xUm && a.yUm == b.yUm
        case .lineSource:
            return a.xUm == b.xUm && a.yUm == b.yUm
        }
    }
}
