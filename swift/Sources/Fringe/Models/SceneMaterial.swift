import Foundation

// Element materials of the scene JSON: a constant index n + ik, a Lorentz–Drude model
// evaluated at the scene wavelength, or a perfect electric conductor. Foundation only.

public enum MaterialKind: String, Codable, CaseIterable, Sendable {
    case dielectric
    case dispersive
    case pec

    /// "Index", "Lorentz–Drude", "PEC".
    public var title: String {
        switch self {
        case .dielectric: return "Index"
        case .dispersive: return "Lorentz–Drude"
        case .pec: return "PEC"
        }
    }
}

/// One term of a Lorentz–Drude model, with frequencies as photon energies in eV
/// (e^{+jωt}; absorption is ε″ > 0 in ε = ε′ − jε″):
/// Drude −ωp² / (ω² − jγω), Lorentz Δε·ω0² / (ω0² − ω² + jγω).
public enum Pole: Codable, Equatable, Sendable {
    case drude(plasmaEv: Double, gammaEv: Double)
    case lorentz(strength: Double, resonanceEv: Double, gammaEv: Double)

    public var isDrude: Bool {
        if case .drude = self { return true }
        return false
    }

    // Accessors for inspector bindings. Setters ignore fields the case does not have, and
    // getters return 0 for them.

    /// ħωp of a Drude pole.
    public var plasmaEv: Double {
        get { if case .drude(let p, _) = self { return p } else { return 0 } }
        set { if case .drude(_, let g) = self { self = .drude(plasmaEv: newValue, gammaEv: g) } }
    }

    /// ħγ of either kind.
    public var gammaEv: Double {
        get {
            switch self {
            case .drude(_, let g), .lorentz(_, _, let g): return g
            }
        }
        set {
            switch self {
            case .drude(let p, _): self = .drude(plasmaEv: p, gammaEv: newValue)
            case .lorentz(let s, let r, _): self = .lorentz(strength: s, resonanceEv: r, gammaEv: newValue)
            }
        }
    }

    /// Δε of a Lorentz pole.
    public var strength: Double {
        get { if case .lorentz(let s, _, _) = self { return s } else { return 0 } }
        set { if case .lorentz(_, let r, let g) = self { self = .lorentz(strength: newValue, resonanceEv: r, gammaEv: g) } }
    }

    /// ħω0 of a Lorentz pole.
    public var resonanceEv: Double {
        get { if case .lorentz(_, let r, _) = self { return r } else { return 0 } }
        set { if case .lorentz(let s, _, let g) = self { self = .lorentz(strength: s, resonanceEv: newValue, gammaEv: g) } }
    }

    enum Kind: String, Codable {
        case drude
        case lorentz
    }

    enum CodingKeys: String, CodingKey {
        case type
        case plasmaEv = "plasma_ev"
        case gammaEv = "gamma_ev"
        case strength
        case resonanceEv = "resonance_ev"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .drude:
            self = .drude(plasmaEv: try c.decode(Double.self, forKey: .plasmaEv),
                          gammaEv: try c.decode(Double.self, forKey: .gammaEv))
        case .lorentz:
            self = .lorentz(strength: try c.decode(Double.self, forKey: .strength),
                            resonanceEv: try c.decode(Double.self, forKey: .resonanceEv),
                            gammaEv: try c.decode(Double.self, forKey: .gammaEv))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .drude(let p, let g):
            try c.encode(Kind.drude, forKey: .type)
            try c.encode(p, forKey: .plasmaEv)
            try c.encode(g, forKey: .gammaEv)
        case .lorentz(let s, let r, let g):
            try c.encode(Kind.lorentz, forKey: .type)
            try c.encode(s, forKey: .strength)
            try c.encode(r, forKey: .resonanceEv)
            try c.encode(g, forKey: .gammaEv)
        }
    }
}

/// A dielectric `n + ik` (k ≥ 0 absorbs), a Lorentz–Drude model or a perfect electric
/// conductor. One struct for all kinds: switching kind keeps the values of the others, so
/// switching back restores them.
public struct Material: Codable, Equatable, Sendable {
    public var kind: MaterialKind = .dielectric
    public var n: Double = 1.5
    public var k: Double = 0.0
    /// The library entry the Lorentz–Drude numbers came from, if any. Only a label: the
    /// numbers are always stored in full.
    public var preset: String?
    public var epsInf: Double = 1.0
    public var poles: [Pole] = []

    public init(kind: MaterialKind = .dielectric, n: Double = 1.5, k: Double = 0.0) {
        self.kind = kind
        self.n = n
        self.k = k
    }

    public init(preset: String?, epsInf: Double, poles: [Pole]) {
        kind = .dispersive
        self.preset = preset
        self.epsInf = epsInf
        self.poles = poles
    }

    public static let pec = Material(kind: .pec)

    public static func glass(_ n: Double, k: Double = 0) -> Material {
        Material(kind: .dielectric, n: n, k: k)
    }

    public var isPEC: Bool { kind == .pec }

    /// Most Lorentz–Drude models the core accepts.
    public static let maxPoles = 8

    /// Pole `i` for inspector bindings: reading past the end gives a zero Drude pole and
    /// writing there does nothing, so a binding outliving its pole never traps.
    public subscript(pole i: Int) -> Pole {
        get { poles.indices.contains(i) ? poles[i] : .drude(plasmaEv: 0, gammaEv: 0) }
        set { if poles.indices.contains(i) { poles[i] = newValue } }
    }

    /// The Lorentz–Drude numbers equal `other`'s, whatever the preset label says.
    public func sameModel(as other: Material) -> Bool {
        epsInf == other.epsInf && poles == other.poles
    }

    /// A lossless Lorentz–Drude model with about index `n` in the visible: ε∞ = 1 and one
    /// Sellmeier-like term Δε = n² − 1 resonant at 10 eV in the ultraviolet.
    public static func seededDispersive(n: Double) -> (epsInf: Double, poles: [Pole]) {
        (1, [.lorentz(strength: max(0, n * n - 1), resonanceEv: 10, gammaEv: 0)])
    }

    enum CodingKeys: String, CodingKey {
        case type
        case n
        case k
        case preset
        case epsInf = "eps_inf"
        case poles
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(MaterialKind.self, forKey: .type)
        switch kind {
        case .dielectric:
            n = try c.decode(Double.self, forKey: .n)
            k = try c.decodeIfPresent(Double.self, forKey: .k) ?? 0.0
        case .dispersive:
            preset = try c.decodeIfPresent(String.self, forKey: .preset)
            epsInf = try c.decode(Double.self, forKey: .epsInf)
            poles = try c.decodeIfPresent([Pole].self, forKey: .poles) ?? []
        case .pec:
            break
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .type)
        switch kind {
        case .dielectric:
            try c.encode(n, forKey: .n)
            try c.encode(k, forKey: .k)
        case .dispersive:
            // Written as null when there is no preset, as the core writes it.
            try c.encode(preset, forKey: .preset)
            try c.encode(epsInf, forKey: .epsInf)
            try c.encode(poles, forKey: .poles)
        case .pec:
            break
        }
    }

    /// Equal when the JSON is equal: values of the other kinds do not count.
    public static func == (a: Material, b: Material) -> Bool {
        guard a.kind == b.kind else { return false }
        switch a.kind {
        case .pec: return true
        case .dielectric: return a.n == b.n && a.k == b.k
        case .dispersive: return a.preset == b.preset && a.epsInf == b.epsInf && a.poles == b.poles
        }
    }

    /// "$n$ 1.50", "$n$ 1.50 + 0.050$\mathrm{i}$", "Gold", "Lorentz–Drude" or "PEC", for
    /// `MathText`: the index as it is entered, n + ik.
    public var badge: String {
        switch kind {
        case .pec:
            return "PEC"
        case .dielectric:
            let n = "$n$ " + SceneFormat.fixed(self.n, 2)
            return k > 0 ? n + " + \(SceneFormat.fixed(k, 3))" + #"$\mathrm{i}$"# : n
        case .dispersive:
            guard let preset else { return MaterialKind.dispersive.title }
            return MathTypesetter.escaped(MaterialLibrary.displayName(of: preset))
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
