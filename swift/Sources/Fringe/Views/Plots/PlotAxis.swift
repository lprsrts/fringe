import CoreGraphics
import Foundation

struct PlotTick: Equatable, Sendable {
    var value: Double
    var label: String
}

/// Tick values for one axis: nice steps of 1, 2, 2.5 or 5 × 10ᵏ spaced by length.
/// y axes snap outward so the plot's top and bottom are tick values; x axes keep the data
/// domain (a detector from 0 to L, the λ range) and label only round values, adding an
/// exact end label only where it reads cleanly beside them.
struct PlotAxis: Sendable {
    enum Ends: Sendable { case snapOut, labelExact }

    var domain: ClosedRange<Double>
    /// Points available along the axis.
    var length: CGFloat
    /// Smallest distance between ticks in points.
    var minSpacing: CGFloat
    var ends: Ends
    /// The least span shown, so a nearly flat curve is not magnified (n of a glass).
    var minSpan: Double = 0
    /// Start at zero (k, |E|², powers).
    var fromZero = false
    /// x axes: label a non-round end exactly where it clears the round ticks (a detector's
    /// physical end), rather than leaving it to the frame (the λ range).
    var exactEnds = true

    struct Layout: Equatable, Sendable {
        /// The domain the scale maps (snapped out for y axes).
        var domain: ClosedRange<Double>
        var ticks: [PlotTick]
        /// Tick labels are value / 10^exponent; the title carries "(×10ⁿ)".
        var exponent: Int?
    }

    /// `measure` gives a label's width in points (for the end-collision rule).
    func layout(measure: (String) -> CGFloat = { _ in 0 }) -> Layout {
        var lo = domain.lowerBound, hi = domain.upperBound
        guard lo.isFinite, hi.isFinite else { return Layout(domain: 0...1, ticks: [], exponent: nil) }
        if fromZero { lo = min(0, lo); hi = max(0, hi) }
        // The ×10ⁿ form for very large or very small values.
        let magnitude = max(abs(lo), abs(hi))
        var exponent: Int?
        if magnitude >= 1e4 || (magnitude > 0 && magnitude < 1e-2) {
            exponent = Int(floor(log10(magnitude)))
        }
        let unit = exponent.map { pow(10, Double($0)) } ?? 1
        var scaled = PlotAxis(domain: (lo / unit)...(hi / unit), length: length, minSpacing: minSpacing, ends: ends,
                              minSpan: minSpan / unit, fromZero: fromZero, exactEnds: exactEnds)
        scaled.domain = (lo / unit)...(hi / unit)
        var out = scaled.layoutPlain(measure: measure)
        out.domain = (out.domain.lowerBound * unit)...(out.domain.upperBound * unit)
        out.ticks = out.ticks.map { PlotTick(value: $0.value * unit, label: $0.label) }
        out.exponent = exponent
        return out
    }

    private func layoutPlain(measure: (String) -> CGFloat) -> Layout {
        var lo = domain.lowerBound, hi = domain.upperBound
        // 1. Span, widened to minSpan about the middle, or made up for a flat curve.
        var span = hi - lo
        if span < minSpan {
            let mid = (lo + hi) / 2
            lo = mid - minSpan / 2
            hi = mid + minSpan / 2
            if fromZero, lo < 0, domain.lowerBound >= 0 { hi -= lo; lo = 0 }
            span = hi - lo
        }
        if span <= 0 {
            let pad = max(abs(lo) * 0.1, 1e-3) / 2
            lo -= pad; hi += pad
            if fromZero, lo < 0, domain.lowerBound >= 0 { hi -= lo; lo = 0 }
            span = hi - lo
        }
        // 2–3. The smallest nice step whose ticks are at least minSpacing apart.
        var step = Self.step(lo: lo, hi: hi, length: length, minSpacing: minSpacing, snap: ends == .snapOut)
        // A journal figure rarely needs more than seven intervals on an x axis: 0 1 2 3 4,
        // not 0 0.5 1.0 … 4.0 across a wide panel.
        if ends == .labelExact {
            while span / step > Self.maxIntervals + 1e-9 { step = Self.nextStep(after: step) }
            // Labels at least a gap apart (wide labels such as "0.25" need more than 44 pt
            // less often than "2" needs less).
            while true {
                let decimals = Self.decimals(of: step)
                let widest = Double(measure(Self.label(hi, decimals: decimals))) // the widest label is at an end
                if Double(length) / span * step - max(widest, Double(measure(Self.label(lo, decimals: decimals)))) >= 16 { break }
                step = Self.nextStep(after: step)
            }
        }
        let decimals = Self.decimals(of: step)
        switch ends {
        case .snapOut:
            let i0 = Int(floor(lo / step + 1e-9)), i1 = Int(ceil(hi / step - 1e-9))
            let ticks = (i0...max(i0, i1)).map { i -> PlotTick in
                let v = Double(i) * step
                return PlotTick(value: v, label: Self.label(v, decimals: decimals))
            }
            return Layout(domain: (Double(i0) * step)...(Double(max(i0 + 1, i1)) * step), ticks: ticks, exponent: nil)
        case .labelExact:
            // Only round values (multiples of the step) are labelled, all with the step's
            // decimals, so the labels are evenly spaced and read as one series: 0.5 1.0 1.5
            // 2.0, never 0.3 1.0 1.5 2.0. A round tick is never dropped to make room for an
            // end. An end that is not round (a detector's 4.37 µm or 37.5 µm) is labelled
            // exactly only when `exactEnds` is set, it lies at least 0.6 of a step from the
            // nearest round tick and its label clears that tick's label; otherwise the
            // frame's end stands for it.
            let scale = Double(length) / span
            func position(_ v: Double) -> Double { (v - lo) * scale }
            let pad: Double = 8
            var round: [PlotTick] = []
            let i0 = Int(ceil(lo / step - 1e-9)), i1 = Int(floor(hi / step + 1e-9))
            if i0 <= i1 {
                for i in i0...i1 {
                    let v = abs(Double(i) * step - lo) < step * 1e-9 ? lo : abs(Double(i) * step - hi) < step * 1e-9 ? hi : Double(i) * step
                    round.append(PlotTick(value: v, label: Self.label(v, decimals: decimals)))
                }
            }
            func endTick(_ v: Double) -> PlotTick? {
                guard !round.contains(where: { abs($0.value - v) < step * 1e-9 }) else { return nil }
                let label = Self.label(v, decimals: v == 0 ? 0 : max(decimals, Self.exactDecimals(v)))
                // Too few round ticks to read the axis by: the ends carry it.
                if round.count < 2 { return PlotTick(value: v, label: label) }
                guard exactEnds else { return nil }
                guard let near = round.min(by: { abs($0.value - v) < abs($1.value - v) }) else { return PlotTick(value: v, label: label) }
                guard abs(near.value - v) >= step * 0.6 - 1e-9 else { return nil }
                let gap = abs(position(near.value) - position(v)) - Double(measure(near.label) + measure(label)) / 2
                return gap >= pad ? PlotTick(value: v, label: label) : nil
            }
            var ticks = round
            if let t = endTick(lo) { ticks.insert(t, at: 0) }
            if let t = endTick(hi) { ticks.append(t) }
            return Layout(domain: lo...hi, ticks: ticks, exponent: nil)
        }
    }

    /// The smallest of {1, 2, 2.5, 5} × 10ᵏ whose ticks land at least `minSpacing` apart
    /// (after snapping out, for y axes). 2.5 only where it adds no decimal (25, 250, …).
    static func step(lo: Double, hi: Double, length: CGFloat, minSpacing: CGFloat, snap: Bool) -> Double {
        let span = hi - lo
        let target = max(1, floor(Double(length / max(1, minSpacing))))
        var mag = pow(10, floor(log10(span / target))) / 10
        for _ in 0..<6 {
            for m in [1.0, 2, 2.5, 5] {
                if m == 2.5 && mag < 10 { continue }
                let step = m * mag
                let intervals = snap ? ceil(hi / step - 1e-9) - floor(lo / step + 1e-9) : span / step
                if intervals >= 1, Double(length) / intervals >= Double(minSpacing) { return step }
                if intervals < 1 { return step }
            }
            mag *= 10
        }
        return mag
    }

    static let maxIntervals = 7.0

    /// The next nice step up: 1 → 2 → 5 → 10 (2.5 only from 25 up).
    static func nextStep(after step: Double) -> Double {
        let mag = pow(10, floor(log10(step) + 1e-9))
        let m = (step / mag).rounded()
        switch m {
        case ..<2: return 2 * mag
        case ..<5: return mag >= 10 && m < 2.5 ? 2.5 * mag : 5 * mag
        default: return 10 * mag
        }
    }

    /// Decimals a step needs: 0.5 → 1, 0.05 → 2, 5 → 0.
    static func decimals(of step: Double) -> Int {
        for d in 0...6 {
            let scaled = step * pow(10, Double(d))
            if abs(scaled - scaled.rounded()) < 1e-6 * max(1, scaled) { return d }
        }
        return 6
    }

    /// Decimals to print `v` rounded to 3 significant digits, at most 3: 4.37 → 2, 2 → 0.
    static func exactDecimals(_ v: Double) -> Int {
        guard v != 0, v.isFinite else { return 0 }
        let digits = 3 - Int(floor(log10(abs(v)))) - 1
        let rounded = (v * pow(10, Double(digits))).rounded() / pow(10, Double(digits))
        for d in 0...3 {
            let s = rounded * pow(10, Double(d))
            if abs(s - s.rounded()) < 1e-6 * max(1, abs(s)) { return d }
        }
        return 3
    }

    /// "0", never "−0" or "0.0"; U+2212 for negatives.
    static func label(_ v: Double, decimals: Int) -> String {
        if abs(v) < 1e-12 { return "0" }
        return Format.number(v, digits: decimals...decimals)
    }

    /// "×10⁻³" for an exponent.
    static func exponentLabel(_ e: Int) -> String {
        let digits: [Character] = ["⁰", "¹", "²", "³", "⁴", "⁵", "⁶", "⁷", "⁸", "⁹"]
        return "×10" + (e < 0 ? "⁻" : "") + String(String(abs(e)).map { digits[Int(String($0))!] })
    }
}

/// A linear map from a domain to a span of points (top-down for y).
struct PlotScale: Sendable {
    var domain: ClosedRange<Double>
    var range: ClosedRange<CGFloat>
    var flipped = false

    func callAsFunction(_ v: Double) -> CGFloat {
        let span = domain.upperBound - domain.lowerBound
        let t = span > 0 ? (v - domain.lowerBound) / span : 0.5
        let t2 = flipped ? 1 - t : t
        return range.lowerBound + CGFloat(t2) * (range.upperBound - range.lowerBound)
    }

    func invert(_ p: CGFloat) -> Double {
        let w = range.upperBound - range.lowerBound
        var t = w > 0 ? Double((p - range.lowerBound) / w) : 0
        if flipped { t = 1 - t }
        return domain.lowerBound + t * (domain.upperBound - domain.lowerBound)
    }
}
