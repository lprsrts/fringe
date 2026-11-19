import AppKit

/// The computed layout of one figure at one size: a shared left gutter so every panel's
/// plot box lines up, the panels top to bottom, the x tick and title rows, and where the
/// curve names go. Pure (text is measured with AppKit fonts), so the harness can print it.
struct PlotFrame {
    struct Panel {
        /// The plot box.
        var rect: CGRect
        var y: PlotAxis.Layout
        var yScale: PlotScale
        /// The y title with its ×10ⁿ, if any.
        var title: String?
    }

    var size: CGSize
    var panels: [Panel]
    var x: PlotAxis.Layout
    var xScale: PlotScale
    var xTitle: String
    /// Top of the x tick-label row, of the title row and of the first note.
    var xTickTop: CGFloat
    var xTitleTop: CGFloat
    var noteTop: CGFloat
    var labels: [PlacedLabel]
    /// The curves named inside each panel, kept so the names can be placed again away
    /// from the crosshair; empty when the names sit at the curve ends.
    var insideCurves: [(plot: CGRect, curves: [DirectLabel.Curve])] = []
    var isNarrow: Bool
    /// From the top of the first panel to the bottom of the last.
    var plotSpan: CGRect {
        guard let first = panels.first, let last = panels.last else { return .zero }
        return CGRect(x: first.rect.minX, y: first.rect.minY, width: first.rect.width, height: last.rect.maxY - first.rect.minY)
    }

    static func measureTick(_ s: String) -> CGFloat { PlotStyle.width(s, font: PlotStyle.tickNSFont) }

    /// The inside names placed again with no name within `clearance` points of `x` (the
    /// crosshair). A name already clear of it stays where it is.
    func labels(avoiding x: CGFloat, clearance: CGFloat = 48) -> [PlacedLabel] {
        guard !insideCurves.isEmpty else { return labels }
        let band = (x - clearance)...(x + clearance)
        func hits(_ r: CGRect) -> Bool { r.maxX >= band.lowerBound && r.minX <= band.upperBound }
        guard labels.contains(where: { hits($0.rect) }) else { return labels }
        return insideCurves.flatMap { DirectLabel.inside($0.curves, plot: $0.plot, avoid: band) }
    }

    init(spec: PlotSpec, size: CGSize, hasData: Bool) {
        self.size = size
        let bottomRows = PlotStyle.tickLength + PlotStyle.tickRow + PlotStyle.xTitleRow + CGFloat(spec.notes.count) * PlotStyle.noteRow
        // Heights: fixed panels as given, flexible ones share the rest.
        var fixed = bottomRows
        for (i, p) in spec.panels.enumerated() {
            fixed += PlotStyle.titleRow + (i > 0 ? PlotStyle.panelGap : 0) + (p.height ?? 0)
        }
        let flexible = spec.panels.filter { $0.height == nil }
        let flexHeight = flexible.isEmpty ? 0 : max(0, size.height - fixed) / CGFloat(flexible.count)
        let heights = spec.panels.map { $0.height ?? max($0.minHeight, flexHeight) }

        // y layouts (independent of x).
        let ys: [PlotAxis.Layout] = zip(spec.panels, heights).map { panel, h in
            let values = panel.series.flatMap { $0.points(in: spec.x.domain).map(\.y) }
            let lo = panel.dataRange?.lowerBound ?? values.min() ?? 0, hi = panel.dataRange?.upperBound ?? values.max() ?? 1
            return PlotAxis(domain: lo...max(lo, hi), length: h, minSpacing: panel.minSpacing, ends: .snapOut,
                            minSpan: panel.minSpan, fromZero: panel.fromZero).layout()
        }
        // The left gutter: widest y tick label + tick + gap, the same for every panel.
        let widest = hasData ? ys.flatMap(\.ticks).map { Self.measureTick($0.label) }.max() ?? 0 : 0
        let left = max(spec.minLeftGutter, ceil(widest + PlotStyle.tickLength + PlotStyle.labelGap + 2))

        // Panel rects (x filled in once the trailing gutter is known).
        var tops: [CGFloat] = []
        var top: CGFloat = 0
        for (i, h) in heights.enumerated() {
            top += (i > 0 ? PlotStyle.panelGap : 0) + PlotStyle.titleRow
            tops.append(top)
            top += h
        }
        let yScales = zip(ys, zip(tops, heights)).map { layout, th in
            PlotScale(domain: layout.domain, range: th.0...(th.0 + th.1), flipped: true)
        }

        // Curve names: at the right ends when they clear each other, else inside.
        let xMin = spec.x.domain.lowerBound, xMax = spec.x.domain.upperBound
        let lastX = spec.panels.flatMap { $0.series.filter(\.labelled).compactMap { $0.points(in: spec.x.domain).last?.x } }.max() ?? xMax
        var curvesInPanel: [(panel: Int, series: PlotSeries)] = []
        for (i, p) in spec.panels.enumerated() {
            for s in p.series where s.labelled && !s.points(in: spec.x.domain).isEmpty { curvesInPanel.append((i, s)) }
        }
        func labelSize(_ text: String) -> CGSize {
            CGSize(width: PlotStyle.width(text, font: PlotStyle.curveLabelNSFont), height: 14)
        }
        func curves(xScale: PlotScale) -> [DirectLabel.Curve] {
            curvesInPanel.map { entry in
                let pts = entry.series.points(in: spec.x.domain).map { CGPoint(x: xScale($0.x), y: yScales[entry.panel]($0.y)) }
                return DirectLabel.Curve(text: entry.series.name, points: pts, size: labelSize(entry.series.name),
                                         secondary: entry.series.style == .reference)
            }
        }
        let prelimWidth = size.width - left - 8
        let narrow = prelimWidth < PlotStyle.narrowWidth
        // A provisional x scale for the coincidence and end tests (only y matters for them).
        let provisional = PlotScale(domain: xMin...max(xMax, xMin + 1e-12), range: left...(left + max(1, prelimWidth)))
        var named = curves(xScale: provisional)
        var merged = false
        if named.count == 2, let mergedText = spec.mergedLabel, DirectLabel.coincide(named[0], named[1]) {
            named = [DirectLabel.Curve(text: mergedText, points: named[0].points, size: labelSize(mergedText), secondary: false)]
            merged = true
        }
        let ends = !spec.endLabels || (narrow && !merged) ? nil : DirectLabel.atEnds(named, endX: 0)
        let endsFitAtLastX = abs(lastX - xMax) <= (xMax - xMin) * 0.02
        let useEnds = hasData && ends != nil && !named.isEmpty && endsFitAtLastX
        let labelGutter = useEnds ? DirectLabel.endGap + (named.map(\.size.width).max() ?? 0) + 4 : 0

        // x axis: the trailing gutter also holds half the last tick label.
        var right = max(8, labelGutter)
        let xProbe = PlotAxis(domain: xMin...xMax, length: max(1, size.width - left - right), minSpacing: spec.x.minSpacing, ends: .labelExact, exactEnds: spec.x.exactEnds)
            .layout(measure: Self.measureTick)
        if let last = xProbe.ticks.last { right = max(right, Self.measureTick(last.label) / 2 + 1) }
        let plotWidth = max(1, size.width - left - right)
        x = PlotAxis(domain: xMin...xMax, length: plotWidth, minSpacing: spec.x.minSpacing, ends: .labelExact, exactEnds: spec.x.exactEnds).layout(measure: Self.measureTick)
        xScale = PlotScale(domain: x.domain, range: left...(left + plotWidth))
        panels = (0..<spec.panels.count).map { i in
            let p = spec.panels[i]
            let rect = CGRect(x: left, y: tops[i], width: plotWidth, height: heights[i])
            let title = p.label ?? p.title
            let withExp = ys[i].exponent.map { e in (title ?? "") + " (" + PlotAxis.exponentLabel(e) + ")" } ?? title
            return Panel(rect: rect, y: ys[i], yScale: yScales[i], title: withExp)
        }
        let bottom = (panels.last?.rect.maxY ?? 0) + PlotStyle.tickLength
        xTickTop = bottom + 1
        xTitleTop = xTickTop + PlotStyle.tickRow
        noteTop = xTitleTop + PlotStyle.xTitleRow
        xTitle = narrow ? (spec.x.shortTitle ?? spec.x.title) : spec.x.title
        isNarrow = narrow

        // Place the names on the real scale.
        var final = curves(xScale: xScale)
        if merged, let first = final.first, let text = spec.mergedLabel {
            final = [DirectLabel.Curve(text: text, points: first.points, size: labelSize(text), secondary: false)]
        }
        if !hasData || final.isEmpty {
            labels = []
        } else if useEnds {
            labels = DirectLabel.atEnds(final, endX: xScale(lastX)) ?? []
        } else {
            // Per panel, inside its box.
            var out: [PlacedLabel] = []
            var kept: [(plot: CGRect, curves: [DirectLabel.Curve])] = []
            for (i, panel) in panels.enumerated() {
                let inPanel = final.enumerated().filter { k, _ in merged ? i == curvesInPanel.first?.panel : curvesInPanel[k].panel == i }.map(\.element)
                if !inPanel.isEmpty {
                    out += DirectLabel.inside(inPanel, plot: panel.rect)
                    kept.append((panel.rect, inPanel))
                }
            }
            labels = out
            insideCurves = kept
        }
    }
}
