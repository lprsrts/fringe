import Foundation

// The puzzle sounds as data: the tuning table, the levels, the meter map (design 2.5), the
// event recipes (2.2) and the builder that turns a reveal description into a SoundScore.
// Pure functions of their inputs; nothing here plays anything. SoundEngine plays a score, and
// the offline test tool renders the same scores to WAV through the same SynthBank.
//
// How a reveal reaches this file
// ------------------------------
// `SoundPalette.reveal(_:)` takes a `SoundRevealInput`, a small Sendable value that the reveal
// planner fills from its RevealPlan. Times are seconds after the Check result arrives (t = 0 of
// the design), on the same clock as the plan's visual beats. The fields:
//
// - `kind`: `.full` (cases, then the meter, design 1.3/1.4), `.delta` (changed cases glide from
//   their previous values and the meter runs from the previous score, 1.6), `.recheck` (the
//   verdict tone at 60 ms), `.reduced` (Reduce Motion: the verdict tone at 360 ms, 1.8),
//   `.voiceOver` (the verdict tone at −6 dB when the announcement is posted) or `.instant`
//   (no sound).
// - `passed`, `stars` (0…3), `verdictAt`, `extra` (only the highest one; it sounds at the
//   verdict).
// - `cases`: truth tables only, the cases that play, in table order, each with its start
//   time and one `Output` per goal detector: the normalised power `value` (0…1 of the
//   reference, NaN and negatives are treated as 0), the `previous` value in a delta reveal,
//   whether that output is `wrong` on this row, and optional `interference` data (the powers
//   of input A alone and input B alone on this detector and the inferred phase φ; see
//   `SoundInterference.infer`). `caseStep` is the time between case starts (S of 1.3, or the
//   delta step).
// - `meter`: start, duration, the fill from/to x on the ScoreBar track, the pass and star
//   positions on that track, `curve` (.normal or .nearMiss), the near-miss beat in Hz
//   (1.5…6), the crossing times of the earned stars (absolute, full reveals only; they must be
//   the times the fill crosses each star, `SoundMeterMath.starCrossingTimes` computes them),
//   the previous result's stars (delta), and, for single-case goals, `valueFill`: the fill
//   then follows the counted value through the track map (ScoreBar's position function).
// - `single`: single-case goals only (maximize, minimize, target). One voice is both the
//   reading and the meter; `fieldValue` is the normalised power it ends on (minimize: the
//   residual over the reference), `previousFieldValue` the value it starts from in a delta,
//   `pan` the target lean (0.35 · share difference / tolerance, clamped to ±0.8), and
//   `sideConditionFailed` (the share is outside its tolerance).
//
// Skipping: call `SoundEngine.fadeOutAll(0.06)` and then play `SoundPalette.skipTone(for:)`.

// MARK: - Tuning and levels

/// Just intonation on C4 = 261.63 Hz (design 2.1).
enum SoundTuning {
    static let R = 261.63
    static let G3 = R * 3 / 4
    static let C4 = R
    static let E4 = R * 5 / 4
    static let G4 = R * 3 / 2
    static let C5 = R * 2
    static let E5 = R * 5 / 2
    static let G5 = R * 3
    static let C6 = R * 4
    static let E6 = R * 5
    /// Truth-table output voices: all at or above 261 Hz, consonant with each other.
    static let outputPitch = [C4, E4, R * 9 / 8, R * 4 / 3]
    /// Star 1 (= pass), star 2, star 3.
    static let starPitch = [G4, C5, E5]
    static let meterPitches = (g3: G3, g4: G4, c5: C5, e5: E5, g5: G5)

    static func outputPitch(_ index: Int) -> Double { outputPitch[min(max(index, 0), outputPitch.count - 1)] }
}

/// Levels at the default volume (master gain 1), linear peak per channel at centre.
/// Calibrated so the loudest 400 ms of a reveal is −28 ± 2 LUFS.
enum SoundLevel {
    static let star = [SynthMath.dB(-25), SynthMath.dB(-26), SynthMath.dB(-27)]
    /// The truth-table meter riser, 6.5 dB under star 1.
    static let riser = SynthMath.dB(-31.5)
    /// The shutter tap of each case.
    static let tick = SynthMath.dB(-23)
    /// Verdict tone (skip, re-check, Reduce Motion, delta chord) relative to the reveal.
    static let verdictToneDB = -3.0
    /// Verdict tone under VoiceOver.
    static let voiceOverDB = -6.0
    /// Toggle tones after a Check: the field and the tap at −6 dB (0.5).
    static let toggleDB = -6.0
}

// MARK: - Score

/// Notes with start offsets in seconds from the moment the score is played.
struct SoundScore: Sendable {
    var notes: [NoteSpec] = []

    static let empty = SoundScore()

    var isEmpty: Bool { notes.isEmpty }
    /// When the last note has rung out (−60 dB plus the 5 ms ramp).
    var end: Double { notes.map(\.end).max() ?? 0 }

    mutating func append(_ note: NoteSpec) { notes.append(note) }
    mutating func append(contentsOf other: SoundScore) { notes += other.notes }

    /// The same score starting `seconds` later.
    func delayed(by seconds: Double) -> SoundScore {
        SoundScore(notes: notes.map { n in var n = n; n.start += seconds; return n })
    }
}

// MARK: - Reveal input

/// What a reveal sounds like, described by the reveal planner. See the top of this file.
struct SoundRevealInput: Sendable {
    enum Kind: Sendable { case full, delta, recheck, reduced, voiceOver, instant }

    /// Extras in rising priority; only the highest one that applies is given.
    enum Extra: Int, Sendable, Comparable {
        case none, newBest, firstSolve, allStars, chapterComplete
        static func < (a: Extra, b: Extra) -> Bool { a.rawValue < b.rawValue }
    }

    struct Interference: Sendable {
        /// Normalised power of the first input alone (it plays first) and of the second alone.
        var powerA: Double
        var powerB: Double
        /// Relative phase φ of the second beam (rad), fixed.
        var phase: Double
    }

    struct Output: Sendable {
        var value: Double
        var previous: Double? = nil
        var wrong = false
        var interference: Interference? = nil
    }

    struct Case: Sendable {
        var start: Double
        var outputs: [Output]
    }

    enum Curve: Sendable { case normal, nearMiss }

    struct ValueFill: Sendable {
        var track: SoundTrackMap
        var fromValue: Double
        var toValue: Double
    }

    struct Meter: Sendable {
        var start: Double
        var duration: Double
        var fromX: Double
        var toX: Double
        var passX: Double
        /// Track positions of star 1 (the pass line), 2 and 3.
        var starX: [Double]
        var curve: Curve = .normal
        var nearMissBeat: Double = 6
        /// Absolute crossing times of the earned stars (full reveals; empty for delta).
        var starTimes: [Double] = []
        /// Delta reveals: the stars of the previous result.
        var previousStars = 0
        /// Single-case goals: the fill follows the counted value.
        var valueFill: ValueFill? = nil
        /// Whether the meter runs from a previous result. Nil decides by `fromX > 0`, which is
        /// wrong for a full reveal whose track starts above 0 (× puzzles count from 1.0×).
        var delta: Bool? = nil

        var isDelta: Bool { delta ?? (fromX > 0) }
    }

    enum GoalKind: Sendable { case maximize, minimize, target }

    struct SingleCase: Sendable {
        var kind: GoalKind
        var fieldValue: Double
        var previousFieldValue: Double? = nil
        var pan: Double = 0
        var sideConditionFailed = false
    }

    var kind: Kind
    var passed: Bool
    var stars: Int
    var verdictAt: Double
    var extra: Extra = .none
    var cases: [Case] = []
    var caseStep: Double = 0.25
    var meter: Meter? = nil
    var single: SingleCase? = nil
}

// MARK: - Track and meter math

/// The ScoreBar's value → x map as knots (Views/Plots/PuzzleCharts.swift, ScoreBar.position).
/// `scoreBar` is a port of that function; the integration may build the knots from ScoreBar
/// itself instead.
struct SoundTrackMap: Sendable {
    var values: [Double]
    var spots: [Double]

    func position(_ v: Double) -> Double {
        var p = SynthMeterPitch()
        p.setTrack(values: values, spots: spots)
        return p.track(v)
    }

    static func scoreBar(thresholds: [Double], pass: Double, percent: Bool) -> SoundTrackMap {
        // Domain, as ScoreBar.domain.
        var lo = 0.0, hi = 1.0
        if let first = thresholds.first, let last = thresholds.last {
            let spread = max(last - first, abs(last) * 0.1, 1e-9)
            let step = pow(10, floor(log10(spread)))
            lo = max(0, floor((first - 1.5 * spread) / step) * step)
            if lo <= 0.5 * first { lo = 0 }
            hi = last + 0.6 * spread
            if percent, last <= 100 { hi = min(hi, 100) }
            hi = max(hi, lo + 1e-9)
        }
        let ordered = thresholds.count == 3 && thresholds[0] < thresholds[1] && thresholds[1] < thresholds[2]
        guard ordered, thresholds[0] > lo else {
            return SoundTrackMap(values: [lo, hi], spots: [0, 1])
        }
        let values = [lo] + thresholds + [max(hi, thresholds[2])]
        let spots: [Double] = values[4] > thresholds[2] ? [0, 0.4, 0.65, 0.9, 1] : [0, 0.45, 0.725, 1, 1]
        return SoundTrackMap(values: values, spots: spots)
    }
}

enum SoundMeterMath {
    /// Near miss (design 1.5): xp − 0.15 ≤ xs < xp, or within 10 % of the pass value, and not
    /// passed. The beat against G4 is 1.5 Hz a hair short and 6 Hz at the edge of the zone.
    static func nearMiss(toX xs: Double, passX xp: Double, score: Double, pass: Double, passed: Bool)
        -> (isNearMiss: Bool, beat: Double) {
        let byX = (xp - xs) / 0.15
        let byValue = pass != 0 ? (pass - SynthMath.finite(score)) / (0.1 * abs(pass)) : 2
        let isNear = !passed && xs < xp && min(byX, byValue) <= 1
        let beat = 1.5 + 4.5 * SynthMath.clamp(min(byX, byValue), 0, 1)
        return (isNear, beat)
    }

    /// The rest pitch of a result: the top earned star, or the meter map at the score.
    static func restPitch(meter m: SoundRevealInput.Meter, x: Double, stars: Int) -> Double {
        if stars > 0 { return SoundTuning.starPitch[min(stars, 3) - 1] }
        return pitchCurve(m, stars: 0).map(x)
    }

    /// Where the meter tone stops: G4 − beat for a near miss, else the rest pitch.
    static func stopPitch(meter m: SoundRevealInput.Meter, stars: Int) -> Double {
        if m.curve == .nearMiss { return SoundTuning.G4 - SynthMath.clamp(m.nearMissBeat, 1.5, 6) }
        return restPitch(meter: m, x: m.toX, stars: stars)
    }

    /// The meter pitch the render block evaluates, without the star lock.
    static func pitchCurve(_ m: SoundRevealInput.Meter, stars: Int) -> SynthMeterPitch {
        var p = SynthMeterPitch()
        p.isActive = true
        p.duration = m.duration
        p.fromX = m.fromX
        p.toX = m.toX
        p.passX = m.passX
        p.setAnchors(passX: m.passX, starX: m.starX, pitches: SoundTuning.meterPitches)
        let isDelta = m.isDelta
        if m.curve == .nearMiss && !isDelta {
            p.fill = .nearMiss
        } else if let vf = m.valueFill, !isDelta {
            p.fill = .value
            p.setTrack(values: vf.track.values, spots: vf.track.spots)
            p.fromValue = vf.fromValue
            p.toValue = vf.toValue
        } else {
            p.fill = .ease
        }
        p.prepare()
        p.stopPitch = m.curve == .nearMiss
            ? SoundTuning.G4 - SynthMath.clamp(m.nearMissBeat, 1.5, 6)
            : (stars > 0 ? SoundTuning.starPitch[min(stars, 3) - 1] : p.map(m.toX))
        return p
    }

    /// The fill position at u = (t − start) / duration, as the render block computes it.
    static func fillX(_ m: SoundRevealInput.Meter, u: Double) -> Double {
        pitchCurve(m, stars: 0).x(u)
    }

    /// Absolute times at which the fill crosses each earned star (full reveals; none for delta).
    static func starCrossingTimes(_ m: SoundRevealInput.Meter, stars: Int) -> [Double] {
        guard !m.isDelta else { return [] }
        let p = pitchCurve(m, stars: 0)
        var times: [Double] = []
        for i in 0..<min(stars, m.starX.count) {
            let target = m.starX[i]
            var lo = 0.0, hi = 1.0
            for _ in 0..<50 {
                let mid = (lo + hi) / 2
                if p.x(mid) < target { lo = mid } else { hi = mid }
            }
            times.append(m.start + hi * m.duration)
        }
        return times
    }
}

/// Two-beam inference of design 2.4 for a case with exactly two inputs on.
enum SoundInterference {
    /// `both`: the detector's power with both inputs on; `a`, `b`: with each input alone (all
    /// on the same scale). Nil means "play a plain reading": another source is always on, the
    /// number of inputs on is not 2, a single-input power is under 1e-4 of full scale, or the
    /// clamp would move cos φ by more than 0.05.
    static func infer(both: Double, a: Double, b: Double, fullScale: Double = 1,
                      inputsOn: Int, otherSourceOn: Bool) -> SoundRevealInput.Interference? {
        guard inputsOn == 2, !otherSourceOn, fullScale > 0 else { return nil }
        let pa = SynthMath.finite(a) / fullScale, pb = SynthMath.finite(b) / fullScale
        let pab = SynthMath.finite(both) / fullScale
        guard pa >= 1e-4, pb >= 1e-4 else { return nil }
        let raw = (pab - pa - pb) / (2 * (pa * pb).squareRoot())
        guard abs(raw) <= 1.05 else { return nil }
        return .init(powerA: pa, powerB: pb, phase: acos(SynthMath.clamp(raw, -1, 1)))
    }
}

// MARK: - Recipes

enum SoundPalette {
    /// One case of a detector voice.
    struct CaseSegment {
        var t: Double
        var value: Double
        var interference: SoundRevealInput.Interference? = nil
        var wrong = false
        var from: Double? = nil
    }

    /// The detector voice (2.2): one phase-continuous field voice per goal detector for the
    /// whole case sequence. Each case: a shutter tap, a 30 ms −6 dB dip and a 25 ms glide of the
    /// field to the case's value. An interference case plays input A alone for 80 ms, then B's
    /// field ramps in over 100 ms at the fixed phase. A wrong row carries roughness inside it.
    static func detectorVoice(_ segs: [CaseSegment], step S: Double, pitch: Double,
                              glide: Double = 0.025, deltaGlide: Double = 0.12, tau: Double = 0.06,
                              fieldGain: Double = 1, tickAmp: Double = SoundLevel.tick,
                              lastHold: Double = 0.08) -> NoteSpec? {
        guard let first = segs.first, let last = segs.last else { return nil }
        let t0 = first.t
        func root(_ v: Double) -> Double { SynthMath.clamp(v, 0, 1).squareRoot() }
        var field: [(Double, Double)] = []
        var partner: [(Double, Double)] = [(0, 0)]
        var phase: [(Double, Double)] = []
        var gain: [(Double, Double)] = [(0, 0)]
        var rough: [(Double, Double)] = [(0, 0)]
        var current = 0.0
        var currentPartner = 0.0
        for (k, s) in segs.enumerated() {
            let a = s.t - t0
            let target = s.interference.map { root($0.powerA) } ?? root(s.value)
            field.append((a, current))
            if let from = s.from {
                field.append((a + glide, root(from)))
                field.append((a + glide + deltaGlide, target))
            } else {
                field.append((a + glide, target))
            }
            partner.append((a, currentPartner))
            partner.append((a + glide, 0))
            currentPartner = 0
            if let i = s.interference {
                phase.append((a + glide + 0.001, SynthMath.finite(i.phase)))
                partner.append((a + 0.080, 0))
                partner.append((a + 0.180, root(i.powerB)))
                currentPartner = root(i.powerB)
            }
            if k == 0 {
                gain.append((a + 0.020, 1))
            } else {
                gain.append((a, 1))
                gain.append((a + 0.012, 0.5))
                gain.append((a + 0.030, 1))
            }
            let end = k + 1 < segs.count ? segs[k + 1].t - t0 : a + S
            rough.append((a, 0))
            if s.wrong {
                rough.append((a + 0.02, 1))
                rough.append((end - 0.01, 1))
                rough.append((end, 0))
            }
            current = target
        }
        let releaseAt = last.t - t0 + S + lastHold
        phase.insert((0, phase.first?.1 ?? 0), at: 0)
        var n = NoteSpec()
        n.start = t0
        n.frequency = pitch
        n.cutoffMax = 3200
        n.amplitude = 0
        n.envelope = SynthEnvelope(curve: SynthCurve(gain), releaseAt: releaseAt, tau: tau)
        n.hasField = true
        n.field = SynthCurve(field)
        if partner.contains(where: { $0.1 > 0 }) {
            n.hasPartner = true
            n.partnerField = SynthCurve(partner)
            n.partnerPhase = SynthCurve(phase, smooth: false)
        }
        if segs.contains(where: \.wrong) {
            n.hasRough = true
            n.rough = SynthCurve(rough)
        }
        n.fieldGain = fieldGain
        for s in segs { n.addTick(s.t - t0) }
        n.tickAmp = tickAmp
        return n
    }

    /// The truth-table meter riser: a pure sine, low-passed at 1.2 kHz, 6.5 dB under star 1.
    static func riser(at t: Double, releaseAt: Double, tau: Double, amplitude: Double = SoundLevel.riser) -> NoteSpec {
        var n = NoteSpec()
        n.start = t
        n.frequency = SoundTuning.G3
        n.brightWeights = (0, 0)
        n.cutoffMax = 1200
        n.brightness = 1
        n.amplitude = amplitude
        n.envelope = SynthEnvelope(curve: SynthCurve([(0, 0), (0.05, 1)]), releaseAt: releaseAt, tau: tau)
        return n
    }

    /// Near-miss reference: exactly G4, pure, fades in over the crawl, held after the stop.
    static func nearMissReference(start: Double, fadeIn: Double, hold: Double, amplitude: Double) -> NoteSpec {
        var n = NoteSpec()
        n.start = start
        n.frequency = SoundTuning.G4
        n.brightWeights = (0, 0)
        n.cutoffMax = 1200
        n.amplitude = amplitude
        n.envelope = SynthEnvelope(curve: SynthCurve([(0, 0), (fadeIn, 1)]), releaseAt: fadeIn + hold, tau: 0.05)
        return n
    }

    /// starLand(i): struck, decays to −6 dB, sustains until the verdict, then releases.
    static func starLand(_ i: Int, at t: Double, verdict: Double, tau: Double = 0.08, inheritFrom: UInt8 = 0) -> NoteSpec {
        let k = min(max(i, 0), 2)
        var n = NoteSpec()
        n.start = t
        n.frequency = SoundTuning.starPitch[k]
        n.amplitude = SoundLevel.star[k]
        n.envelope = .struck(releaseAt: max(0.16, verdict - t), tau: tau)
        n.inheritPhaseFrom = inheritFrom
        return n
    }

    /// The verdict tone used without a meter (skip, re-check, Reduce Motion, VoiceOver):
    /// pass = the earned chord struck at once; fail = one soft unresolved tone at the stop pitch.
    static func verdictTone(stars: Int, failPitch: Double, at t: Double, tau: Double,
                            gainDB: Double = SoundLevel.verdictToneDB) -> SoundScore {
        if stars > 0 {
            return SoundScore(notes: (0..<min(3, stars)).map { i in
                var n = NoteSpec()
                n.start = t
                n.frequency = SoundTuning.starPitch[i]
                n.amplitude = SoundLevel.star[i] * SynthMath.dB(gainDB)
                n.envelope = .struck(attack: 0.006, sustain: 0.5, decay: 0.08, releaseAt: 0.09, tau: tau)
                return n
            })
        }
        var n = NoteSpec()
        n.start = t
        n.frequency = failPitch
        n.brightWeights = (0, 0)
        n.cutoffMax = 1200
        n.amplitude = SoundLevel.riser * SynthMath.dB(gainDB + 3)
        n.envelope = .ahr(attack: 0.015, releaseAt: 0.10, tau: tau)
        return SoundScore(notes: [n])
    }

    // MARK: Extras (the highest one only, starting ≤ 300 ms after the verdict)

    /// A quiet C6 folded into the chord.
    static func newBest(verdict: Double, tau: Double) -> NoteSpec {
        var n = NoteSpec()
        n.start = verdict
        n.frequency = SoundTuning.C6
        n.brightWeights = (0, 0)
        n.amplitude = SoundLevel.star[2] * SynthMath.dB(-10)
        n.envelope = .ahr(attack: 0.040, releaseAt: 0.10, tau: tau)
        return n
    }

    /// The root C4 under the chord, with strong partials so laptop speakers carry it.
    static func firstSolve(verdict: Double) -> NoteSpec {
        var n = NoteSpec()
        n.start = verdict
        n.frequency = SoundTuning.C4
        n.brightWeights = (0.6, 0.3)
        n.cutoffMax = 1600
        n.amplitude = SoundLevel.star[0] * SynthMath.dB(-4)
        n.envelope = .ahr(attack: 0.030, releaseAt: 0.12, tau: 0.16)
        return n
    }

    /// One quiet E6 partial, about 400 ms.
    static func allStars(verdict: Double) -> NoteSpec {
        var n = NoteSpec()
        n.start = verdict + 0.08
        n.frequency = SoundTuning.E6
        n.brightWeights = (0, 0)
        n.amplitude = SoundLevel.star[2] * SynthMath.dB(-12)
        n.envelope = .ahr(attack: 0.060, releaseAt: 0.10, tau: 0.045)
        return n
    }

    /// The full chord strummed once, softly (C4 G4 C5 E5, 30 ms apart), 250 ms after the verdict.
    static func chapterComplete(verdict: Double) -> SoundScore {
        let pitches = [SoundTuning.C4, SoundTuning.G4, SoundTuning.C5, SoundTuning.E5]
        return SoundScore(notes: pitches.enumerated().map { k, f in
            var n = NoteSpec()
            n.start = verdict + 0.25 + 0.030 * Double(k)
            n.frequency = f
            n.brightWeights = k == 0 ? (0.6, 0.3) : (0.35, 0.12)
            n.amplitude = SoundLevel.star[0] * SynthMath.dB(-5)
            n.envelope = .struck(sustain: 0.4, decay: 0.12, releaseAt: 0.14, tau: 0.10)
            return n
        })
    }

    static func extra(_ e: SoundRevealInput.Extra, verdict: Double, chordTau: Double) -> SoundScore {
        switch e {
        case .none: return .empty
        case .newBest: return SoundScore(notes: [newBest(verdict: verdict, tau: chordTau)])
        case .firstSolve: return SoundScore(notes: [firstSolve(verdict: verdict)])
        case .allStars: return SoundScore(notes: [allStars(verdict: verdict)])
        case .chapterComplete: return chapterComplete(verdict: verdict)
        }
    }

    // MARK: Single tones

    /// Invalid design: a short muted knock on C4 with strong partials.
    static func invalidDesign(at t: Double = 0) -> SoundScore {
        var n = NoteSpec()
        n.start = t
        n.frequency = SoundTuning.C4
        n.brightWeights = (0.6, 0.3)
        n.cutoffMax = 1400
        n.amplitude = SoundLevel.star[0]
        n.envelope = .ahr(attack: 0.003, releaseAt: 0.003, tau: 0.045)
        return SoundScore(notes: [n])
    }

    /// Simulator, opt-in: one soft struck C5 when a long final solve finishes.
    static func finalSolveDone(at t: Double = 0) -> SoundScore {
        var n = NoteSpec()
        n.start = t
        n.frequency = SoundTuning.C5
        n.amplitude = SoundLevel.star[1] * SynthMath.dB(-3)
        n.envelope = .struck(sustain: 0.4, decay: 0.15, releaseAt: 0.16, tau: 0.12)
        return SoundScore(notes: [n])
    }

    /// Toggle tone after a Check (1.9) for one goal detector: a tap, a 25 ms glide to the case's
    /// value, a 150 ms hold and a 250 ms fade, at −6 dB; rough on a wrong row. Toggles on the same
    /// output continue one voice (legato), so a quick flick glides without a dip.
    static func toggleTone(value: Double, wrong: Bool, output: Int = 0, at t: Double = 0) -> SoundScore {
        let f = SynthMath.clamp(value, 0, 1).squareRoot()
        var n = NoteSpec()
        n.start = t
        n.frequency = SoundTuning.outputPitch(output)
        n.cutoffMax = 3200
        n.amplitude = 0
        n.envelope = SynthEnvelope(curve: SynthCurve([(0, 0), (0.020, 1), (0.15, 1), (0.40, 0)]), releaseAt: 0.45, tau: 0.03)
        n.hasField = true
        n.field = SynthCurve([(0, f), (0.025, f)])
        n.fieldGain = 0.5
        // Always present, so a legato take-over can carry the previous roughness level.
        n.hasRough = true
        n.rough = wrong ? SynthCurve([(0, 0), (0.02, 1), (0.40, 1)]) : SynthCurve([(0, 0), (0.02, 0)])
        n.addTick(0)
        n.tickAmp = SoundLevel.tick * SynthMath.dB(SoundLevel.toggleDB)
        n.legatoKey = UInt8(1 + min(max(output, 0), 200))
        return SoundScore(notes: [n])
    }

    // MARK: The meter

    /// Riser (or the single-case voice), star tones, near-miss reference and the extra.
    static func meterScore(_ m: SoundRevealInput.Meter, stars: Int, verdict: Double, extra: SoundRevealInput.Extra,
                           riserVoice: NoteSpec? = nil, ids: inout UInt8) -> SoundScore {
        var s = SoundScore()
        let isDelta = m.isDelta
        var pitch = SoundMeterMath.pitchCurve(m, stars: stars)
        let starTimes = isDelta ? [] : (m.starTimes.count >= stars ? m.starTimes : SoundMeterMath.starCrossingTimes(m, stars: stars))
        if isDelta {
            pitch.fromPitch = SoundMeterMath.restPitch(meter: m, x: m.fromX, stars: m.previousStars)
        } else if stars > 0, let last = starTimes.prefix(stars).last {
            pitch.lockAt = last - m.start
            pitch.lockPitch = SoundTuning.starPitch[min(stars, 3) - 1]
        }
        var riser = riserVoice ?? Self.riser(at: m.start, releaseAt: m.duration, tau: 0.06)
        riser.meter = pitch
        ids &+= 1
        riser.id = ids
        let lastLand = starTimes.prefix(stars).last
        let D = m.duration
        if m.curve == .nearMiss {
            riser.envelope.releaseAt = D + 0.20
            riser.envelope.tau = 0.05
            // The reference sits at the riser's fundamental level, so the beat is deep but not a gate.
            var refAmp = riser.amplitude * SynthMath.dB(-1)
            if riser.hasField {
                let f = riser.field.lastValue
                let v = f * f, b = SynthFieldMap.brightness(v)
                refAmp = SynthFieldMap.amplitude(v) / (1 + riser.brightWeights.0 * b + riser.brightWeights.1 * b) * SynthMath.dB(-1)
            }
            s.append(nearMissReference(start: m.start + D - 0.15, fadeIn: 0.15, hold: 0.20, amplitude: refAmp))
        } else if stars > 0, let tl = lastLand, !isDelta {
            riser.envelope.releaseAt = tl - m.start + 0.03
            riser.envelope.tau = 0.04
        } else if stars > 0 {
            riser.envelope.releaseAt = D + 0.02
            riser.envelope.tau = 0.04
        } else {
            riser.envelope.releaseAt = D + 0.12
            riser.envelope.tau = 0.06
        }
        s.append(riser)
        let tau = extra == .firstSolve ? 0.16 : 0.08
        let earned = min(max(stars, 0), 3)
        if !isDelta {
            for i in 0..<min(earned, starTimes.count) {
                s.append(starLand(i, at: starTimes[i], verdict: verdict, tau: tau, inheritFrom: i == earned - 1 ? riser.id : 0))
            }
        } else if earned > 0 {
            // Delta: the earned chord, struck as the riser comes to rest on its top note.
            for i in 0..<earned {
                var n = starLand(i, at: m.start + D, verdict: verdict, tau: tau, inheritFrom: i == earned - 1 ? riser.id : 0)
                n.amplitude *= SynthMath.dB(SoundLevel.verdictToneDB)
                s.append(n)
            }
        }
        s.append(contentsOf: Self.extra(extra, verdict: verdict, chordTau: tau))
        return s
    }

    // MARK: Reveals

    /// The whole sound of a reveal.
    static func reveal(_ input: SoundRevealInput) -> SoundScore {
        let stars = input.passed ? min(max(input.stars, 0), 3) : 0
        switch input.kind {
        case .instant:
            return .empty
        case .recheck:
            return verdictTone(stars: stars, failPitch: failPitch(input), at: 0.06, tau: 0.058)
        case .reduced:
            return verdictTone(stars: stars, failPitch: failPitch(input), at: 0.36, tau: 0.05)
        case .voiceOver:
            return verdictTone(stars: stars, failPitch: failPitch(input), at: 0, tau: 0.05, gainDB: SoundLevel.voiceOverDB)
        case .full, .delta:
            break
        }
        var ids: UInt8 = 0
        var score = SoundScore()
        if let single = input.single, let m = input.meter {
            score.append(contentsOf: singleCase(single, meter: m, stars: stars, input: input, ids: &ids))
            return score
        }
        let outputs = input.cases.map(\.outputs.count).max() ?? 0
        let isDelta = input.kind == .delta
        let S = max(0.02, SynthMath.finite(input.caseStep))
        for j in 0..<outputs {
            let segs: [CaseSegment] = input.cases.compactMap { c in
                guard j < c.outputs.count else { return nil }
                let o = c.outputs[j]
                return CaseSegment(t: c.start, value: SynthMath.finite(o.value), interference: isDelta ? nil : o.interference,
                                   wrong: o.wrong, from: isDelta ? (o.previous ?? o.value) : nil)
            }
            let voice = detectorVoice(segs, step: S, pitch: SoundTuning.outputPitch(j),
                                      deltaGlide: isDelta ? min(0.10, S - 0.03) : 0.12,
                                      tickAmp: j == 0 ? SoundLevel.tick : 0)
            if let voice { score.append(voice) }
        }
        if let m = input.meter {
            score.append(contentsOf: meterScore(m, stars: stars, verdict: input.verdictAt, extra: input.extra, ids: &ids))
        }
        return score
    }

    /// Single-case goals (1.4): one voice is both the reading and the meter. Its pitch is the
    /// meter; its loudness and brightness are the counted field (maximize and target: rising;
    /// minimize: the reference falling to the residual; target: panned by the split). A fail
    /// that is not a near miss stops with the "off" roughness.
    static func singleCase(_ single: SoundRevealInput.SingleCase, meter m: SoundRevealInput.Meter, stars: Int,
                           input: SoundRevealInput, ids: inout UInt8) -> SoundScore {
        let D = m.duration
        let to = SynthMath.finite(single.fieldValue)
        let from: Double
        if input.kind == .delta, let p = single.previousFieldValue {
            from = SynthMath.finite(p)
        } else {
            from = single.kind == .minimize ? 1 : 0
        }
        var field: [(Double, Double)] = []
        var s = 0.0
        while s <= D + 1e-9 {
            let u = SynthMath.easeOutCubic(s / D)
            field.append((s, SynthMath.clamp(from + (to - from) * u, 0, 1).squareRoot()))
            s += 0.02
        }
        var voice = NoteSpec()
        voice.start = m.start
        voice.frequency = SoundTuning.G3
        voice.brightWeights = (0.35, 0.12)
        voice.cutoffMax = 2400
        voice.amplitude = 0
        voice.envelope = SynthEnvelope(curve: SynthCurve([(0, 0), (0.05, 1)]), releaseAt: D, tau: 0.06)
        voice.hasField = true
        voice.field = SynthCurve(field)
        voice.addTick(0)
        voice.tickAmp = SoundLevel.tick
        if single.kind == .target {
            voice.pan = SynthCurve([(0, 0), (D, SynthMath.clamp(single.pan, -0.8, 0.8))])
        }
        if !input.passed && m.curve != .nearMiss {
            voice.hasRough = true
            voice.rough = SynthCurve([(0, 0), (D - 0.05, 0), (D + 0.02, 1)])
        }
        return meterScore(m, stars: stars, verdict: input.verdictAt, extra: input.extra, riserVoice: voice, ids: &ids)
    }

    /// The tone a skipper hears: play it right after `fadeOutAll(0.06)`. It starts at 60 ms,
    /// when the fade has finished: the earned chord, or one unresolved tone at the stop pitch.
    static func skipTone(for input: SoundRevealInput) -> SoundScore {
        if input.kind == .instant { return .empty }
        let stars = input.passed ? min(max(input.stars, 0), 3) : 0
        return verdictTone(stars: stars, failPitch: failPitch(input), at: 0.060, tau: 0.05)
    }

    /// Where an unresolved verdict tone sits: the meter's stop pitch.
    static func failPitch(_ input: SoundRevealInput) -> Double {
        guard let m = input.meter else { return SoundTuning.E4 }
        return SoundMeterMath.stopPitch(meter: m, stars: 0)
    }

    // MARK: Settings sample

    /// "Play Sample" in Settings: about 1.2 s of a real three-star reveal (XOR's last case, where
    /// the second beam cancels the first, then the meter and the chord), at the reveal level.
    static func sample() -> SoundScore {
        let track = SoundTrackMap.scoreBar(thresholds: [6, 10, 15], pass: 6, percent: false)
        let score = 17.52
        let a = 0.495, b = 0.507, both = 0.00876
        let interference = SoundInterference.infer(both: both, a: a, b: b, inputsOn: 2, otherSourceOn: false)
        let step = 0.25
        var meter = SoundRevealInput.Meter(start: step + 0.03, duration: 0.45, fromX: 0, toX: track.position(score),
                                           passX: track.position(6), starX: [6, 10, 15].map(track.position))
        meter.starTimes = SoundMeterMath.starCrossingTimes(meter, stars: 3)
        let input = SoundRevealInput(kind: .full, passed: true, stars: 3, verdictAt: meter.start + meter.duration,
                                     cases: [.init(start: 0, outputs: [.init(value: both, interference: interference)])],
                                     caseStep: step, meter: meter)
        return reveal(input)
    }
}
