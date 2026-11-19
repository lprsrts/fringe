import Foundation

// A Codable mirror of the core's scene JSON, schema version 3 (version 2 is read and
// upgraded). Sources, materials, elements and detectors are in the Scene*.swift files.
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
    public static let schemaVersion = 3
    /// The id the core gives the single source of a version 2 scene when it upgrades it.
    public static let upgradedSourceID = "source-1"

    public var version: Int = SimScene.schemaVersion
    /// Vacuum wavelength λ0.
    public var wavelengthUm: Double = 1.0
    public var background = Background()
    /// Only "ez" exists in this version.
    public var polarization: String = "ez"
    /// Coherent at the scene wavelength; the incident field is the sum of the enabled ones.
    public var sources: [Source] = [Source(id: SimScene.upgradedSourceID)]
    public var elements: [Element] = []
    /// Where the solved field is measured. They do not change the field.
    public var detectors: [Detector] = []
    public var domain = Domain()
    public var solver = SolverSettings()

    public init() {}

    enum CodingKeys: String, CodingKey {
        case version
        case wavelengthUm = "wavelength_um"
        case background
        case polarization
        case sources
        /// Version 2 and early version 3 files: one source without an id. Read only.
        case source
        case elements
        case detectors
        case domain
        case solver
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Upgraded in memory as the core does it; saving writes the current version.
        version = max(try c.decode(Int.self, forKey: .version), SimScene.schemaVersion)
        wavelengthUm = try c.decode(Double.self, forKey: .wavelengthUm)
        background = try c.decode(Background.self, forKey: .background)
        polarization = try c.decodeIfPresent(String.self, forKey: .polarization) ?? "ez"
        // Like the core, the upgrade keys on the `source` field rather than on the version,
        // so the version 3 files written before the source list still open.
        if c.contains(.source), !c.contains(.sources) {
            var single = try c.decode(Source.self, forKey: .source)
            single.id = SimScene.upgradedSourceID
            single.name = ""
            single.enabled = true
            sources = [single]
        } else {
            sources = try c.decode([Source].self, forKey: .sources)
        }
        elements = try c.decodeIfPresent([Element].self, forKey: .elements) ?? []
        detectors = try c.decodeIfPresent([Detector].self, forKey: .detectors) ?? []
        domain = try c.decode(Domain.self, forKey: .domain)
        solver = try c.decodeIfPresent(SolverSettings.self, forKey: .solver) ?? SolverSettings()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(wavelengthUm, forKey: .wavelengthUm)
        try c.encode(background, forKey: .background)
        try c.encode(polarization, forKey: .polarization)
        try c.encode(sources, forKey: .sources)
        try c.encode(elements, forKey: .elements)
        try c.encode(detectors, forKey: .detectors)
        try c.encode(domain, forKey: .domain)
        try c.encode(solver, forKey: .solver)
    }

    // MARK: Derived

    /// Wavelength in the background medium, λ_b = λ0 / n_b.
    public var lambdaB: Double {
        background.n > 0 ? wavelengthUm / background.n : wavelengthUm
    }

    public var enabledSources: [Source] { sources.filter(\.enabled) }

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

    public subscript(source id: String) -> Source? {
        get { sources.first { $0.id == id } }
        set {
            guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
            if let newValue {
                sources[index] = newValue
            } else {
                sources.remove(at: index)
            }
        }
    }

    public subscript(detector id: String) -> Detector? {
        get { detectors.first { $0.id == id } }
        set {
            guard let index = detectors.firstIndex(where: { $0.id == id }) else { return }
            if let newValue {
                detectors[index] = newValue
            } else {
                detectors.remove(at: index)
            }
        }
    }

    public func elementIndex(_ id: String) -> Int? {
        elements.firstIndex { $0.id == id }
    }

    public func sourceIndex(_ id: String) -> Int? {
        sources.firstIndex { $0.id == id }
    }

    public func detectorIndex(_ id: String) -> Int? {
        detectors.firstIndex { $0.id == id }
    }

    /// `"<prefix>-<n>"` with the smallest n ≥ 1 that no source or detector uses. Sources and
    /// detectors get readable ids rather than UUIDs because puzzles and saved JSON refer to
    /// them.
    public func freeID(prefix: String) -> String {
        let used = Set(sources.map(\.id) + detectors.map(\.id))
        var n = 1
        while used.contains("\(prefix)-\(n)") { n += 1 }
        return "\(prefix)-\(n)"
    }

    /// The scene without what does not change the solution (names, and the detectors, which
    /// are measured on the solved field afterwards), as sorted-key JSON. Two scenes with the
    /// same revision give the same field.
    public var physicsRevision: Data {
        PerfProbe.time("scene.physicsRevision") {
            var copy = withoutNames
            copy.detectors = []
            return (try? SimScene.jsonEncoder.encode(copy)) ?? Data()
        }
    }

    /// `physicsRevision` with the detectors: what the core's check depends on.
    public var checkRevision: Data {
        PerfProbe.time("scene.checkRevision") { (try? SimScene.jsonEncoder.encode(withoutNames)) ?? Data() }
    }

    private var withoutNames: SimScene {
        var copy = self
        for i in copy.elements.indices {
            copy.elements[i].name = ""
        }
        for i in copy.sources.indices {
            copy.sources[i].name = ""
        }
        for i in copy.detectors.indices {
            copy.detectors[i].name = ""
        }
        return copy
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
