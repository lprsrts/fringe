// Offline test of the app's sound engine DSP (design 4.6 "Offline DSP").
//
// Compiled with the app's own Audio/SynthVoice.swift and Audio/SoundPalette.swift (scripts/sound.sh).
// Every file is rendered
// through SynthRenderer, the object the app's render callback calls: scores are pushed into the
// command ring as SoundEngine.play does, fadeOutAll goes through the same ring, and audio is
// pulled in callback-sized chunks. Then the 4.6 criteria are asserted, a laptop-speaker model is
// reported, and, when a directory of the reviewed prototype's renders is given, each file is
// compared with the prototype's render of the same case.
//
// Usage: fringe-sound-offline <wav-dir> [prototype-wav-dir]
// In every file the result arrives (t = 0 of the design) at 0.10 s, as in the prototype.

import Foundation

let args = CommandLine.arguments
let outDir = args.count > 1 ? args[1] : "wav"
let protoDir: String? = args.count > 2 ? args[2] : nil
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let fs = 48000.0
let lead = 0.10
var problems: [String] = []
var timingLines: [String] = []
var checkLines: [String] = []
var compareLines: [String] = []
var rows: [(Report, SynthStats, String)] = []
var rendered: [String: ([Float], [Float])] = [:]

func ms(_ s: Double) -> String { String(format: "%.0f", s * 1000) }
func f1(_ x: Double) -> String { x < -150 ? "−∞" : String(format: "%.1f", x).replacingOccurrences(of: "-", with: "−") }
func f2(_ x: Double) -> String { String(format: "%.2f", x) }

// MARK: - Rendering through the app's render path

enum Action {
    case play(SoundScore)
    case fadeOutAll(Double)
}

struct Event {
    var time: Double
    var action: Action
}

/// Renders events through a fresh SynthRenderer in callback-sized chunks (at most 512 frames).
func renderEvents(_ eventsIn: [Event], sampleRate: Double = fs, master: Double = 1, length: Int? = nil,
                  tail: Double = 0.15) -> ([Float], [Float], SynthStats) {
    let events = eventsIn.sorted { $0.time < $1.time }
    let r = SynthRenderer.allocate(sampleRate: sampleRate)
    defer { r.deallocate() }
    r.bank.pointee.jumpMasterGain(master)
    r.setMasterGain(master)
    var end = 0.0
    for e in events { if case .play(let s) = e.action { end = max(end, e.time + s.end) } }
    let n = length ?? Int((end + tail) * sampleRate)
    var L = [Float](repeating: 0, count: n), R = L
    var pos = 0
    var batch: UInt32 = 0
    func pull(to target: Int) {
        while pos < min(target, n) {
            let frames = min(512, min(target, n) - pos)
            L.withUnsafeMutableBufferPointer { lb in
                R.withUnsafeMutableBufferPointer { rb in
                    r.render(frames: frames, left: lb.baseAddress! + pos, right: rb.baseAddress! + pos)
                }
            }
            pos += frames
        }
    }
    for e in events {
        pull(to: Int(e.time * sampleRate))
        switch e.action {
        case .play(let score):
            batch &+= 1
            for note in score.notes {
                var s = note.sanitized()
                s.batch = batch
                if !r.ring.push(SynthCommand(op: .play, note: s)) { problems.append("ring full") }
            }
        case .fadeOutAll(let seconds):
            r.ring.push(SynthCommand(op: .fadeOutAll, seconds: seconds))
        }
        // An empty callback drains the ring at this sample, as the next real callback would.
        L.withUnsafeMutableBufferPointer { lb in
            R.withUnsafeMutableBufferPointer { rb in r.render(frames: 0, left: lb.baseAddress!, right: rb.baseAddress!) }
        }
    }
    pull(to: n)
    return (L, R, r.bank.pointee.stats)
}

/// role: "reveal" (loudest-moment target), "info" (must be ≥ −46 LUFS M), "test", "other".
struct Times {
    var verdict: Double
    var visualEnd: Double
    var kind: String
    var caseStarts: [Double] = []
}

func emit(_ name: String, _ events: [Event], role: String = "info", master: Double = 1, times: Times? = nil) {
    let shifted = events.map { Event(time: $0.time + lead, action: $0.action) }
    let proto = protoDir.flatMap { readWAV("\($0)/\(name).wav") }
    let (L, R, st) = renderEvents(shifted, master: master, length: proto?.0.count)
    do { try writeWAV("\(outDir)/\(name).wav", L, R) } catch { problems.append("write \(name): \(error)") }
    let r = analyse(name, L, R)
    rows.append((r, st, role))
    rendered[name] = (L, R)
    if let t = times {
        let end60 = r.audibleEnd - lead, end40 = r.end40 - lead
        timingLines.append("\(name) [\(t.kind)]: verdict \(ms(t.verdict)) ms, visual end \(ms(t.visualEnd)) ms, sound −40 dB re peak at \(ms(end40)) ms (\(end40 <= t.visualEnd + 0.3 + 1e-9 ? "≤" : ">") visual end + 300), −60 dB at \(ms(end60)) ms (\(end60 <= 3.0 ? "≤" : ">") 3000)")
        if end40 > t.visualEnd + 0.3 + 1e-9 { problems.append("\(name): sound outlasts the visual end by \(ms(end40 - t.visualEnd)) ms") }
        if end60 > 3.0 { problems.append("\(name): audible end \(ms(end60)) ms > 3000 ms") }
    }
    if let (pl, pr) = proto {
        let p = analyse(name, pl, pr)
        var e = 0.0, d = 0.0
        for i in 0..<min(pl.count, L.count) {
            let a = Double(L[i]) - Double(pl[i]), b = Double(R[i]) - Double(pr[i])
            e += a * a + b * b
            d += Double(pl[i] * pl[i] + pr[i] * pr[i])
        }
        let residual = d > 0 ? 10 * log10(max(e, 1e-30) / d) : -200
        // Envelope agreement: 10 ms RMS of both files, where the prototype is within 40 dB of its peak.
        var envDiff = 0.0
        var t = 0.0
        let floorDB = p.peakDB - 40
        while t + 0.01 <= Double(min(pl.count, L.count)) / fs {
            let a = rmsDB(L, R, t, t + 0.01), b = rmsDB(pl, pr, t, t + 0.01)
            if b > floorDB { envDiff = max(envDiff, abs(a - b)) }
            t += 0.01
        }
        compareLines.append("| \(name) | \(f1(residual)) | \(String(format: "%.2f", envDiff)) | \(f1(r.momentaryMax - p.momentaryMax)) | \(f1(r.peakDB - p.peakDB)) | \(ms(r.end40 - p.end40)) / \(ms(r.audibleEnd - p.audibleEnd)) |")
        rendered["proto:" + name] = (pl, pr)
    } else {
        compareLines.append("| \(name) | (no prototype file) | | | | |")
    }
}

func play(_ s: SoundScore, at t: Double = 0) -> [Event] { [Event(time: t, action: .play(s))] }
func notes(_ n: [NoteSpec]) -> SoundScore { SoundScore(notes: n) }

// MARK: - Mock results (the prototype's, so files are comparable)

struct TruthTableMock {
    var values: [[Double]]
    var targets: [[Int]]
    var inputs: Int
    var hasBias = false
    var pass: Double
    var stars: [Double]

    static let floor = 1e-6
    var cases: Int { values.count }
    func bits(_ k: Int) -> [Bool] { (0..<inputs).map { i in (k >> (inputs - 1 - i)) & 1 == 1 } }

    /// Score and per-row verdicts as PuzzleReport computes them.
    var analysis: (score: Double, rowOK: [Bool]) {
        var score = Double.infinity
        var ok = [Bool](repeating: true, count: cases)
        let need = pow(10, pass / 10)
        for j in targets.indices {
            var ones: [(Int, Double)] = [], zeros: [(Int, Double)] = []
            for k in 0..<cases {
                let v = max(SynthMath.finite(values[k][j]), Self.floor)
                if targets[j][k] == 1 { ones.append((k, v)) } else { zeros.append((k, v)) }
            }
            let weakest = ones.map(\.1).min()!, strongest = zeros.map(\.1).max()!
            score = min(score, 10 * log10(weakest / strongest))
            for (k, v) in ones where !(v / strongest >= need * (1 - 1e-12)) { ok[k] = false }
            for (k, v) in zeros where !(v <= Self.floor * (1 + 1e-9) || weakest / v >= need * (1 - 1e-12)) { ok[k] = false }
        }
        return (score, ok)
    }

    func outputWrong(_ k: Int, _ j: Int) -> Bool {
        var single = self
        single.targets = [targets[j]]
        single.values = values.map { [$0[j]] }
        return !single.analysis.rowOK[k]
    }

    func interference(_ k: Int, _ j: Int) -> SoundRevealInput.Interference? {
        let on = bits(k).enumerated().filter { $0.element }.map(\.offset)
        guard on.count == 2 else { return nil }
        let ki = 1 << (inputs - 1 - on[0]), kj = 1 << (inputs - 1 - on[1])
        return SoundInterference.infer(both: values[k][j], a: values[ki][j], b: values[kj][j],
                                       inputsOn: on.count, otherSourceOn: hasBias)
    }
}

func starsFor(score: Double, pass: Double, stars: [Double]) -> (Bool, Int) {
    let passed = score >= pass
    return (passed, passed ? stars.filter { $0 <= score }.count : 0)
}

let hold = 0.080, gap = 0.030, meterD = 0.450
func step(_ n: Int) -> Double { SynthMath.clamp(1.0 / Double(n), 0.080, 0.300) }

func meterFor(score: Double, pass: Double, stars: [Double], percent: Bool, passed: Bool, earned: Int,
              start: Double, duration: Double, fromX: Double = 0, valueFill: Bool = false) -> SoundRevealInput.Meter {
    let track = SoundTrackMap.scoreBar(thresholds: stars, pass: pass, percent: percent)
    let xs = track.position(SynthMath.finite(score)), xp = track.position(pass)
    let nm = SoundMeterMath.nearMiss(toX: xs, passX: xp, score: score, pass: pass, passed: passed)
    var m = SoundRevealInput.Meter(start: start, duration: duration, fromX: fromX, toX: xs, passX: xp,
                                   starX: stars.map(track.position), curve: nm.isNearMiss ? .nearMiss : .normal,
                                   nearMissBeat: nm.beat)
    if valueFill { m.valueFill = .init(track: track, fromValue: 0, toValue: score) }
    m.starTimes = SoundMeterMath.starCrossingTimes(m, stars: earned)
    return m
}

func fullInput(_ mock: TruthTableMock, extra: SoundRevealInput.Extra) -> (SoundRevealInput, Times) {
    let (score, _) = mock.analysis
    let (passed, stars) = starsFor(score: score, pass: mock.pass, stars: mock.stars)
    let N = mock.cases, S = step(N)
    let starts = (0..<N).map { hold + Double($0) * S }
    let cases = (0..<N).map { k in
        SoundRevealInput.Case(start: starts[k], outputs: mock.targets.indices.map { j in
            .init(value: mock.values[k][j], wrong: mock.outputWrong(k, j), interference: j == 0 ? mock.interference(k, j) : nil)
        })
    }
    let meterStart = hold + Double(N) * S + gap
    let m = meterFor(score: score, pass: mock.pass, stars: mock.stars, percent: false, passed: passed, earned: stars,
                     start: meterStart, duration: meterD)
    let verdict = meterStart + meterD
    let input = SoundRevealInput(kind: .full, passed: passed, stars: stars, verdictAt: verdict, extra: extra,
                                 cases: cases, caseStep: S, meter: m)
    let times = Times(verdict: verdict, visualEnd: verdict + 0.15 + (extra == .none ? 0 : 0.30), kind: "full", caseStarts: starts)
    if m.curve == .nearMiss || stars > 0 || !passed {
        timingLines.append("  score \(f2(score)) dB, passed \(passed), stars \(stars), xs \(String(format: "%.3f", m.toX)), near miss \(m.curve == .nearMiss)\(m.curve == .nearMiss ? String(format: " (beat %.2f Hz, stop %.2f Hz vs G4 392.44)", m.nearMissBeat, SoundMeterMath.stopPitch(meter: m, stars: 0)) : ""), star lands \(m.starTimes.map(ms).joined(separator: "/")) ms")
    }
    return (input, times)
}

func deltaInput(_ mock: TruthTableMock, previous prev: TruthTableMock, extra: SoundRevealInput.Extra) -> (SoundRevealInput, Times) {
    let (score, _) = mock.analysis, (pScore, _) = prev.analysis
    let (passed, stars) = starsFor(score: score, pass: mock.pass, stars: mock.stars)
    let (_, pStars) = starsFor(score: pScore, pass: mock.pass, stars: mock.stars)
    var changed: [Int] = []
    for k in 0..<mock.cases {
        let flips = (0..<mock.targets.count).contains { mock.outputWrong(k, $0) != prev.outputWrong(k, $0) }
        let moved = (0..<mock.targets.count).contains { j in
            abs(10 * log10(max(mock.values[k][j], 1e-6) / max(prev.values[k][j], 1e-6))) >= 1
        }
        if flips || moved { changed.append(k) }
    }
    let Sd = changed.isEmpty ? 0 : min(0.15, 0.45 / Double(changed.count))
    let starts = changed.indices.map { 0.060 + Double($0) * Sd }
    let cases = changed.enumerated().map { idx, k in
        SoundRevealInput.Case(start: starts[idx], outputs: mock.targets.indices.map { j in
            .init(value: mock.values[k][j], previous: prev.values[k][j], wrong: mock.outputWrong(k, j))
        })
    }
    let track = SoundTrackMap.scoreBar(thresholds: mock.stars, pass: mock.pass, percent: false)
    let meterStart = (starts.last.map { $0 + Sd } ?? 0.060) + 0.020
    var m = meterFor(score: score, pass: mock.pass, stars: mock.stars, percent: false, passed: passed, earned: stars,
                     start: meterStart, duration: 0.30, fromX: max(track.position(pScore), 1e-6))
    m.previousStars = pStars
    let verdict = meterStart + 0.30
    let input = SoundRevealInput(kind: .delta, passed: passed, stars: stars, verdictAt: verdict, extra: extra,
                                 cases: cases, caseStep: max(Sd, 0.02), meter: m)
    return (input, Times(verdict: verdict, visualEnd: verdict + 0.15, kind: "delta (\(changed.count) changed)", caseStarts: starts))
}

struct SingleMock {
    var kind: SoundRevealInput.GoalKind
    var value: Double
    var score: Double
    var pass: Double
    var stars: [Double]
    var percent = true
    var share = 0.0
    var tolerance = 5.0
    var sideConditionFails = false
}

func singleInput(_ mock: SingleMock, extra: SoundRevealInput.Extra) -> (SoundRevealInput, Times) {
    var (passed, stars) = starsFor(score: mock.score, pass: mock.pass, stars: mock.stars)
    if mock.sideConditionFails { passed = false; stars = 0 }
    let start = 0.080, D = 0.80
    let m = meterFor(score: mock.score, pass: mock.pass, stars: mock.stars, percent: mock.percent, passed: passed,
                     earned: stars, start: start, duration: D, valueFill: !mock.sideConditionFails)
    let verdict = start + D + 0.04
    let single = SoundRevealInput.SingleCase(kind: mock.kind, fieldValue: mock.value,
                                             pan: SynthMath.clamp(0.35 * mock.share / max(mock.tolerance, 1e-9), -0.8, 0.8),
                                             sideConditionFailed: mock.sideConditionFails)
    let input = SoundRevealInput(kind: .full, passed: passed, stars: stars, verdictAt: verdict, extra: extra,
                                 caseStep: D, meter: m, single: single)
    timingLines.append("  score \(mock.score), passed \(passed), stars \(stars), xs \(String(format: "%.3f", m.toX)), near miss \(m.curve == .nearMiss)\(m.curve == .nearMiss ? String(format: " (beat %.2f Hz)", m.nearMissBeat) : ""), star lands \(m.starTimes.map(ms).joined(separator: "/")) ms")
    return (input, Times(verdict: verdict, visualEnd: verdict + 0.15 + (extra == .none ? 0 : 0.30), kind: "single", caseStarts: [start]))
}

let xorRef = TruthTableMock(values: [[1e-6], [0.507], [0.495], [0.00876]], targets: [[0, 1, 1, 0]], inputs: 2, pass: 6, stars: [6, 10, 15])
let xorNear = TruthTableMock(values: [[1e-6], [0.52], [0.44], [0.44 / pow(10, 0.54)]], targets: [[0, 1, 1, 0]], inputs: 2, pass: 6, stars: [6, 10, 15])
let xorNear2 = TruthTableMock(values: [[1e-6], [0.52], [0.44], [0.44 / pow(10, 0.59)]], targets: [[0, 1, 1, 0]], inputs: 2, pass: 6, stars: [6, 10, 15])
let xorFar = TruthTableMock(values: [[1e-6], [0.52], [0.44], [0.44 / pow(10, 0.21)]], targets: [[0, 1, 1, 0]], inputs: 2, pass: 6, stars: [6, 10, 15])
let xorPrev3 = TruthTableMock(values: [[1e-6], [0.52], [0.44], [0.44 / pow(10, 0.30)]], targets: [[0, 1, 1, 0]], inputs: 2, pass: 6, stars: [6, 10, 15])
let xorNew45 = TruthTableMock(values: [[1e-6], [0.52], [0.44], [0.44 / pow(10, 0.45)]], targets: [[0, 1, 1, 0]], inputs: 2, pass: 6, stars: [6, 10, 15])
let xor123 = TruthTableMock(values: [[1e-6], [0.507], [0.495], [0.495 / pow(10, 1.23)]], targets: [[0, 1, 1, 0]], inputs: 2, pass: 6, stars: [6, 10, 15])
let andCap = TruthTableMock(values: [[1e-6], [0.255], [0.245], [0.255 * pow(10, 0.59)]], targets: [[0, 0, 0, 1]], inputs: 2, pass: 4, stars: [4, 5, 5.7])
let notGate = TruthTableMock(values: [[0.62], [0.004]], targets: [[1, 0]], inputs: 1, hasBias: true, pass: 6, stars: [6, 10, 15])
let majority = TruthTableMock(values: [[1e-6], [0.03], [0.03], [0.42], [0.03], [0.40], [0.41], [0.95]],
                              targets: [[0, 0, 0, 1, 0, 1, 1, 1]], inputs: 3, pass: 6, stars: [6, 9, 12])
let halfAdder = TruthTableMock(values: [[1e-6, 1e-6], [0.50, 0.30], [0.49, 0.02], [0.01, 0.90]],
                               targets: [[0, 1, 1, 0], [0, 0, 0, 1]], inputs: 2, pass: 6, stars: [6, 10, 15])

func failPitch(_ mock: TruthTableMock) -> Double {
    let (score, _) = mock.analysis
    let (p, s) = starsFor(score: score, pass: mock.pass, stars: mock.stars)
    return SoundMeterMath.stopPitch(meter: meterFor(score: score, pass: mock.pass, stars: mock.stars, percent: false,
                                                    passed: p, earned: s, start: 0, duration: meterD), stars: 0)
}

// MARK: - Single events (design 2.2), each starting at t = 0

let S4 = step(4)
func oneCase(_ v: Double, wrong: Bool = false, interference: SoundRevealInput.Interference? = nil) -> SoundScore {
    notes([SoundPalette.detectorVoice([.init(t: 0, value: v, interference: interference, wrong: wrong)], step: S4 + 0.1,
                                      pitch: SoundTuning.C4)!])
}
emit("event-01-case-bright-0.507", play(oneCase(0.507)))
emit("event-02-case-dark-0.00876", play(oneCase(0.00876)))
emit("event-02b-case-floor-0.0003", play(oneCase(0.0003)))
emit("event-03-case-silent-1e-6-shutter-only", play(oneCase(1e-6)))
emit("event-04-case-wrong-0.44", play(oneCase(0.44, wrong: true)))
emit("event-05-interference-destructive-xor11",
     play(oneCase(0, interference: SoundInterference.infer(both: 0.00876, a: 0.495, b: 0.507, inputsOn: 2, otherSourceOn: false))))
emit("event-06-interference-constructive-and11",
     play(oneCase(0, interference: SoundInterference.infer(both: 0.255 * pow(10, 0.59), a: 0.245, b: 0.255, inputsOn: 2, otherSourceOn: false))))
do {
    let m3 = meterFor(score: 17.52, pass: 6, stars: [6, 10, 15], percent: false, passed: true, earned: 3, start: 0, duration: meterD)
    var riser = SoundPalette.riser(at: 0, releaseAt: m3.starTimes[2] + 0.03, tau: 0.04)
    riser.meter = SoundMeterMath.pitchCurve(m3, stars: 3)
    riser.meter.lockAt = m3.starTimes[2]
    riser.meter.lockPitch = SoundTuning.E5
    emit("event-07-meterRiser-pass-3stars-alone", play(notes([riser])))
    var ids: UInt8 = 0
    emit("event-08-meter-pass-3stars-with-stars", play(SoundPalette.meterScore(m3, stars: 3, verdict: meterD, extra: .none, ids: &ids)))
    let fail = meterFor(score: 2.1, pass: 6, stars: [6, 10, 15], percent: false, passed: false, earned: 0, start: 0, duration: meterD)
    emit("event-09-meter-failStop-2.1dB", play(SoundPalette.meterScore(fail, stars: 0, verdict: meterD, extra: .none, ids: &ids)))
    for (score, label) in [(5.4, "5.4dB-beat"), (5.9, "5.9dB-beat"), (5.0, "5.0dB-beat")] {
        let n = meterFor(score: score, pass: 6, stars: [6, 10, 15], percent: false, passed: false, earned: 0, start: 0, duration: meterD)
        emit("event-10-nearMiss-\(label)-\(String(format: "%.1f", n.nearMissBeat))Hz",
             play(SoundPalette.meterScore(n, stars: 0, verdict: meterD, extra: .none, ids: &ids)))
    }
}
emit("event-11-starLand1-G4", play(notes([SoundPalette.starLand(0, at: 0, verdict: 0.3)])))
emit("event-12-starLand2-C5", play(notes([SoundPalette.starLand(1, at: 0, verdict: 0.3)])))
emit("event-13-starLand3-E5", play(notes([SoundPalette.starLand(2, at: 0, verdict: 0.3)])))
let chord3 = (0..<3).map { SoundPalette.starLand($0, at: 0, verdict: 0.2) }
emit("event-14-newBest-chord-plus-C6", play(notes(chord3 + [SoundPalette.newBest(verdict: 0.2, tau: 0.08)])))
emit("event-15-firstSolve-chord-plus-C4-root",
     play(notes((0..<3).map { SoundPalette.starLand($0, at: 0, verdict: 0.2, tau: 0.16) } + [SoundPalette.firstSolve(verdict: 0.2)])))
emit("event-16-allStars-E6-alone", play(notes([SoundPalette.allStars(verdict: 0)])))
emit("event-17-chapterComplete-strum-alone", play(SoundPalette.chapterComplete(verdict: -0.25)))
emit("event-18-invalidDesign", play(SoundPalette.invalidDesign()))
emit("event-19-toggle-bright", play(SoundPalette.toggleTone(value: 0.507, wrong: false)))
emit("event-20-toggle-wrong", play(SoundPalette.toggleTone(value: 0.44, wrong: true)))
emit("event-21-skipTone-pass-3stars", play(SoundPalette.verdictTone(stars: 3, failPitch: 300, at: 0, tau: 0.05)))
emit("event-21b-skipTone-fail", play(SoundPalette.verdictTone(stars: 0, failPitch: failPitch(xorFar), at: 0, tau: 0.05)))
emit("event-22-recheckTone-3stars", play(SoundPalette.verdictTone(stars: 3, failPitch: 300, at: 0, tau: 0.058)))
emit("event-26-finalSolveDone-C5", play(SoundPalette.finalSolveDone()))
emit("event-27-settings-sample", play(SoundPalette.sample()))

// MARK: - Truth-table reveals

func emitFull(_ name: String, _ mock: TruthTableMock, _ extra: SoundRevealInput.Extra) -> (SoundRevealInput, Times) {
    let (input, t) = fullInput(mock, extra: extra)
    emit(name, play(SoundPalette.reveal(input)), role: "reveal", times: t)
    return (input, t)
}
let (seq1Input, seq1Times) = emitFull("seq-1-xor-pass-3stars-allStars", xorRef, .allStars)
_ = emitFull("seq-2-xor-near-miss-5.4dB", xorNear, .none)
_ = emitFull("seq-2b-xor-near-miss-5.9dB-very-close", xorNear2, .none)
let (seq2cInput, _) = emitFull("seq-2c-xor-fail-2.1dB", xorFar, .none)
let (_, andTimes) = emitFull("seq-3-and-5.9dB-chapterComplete", andCap, .chapterComplete)
_ = emitFull("seq-3b-not-2cases-firstSolve", notGate, .firstSolve)
_ = emitFull("seq-3c-majority-8cases-newBest", majority, .newBest)
_ = emitFull("seq-3d-half-adder-carry-row-01-wrong", halfAdder, .none)

// MARK: - Single-case reveals

let maxStars: [Double] = [60, 75, 82]
func emitSingle(_ name: String, _ m: SingleMock, _ e: SoundRevealInput.Extra) {
    let (input, t) = singleInput(m, extra: e)
    emit(name, play(SoundPalette.reveal(input)), role: "reveal", times: t)
}
emitSingle("seq-4-maximize-84.7-3stars-newBest", SingleMock(kind: .maximize, value: 0.847, score: 84.7, pass: 60, stars: maxStars), .newBest)
emitSingle("seq-4b-maximize-76-2stars-firstSolve", SingleMock(kind: .maximize, value: 0.76, score: 76, pass: 60, stars: maxStars), .firstSolve)
emitSingle("seq-5-maximize-fail-12pc", SingleMock(kind: .maximize, value: 0.12, score: 12, pass: 60, stars: maxStars), .none)
emitSingle("seq-5b-maximize-near-miss-57pc", SingleMock(kind: .maximize, value: 0.57, score: 57, pass: 60, stars: maxStars), .none)
emitSingle("seq-5c-minimize-residual-0.02-17dB-2stars", SingleMock(kind: .minimize, value: 0.02, score: 17.0, pass: 10, stars: [10, 15, 20], percent: false), .none)
emitSingle("seq-5d-minimize-residual-0.2-7dB-fail", SingleMock(kind: .minimize, value: 0.2, score: 7.0, pass: 10, stars: [10, 15, 20], percent: false), .none)
emitSingle("seq-5e-target-balanced-49.5-50.7-3stars", SingleMock(kind: .target, value: 1.0, score: 99, pass: 90, stars: [90, 95, 98], share: -0.6), .none)
emitSingle("seq-5f-target-lopsided-62-38-outside-tolerance", SingleMock(kind: .target, value: 1.0, score: 97, pass: 90, stars: [90, 95, 98], share: 12, sideConditionFails: true), .none)

// MARK: - Toggles after a Check (1.9): one legato voice, each toggle sent when it happens

func toggles(_ mock: TruthTableMock, _ seq: [(Double, Int)]) -> [Event] {
    seq.flatMap { t, k in play(SoundPalette.toggleTone(value: mock.values[k][0], wrong: mock.outputWrong(k, 0)), at: t) }
}
emit("seq-6-xor-toggle-inputs-after-check", toggles(xorRef, [(0.0, 1), (0.6, 0), (1.2, 2), (1.8, 3), (2.4, 1), (2.45, 3)]))
emit("seq-6b-xor-near-miss-toggles-rough-rows", toggles(xorNear, [(0.0, 1), (0.6, 2), (1.2, 3), (1.8, 0)]))

// MARK: - Skip, re-check, delta, Reduce Motion, VoiceOver, invalid

func skipped(_ input: SoundRevealInput, at t: Double) -> [Event] {
    play(SoundPalette.reveal(input)) + [Event(time: t, action: .fadeOutAll(0.06))] + play(SoundPalette.skipTone(for: input), at: t)
}
emit("seq-7-xor-skipped-at-800ms", skipped(seq1Input, at: 0.8), role: "reveal")
emit("seq-7b-xor-fail-skipped-at-500ms", skipped(seq2cInput, at: 0.5), role: "reveal")
var recheck = seq1Input
recheck.kind = .recheck
emit("seq-8-xor-recheck-unchanged", play(SoundPalette.reveal(recheck)), role: "reveal",
     times: Times(verdict: 0.06, visualEnd: 0.16, kind: "recheck"))
for (name, mock, prev, extra) in [("seq-11a-xor-delta-3.0-to-4.5dB-better", xorNew45, xorPrev3, SoundRevealInput.Extra.none),
                                  ("seq-11b-xor-delta-17.5-to-12.3dB-worse-star-lost", xor123, xorRef, .none),
                                  ("seq-11c-xor-delta-5.4-to-5.9dB-under-1dB", xorNear2, xorNear, .newBest)] {
    let (input, t) = deltaInput(mock, previous: prev, extra: extra)
    emit(name, play(SoundPalette.reveal(input)), role: "reveal", times: t)
}
var reduced = seq1Input
reduced.kind = .reduced
emit("seq-9-xor-reduce-motion", play(SoundPalette.reveal(reduced)), role: "reveal", times: Times(verdict: 0.42, visualEnd: 0.60, kind: "reduce motion"))
var vo = seq1Input
vo.kind = .voiceOver
emit("seq-12-xor-voiceover-pass", play(SoundPalette.reveal(vo)), role: "reveal", times: Times(verdict: 0, visualEnd: 0.15, kind: "VoiceOver"))
emit("seq-10-invalid-design", play(SoundPalette.invalidDesign()), times: Times(verdict: 0, visualEnd: 0.15, kind: "invalid"))
var instant = seq1Input
instant.kind = .instant
if !SoundPalette.reveal(instant).isEmpty { problems.append("instant reveal is not silent") }

// MARK: - Near-miss beat diagnostics: the stop pitch against G4, held 2 s

for score in [5.9, 5.4, 5.0, 4.6] {
    let m = meterFor(score: score, pass: 6, stars: [6, 10, 15], percent: false, passed: false, earned: 0, start: 0, duration: meterD)
    guard m.curve == .nearMiss else { continue }
    var r = SoundPalette.riser(at: 0, releaseAt: 2.0, tau: 0.05)
    r.frequency = SoundMeterMath.stopPitch(meter: m, stars: 0)
    let ref = SoundPalette.nearMissReference(start: 0, fadeIn: 0.05, hold: 1.95, amplitude: SoundLevel.riser * SynthMath.dB(-1))
    if m.nearMissBeat < 1.5 || m.nearMissBeat > 6 { problems.append("near-miss beat \(m.nearMissBeat) outside 1.5…6 Hz") }
    emit("diag-nearMiss-\(String(format: "%.1f", score))dB-stop-vs-G4-held-2s-\(String(format: "%.2f", m.nearMissBeat))Hz", play(notes([r, ref])), role: "test")
}

// MARK: - Adversarial and stress (2.6)

var adv = SoundScore()
for (k, v) in [Double.nan, 1e9, -1, 0, .infinity, -.infinity, 1e-300].enumerated() {
    let seg = SoundPalette.CaseSegment(t: 0.05 * Double(k), value: v,
                                       interference: k == 2 ? .init(powerA: .nan, powerB: 1e9, phase: .nan) : nil, wrong: k % 2 == 0)
    if let n = SoundPalette.detectorVoice([seg], step: 0.2, pitch: k == 3 ? .nan : 1e9) { adv.append(n) }
    adv.append(contentsOf: SoundPalette.toggleTone(value: v, wrong: true, at: 0.05 * Double(k)))
}
var bad = SoundPalette.finalSolveDone(at: 0.3).notes[0]
bad.frequency = 1e9; bad.pan = .constant(5); bad.amplitude = 1e9; bad.detune = 200
bad.hasRough = true; bad.rough = .constant(1)
adv.append(bad)
var bad2 = SoundPalette.finalSolveDone(at: 0.3).notes[0]
bad2.frequency = .nan; bad2.pan = .constant(.nan); bad2.amplitude = .infinity; bad2.envelope.tau = 0
adv.append(bad2)
var bad3 = SoundPalette.riser(at: 0.35, releaseAt: .nan, tau: .infinity)
bad3.meter = SoundMeterMath.pitchCurve(.init(start: .nan, duration: .nan, fromX: .nan, toX: .infinity, passX: -3,
                                             starX: [.nan, 2, -1], curve: .nearMiss, nearMissBeat: .nan), stars: 2)
adv.append(bad3)
for k in 0..<30 { adv.append(SoundPalette.starLand(k % 3, at: 0.4 + 0.002 * Double(k), verdict: 0.8)) }
emit("test-adversarial", play(adv), role: "test")
emit("test-adversarial-volume-max-plus12dB", play(adv), role: "test", master: SynthMath.dB(12))
emit("test-seq-1-at-volume-max-plus12dB", play(SoundPalette.reveal(seq1Input)), role: "test", master: SynthMath.dB(12))

// MARK: - Physics checks

func caseRMS(_ name: String, _ starts: [Double], step: Double) -> [Double] {
    guard let (L, R) = rendered[name] else { return [] }
    return starts.map { rmsDB(L, R, lead + $0 + 0.19, lead + $0 + step - 0.01) }
}
let xorCases = caseRMS("seq-1-xor-pass-3stars-allStars", seq1Times.caseStarts, step: S4)
checkLines.append("seq-1 XOR per-case RMS (settled part of each case, dBFS): " + xorCases.map(f1).joined(separator: " / "))
if let (L, R) = rendered["seq-1-xor-pass-3stars-allStars"] {
    func peak20(_ t0: Double) -> Double {
        var p = -200.0, t = t0 + 0.04
        while t + 0.02 <= t0 + S4 { p = max(p, rmsDB(L, R, t, t + 0.02)); t += 0.01 }
        return p
    }
    let peak11 = peak20(lead + seq1Times.caseStarts[3])
    let bright = max(peak20(lead + seq1Times.caseStarts[1]), peak20(lead + seq1Times.caseStarts[2]))
    checkLines.append("seq-1 XOR case 11 (dark-not-louder): loudest 20 ms after the tap \(f1(peak11)) dBFS vs the bright cases' \(f1(bright)) dBFS: \(peak11 <= bright + 0.5 ? "ok" : "FAIL"); settled \(f1(xorCases[3])) dBFS")
    if peak11 > bright + 0.5 { problems.append("XOR dark 11 louder than a bright case") }
    // Interference must not modulate: the 20 ms envelope of case 11 after A alone only falls.
    var env: [Double] = []
    var t = lead + seq1Times.caseStarts[3] + 0.06
    while t < lead + seq1Times.caseStarts[3] + 0.24 { env.append(rmsDB(L, R, t, t + 0.02)); t += 0.02 }
    let rises = zip(env, env.dropFirst()).filter { $1 > $0 + 0.3 }.count
    checkLines.append("seq-1 XOR case 11 envelope after A alone (dBFS, 20 ms): " + env.map(f1).joined(separator: " ") + (rises == 0 ? " (monotonic: ok)" : " (rises: FAIL)"))
    if rises > 0 { problems.append("XOR case 11 envelope is not monotonic") }
}
checkLines.append("seq-3 AND per-case RMS (dBFS, constructive 11 is the loudest): " + caseRMS("seq-3-and-5.9dB-chapterComplete", andTimes.caseStarts, step: S4).map(f1).joined(separator: " / "))

// Legato toggles: a quick flick (2.40 → 2.45 s) must glide on one voice with no level dip.
if let (L, R) = rendered["seq-6-xor-toggle-inputs-after-check"] {
    let a = rmsDB(L, R, lead + 2.43, lead + 2.45), b = rmsDB(L, R, lead + 2.45, lead + 2.47)
    checkLines.append("seq-6 quick flick at 2.45 s: RMS \(f1(a)) → \(f1(b)) dBFS across the retrigger (\(b > a - 6 ? "no dip: ok" : "dip: FAIL"))")
    if b <= a - 6 { problems.append("toggle retrigger dips") }
}

// The same reveal at 44.1 kHz (a common device rate): peak, limiter, clicks, tail.
do {
    let (L, R, st) = renderEvents(play(SoundPalette.reveal(seq1Input)).map { Event(time: $0.time + lead, action: $0.action) }, sampleRate: 44100)
    var peak = 0.0
    for i in 0..<L.count { peak = max(peak, Double(abs(L[i])), Double(abs(R[i]))) }
    let tailN = 441
    var tail = 0.0
    for i in (L.count - tailN)..<L.count { tail += Double(L[i] * L[i] + R[i] * R[i]) }
    var maxD = 0.0
    for ch in [L, R] {
        for i in 4..<ch.count {
            maxD = max(maxD, abs(Double(ch[i]) - 4 * Double(ch[i - 1]) + 6 * Double(ch[i - 2]) - 4 * Double(ch[i - 3]) + Double(ch[i - 4])))
        }
    }
    let click = SynthMath.toDB(maxD / peak)
    checkLines.append("seq-1 at 44.1 kHz: peak \(f1(SynthMath.toDB(peak))) dBFS, limiter GR \(String(format: "%.2f", st.maxGainReductionDB)) dB, click \(f1(click)) dB re peak, last 10 ms \(f1(SynthMath.toDB((tail / Double(2 * tailN)).squareRoot()))) dBFS")
    let tailDB = SynthMath.toDB((tail / Double(2 * tailN)).squareRoot())
    if st.maxGainReductionDB > 0.01 || click > -20 || tailDB > -100 || peak > SynthMath.dB(-6) { problems.append("seq-1 at 44.1 kHz fails peak/limiter/click/tail") }
}

// MARK: - The render path does not allocate

do {
    let r = SynthRenderer.allocate(sampleRate: fs)
    defer { r.deallocate() }
    var L = [Float](repeating: 0, count: 512), R = L
    var batch: UInt32 = 1
    var scores = [SoundPalette.reveal(seq1Input)]
    scores.append(SoundPalette.toggleTone(value: 0.4, wrong: true))
    scores.append(SoundPalette.toggleTone(value: 0.1, wrong: false))
    for s in scores {
        for n in s.notes { var n = n.sanitized(); n.batch = batch; r.ring.push(SynthCommand(op: .play, note: n)) }
        batch += 1
    }
    // Warm up one callback (first-use runtime work), then count heap blocks over 3 s of rendering.
    L.withUnsafeMutableBufferPointer { lb in R.withUnsafeMutableBufferPointer { rb in r.render(frames: 512, left: lb.baseAddress!, right: rb.baseAddress!) } }
    var before = malloc_statistics_t(), after = malloc_statistics_t()
    malloc_zone_statistics(nil, &before)
    let t0 = Date()
    L.withUnsafeMutableBufferPointer { lb in
        R.withUnsafeMutableBufferPointer { rb in
            for k in 0..<281 {
                if k == 100 { r.ring.push(SynthCommand(op: .fadeOutAll, seconds: 0.06)) }
                r.render(frames: 512, left: lb.baseAddress!, right: rb.baseAddress!)
            }
        }
    }
    let elapsed = Date().timeIntervalSince(t0)
    malloc_zone_statistics(nil, &after)
    let blocks = Int(after.blocks_in_use) - Int(before.blocks_in_use)
    let bytes = Int(after.size_in_use) - Int(before.size_in_use)
    checkLines.append("render path: 3.0 s of audio (seq-1 + two toggles, a fadeOutAll mid-way) rendered in \(String(format: "%.1f", elapsed * 1000)) ms (\(String(format: "%.2f", elapsed / 3.0 * 100)) % of real time, one core); heap blocks in use changed by \(blocks), bytes by \(bytes)")
    if blocks != 0 || bytes != 0 { problems.append("render path changed the heap (\(blocks) blocks, \(bytes) bytes)") }
}

// MARK: - Output

print("| file | role | dur s | peak dBFS | limiter GR dB | LUFS (int.) | max momentary LUFS | laptop-model max M | clipped | centroid Hz | >6 kHz dB | last 10 ms | click dB re peak | sound −40 / −60 dB re peak (s) | voices / steals / notes |")
print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
var loudest: [(String, Double, Double)] = []
for (r, s, role) in rows {
    print("| \(r.file) | \(role) | \(f2(r.duration)) | \(f1(r.peakDB)) | \(String(format: "%.1f", s.maxGainReductionDB)) | \(f1(r.lufs)) | \(f1(r.momentaryMax)) | \(f1(r.lapMomentaryMax)) | \(r.clipped) | \(Int(r.centroid)) | \(f1(r.hf6kDB)) | \(f1(r.tailDB)) | \(f1(r.clickDB)) | \(String(format: "%.2f / %.2f", r.end40, r.audibleEnd)) | \(s.maxVoices) / \(s.steals) / \(s.notes) |")
    if r.peakDB > -6.0001 { problems.append("\(r.file): peak \(r.peakDB) > −6 dBFS") }
    if r.clipped > 0 { problems.append("\(r.file): clipped") }
    if r.tailDB > -100 { problems.append("\(r.file): tail not silent (\(r.tailDB))") }
    if r.clickDB > -20 { problems.append("\(r.file): click metric \(r.clickDB) dB at \(r.clickAt) s") }
    if role != "test", s.maxGainReductionDB > 0.01 { problems.append("\(r.file): limiter engaged (\(s.maxGainReductionDB) dB) at the default volume") }
    if role == "reveal" { loudest.append((r.file, r.momentaryMax, r.lapMomentaryMax)) }
    if role == "info" || role == "reveal", r.momentaryMax < -46 { problems.append("\(r.file): max momentary \(f1(r.momentaryMax)) LUFS < −46") }
}
let full = loudest.filter { n, _, _ in !["skipped", "recheck", "reduce", "voiceover", "delta"].contains { n.contains($0) } }
print("")
print("LOUDEST MOMENT of full reveals (target −28 ± 2 LUFS; a fail of a dim design may be −34…−26): " + full.map { "\($0.0) \(f1($0.1))" }.joined(separator: "; "))
for (n, v, _) in full where v > -26 || v < (n.contains("fail") ? -34 : -30) { problems.append("\(n): loudest moment \(f1(v)) LUFS outside the target") }
print("")
print("LAPTOP-SPEAKER MODEL (4th-order high-pass at 200 Hz before K-weighting), loss of the loudest moment:")
for (n, v, lap) in loudest { print("- \(n): \(f1(v)) → \(f1(lap)) LUFS (\(f1(lap - v)) dB)") }
let worst = rows.filter { $0.2 != "test" }.map { ($0.0.file, $0.0.lapMomentaryMax - $0.0.momentaryMax) }.min { $0.1 < $1.1 }
if let w = worst { print("Worst laptop loss of any listening file: \(w.0) \(f1(w.1)) dB") }
print("")
print("TIMING")
for l in timingLines { print("- " + l) }
print("")
print("CHECKS")
for l in checkLines { print("- " + l) }
print("")
if protoDir != nil {
    print("AGAINST THE PROTOTYPE (same mock results; residual = energy of app − prototype re prototype, whole file)")
    print("")
    print("| file | residual dB | max Δ 10 ms envelope dB | Δ max momentary LU | Δ peak dB | Δ end −40 / −60 dB (ms) |")
    print("|---|---|---|---|---|---|")
    for l in compareLines { print(l) }
    print("")
}
print("PROBLEMS: \(problems.isEmpty ? "none" : "")")
for p in problems { print("- " + p) }
exit(problems.isEmpty ? 0 : 1)
