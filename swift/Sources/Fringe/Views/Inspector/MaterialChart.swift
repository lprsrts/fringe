import SwiftUI

/// n and k of a material over wavelength as two stacked panels sharing the λ axis, each
/// on its own scale (gold's k runs to 12, its n stays under 2), with a rule at the scene
/// wavelength through both. A lossless model shows the n panel only; a model that is the
/// same at every wavelength gets no plot. The preset's fitted range is noted, and shaded
/// where the plot runs outside it.
struct MaterialChart: View {
    let curve: MaterialCurve
    let lambda0: Double
    /// Where the preset's fit holds; nil for a custom or edited model.
    var validRange: ClosedRange<Double>?
    var materialName: String?
    /// The harness's hover override.
    var hoverX: Double?

    static let panelHeight: CGFloat = 84
    /// Below this k is drawn as zero and the k panel is left out.
    static let losslessK = 1e-4

    var body: some View {
        let _ = PerfProbe.body("MaterialChart")
        if Self.isConstant(curve) {
            Text("The same at every wavelength.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            PlotFigure(spec: spec, hoverX: hoverX, accessibility: accessibility)
        }
    }

    /// n and k do not change over the plotted range.
    static func isConstant(_ curve: MaterialCurve) -> Bool {
        func flat(_ v: [Double]) -> Bool {
            let f = v.filter(\.isFinite)
            guard let lo = f.min(), let hi = f.max() else { return true }
            return hi - lo < 1e-6
        }
        return flat(curve.n) && flat(curve.k)
    }

    private var domain: ClosedRange<Double> {
        let lo = curve.wavelengthUm.first ?? 0.3, hi = curve.wavelengthUm.last ?? 2
        return lo...max(hi, lo + 1e-6)
    }

    private var hasK: Bool { (curve.k.filter(\.isFinite).max() ?? 0) >= Self.losslessK }

    var spec: PlotSpec {
        let poles = Self.poles(curve)
        let n = Self.cut(curve.wavelengthUm, curve.n, at: poles), k = Self.cut(curve.wavelengthUm, curve.k, at: poles)
        // Near a pole the scale is set away from it, but always takes in the value at λ0, so
        // the λ0 marker is on the plot whatever the samples do.
        let nRange = Self.including(Self.rangeAwayFrom(poles, curve.wavelengthUm, curve.n), curve.at?.n, lambda0: lambda0, domain: domain)
        let kRange = Self.including(Self.rangeAwayFrom(poles, curve.wavelengthUm, curve.k), curve.at?.k, lambda0: lambda0, domain: domain)
        var panels = [PlotPanel(label: "$n$", series: [PlotSeries(name: "$n$", x: n.x, y: n.y, labelled: false)],
                                minSpan: 0.1, height: Self.panelHeight, dataRange: nRange)]
        var notes: [String] = []
        if hasK {
            panels.append(PlotPanel(label: "$k$", series: [PlotSeries(name: "$k$", x: k.x, y: k.y, labelled: false)],
                                    fromZero: true, height: Self.panelHeight, dataRange: kRange))
        } else {
            notes.append("$k$ < 10⁻⁴ over this range (lossless)")
        }
        var rules = [PlotRule(x: lambda0, label: #"$\lambda_0$ = "# + Self.wavelength(lambda0),
                              exact: curve.at.map { ["$n$": $0.n, "$k$": $0.k] } ?? [:])]
        if !poles.isEmpty {
            rules += poles.map { PlotRule(x: $0, markers: false, style: .pole) }
            let at = poles.map { Self.exact($0) }.joined(separator: ", ")
            notes.append(poles.count == 1 ? "Dotted: undamped resonance at \(at) µm" : "Dotted: undamped resonances at \(at) µm")
        }
        var bands: [PlotBand] = []
        if let fit = validRange {
            let range = "\(Self.exact(fit.lowerBound))–\(Self.exact(fit.upperBound)) µm"
            if fit.lowerBound > domain.lowerBound { bands.append(PlotBand(x: domain.lowerBound...min(fit.lowerBound, domain.upperBound))) }
            if fit.upperBound < domain.upperBound { bands.append(PlotBand(x: max(fit.upperBound, domain.lowerBound)...domain.upperBound)) }
            if !fit.contains(lambda0) {
                notes.append(#"$\lambda_0$ is outside the fitted range (\#(range))"#)
            } else if !bands.isEmpty {
                notes.append("Shaded: outside the fitted range (\(range))")
            } else {
                notes.append("Fitted \(range)")
            }
        }
        return PlotSpec(
            // The λ range starts and stops where the sampling does (0.3 µm): only round
            // wavelengths are labelled, so the axis reads 0.5 1.0 1.5 2.0 or 2 4 … 12.
            x: PlotXAxis(title: #"$\lambda$ (µm)"#, unit: "µm", domain: domain, exactEnds: false),
            panels: panels,
            rules: rules,
            bands: bands,
            notes: notes
        )
    }

    // MARK: Poles

    /// Where an undamped resonance sits between two samples: ε′ swings from a large value
    /// to a large value of the other sign in one step (a smooth zero crossing, as at a
    /// metal's plasma edge, passes through small values) and ε″ is zero on both sides. A
    /// damped resonance is never cut: `sample` resolves its peak instead. The place is
    /// where 1/ε′ crosses zero, which is linear in λ near the pole.
    static func poles(_ c: MaterialCurve) -> [Double] {
        let finite = c.eps1.indices.filter { c.eps1[$0].isFinite && c.wavelengthUm[$0].isFinite }
        var out: [Double] = []
        for (j, l) in zip(finite, finite.dropFirst()) where l - j <= 2 {
            let a = c.eps1[j], b = c.eps1[l]
            guard isJump(a, b), isLossless(c, j), isLossless(c, l) else { continue }
            let u = 1 / a, v = 1 / b
            let t = u / (u - v)
            out.append(c.wavelengthUm[j] + t * (c.wavelengthUm[l] - c.wavelengthUm[j]))
        }
        return out
    }

    /// ε′ changes sign between two large values in one step.
    static func isJump(_ a: Double, _ b: Double) -> Bool {
        a * b < 0 && min(abs(a), abs(b)) > 1.5
    }

    /// ε″ is zero at sample `i`, to rounding.
    static func isLossless(_ c: MaterialCurve, _ i: Int) -> Bool {
        let e2 = c.eps2[i]
        return e2.isFinite && abs(e2) <= 1e-9 * max(1, abs(c.eps1[i]))
    }

    /// The chart's curve for a material: evenly spaced samples over `range(lambda0:)`, with
    /// extra samples wherever a narrow damped resonance falls between two of them (ε′
    /// jumping sign with loss, or k peaking well above both neighbours), so its absorption
    /// peak is drawn at its height rather than as a stub. Up to three rounds, each 40 times
    /// finer, which resolves a linewidth down to about 10⁻⁶ of the range.
    static func sample(_ material: Material, lambda0: Double) -> MaterialCurve? {
        guard var c = FringeBridge.materialCurve(material, range: range(lambda0: lambda0),
                                                 count: MaterialCurveCache.pointCount, lambda0: lambda0) else { return nil }
        for _ in 0..<3 {
            var spans: [ClosedRange<Double>] = []
            let x = c.wavelengthUm
            for i in 0..<(x.count - 1) {
                let a = c.eps1[i], b = c.eps1[i + 1]
                guard a.isFinite, b.isFinite else { continue }
                let damped = isJump(a, b) && !(isLossless(c, i) && isLossless(c, i + 1))
                let peak = i > 0 && c.k[i].isFinite && c.k[i] > 0.05 && c.k[i] > 3 * max(c.k[i - 1], c.k[i + 1])
                if damped { spans.append(x[i]...x[i + 1]) }
                if peak { spans.append(x[i - 1]...x[i + 1]) }
            }
            guard !spans.isEmpty, spans.count <= 8 else { break }
            var extra: [Double] = []
            for s in spans {
                let m = 40
                extra += (1..<m).map { s.lowerBound + (s.upperBound - s.lowerBound) * Double($0) / Double(m) }
            }
            guard let values = FringeBridge.evaluate(material, wavelengthsUm: extra) else { break }
            var merged = zip(x, (0..<x.count).map { EffectiveIndex(n: c.n[$0], k: c.k[$0], eps1: c.eps1[$0], eps2: c.eps2[$0]) }).map { ($0, $1) }
            merged += zip(extra, values).map { ($0, $1) }
            merged.sort { $0.0 < $1.0 }
            merged = merged.enumerated().filter { i, e in i == 0 || e.0 - merged[i - 1].0 > 1e-12 }.map(\.element)
            c = MaterialCurve(wavelengthUm: merged.map(\.0), n: merged.map(\.1.n), k: merged.map(\.1.k),
                              eps1: merged.map(\.1.eps1), eps2: merged.map(\.1.eps2), at: c.at)
        }
        return c
    }

    /// `range` widened to take in `value` when λ0 is on the plot; nil stays nil (the
    /// panel then spans all its data, λ0's value among it).
    static func including(_ range: ClosedRange<Double>?, _ value: Double?, lambda0: Double, domain: ClosedRange<Double>) -> ClosedRange<Double>? {
        guard let range, let value, value.isFinite, domain.contains(lambda0) else { return range }
        return min(range.lowerBound, value)...max(range.upperBound, value)
    }

    /// The samples with a break (NaN) at each pole, so no line is drawn across it.
    static func cut(_ x: [Double], _ y: [Double], at poles: [Double]) -> (x: [Double], y: [Double]) {
        guard !poles.isEmpty else { return (x, y) }
        var xs: [Double] = [], ys: [Double] = []
        var remaining = poles.sorted()[...]
        for (xv, yv) in zip(x, y) {
            while let p = remaining.first, p < xv {
                xs.append(p); ys.append(.nan)
                remaining = remaining.dropFirst()
            }
            xs.append(xv); ys.append(yv)
        }
        return (xs, ys)
    }

    /// The y range of the samples more than 3 % of the plotted span from every pole, so
    /// the axis is set by the material and not by how close a sample lands to the pole;
    /// nil without poles.
    static func rangeAwayFrom(_ poles: [Double], _ x: [Double], _ y: [Double]) -> ClosedRange<Double>? {
        guard !poles.isEmpty, let lo = x.first, let hi = x.last else { return nil }
        let window = (hi - lo) * 0.03
        let kept = zip(x, y).filter { xv, yv in yv.isFinite && poles.allSatisfy { abs($0 - xv) > window } }.map(\.1)
        guard let min = kept.min(), let max = kept.max() else { return nil }
        return min...max
    }

    private var accessibility: PlotAccessibility {
        let name = materialName.map { " of \($0)" } ?? ""
        func from(_ v: [Double]) -> String {
            "from \(Format.significant(v.first ?? .nan, digits: 2)) to \(Format.significant(v.last ?? .nan, digits: 2))"
        }
        let k = hasK ? ", k \(from(curve.k))" : ", k under 10⁻⁴"
        var series = [PlotSeries(name: "n", x: curve.wavelengthUm, y: curve.n)]
        if hasK { series.append(PlotSeries(name: "k", x: curve.wavelengthUm, y: curve.k)) }
        return PlotAccessibility(
            title: "Refractive index\(name)",
            summary: "n \(from(curve.n))\(k) over \(Self.exact(domain.lowerBound)) to \(Self.exact(domain.upperBound)) µm",
            xTitle: "Wavelength", xUnit: "µm", yTitle: "n, k", series: series
        )
    }

    /// The scene wavelength as the chart and the value row under it both print it: in nm
    /// as everywhere else in the app ("550 nm", "1064 nm"), in µm from 2 µm up ("10 µm").
    static func wavelength(_ um: Double) -> String {
        um < 2 ? Format.wavelength(um) : "\(Format.number(um, digits: 0...2)) µm"
    }

    /// A wavelength as given, to 3 significant digits: 0.55, 0.633, 2.
    static func exact(_ v: Double) -> String {
        let d = PlotAxis.exactDecimals(v)
        return Format.number(v, digits: d...d)
    }

    /// The plotted range: 0.3–2 µm, widened to take in the scene wavelength, with the ends
    /// on round values (0.1 µm below 1 µm, whole µm above 2) so the axis ends read cleanly.
    static func range(lambda0: Double) -> ClosedRange<Double> {
        var lo = 0.3
        if 0.8 * lambda0 < lo {
            lo = floor(0.8 * lambda0 * 10) / 10
            if lo <= 0 { lo = max(0.01, floor(0.8 * lambda0 * 100) / 100) }
        }
        let hi = 1.2 * lambda0 > 2 ? ceil(1.2 * lambda0) : 2
        return lo...hi
    }
}

/// Material curves for the chart, keyed by the material's JSON and λ0. Computing one is a
/// single core call, well under a millisecond; the cache spares it on every redraw.
@MainActor
final class MaterialCurveCache {
    static let shared = MaterialCurveCache()
    static let pointCount = 171

    private var entries: [String: MaterialCurve] = [:]
    private var order: [String] = []
    private let capacity = 32

    func curve(for material: Material, lambda0: Double) -> MaterialCurve? {
        guard !material.isPEC, let json = try? FringeBridge.encode(material) else { return nil }
        let key = "\(json)|\(lambda0)"
        if let hit = entries[key] { return hit }
        guard let curve = MaterialChart.sample(material, lambda0: lambda0) else { return nil }
        entries[key] = curve
        order.append(key)
        if order.count > capacity {
            entries[order.removeFirst()] = nil
        }
        return curve
    }
}
