import Foundation

// How a solved field is shown: quantity, colormap, scaling, phase and overlays. Changing
// any of it re-renders the cached field and never solves again.
//
// No SwiftUI or AppKit here: the command-line harness compiles this file on its own.

public enum Quantity: String, Codable, CaseIterable, Identifiable, Sendable {
    case intensity
    case magnitude
    case real
    case phase

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .intensity: return "Intensity"
        case .magnitude: return "Magnitude"
        case .real: return "Real Part"
        case .phase: return "Phase"
        }
    }

    /// Short label for the toolbar picker and captions.
    public var symbol: String {
        switch self {
        case .intensity: return "|E|²"
        case .magnitude: return "|E|"
        case .real: return "Re E"
        case .phase: return "∠E"
        }
    }

    public var systemImage: String {
        switch self {
        case .intensity: return "sun.max"
        case .magnitude: return "waveform.path.ecg"
        case .real: return "waveform"
        case .phase: return "circle.dotted.circle"
        }
    }

    /// The colormaps that suit this quantity.
    public var colormapKind: ColormapKind {
        switch self {
        case .intensity, .magnitude: return .sequential
        case .real: return .diverging
        case .phase: return .cyclic
        }
    }

    public var defaultColormap: ColormapName {
        switch self {
        case .intensity, .magnitude: return .inferno
        case .real: return .rdbu
        case .phase: return .twilight
        }
    }

    /// Whether the phase slider changes the picture.
    public var dependsOnPhase: Bool { self == .real || self == .phase }

    public var fileTag: String { rawValue }

    /// ⌃1…⌃4 in the Display menu.
    public var shortcutDigit: Character {
        switch self {
        case .intensity: return "1"
        case .magnitude: return "2"
        case .real: return "3"
        case .phase: return "4"
        }
    }
}

public enum FieldPartName: String, Codable, CaseIterable, Identifiable, Sendable {
    case total
    case scattered
    case incident

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .total: return "Total"
        case .scattered: return "Scattered"
        case .incident: return "Incident"
        }
    }

    public var code: UInt32 {
        switch self {
        case .total: return 0
        case .scattered: return 1
        case .incident: return 2
        }
    }
}

public enum ColormapKind: String, Sendable {
    case sequential
    case diverging
    case cyclic

    public var title: String {
        switch self {
        case .sequential: return "Sequential"
        case .diverging: return "Diverging"
        case .cyclic: return "Cyclic"
        }
    }
}

/// Raw values are the core's colormap names.
public enum ColormapName: String, Codable, CaseIterable, Identifiable, Sendable {
    case inferno
    case viridis
    case plasma
    case turbo
    case laserGlow = "laser_glow"
    case asympton
    case rdbu
    case spectralGlow = "spectral_glow"
    case twilight
    case phaseWheel = "phase_wheel"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .viridis: return "Viridis"
        case .inferno: return "Inferno"
        case .plasma: return "Plasma"
        case .turbo: return "Turbo"
        case .laserGlow: return "Laser Glow"
        case .asympton: return "Asympton"
        case .rdbu: return "Red–Blue"
        case .spectralGlow: return "Spectral Glow"
        case .twilight: return "Twilight"
        case .phaseWheel: return "Phase Wheel"
        }
    }

    public var kind: ColormapKind {
        switch self {
        case .rdbu, .spectralGlow: return .diverging
        case .twilight, .phaseWheel: return .cyclic
        default: return .sequential
        }
    }

    public static func all(of kind: ColormapKind) -> [ColormapName] {
        allCases.filter { $0.kind == kind }
    }

    public var fileTag: String { rawValue.replacingOccurrences(of: "_", with: "-") }
}

public enum NormalizationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case incident
    case fixed

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: return "Auto"
        case .incident: return "Incident"
        case .fixed: return "Fixed"
        }
    }
}

public struct DisplaySettings: Codable, Equatable, Sendable {
    public var quantity: Quantity = .intensity
    public var part: FieldPartName = .total
    /// The last colormap picked for each quantity.
    public var colormaps: [Quantity: ColormapName] = [:]
    public var gamma: Double = 1
    public var normalization: NormalizationMode = .auto
    /// Scale for the fixed normalisation, in units of the incident amplitude.
    public var normalizationValue: Double = 1
    /// dB range below the scale maximum for intensity and magnitude; nil is linear.
    public var logDb: Double?
    /// φ in Re(E e^{jφ}) and arg(E e^{jφ}).
    public var phaseDeg: Double = 0
    /// Phase only: brightness follows |E|.
    public var phaseWeighted = false
    /// Phase animation speed in periods per second.
    public var playbackSpeed: Double = 0.5

    public var showOverlays = true
    public var showOutlines = true
    public var showSourceGlyph = true
    public var showParaxialFocus = true
    public var showScaleBar = true
    public var showCaption = true
    public var showLegend = true
    public var showPML = false

    /// Phase animation. Not saved: the app always opens paused.
    public var isPlaying = false

    public init() {}

    public static let playbackSpeedRange: ClosedRange<Double> = 0.25...2

    enum CodingKeys: String, CodingKey {
        case quantity
        case part
        case colormaps
        case gamma
        case normalization
        case normalizationValue = "normalization_value"
        case logDb = "log_db"
        case phaseDeg = "phase_deg"
        case phaseWeighted = "phase_weighted"
        case playbackSpeed = "playback_speed"
        case showOverlays = "show_overlays"
        case showOutlines = "show_outlines"
        case showSourceGlyph = "show_source_glyph"
        case showParaxialFocus = "show_paraxial_focus"
        case showScaleBar = "show_scale_bar"
        case showCaption = "show_caption"
        case showLegend = "show_legend"
        case showPML = "show_pml"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DisplaySettings.defaults
        quantity = try c.decodeIfPresent(Quantity.self, forKey: .quantity) ?? d.quantity
        part = try c.decodeIfPresent(FieldPartName.self, forKey: .part) ?? d.part
        // Stored as name pairs, so an unknown colormap from a newer build is skipped
        // rather than failing the whole document.
        let raw = try c.decodeIfPresent([String: String].self, forKey: .colormaps) ?? [:]
        var maps: [Quantity: ColormapName] = [:]
        for (q, m) in raw {
            if let q = Quantity(rawValue: q), let m = ColormapName(rawValue: m) { maps[q] = m }
        }
        colormaps = maps
        gamma = try c.decodeIfPresent(Double.self, forKey: .gamma) ?? d.gamma
        normalization = try c.decodeIfPresent(NormalizationMode.self, forKey: .normalization) ?? d.normalization
        normalizationValue = try c.decodeIfPresent(Double.self, forKey: .normalizationValue) ?? d.normalizationValue
        logDb = try c.decodeIfPresent(Double.self, forKey: .logDb)
        phaseDeg = try c.decodeIfPresent(Double.self, forKey: .phaseDeg) ?? d.phaseDeg
        phaseWeighted = try c.decodeIfPresent(Bool.self, forKey: .phaseWeighted) ?? d.phaseWeighted
        playbackSpeed = try c.decodeIfPresent(Double.self, forKey: .playbackSpeed) ?? d.playbackSpeed
        showOverlays = try c.decodeIfPresent(Bool.self, forKey: .showOverlays) ?? d.showOverlays
        showOutlines = try c.decodeIfPresent(Bool.self, forKey: .showOutlines) ?? d.showOutlines
        showSourceGlyph = try c.decodeIfPresent(Bool.self, forKey: .showSourceGlyph) ?? d.showSourceGlyph
        showParaxialFocus = try c.decodeIfPresent(Bool.self, forKey: .showParaxialFocus) ?? d.showParaxialFocus
        showScaleBar = try c.decodeIfPresent(Bool.self, forKey: .showScaleBar) ?? d.showScaleBar
        showCaption = try c.decodeIfPresent(Bool.self, forKey: .showCaption) ?? d.showCaption
        showLegend = try c.decodeIfPresent(Bool.self, forKey: .showLegend) ?? d.showLegend
        showPML = try c.decodeIfPresent(Bool.self, forKey: .showPML) ?? d.showPML
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(quantity, forKey: .quantity)
        try c.encode(part, forKey: .part)
        try c.encode(Dictionary(uniqueKeysWithValues: colormaps.map { ($0.key.rawValue, $0.value.rawValue) }), forKey: .colormaps)
        try c.encode(gamma, forKey: .gamma)
        try c.encode(normalization, forKey: .normalization)
        try c.encode(normalizationValue, forKey: .normalizationValue)
        try c.encode(logDb, forKey: .logDb)
        try c.encode(phaseDeg, forKey: .phaseDeg)
        try c.encode(phaseWeighted, forKey: .phaseWeighted)
        try c.encode(playbackSpeed, forKey: .playbackSpeed)
        try c.encode(showOverlays, forKey: .showOverlays)
        try c.encode(showOutlines, forKey: .showOutlines)
        try c.encode(showSourceGlyph, forKey: .showSourceGlyph)
        try c.encode(showParaxialFocus, forKey: .showParaxialFocus)
        try c.encode(showScaleBar, forKey: .showScaleBar)
        try c.encode(showCaption, forKey: .showCaption)
        try c.encode(showLegend, forKey: .showLegend)
        try c.encode(showPML, forKey: .showPML)
    }

    private static let defaults = DisplaySettings()

    /// Equal when everything saved is equal; `isPlaying` is transient.
    public static func == (a: DisplaySettings, b: DisplaySettings) -> Bool {
        a.savedFieldsEqual(b)
    }

    private func savedFieldsEqual(_ o: DisplaySettings) -> Bool {
        quantity == o.quantity && part == o.part && colormaps == o.colormaps && gamma == o.gamma
            && normalization == o.normalization && normalizationValue == o.normalizationValue
            && logDb == o.logDb && phaseDeg == o.phaseDeg && phaseWeighted == o.phaseWeighted
            && playbackSpeed == o.playbackSpeed && showOverlays == o.showOverlays
            && showOutlines == o.showOutlines && showSourceGlyph == o.showSourceGlyph
            && showParaxialFocus == o.showParaxialFocus && showScaleBar == o.showScaleBar
            && showCaption == o.showCaption && showLegend == o.showLegend && showPML == o.showPML
    }

    /// The colormap for the current quantity.
    public var colormap: ColormapName {
        get {
            let picked = colormaps[quantity] ?? quantity.defaultColormap
            return picked.kind == quantity.colormapKind ? picked : quantity.defaultColormap
        }
        set { colormaps[quantity] = newValue }
    }

    /// Whether the log scale applies to the current quantity.
    public var usesLogScale: Bool {
        logDb != nil && (quantity == .intensity || quantity == .magnitude)
    }

    /// View JSON for the core's renderer (spec §3.6). `viewRect` nil shows the whole grid.
    /// `incidentAmplitude` turns the fixed normalisation, given in units of the incident
    /// amplitude, into the field scale the core expects.
    public func viewJSON(viewRect: RectUm?, incidentAmplitude: Double = 1, phaseDeg: Double? = nil) -> String {
        let view = ViewJSON(
            quantity: quantity.rawValue,
            part: part.rawValue,
            phaseDeg: (phaseDeg ?? self.phaseDeg),
            colormap: colormap.rawValue,
            gamma: gamma,
            normalization: .init(mode: normalization.rawValue, value: max(1e-12, normalizationValue * incidentAmplitude)),
            logDb: usesLogScale ? logDb : nil,
            phaseWeighted: quantity == .phase && phaseWeighted,
            viewUm: viewRect,
            outsideRgba: [0, 0, 0, 0],
            pecRgba: [128, 128, 128, 255]
        )
        return (try? SimScene.jsonEncoder.encode(view)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

/// The core's view parameters.
private struct ViewJSON: Encodable {
    struct Normalization: Encodable {
        var mode: String
        var value: Double
    }

    var quantity: String
    var part: String
    var phaseDeg: Double
    var colormap: String
    var gamma: Double
    var normalization: Normalization
    var logDb: Double?
    var phaseWeighted: Bool
    var viewUm: RectUm?
    var outsideRgba: [UInt8]
    var pecRgba: [UInt8]

    enum CodingKeys: String, CodingKey {
        case quantity
        case part
        case phaseDeg = "phase_deg"
        case colormap
        case gamma
        case normalization
        case logDb = "log_db"
        case phaseWeighted = "phase_weighted"
        case viewUm = "view_um"
        case outsideRgba = "outside_rgba"
        case pecRgba = "pec_rgba"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(quantity, forKey: .quantity)
        try c.encode(part, forKey: .part)
        try c.encode(phaseDeg, forKey: .phaseDeg)
        try c.encode(colormap, forKey: .colormap)
        try c.encode(gamma, forKey: .gamma)
        try c.encode(normalization, forKey: .normalization)
        try c.encode(logDb, forKey: .logDb)
        try c.encode(phaseWeighted, forKey: .phaseWeighted)
        try c.encode(viewUm, forKey: .viewUm)
        try c.encode(outsideRgba, forKey: .outsideRgba)
        try c.encode(pecRgba, forKey: .pecRgba)
    }
}
