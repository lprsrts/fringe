import Foundation

// Detectors of the scene JSON: places where the solved field is measured. A line counts
// the power through a segment; a box averages |E|² over a rectangle. Foundation only.

public enum DetectorKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case line
    case box

    public var id: String { rawValue }

    /// "Line Detector", "Box Detector".
    public var title: String {
        switch self {
        case .line: return "Line Detector"
        case .box: return "Box Detector"
        }
    }

    /// The name a detector of this kind shows when it has none.
    public var rowTitle: String {
        switch self {
        case .line: return "Line Detector"
        case .box: return "Box Detector"
        }
    }

    public var symbol: String {
        switch self {
        case .line: return "line.diagonal"
        case .box: return "square.dashed"
        }
    }
}

/// A segment from (x1, y1) to (x2, y2). Flux counts positive along the normal to the
/// right of start → end.
public struct LineGeometry: Hashable, Sendable {
    public var x1Um: Double
    public var y1Um: Double
    public var x2Um: Double
    public var y2Um: Double

    public init(x1Um: Double, y1Um: Double, x2Um: Double, y2Um: Double) {
        self.x1Um = x1Um
        self.y1Um = y1Um
        self.x2Um = x2Um
        self.y2Um = y2Um
    }
}

/// An axis-aligned rectangle centred on (x, y).
public struct BoxGeometry: Equatable, Sendable {
    public var xUm: Double
    public var yUm: Double
    public var widthUm: Double
    public var heightUm: Double

    public init(xUm: Double, yUm: Double, widthUm: Double, heightUm: Double) {
        self.xUm = xUm
        self.yUm = yUm
        self.widthUm = widthUm
        self.heightUm = heightUm
    }
}

public enum DetectorShape: Codable, Equatable, Sendable {
    case line(LineGeometry)
    case box(BoxGeometry)

    public var kind: DetectorKind {
        switch self {
        case .line: return .line
        case .box: return .box
        }
    }

    // Accessors for inspector bindings. Switching kind goes through `converted(to:)`, so a
    // getter's default is only seen by a stale binding.

    public var line: LineGeometry {
        get { if case .line(let g) = self { return g } else { return LineGeometry(x1Um: 0, y1Um: -1, x2Um: 0, y2Um: 1) } }
        set { self = .line(newValue) }
    }

    public var box: BoxGeometry {
        get { if case .box(let g) = self { return g } else { return BoxGeometry(xUm: 0, yUm: 0, widthUm: 1, heightUm: 1) } }
        set { self = .box(newValue) }
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case x1Um = "x1_um"
        case y1Um = "y1_um"
        case x2Um = "x2_um"
        case y2Um = "y2_um"
        case xUm = "x_um"
        case yUm = "y_um"
        case widthUm = "width_um"
        case heightUm = "height_um"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d(_ key: CodingKeys) throws -> Double { try c.decode(Double.self, forKey: key) }
        switch try c.decode(DetectorKind.self, forKey: .kind) {
        case .line:
            self = .line(LineGeometry(x1Um: try d(.x1Um), y1Um: try d(.y1Um), x2Um: try d(.x2Um), y2Um: try d(.y2Um)))
        case .box:
            self = .box(BoxGeometry(xUm: try d(.xUm), yUm: try d(.yUm), widthUm: try d(.widthUm), heightUm: try d(.heightUm)))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        switch self {
        case .line(let g):
            try c.encode(g.x1Um, forKey: .x1Um)
            try c.encode(g.y1Um, forKey: .y1Um)
            try c.encode(g.x2Um, forKey: .x2Um)
            try c.encode(g.y2Um, forKey: .y2Um)
        case .box(let g):
            try c.encode(g.xUm, forKey: .xUm)
            try c.encode(g.yUm, forKey: .yUm)
            try c.encode(g.widthUm, forKey: .widthUm)
            try c.encode(g.heightUm, forKey: .heightUm)
        }
    }
}

public struct Detector: Codable, Equatable, Identifiable, Sendable {
    /// Unique among the detectors; puzzles refer to detectors by id.
    public var id: String
    public var name: String = ""
    public var enabled: Bool = true
    public var shape: DetectorShape

    public init(id: String, name: String = "", enabled: Bool = true, shape: DetectorShape) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.shape = shape
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case enabled
        case shape
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        shape = try c.decode(DetectorShape.self, forKey: .shape)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(shape, forKey: .shape)
    }

    public var kind: DetectorKind { shape.kind }

    /// The name, or the kind's name when it is empty.
    public var displayName: String {
        name.isEmpty ? kind.rowTitle : name
    }

    // MARK: Geometry

    public var center: (x: Double, y: Double) {
        switch shape {
        case .line(let g): return ((g.x1Um + g.x2Um) / 2, (g.y1Um + g.y2Um) / 2)
        case .box(let g): return (g.xUm, g.yUm)
        }
    }

    /// Length of a line; 0 for a box.
    public var length: Double {
        guard case .line(let g) = shape else { return 0 }
        return hypot(g.x2Um - g.x1Um, g.y2Um - g.y1Um)
    }

    /// Direction flux counts positive along: start → end turned by −90°, counter-clockwise
    /// from +x in degrees. nil for a box or a zero-length line.
    public var normalAngleDeg: Double? {
        guard case .line(let g) = shape, length > 0 else { return nil }
        let along = atan2(g.y2Um - g.y1Um, g.x2Um - g.x1Um) * 180 / .pi
        var angle = along - 90
        if angle <= -180 { angle += 360 }
        return angle
    }

    /// The points that bound it: the two ends of a line, the four corners of a box
    /// (counter-clockwise from the lower left).
    public var points: [(x: Double, y: Double)] {
        switch shape {
        case .line(let g):
            return [(g.x1Um, g.y1Um), (g.x2Um, g.y2Um)]
        case .box(let g):
            let hw = g.widthUm / 2, hh = g.heightUm / 2
            return [(g.xUm - hw, g.yUm - hh), (g.xUm + hw, g.yUm - hh), (g.xUm + hw, g.yUm + hh), (g.xUm - hw, g.yUm + hh)]
        }
    }

    /// A line with its ends swapped, which reverses its normal; a box unchanged.
    public func flipped() -> Detector {
        var copy = self
        if case .line(let g) = shape {
            copy.shape = .line(LineGeometry(x1Um: g.x2Um, y1Um: g.y2Um, x2Um: g.x1Um, y2Um: g.y1Um))
        }
        return copy
    }

    public func moved(by dx: Double, _ dy: Double) -> Detector {
        var copy = self
        switch shape {
        case .line(let g):
            copy.shape = .line(LineGeometry(x1Um: g.x1Um + dx, y1Um: g.y1Um + dy, x2Um: g.x2Um + dx, y2Um: g.y2Um + dy))
        case .box(let g):
            copy.shape = .box(BoxGeometry(xUm: g.xUm + dx, yUm: g.yUm + dy, widthUm: g.widthUm, heightUm: g.heightUm))
        }
        return copy
    }

    /// The same detector as `kind`, about the same centre: a line of length L becomes an
    /// L × ½ λ_b box, a box becomes a vertical line as long as the box is high.
    public func converted(to kind: DetectorKind, lambdaB: Double) -> Detector {
        guard kind != self.kind else { return self }
        var copy = self
        let c = center
        switch shape {
        case .line:
            let side = max(length, lambdaB / 2)
            copy.shape = .box(BoxGeometry(xUm: c.x, yUm: c.y, widthUm: side, heightUm: lambdaB / 2))
        case .box(let g):
            let h = max(g.heightUm, lambdaB / 2)
            // Bottom to top, so the normal points along +x, the usual direction of travel.
            copy.shape = .line(LineGeometry(x1Um: c.x, y1Um: c.y - h / 2, x2Um: c.x, y2Um: c.y + h / 2))
        }
        return copy
    }
}
