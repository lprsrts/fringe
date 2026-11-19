import Foundation

// From a reveal plan to the palette's input (design 4.3). The plan holds the times and values
// the views show; the sound is built from the same numbers, so a case's tap lands on its row
// highlight and a star's tone on its glyph.

extension ScoreTrack {
    /// The track's value → position knots, for the meter's pitch in the render block. The same
    /// mapping as `position(_:)`.
    var soundTrackMap: SoundTrackMap {
        let d = domain
        guard thresholds.count == 3, zip(thresholds, thresholds.dropFirst()).allSatisfy({ $0 < $1 }),
              thresholds[0] > d.lowerBound else {
            return SoundTrackMap(values: [d.lowerBound, d.upperBound], spots: [0, 1])
        }
        let values = [d.lowerBound] + thresholds + [max(d.upperBound, thresholds[2])]
        let spots: [Double] = values[4] > thresholds[2] ? [0, 0.4, 0.65, 0.9, 1] : [0, 0.45, 0.725, 1, 1]
        return SoundTrackMap(values: values, spots: spots)
    }
}

extension SoundRevealInput {
    /// The sound of `plan`, a reveal of `puzzle`'s Check result.
    init(plan: RevealPlan, puzzle: Puzzle) {
        let kind: Kind
        switch plan.kind {
        case .full: kind = .full
        case .delta: kind = .delta
        case .recheck: kind = .recheck
        case .reduced: kind = .reduced
        case .voiceOver: kind = .voiceOver
        case .instant: kind = .instant
        }
        let extra: Extra
        switch plan.topExtra {
        case nil: extra = .none
        case .newBest?: extra = .newBest
        case .firstSolve?: extra = .firstSolve
        case .allStars?: extra = .allStars
        case .chapterComplete?: extra = .chapterComplete
        }
        let m = plan.meter
        var meter = Meter(start: m.start, duration: m.duration, fromX: m.fromX, toX: m.toX, passX: m.track.passX,
                          starX: m.starX, curve: m.nearMiss ? .nearMiss : .normal, nearMissBeat: m.beatHz ?? 6)
        meter.starTimes = m.starTimes
        meter.previousStars = m.starsBefore
        meter.delta = m.isDelta
        if case .valueFill = m.curve {
            meter.valueFill = ValueFill(track: m.track.soundTrackMap, fromValue: m.fromScore, toValue: m.toScore)
        }
        self.init(kind: kind, passed: plan.passed, stars: plan.stars, verdictAt: plan.verdictAt, extra: extra, meter: meter)

        if plan.goal == .truthTable {
            let scale = plan.fullScale > 0 ? plan.fullScale : 1
            cases = plan.cases.compactMap { c in
                guard let start = c.start else { return nil }
                return Case(start: start, outputs: c.to.indices.map { j in
                    let previous = c.previous.flatMap { j < $0.count ? $0[j] : nil }
                    return Output(value: (c.to[j] ?? 0) / scale,
                                  previous: previous.map { $0 / scale },
                                  wrong: j < c.wrong.count && c.wrong[j],
                                  interference: (j < c.interference.count ? c.interference[j] : nil)
                                      .map { Interference(powerA: $0.powerA / scale, powerB: $0.powerB / scale, phase: $0.phase) })
                })
            }
            caseStep = plan.cases.first { $0.start != nil }?.slot ?? RevealPlanner.step(cases: plan.cases.count)
            return
        }

        // Single-case goals: one voice is the reading and the meter.
        guard let c = plan.cases.first else { return }
        caseStep = m.duration
        let goal: GoalKind
        switch plan.goal {
        case .minimize: goal = .minimize
        case .target: goal = .target
        default: goal = .maximize
        }
        func field(_ values: [Double?]) -> Double {
            let v = values.map { $0 ?? 0 }
            switch plan.goal {
            // The residual over the reference (several detectors: their sum sets the score),
            // or the total of a split.
            case .minimize, .target: return v.reduce(0, +)
            // A fraction of the source power, or an intensity factor over its full scale.
            default: return (v.first ?? 0) / (plan.fullScale > 0 ? plan.fullScale : 1)
            }
        }
        var single = SingleCase(kind: goal, fieldValue: field(c.to))
        if plan.kind == .delta, let previous = c.previous { single.previousFieldValue = field(previous) }
        if plan.goal == .target {
            let v = c.to.map { $0 ?? 0 }
            let total = v.reduce(0, +)
            if v.count >= 2, total > 0 {
                let share = v[0] / total
                let ratio = puzzle.goal.ratio ?? 0.5
                let tolerance = max(puzzle.goal.tolerance ?? 0.05, 1e-9)
                single.pan = min(0.8, max(-0.8, 0.35 * (share - ratio) / tolerance))
            }
            let pass = puzzle.passScore ?? m.track.thresholds.first ?? 0
            single.sideConditionFailed = !plan.passed && plan.score >= pass
        }
        self.single = single
    }
}
