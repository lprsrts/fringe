import SwiftUI

// The puzzle result plots, on the plot layer's look (PlotStyle): thin ink, L-axes with
// short ticks, a hairline grid, values printed where they are, no legend. Pass and fail are
// SF Symbols with words for VoiceOver, never a bar colour.
//
// - PuzzleBarChart: one bar per input case (truth tables, one panel per output) or per goal
//   detector, with the contrast gap, the pass rule or the aim of a split.
// - PuzzleContrastPlot: every case of each output on one value axis, the 0-cases and the
//   1-cases as two bands with the gap (or overlap) between them.
// - ScoreBar: the score on a track with the pass level and the three star thresholds.

/// Pixel-snapped hairlines and typeset text on a `Canvas`, the way `PlotFigure` draws.
struct PlotPen {
    var context: GraphicsContext
    let scale: CGFloat
    var hair: CGFloat { 1 / scale }

    /// A hairline's centre on the pixel grid.
    func snap(_ v: CGFloat) -> CGFloat { (floor(v * scale) + 0.5) / scale }

    func line(_ a: CGPoint, _ b: CGPoint, _ color: Color, width: CGFloat? = nil, dash: [CGFloat] = []) {
        var p = Path()
        p.move(to: a)
        p.addLine(to: b)
        context.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width ?? hair, dash: dash))
    }

    func text(_ source: String, size: CGFloat = PlotStyle.tickSize, weight: Font.Weight = .regular, color: Color) -> GraphicsContext.ResolvedText {
        context.resolve(Text(MathTypesetter.styled(source, pointSize: size)).font(.system(size: size, weight: weight).monospacedDigit()).foregroundStyle(color))
    }

    func width(_ t: GraphicsContext.ResolvedText) -> CGFloat {
        t.measure(in: CGSize(width: 1000, height: 100)).width
    }

    func draw(_ t: GraphicsContext.ResolvedText, at p: CGPoint, anchor: UnitPoint) {
        context.draw(t, at: p, anchor: anchor)
    }

    /// A pass or fail symbol, `size` points across, centred on `p`.
    func verdict(_ passes: Bool, at p: CGPoint, size: CGFloat = 11) {
        var image = context.resolve(Image(systemName: passes ? "checkmark.circle.fill" : "xmark.circle.fill"))
        image.shading = .color(passes ? .green : .red)
        context.draw(image, in: CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size))
    }

    /// The y axis of a value plot: grid at the ticks, the L-axis, ticks and labels.
    func valueAxis(_ layout: PlotAxis.Layout, scale y: PlotScale, plot r: CGRect, palette: PlotStyle.Palette) {
        for tick in layout.ticks where tick.value > layout.domain.lowerBound + 1e-12 {
            let yy = snap(y(tick.value))
            line(CGPoint(x: r.minX, y: yy), CGPoint(x: r.maxX, y: yy), palette.grid)
        }
        let ax = snap(r.minX) - hair, ay = snap(r.maxY)
        line(CGPoint(x: ax, y: r.minY), CGPoint(x: ax, y: ay + hair / 2), palette.frame)
        line(CGPoint(x: ax - hair / 2, y: ay), CGPoint(x: r.maxX, y: ay), palette.frame)
        for tick in layout.ticks {
            let yy = snap(y(tick.value))
            line(CGPoint(x: ax - PlotStyle.tickLength, y: yy), CGPoint(x: ax, y: yy), palette.frame)
            draw(text(tick.label, color: palette.textSecondary), at: CGPoint(x: ax - PlotStyle.tickLength - PlotStyle.labelGap, y: y(tick.value)), anchor: .trailing)
        }
    }
}

// MARK: - Bars

struct PuzzleBarSpec: Equatable {
    struct Bar: Equatable {
        /// "$A$ 0 $B$ 1" or a detector name.
        var label: String
        /// "should be 1", as the contrast plot says it.
        var sublabel: String?
        var value: Double?
        var passes: Bool?
        /// A split's aim for this bar, in plotted units.
        var aim: Double?
        /// The case the canvas shows.
        var isShown = false
    }

    struct Rule: Equatable {
        var value: Double
        var label: String
    }

    struct Panel: Equatable {
        /// The output's name when there are several.
        var name: String?
        var bars: [Bar]
        /// Between the strongest 0 and the weakest 1 (or their overlap).
        var gap: ClosedRange<Double>?
        var gapLabel: String?
        var rules: [Rule] = []
    }

    /// Over the value axis, with math.
    var yTitle: String
    var style: PuzzleReport.ValueStyle
    var panels: [Panel]
    var dimmed = false
    var note: String?

    /// A value as the bars plot it: percent styles in percent.
    func plotted(_ v: Double) -> Double { style == .percent ? v * 100 : v }
}

/// One bar per case or per detector, values printed over the bars.
struct PuzzleBarChart: View {
    let spec: PuzzleBarSpec
    @Environment(\.colorScheme) private var scheme
    @Environment(\.plotSurface) private var surface
    @Environment(\.displayScale) private var displayScale

    static let barWidth: CGFloat = 18
    static let labelRows: CGFloat = 15

    var body: some View {
        let _ = PerfProbe.body("PuzzleBarChart")
        Canvas { context, size in
            draw(size: size, palette: PlotStyle.Palette(scheme, surface: surface), in: context)
        }
        .frame(minHeight: CGFloat(spec.panels.count) * 64 + 60)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MathTypesetter.plain(spec.yTitle))
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        spec.panels.map { panel in
            let bars = panel.bars.map { bar in
                var s = "\(MathTypesetter.plain(bar.label)) \(spec.style.format(bar.value))"
                if let passes = bar.passes, !spec.dimmed { s += passes ? ", passes" : ", fails" }
                return s
            }.joined(separator: "; ")
            return (panel.name.map { "\($0): " } ?? "") + bars
        }.joined(separator: ". ")
    }

    private func draw(size: CGSize, palette: PlotStyle.Palette, in context: GraphicsContext) {
        let pen = PlotPen(context: context, scale: max(1, displayScale))
        let hasSub = spec.panels.contains { $0.bars.contains { $0.sublabel != nil } }
        let hasVerdicts = !spec.dimmed && spec.panels.contains { $0.bars.contains { $0.passes != nil } }
        let bottom = PlotStyle.tickLength + Self.labelRows * (hasSub ? 2 : 1) + (hasVerdicts ? 16 : 0)
            + (spec.note == nil ? 0 : PlotStyle.noteRow)
        let n = CGFloat(spec.panels.count)
        let plotHeight = max(30, (size.height - bottom - n * PlotStyle.titleRow - (n - 1) * PlotStyle.panelGap) / n)

        // y layouts, and one left gutter for every panel.
        let layouts: [PlotAxis.Layout] = spec.panels.map { panel in
            var hi = panel.bars.compactMap { $0.value.map(spec.plotted) }.max() ?? 0
            hi = max(hi, panel.gap.map { spec.plotted($0.upperBound) } ?? 0)
            hi = max(hi, panel.rules.map(\.value).max() ?? 0, panel.bars.compactMap(\.aim).max() ?? 0)
            return PlotAxis(domain: 0...max(hi, 1e-9), length: plotHeight, minSpacing: 20, ends: .snapOut, fromZero: true).layout()
        }
        let widest = layouts.flatMap(\.ticks).map { PlotFrame.measureTick($0.label) }.max() ?? 0
        let left = max(30, ceil(widest + PlotStyle.tickLength + PlotStyle.labelGap + 2))
        let right: CGFloat = 8
        let plotWidth = max(40, size.width - left - right)
        let count = max(1, spec.panels.map(\.bars.count).max() ?? 1)
        let slot = plotWidth / CGFloat(count)
        let barWidth = min(Self.barWidth, slot * 0.6)
        let marks = spec.dimmed ? 0.45 : 1.0

        var top: CGFloat = 0
        for (i, panel) in spec.panels.enumerated() {
            top += (i > 0 ? PlotStyle.panelGap : 0) + PlotStyle.titleRow
            let r = CGRect(x: left, y: top, width: plotWidth, height: plotHeight)
            top += plotHeight
            let layout = layouts[i]
            let y = PlotScale(domain: layout.domain, range: r.minY...r.maxY, flipped: true)
            func cx(_ k: Int) -> CGFloat { r.minX + slot * (CGFloat(k) + 0.5) }

            // Title row: the output's name, then (first panel) the value axis title.
            drawTitle(name: panel.name, first: i == 0, at: CGPoint(x: 0, y: r.minY - 7), pen: pen, palette: palette)

            // The shown case: a faint column behind its bar.
            for (k, bar) in panel.bars.enumerated() where bar.isShown {
                let col = CGRect(x: cx(k) - slot / 2 + 2, y: r.minY, width: slot - 4, height: r.height)
                context.fill(Path(roundedRect: col, cornerRadius: 3), with: .color(palette.text.opacity(0.06)))
            }
            // The gap between the 0s and the 1s.
            if let gap = panel.gap {
                let y0 = y(spec.plotted(gap.upperBound)), y1 = y(spec.plotted(gap.lowerBound))
                let band = CGRect(x: r.minX, y: y0, width: r.width, height: max(0, y1 - y0))
                context.fill(Path(band), with: .color(PlotStyle.gapFill(palette)))
                for edge in [y0, y1] {
                    let e = pen.snap(edge)
                    pen.line(CGPoint(x: r.minX, y: e), CGPoint(x: r.maxX, y: e), palette.frame, dash: [2, 2])
                }
            }
            pen.valueAxis(layout, scale: y, plot: r, palette: palette)

            // Bars: 3 pt round top, square at the baseline.
            var barContext = context
            barContext.opacity = marks
            // What the gap label must stay clear of: bars, their values and the aim word.
            var occupied: [CGRect] = []
            for (k, bar) in panel.bars.enumerated() {
                guard let v = bar.value, v.isFinite else { continue }
                let h = max(0, r.maxY - y(spec.plotted(v)))
                let rect = CGRect(x: cx(k) - barWidth / 2, y: r.maxY - h, width: barWidth, height: h)
                let shape = UnevenRoundedRectangle(topLeadingRadius: min(3, h), topTrailingRadius: min(3, h)).path(in: rect)
                barContext.fill(shape, with: .color(palette.ink))
                occupied.append(rect.insetBy(dx: -3, dy: 0))
                // The value over the bar when it fits the slot.
                let label = pen.text(spec.style.format(v), color: palette.textSecondary)
                if pen.width(label) + 4 <= slot {
                    let w = pen.width(label)
                    occupied.append(CGRect(x: cx(k) - w / 2 - 3, y: r.maxY - h - 2 - 14, width: w + 6, height: 14))
                    var c = context
                    c.opacity = marks
                    c.draw(label, at: CGPoint(x: cx(k), y: r.maxY - h - 2), anchor: .bottom)
                }
                if let aim = bar.aim {
                    let a = pen.snap(y(aim))
                    var p = Path()
                    p.move(to: CGPoint(x: cx(k) - slot * 0.4, y: a))
                    p.addLine(to: CGPoint(x: cx(k) + slot * 0.4, y: a))
                    context.stroke(p, with: .color(palette.reference), style: PlotStyle.reference)
                }
            }
            if panel.bars.contains(where: { $0.aim != nil }), let k = panel.bars.lastIndex(where: { $0.aim != nil }), let aim = panel.bars[k].aim {
                pen.draw(pen.text("aim", color: palette.textSecondary), at: CGPoint(x: cx(k) + slot * 0.4 + 3, y: y(aim)), anchor: .leading)
            }
            // Rules (the pass level), labelled at the right end over the line.
            for rule in panel.rules {
                let yy = pen.snap(y(rule.value))
                pen.line(CGPoint(x: r.minX, y: yy), CGPoint(x: r.maxX, y: yy), palette.reference)
                let rt = pen.text(rule.label, color: palette.textSecondary)
                pen.draw(rt, at: CGPoint(x: r.maxX - 2, y: yy - 2), anchor: .bottomTrailing)
                occupied.append(CGRect(x: r.maxX - 4 - pen.width(rt), y: yy - 16, width: pen.width(rt) + 4, height: 14))
            }
            if let gap = panel.gap, let label = panel.gapLabel {
                let t = pen.text(label, color: palette.textSecondary)
                let w = pen.width(t), th: CGFloat = 13
                let top = y(spec.plotted(gap.upperBound)), bottom = y(spec.plotted(gap.lowerBound))
                // The first place clear of the bars and their values: inside the band when it
                // is tall enough, else just over it, at the right end or between two bars;
                // failing all, in the panel's title row at the right.
                let rows: [CGFloat] = bottom - top >= th + 2 ? [(top + bottom) / 2 - th / 2] : [top - 2 - th]
                var xs: [CGFloat] = [r.maxX - 2 - w]
                for k in stride(from: count - 1, through: 1, by: -1) { xs.append(r.minX + slot * CGFloat(k) - w / 2) }
                let spot = rows.lazy.flatMap { yy in xs.lazy.map { CGRect(x: $0, y: yy, width: w, height: th) } }
                    .first { c in c.minX >= r.minX + 2 && c.minY >= r.minY && !occupied.contains { $0.intersects(c) } }
                if let spot {
                    pen.draw(t, at: CGPoint(x: spot.minX, y: spot.midY), anchor: .leading)
                } else {
                    pen.draw(t, at: CGPoint(x: r.maxX - 2, y: r.minY - 7), anchor: .bottomTrailing)
                }
            }
            // Category rows under the last panel only.
            if i == spec.panels.count - 1 {
                var row = r.maxY + PlotStyle.tickLength + 1
                for (k, bar) in panel.bars.enumerated() {
                    let t = pen.text(bar.label, weight: bar.isShown ? .semibold : .regular, color: bar.isShown ? palette.text : palette.textSecondary)
                    pen.draw(t, at: CGPoint(x: cx(k), y: row), anchor: .top)
                }
                row += Self.labelRows
                if hasSub {
                    for (k, bar) in panel.bars.enumerated() {
                        if let sub = bar.sublabel {
                            pen.draw(pen.text(sub, color: palette.textSecondary), at: CGPoint(x: cx(k), y: row), anchor: .top)
                        }
                    }
                    row += Self.labelRows
                }
                if hasVerdicts {
                    // Every panel's verdict for the case: it passes only if all outputs do.
                    for k in 0..<count {
                        let verdicts = spec.panels.compactMap { $0.bars.indices.contains(k) ? $0.bars[k].passes : nil }
                        guard !verdicts.isEmpty else { continue }
                        pen.verdict(verdicts.allSatisfy { $0 }, at: CGPoint(x: cx(k), y: row + 7))
                    }
                    row += 16
                }
                if let note = spec.note {
                    pen.draw(pen.text(note, color: palette.textSecondary), at: CGPoint(x: left, y: row + 1), anchor: .topLeading)
                }
            }
        }
    }

    private func drawTitle(name: String?, first: Bool, at p: CGPoint, pen: PlotPen, palette: PlotStyle.Palette) {
        // The output's name in the label colour, the axis title in the secondary grey.
        var x = p.x
        if let name {
            let t = pen.text(MathTypesetter.escaped(name), size: 11, weight: .semibold, color: palette.text)
            pen.draw(t, at: CGPoint(x: x, y: p.y), anchor: .bottomLeading)
            x += pen.width(t) + 8
        }
        if first {
            pen.draw(pen.text(spec.yTitle, color: palette.textSecondary), at: CGPoint(x: x, y: p.y), anchor: .bottomLeading)
        }
    }
}

// MARK: - Contrast

struct PuzzleContrastSpec: Equatable {
    struct Row: Equatable {
        /// The output's name, shown when there are several.
        var name: String?
        /// Values of the cases that should be 1 and 0, with their case index.
        var ones: [Double]
        var zeros: [Double]
        var oneCases: [Int]
        var zeroCases: [Int]
        var decibels: Double
    }

    var xTitle: String
    var rows: [Row]
    var dimmed = false
    /// Under the plot: "Contrast 17.5 dB. Passes at 6 dB."
    var status: String?
    var passes: Bool?
}

/// Each output's cases on one value axis: the 0-cases (hollow, second ink) and the 1-cases
/// (filled, ink) each as a band from their weakest to their strongest, and the gap between
/// the strongest 0 and the weakest 1 shaded and named in dB. A log axis when the values
/// span more than a decade; values under its start sit at the left edge.
struct PuzzleContrastPlot: View {
    let spec: PuzzleContrastSpec
    @Environment(\.colorScheme) private var scheme
    @Environment(\.plotSurface) private var surface
    @Environment(\.displayScale) private var displayScale

    static let rowHeight: CGFloat = 52

    var body: some View {
        let _ = PerfProbe.body("PuzzleContrastPlot")
        Canvas { context, size in
            draw(size: size, palette: PlotStyle.Palette(scheme, surface: surface), in: context)
        }
        .frame(minHeight: CGFloat(spec.rows.count) * Self.rowHeight + 56)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Contrast between the cases that should be 1 and those that should be 0")
        .accessibilityValue(spec.rows.map { row in
            (row.name.map { "\($0): " } ?? "") + "should be 1: \(row.ones.map { Format.significant($0) }.joined(separator: ", ")); should be 0: \(row.zeros.map { Format.significant($0) }.joined(separator: ", ")); \(Format.decibels(row.decibels))"
        }.joined(separator: ". "))
    }

    /// The value axis: log over whole decades when the values span more than 10× (the
    /// contrast is a ratio, so equal steps in dB are equal distances).
    struct Axis {
        var log: Bool
        var lo: Double
        var hi: Double
        var ticks: [PlotTick]
        /// Some value lies under `lo` and is drawn at the edge.
        var clamped: Bool

        init(values: [Double], length: CGFloat) {
            let positive = values.filter { $0 > PuzzleReport.floor * 1.0001 }
            let maxV = values.max() ?? 1
            let minP = positive.min() ?? maxV
            if maxV > 0, minP > 0, maxV / minP > 10 {
                let low = pow(10, floor(log10(minP)))
                var high = pow(10, ceil(log10(maxV)))
                if high <= low { high = low * 10 }
                let under = values.contains { $0 < low }
                let d0 = Int(log10(low).rounded()), d1 = Int(log10(high).rounded())
                let step = max(1, Int(ceil(Double(d1 - d0) / max(1, Double(length / 40)))))
                var marks = stride(from: d0, through: d1, by: step).map { d in
                    PlotTick(value: pow(10, Double(d)), label: Self.decade(d))
                }
                if under, !marks.isEmpty { marks[0].label = "≤ " + marks[0].label }
                log = true
                lo = low
                hi = high
                clamped = under
                ticks = marks
            } else {
                log = false
                clamped = false
                let layout = PlotAxis(domain: 0...max(maxV, 1e-9), length: length, minSpacing: 40, ends: .snapOut, fromZero: true).layout()
                lo = layout.domain.lowerBound
                hi = layout.domain.upperBound
                ticks = layout.ticks
            }
        }

        /// "10⁻³", "1", "10".
        static func decade(_ d: Int) -> String {
            switch d {
            case 0: return "1"
            case 1: return "10"
            default: return PlotAxis.exponentLabel(d).replacingOccurrences(of: "×", with: "")
            }
        }

        func position(_ v: Double, in r: ClosedRange<CGFloat>) -> CGFloat {
            let t: Double
            if log {
                t = (log10(max(v, lo)) - log10(lo)) / max(1e-12, log10(hi) - log10(lo))
            } else {
                t = (v - lo) / max(1e-300, hi - lo)
            }
            return r.lowerBound + CGFloat(min(1, max(0, t))) * (r.upperBound - r.lowerBound)
        }

        /// The minor ticks of a log axis: 2 and 5 in each decade.
        func minors() -> [Double] {
            guard log else { return [] }
            var out: [Double] = []
            var d = lo
            while d < hi * 0.999 {
                out += [2 * d, 5 * d].filter { $0 < hi }
                d *= 10
            }
            return out
        }
    }

    private func draw(size: CGSize, palette: PlotStyle.Palette, in context: GraphicsContext) {
        let pen = PlotPen(context: context, scale: max(1, displayScale))
        let names = spec.rows.contains { $0.name != nil }
        let nameWidth: CGFloat = names ? (spec.rows.compactMap(\.name).map { pen.width(pen.text(MathTypesetter.escaped($0), size: 11, weight: .semibold, color: palette.text)) }.max() ?? 0) + 10 : 0
        let left = max(14, nameWidth), right: CGFloat = 18
        let span = (left)...(max(left + 40, size.width - right))
        let values = spec.rows.flatMap { $0.ones + $0.zeros }
        let axis = Axis(values: values, length: span.upperBound - span.lowerBound)
        func x(_ v: Double) -> CGFloat { axis.position(v, in: span) }
        let marks = spec.dimmed ? 0.45 : 1.0
        var top: CGFloat = 4

        for row in spec.rows {
            let r = CGRect(x: span.lowerBound, y: top, width: span.upperBound - span.lowerBound, height: Self.rowHeight)
            let dotsY = r.minY + 26
            if let name = row.name {
                pen.draw(pen.text(MathTypesetter.escaped(name), size: 11, weight: .semibold, color: palette.text), at: CGPoint(x: 0, y: dotsY), anchor: .leading)
            }
            let weakestOne = row.ones.min() ?? 0, strongestZero = row.zeros.max() ?? 0
            // Gap (or overlap) band through the row, edges as dotted frame hairlines.
            let a = x(min(weakestOne, strongestZero)), b = x(max(weakestOne, strongestZero))
            let band = CGRect(x: a, y: dotsY - 11, width: max(0, b - a), height: 22)
            context.fill(Path(band), with: .color(PlotStyle.gapFill(palette)))
            for edge in [a, b] {
                let e = pen.snap(edge)
                pen.line(CGPoint(x: e, y: band.minY), CGPoint(x: e, y: band.maxY), palette.frame, dash: [2, 2])
            }
            // The two groups' bands: weakest to strongest of each, under the dots.
            var marksContext = context
            marksContext.opacity = marks
            for (group, color) in [(row.zeros, palette.ink2), (row.ones, palette.ink)] where !group.isEmpty {
                let g0 = x(group.min()!), g1 = x(group.max()!)
                let rect = CGRect(x: g0 - 5, y: dotsY - 5, width: max(10, g1 - g0 + 10), height: 10)
                marksContext.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(color.opacity(0.18)))
            }
            // Dots: coincident cases step vertically by case index, never at random.
            func dots(_ values: [Double], _ cases: [Int], filled: Bool) {
                var placed: [CGFloat] = []
                for (v, _) in zip(values, cases) {
                    let px = x(v)
                    let k = placed.filter { abs($0 - px) < 7 }.count
                    placed.append(px)
                    let py = dotsY + CGFloat(k % 2 == 0 ? k / 2 : -(k + 1) / 2) * 5
                    let rr: CGFloat = 4, ring: CGFloat = 1.5
                    let outer = CGRect(x: px - rr - ring, y: py - rr - ring, width: 2 * (rr + ring), height: 2 * (rr + ring))
                    marksContext.fill(Path(ellipseIn: outer), with: .color(palette.surface))
                    let inner = outer.insetBy(dx: ring, dy: ring)
                    if filled {
                        marksContext.fill(Path(ellipseIn: inner), with: .color(palette.ink))
                    } else {
                        marksContext.stroke(Path(ellipseIn: inner.insetBy(dx: 0.75, dy: 0.75)), with: .color(palette.ink2), lineWidth: 1.5)
                    }
                }
            }
            dots(row.zeros, row.zeroCases, filled: false)
            dots(row.ones, row.oneCases, filled: true)

            // Names over each group, and the gap's size over the band; any that would
            // collide is left out (the status line and VoiceOver carry it).
            let labelY = r.minY + 8
            var taken: [CGRect] = []
            /// Places a label with its left edge at `x0` (clamped into the plot) on `y`;
            /// false when it would collide with one already placed.
            @discardableResult
            func place(_ s: String, left x0: CGFloat, y: CGFloat, color: Color) -> Bool {
                let t = pen.text(s, color: color)
                let w = pen.width(t)
                let x = min(max(x0, 0), size.width - w)
                let rect = CGRect(x: x, y: y - 6, width: w, height: 12)
                guard !taken.contains(where: { $0.insetBy(dx: -4, dy: 0).intersects(rect) }) else { return false }
                taken.append(rect)
                pen.draw(t, at: CGPoint(x: x, y: y), anchor: .leading)
                return true
            }
            // The group names at their outer ends (0s from the left, 1s to the right), the
            // gap's size over its band, or under the dots when the names leave no room.
            if let z0 = row.zeros.min() {
                place("should be 0", left: x(z0) - 5, y: labelY, color: palette.textSecondary)
            }
            if let o1 = row.ones.max() {
                let w = pen.width(pen.text("should be 1", color: palette.textSecondary))
                place("should be 1", left: x(o1) + 5 - w, y: labelY, color: palette.textSecondary)
            }
            let gapText = weakestOne >= strongestZero ? "gap " + Format.decibels(row.decibels) : "overlap " + Format.decibels(-row.decibels)
            let gw = pen.width(pen.text(gapText, color: palette.text))
            if !place(gapText, left: (a + b) / 2 - gw / 2, y: labelY, color: palette.text) {
                place(gapText, left: (a + b) / 2 - gw / 2, y: dotsY + 17, color: palette.text)
            }
            top += Self.rowHeight
        }

        // The shared value axis.
        let ay = pen.snap(top + 4)
        pen.line(CGPoint(x: span.lowerBound, y: ay), CGPoint(x: span.upperBound, y: ay), palette.frame)
        for v in axis.minors() {
            let xx = pen.snap(x(v))
            pen.line(CGPoint(x: xx, y: ay), CGPoint(x: xx, y: ay + 2), palette.frame)
        }
        for tick in axis.ticks {
            let xx = pen.snap(x(tick.value))
            pen.line(CGPoint(x: xx, y: ay), CGPoint(x: xx, y: ay + PlotStyle.tickLength), palette.frame)
            pen.draw(pen.text(tick.label, color: palette.textSecondary), at: CGPoint(x: x(tick.value), y: ay + PlotStyle.tickLength + 1), anchor: .top)
        }
        let titleY = ay + PlotStyle.tickLength + PlotStyle.tickRow + 1
        pen.draw(pen.text(spec.xTitle + (axis.log ? " (log scale)" : ""), color: palette.textSecondary),
                 at: CGPoint(x: (span.lowerBound + span.upperBound) / 2, y: titleY), anchor: .top)
        if let status = spec.status {
            let y = titleY + PlotStyle.xTitleRow + 8
            var x = span.lowerBound
            if let passes = spec.passes, !spec.dimmed {
                pen.verdict(passes, at: CGPoint(x: x + 6, y: y))
                x += 16
            }
            pen.draw(pen.text(status, size: 11, color: palette.text), at: CGPoint(x: x, y: y), anchor: .leading)
        }
    }
}

// MARK: - Score bar

/// The score on a horizontal track: the pass level and the three star thresholds as ticks
/// with star marks (filled once reached), the score as an ink bar from the start. A score
/// below the track's start (a dB score of −60) shows as a mark at the edge with its value.
struct ScoreBar: View {
    var score: Double?
    var thresholds: [Double]
    var pass: Double?
    var scale: PuzzleScoreScale
    var dimmed = false
    /// The best score so far (said in the readout for VoiceOver; the card prints it).
    var best: Double?

    @Environment(\.colorScheme) private var scheme
    @Environment(\.plotSurface) private var surface
    @Environment(\.displayScale) private var displayScale

    /// Room for the track, the stars and two rows of threshold labels (a label that would
    /// collide with its neighbour drops to the second row).
    static let height: CGFloat = 56

    var body: some View {
        let _ = PerfProbe.body("ScoreBar")
        Canvas { context, size in
            draw(size: size, palette: PlotStyle.Palette(scheme, surface: surface), in: context)
        }
        .frame(height: Self.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Score")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        var parts: [String] = [score.map { scale.format($0) } ?? "Not checked"]
        if thresholds.count == 3 { parts.append("stars at \(thresholds.map(scale.formatBare).joined(separator: ", "))") }
        if let best { parts.append("best \(scale.format(best))") }
        return parts.joined(separator: "; ")
    }

    /// The track's range: from 0 (or the pass level for scores that can be negative, if it
    /// is lower) to a little past the third star or the score.
    /// Thresholds close together (85, 92, 96 %) get a track that starts above 0, so the
    /// stars stand apart; the start is labelled.
    var domain: ClosedRange<Double> {
        guard let first = thresholds.first ?? pass, let last = thresholds.last ?? pass else { return 0...1 }
        let spread = max(last - first, abs(last) * 0.1, 1e-9)
        // A round start: 60 rather than 68.5.
        let step = pow(10, Foundation.floor(log10(spread)))
        var lo = max(0, Foundation.floor((first - 1.5 * spread) / step) * step)
        // A start below half the first star says little: start at 0 then (4, 5, 5.6 dB → 0).
        if lo <= 0.5 * first { lo = 0 }
        var hi = last + 0.6 * spread
        if scale.unit == "%", last <= 100 { hi = min(hi, 100) }
        return lo...max(hi, lo + 1e-9)
    }

    /// Where `v` sits on the track, 0…1. With three stars the track is a star scale: the
    /// stars stand at fixed, even spots (40, 65 and 90 %) and the values between them map
    /// linearly, so thresholds close together (4, 5 and 5.6 dB) never crowd one end.
    func position(_ v: Double, in d: ClosedRange<Double>) -> Double {
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

    private func draw(size: CGSize, palette: PlotStyle.Palette, in context: GraphicsContext) {
        let pen = PlotPen(context: context, scale: max(1, displayScale))
        let d = domain
        let left: CGFloat = 4, right: CGFloat = 4
        let track = CGRect(x: left, y: 16, width: max(10, size.width - left - right), height: 6)
        func x(_ v: Double) -> CGFloat { track.minX + CGFloat(position(v, in: d)) * track.width }
        context.fill(Path(roundedRect: track, cornerRadius: 3), with: .color(palette.grid))
        var taken: [CGRect] = []
        if d.lowerBound > 0 {
            let start = pen.text(scale.formatBare(d.lowerBound), color: palette.textSecondary)
            taken.append(CGRect(x: track.minX, y: track.maxY + 4, width: pen.width(start), height: 12))
            pen.draw(start, at: CGPoint(x: track.minX, y: track.maxY + 4), anchor: .topLeading)
        }
        if let score, score.isFinite {
            var c = context
            c.opacity = dimmed ? 0.45 : 1
            let w = max(0, x(score) - track.minX)
            if w > 0 {
                c.fill(Path(roundedRect: CGRect(x: track.minX, y: track.minY, width: w, height: track.height), cornerRadius: 3), with: .color(palette.ink))
            }
            if score < d.lowerBound {
                // Off the start: a small wedge at the edge.
                var p = Path()
                p.move(to: CGPoint(x: track.minX - 1, y: track.midY))
                p.addLine(to: CGPoint(x: track.minX + 5, y: track.minY - 1))
                p.addLine(to: CGPoint(x: track.minX + 5, y: track.maxY + 1))
                p.closeSubpath()
                c.fill(p, with: .color(palette.ink))
            }
        }
        // Thresholds: a tick through the track, a star over it, the value under it.
        for (i, t) in thresholds.enumerated() {
            let tx = x(t)
            pen.line(CGPoint(x: pen.snap(tx), y: track.minY - 2), CGPoint(x: pen.snap(tx), y: track.maxY + 2), palette.text.opacity(0.7))
            let reached = (score ?? -Double.infinity) >= t && !dimmed
            var star = context.resolve(Image(systemName: reached ? "star.fill" : "star"))
            star.shading = .color(reached ? .yellow : palette.textSecondary)
            let s: CGFloat = 10
            context.draw(star, in: CGRect(x: tx - s / 2, y: 1, width: s, height: s))
            let label = pen.text(scale.formatBare(t) + (i == thresholds.count - 1 ? (scale.unit == "dB" ? " dB" : scale.unit) : ""), color: palette.textSecondary)
            let w = pen.width(label)
            let x0 = min(max(tx - w / 2, 0), size.width - w)
            let free = [track.maxY + 4, track.maxY + 17].lazy.map { CGRect(x: x0, y: $0, width: w, height: 12) }
                .first { rect in !taken.contains(where: { $0.insetBy(dx: -3, dy: 0).intersects(rect) }) }
            guard let rect = free else { continue }
            taken.append(rect)
            pen.draw(label, at: rect.origin, anchor: .topLeading)
        }
        if let pass, !thresholds.contains(where: { abs($0 - pass) < 1e-9 }) {
            let px = pen.snap(x(pass))
            pen.line(CGPoint(x: px, y: track.minY - 2), CGPoint(x: px, y: track.maxY + 2), palette.reference)
            let label = pen.text("pass", color: palette.textSecondary)
            let w = pen.width(label)
            let rect = CGRect(x: px - w / 2, y: track.maxY + 4, width: w, height: 12)
            if !taken.contains(where: { $0.insetBy(dx: -3, dy: 0).intersects(rect) }) {
                pen.draw(label, at: CGPoint(x: px, y: track.maxY + 4), anchor: .top)
            }
        }
        if let score, score.isFinite, score < d.lowerBound {
            let t = pen.text(scale.format(score), color: palette.textSecondary)
            let rect = CGRect(x: track.minX, y: track.maxY + 17, width: pen.width(t), height: 12)
            if !taken.contains(where: { $0.insetBy(dx: -3, dy: 0).intersects(rect) }) {
                pen.draw(t, at: rect.origin, anchor: .topLeading)
            }
        }
    }
}

// MARK: - Specs from a result

extension Puzzle {
    /// The value axis title of the result plots.
    func valueTitle(percent: Bool) -> String {
        let kinds = goalDetectorIDs.compactMap { scene[detector: $0]?.kind }
        let box = !kinds.isEmpty && kinds.allSatisfy { $0 == .box }
        let reference = goal.reference ?? "source"
        let what = box ? "Mean $|E|^2$" : "Power"
        let over: String
        switch reference {
        case "incident": over = box ? "incident intensity" : "incident power"
        case "source": over = box ? "$A^2$" : (scene.sources.contains { $0.kind == .lineSource } ? "emitted power" : "source power")
        default: over = "the puzzle's reference"
        }
        return percent ? "\(what) (% of \(over))" : "\(what) over \(over)"
    }
}

extension PuzzleReport {
    /// One bar per case (truth tables, a panel per output) or per goal detector.
    func barSpec(puzzle: Puzzle, shownBits: [Bool], stale: Bool) -> PuzzleBarSpec {
        let title = puzzle.valueTitle(percent: valueStyle == .percent)
        if isTruthTable {
            let panels = outputs.enumerated().map { j, output -> PuzzleBarSpec.Panel in
                let bars = rows.map { row -> PuzzleBarSpec.Bar in
                    let cell = row.cells[j]
                    let label = zip(letters, row.bits).map { "$\($0)$ \($1 ? 1 : 0)" }.joined(separator: " ")
                    return PuzzleBarSpec.Bar(label: label, sublabel: outputs.count == 1 ? cell.target.map { "should be \($0 ? 1 : 0)" } : nil,
                                             value: cell.value, passes: cell.passes, isShown: row.bits == shownBits)
                }
                let contrast = contrasts.first { $0.output.id == output.id }
                let gap = contrast.map { min($0.weakestOne, $0.strongestZero)...max($0.weakestOne, $0.strongestZero) }
                let gapLabel = contrast.map { $0.decibels >= 0 ? "gap " + Format.decibels($0.decibels) : "overlap " + Format.decibels(-$0.decibels) }
                return PuzzleBarSpec.Panel(name: outputs.count > 1 ? output.name : nil, bars: bars, gap: gap, gapLabel: gapLabel)
            }
            return PuzzleBarSpec(yTitle: title, style: valueStyle, panels: panels, dimmed: stale,
                                 note: stale ? "Out of date. Check again to score." : nil)
        }
        let bars = detectorRows.map { row in
            PuzzleBarSpec.Bar(label: MathTypesetter.escaped(row.name), value: row.value, passes: row.passes,
                              aim: row.aim.map { valueStyle == .percent ? $0 * 100 : $0 })
        }
        var rules: [PuzzleBarSpec.Rule] = []
        if let pass {
            switch puzzle.goal.type {
            case "maximize": rules.append(.init(value: pass, label: "Pass " + scale.formatThreshold(pass)))
            case "minimize" where detectorRows.count == 1:
                let limit = pow(10, -pass / 10) * 100
                rules.append(.init(value: limit, label: "Pass ≤ " + Format.number(limit, digits: 0...1) + "%"))
            default: break
            }
        }
        return PuzzleBarSpec(yTitle: title, style: valueStyle, panels: [.init(bars: bars, rules: rules)], dimmed: stale,
                             note: stale ? "Out of date. Check again to score." : nil)
    }

    /// Each output's cases on one axis (truth tables only).
    func contrastSpec(puzzle: Puzzle, evaluation: PuzzleEvaluation?, stale: Bool) -> PuzzleContrastSpec? {
        guard isTruthTable, !contrasts.isEmpty else { return nil }
        let rows = contrasts.map { c in
            PuzzleContrastSpec.Row(name: contrasts.count > 1 ? c.output.name : nil,
                                   ones: c.ones.map(\.value), zeros: c.zeros.map(\.value),
                                   oneCases: c.ones.map(\.case), zeroCases: c.zeros.map(\.case), decibels: c.decibels)
        }
        var status: String?
        if stale {
            status = "Out of date. Check again to score."
        } else if let score = evaluation?.score, let pass {
            let needed = puzzle.scoreScale.formatThreshold(pass)
            status = "Contrast \(Format.decibels(score)). " + (score >= pass ? "Passes at \(needed)." : "Needs \(needed).")
        }
        return PuzzleContrastSpec(xTitle: puzzle.valueTitle(percent: false), rows: rows, dimmed: stale, status: status,
                                  passes: evaluation.map { $0.passed })
    }
}
