import Foundation

/// `--reveal-self-test`: builds the reveal plan of every bundled puzzle for made-up results
/// (a pass, a near miss, a far fail, three stars, the same result again, a better and a
/// worse result after a first one, a flip to fail and to pass, a star gained after a first
/// result, a near miss after a fail, a target split that fails its side condition) under each
/// option set (normal, Reduce Motion, VoiceOver, sound off, animation off, Reduce Motion with
/// sound off, after three skips), checks the kind and the timing rules of the design (§1.2,
/// §1.5, §1.6, §1.8, §4.6) and prints a table.
/// Returns the number of failed checks.
enum RevealSelfTest {
    enum Outcome: String, CaseIterable {
        case pass, nearMiss = "near-miss", farFail = "far-fail", threeStars = "3-stars"
        case recheck, deltaBetter = "delta-better", deltaWorse = "delta-worse"
        case flipToFail = "flip-to-fail", flipToPass = "flip-to-pass", starGain = "star-gain"
        case deltaNearMiss = "delta-near", sideFail = "side-fail"

        var isNearMiss: Bool { self == .nearMiss || self == .deltaNearMiss }
    }

    enum Variant: String, CaseIterable {
        case normal, reduceMotion = "reduce-motion", voiceOver = "voiceover", soundOff = "sound-off"
        case animateOff = "animate-off", reduceMotionSoundOff = "rm-sound-off", shortened = "3-skips"

        var options: RevealOptions {
            switch self {
            case .normal: return RevealOptions(soundOn: true)
            case .reduceMotion: return RevealOptions(reduceMotion: true, soundOn: true)
            case .voiceOver: return RevealOptions(voiceOver: true, soundOn: true)
            case .soundOff: return RevealOptions(soundOn: false)
            case .animateOff: return RevealOptions(soundOn: true, animate: false)
            case .reduceMotionSoundOff: return RevealOptions(reduceMotion: true, soundOn: false)
            case .shortened: return RevealOptions(soundOn: true, skipsInARow: 3)
            }
        }
    }

    static func run() -> Int {
        var failures = 0
        var rows: [String] = []
        let puzzles = FringeBridge.puzzleList().compactMap { FringeBridge.puzzle($0.id) }
        if puzzles.isEmpty {
            print("FAIL no puzzles")
            return 1
        }
        let header = "puzzle".padding(toLength: 34, withPad: " ", startingAt: 0) + "outcome".padding(toLength: 14, withPad: " ", startingAt: 0)
            + Variant.allCases.map { $0.rawValue.padding(toLength: 20, withPad: " ", startingAt: 0) }.joined()
        rows.append(header)
        var plans = 0
        for puzzle in puzzles {
            for outcome in Outcome.allCases where outcome != .sideFail || puzzle.goal.type == "target" {
                var cells: [String] = []
                for variant in Variant.allCases {
                    let (cell, problems) = check(puzzle, outcome, variant)
                    plans += 1
                    cells.append(cell.padding(toLength: 20, withPad: " ", startingAt: 0))
                    for p in problems {
                        print("FAIL \(puzzle.id) \(outcome.rawValue) \(variant.rawValue): \(p)")
                        failures += 1
                    }
                }
                rows.append(puzzle.id.padding(toLength: 34, withPad: " ", startingAt: 0)
                            + outcome.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0) + cells.joined())
            }
        }
        print("Each cell: kind, verdict at / visual end in seconds.")
        rows.forEach { print($0) }
        print("\(plans) plans over \(puzzles.count) puzzles, \(failures) failed checks.")
        return failures
    }

    /// One plan and its checks: the table cell and the problems found.
    static func check(_ puzzle: Puzzle, _ outcome: Outcome, _ variant: Variant) -> (String, [String]) {
        var problems: [String] = []
        let stars = puzzle.stars
        guard stars.count == 3, let pass = puzzle.passScore else { return ("no stars", ["the puzzle has no three stars"]) }
        let (s1, s2, s3) = (stars[0], stars[1], stars[2])
        let between = s1 + 0.5 * (s2 - s1)
        let score: Double
        var previousScore: Double?
        switch outcome {
        case .pass: score = between
        case .threeStars: score = s3 + 0.2 * (s3 - s2)
        case .nearMiss: score = pass - 0.04 * abs(pass)
        case .farFail: score = pass > 0 ? 0.3 * pass : pass - 10
        case .recheck: score = between; previousScore = between
        case .deltaBetter: score = s1 + 0.6 * (s2 - s1); previousScore = s1 + 0.1 * (s2 - s1)
        case .deltaWorse: score = between; previousScore = s2 + 0.5 * (s3 - s2)
        case .flipToFail: score = pass > 0 ? 0.3 * pass : pass - 10; previousScore = between
        case .flipToPass: score = between; previousScore = pass > 0 ? 0.3 * pass : pass - 10
        case .starGain: score = s3 + 0.2 * (s3 - s2); previousScore = between
        case .deltaNearMiss: score = pass - 0.04 * abs(pass); previousScore = pass > 0 ? 0.3 * pass : pass - 10
        case .sideFail: score = between
        }
        guard let evaluation = evaluation(puzzle, score: score, failsSideCondition: outcome == .sideFail) else { return ("no result", ["the made-up result did not decode"]) }
        let revision = Data("design-\(outcome.rawValue)".utf8)
        var previous: RevealedResult?
        var before = PuzzleProgress()
        if let previousScore, let first = self.evaluation(puzzle, score: previousScore) {
            let report = PuzzleReport(puzzle: puzzle, evaluation: first)
            previous = RevealPlanner.revealed(report: report, evaluation: first,
                                              revision: outcome == .recheck ? revision : Data("earlier".utf8))
            before.record(score: first.score, stars: first.stars, passed: first.passed)
        }
        var after = before
        after.record(score: evaluation.score, stars: evaluation.stars, passed: evaluation.passed)
        let options = variant.options
        guard let plan = RevealPlanner.plan(evaluation: evaluation, revision: revision, previous: previous, puzzle: puzzle,
                                            shownBits: puzzle.allCases.last ?? [], before: before, after: after,
                                            firstCheckThisSession: previous == nil, chapterCompleted: false,
                                            options: options) else { return ("no plan", ["no plan for a scored result"]) }
        let cell = "\(plan.kind.rawValue) \(fmt(plan.verdictAt))/\(fmt(plan.visualEnd))"

        // The kind.
        let expected: RevealPlan.Kind
        switch variant {
        case .voiceOver: expected = .voiceOver
        case .reduceMotion: expected = .reduced
        case .animateOff, .reduceMotionSoundOff: expected = .instant
        default:
            switch outcome {
            case .recheck: expected = .recheck
            case .deltaBetter, .deltaWorse, .deltaNearMiss: expected = .delta
            // A star gained replays the whole result, unless three skips shortened reveals.
            case .starGain: expected = variant == .shortened ? .delta : .full
            default: expected = .full
            }
        }
        if plan.kind != expected { problems.append("kind \(plan.kind.rawValue), expected \(expected.rawValue)") }

        // Caps (§1.2, §1.8).
        let eps = 1e-9
        switch plan.kind {
        case .full where plan.goal == .truthTable:
            if plan.verdictAt > 1.6 + eps { problems.append("full truth-table verdict at \(fmt(plan.verdictAt)) s > 1.6 s") }
        case .full:
            if plan.verdictAt > 0.95 + eps { problems.append("single-case verdict at \(fmt(plan.verdictAt)) s > 0.95 s") }
        case .delta:
            if plan.verdictAt > 0.6 + eps { problems.append("delta verdict at \(fmt(plan.verdictAt)) s > 0.6 s") }
        case .reduced:
            if plan.visualEnd > 0.6 + eps { problems.append("Reduce Motion ends at \(fmt(plan.visualEnd)) s > 0.6 s") }
        case .recheck:
            if plan.visualEnd > 0.1 + eps { problems.append("re-check ends at \(fmt(plan.visualEnd)) s > 0.1 s") }
        case .voiceOver, .instant:
            if plan.visualEnd > 0.15 + eps { problems.append("instant reveal ends at \(fmt(plan.visualEnd)) s") }
        }
        if plan.visualEnd + eps < plan.verdictAt { problems.append("visual end before the verdict") }
        for e in plan.extras where e.at > plan.verdictAt + 0.3 + eps {
            problems.append("extra \(e.extra) at \(fmt(e.at)) s, more than 0.3 s after the verdict")
        }
        if variant == .soundOff, plan.kind == .full || plan.kind == .delta, abs(plan.timeScale - 0.7) > eps {
            problems.append("sound off does not shorten the timeline (×\(plan.timeScale))")
        }

        // The near miss and its beat (§1.5).
        if let beat = plan.meter.beatHz, !(1.5 - eps...6 + eps).contains(beat) { problems.append("near-miss beat \(beat) Hz") }
        if outcome.isNearMiss, !plan.meter.nearMiss { problems.append("a score just under the pass is not a near miss") }
        if outcome.isNearMiss, plan.shortfall == nil { problems.append("a near miss has no shortfall line") }
        if outcome == .farFail || outcome == .flipToFail, plan.meter.nearMiss { problems.append("a far fail reads as a near miss") }
        if outcome == .sideFail {
            if plan.passed || plan.stars != 0 { problems.append("a split outside its tolerance passes") }
            if plan.meter.nearMiss { problems.append("a side-condition fail reads as a near miss") }
            if plan.options.soundOn, plan.kind == .full,
               SoundRevealInput(plan: plan, puzzle: puzzle).single?.sideConditionFailed != true {
                problems.append("the sound does not mark the failed side condition")
            }
        }
        if plan.kind == .reduced || plan.kind == .instant, plan.extras.contains(where: { $0.extra == .newBest }),
           plan.frame(at: plan.verdictAt + 0.01).bestScore != plan.final.bestScore {
            problems.append("the best marker slides under Reduce Motion or the short fade")
        }
        if plan.meter.nearMiss, plan.passed { problems.append("a pass marked as a near miss") }

        // Stars land in order, as the fill crosses their ticks.
        let times = plan.meter.starTimes
        if plan.kind == .full {
            if times.count != plan.stars { problems.append("\(times.count) star times for \(plan.stars) stars") }
            for (i, t) in times.enumerated() {
                if i > 0, t <= times[i - 1] { problems.append("star \(i + 1) lands before star \(i)") }
                let x = plan.meter.x(at: t)
                if abs(x - plan.meter.starX[i]) > 1e-3 { problems.append("star \(i + 1) lands at x \(fmt(x)), its tick is at \(fmt(plan.meter.starX[i]))") }
                if t < plan.meter.start - eps || t > plan.meter.end + eps { problems.append("star \(i + 1) lands outside the meter") }
            }
        }

        // Frames: hidden at the start of a full reveal, the final frame at the end, the fill
        // never running backwards in a full reveal.
        let end = plan.frame(at: plan.visualEnd)
        if end != plan.final { problems.append("frame(at: visualEnd) is not the final frame: \(differences(end, plan.final))") }
        if plan.frame(at: plan.visualEnd + 5) != plan.final { problems.append("frames after the end are not final") }
        if plan.kind == .full {
            let start = plan.frame(at: 0)
            if start.verdictShown { problems.append("the verdict shows at t = 0") }
            if start.meterX != nil { problems.append("the fill shows at t = 0") }
            if start.values.contains(where: { $0.contains { $0 != nil } }) { problems.append("a value shows at t = 0") }
            // From its start towards the score, never back (a × score under free space
            // counts down from 1.0×).
            let sign: Double = plan.meter.toX >= plan.meter.fromX ? 1 : -1
            var last: Double?
            for i in 0...200 {
                let f = plan.frame(at: plan.visualEnd * Double(i) / 200)
                if let x = f.meterX {
                    if let last, sign * (x - last) < -1e-12 { problems.append("the fill turns back"); break }
                    last = x
                }
            }
            if plan.goal == .truthTable, plan.caseCount > 1, !plan.canvasSteps { problems.append("the canvas does not step") }
        }
        if plan.kind == .delta {
            let start = plan.frame(at: 0)
            if start.meterX == nil { problems.append("a delta reveal starts with an empty fill") }
            if outcome == .deltaBetter, plan.goal == .truthTable, abs(score - (previousScore ?? score)) >= 1.5,
               !plan.cases.contains(where: \.changed) {
                problems.append("no case changed in a better result")
            }
        }
        if plan.kind == .voiceOver, plan.announcement.isEmpty { problems.append("no announcement") }
        if plan.options.soundOn { problems += checkSound(plan, puzzle) }
        return (cell, problems)
    }

    /// The reveal's sound against its picture (§1.2, §2.5): the meter tone follows the fill,
    /// the struck star tones land with their glyphs, and nothing sounds past 3 s.
    static func checkSound(_ plan: RevealPlan, _ puzzle: Puzzle) -> [String] {
        var problems: [String] = []
        let input = SoundRevealInput(plan: plan, puzzle: puzzle)
        let score = SoundPalette.reveal(input)
        if plan.kind == .instant {
            if !score.isEmpty { problems.append("an instant reveal makes a sound") }
            return problems
        }
        if score.isEmpty { problems.append("no sound") }
        if SoundPalette.skipTone(for: input).isEmpty { problems.append("no verdict tone for a skip") }
        if score.end > 3.0 + 1e-9 { problems.append("sound ends at \(fmt(score.end)) s > 3.0 s") }
        for n in score.notes where !(n.start.isFinite && n.amplitude.isFinite && n.end.isFinite) {
            problems.append("a note with a value that is not finite")
            break
        }
        guard plan.kind == .full || plan.kind == .delta, let m = input.meter else { return problems }
        // The tone's fill against the picture's, through the whole meter. A near miss's
        // crawl is shaped the same way but may start from a slightly different cruise point.
        let tolerance = plan.meter.nearMiss && !plan.meter.isDelta ? 0.03 : 1e-6
        for i in 0...100 {
            let u = Double(i) / 100
            let heard = SoundMeterMath.fillX(m, u: u), seen = plan.meter.x(u: u)
            if abs(heard - seen) > tolerance {
                problems.append("the meter tone's fill is at x \(fmt(heard)) where the bar is at \(fmt(seen)) (u \(fmt(u)))")
                break
            }
        }
        // The star tones are struck when the bar's fill crosses each tick, and the tone
        // passes through the star's pitch there.
        if plan.kind == .full {
            let heard = SoundMeterMath.starCrossingTimes(m, stars: plan.stars)
            for (i, t) in plan.meter.starTimes.enumerated() where i < heard.count && abs(heard[i] - t) > 0.002 {
                problems.append("star \(i + 1): the tone crosses at \(fmt(heard[i])) s, the glyph lands at \(fmt(t)) s")
            }
        }
        return problems
    }

    /// A scored result of `puzzle` with `score`, its detector values made to match.
    /// `failsSideCondition`: a target split whose power is above the pass but whose share is
    /// outside its tolerance, so it fails.
    static func evaluation(_ puzzle: Puzzle, score: Double, failsSideCondition: Bool = false) -> PuzzleEvaluation? {
        let pass = puzzle.passScore ?? 0
        let passed = score >= pass && !failsSideCondition
        let stars = passed ? puzzle.stars.filter { $0 <= score }.count : 0
        let ids = puzzle.goalDetectorIDs
        var cases: [[String: Any]] = []
        switch puzzle.goal.type {
        case "truth_table":
            let one = 0.5, zero = one / pow(10, score / 10)
            let targets = Dictionary(puzzle.goal.outputs.map { ($0.detector, $0.bits) }, uniquingKeysWith: { a, _ in a })
            for (k, bits) in puzzle.allCases.enumerated() {
                let outputs: [[String: Any]] = ids.map { id in
                    let bit = targets[id].flatMap { $0.indices.contains(k) ? $0[k] : nil } ?? 0
                    // A little spread between the cases, as real readings have.
                    let v = (bit == 1 ? one : zero) * (1 + 0.02 * Double(k))
                    return ["detector": id, "value": v, "target": bit == 1]
                }
                cases.append(["bits": bits, "weights": [], "readings": [], "outputs": outputs])
            }
        default:
            let values: [Double]
            switch puzzle.goal.type {
            case "minimize":
                let residual = pow(10, -score / 10)
                values = ids.map { _ in residual / Double(max(1, ids.count)) }
            case "target":
                let ratio = puzzle.goal.ratio ?? 0.5
                values = ids.enumerated().map { i, _ in score / 100 * (i == 0 ? ratio : 1 - ratio) }
            default:
                values = ids.map { _ in puzzle.scoreScale.unit == "×" ? score : score / 100 }
            }
            let outputs: [[String: Any]] = zip(ids, values).map { ["detector": $0, "value": $1] }
            cases.append(["bits": [Bool](), "weights": [], "readings": [], "outputs": outputs])
        }
        let object: [String: Any] = [
            "puzzle": puzzle.id, "valid": true, "issues": [], "sources": [], "inputs": puzzle.inputs,
            "cases": cases, "score": score, "pass": pass, "passed": passed, "stars": stars,
            "star_thresholds": puzzle.stars,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(PuzzleEvaluation.self, from: data)
    }

    private static func fmt(_ v: Double) -> String { String(format: "%.2f", v) }

    /// The fields in which two frames differ, for a failure line.
    static func differences(_ a: RevealFrame, _ b: RevealFrame) -> String {
        var out: [String] = []
        if a.values != b.values { out.append("values \(a.values) vs \(b.values)") }
        if a.dimmed != b.dimmed { out.append("dimmed") }
        if a.caseVerdictShown != b.caseVerdictShown { out.append("case verdicts") }
        if a.caseOpacity != b.caseOpacity { out.append("case opacity \(a.caseOpacity)") }
        if a.highlightedCase != b.highlightedCase { out.append("highlight") }
        if a.canvasCase != b.canvasCase { out.append("canvas") }
        if a.inputsDimmed != b.inputsDimmed { out.append("inputs") }
        if a.meterX != b.meterX { out.append("meter x \(a.meterX ?? .nan) vs \(b.meterX ?? .nan)") }
        if a.meterOpacity != b.meterOpacity { out.append("meter opacity \(a.meterOpacity)") }
        if a.starLand != b.starLand { out.append("stars \(a.starLand) vs \(b.starLand)") }
        if a.starsFadeOnly != b.starsFadeOnly { out.append("star fade only") }
        if a.bestScore != b.bestScore { out.append("best \(a.bestScore ?? .nan) vs \(b.bestScore ?? .nan)") }
        if a.verdictOpacity != b.verdictOpacity { out.append("verdict \(a.verdictOpacity)") }
        if a.extrasShown != b.extrasShown { out.append("extras") }
        if a.showsAfterProgress != b.showsAfterProgress { out.append("progress") }
        if a.showSkipHint != b.showSkipHint { out.append("skip hint") }
        if a.nearMissShortfall != b.nearMissShortfall { out.append("shortfall") }
        return out.joined(separator: "; ")
    }
}
