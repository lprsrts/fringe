import Foundation

// Decodable mirrors of the core's material library, material curves, detector readings and
// puzzles. Everything not certain to be present decodes with `decodeIfPresent`, so an extra
// or missing optional key never breaks decoding; a change of shape touches only this file.

// MARK: - Materials

/// One entry of `fringe_material_presets()`: a Lorentz–Drude fit with its source.
public struct MaterialLibraryEntry: Decodable, Equatable, Identifiable, Sendable {
    public var id: String
    /// "Gold", "BK7".
    public var name: String
    /// "metal" or "glass".
    public var kind: String
    /// Where the numbers come from, for a footer.
    public var source: String
    /// Wavelengths in µm the fit is good for.
    public var rangeUm: ClosedRange<Double>?
    public var material: Material

    public var isMetal: Bool { kind == "metal" }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case kind
        case source
        case rangeUm = "range_um"
        case material
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        if let range = try c.decodeIfPresent([Double].self, forKey: .rangeUm), range.count == 2, range[0] <= range[1] {
            rangeUm = range[0]...range[1]
        }
        material = try c.decode(Material.self, forKey: .material)
    }
}

/// The core's preset library, read once.
public enum MaterialLibrary {
    public static let entries: [MaterialLibraryEntry] = FringeBridge.materialLibrary()

    public static func entry(_ id: String) -> MaterialLibraryEntry? {
        entries.first { $0.id == id }
    }

    /// "Gold" for "gold"; an id the library does not know is shown capitalised, with
    /// underscores as spaces.
    public static func displayName(of id: String) -> String {
        if let entry = entry(id) { return entry.name }
        let words = id.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

/// n + ik and ε1 + iε2 at one wavelength, in the optics convention (k ≥ 0 and ε2 ≥ 0
/// absorb), which is how the app shows them. The core solves in n − jk; it converts.
public struct EffectiveIndex: Decodable, Equatable, Sendable {
    public var n: Double
    public var k: Double
    public var eps1: Double
    public var eps2: Double

    public init(n: Double, k: Double, eps1: Double, eps2: Double) {
        self.n = n
        self.k = k
        self.eps1 = eps1
        self.eps2 = eps2
    }

    enum CodingKeys: String, CodingKey {
        case n
        case k
        case eps1
        case eps2
        case epsRe = "eps_re"
        case epsIm = "eps_im"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        n = try c.decode(Double.self, forKey: .n)
        k = try c.decodeIfPresent(Double.self, forKey: .k) ?? 0
        eps1 = try c.decodeIfPresent(Double.self, forKey: .eps1) ?? c.decodeIfPresent(Double.self, forKey: .epsRe) ?? (n * n - k * k)
        eps2 = try c.decodeIfPresent(Double.self, forKey: .eps2) ?? c.decodeIfPresent(Double.self, forKey: .epsIm) ?? (2 * n * k)
    }
}

/// n and k of a material over a range of wavelengths, for the material chart, and the
/// value at the scene wavelength.
public struct MaterialCurve: Equatable, Sendable {
    public var wavelengthUm: [Double]
    public var n: [Double]
    public var k: [Double]
    public var eps1: [Double]
    public var eps2: [Double]
    /// At λ0.
    public var at: EffectiveIndex?
}

// MARK: - Detector readings

/// One entry of the field info's `detectors`: a line's power flux or a box's |E|².
public struct DetectorReading: Decodable, Equatable, Identifiable, Sendable {
    /// Power per µm in z, positive along the normal (η0 = 1: a plane wave of amplitude A in
    /// background n_b carries n_b A²/2 per µm).
    public struct Flux: Decodable, Equatable, Sendable {
        public var total: Double
        public var incident: Double
        public var scattered: Double

        /// A value the core could not compute comes as null and decodes as NaN, which
        /// every readout shows as a dash.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            total = try c.decodeIfPresent(Double.self, forKey: .total) ?? .nan
            incident = try c.decodeIfPresent(Double.self, forKey: .incident) ?? .nan
            scattered = try c.decodeIfPresent(Double.self, forKey: .scattered) ?? (total - incident)
        }

        enum CodingKeys: String, CodingKey {
            case total
            case incident
            case scattered
        }
    }

    /// |E|² over a box: its mean, its integral in µm² and its largest sample.
    public struct Intensity: Decodable, Equatable, Sendable {
        /// NaN when the core sends null.
        public var mean: Double
        public var integral: Double?
        public var max: Double?

        enum CodingKeys: String, CodingKey {
            case mean
            case integral
            case max
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            mean = try c.decodeIfPresent(Double.self, forKey: .mean) ?? .nan
            integral = try c.decodeIfPresent(Double.self, forKey: .integral)
            max = try c.decodeIfPresent(Double.self, forKey: .max)
        }
    }

    public var id: String
    public var name: String
    public var kind: DetectorKind
    public var lengthUm: Double?
    /// Unit normal of a line, the direction its flux counts positive along.
    public var normal: [Double]?
    public var flux: Flux?
    public var areaUm2: Double?
    public var total: Intensity?
    public var incident: Intensity?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case kind
        case lengthUm = "length_um"
        case normal
        case flux
        case areaUm2 = "area_um2"
        case total
        case incident
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try c.decode(DetectorKind.self, forKey: .kind)
        lengthUm = try c.decodeIfPresent(Double.self, forKey: .lengthUm)
        normal = try? c.decodeIfPresent([Double].self, forKey: .normal)
        flux = try c.decodeIfPresent(Flux.self, forKey: .flux)
        areaUm2 = try c.decodeIfPresent(Double.self, forKey: .areaUm2)
        total = try c.decodeIfPresent(Intensity.self, forKey: .total)
        incident = try c.decodeIfPresent(Intensity.self, forKey: .incident)
    }

    /// The total value: a line's net flux, a box's mean |E|².
    public var totalValue: Double? {
        kind == .line ? flux?.total : total?.mean
    }

    /// The same without the elements: the incident field alone.
    public var incidentValue: Double? {
        kind == .line ? flux?.incident : incident?.mean
    }

    /// Total over incident; nil when the incident value is zero or not finite (a detector
    /// in the shadow of nothing, or one no source reaches).
    public var ratio: Double? {
        guard let t = totalValue, let i = incidentValue, i.isFinite, t.isFinite, abs(i) > 0 else { return nil }
        return t / i
    }
}

// MARK: - Puzzles

/// One entry of `fringe_puzzle_list()`.
public struct PuzzleSummary: Decodable, Equatable, Identifiable, Sendable {
    public var id: String
    public var chapter: String
    public var chapterTitle: String?
    public var order: Int
    public var title: String
    public var summary: String
    public var goalType: String?
    /// The three score thresholds.
    public var stars: [Double]

    enum CodingKeys: String, CodingKey {
        case id
        case chapter
        case chapterTitle = "chapter_title"
        case order
        case title
        case summary
        case goalType = "goal_type"
        case stars
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        chapter = try c.decodeIfPresent(String.self, forKey: .chapter) ?? ""
        chapterTitle = try c.decodeIfPresent(String.self, forKey: .chapterTitle)
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? id
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        goalType = try c.decodeIfPresent(String.self, forKey: .goalType)
        stars = try c.decodeIfPresent([Double].self, forKey: .stars) ?? []
    }
}

public struct PuzzleGoal: Decodable, Equatable, Sendable {
    public struct Output: Decodable, Equatable, Sendable {
        public var detector: String
        /// One per input case, 0 or 1.
        public var bits: [Int]

        enum CodingKeys: String, CodingKey {
            case detector
            case bits
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            detector = try c.decode(String.self, forKey: .detector)
            bits = try c.decodeIfPresent([Int].self, forKey: .bits) ?? []
        }
    }

    /// `truth_table`, `maximize`, `minimize` or `target`.
    public var type: String
    /// Pass threshold in the metric's unit.
    public var pass: Double?
    /// The core's own one-line goal, when it sends one.
    public var text: String?
    public var outputs: [Output]
    public var detector: String?
    public var detectors: [String]
    public var ratio: Double?
    public var tolerance: Double?
    /// `minimize`: "scattered", "flux" or "intensity".
    public var quantity: String?
    /// What detector values are divided by: "source", "incident", or a fixed number (then
    /// nil here).
    public var reference: String?
    /// A fixed reference: a flux per µm or an |E|².
    public var referenceValue: Double?
    /// The source the "source" reference is taken from; nil: the first input, else the
    /// first enabled source.
    public var referenceSource: String?

    enum CodingKeys: String, CodingKey {
        case type
        case pass
        case text
        case outputs
        case detector
        case detectors
        case ratio
        case tolerance
        case quantity
        case reference
        case referenceSource = "reference_source"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        pass = try c.decodeIfPresent(Double.self, forKey: .pass)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        outputs = try c.decodeIfPresent([Output].self, forKey: .outputs) ?? []
        detector = try c.decodeIfPresent(String.self, forKey: .detector)
        detectors = try c.decodeIfPresent([String].self, forKey: .detectors) ?? []
        ratio = try c.decodeIfPresent(Double.self, forKey: .ratio)
        tolerance = try c.decodeIfPresent(Double.self, forKey: .tolerance)
        quantity = try c.decodeIfPresent(String.self, forKey: .quantity)
        reference = try? c.decodeIfPresent(String.self, forKey: .reference)
        referenceValue = try? c.decodeIfPresent(Double.self, forKey: .reference)
        referenceSource = try c.decodeIfPresent(String.self, forKey: .referenceSource)
    }
}

public struct PaletteEntry: Decodable, Equatable, Sendable {
    public var kind: ShapeKind
    /// "pec", a preset id or a key of `PuzzleRules.materials`. Empty allows any material.
    public var materials: [String]
    /// nil: no limit.
    public var max: Int?

    enum CodingKeys: String, CodingKey {
        case kind
        case materials
        case max
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(ShapeKind.self, forKey: .kind)
        materials = try c.decodeIfPresent([String].self, forKey: .materials) ?? []
        max = try c.decodeIfPresent(Int.self, forKey: .max)
    }
}

public struct PuzzleRules: Decodable, Equatable, Sendable {
    public var locked: [String]
    /// Where the player's elements must lie.
    public var region: RectUm?
    public var palette: [PaletteEntry]
    public var maxElements: Int?
    /// The puzzle's own materials by palette name.
    public var materials: [String: Material]
    /// Their display names ("Dense glass (n = 2)"), when the puzzle gives one.
    public var materialNames: [String: String]

    public init(locked: [String], region: RectUm?, palette: [PaletteEntry], maxElements: Int?,
                materials: [String: Material], materialNames: [String: String] = [:]) {
        self.locked = locked
        self.region = region
        self.palette = palette
        self.maxElements = maxElements
        self.materials = materials
        self.materialNames = materialNames
    }

    private struct Named: Decodable {
        var name: String?
    }

    enum CodingKeys: String, CodingKey {
        case locked
        case region
        case palette
        case maxElements = "max_elements"
        case materials
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        locked = try c.decodeIfPresent([String].self, forKey: .locked) ?? []
        if let r = try c.decodeIfPresent([Double].self, forKey: .region), r.count == 4 {
            region = RectUm(xMin: r[0], xMax: r[1], yMin: r[2], yMax: r[3])
        }
        palette = try c.decodeIfPresent([PaletteEntry].self, forKey: .palette) ?? []
        maxElements = try c.decodeIfPresent(Int.self, forKey: .maxElements)
        materials = try c.decodeIfPresent([String: Material].self, forKey: .materials) ?? [:]
        let named = (try? c.decodeIfPresent([String: Named].self, forKey: .materials)) ?? [:]
        materialNames = named.compactMapValues(\.name)
    }
}

public struct PuzzleScoring: Decodable, Equatable, Sendable {
    public var method: SolverMethod
    /// The preview resolution scoring uses; nil: the method's default.
    public var ppw: Double?

    enum CodingKeys: String, CodingKey {
        case method
        case ppw
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        method = try c.decodeIfPresent(SolverMethod.self, forKey: .method) ?? .fem
        ppw = try c.decodeIfPresent(Double.self, forKey: .ppw)
    }
}

/// A whole puzzle, `fringe_puzzle_get(id)`.
public struct Puzzle: Decodable, Equatable, Identifiable, Sendable {
    public var id: String
    public var chapter: String
    public var order: Int
    public var title: String
    public var summary: String
    public var hints: [String]
    public var scene: SimScene
    /// Source ids switched on and off as the input bits, most significant first.
    public var inputs: [String]
    public var goal: PuzzleGoal
    public var rules: PuzzleRules
    public var scoring: PuzzleScoring?
    public var stars: [Double]
    /// Elements of one known solution.
    public var reference: [Element]

    enum CodingKeys: String, CodingKey {
        case id
        case chapter
        case order
        case title
        case summary
        case hints
        case scene
        case inputs
        case goal
        case rules
        case scoring
        case stars
        case reference
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        chapter = try c.decodeIfPresent(String.self, forKey: .chapter) ?? ""
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? id
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        hints = try c.decodeIfPresent([String].self, forKey: .hints) ?? []
        scene = try c.decode(SimScene.self, forKey: .scene)
        inputs = try c.decodeIfPresent([String].self, forKey: .inputs) ?? []
        goal = try c.decode(PuzzleGoal.self, forKey: .goal)
        rules = try c.decodeIfPresent(PuzzleRules.self, forKey: .rules) ?? PuzzleRules.none
        scoring = try c.decodeIfPresent(PuzzleScoring.self, forKey: .scoring)
        stars = try c.decodeIfPresent([Double].self, forKey: .stars) ?? []
        reference = try c.decodeIfPresent([Element].self, forKey: .reference) ?? []
    }
}

extension PuzzleRules {
    /// No restrictions, for a puzzle without `rules`.
    static let none = PuzzleRules(locked: [], region: nil, palette: [], maxElements: nil, materials: [:])
}

/// How a puzzle evaluation scored: "contrast" in dB, "share" in %, ….
public struct PuzzleMetric: Decodable, Equatable, Sendable {
    public var label: String
    public var unit: String
    /// null when a detector value is not finite.
    public var value: Double?
    /// "weakest 1 is 0.81, strongest 0 is 0.05".
    public var text: String?

    enum CodingKeys: String, CodingKey {
        case label
        case unit
        case value
        case text
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        unit = try c.decodeIfPresent(String.self, forKey: .unit) ?? ""
        value = try c.decodeIfPresent(Double.self, forKey: .value)
        text = try c.decodeIfPresent(String.self, forKey: .text)
    }
}

/// One goal detector's value in one case, over the puzzle's reference.
public struct PuzzleCaseOutput: Decodable, Equatable, Sendable {
    public var detector: String
    /// The wanted bit; null unless the goal is a truth table.
    public var target: Bool?
    /// null when not finite.
    public var value: Double?

    enum CodingKeys: String, CodingKey {
        case detector
        case target
        case value
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        detector = try c.decodeIfPresent(String.self, forKey: .detector) ?? ""
        target = try c.decodeIfPresent(Bool.self, forKey: .target)
        value = try c.decodeIfPresent(Double.self, forKey: .value)
    }
}

public struct PuzzleCase: Decodable, Equatable, Sendable {
    public var bits: [Bool]
    /// [re, im] per per-source field, in the order of `PuzzleEvaluation.sources`.
    public var weights: [[Double]]
    public var readings: [DetectorReading]
    public var outputs: [PuzzleCaseOutput]

    enum CodingKeys: String, CodingKey {
        case bits
        case weights
        case readings
        case outputs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bits = try c.decodeIfPresent([Bool].self, forKey: .bits) ?? []
        weights = try c.decodeIfPresent([[Double]].self, forKey: .weights) ?? []
        readings = try c.decodeIfPresent([DetectorReading].self, forKey: .readings) ?? []
        outputs = try c.decodeIfPresent([PuzzleCaseOutput].self, forKey: .outputs) ?? []
    }
}

/// The JSON part of a puzzle evaluation.
public struct PuzzleEvaluation: Decodable, Equatable, Sendable {
    public var puzzle: String
    public var valid: Bool
    public var issues: [Issue]
    /// Order of the per-source fields.
    public var sources: [String]
    public var inputs: [String]
    public var cases: [PuzzleCase]
    public var metric: PuzzleMetric?
    public var score: Double?
    public var pass: Double?
    public var passed: Bool
    public var stars: Int
    public var starThresholds: [Double]
    public var wallS: Double?
    public var goalType: String?
    public var method: SolverMethod?
    public var ppw: Double?

    enum CodingKeys: String, CodingKey {
        case puzzle
        case valid
        case issues
        case sources
        case inputs
        case cases
        case metric
        case score
        case pass
        case passed
        case stars
        case starThresholds = "star_thresholds"
        case wallS = "wall_s"
        case goalType = "goal_type"
        case method
        case ppw
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        puzzle = try c.decodeIfPresent(String.self, forKey: .puzzle) ?? ""
        valid = try c.decodeIfPresent(Bool.self, forKey: .valid) ?? false
        issues = try c.decodeIfPresent([Issue].self, forKey: .issues) ?? []
        sources = try c.decodeIfPresent([String].self, forKey: .sources) ?? []
        inputs = try c.decodeIfPresent([String].self, forKey: .inputs) ?? []
        cases = try c.decodeIfPresent([PuzzleCase].self, forKey: .cases) ?? []
        metric = try c.decodeIfPresent(PuzzleMetric.self, forKey: .metric)
        score = try c.decodeIfPresent(Double.self, forKey: .score)
        pass = try c.decodeIfPresent(Double.self, forKey: .pass)
        passed = try c.decodeIfPresent(Bool.self, forKey: .passed) ?? false
        stars = try c.decodeIfPresent(Int.self, forKey: .stars) ?? 0
        starThresholds = try c.decodeIfPresent([Double].self, forKey: .starThresholds) ?? []
        wallS = try c.decodeIfPresent(Double.self, forKey: .wallS)
        goalType = try c.decodeIfPresent(String.self, forKey: .goalType)
        method = try? c.decodeIfPresent(SolverMethod.self, forKey: .method)
        ppw = try c.decodeIfPresent(Double.self, forKey: .ppw)
    }

    /// The case with these input bits (the only case when the puzzle has no inputs).
    public func `case`(bits: [Bool]) -> PuzzleCase? {
        cases.first { $0.bits == bits } ?? (cases.count == 1 && bits.isEmpty ? cases.first : nil)
    }
}
