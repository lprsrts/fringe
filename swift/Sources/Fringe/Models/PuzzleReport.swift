import Foundation

// How a puzzle and its last Check read in the app: the score's name and unit, the truth
// table (or the one-case table of the other goals) with each row's verdict, and what the
// charts draw. Foundation only (the shot harness prints it).

/// What the chart beside a puzzle's table shows.
public enum PuzzleResultChart: String, CaseIterable, Identifiable, Sendable {
    /// One bar per case (or per goal detector).
    case readings
    /// The truth table's 0-cases and 1-cases on one axis, with the gap between them.
    case contrast

    public var id: String { rawValue }
    var title: String {
        switch self {
        case .readings: return "Readings"
        case .contrast: return "Contrast"
        }
    }
}

/// The score of a puzzle: what it is called, its unit and how its values print.
public struct PuzzleScoreScale: Equatable, Sendable {
    /// "contrast", "power", "intensity", "suppression", "balanced power".
    public var label: String
    /// "dB", "%" or "×".
    public var unit: String

    /// "17.5 dB", "95.5%", "2.3×".
    public func format(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        switch unit {
        case "dB": return Format.decibels(value)
        case "%": return Format.number(value, digits: 0...1) + "%"
        case "×": return Format.number(value, digits: 0...2) + "×"
        default: return Format.significant(value) + (unit.isEmpty ? "" : " \(unit)")
        }
    }

    /// A threshold as the goal states it: "6 dB", "85%", "2.5×".
    public func formatThreshold(_ value: Double) -> String {
        let number = Format.number(value, digits: 0...1)
        switch unit {
        case "dB": return number + " dB"
        case "%", "×": return number + unit
        default: return number
        }
    }

    /// The threshold alone, as the axis and the stars line print it: "6", "85", "2.5".
    public func formatBare(_ value: Double) -> String {
        Format.number(value, digits: 0...1)
    }
}

extension Puzzle {
    /// The goal's detectors in goal order: the truth table's outputs, the maximised one,
    /// or the listed ones.
    public var goalDetectorIDs: [String] {
        switch goal.type {
        case "truth_table": return goal.outputs.map(\.detector)
        case "maximize": return goal.detector.map { [$0] } ?? []
        default: return goal.detectors
        }
    }

    public func detectorName(_ id: String) -> String {
        scene[detector: id].map(\.displayName) ?? id
    }

    /// What the score is called and its unit, as the core reports it.
    public var scoreScale: PuzzleScoreScale {
        switch goal.type {
        case "truth_table": return PuzzleScoreScale(label: "contrast", unit: "dB")
        case "minimize": return PuzzleScoreScale(label: "suppression", unit: "dB")
        case "target": return PuzzleScoreScale(label: "balanced power", unit: "%")
        case "maximize":
            if let id = goal.detector, scene[detector: id]?.kind == .box {
                return PuzzleScoreScale(label: "intensity", unit: "×")
            }
            return PuzzleScoreScale(label: "power", unit: "%")
        default: return PuzzleScoreScale(label: "score", unit: "")
        }
    }

    /// The pass threshold (the goal's, else the first star's).
    public var passScore: Double? { goal.pass ?? stars.first }

    /// "Pass: contrast of at least 6 dB".
    public var passLine: String? {
        guard let pass = passScore else { return nil }
        let scale = scoreScale
        var line = "Pass: \(scale.label) of at least \(scale.formatThreshold(pass))"
        if goal.type == "target", let tolerance = goal.tolerance {
            line += ", with the split within \(Format.number(tolerance * 100, digits: 0...1)) points"
        }
        return line
    }

    /// "Stars at 6, 10 and 15 dB".
    public var starsLine: String? {
        guard stars.count == 3 else { return nil }
        let scale = scoreScale
        let values = stars.map(scale.formatBare)
        let unit = scale.unit == "dB" ? " dB" : scale.unit
        return "Stars at \(values[0]), \(values[1]) and \(values[2])\(unit)"
    }

    /// The case label "A=1 B=0" for the status bar, "" without inputs.
    public func caseLabel(_ bits: [Bool]) -> String {
        zip(inputLetters, bits).map { "\($0)=\($1 ? 1 : 0)" }.joined(separator: " ")
    }

    /// Every input case in the core's order (input 0 the most significant bit).
    public var allCases: [[Bool]] {
        let n = inputs.count
        guard n > 0 else { return [[]] }
        return (0..<(1 << n)).map { k in (0..<n).map { i in (k >> (n - 1 - i)) & 1 == 1 } }
    }

    /// Whether a detector's value prints as a share of the reference ("95.5%") rather than
    /// as a factor ("2.3×") or a plain ratio (truth tables, "0.495").
    var valueStyle: PuzzleReport.ValueStyle {
        switch goal.type {
        case "truth_table": return .ratio
        case "maximize" where scoreScale.unit == "×": return .factor
        default: return .percent
        }
    }
}

/// The table under the canvas and the charts beside it, from the puzzle and its last
/// Check (nil before one).
public struct PuzzleReport: Equatable, Sendable {
    public enum ValueStyle: Equatable, Sendable {
        /// Truth tables: the output over the reference, "0.495".
        case ratio
        /// A share of the reference, "95.5%".
        case percent
        /// A factor over the reference, "2.3×".
        case factor

        public func format(_ value: Double?) -> String {
            guard let value, value.isFinite else { return "—" }
            switch self {
            case .ratio:
                // Three significant digits without trailing zeros: 0.507, 0.02, 0.00876, 1.91.
                if abs(value) < 5e-7 { return "0" }
                let decimals = min(6, max(0, 2 - Int(Foundation.floor(log10(abs(value))))))
                return Format.number(value, digits: 0...decimals)
            case .percent:
                // Small shares keep two significant digits ("0.054%"), so a 31 dB shield
                // reads apart from a 29 dB one.
                let p = value * 100
                if abs(p) >= 1e-4, abs(p) < 1 {
                    let decimals = min(4, 1 - Int(Foundation.floor(log10(abs(p)))))
                    return Format.number(p, digits: 0...decimals) + "%"
                }
                return Format.number(p, digits: 0...1) + "%"
            case .factor: return Format.number(value, digits: 0...2) + "×"
            }
        }
    }

    public struct Output: Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
    }

    /// One output of one case.
    public struct Cell: Equatable, Sendable {
        /// The wanted bit (truth tables).
        public var target: Bool?
        public var value: Double?
        /// Whether this case keeps the output's contrast at the pass level.
        public var passes: Bool?
        /// The weakest 1 or the strongest 0 of its output: the values the contrast is made of.
        public var decisive = false
    }

    /// One case of a truth table.
    public struct Row: Equatable, Sendable, Identifiable {
        public var id: Int
        public var bits: [Bool]
        public var cells: [Cell]
        public var passes: Bool? {
            let verdicts = cells.compactMap(\.passes)
            return verdicts.count == cells.count && !cells.isEmpty ? verdicts.allSatisfy { $0 } : nil
        }
    }

    /// One goal detector of a puzzle with one case.
    public struct DetectorRow: Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var value: Double?
        /// "≥ 80%", "≤ 10% in all", "50% ± 5 of the two".
        public var goal: String
        public var passes: Bool?
        /// The aim for this detector as a share of the reference (target goals).
        public var aim: Double?
    }

    /// What a truth table's output scores: its weakest 1 over its strongest 0.
    public struct Contrast: Equatable, Sendable {
        public var output: Output
        public var weakestOne: Double
        public var strongestZero: Double
        /// 10 log10(weakest 1 / strongest 0), with both floored as the core does.
        public var decibels: Double
        /// The 1 and 0 values by case index.
        public var ones: [(case: Int, value: Double)]
        public var zeros: [(case: Int, value: Double)]

        public static func == (a: Contrast, b: Contrast) -> Bool {
            a.output == b.output && a.weakestOne == b.weakestOne && a.strongestZero == b.strongestZero
                && a.ones.map(\.value) == b.ones.map(\.value) && a.zeros.map(\.value) == b.zeros.map(\.value)
        }
    }

    public var isTruthTable: Bool
    public var letters: [String]
    public var outputs: [Output]
    public var rows: [Row]
    public var detectorRows: [DetectorRow]
    public var contrasts: [Contrast]
    public var valueStyle: ValueStyle
    public var scale: PuzzleScoreScale
    public var pass: Double?
    /// Values come from a Check (else the table shows targets and "—").
    public var isChecked: Bool

    /// The value the core floors outputs to (relative to the reference).
    static let floor = 1e-6

    public init(puzzle: Puzzle, evaluation: PuzzleEvaluation?) {
        let evaluation = evaluation?.valid == true ? evaluation : nil
        isTruthTable = puzzle.goal.type == "truth_table"
        letters = puzzle.inputLetters
        scale = puzzle.scoreScale
        pass = evaluation?.pass ?? puzzle.passScore
        valueStyle = puzzle.valueStyle
        isChecked = evaluation != nil
        outputs = puzzle.goalDetectorIDs.map { Output(id: $0, name: puzzle.detectorName($0)) }
        rows = []
        detectorRows = []
        contrasts = []

        func value(_ detector: String, bits: [Bool]) -> Double? {
            evaluation?.case(bits: bits)?.outputs.first { $0.detector == detector }?.value
        }

        if isTruthTable {
            let cases = puzzle.allCases
            let bitsByOutput = Dictionary(puzzle.goal.outputs.map { ($0.detector, $0.bits) }, uniquingKeysWith: { a, _ in a })
            rows = cases.enumerated().map { k, bits in
                Row(id: k, bits: bits, cells: outputs.map { output in
                    let bit = bitsByOutput[output.id].flatMap { $0.indices.contains(k) ? $0[k] : nil }
                    return Cell(target: bit.map { $0 != 0 }, value: value(output.id, bits: bits))
                })
            }
            guard evaluation != nil else { return }
            // Each case against the output's other group: a 1 must sit the pass contrast
            // above the strongest 0, a 0 that far below the weakest 1. All cases passing is
            // the core's pass (the score is the smallest contrast over the outputs).
            let need = pow(10, (pass ?? 0) / 10)
            for (j, output) in outputs.enumerated() {
                var ones: [(Int, Double)] = [], zeros: [(Int, Double)] = []
                for (k, row) in rows.enumerated() {
                    guard let target = row.cells[j].target, let v = row.cells[j].value, v.isFinite else { continue }
                    if target { ones.append((k, max(v, Self.floor))) } else { zeros.append((k, max(v, Self.floor))) }
                }
                guard let weakest = ones.min(by: { $0.1 < $1.1 }), let strongest = zeros.max(by: { $0.1 < $1.1 }) else { continue }
                contrasts.append(Contrast(output: output, weakestOne: weakest.1, strongestZero: strongest.1,
                                          decibels: 10 * log10(weakest.1 / strongest.1),
                                          ones: ones.map { (case: $0.0, value: $0.1) }, zeros: zeros.map { (case: $0.0, value: $0.1) }))
                // A 0 at the floor (no light at all, as with every input off) is as dark as a
                // case can be: it passes and never limits the contrast, which then only
                // the weakest 1 can raise.
                let atFloor = { (v: Double) in v <= Self.floor * (1 + 1e-9) }
                rows[weakest.0].cells[j].decisive = true
                if !atFloor(strongest.1) { rows[strongest.0].cells[j].decisive = true }
                for (k, v) in ones { rows[k].cells[j].passes = v / strongest.1 >= need * (1 - 1e-12) }
                for (k, v) in zeros { rows[k].cells[j].passes = atFloor(v) || weakest.1 / v >= need * (1 - 1e-12) }
            }
        } else {
            let passed = evaluation.map(\.passed)
            let unit = puzzle.scoreScale
            let ratio = puzzle.goal.ratio ?? 0.5
            let caseOutputs = evaluation?.cases.first?.outputs ?? []
            let total = caseOutputs.compactMap(\.value).reduce(0, +)
            detectorRows = outputs.enumerated().map { i, output in
                let v = caseOutputs.first { $0.detector == output.id }?.value
                var goal = ""
                var aim: Double?
                switch puzzle.goal.type {
                case "maximize":
                    goal = pass.map { "≥ " + unit.formatThreshold($0) } ?? ""
                case "minimize":
                    let limit = pass.map { pow(10, -$0 / 10) }
                    goal = limit.map { (outputs.count > 1 ? "Sum ≤ " : "≤ ") + Format.number($0 * 100, digits: 0...1) + "%" } ?? ""
                case "target":
                    let share = i == 0 ? ratio : 1 - ratio
                    let tolerance = puzzle.goal.tolerance.map { " ± " + Format.number($0 * 100, digits: 0...1) } ?? ""
                    goal = "Share " + Format.number(share * 100, digits: 0...1) + "%" + tolerance
                    if total > 0 { aim = share * total }
                default:
                    break
                }
                return DetectorRow(id: output.id, name: output.name, value: v, goal: goal, passes: passed, aim: aim)
            }
        }
    }

    /// The case the table marks as shown.
    public func rowIndex(bits: [Bool]) -> Int? {
        rows.firstIndex { $0.bits == bits }
    }

    /// "A 1, B 0: Output should be 1, measured 0.81, passes", for VoiceOver.
    public func accessibilityLabel(_ row: Row) -> String {
        var parts = [zip(letters, row.bits).map { "\($0) \($1 ? 1 : 0)" }.joined(separator: ", ")]
        for (j, cell) in row.cells.enumerated() {
            var s = "\(outputs[j].name) should be \(cell.target == true ? 1 : 0)"
            if cell.value != nil { s += ", measured \(valueStyle.format(cell.value))" }
            if let passes = cell.passes { s += passes ? ", passes" : ", fails" }
            parts.append(s)
        }
        return parts.joined(separator: ": ")
    }
}

extension PuzzleEvaluation {
    /// "Contrast 17.5 dB: weakest 1 is 0.495, strongest 0 is 0.00876."
    public func summary(scale: PuzzleScoreScale) -> String? {
        guard valid else { return nil }
        let label = (metric?.label.isEmpty == false ? metric!.label : scale.label).capitalizedFirst
        let value = (metric?.value ?? score).map { scale.format($0) } ?? "—"
        var line = "\(label) \(value)"
        if let raw = metric?.text?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            let text = Self.tidied(raw)
            if let first = text.split(separator: " ").first, first == value.split(separator: " ").first {
                // "95.5% of the source power reaches Up" says the value itself.
                line = text.capitalizedFirst
            } else if text.contains(": ") {
                // "Carry: weakest 1 is …": a sentence of its own, not a second colon.
                line += ". " + text
            } else {
                line += ": " + text
            }
        }
        return line.hasSuffix(".") ? line : line + "."
    }

    /// The core's wording in the app's style: "95.5%" with no space, a real minus sign and
    /// no negative zero ("Up 0.0%", "a 100/0 split").
    static func tidied(_ text: String) -> String {
        var s = text.replacingOccurrences(of: #"(\d) %"#, with: "$1%", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?<![\d.])-0(\.0+)?(?![\d.])"#, with: "0$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?<![\w])-(?=\d)"#, with: "−", options: .regularExpression)
        return s
    }
}

// MARK: - Live values

extension Puzzle {
    /// The source the "source" reference is taken from, as the core picks it.
    var referenceSourceID: String? {
        goal.referenceSource ?? inputs.first ?? scene.sources.first(where: \.enabled)?.id
    }

    /// A reading on the live preview as the core would score it: the goal's quantity over the
    /// goal's reference, so the table and the plates read in the goal's unit before a Check.
    /// nil when the app cannot know the reference: an emitter's power depends on the design.
    public func liveValue(_ reading: DetectorReading, in scene: SimScene) -> Double? {
        let line = reading.kind == .line
        let quantity: Double?
        if goal.type == "minimize", line, (goal.quantity ?? "scattered") == "scattered" {
            quantity = reading.flux?.scattered
        } else {
            quantity = reading.totalValue
        }
        guard let quantity, quantity.isFinite else { return nil }
        let reference: Double?
        if let fixed = goal.referenceValue {
            reference = fixed
        } else if goal.reference == "incident" {
            reference = reading.incidentValue
        } else {
            guard let source = referenceSourceID.flatMap({ scene[source: $0] }) else { return nil }
            if !line {
                reference = source.amplitude * source.amplitude
            } else if source.kind == .gaussianBeam {
                reference = Self.beamPower(waistUm: source.waistUm, amplitude: source.amplitude,
                                           wavelengthUm: scene.wavelengthUm, n: scene.background.n)
            } else {
                reference = nil
            }
        }
        guard let reference, reference.isFinite, abs(reference) > 1e-300 else { return nil }
        return quantity / reference
    }

    /// The power per µm a Gaussian beam carries, as the core's `source_power` takes it: its
    /// spectrum exp(−κ²w0²/4) over the propagating band |κ| ≤ k_b, scaled so the field at the
    /// waist centre is A; then (1/2k0)(1/2π) ∫ |Ê(κ)|² √(k_b² − κ²) dκ. With κ = k_b sin α
    /// both integrals are smooth.
    static func beamPower(waistUm w0: Double, amplitude: Double, wavelengthUm: Double, n: Double) -> Double {
        let k0 = 2 * Double.pi / wavelengthUm
        let kb = k0 * n
        let steps = 2000
        let h = Double.pi / Double(steps)
        var norm = 0.0, power = 0.0
        for i in 0...steps {
            let a = -Double.pi / 2 + Double(i) * h
            let weight: Double = (i == 0 || i == steps) ? 1 : (i % 2 == 1 ? 4 : 2)
            let kappa = kb * sin(a), c = cos(a)
            let g = exp(-0.25 * kappa * kappa * w0 * w0)
            norm += weight * g * kb * c
            power += weight * g * g * kb * kb * c * c
        }
        norm *= h / 3
        power *= h / 3
        let c0 = 2 * Double.pi * amplitude / norm
        return c0 * c0 * power / (2 * k0) / (2 * Double.pi)
    }
}
