import Foundation

// The reveal of a Check result (sound design §1, §4.3). When a result arrives it is turned
// once into a plan: beats with start times for the cases, the score meter, the verdict and
// the extras. Views show `frame(at:)` of the plan at the current time; sound is scheduled
// from the same plan (Audio/RevealSound.swift), so picture and sound cannot drift. Foundation only, so the
// self-test (`--reveal-self-test`) runs it without a window.

/// What decides how a reveal plays, read when the result arrives.
struct RevealOptions: Sendable, Equatable {
    /// System setting: no counting, sweeping or stepping, only fades.
    var reduceMotion = false
    /// VoiceOver is running: the result shows at once and is announced.
    var voiceOver = false
    /// Puzzle sound will play. Without it the visual timeline is 0.7 times as long.
    var soundOn = false
    /// The "Animate puzzle results" setting; off shows every result at once.
    var animate = true
    /// Reveals skipped in a row this session; from three on, checks reveal only changes.
    var skipsInARow = 0
    /// The first reveals of a session say "Space to skip".
    var showSkipHint = false
}

/// The last result a reveal showed for a puzzle in this app session. A later Check of the
/// same puzzle reveals only what changed against it.
struct RevealedResult: Equatable, Sendable {
    var revision: Data?
    var score: Double?
    var passed: Bool
    var stars: Int
    /// By case, then by goal detector; nil where the value is not finite.
    var values: [[Double?]]
    /// By case, then by goal detector: whether that output misses its target in that case.
    var wrong: [[Bool]]
}

/// What a result adds beyond its score, in rising priority: only the highest one's sound
/// plays, and "New best" is not shown beside a higher one.
enum RevealExtra: Int, Sendable, Comparable, CaseIterable {
    case newBest
    case firstSolve
    case allStars
    case chapterComplete

    static func < (a: RevealExtra, b: RevealExtra) -> Bool { a.rawValue < b.rawValue }
}

// MARK: - The score track

/// The goal card's score track as `ScoreBar` draws it: where a score sits, 0…1, with the
/// three stars at fixed spots. The meter moves along the same positions.
struct ScoreTrack: Equatable, Sendable {
    var thresholds: [Double]
    var pass: Double?
    /// Percent scores: the track ends at 100.
    var percent: Bool

    init(thresholds: [Double], pass: Double?, percent: Bool) {
        self.thresholds = thresholds
        self.pass = pass
        self.percent = percent
    }

    init(puzzle: Puzzle) {
        self.init(thresholds: puzzle.stars, pass: puzzle.passScore, percent: puzzle.scoreScale.unit == "%")
    }

    /// From 0 (or a round value under the first star when the stars sit close together) to a
    /// little past the third star.
    var domain: ClosedRange<Double> {
        guard let first = thresholds.first ?? pass, let last = thresholds.last ?? pass else { return 0...1 }
        let spread = max(last - first, abs(last) * 0.1, 1e-9)
        // A round start: 60 rather than 68.5.
        let step = pow(10, Foundation.floor(log10(spread)))
        var lo = max(0, Foundation.floor((first - 1.5 * spread) / step) * step)
        // A start below half the first star says little: start at 0 then (4, 5, 5.6 dB → 0).
        if lo <= 0.5 * first { lo = 0 }
        var hi = last + 0.6 * spread
        if percent, last <= 100 { hi = min(hi, 100) }
        return lo...max(hi, lo + 1e-9)
    }

    /// Where `v` sits on the track, 0…1. With three stars the stars stand at 40, 65 and 90 %
    /// and the values between them map linearly.
    func position(_ v: Double) -> Double {
        guard v.isFinite else { return 0 }
        let d = domain
        let span = d.upperBound - d.lowerBound
        guard thresholds.count == 3, zip(thresholds, thresholds.dropFirst()).allSatisfy({ $0 < $1 }),
              thresholds[0] > d.lowerBound else {
            return min(1, max(0, (v - d.lowerBound) / span))
        }
        let values = [d.lowerBound] + thresholds + [max(d.upperBound, thresholds[2])]
        let spots: [Double] = values[4] > thresholds[2] ? [0, 0.4, 0.65, 0.9, 1] : [0, 0.45, 0.725, 1, 1]
        if v <= values[0] { return 0 }
        for i in 0..<4 where v <= values[i + 1] {
            let w = values[i + 1] - values[i]
            return w > 0 ? spots[i] + (spots[i + 1] - spots[i]) * (v - values[i]) / w : spots[i + 1]
        }
        return 1
    }

    var starX: [Double] { thresholds.map(position) }
    var passX: Double { position(pass ?? thresholds.first ?? 0) }
}

// MARK: - The plan

struct RevealPlan: Sendable, Equatable {
    enum Kind: String, Sendable {
        /// Every case, then the meter, then the verdict (first check, a pass flip, a star gained).
        case full
        /// Only the cases that changed, the meter from the previous score.
        case delta
        /// The same design and score again: the verdict only.
        case recheck
        /// Reduce Motion: fades only, 0.6 s.
        case reduced
        /// VoiceOver: shown at once and announced.
        case voiceOver
        /// Animation off, or Reduce Motion with sound off: shown at once (or one short fade).
        case instant
    }

    enum Goal: String, Sendable {
        case truthTable, maximize, minimize, target
    }

    /// Two inputs lit together in a truth-table case, as the detector sees them (§2.4):
    /// `|√powerA + √powerB·e^{i·phase}|²` is the measured value.
    struct Interference: Equatable, Sendable {
        /// The two input indices, most significant first.
        var inputs: [Int]
        var powerA: Double
        var powerB: Double
        /// Radians, 0…π.
        var phase: Double
    }

    /// One case of the table (the only case of a single-case goal).
    struct CaseBeat: Equatable, Sendable {
        /// Row in the table.
        var index: Int
        var bits: [Bool]
        /// When the case is measured; nil when it does not play (a delta reveal's unchanged
        /// case), so it shows its value from the start.
        var start: Double?
        /// How long the case holds the highlight (the step to the next case).
        var slot: Double
        /// How long its values count; 0 shows them whole.
        var countDuration: Double
        /// When its ✓ or ✗ appears.
        var verdictAt: Double?
        /// Opacity ramp at the start (Reduce Motion and the short fades); 0 for none.
        var fadeIn: Double
        /// Where each goal detector's count starts and ends.
        var from: [Double]
        var to: [Double?]
        /// Delta: the previous values, shown dimmed until the case plays.
        var previous: [Double?]?
        var passes: Bool?
        /// By goal detector: misses its target in this case.
        var wrong: [Bool]
        /// By goal detector: the two-beam reading of this case, when it is one (§2.4).
        var interference: [Interference?]
        /// Single-case goals: the count moves with the meter.
        var followsMeter: Bool
        /// Delta: whether this case changed (moved by 1 dB or more, or its verdict flipped).
        var changed: Bool
    }

    /// The score meter: the goal card's fill sweeping to the score, the stars landing.
    struct MeterBeat: Equatable, Sendable {
        enum Curve: Equatable, Sendable {
            /// fromX → toX, ease-out cubic.
            case easeOut
            /// A near miss: ease-out cubic to `cruise` by `crawlFrom` (a fraction of the
            /// duration), then an ease-out quintic crawl to the score.
            case nearMiss(cruise: Double, crawlFrom: Double)
            /// Single-case goals: the score counts with ease-out cubic and the fill follows it
            /// through the track's mapping.
            case valueFill
        }

        var start: Double
        var duration: Double
        var fromX: Double
        var toX: Double
        /// The counted score (single-case goals).
        var fromScore: Double
        var toScore: Double
        var curve: Curve
        var track: ScoreTrack
        var starX: [Double]
        /// When each earned star lands (full reveals; empty otherwise).
        var starTimes: [Double]
        /// Stars shown before the meter moves (delta: the previous result's).
        var starsBefore: Int
        var stars: Int
        var passed: Bool
        var isDelta: Bool
        var nearMiss: Bool
        /// A near miss's beat against the pass pitch, 1.5…6 Hz, from the shortfall (§1.5).
        var beatHz: Double?
        /// The fill fades in at its end position instead of sweeping (Reduce Motion, fades).
        var fadeIn: Double

        var end: Double { start + duration }

        /// 0…1 through the meter at `t`.
        func u(at t: Double) -> Double {
            guard duration > 0 else { return t >= start ? 1 : 0 }
            return ramp(t, from: start, over: duration)
        }

        /// The fill position at `t`.
        func x(at t: Double) -> Double { x(u: u(at: t)) }

        func x(u: Double) -> Double {
            if u >= 1 { return toX }
            switch curve {
            case .easeOut:
                return fromX + (toX - fromX) * easeOutCubic(u)
            case .nearMiss(let cruise, let crawlFrom):
                if u <= crawlFrom { return fromX + (cruise - fromX) * easeOutCubic(u / crawlFrom) }
                return cruise + (toX - cruise) * easeOutQuint((u - crawlFrom) / (1 - crawlFrom))
            case .valueFill:
                return track.position(fromScore + (toScore - fromScore) * easeOutCubic(u))
            }
        }

        /// How far the count has gone, 0…1: in step with the fill.
        func progress(at t: Double) -> Double {
            let u = u(at: t)
            if u >= 1 { return 1 }
            switch curve {
            case .valueFill, .easeOut:
                return easeOutCubic(u)
            case .nearMiss:
                let span = toX - fromX
                return abs(span) > 1e-12 ? min(1, max(0, (x(u: u) - fromX) / span)) : easeOutCubic(u)
            }
        }

        /// Whether star `i` shows as reached at `t`, 0…1 through its landing.
        func starLanding(_ i: Int, at t: Double) -> Double {
            if fadeIn > 0 || duration == 0 {
                guard i < stars, t >= start else { return 0 }
                return fadeIn > 0 ? ramp(t, from: start, over: fadeIn) : 1
            }
            if isDelta {
                if t >= end { return i < stars ? 1 : 0 }
                if i < stars { return 1 }
                return i < starsBefore && x(at: t) >= starX[i] - 1e-9 ? 1 : 0
            }
            guard i < starTimes.count else { return 0 }
            return ramp(t, from: starTimes[i], over: RevealPlan.starLandDuration)
        }
    }

    struct ExtraBeat: Equatable, Sendable {
        var extra: RevealExtra
        var at: Double
    }

    /// A star glyph's landing: opacity and a 0.9 → 1 scale, no overshoot.
    static let starLandDuration = 0.12
    static let verdictFadeDuration = 0.15

    var kind: Kind
    var goal: Goal
    var puzzleID: String
    var outputCount: Int
    var cases: [CaseBeat]
    var meter: MeterBeat
    var verdictAt: Double
    var verdictFade: Double
    /// At most 0.3 s after the verdict.
    var extras: [ExtraBeat]
    /// The last visual change; `frame(at: visualEnd)` is the final frame.
    var visualEnd: Double
    /// Progress before and after this Check: the goal card shows `before` until the verdict.
    var before: PuzzleProgress
    var after: PuzzleProgress
    /// The result.
    var score: Double
    var passed: Bool
    var stars: Int
    /// A value (×) puzzle's detector values over this are full brightness (§2.3).
    var fullScale: Double
    /// The case the player shows; the canvas comes back to it.
    var shownBits: [Bool]
    /// The canvas steps through the cases (full truth-table reveals).
    var canvasSteps: Bool
    var showSkipHint: Bool
    /// A near miss's shortfall, "0.6 dB short".
    var shortfall: String?
    /// What VoiceOver says, posted once when the reveal begins under VoiceOver.
    var announcement: String
    /// Pass ↔ fail against the last revealed result.
    var passFlip: Bool
    /// 1, or 0.7 when sound is off (§1.8).
    var timeScale: Double
    var options: RevealOptions

    /// The highest extra, whose sound plays.
    var topExtra: RevealExtra? { extras.map(\.extra).max() }
    var caseCount: Int { cases.count }

    // MARK: Frames

    /// What the views show at `t` seconds after the result arrived.
    func frame(at time: Double) -> RevealFrame {
        let t = time.isFinite ? max(0, time) : visualEnd
        var f = RevealFrame(cases: cases.count, outputs: outputCount, stars: meter.starX.count)
        for (k, c) in cases.enumerated() {
            guard let start = c.start else {
                f.values[k] = c.to
                f.caseVerdictShown[k] = true
                continue
            }
            if t < start {
                if let previous = c.previous {
                    f.values[k] = previous
                    f.dimmed[k] = true
                }
                if c.fadeIn > 0 { f.caseOpacity[k] = 0 }
                continue
            }
            let p: Double
            if c.followsMeter {
                p = meter.progress(at: t)
            } else if c.countDuration <= 0 || t >= start + c.countDuration - 1e-9 {
                p = 1
            } else {
                p = easeOutCubic((t - start) / c.countDuration)
            }
            f.values[k] = zip(c.from, c.to).map { from, to in
                to.map { p >= 1 ? $0 : from + ($0 - from) * p }
            }
            f.caseVerdictShown[k] = c.verdictAt.map { t >= $0 } ?? true
            if c.fadeIn > 0 { f.caseOpacity[k] = ramp(t, from: start, over: c.fadeIn) }
            if t < start + c.slot, kind == .full || kind == .delta, goal == .truthTable {
                f.highlightedCase = k
            }
        }
        if canvasSteps, let k = f.highlightedCase {
            f.canvasCase = k
            f.inputsDimmed = true
        }

        // The meter: empty (delta: at the previous score) until it starts.
        if t < meter.start {
            f.meterX = meter.isDelta ? meter.fromX : nil
            for i in f.starLand.indices { f.starLand[i] = meter.isDelta && i < meter.starsBefore ? 1 : 0 }
        } else {
            f.meterX = meter.x(at: t)
            if meter.fadeIn > 0 {
                f.meterOpacity = ramp(t, from: meter.start, over: meter.fadeIn)
                f.starsFadeOnly = true
            }
            for i in f.starLand.indices { f.starLand[i] = meter.starLanding(i, at: t) }
        }

        if t >= verdictAt {
            f.verdictOpacity = ramp(t, from: verdictAt, over: verdictFade)
            f.showsAfterProgress = true
            f.nearMissShortfall = shortfall
            // Reduce Motion and the short fade do not slide anything.
            if kind != .reduced, kind != .instant,
               extras.contains(where: { $0.extra == .newBest }), let old = before.bestScore, let new = after.bestScore {
                let u = ramp(t, from: verdictAt, over: min(RevealPlan.bestSlideDuration, visualEnd - verdictAt))
                f.bestScore = u >= 1 ? new : old + (new - old) * easeOutCubic(u)
            } else {
                f.bestScore = after.bestScore
            }
        } else {
            f.bestScore = before.bestScore
            f.showSkipHint = showSkipHint
        }
        f.extrasShown = Set(extras.filter { t >= $0.at }.map(\.extra))
        return f
    }

    /// The best marker slides to a new best in this long (or until the end, if sooner).
    static let bestSlideDuration = 0.25

    /// Everything shown: the result as it stands once the reveal is over.
    var final: RevealFrame {
        var f = RevealFrame(cases: cases.count, outputs: outputCount, stars: meter.starX.count)
        f.values = cases.map(\.to)
        f.caseVerdictShown = cases.map { _ in true }
        f.meterX = meter.toX
        for i in f.starLand.indices { f.starLand[i] = i < meter.stars ? 1 : 0 }
        f.starsFadeOnly = meter.fadeIn > 0
        f.bestScore = after.bestScore
        f.verdictOpacity = 1
        f.extrasShown = Set(extras.map(\.extra))
        f.showsAfterProgress = true
        f.nearMissShortfall = shortfall
        return f
    }

    /// Every time in the plan multiplied by `s` (sound off: 0.7).
    func scaled(by s: Double) -> RevealPlan {
        guard s != 1 else { return self }
        var p = self
        p.timeScale *= s
        p.cases = cases.map { c in
            var c = c
            c.start = c.start.map { $0 * s }
            c.slot *= s
            c.countDuration *= s
            c.verdictAt = c.verdictAt.map { $0 * s }
            c.fadeIn *= s
            return c
        }
        p.meter.start *= s
        p.meter.duration *= s
        p.meter.starTimes = meter.starTimes.map { $0 * s }
        p.meter.fadeIn *= s
        p.verdictAt *= s
        p.verdictFade *= s
        p.extras = extras.map { ExtraBeat(extra: $0.extra, at: $0.at * s) }
        p.visualEnd *= s
        return p
    }
}

/// What the views show at one moment of a reveal.
struct RevealFrame: Equatable, Sendable {
    /// By case, then goal detector; nil shows "—".
    var values: [[Double?]]
    /// Delta: the previous value, dimmed, before its case plays.
    var dimmed: [Bool]
    var caseVerdictShown: [Bool]
    var caseOpacity: [Double]
    /// The case being measured: table row, Inputs bar, status bar and chart.
    var highlightedCase: Int?
    /// The case the canvas shows; nil is the player's.
    var canvasCase: Int?
    var inputsDimmed = false
    /// The fill position, 0…1; nil is an empty track.
    var meterX: Double?
    var meterOpacity = 1.0
    /// Per star, 0 (outline) … 1 (landed).
    var starLand: [Double]
    /// Stars land by opacity alone, at full size (Reduce Motion and the short fade).
    var starsFadeOnly = false
    /// Where the best marker sits, as a score.
    var bestScore: Double?
    var verdictOpacity = 0.0
    var extrasShown: Set<RevealExtra> = []
    /// Progress shows the state after this Check (from the verdict on).
    var showsAfterProgress = false
    var showSkipHint = false
    /// "0.6 dB short", at the stop.
    var nearMissShortfall: String?

    var verdictShown: Bool { verdictOpacity > 0 }

    init(cases: Int, outputs: Int, stars: Int) {
        values = Array(repeating: Array(repeating: nil, count: outputs), count: cases)
        dimmed = Array(repeating: false, count: cases)
        caseVerdictShown = Array(repeating: false, count: cases)
        caseOpacity = Array(repeating: 1, count: cases)
        starLand = Array(repeating: 0, count: stars)
    }
}

// MARK: - The planner

enum RevealPlanner {
    /// Case step of a full truth-table reveal: 1 s over the cases, 80…300 ms each (§1.3).
    static func step(cases n: Int) -> Double { min(0.300, max(0.080, 1.0 / Double(max(1, n)))) }
    static let hold = 0.080
    static let meterGap = 0.030
    static let meterDuration = 0.450
    static let singleDuration = 0.800
    static let deltaHold = 0.060
    static let deltaMeter = 0.300
    /// The delta reveal's cases share this long, so its verdict stays within 0.6 s.
    static let deltaCaseSpan = 0.220
    /// Values of a truth table are floored to this by the core.
    static let floor = 1e-6

    /// The plan for a Check result, nil when there is nothing to reveal (an unscored design).
    static func plan(evaluation: PuzzleEvaluation, revision: Data?, previous: RevealedResult?, puzzle: Puzzle,
                     shownBits: [Bool], before: PuzzleProgress, after: PuzzleProgress,
                     firstCheckThisSession: Bool, chapterCompleted: Bool,
                     options: RevealOptions) -> RevealPlan? {
        guard evaluation.valid, let rawScore = evaluation.score, rawScore.isFinite else { return nil }
        let report = PuzzleReport(puzzle: puzzle, evaluation: evaluation)
        let result = revealed(report: report, evaluation: evaluation, revision: revision)
        let goal: RevealPlan.Goal
        switch puzzle.goal.type {
        case "truth_table": goal = .truthTable
        case "minimize": goal = .minimize
        case "target": goal = .target
        default: goal = .maximize
        }
        let scale = puzzle.scoreScale
        let track = ScoreTrack(puzzle: puzzle)
        let score = rawScore
        let passed = evaluation.passed
        let stars = passed ? min(3, max(0, evaluation.stars)) : 0
        let pass = puzzle.passScore ?? track.thresholds.first ?? 0

        // The kind (§1.6, §1.8).
        let passFlip = previous.map { $0.passed != passed } ?? false
        let starGained = previous.map { stars > $0.stars } ?? false
        let sameResult = previous.map { prev in
            prev.revision != nil && prev.revision == revision
                && (prev.score.map { abs($0 - score) <= 1e-9 } ?? false)
        } ?? false
        let kind: RevealPlan.Kind
        if options.voiceOver {
            kind = .voiceOver
        } else if !options.animate || (options.reduceMotion && !options.soundOn) {
            kind = .instant
        } else if options.reduceMotion {
            kind = .reduced
        } else if sameResult {
            kind = .recheck
        } else if let previous, previous.values.count == result.values.count, !passFlip,
                  options.skipsInARow >= 3 || !(firstCheckThisSession || starGained) {
            kind = .delta
        } else {
            kind = .full
        }

        // The meter's end and the near miss (§1.5).
        let xs = track.position(score)
        let near = nearMiss(track: track, score: score, passed: passed)
        let nearMiss = near != nil
        let beatHz = near.map { 1.5 + 4.5 * $0 }
        let shortfall = shortfall(puzzle: puzzle, score: score, passed: passed)
        // A balanced split outside its tolerance fails with the power itself above the pass.
        let sideConditionFailed = goal == .target && !passed && score >= pass

        // Extras (§1.5).
        var extraKinds: [RevealExtra] = []
        if let best = before.bestScore, score > best { extraKinds.append(.newBest) }
        if !before.passed && after.passed { extraKinds.append(.firstSolve) }
        if after.stars == 3 && before.stars < 3 { extraKinds.append(.allStars) }
        if chapterCompleted { extraKinds.append(.chapterComplete) }

        let outputs = report.outputs.count
        let fullScale = goal == .maximize && scale.unit == "×" ? max(1e-9, 1.25 * (puzzle.stars.last ?? 1)) : 1
        let cases = caseInputs(report: report, puzzle: puzzle, goal: goal, result: result)

        var plan = RevealPlan(
            kind: kind, goal: goal, puzzleID: puzzle.id, outputCount: outputs, cases: [],
            meter: RevealPlan.MeterBeat(start: 0, duration: 0, fromX: xs, toX: xs, fromScore: score, toScore: score,
                                        curve: .easeOut, track: track, starX: track.starX, starTimes: [],
                                        starsBefore: 0, stars: stars, passed: passed, isDelta: false,
                                        nearMiss: nearMiss, beatHz: beatHz, fadeIn: 0),
            verdictAt: 0, verdictFade: 0, extras: [], visualEnd: 0, before: before, after: after,
            score: score, passed: passed, stars: stars, fullScale: fullScale, shownBits: shownBits,
            canvasSteps: false, showSkipHint: options.showSkipHint, shortfall: shortfall,
            announcement: announcement(puzzle: puzzle, report: report, score: score, passed: passed, stars: stars,
                                       shortfall: pass - score, extras: extraKinds),
            passFlip: passFlip, timeScale: 1, options: options)

        let singleFrom: [Double] = report.outputs.map { _ in
            switch goal {
            case .minimize: return 1
            case .maximize where scale.unit == "×": return 1
            default: return 0
            }
        }
        let singleFromScore: Double = goal == .maximize && scale.unit == "×" ? 1 : (goal == .truthTable ? track.domain.lowerBound : 0)

        func atOnce(fade: Double) {
            plan.cases = cases.map { c in
                var c = c
                c.start = 0
                c.fadeIn = fade
                c.verdictAt = 0
                return c
            }
            plan.meter.start = 0
            plan.meter.fadeIn = fade
            plan.verdictAt = 0
            plan.verdictFade = fade
            plan.extras = extraKinds.map { .init(extra: $0, at: 0) }
            plan.visualEnd = fade
        }

        switch kind {
        case .voiceOver:
            atOnce(fade: 0)
        case .instant:
            // Reduce Motion with sound off still gets one short cross-fade from "—".
            atOnce(fade: options.animate ? 0.15 : 0)
        case .recheck:
            // The values are the ones already shown: only the verdict comes again.
            atOnce(fade: 0)
            plan.verdictFade = 0.1
            plan.visualEnd = 0.1
        case .reduced:
            let n = cases.count
            let step = n > 1 ? min(0.080, 0.240 / Double(n - 1)) : 0
            plan.cases = cases.enumerated().map { k, c in
                var c = c
                c.start = Double(k) * step
                c.fadeIn = 0.12
                c.verdictAt = c.start
                return c
            }
            plan.meter.start = 0.36
            plan.meter.fadeIn = 0.12
            plan.verdictAt = 0.42
            plan.verdictFade = 0.12
            plan.extras = extraKinds.map { .init(extra: $0, at: 0.48) }
            plan.visualEnd = 0.60
        case .full:
            if goal == .truthTable {
                let n = cases.count
                let s = step(cases: n)
                // Four inputs (80 ms a case) roll: the values appear whole.
                let count = s <= 0.080 + 1e-12 && n >= 16 ? 0 : 0.7 * s
                plan.cases = cases.enumerated().map { k, c in
                    var c = c
                    let start = hold + Double(k) * s
                    c.start = start
                    c.slot = s
                    c.countDuration = count
                    c.verdictAt = start + (count > 0 ? count + 0.020 : 0)
                    return c
                }
                let meterStart = hold + Double(n) * s + meterGap
                plan.meter = makeMeter(base: plan.meter, start: meterStart, duration: meterDuration, fromX: 0,
                                       fromScore: track.domain.lowerBound, nearMiss: nearMiss, valueFill: false)
                plan.verdictAt = meterStart + meterDuration
                plan.canvasSteps = n > 1
            } else {
                plan.cases = cases.map { c in
                    var c = c
                    c.start = hold
                    c.slot = singleDuration
                    c.countDuration = singleDuration
                    c.verdictAt = hold + singleDuration
                    c.from = singleFrom
                    c.followsMeter = true
                    return c
                }
                plan.meter = makeMeter(base: plan.meter, start: hold, duration: singleDuration,
                                       fromX: track.position(singleFromScore), fromScore: singleFromScore,
                                       nearMiss: nearMiss, valueFill: !sideConditionFailed)
                plan.verdictAt = hold + singleDuration + 0.040
            }
            plan.verdictFade = RevealPlan.verdictFadeDuration
            plan.extras = extraBeats(extraKinds, verdict: plan.verdictAt)
            plan.visualEnd = plan.verdictAt + RevealPlan.verdictFadeDuration + (extraKinds.isEmpty ? 0 : 0.30)
        case .delta:
            guard let previous else { return nil }
            let fromX = track.position(previous.score ?? score)
            let fromPitchScore = previous.score ?? score
            if goal == .truthTable {
                var changed: [Int] = []
                for (k, c) in cases.enumerated() {
                    let before = previous.values[k], beforeWrong = previous.wrong[k]
                    let flipped = c.wrong != beforeWrong
                    let moved = c.to.indices.contains { j in
                        let a = max(c.to[j] ?? 0, floor), b = max(j < before.count ? before[j] ?? 0 : 0, floor)
                        return abs(10 * log10(a / b)) >= 1
                    }
                    if flipped || moved { changed.append(k) }
                }
                let sd = changed.isEmpty ? 0 : min(0.150, deltaCaseSpan / Double(changed.count))
                plan.cases = cases.enumerated().map { k, c in
                    var c = c
                    c.previous = previous.values[k]
                    if let i = changed.firstIndex(of: k) {
                        let start = deltaHold + Double(i) * sd
                        c.start = start
                        c.slot = sd
                        c.countDuration = 0.7 * sd
                        c.verdictAt = start + 0.7 * sd + 0.020
                        c.from = previous.values[k].map { $0 ?? 0 }
                        c.changed = true
                    } else {
                        c.start = nil
                    }
                    return c
                }
                let meterStart = (changed.isEmpty ? deltaHold : deltaHold + Double(changed.count) * sd) + 0.020
                plan.meter = makeMeter(base: plan.meter, start: meterStart, duration: deltaMeter, fromX: fromX,
                                       fromScore: fromPitchScore, nearMiss: false, valueFill: false, isDelta: true)
                plan.meter.starsBefore = previous.stars
                plan.verdictAt = meterStart + deltaMeter
            } else {
                plan.cases = cases.enumerated().map { k, c in
                    var c = c
                    c.previous = previous.values.indices.contains(k) ? previous.values[k] : nil
                    c.start = deltaHold
                    c.slot = deltaMeter
                    c.countDuration = deltaMeter
                    c.verdictAt = deltaHold + deltaMeter
                    c.from = (c.previous ?? []).map { $0 ?? 0 } + Array(repeating: 0, count: max(0, c.to.count - (c.previous?.count ?? 0)))
                    c.followsMeter = true
                    c.changed = true
                    return c
                }
                plan.meter = makeMeter(base: plan.meter, start: deltaHold, duration: deltaMeter, fromX: fromX,
                                       fromScore: fromPitchScore, nearMiss: false, valueFill: false, isDelta: true)
                plan.meter.starsBefore = previous.stars
                plan.verdictAt = deltaHold + deltaMeter + 0.020
            }
            plan.verdictFade = RevealPlan.verdictFadeDuration
            plan.extras = extraBeats(extraKinds, verdict: plan.verdictAt)
            plan.visualEnd = plan.verdictAt + RevealPlan.verdictFadeDuration + (extraKinds.isEmpty ? 0 : 0.30)
        }
        if (kind == .full || kind == .delta) && !options.soundOn {
            plan = plan.scaled(by: 0.7)
        }
        return plan
    }

    /// A near miss (§1.5): under the pass, but within 0.15 of the track or 10 % of the pass
    /// value. Returns how far short it is, 0 (a hair) … 1 (the edge of the zone); nil when
    /// it is not a near miss.
    static func nearMiss(track: ScoreTrack, score: Double, passed: Bool) -> Double? {
        let pass = track.pass ?? track.thresholds.first ?? 0
        let xs = track.position(score), xp = track.passX
        let byX = (xp - xs) / 0.15
        let byValue = pass != 0 ? (pass - score) / (0.1 * abs(pass)) : 2
        guard !passed, xs < xp, min(byX, byValue) <= 1 else { return nil }
        return min(1, max(0, min(byX, byValue)))
    }

    /// A near miss's shortfall as the verdict says it, "0.6 dB short".
    static func shortfall(puzzle: Puzzle, score: Double, passed: Bool) -> String? {
        guard score.isFinite, let pass = puzzle.passScore,
              nearMiss(track: ScoreTrack(puzzle: puzzle), score: score, passed: passed) != nil else { return nil }
        return puzzle.scoreScale.format(pass - score) + " short"
    }

    /// The meter of a full or delta reveal, with its star times (§1.5, §2.5).
    private static func makeMeter(base: RevealPlan.MeterBeat, start: Double, duration d: Double, fromX: Double,
                                  fromScore: Double, nearMiss: Bool, valueFill: Bool, isDelta: Bool = false) -> RevealPlan.MeterBeat {
        var m = base
        m.isDelta = isDelta
        m.start = start
        m.duration = d
        m.fromX = fromX
        m.fromScore = fromScore
        let xs = m.toX, xp = m.track.passX
        if nearMiss {
            // Same length as any meter; only the last 150 ms crawl to just short of the pass tick.
            let crawlFrom = max(0.5, 1 - 0.15 / d)
            let cruise = max(fromX, min(xp - 0.12, fromX + (xs - fromX) * 0.85))
            m.curve = .nearMiss(cruise: cruise, crawlFrom: crawlFrom)
        } else {
            m.curve = valueFill ? .valueFill : .easeOut
        }
        m.starTimes = []
        // A delta reveal's stars do not land one by one: they stay or go with the fill.
        if !isDelta {
            for i in 0..<min(m.stars, m.starX.count) {
                let target = m.starX[i]
                var lo = 0.0, hi = 1.0
                for _ in 0..<50 {
                    let mid = (lo + hi) / 2
                    if m.x(u: mid) < target { lo = mid } else { hi = mid }
                }
                m.starTimes.append(start + hi * d)
            }
        }
        return m
    }

    private static func extraBeats(_ kinds: [RevealExtra], verdict: Double) -> [RevealPlan.ExtraBeat] {
        kinds.map { kind in
            switch kind {
            case .chapterComplete: return .init(extra: kind, at: verdict + 0.25)
            case .allStars: return .init(extra: kind, at: verdict + 0.08)
            case .newBest, .firstSolve: return .init(extra: kind, at: verdict)
            }
        }
    }

    /// The result as the next Check compares against it.
    static func revealed(report: PuzzleReport, evaluation: PuzzleEvaluation, revision: Data?) -> RevealedResult {
        let values: [[Double?]]
        let wrong: [[Bool]]
        if report.isTruthTable {
            values = report.rows.map { $0.cells.map { $0.value.flatMap { $0.isFinite ? $0 : nil } } }
            wrong = report.rows.map { $0.cells.map { $0.passes == false } }
        } else {
            values = [report.detectorRows.map { $0.value.flatMap { $0.isFinite ? $0 : nil } }]
            wrong = [report.detectorRows.map { $0.passes == false }]
        }
        let passed = evaluation.passed
        return RevealedResult(revision: revision, score: evaluation.score, passed: passed,
                              stars: passed ? evaluation.stars : 0, values: values, wrong: wrong)
    }

    /// The cases of the table with their values and the two-beam readings; times are set later.
    private static func caseInputs(report: PuzzleReport, puzzle: Puzzle, goal: RevealPlan.Goal,
                                   result: RevealedResult) -> [RevealPlan.CaseBeat] {
        let n = puzzle.inputs.count
        let bias = puzzle.scene.sources.contains { $0.enabled && !puzzle.inputs.contains($0.id) }
        let bits: [[Bool]] = goal == .truthTable ? report.rows.map(\.bits) : [[]]
        return result.values.indices.map { k in
            let to = result.values[k]
            var interference: [RevealPlan.Interference?] = Array(repeating: nil, count: to.count)
            if goal == .truthTable, !bias, n >= 2 {
                let on = bits[k].enumerated().filter(\.element).map(\.offset)
                if on.count == 2 {
                    let ka = 1 << (n - 1 - on[0]), kb = 1 << (n - 1 - on[1])
                    for j in to.indices where result.values.indices.contains(ka) && result.values.indices.contains(kb) {
                        let pa = result.values[ka][j] ?? 0, pb = result.values[kb][j] ?? 0, pab = to[j] ?? 0
                        guard pa >= 1e-4, pb >= 1e-4 else { continue }
                        let raw = (pab - pa - pb) / (2 * (pa * pb).squareRoot())
                        guard raw.isFinite, abs(raw) <= 1.05 else { continue }
                        interference[j] = .init(inputs: on, powerA: pa, powerB: pb, phase: acos(min(1, max(-1, raw))))
                    }
                }
            }
            let passes: Bool? = goal == .truthTable ? report.rows[k].passes : result.passed
            return RevealPlan.CaseBeat(index: k, bits: bits[k], start: nil, slot: 0, countDuration: 0, verdictAt: nil,
                                       fadeIn: 0, from: to.map { _ in 0 }, to: to, previous: nil, passes: passes,
                                       wrong: result.wrong[k], interference: interference, followsMeter: false,
                                       changed: false)
        }
    }

    /// "Passed, 3 of 3 stars, contrast 17.5 dB, new best." / "Not passed: contrast 5.4 dB,
    /// needs 6 dB, 0.6 dB short. Rows A1 B0 and A1 B1 are wrong."
    static func announcement(puzzle: Puzzle, report: PuzzleReport, score: Double, passed: Bool, stars: Int,
                             shortfall: Double, extras: [RevealExtra]) -> String {
        let scale = puzzle.scoreScale
        if passed {
            var s = "Passed, \(stars) of 3 stars, \(scale.label) \(scale.format(score))"
            if extras.contains(.firstSolve) {
                s += ", solved for the first time"
            } else if extras.contains(.newBest) {
                s += ", new best"
            }
            return s + "."
        }
        var s = "Not passed: \(scale.label) \(scale.format(score))"
        if let pass = puzzle.passScore {
            s += ", needs \(scale.formatThreshold(pass))"
            if shortfall > 0 { s += ", \(scale.format(shortfall)) short" }
        }
        s += "."
        if report.isTruthTable {
            let wrong = report.rows.filter { $0.passes == false }.map { row in
                zip(report.letters, row.bits).map { "\($0)\($1 ? 1 : 0)" }.joined(separator: " ")
            }
            if wrong.count == 1 {
                s += " Row \(wrong[0]) is wrong."
            } else if wrong.count > 1 {
                s += " Rows \(wrong.dropLast().joined(separator: ", ")) and \(wrong.last!) are wrong."
            }
        }
        return s
    }
}

/// 0 before `start`, 1 from `start + duration` on (to within a nanosecond, so a time scaled
/// by 0.7 still ends exactly), linear between.
func ramp(_ t: Double, from start: Double, over duration: Double) -> Double {
    if t >= start + duration - 1e-9 { return 1 }
    if t < start { return 0 }
    return min(1, max(0, (t - start) / duration))
}

func easeOutCubic(_ u: Double) -> Double {
    let x = min(1, max(0, u.isFinite ? u : 0))
    return 1 - pow(1 - x, 3)
}

func easeOutQuint(_ u: Double) -> Double {
    let x = min(1, max(0, u.isFinite ? u : 0))
    return 1 - pow(1 - x, 5)
}
