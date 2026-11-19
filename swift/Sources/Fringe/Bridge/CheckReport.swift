import Foundation

// Decodable mirrors of the JSON the core returns: the check report, the field
// info and the scene outlines. Keys the app does not use are ignored.

public enum IssueSeverity: String, Decodable, Sendable {
    case error
    case warning
}

public enum QualityName: String, Codable, Sendable {
    case preview
    case final

    public var title: String {
        switch self {
        case .preview: return "Preview"
        case .final: return "Final"
        }
    }

    public var code: UInt32 {
        switch self {
        case .preview: return 0
        case .final: return 1
        }
    }
}

public struct Issue: Decodable, Hashable, Sendable {
    /// JSON path into the scene, such as `elements[2].shape.r1_um`; empty for the whole scene.
    public var path: String
    public var code: String
    public var severity: IssueSeverity
    /// Plain text.
    public var message: String
    /// The message with `$…$` math, when it has any.
    public var messageMath: String?
    /// nil when the issue applies to both qualities.
    public var quality: QualityName?

    enum CodingKeys: String, CodingKey {
        case path
        case code
        case severity
        case message
        case messageMath = "message_math"
        case quality
    }

    public init(path: String, code: String, severity: IssueSeverity, message: String, messageMath: String? = nil, quality: QualityName? = nil) {
        self.path = path
        self.code = code
        self.severity = severity
        self.message = message
        self.messageMath = messageMath
        self.quality = quality
    }

    public var isError: Bool { severity == .error }

    public func applies(to quality: QualityName) -> Bool {
        self.quality == nil || self.quality == quality
    }

    /// The index of a `<collection>[i]…` path: 2 for `elements[2].shape.r1_um` in
    /// "elements".
    public func index(in collection: String) -> Int? {
        let prefix = collection + "["
        guard path.hasPrefix(prefix) else { return nil }
        let digits = path.dropFirst(prefix.count).prefix { $0.isNumber }
        return Int(digits)
    }

    /// The element index of an `elements[i]…` path.
    public var elementIndex: Int? { index(in: "elements") }

    /// The last key of the path: `r1_um` for `elements[0].shape.r1_um`, `waist_um` for
    /// `source.waist_um`.
    public var fieldKey: String? {
        guard let last = path.split(separator: ".").last else { return nil }
        let key = last.split(separator: "[").first.map(String.init) ?? String(last)
        return key.isEmpty ? nil : key
    }

    /// The message with its first letter capitalised and a closing full stop.
    public var sentence: String { Self.sentence(message) }

    /// `sentence` with its math marked up, for `MathText`.
    public var mathSentence: String { Self.sentence(messageMath ?? MathTypesetter.escaped(message)) }

    private static func sentence(_ message: String) -> String {
        guard let first = message.first else { return message }
        var text = first.uppercased() + message.dropFirst()
        if !text.hasSuffix(".") { text += "." }
        return text
    }
}

public struct EstimateReport: Decodable, Equatable, Sendable {
    public var method: SolverMethod
    public var ppw: Double
    public var unknowns: Double
    public var memoryMb: Double
    public var seconds: Double
    public var grid: [Int]?
    public var detail: String

    enum CodingKeys: String, CodingKey {
        case method
        case ppw
        case unknowns
        case memoryMb = "memory_mb"
        case seconds
        case grid
        case detail
    }

    /// "150k cells · 0.2 s".
    public var summary: String {
        "\(SceneFormat.count(unknowns)) \(method.unknownsNoun) · \(SceneFormat.seconds(seconds))"
    }
}

public struct Estimates: Decodable, Equatable, Sendable {
    public var preview: EstimateReport?
    public var final: EstimateReport?

    enum CodingKeys: String, CodingKey {
        case preview
        case final
    }
}

/// Paraxial and textbook quantities for the inspector. Not solver output.
public struct Derived: Decodable, Equatable, Sendable {
    public struct SourceInfo: Decodable, Equatable, Sendable {
        /// Empty in the version 2 `source` object.
        public var id: String
        public var rayleighRangeUm: Double?
        public var divergenceDeg: Double?

        enum CodingKeys: String, CodingKey {
            case id
            case rayleighRangeUm = "rayleigh_range_um"
            case divergenceDeg = "divergence_deg"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
            rayleighRangeUm = try c.decodeIfPresent(Double.self, forKey: .rayleighRangeUm)
            divergenceDeg = try c.decodeIfPresent(Double.self, forKey: .divergenceDeg)
        }
    }

    public struct LensInfo: Decodable, Equatable, Sendable {
        public var paraxialFocalUm: Double?
        public var backFocalUm: Double?
        public var edgeThicknessUm: Double?
        public var paraxialFocusUm: [Double]?

        enum CodingKeys: String, CodingKey {
            case paraxialFocalUm = "paraxial_focal_um"
            case backFocalUm = "back_focal_um"
            case edgeThicknessUm = "edge_thickness_um"
            case paraxialFocusUm = "paraxial_focus_um"
        }
    }

    public struct MirrorInfo: Decodable, Equatable, Sendable {
        public var focalUm: Double?

        enum CodingKeys: String, CodingKey {
            case focalUm = "focal_um"
        }
    }

    public struct GratingOrder: Decodable, Equatable, Sendable {
        public var m: Int
        public var angleDeg: Double

        enum CodingKeys: String, CodingKey {
            case m
            case angleDeg = "angle_deg"
        }
    }

    public struct GratingInfo: Decodable, Equatable, Sendable {
        public var orders: [GratingOrder]
    }

    public struct SlitsInfo: Decodable, Equatable, Sendable {
        public var singleSlitNullDeg: Double?
        public var fringeSpacingDeg: Double?

        enum CodingKeys: String, CodingKey {
            case singleSlitNullDeg = "single_slit_null_deg"
            case fringeSpacingDeg = "fringe_spacing_deg"
        }
    }

    public struct CylinderInfo: Decodable, Equatable, Sendable {
        public var sizeParameter: Double

        enum CodingKeys: String, CodingKey {
            case sizeParameter = "size_parameter"
        }
    }

    public struct WaveguideInfo: Decodable, Equatable, Sendable {
        public var vNumber: Double
        public var guidedModes: Int

        enum CodingKeys: String, CodingKey {
            case vNumber = "v_number"
            case guidedModes = "guided_modes"
        }
    }

    public struct PrismInfo: Decodable, Equatable, Sendable {
        public var minDeviationDeg: Double?

        enum CodingKeys: String, CodingKey {
            case minDeviationDeg = "min_deviation_deg"
        }
    }

    public struct ElementInfo: Decodable, Equatable, Sendable {
        public var id: String
        public var lens: LensInfo?
        public var mirror: MirrorInfo?
        public var grating: GratingInfo?
        public var slits: SlitsInfo?
        public var cylinder: CylinderInfo?
        public var waveguide: WaveguideInfo?
        public var prism: PrismInfo?
        /// n + ik and ε at λ0 of a dielectric or Lorentz–Drude element; nil for PEC.
        public var material: EffectiveIndex?
    }

    public var lambdaBUm: Double
    public var lambdaMinUm: Double
    /// Per source, by id.
    public var sources: [SourceInfo]
    public var elements: [ElementInfo]

    enum CodingKeys: String, CodingKey {
        case lambdaBUm = "lambda_b_um"
        case lambdaMinUm = "lambda_min_um"
        case source
        case sources
        case elements
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lambdaBUm = try c.decode(Double.self, forKey: .lambdaBUm)
        lambdaMinUm = try c.decode(Double.self, forKey: .lambdaMinUm)
        // An older core sends only `source`.
        sources = try c.decodeIfPresent([SourceInfo].self, forKey: .sources)
            ?? c.decodeIfPresent(SourceInfo.self, forKey: .source).map { [$0] } ?? []
        elements = try c.decodeIfPresent([ElementInfo].self, forKey: .elements) ?? []
    }

    public func element(_ id: String) -> ElementInfo? {
        elements.first { $0.id == id }
    }

    public func source(_ id: String) -> SourceInfo? {
        sources.first { $0.id == id }
    }
}

public struct CheckReport: Decodable, Equatable, Sendable {
    /// True when nothing blocks a preview solve.
    public var ok: Bool
    public var issues: [Issue]
    public var estimates: Estimates?
    public var derived: Derived?

    enum CodingKeys: String, CodingKey {
        case ok
        case issues
        case estimates
        case derived
    }

    public init(ok: Bool, issues: [Issue], estimates: Estimates? = nil, derived: Derived? = nil) {
        self.ok = ok
        self.issues = issues
        self.estimates = estimates
        self.derived = derived
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decode(Bool.self, forKey: .ok)
        issues = try c.decodeIfPresent([Issue].self, forKey: .issues) ?? []
        estimates = try c.decodeIfPresent(Estimates.self, forKey: .estimates)
        // `derived` is null for a scene that does not parse.
        derived = try? c.decodeIfPresent(Derived.self, forKey: .derived)
    }

    public var errors: [Issue] { issues.filter(\.isError) }

    /// Whether a solve at `quality` would be refused.
    public func isBlocked(_ quality: QualityName) -> Bool {
        issues.contains { $0.isError && $0.applies(to: quality) }
    }

    /// The first error that blocks a preview.
    public var firstError: Issue? {
        issues.first { $0.isError && $0.applies(to: .preview) }
    }

    /// Issues about element `index`.
    public func issues(forElement index: Int) -> [Issue] {
        issues.filter { $0.elementIndex == index }
    }

    /// Issues about source `index` (paths `sources[i]…`).
    public func issues(forSource index: Int) -> [Issue] {
        issues.filter { $0.index(in: "sources") == index }
    }

    /// Issues about detector `index` (paths `detectors[i]…`).
    public func issues(forDetector index: Int) -> [Issue] {
        issues.filter { $0.index(in: "detectors") == index }
    }

    /// Issues whose path starts with `prefix` (for example `source` or `solver`).
    public func issues(withPrefix prefix: String) -> [Issue] {
        issues.filter { $0.path == prefix || $0.path.hasPrefix(prefix + ".") || $0.path.hasPrefix(prefix + "[") }
    }
}

// MARK: - Field info

public struct GridInfo: Decodable, Equatable, Sendable {
    public var x0Um: Double
    public var y0Um: Double
    public var dxUm: Double
    public var nx: Int
    public var ny: Int

    enum CodingKeys: String, CodingKey {
        case x0Um = "x0_um"
        case y0Um = "y0_um"
        case dxUm = "dx_um"
        case nx
        case ny
    }

    public var rect: RectUm {
        RectUm(xMin: x0Um, xMax: x0Um + Double(nx - 1) * dxUm, yMin: y0Um, yMax: y0Um + Double(ny - 1) * dxUm)
    }
}

public struct SolveMeta: Decodable, Equatable, Sendable {
    public var unknowns: Double
    public var periods: Double?
    public var converged: Bool
    public var residual: Double?
    public var condEstimate: Double?
    public var warnings: [String]
    public var method: SolverMethod
    public var quality: QualityName
    public var ppw: Double
    public var incidentKind: String
    public var wallS: Double
    /// Peak memory of the solve, when the core reports it.
    public var memoryMb: Double?

    enum CodingKeys: String, CodingKey {
        case unknowns
        case periods
        case converged
        case residual
        case condEstimate = "cond_estimate"
        case warnings
        case method
        case quality
        case ppw
        case incidentKind = "incident_kind"
        case wallS = "wall_s"
        case memoryMb = "memory_mb"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        unknowns = try c.decodeIfPresent(Double.self, forKey: .unknowns) ?? 0
        periods = try c.decodeIfPresent(Double.self, forKey: .periods)
        converged = try c.decodeIfPresent(Bool.self, forKey: .converged) ?? true
        residual = try c.decodeIfPresent(Double.self, forKey: .residual)
        condEstimate = try c.decodeIfPresent(Double.self, forKey: .condEstimate)
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
        method = try c.decode(SolverMethod.self, forKey: .method)
        quality = try c.decode(QualityName.self, forKey: .quality)
        ppw = try c.decodeIfPresent(Double.self, forKey: .ppw) ?? 0
        incidentKind = try c.decodeIfPresent(String.self, forKey: .incidentKind) ?? "analytic"
        wallS = try c.decodeIfPresent(Double.self, forKey: .wallS) ?? 0
        memoryMb = try c.decodeIfPresent(Double.self, forKey: .memoryMb)
    }
}

public struct BodyInfo: Decodable, Equatable, Sendable {
    public var elementId: String
    public var name: String
    public var pec: Bool
    public var n: Double
    public var k: Double

    enum CodingKeys: String, CodingKey {
        case elementId = "element_id"
        case name
        case pec
        case n
        case k
    }
}

public struct FieldInfo: Decodable, Equatable, Sendable {
    public var grid: GridInfo
    public var domain: Domain
    public var pmlUm: Double
    public var wavelengthUm: Double
    public var backgroundN: Double
    public var incidentPeak: Double
    public var totalPeak: Double
    public var quality: QualityName
    public var method: SolverMethod
    public var meta: SolveMeta
    public var bodies: [BodyInfo]
    /// One per enabled detector, in scene order.
    public var detectors: [DetectorReading]

    enum CodingKeys: String, CodingKey {
        case grid
        case domain
        case pmlUm = "pml_um"
        case wavelengthUm = "wavelength_um"
        case backgroundN = "background_n"
        case incidentPeak = "incident_peak"
        case totalPeak = "total_peak"
        case quality
        case method
        case meta
        case bodies
        case detectors
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        grid = try c.decode(GridInfo.self, forKey: .grid)
        domain = try c.decode(Domain.self, forKey: .domain)
        pmlUm = try c.decode(Double.self, forKey: .pmlUm)
        wavelengthUm = try c.decode(Double.self, forKey: .wavelengthUm)
        backgroundN = try c.decode(Double.self, forKey: .backgroundN)
        incidentPeak = try c.decode(Double.self, forKey: .incidentPeak)
        totalPeak = try c.decode(Double.self, forKey: .totalPeak)
        quality = try c.decode(QualityName.self, forKey: .quality)
        method = try c.decode(SolverMethod.self, forKey: .method)
        meta = try c.decode(SolveMeta.self, forKey: .meta)
        bodies = try c.decode([BodyInfo].self, forKey: .bodies)
        detectors = try c.decodeIfPresent([DetectorReading].self, forKey: .detectors) ?? []
    }

    public func reading(_ detectorID: String) -> DetectorReading? {
        detectors.first { $0.id == detectorID }
    }
}

// MARK: - Outlines

public struct SceneOutlines: Decodable, Equatable, Sendable {
    public struct Body: Decodable, Equatable, Sendable {
        public var elementId: String
        /// False for a disabled element: drawn dashed, not part of the solve.
        public var enabled: Bool
        public var pec: Bool
        /// Closed polyline, [x, y] pairs in µm.
        public var outline: [[Double]]

        enum CodingKeys: String, CodingKey {
            case elementId = "element_id"
            case enabled
            case pec
            case outline
        }
    }

    /// The first enabled source in the version 2 shape. The app draws sources from the
    /// scene, so this is not used for drawing.
    public struct SourceGlyph: Decodable, Equatable, Sendable {
        public var kind: SourceKind
        /// Waist centre for a Gaussian beam, the domain centre for a plane wave.
        public var waistUm: [Double]
        public var angleDeg: Double?
        public var w0Um: Double?

        enum CodingKeys: String, CodingKey {
            case kind
            case waistUm = "waist_um"
            case angleDeg = "angle_deg"
            case w0Um = "w0_um"
        }
    }

    public var domain: Domain
    public var pmlUm: Double
    public var bodies: [Body]
    /// Optional: a later core may drop it, and a scene without an enabled source has none.
    public var source: SourceGlyph?

    enum CodingKeys: String, CodingKey {
        case domain
        case pmlUm = "pml_um"
        case bodies
        case source
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        domain = try c.decode(Domain.self, forKey: .domain)
        pmlUm = try c.decode(Double.self, forKey: .pmlUm)
        bodies = try c.decode([Body].self, forKey: .bodies)
        source = try? c.decodeIfPresent(SourceGlyph.self, forKey: .source)
    }

    public func bodies(of elementID: String) -> [Body] {
        bodies.filter { $0.elementId == elementID }
    }
}
