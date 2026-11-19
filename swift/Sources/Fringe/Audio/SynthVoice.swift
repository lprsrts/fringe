import Foundation
import Synchronization

// The DSP of the puzzle sounds (design sections 2.1, 2.3, 2.6 and 4.2). No AVFoundation here:
// the offline test tool compiles this file unchanged and renders exactly what the app plays.
//
// What runs on the audio thread is `SynthRenderer.render`. It and everything it calls use only
// fixed-size storage that was allocated up front: no allocation, no locks, no class references
// and no Objective-C messages. Notes reach it through `SynthCommandRing`, a single-producer,
// single-consumer ring of 64 commands.
//
// Reference: the reviewed prototype in sound/proto/SynthVoice.swift. The arithmetic is the same;
// the differences are storage (fixed-size keyframes instead of arrays), the meter pitch being
// computed per sample instead of from 10 ms keyframes, and legato toggle voices (a new toggle
// continues the sounding voice instead of being known in advance).

// MARK: - Math

enum SynthMath {
    @inline(__always) static func finite(_ x: Double) -> Double { x.isFinite ? x : 0 }
    @inline(__always) static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        min(hi, max(lo, finite(x)))
    }
    @inline(__always) static func dB(_ x: Double) -> Double { pow(10, x / 20) }
    @inline(__always) static func toDB(_ x: Double) -> Double { x > 0 ? 20 * log10(x) : -200 }
    @inline(__always) static func easeOutCubic(_ u: Double) -> Double {
        let x = clamp(u, 0, 1)
        let r = 1 - x
        return 1 - r * r * r
    }
    @inline(__always) static func easeOutQuint(_ u: Double) -> Double {
        let x = clamp(u, 0, 1)
        let r = 1 - x
        return 1 - r * r * r * r * r
    }
}

/// The loudness and timbre map of design 2.3. The level is half the dB of the power ratio, with
/// a floor so a dim but non-zero case is still heard; the rest of the contrast is timbre.
enum SynthFieldMap {
    /// Linear peak per channel of a v = 1 field voice at the default volume (calibrated).
    static let aMax = SynthMath.dB(-25)
    /// Floor for any non-silent case, so nothing informative plays under about −46 LUFS.
    static let aFloor = SynthMath.dB(-41)
    /// Below this normalised power the voice fades to silence (the 1e-6 floor of a dark case).
    static let vSilent = 1e-4
    static let atSilent = max(aMax * pow(vSilent, 0.25), aFloor)

    @inline(__always) static func amplitude(_ vIn: Double) -> Double {
        let v = SynthMath.clamp(vIn, 0, 1)
        if v < vSilent { return atSilent * v / vSilent }
        return max(aMax * pow(v, 0.25), aFloor)
    }
    /// 0…1 from the power in dB: −3 dB → 1, −25 dB → 0.
    @inline(__always) static func brightness(_ vIn: Double) -> Double {
        let v = SynthMath.clamp(vIn, 1e-12, 1)
        return SynthMath.clamp((10 * log10(v) + 25) / 22, 0, 1)
    }
}

// MARK: - Curves

struct SynthKeyframe: Sendable {
    var t: Float
    var v: Float
}

/// A piecewise curve in fixed storage (64 keyframes). Smooth curves use raised-cosine segments,
/// so there are no corners at keyframes; others are linear. Before the first keyframe the curve
/// holds its first value, after the last its last value. An empty curve is 0.
struct SynthCurve: Sendable {
    static let capacity = 64
    var points = InlineArray<64, SynthKeyframe>(repeating: SynthKeyframe(t: 0, v: 0))
    private(set) var count = 0
    var smooth = true
    /// Set when keyframes had to be dropped because the storage was full.
    private(set) var overflowed = false

    init(smooth: Bool = true) { self.smooth = smooth }

    /// Builds a curve from (time, value) pairs. Exact repeats and the middle of three equal
    /// values are merged, which does not change the curve.
    init(_ pairs: [(Double, Double)], smooth: Bool = true) {
        self.smooth = smooth
        for (t, v) in pairs { append(t, v) }
    }

    static func constant(_ v: Double) -> SynthCurve { SynthCurve([(0, v)]) }

    mutating func append(_ tIn: Double, _ vIn: Double) {
        let k = SynthKeyframe(t: Float(SynthMath.finite(tIn)), v: Float(SynthMath.finite(vIn)))
        if count >= 1, points[count - 1].t == k.t, points[count - 1].v == k.v { return }
        if count >= 2, points[count - 2].v == k.v, points[count - 1].v == k.v, k.t >= points[count - 1].t {
            points[count - 1].t = k.t
            return
        }
        guard count < Self.capacity else { overflowed = true; return }
        points[count] = k
        count += 1
    }

    var isEmpty: Bool { count == 0 }
    var firstValue: Double { count > 0 ? Double(points[0].v) : 0 }
    var lastValue: Double { count > 0 ? Double(points[count - 1].v) : 0 }
    var lastTime: Double { count > 0 ? Double(points[count - 1].t) : 0 }

    mutating func setFirstValue(_ v: Double) {
        guard count > 0 else { return }
        points[0].v = Float(SynthMath.finite(v))
    }

    mutating func mapTimes(_ f: (Double) -> Double) {
        for i in 0..<count { points[i].t = Float(SynthMath.finite(f(Double(points[i].t)))) }
    }

    mutating func mapValues(_ f: (Double) -> Double) {
        for i in 0..<count { points[i].v = Float(SynthMath.finite(f(Double(points[i].v)))) }
    }

    /// The value at `t`, for a caller whose `t` never decreases: `cursor` remembers the segment.
    @inline(__always) func value(at t: Double, cursor: inout Int) -> Double {
        guard count > 0 else { return 0 }
        if t <= Double(points[0].t) { return Double(points[0].v) }
        var i = max(cursor, 1)
        while i < count && t > Double(points[i].t) { i += 1 }
        cursor = i
        if i >= count { return Double(points[count - 1].v) }
        let a = points[i - 1], b = points[i]
        let w = Double(b.t) - Double(a.t)
        guard w > 0 else { return Double(b.v) }
        var u = (t - Double(a.t)) / w
        if smooth { u = 0.5 - 0.5 * cos(Double.pi * u) }
        return Double(a.v) + (Double(b.v) - Double(a.v)) * u
    }

    func value(at t: Double) -> Double {
        var cursor = 1
        return value(at: t, cursor: &cursor)
    }
}

/// Gain envelope: the curve up to `releaseAt`, then an exponential release with time constant
/// `tau`; after 6.9 τ (−60 dB) a 5 ms linear ramp to exactly 0.
struct SynthEnvelope: Sendable {
    var curve: SynthCurve
    var releaseAt: Double
    var tau: Double

    /// Raised-cosine attack, hold until `releaseAt`, release.
    static func ahr(attack: Double, releaseAt: Double, tau: Double) -> SynthEnvelope {
        SynthEnvelope(curve: SynthCurve([(0, 0), (attack, 1)]), releaseAt: max(releaseAt, attack), tau: tau)
    }

    /// Struck: a fast attack, a decay to `sustain` over `decay`, hold, release.
    static func struck(attack: Double = 0.006, sustain: Double = 0.5, decay: Double = 0.15,
                       releaseAt: Double, tau: Double) -> SynthEnvelope {
        SynthEnvelope(curve: SynthCurve([(0, 0), (attack, 1), (attack + decay, sustain)]),
                      releaseAt: max(releaseAt, attack), tau: tau)
    }

    var end: Double { releaseAt + 6.9 * tau + 0.005 }

    @inline(__always) func level(_ t: Double, cursor: inout Int, releaseLevel l0: Double) -> Double {
        if t < 0 { return 0 }
        if t <= releaseAt { return curve.value(at: t, cursor: &cursor) }
        let dt = t - releaseAt
        let tail = 6.9 * tau
        if dt <= tail { return l0 * exp(-dt / tau) }
        let r = 1 - (dt - tail) / 0.005
        return r > 0 ? l0 * exp(-6.9) * r : 0
    }
}

// MARK: - Meter pitch (design 2.5), evaluated per sample

/// The meter tone's pitch over time, computed from the meter parameters so it never steps.
/// x(u) is the ScoreBar fill position at u = t / duration; the pitch is the log-piecewise map
/// through G3 (track start), G4 (pass), C5, E5 and G5 (track end).
struct SynthMeterPitch: Sendable {
    enum Fill: UInt8, Sendable {
        /// Ease-out cubic from `fromX` to `toX`.
        case ease
        /// Near miss: ease-out cubic to just under the pass line, then a 150 ms ease-out quintic
        /// crawl to `toX`, while the pitch glides into `stopPitch` (G4 − beat).
        case nearMiss
        /// Single-case goals: the fill follows the counted value through the track map.
        case value
    }

    var isActive = false
    var duration = 0.45
    var fill = Fill.ease
    var fromX = 0.0
    var toX = 0.0
    var passX = 0.0
    var trackValues = InlineArray<6, Double>(repeating: 0)
    var trackSpots = InlineArray<6, Double>(repeating: 0)
    var trackCount = 0
    var fromValue = 0.0
    var toValue = 0.0
    var anchorX = InlineArray<5, Double>(repeating: 0)
    var anchorF = InlineArray<5, Double>(repeating: 0)
    var anchorCount = 0
    var stopPitch = 392.44
    /// Delta reveals: > 0 glides from this rest pitch to `stopPitch` instead of following x.
    var fromPitch = 0.0
    /// Relative time from which the pitch holds `lockPitch` (the top earned star); < 0 = never.
    var lockAt = -1.0
    var lockPitch = 0.0

    // Derived by `prepare()`.
    private(set) var crawlFrom = 0.0
    private(set) var crawlU = 0.5
    private(set) var crawlStartX = 0.0
    private(set) var crawlStartF = 196.22

    init() {}

    /// Sets the anchors from the star positions: x = 0 → G3, pass (star 1) → G4, star 2 → C5,
    /// star 3 → E5, x = 1 → G5. Anchors that do not move right are dropped.
    mutating func setAnchors(passX: Double, starX: [Double], pitches: (g3: Double, g4: Double, c5: Double, e5: Double, g5: Double)) {
        anchorCount = 0
        anchorX[0] = 0
        anchorF[0] = pitches.g3
        anchorCount = 1
        let raw: [(Double, Double)] = [
            (starX.count > 0 ? starX[0] : passX, pitches.g4),
            (starX.count > 1 ? starX[1] : 2, pitches.c5),
            (starX.count > 2 ? starX[2] : 2, pitches.e5),
            (1, pitches.g5),
        ]
        for (xIn, f) in raw {
            let x = SynthMath.finite(xIn)
            if x > anchorX[anchorCount - 1] + 1e-9 && x <= 1 && anchorCount < 5 {
                anchorX[anchorCount] = x
                anchorF[anchorCount] = f
                anchorCount += 1
            }
        }
    }

    /// Sets the value → x map (the ScoreBar track). Values must not decrease.
    mutating func setTrack(values: [Double], spots: [Double]) {
        trackCount = min(6, min(values.count, spots.count))
        for i in 0..<trackCount {
            trackValues[i] = SynthMath.finite(values[i])
            trackSpots[i] = SynthMath.clamp(spots[i], 0, 1)
        }
    }

    mutating func prepare() {
        duration = max(0.01, SynthMath.finite(duration))
        fromX = SynthMath.clamp(fromX, 0, 1)
        toX = SynthMath.clamp(toX, 0, 1)
        passX = SynthMath.clamp(passX, 0, 1)
        crawlU = max(0.5, 1 - 0.15 / duration)
        // As the bar's near-miss curve (RevealPlanner): the crawl starts 85 % of the way to the
        // score, and at least 0.12 under the pass tick. A × puzzle's fill starts above 0.
        crawlFrom = max(fromX, min(passX - 0.12, fromX + (toX - fromX) * 0.85))
        crawlStartX = x(crawlU)
        crawlStartF = map(crawlStartX)
    }

    @inline(__always) func track(_ v: Double) -> Double {
        let n = trackCount
        guard n >= 2 else { return SynthMath.clamp(v, 0, 1) }
        if v <= trackValues[0] { return trackSpots[0] }
        for i in 0..<(n - 1) where v <= trackValues[i + 1] {
            let w = trackValues[i + 1] - trackValues[i]
            return w > 0 ? trackSpots[i] + (trackSpots[i + 1] - trackSpots[i]) * (v - trackValues[i]) / w : trackSpots[i + 1]
        }
        return trackSpots[n - 1]
    }

    /// Fill position at u ∈ [0, 1].
    @inline(__always) func x(_ u: Double) -> Double {
        switch fill {
        case .nearMiss:
            let a = crawlFrom
            return u <= crawlU
                ? fromX + (a - fromX) * SynthMath.easeOutCubic(u / crawlU)
                : a + (toX - a) * SynthMath.easeOutQuint((u - crawlU) / (1 - crawlU))
        case .value:
            return track(fromValue + (toValue - fromValue) * SynthMath.easeOutCubic(u))
        case .ease:
            return fromX + (toX - fromX) * SynthMath.easeOutCubic(u)
        }
    }

    /// The meter map M(x).
    @inline(__always) func map(_ xIn: Double) -> Double {
        guard anchorCount >= 2 else { return anchorCount == 1 ? anchorF[0] : 392.44 }
        let x = SynthMath.clamp(xIn, 0, 1)
        for i in 1..<anchorCount where x <= anchorX[i] {
            let ax = anchorX[i - 1], af = anchorF[i - 1], bx = anchorX[i], bf = anchorF[i]
            return af * pow(bf / af, (x - ax) / (bx - ax))
        }
        return anchorF[anchorCount - 1]
    }

    /// Pitch in Hz at `t` seconds after the meter starts. Before 0 it is the start pitch, after
    /// the duration it holds.
    @inline(__always) func pitch(at t: Double) -> Double {
        let s = min(max(t, 0), duration)
        let u = s / duration
        var f: Double
        if fromPitch > 0 {
            f = fromPitch * pow(stopPitch / fromPitch, SynthMath.easeOutCubic(u))
        } else if fill == .nearMiss && u > crawlU {
            let w = (x(u) - crawlStartX) / max(toX - crawlStartX, 1e-9)
            f = crawlStartF * pow(stopPitch / crawlStartF, SynthMath.clamp(w, 0, 1))
        } else {
            f = map(x(u))
        }
        if lockAt >= 0 && fromPitch <= 0 && s >= lockAt { f = lockPitch }
        return f
    }

    mutating func sanitize() {
        let pitchRange = (100.0, 1400.0)
        for i in 0..<anchorCount {
            anchorX[i] = SynthMath.clamp(anchorX[i], 0, 1)
            anchorF[i] = SynthMath.clamp(anchorF[i], pitchRange.0, pitchRange.1)
        }
        for i in 0..<trackCount {
            trackValues[i] = SynthMath.finite(trackValues[i])
            trackSpots[i] = SynthMath.clamp(trackSpots[i], 0, 1)
        }
        fromValue = SynthMath.finite(fromValue)
        toValue = SynthMath.finite(toValue)
        stopPitch = SynthMath.clamp(stopPitch, pitchRange.0, pitchRange.1)
        fromPitch = fromPitch > 0 ? SynthMath.clamp(fromPitch, pitchRange.0, pitchRange.1) : 0
        lockAt = lockAt.isFinite ? lockAt : -1
        lockPitch = SynthMath.clamp(lockPitch, pitchRange.0, pitchRange.1)
        prepare()
    }
}

// MARK: - Notes

/// One synthesized voice, scheduled at `start` seconds after the score begins. Plain old data
/// in fixed storage, so it can be copied into the render thread without touching the heap.
struct NoteSpec: Sendable {
    var start: Double = 0
    /// Fundamental in Hz when `meter` is not active.
    var frequency: Double = 261.63
    /// Meter pitch, evaluated in the render block (riser and single-case meter voice).
    var meter = SynthMeterPitch()
    /// Weights of partials 2 and 3 at full brightness (partial 1 is 1). Dim = pure sine.
    var brightWeights: (Double, Double) = (0.35, 0.12)
    /// Low-pass cutoff at full brightness; the dim end is 600 Hz.
    var cutoffMax: Double = 3000
    /// Brightness 0…1 of a voice without a field.
    var brightness: Double = 1
    /// Linear peak per channel at centre and the default volume, for a voice without a field.
    var amplitude: Double = 0
    var envelope = SynthEnvelope(curve: SynthCurve([(0, 0), (0.003, 1)]), releaseAt: 0.003, tau: 0.05)
    /// Field voice: the physical field amplitude sqrt(P) over time, mapped by SynthFieldMap.
    var hasField = false
    var field = SynthCurve()
    /// Interference partner: a second field amplitude at relative phase `partnerPhase` (rad).
    var hasPartner = false
    var partnerField = SynthCurve()
    var partnerPhase = SynthCurve(smooth: false)
    /// Multiplies the mapped field amplitude (toggle tones: −6 dB).
    var fieldGain: Double = 1
    /// 0…1 level of the detuned roughness copy ("off").
    var hasRough = false
    var rough = SynthCurve()
    var detune: Double = 6.5
    var roughLevel: Double = SynthMath.dB(-8)
    /// Shutter taps on the voice's own oscillator, in seconds from the note start (ascending).
    var ticks = InlineArray<16, Float>(repeating: 0)
    var tickCount = 0
    var tickAmp: Double = 0
    var pan = SynthCurve.constant(0)
    /// Identifies the note inside its score (0 = none) for phase inheritance.
    var id: UInt8 = 0
    /// Takes the fundamental phase of the sounding note with this id in the same score.
    var inheritPhaseFrom: UInt8 = 0
    /// Non-zero: continues a sounding voice with the same key (toggle tones), taking over its
    /// phase, filter, level, field and roughness, so repeated toggles glide on one voice.
    var legatoKey: UInt8 = 0
    /// Set by the queue: which `play` call the note came from.
    var batch: UInt32 = 0

    mutating func addTick(_ t: Double) {
        guard tickCount < 16 else { return }
        ticks[tickCount] = Float(SynthMath.finite(t))
        tickCount += 1
    }

    var end: Double { start + envelope.end }

    /// The clamps of design 2.6. Every note passes here before it reaches the render thread.
    func sanitized() -> NoteSpec {
        var n = self
        // Bounded so the sample offsets the render thread computes always fit an Int64.
        n.start = min(max(0, SynthMath.finite(n.start)), 60)
        n.frequency = SynthMath.clamp(n.frequency, 100, 1400)
        if n.meter.isActive { n.meter.sanitize() }
        n.pan.mapValues { SynthMath.clamp($0, -0.8, 0.8) }
        n.cutoffMax = SynthMath.clamp(n.cutoffMax, 600, 5000)
        n.brightness = SynthMath.clamp(n.brightness, 0, 1)
        n.brightWeights = (SynthMath.clamp(n.brightWeights.0, 0, 1), SynthMath.clamp(n.brightWeights.1, 0, 1))
        n.detune = SynthMath.clamp(n.detune, 0.8, 8)
        n.roughLevel = SynthMath.clamp(n.roughLevel, 0, 1)
        let cap = SynthMath.dB(-14)
        n.amplitude = SynthMath.clamp(n.amplitude, 0, cap)
        n.tickAmp = SynthMath.clamp(n.tickAmp, 0, cap)
        n.fieldGain = SynthMath.clamp(n.fieldGain, 0, 1)
        n.field.mapValues { SynthMath.clamp($0, 0, 1) }
        n.partnerField.mapValues { SynthMath.clamp($0, 0, 1) }
        n.rough.mapValues { SynthMath.clamp($0, 0, 1) }
        for i in 0..<n.tickCount where !Double(n.ticks[i]).isFinite { n.ticks[i] = 0 }
        if n.envelope.curve.count >= 2, n.envelope.curve.points[0].v == 0, n.envelope.curve.points[1].t < 0.003 {
            n.envelope.curve.points[1].t = 0.003
        }
        n.envelope.curve.mapValues { SynthMath.clamp($0, 0, 1) }
        n.envelope.tau = SynthMath.clamp(SynthMath.finite(n.envelope.tau), 0.010, 10)
        n.envelope.releaseAt = min(max(0, SynthMath.finite(n.envelope.releaseAt)), 30)
        return n
    }
}

// MARK: - Voice state

/// TPT state-variable low-pass (Simper), Q = 0.707.
struct SynthLowPass: Sendable {
    var ic1 = 0.0, ic2 = 0.0
    var a1 = 0.0, a2 = 0.0, a3 = 0.0

    @inline(__always) mutating func set(cutoff fc: Double, sampleRate fs: Double) {
        let g = tan(Double.pi * min(fc, 0.45 * fs) / fs)
        let k = 1.41421356
        a1 = 1 / (1 + g * (g + k))
        a2 = g * a1
        a3 = g * a2
    }

    @inline(__always) mutating func process(_ v0: Double) -> Double {
        let v3 = v0 - ic2
        let v1 = a1 * ic1 + a2 * v3
        let v2 = ic2 + a2 * ic1 + a3 * v3
        ic1 = 2 * v1 - ic1
        ic2 = 2 * v2 - ic2
        return v2
    }
}

struct SynthCursors: Sendable {
    var gain = 1, field = 1, partner = 1, phase = 1, rough = 1, pan = 1, tick = 0
}

struct SynthVoiceState: Sendable {
    var isActive = false
    var note = NoteSpec()
    var theta = 0.0
    var thetaD = 0.0
    var filter = SynthLowPass()
    var startSample: Int64 = 0
    var endSample: Int64 = 0
    /// Stolen: fades out over 10 ms from this sample (−1 = not stolen).
    var stealFrom: Int64 = -1
    /// Faded out by `fadeOutAll` from this sample over `killSamples` (−1 = not killed).
    var killFrom: Int64 = -1
    var killSamples: Int64 = 1
    var releaseLevel = 0.0
    var cursors = SynthCursors()
    /// Last computed values, read when a legato note takes the voice over.
    var lastField = 0.0
    var lastGain = 0.0
    var lastRough = 0.0

    var isLive: Bool { isActive && stealFrom < 0 }
}

// MARK: - Render statistics

struct SynthStats: Sendable {
    var preLimiterPeak = 0.0
    var maxGainReductionDB = 0.0
    var maxVoices = 0
    var steals = 0
    var notes = 0
    var dropped = 0
}

// MARK: - The voice bank and bus

/// A preallocated bank of 12 voices (plus 12 slots for stolen voices fading out), a pool of
/// 64 scheduled notes, and the bus: DC blocker, a lookahead soft-knee limiter and the −6 dBFS
/// safety clamp. Noncopyable: it owns its storage.
struct SynthBank: ~Copyable {
    static let maxVoices = 12
    static let slotCount = 24
    static let pendingCapacity = 64
    static let lookaheadCapacity = 512

    let sampleRate: Double
    private let voices: UnsafeMutablePointer<SynthVoiceState>
    private let pending: UnsafeMutablePointer<NoteSpec>
    private let pendingStart: UnsafeMutablePointer<Int64>
    private let pendingUsed: UnsafeMutablePointer<Bool>
    private let limL: UnsafeMutablePointer<Double>
    private let limR: UnsafeMutablePointer<Double>
    private let limPeak: UnsafeMutablePointer<Double>
    private let look: Int
    private var limIndex = 0
    private var limGain = 1.0
    private let limAttack: Double
    private let limRelease: Double
    private var dcxL = 0.0, dcyL = 0.0, dcxR = 0.0, dcyR = 0.0
    private let dcR: Double
    private var nextPendingStart = Int64.max
    private(set) var pendingCount = 0
    private(set) var activeCount = 0
    /// The index of the next sample to render.
    private(set) var sampleTime: Int64 = 0
    /// The master gain the bus moves towards (1 = the calibrated default volume).
    var masterGain = 1.0
    private var currentMaster = 1.0
    private let masterSmoothing: Double
    var stats = SynthStats()

    init(sampleRate fsIn: Double) {
        let fs = fsIn.isFinite && fsIn >= 8000 ? fsIn : 48000
        sampleRate = fs
        voices = .allocate(capacity: Self.slotCount)
        voices.initialize(repeating: SynthVoiceState(), count: Self.slotCount)
        pending = .allocate(capacity: Self.pendingCapacity)
        pending.initialize(repeating: NoteSpec(), count: Self.pendingCapacity)
        pendingStart = .allocate(capacity: Self.pendingCapacity)
        pendingStart.initialize(repeating: 0, count: Self.pendingCapacity)
        pendingUsed = .allocate(capacity: Self.pendingCapacity)
        pendingUsed.initialize(repeating: false, count: Self.pendingCapacity)
        look = max(1, min(Self.lookaheadCapacity, Int(0.002 * fs)))
        limL = .allocate(capacity: Self.lookaheadCapacity)
        limL.initialize(repeating: 0, count: Self.lookaheadCapacity)
        limR = .allocate(capacity: Self.lookaheadCapacity)
        limR.initialize(repeating: 0, count: Self.lookaheadCapacity)
        limPeak = .allocate(capacity: Self.lookaheadCapacity)
        limPeak.initialize(repeating: 0, count: Self.lookaheadCapacity)
        limAttack = 1 - exp(-1 / (0.0005 * fs))
        limRelease = 1 - exp(-1 / (0.080 * fs))
        dcR = 1 - 2 * Double.pi * 5 / fs
        masterSmoothing = 1 - exp(-1 / (0.020 * fs))
    }

    deinit {
        voices.deinitialize(count: Self.slotCount)
        voices.deallocate()
        pending.deinitialize(count: Self.pendingCapacity)
        pending.deallocate()
        pendingStart.deallocate()
        pendingUsed.deallocate()
        limL.deallocate()
        limR.deallocate()
        limPeak.deallocate()
    }

    /// Clears every voice, scheduled note and filter state. Not for the render thread while it runs.
    mutating func reset() {
        for k in 0..<Self.slotCount { voices[k].isActive = false }
        for k in 0..<Self.pendingCapacity { pendingUsed[k] = false }
        for k in 0..<Self.lookaheadCapacity { limL[k] = 0; limR[k] = 0; limPeak[k] = 0 }
        pendingCount = 0
        activeCount = 0
        nextPendingStart = .max
        limGain = 1
        limIndex = 0
        dcxL = 0; dcyL = 0; dcxR = 0; dcyR = 0
        currentMaster = masterGain
    }

    /// Sets the master gain at once (no 20 ms smoothing), for offline renders.
    mutating func jumpMasterGain(_ g: Double) {
        masterGain = g
        currentMaster = g
    }

    /// Schedules a sanitized note to start at an absolute sample. False if the pool is full.
    @discardableResult
    mutating func schedule(_ note: borrowing NoteSpec, atSample start: Int64) -> Bool {
        for k in 0..<Self.pendingCapacity where !pendingUsed[k] {
            pending[k] = copy note
            pendingStart[k] = max(start, sampleTime)
            pendingUsed[k] = true
            pendingCount += 1
            nextPendingStart = min(nextPendingStart, pendingStart[k])
            return true
        }
        stats.dropped += 1
        return false
    }

    /// Fades every sounding voice out over `seconds` from now and drops every scheduled note.
    mutating func fadeOutAll(seconds: Double) {
        let n = max(1, Int64(SynthMath.clamp(seconds, 0.003, 2) * sampleRate))
        for k in 0..<Self.slotCount where voices[k].isActive {
            if voices[k].killFrom < 0 {
                voices[k].killFrom = sampleTime
                voices[k].killSamples = n
            }
        }
        for k in 0..<Self.pendingCapacity { pendingUsed[k] = false }
        pendingCount = 0
        nextPendingStart = .max
    }

    // MARK: Starting notes

    private mutating func startDueNotes(at i: Int64) {
        guard i >= nextPendingStart else { return }
        var next = Int64.max
        // Start in time order so phase inheritance finds its source.
        while true {
            var pick = -1
            for k in 0..<Self.pendingCapacity where pendingUsed[k] && pendingStart[k] <= i {
                if pick < 0 || pendingStart[k] < pendingStart[pick] { pick = k }
            }
            if pick < 0 { break }
            pendingUsed[pick] = false
            pendingCount -= 1
            startVoice(fromPending: pick, at: i)
        }
        for k in 0..<Self.pendingCapacity where pendingUsed[k] { next = min(next, pendingStart[k]) }
        nextPendingStart = next
    }

    private mutating func startVoice(fromPending p: Int, at i: Int64) {
        stats.notes += 1
        // A legato note (toggle tones) takes over the sounding voice with the same key: same
        // oscillator, filter and level, so it glides from where that voice is.
        var legatoSlot = -1
        let key = pending[p].legatoKey
        if key != 0 {
            for k in 0..<Self.slotCount where voices[k].isLive && voices[k].killFrom < 0 && voices[k].note.legatoKey == key {
                legatoSlot = k
                break
            }
        }
        var slot = legatoSlot
        if slot < 0 {
            // Voice limit: the oldest voice in release (else the oldest) is stolen with a 10 ms fade.
            var live = 0
            for k in 0..<Self.slotCount where voices[k].isLive { live += 1 }
            if live >= Self.maxVoices {
                var victim = -1, victimInRelease = false
                for k in 0..<Self.slotCount where voices[k].isLive {
                    let lt = Double(i - voices[k].startSample) / sampleRate
                    let inRelease = lt > voices[k].note.envelope.releaseAt
                    if victim < 0 || (inRelease && !victimInRelease)
                        || (inRelease == victimInRelease && voices[k].startSample < voices[victim].startSample) {
                        victim = k
                        victimInRelease = inRelease
                    }
                }
                if victim >= 0 {
                    voices[victim].stealFrom = i
                    stats.steals += 1
                }
            }
            for k in 0..<Self.slotCount where !voices[k].isActive { slot = k; break }
            if slot < 0 {
                // Every slot holds a stolen voice still fading: end the one that started fading first.
                var oldest = 0
                for k in 0..<Self.slotCount where voices[k].stealFrom >= 0 && voices[k].stealFrom < voices[oldest].stealFrom {
                    oldest = k
                }
                slot = oldest
            }
        }

        let v = voices + slot
        let carried = legatoSlot >= 0
        let theta = carried ? v.pointee.theta : 0
        let thetaD = carried ? v.pointee.thetaD : 0
        let filter = carried ? v.pointee.filter : SynthLowPass()
        let lastGain = v.pointee.lastGain, lastField = v.pointee.lastField, lastRough = v.pointee.lastRough
        // Taps of the old note that are still ringing carry over, so the take-over does not cut them.
        var ringing = InlineArray<16, Float>(repeating: 0)
        var ringingCount = 0
        if carried {
            let elapsed = Double(i - v.pointee.startSample) / sampleRate
            for k in 0..<v.pointee.note.tickCount {
                let d = elapsed - Double(v.pointee.note.ticks[k])
                if d >= 0 && d < 0.12 && ringingCount < 16 {
                    ringing[ringingCount] = Float(-d)
                    ringingCount += 1
                }
            }
        }
        v.pointee.note = pending[p]
        if ringingCount > 0 {
            let own = v.pointee.note.ticks
            let ownCount = v.pointee.note.tickCount
            v.pointee.note.tickCount = 0
            for k in 0..<ringingCount { v.pointee.note.addTick(Double(ringing[k])) }
            for k in 0..<ownCount { v.pointee.note.addTick(Double(own[k])) }
        }
        v.pointee.isActive = true
        v.pointee.theta = theta
        v.pointee.thetaD = thetaD
        v.pointee.filter = filter
        v.pointee.startSample = i
        v.pointee.stealFrom = -1
        v.pointee.killFrom = -1
        v.pointee.killSamples = 1
        v.pointee.cursors = SynthCursors()
        if carried {
            v.pointee.note.envelope.curve.setFirstValue(lastGain)
            if v.pointee.note.hasField { v.pointee.note.field.setFirstValue(lastField) }
            if v.pointee.note.hasRough { v.pointee.note.rough.setFirstValue(lastRough) }
        }
        v.pointee.lastField = 0
        v.pointee.lastGain = 0
        v.pointee.lastRough = 0

        let inherit = v.pointee.note.inheritPhaseFrom
        if inherit != 0 && !carried {
            var src = -1
            for k in 0..<Self.slotCount where k != slot && voices[k].isLive
                && voices[k].note.batch == v.pointee.note.batch && voices[k].note.id == inherit {
                if src < 0 || voices[k].startSample > voices[src].startSample { src = k }
            }
            if src >= 0 { v.pointee.theta = voices[src].theta }
        }

        let env = v.pointee.note.envelope
        v.pointee.releaseLevel = env.curve.value(at: env.releaseAt)
        v.pointee.endSample = i + Int64(env.end * sampleRate) + 1
    }

    // MARK: Rendering

    /// Renders `frames` samples into two channel buffers (overwrites them).
    mutating func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        let fs = sampleRate
        let twoPi = 2 * Double.pi
        let safety = SynthMath.dB(-6)
        for n in 0..<frames {
            let i = sampleTime
            startDueNotes(at: i)
            var sl = 0.0, sr = 0.0
            var count = 0
            for k in 0..<Self.slotCount where voices[k].isActive {
                if renderVoice(voices + k, at: i, fs: fs, twoPi: twoPi, left: &sl, right: &sr) {
                    count += 1
                } else {
                    voices[k].isActive = false
                }
            }
            activeCount = count
            if count > stats.maxVoices { stats.maxVoices = count }

            currentMaster += (masterGain - currentMaster) * masterSmoothing
            var ol = sl * currentMaster, or = sr * currentMaster
            let yl = ol - dcxL + dcR * dcyL
            dcxL = ol; dcyL = yl; ol = yl
            let yr = or - dcxR + dcR * dcyR
            dcxR = or; dcyR = yr; or = yr
            let p = max(abs(ol), abs(or))
            if p > stats.preLimiterPeak { stats.preLimiterPeak = p }
            (ol, or) = limit(ol, or)
            let gr = -SynthMath.toDB(limGain)
            if gr > stats.maxGainReductionDB { stats.maxGainReductionDB = gr }
            // Safety clamp at −6 dBFS: never reached unless the limiter is bypassed by a bug.
            ol = max(-safety, min(safety, ol))
            or = max(-safety, min(safety, or))
            left[n] = Float(ol)
            right[n] = Float(or)
            sampleTime += 1
        }
    }

    /// Lookahead soft-knee limiter: 2 ms lookahead, 0.5 ms attack, 80 ms release. Static curve:
    /// identity below −11 dBFS, a 4 dB quadratic knee, flat at −9 dBFS.
    @inline(__always) private mutating func limit(_ l: Double, _ r: Double) -> (Double, Double) {
        limPeak[limIndex] = max(abs(l), abs(r))
        var windowPeak = 0.0
        for k in 0..<look where limPeak[k] > windowPeak { windowPeak = limPeak[k] }
        var target = 1.0
        if windowPeak > 0 {
            let x = SynthMath.toDB(windowPeak)
            let t = -9.0, w = 4.0
            let y: Double
            if x < t - w / 2 { y = x } else if x > t + w / 2 { y = t } else {
                let d = x - t + w / 2
                y = x - d * d / (2 * w)
            }
            target = SynthMath.dB(y - x)
        }
        limGain += (target - limGain) * (target < limGain ? limAttack : limRelease)
        let ol = limL[limIndex] * limGain, or = limR[limIndex] * limGain
        limL[limIndex] = l
        limR[limIndex] = r
        limIndex += 1
        if limIndex >= look { limIndex = 0 }
        return (ol, or)
    }

    /// One sample of one voice, added to the bus. False when the voice has ended.
    @inline(__always) private func renderVoice(_ v: UnsafeMutablePointer<SynthVoiceState>, at i: Int64, fs: Double,
                                               twoPi: Double, left sl: inout Double, right sr: inout Double) -> Bool {
        if i >= v.pointee.endSample { return false }
        let lt = Double(i - v.pointee.startSample) / fs
        var gain = 1.0
        if v.pointee.killFrom >= 0 {
            gain = 1 - Double(i - v.pointee.killFrom) / Double(v.pointee.killSamples)
            if gain <= 0 { return false }
        }
        if v.pointee.stealFrom >= 0 {
            let d = Double(i - v.pointee.stealFrom) / fs
            if d >= 0.010 { return false }
            gain *= max(0, 1 - d / 0.010)
        }
        let envLevel = v.pointee.note.envelope.level(lt, cursor: &v.pointee.cursors.gain, releaseLevel: v.pointee.releaseLevel)
        v.pointee.lastGain = envLevel
        let e = envLevel * gain

        var amp = v.pointee.note.amplitude
        var b = v.pointee.note.brightness
        var arg = 0.0
        if v.pointee.note.hasField {
            var re = v.pointee.note.field.value(at: lt, cursor: &v.pointee.cursors.field)
            v.pointee.lastField = re
            var im = 0.0
            if v.pointee.note.hasPartner {
                let p = v.pointee.note.partnerField.value(at: lt, cursor: &v.pointee.cursors.partner)
                let phi = v.pointee.note.partnerPhase.value(at: lt, cursor: &v.pointee.cursors.phase)
                re += p * cos(phi)
                im += p * sin(phi)
            }
            let v2 = re * re + im * im
            amp = SynthFieldMap.amplitude(v2) * v.pointee.note.fieldGain
            b = SynthFieldMap.brightness(v2)
            arg = v2 > 1e-14 ? atan2(im, re) : 0
        }

        let f = v.pointee.note.meter.isActive
            ? min(1400, max(100, v.pointee.note.meter.pitch(at: lt)))
            : v.pointee.note.frequency
        v.pointee.theta += twoPi * f / fs
        if v.pointee.theta > twoPi { v.pointee.theta -= twoPi }

        var w2 = v.pointee.note.brightWeights.0 * b
        var w3 = v.pointee.note.brightWeights.1 * b
        if 2 * f > 5000 { w2 = 0 }
        if 3 * f > 5000 { w3 = 0 }
        if (i - v.pointee.startSample) % 16 == 0 {
            let fcut = 600 + (v.pointee.note.cutoffMax - 600) * b
            v.pointee.filter.set(cutoff: fcut, sampleRate: fs)
        }
        let ph = v.pointee.theta + arg
        let norm = 1 + w2 + w3
        var s = (sin(ph) + w2 * sin(2 * ph) + w3 * sin(3 * ph)) / norm * amp * e
        if v.pointee.note.hasRough {
            let rl = v.pointee.note.rough.value(at: lt, cursor: &v.pointee.cursors.rough)
            v.pointee.lastRough = rl
            if rl > 0 {
                v.pointee.thetaD += twoPi * (f + v.pointee.note.detune) / fs
                if v.pointee.thetaD > twoPi { v.pointee.thetaD -= twoPi }
                s += rl * v.pointee.note.roughLevel * amp * e * sin(v.pointee.thetaD + arg) / norm
            }
        }
        s = v.pointee.filter.process(s)

        // Shutter taps: partials 1, 0.5, 0.25 on the voice's own phase; 3 ms raised-cosine
        // attack, τ 15 ms, cut over 100–120 ms.
        let tickAmp = v.pointee.note.tickAmp
        let tickCount = v.pointee.note.tickCount
        if tickAmp > 0 && tickCount > 0 {
            var c = v.pointee.cursors.tick
            while c < tickCount && lt - Double(v.pointee.note.ticks[c]) > 0.12 { c += 1 }
            v.pointee.cursors.tick = c
            var p = 0.0
            var k = c
            while k < tickCount {
                let d = lt - Double(v.pointee.note.ticks[k])
                if d < 0 { break }
                if d <= 0.12 {
                    let a = d < 0.003 ? 0.5 - 0.5 * cos(Double.pi * d / 0.003) : exp(-(d - 0.003) / 0.015)
                    let fade = d > 0.10 ? max(0, 1 - (d - 0.10) / 0.02) : 1
                    p += a * fade
                }
                k += 1
            }
            if p > 0 {
                s += tickAmp * gain * p * (sin(ph) + 0.5 * sin(2 * ph) + 0.25 * sin(3 * ph)) / 1.75
            }
        }

        // Equal-power pan normalised to 0 dB at centre.
        let panValue = v.pointee.note.pan.value(at: lt, cursor: &v.pointee.cursors.pan)
        let a = (panValue + 1) * Double.pi / 4
        sl += s * cos(a) * 1.41421356
        sr += s * sin(a) * 1.41421356
        return true
    }
}

// MARK: - Main thread → render thread

/// A command for the render thread.
struct SynthCommand: Sendable {
    enum Op: UInt8, Sendable { case play, fadeOutAll }
    var op = Op.play
    var note = NoteSpec()
    /// fadeOutAll: the fade length.
    var seconds = 0.06
}

/// Single-producer, single-consumer ring of 64 commands. The main thread pushes, the render
/// thread pops. Indices only grow; the slot is the index modulo the capacity.
struct SynthCommandRing: @unchecked Sendable {
    static let capacity = 64
    let slots: UnsafeMutablePointer<SynthCommand>
    let head: UnsafeMutablePointer<Atomic<Int>>
    let tail: UnsafeMutablePointer<Atomic<Int>>

    static func allocate() -> SynthCommandRing {
        let slots = UnsafeMutablePointer<SynthCommand>.allocate(capacity: capacity)
        slots.initialize(repeating: SynthCommand(), count: capacity)
        let head = UnsafeMutablePointer<Atomic<Int>>.allocate(capacity: 1)
        head.initialize(to: Atomic(0))
        let tail = UnsafeMutablePointer<Atomic<Int>>.allocate(capacity: 1)
        tail.initialize(to: Atomic(0))
        return SynthCommandRing(slots: slots, head: head, tail: tail)
    }

    func deallocate() {
        slots.deinitialize(count: Self.capacity)
        slots.deallocate()
        head.deinitialize(count: 1)
        head.deallocate()
        tail.deinitialize(count: 1)
        tail.deallocate()
    }

    /// Producer side: free slots.
    var freeCount: Int {
        let t = tail.pointee.load(ordering: .relaxed)
        let h = head.pointee.load(ordering: .acquiring)
        return Self.capacity - (t - h)
    }

    var isEmpty: Bool {
        tail.pointee.load(ordering: .acquiring) == head.pointee.load(ordering: .acquiring)
    }

    /// Producer side. False when the ring is full.
    @discardableResult
    func push(_ command: SynthCommand) -> Bool {
        let t = tail.pointee.load(ordering: .relaxed)
        let h = head.pointee.load(ordering: .acquiring)
        guard t - h < Self.capacity else { return false }
        slots[t % Self.capacity] = command
        tail.pointee.store(t + 1, ordering: .releasing)
        return true
    }

    /// Consumer side: the next command, read in place, or nil.
    @inline(__always) func peek() -> UnsafeMutablePointer<SynthCommand>? {
        let h = head.pointee.load(ordering: .relaxed)
        let t = tail.pointee.load(ordering: .acquiring)
        guard h < t else { return nil }
        return slots + (h % Self.capacity)
    }

    @inline(__always) func advance() {
        let h = head.pointee.load(ordering: .relaxed)
        head.pointee.store(h + 1, ordering: .releasing)
    }
}

/// Everything the render callback touches, behind plain pointers: the bank, the command ring,
/// the master gain and a busy count for the idle check. Created and destroyed on the main
/// thread while no render callback runs.
struct SynthRenderer: @unchecked Sendable {
    let bank: UnsafeMutablePointer<SynthBank>
    let ring: SynthCommandRing
    /// The master gain as Double bits, written by the main thread.
    let master: UnsafeMutablePointer<Atomic<UInt64>>
    /// Active voices plus scheduled notes after the last callback, for the idle check.
    let busy: UnsafeMutablePointer<Atomic<Int>>
    /// Batch bookkeeping, only touched by the render thread.
    private let batchState: UnsafeMutablePointer<(batch: UInt32, base: Int64)>

    static func allocate(sampleRate: Double) -> SynthRenderer {
        let bank = UnsafeMutablePointer<SynthBank>.allocate(capacity: 1)
        bank.initialize(to: SynthBank(sampleRate: sampleRate))
        let master = UnsafeMutablePointer<Atomic<UInt64>>.allocate(capacity: 1)
        master.initialize(to: Atomic(Double(1).bitPattern))
        let busy = UnsafeMutablePointer<Atomic<Int>>.allocate(capacity: 1)
        busy.initialize(to: Atomic(0))
        let batchState = UnsafeMutablePointer<(batch: UInt32, base: Int64)>.allocate(capacity: 1)
        batchState.initialize(to: (batch: 0, base: 0))
        return SynthRenderer(bank: bank, ring: .allocate(), master: master, busy: busy, batchState: batchState)
    }

    func deallocate() {
        bank.deinitialize(count: 1)
        bank.deallocate()
        ring.deallocate()
        master.deinitialize(count: 1)
        master.deallocate()
        busy.deinitialize(count: 1)
        busy.deallocate()
        batchState.deinitialize(count: 1)
        batchState.deallocate()
    }

    var sampleRate: Double { bank.pointee.sampleRate }

    /// Main thread: sets the master gain (1 = the calibrated default; smoothed over 20 ms).
    func setMasterGain(_ g: Double) {
        master.pointee.store(SynthMath.clamp(g, 0, 8).bitPattern, ordering: .relaxed)
    }

    /// Main thread: voices sounding or waiting after the last callback.
    var busyCount: Int { busy.pointee.load(ordering: .acquiring) }

    /// Render thread. Applies queued commands, then renders `frames` samples. A play command's
    /// note starts at its batch's base (the first callback that saw the batch) plus its offset.
    func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        let gain = Double(bitPattern: master.pointee.load(ordering: .relaxed))
        bank.pointee.masterGain = gain.isFinite ? gain : 0
        while let c = ring.peek() {
            switch c.pointee.op {
            case .fadeOutAll:
                bank.pointee.fadeOutAll(seconds: c.pointee.seconds)
            case .play:
                let now = bank.pointee.sampleTime
                if c.pointee.note.batch != batchState.pointee.batch {
                    batchState.pointee = (batch: c.pointee.note.batch, base: now)
                }
                let offset = Int64(c.pointee.note.start * bank.pointee.sampleRate)
                bank.pointee.schedule(c.pointee.note, atSample: batchState.pointee.base + offset)
            }
            ring.advance()
        }
        bank.pointee.render(frames: frames, left: left, right: right)
        busy.pointee.store(bank.pointee.activeCount + bank.pointee.pendingCount, ordering: .releasing)
    }
}
