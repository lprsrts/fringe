// Analysis.swift (offline test tool only): WAV reading and writing and the measurements of the
// prototype's analysis (peak, BS.1770 loudness, clipping, DC, spectral centroid, energy above
// 6 kHz, clicks, audible end, a laptop-speaker loudness model). Taken from sound/proto so the
// numbers are comparable; the DSP itself is not copied, it comes from ../SynthVoice.swift.

import Foundation

func writeWAV(_ path: String, _ L: [Float], _ R: [Float], fs: Int = 48000) throws {
    var d = Data()
    func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    let frames = L.count
    let dataBytes = UInt32(frames * 2 * 4)
    d.append(contentsOf: Array("RIFF".utf8)); u32(4 + 26 + 12 + 8 + dataBytes)
    d.append(contentsOf: Array("WAVE".utf8))
    d.append(contentsOf: Array("fmt ".utf8)); u32(18); u16(3); u16(2); u32(UInt32(fs)); u32(UInt32(fs * 8)); u16(8); u16(32); u16(0)
    d.append(contentsOf: Array("fact".utf8)); u32(4); u32(UInt32(frames))
    d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
    var inter = [Float](repeating: 0, count: frames * 2)
    for i in 0..<frames { inter[2 * i] = L[i]; inter[2 * i + 1] = R[i] }
    inter.withUnsafeBytes { d.append(contentsOf: $0) }
    try d.write(to: URL(fileURLWithPath: path))
}

struct Biquad {
    var b0, b1, b2, a1, a2: Double
    var z1 = 0.0, z2 = 0.0
    mutating func run(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

func fft(_ re: inout [Double], _ im: inout [Double]) {
    let n = re.count
    var j = 0
    for i in 1..<n {
        var bit = n >> 1
        while j & bit != 0 { j ^= bit; bit >>= 1 }
        j |= bit
        if i < j { re.swapAt(i, j); im.swapAt(i, j) }
    }
    var len = 2
    while len <= n {
        let ang = -2 * Double.pi / Double(len)
        for i in stride(from: 0, to: n, by: len) {
            for k in 0..<len / 2 {
                let wr = cos(ang * Double(k)), wi = sin(ang * Double(k))
                let ur = re[i + k], ui = im[i + k]
                let vr = re[i + k + len / 2] * wr - im[i + k + len / 2] * wi
                let vi = re[i + k + len / 2] * wi + im[i + k + len / 2] * wr
                re[i + k] = ur + vr; im[i + k] = ui + vi
                re[i + k + len / 2] = ur - vr; im[i + k + len / 2] = ui - vi
            }
        }
        len <<= 1
    }
}

struct Report {
    var file: String
    var duration: Double
    var peakDB: Double
    var lufs: Double
    var lufsNote: String
    var momentaryMax: Double
    var clipped: Int
    var dcDB: Double
    var centroid: Double
    var hf6kDB: Double
    var firstSampleDB: Double
    var lastSampleDB: Double
    var tailDB: Double
    var clickDB: Double          // max |4th difference| re peak, dB (clean ≈ < −60)
    var clickAt: Double
    var edgeClickDB: Double      // same, within the first and last 20 ms of sound
    var audibleStart: Double     // first 10 ms window above peak − 60 dB
    var audibleEnd: Double       // last 10 ms window above peak − 60 dB
    var end40: Double            // last 10 ms window above peak − 40 dB ("effectively over")
    var lapMomentaryMax: Double  // max momentary after a laptop-speaker model (4th-order HP 200 Hz)
}

func highpass(_ fc: Double, _ fs: Double, q: Double = 0.7071) -> Biquad {
    let w = 2 * Double.pi * fc / fs, al = sin(w) / (2 * q), c = cos(w), a0 = 1 + al
    return Biquad(b0: (1 + c) / 2 / a0, b1: -(1 + c) / a0, b2: (1 + c) / 2 / a0, a1: -2 * c / a0, a2: (1 - al) / a0)
}

/// Max momentary loudness (400 ms blocks, 100 ms hop; one block for short files), optional prefilter.
func momentaryLoudnessMax(_ L: [Float], _ R: [Float], fs: Double = 48000, laptop: Bool) -> Double {
    func kw() -> [Biquad] {
        var f: [Biquad] = []
        if laptop { f += [highpass(200, fs), highpass(200, fs)] }
        f += [Biquad(b0: 1.53512485958697, b1: -2.69169618940638, b2: 1.19839281085285, a1: -1.69065929318241, a2: 0.73248077421585),
              Biquad(b0: 1, b1: -2, b2: 1, a1: -1.99004745483398, a2: 0.99007225036621)]
        return f
    }
    var fl = kw(), fr = kw()
    let n = L.count
    var z = [Double](repeating: 0, count: n)
    for i in 0..<n {
        var a = Double(L[i]), b = Double(R[i])
        for k in fl.indices { a = fl[k].run(a) }
        for k in fr.indices { b = fr[k].run(b) }
        z[i] = a * a + b * b
    }
    let block = Int(0.4 * fs), hop = Int(0.1 * fs)
    if n < block { return -0.691 + 10 * log10(max(z.reduce(0, +) / Double(block), 1e-30)) }
    var best = 1e-30, i = 0
    var acc = z[0..<block].reduce(0, +)
    while true {
        best = max(best, acc / Double(block))
        if i + hop + block > n { break }
        acc -= z[i..<(i + hop)].reduce(0, +); acc += z[(i + block)..<(i + block + hop)].reduce(0, +)
        i += hop
    }
    return -0.691 + 10 * log10(best)
}

/// RMS in dB of both channels over [t0, t1).
func rmsDB(_ L: [Float], _ R: [Float], _ t0: Double, _ t1: Double, fs: Double = 48000) -> Double {
    let a = max(0, Int(t0 * fs)), b = min(L.count, Int(t1 * fs))
    guard b > a else { return -200 }
    var e = 0.0
    for i in a..<b { e += Double(L[i] * L[i] + R[i] * R[i]) }
    return 10 * log10(max(e / Double(2 * (b - a)), 1e-30))
}

func analyse(_ file: String, _ L: [Float], _ R: [Float], fs: Double = 48000) -> Report {
    let n = L.count
    var peak = 0.0, clipped = 0
    var sumL = 0.0, sumR = 0.0
    for i in 0..<n {
        let a = Double(abs(L[i])), b = Double(abs(R[i]))
        peak = max(peak, a, b)
        if a >= 0.999 { clipped += 1 }; if b >= 0.999 { clipped += 1 }
        sumL += Double(L[i]); sumR += Double(R[i])
    }
    let dc = max(abs(sumL / Double(n)), abs(sumR / Double(n)))

    // BS.1770-4 K-weighting at 48 kHz, 400 ms blocks with 75 % overlap, gates −70 LUFS / −10 LU.
    func kw() -> (Biquad, Biquad) {
        (Biquad(b0: 1.53512485958697, b1: -2.69169618940638, b2: 1.19839281085285, a1: -1.69065929318241, a2: 0.73248077421585),
         Biquad(b0: 1, b1: -2, b2: 1, a1: -1.99004745483398, a2: 0.99007225036621))
    }
    var (l1, l2) = kw(), (r1, r2) = kw()
    var zl = [Double](repeating: 0, count: n), zr = zl
    for i in 0..<n {
        let a = l2.run(l1.run(Double(L[i]))), b = r2.run(r1.run(Double(R[i])))
        zl[i] = a * a; zr[i] = b * b
    }
    let block = Int(0.4 * fs), hop = Int(0.1 * fs)
    var blocks: [Double] = []
    var note = ""
    if n < block {
        blocks = [(zl.reduce(0, +) + zr.reduce(0, +)) / Double(n)]
        note = "short"
    } else {
        var i = 0
        while i + block <= n {
            var s = 0.0
            for k in i..<(i + block) { s += zl[k] + zr[k] }
            blocks.append(s / Double(block)); i += hop
        }
    }
    func lk(_ p: Double) -> Double { p > 0 ? -0.691 + 10 * log10(p) : -200 }
    let momentaryMax = blocks.map(lk).max() ?? -200
    let abs1 = blocks.filter { lk($0) > -70 }
    var lufs = -200.0
    if !abs1.isEmpty {
        let rel = lk(abs1.reduce(0, +) / Double(abs1.count)) - 10
        let g = abs1.filter { lk($0) > rel }
        lufs = lk(g.reduce(0, +) / Double(max(1, g.count)))
    }

    // Spectrum: Hann 4096, hop 2048, mono mix.
    let N = 4096
    var power = [Double](repeating: 0, count: N / 2)
    var start = 0
    while start + N <= n {
        var re = [Double](repeating: 0, count: N), im = re
        for k in 0..<N {
            let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(k) / Double(N - 1))
            re[k] = 0.5 * Double(L[start + k] + R[start + k]) * w
        }
        fft(&re, &im)
        for k in 0..<N / 2 { power[k] += re[k] * re[k] + im[k] * im[k] }
        start += N / 2
    }
    var tot = 0.0, wsum = 0.0, hf = 0.0
    for k in 1..<N / 2 {
        let f = Double(k) * fs / Double(N)
        tot += power[k]; wsum += f * power[k]
        if f > 6000 { hf += power[k] }
    }
    let centroid = tot > 0 ? wsum / tot : 0
    let hfDB = tot > 0 && hf > 0 ? 10 * log10(hf / tot) : -200

    // Clicks: 4th difference (gain ≈ (2 sin(πf/fs))^4: 8e-4 at 1.3 kHz, 4 at 12 kHz).
    var maxD = 0.0, maxAt = 0
    var d4 = [Double](repeating: 0, count: n)
    for ch in [L, R] {
        if n < 5 { break }
        for i in 4..<n {
            let v = abs(Double(ch[i]) - 4 * Double(ch[i - 1]) + 6 * Double(ch[i - 2]) - 4 * Double(ch[i - 3]) + Double(ch[i - 4]))
            d4[i] = max(d4[i], v)
            if v > maxD { maxD = v; maxAt = i }
        }
    }
    // Sound region: first and last sample above −90 dBFS.
    let thr = Float(SynthMath.dB(-90))
    let firstIdx = (0..<n).first { abs(L[$0]) > thr || abs(R[$0]) > thr } ?? 0
    let lastIdx = (0..<n).last { abs(L[$0]) > thr || abs(R[$0]) > thr } ?? (n - 1)
    let edge = Int(0.02 * fs)
    var edgeMax = 0.0
    for i in max(0, firstIdx - 4)..<min(n, firstIdx + edge) { edgeMax = max(edgeMax, d4[i]) }
    for i in max(0, lastIdx - edge)..<min(n, lastIdx + 5) { edgeMax = max(edgeMax, d4[i]) }
    let tailN = Int(0.01 * fs)
    var tail = 0.0
    for i in (n - tailN)..<n { tail += Double(L[i] * L[i] + R[i] * R[i]) }
    let p = max(peak, 1e-12)
    let w = Int(0.01 * fs)
    var aStart = 0.0, aEnd = 0.0, seen = false, e40 = 0.0
    var i0 = 0
    while i0 + w <= n {
        var e = 0.0
        for i in i0..<(i0 + w) { e += Double(L[i] * L[i] + R[i] * R[i]) }
        let r = (e / Double(2 * w)).squareRoot() * 1.41421356
        if r > p * SynthMath.dB(-60) { if !seen { aStart = Double(i0) / fs; seen = true }; aEnd = Double(i0 + w) / fs }
        if r > p * SynthMath.dB(-40) { e40 = Double(i0 + w) / fs }
        i0 += w
    }
    return Report(file: file, duration: Double(n) / fs, peakDB: SynthMath.toDB(peak), lufs: lufs, lufsNote: note, momentaryMax: momentaryMax,
                  clipped: clipped, dcDB: SynthMath.toDB(dc), centroid: centroid, hf6kDB: hfDB,
                  firstSampleDB: SynthMath.toDB(Double(max(abs(L[0]), abs(R[0])))),
                  lastSampleDB: SynthMath.toDB(Double(max(abs(L[n - 1]), abs(R[n - 1])))),
                  tailDB: SynthMath.toDB((tail / Double(2 * tailN)).squareRoot()),
                  clickDB: SynthMath.toDB(maxD / p), clickAt: Double(maxAt) / fs, edgeClickDB: SynthMath.toDB(edgeMax / p), audibleStart: aStart, audibleEnd: aEnd,
                  end40: e40, lapMomentaryMax: momentaryLoudnessMax(L, R, fs: fs, laptop: true))
}

/// Reads a 32-bit float stereo WAV written by `writeWAV` (the prototype's format).
func readWAV(_ path: String) -> ([Float], [Float])? {
    guard let d = FileManager.default.contents(atPath: path) else { return nil }
    let bytes = [UInt8](d)
    guard let r = (0..<(bytes.count - 4)).first(where: { bytes[$0] == 0x64 && bytes[$0 + 1] == 0x61 && bytes[$0 + 2] == 0x74 && bytes[$0 + 3] == 0x61 }) else { return nil }
    let start = r + 8
    let n = (bytes.count - start) / 8
    var L = [Float](repeating: 0, count: n), R = L
    bytes.withUnsafeBytes { raw in
        for i in 0..<n {
            L[i] = raw.loadUnaligned(fromByteOffset: start + 8 * i, as: Float.self)
            R[i] = raw.loadUnaligned(fromByteOffset: start + 8 * i + 4, as: Float.self)
        }
    }
    return (L, R)
}
