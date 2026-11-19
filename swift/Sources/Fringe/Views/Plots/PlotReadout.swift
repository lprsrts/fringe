import SwiftUI

/// The hover readout: a crosshair through every panel at the nearest sample, a ring
/// marker on each curve there, and a small card with the values first.
///
///     2.13 µm
///     ──  1.98  Total
///     ┄┄  1.10  Incident
///
/// The card goes beside the crosshair, or failing that into a corner of the plot, wherever
/// it covers least: never a hovered point, then no curve name, then as little of the
/// curves as it can. When the hovered points are high in the plot it prefers the bottom.
enum PlotReadout {
    static let padding: CGFloat = 6
    static let rowHeight: CGFloat = 15
    static let keyWidth: CGFloat = 12

    struct Row {
        var series: PlotSeries
        var value: Double
        var point: CGPoint
        /// The point lies in its panel (a value running off to a pole may not): no marker otherwise.
        var onScale: Bool
    }

    /// Everything placed, ready to draw. `card` is what curve names must keep clear of.
    struct Layout {
        var x: CGFloat
        var rows: [Row]
        var card: CGRect
        var header: GraphicsContext.ResolvedText
        var values: [GraphicsContext.ResolvedText]
        var names: [GraphicsContext.ResolvedText]
        var valueWidth: CGFloat
        var showKeys: Bool
        var showNames: Bool
    }

    static func layout(at x: Double, frame f: PlotFrame, spec: PlotSpec, palette: PlotStyle.Palette,
                       snap: (CGFloat) -> CGFloat, context: GraphicsContext) -> Layout? {
        let cx = snap(f.xScale(x))

        // The value of every series at its sample nearest x.
        var rows: [Row] = []
        for (i, panel) in f.panels.enumerated() {
            for series in spec.panels[i].series {
                guard let k = series.nearestIndex(to: x), abs(series.x[k] - x) <= (spec.x.domain.upperBound - spec.x.domain.lowerBound) * 0.02,
                      series.y[k].isFinite else { continue }
                let p = CGPoint(x: f.xScale(series.x[k]), y: panel.yScale(series.y[k]))
                rows.append(Row(series: series, value: series.y[k], point: p, onScale: panel.rect.insetBy(dx: -1, dy: -1).contains(p)))
            }
        }
        // The data before its reference (Total, then Incident).
        rows = rows.filter { $0.series.style != .reference } + rows.filter { $0.series.style == .reference }
        guard !rows.isEmpty else { return nil }

        // Line keys only where they tell curves apart (two styles in one figure).
        let showKeys = Set(rows.map(\.series.style)).count > 1
        let showNames = !f.isNarrow || !showKeys
        func resolve(_ source: String, size: CGFloat, font: Font, color: Color) -> GraphicsContext.ResolvedText {
            context.resolve(Text(MathTypesetter.styled(source, pointSize: size)).font(font).foregroundStyle(color))
        }
        let unbounded = CGSize(width: 1000, height: 100)
        let header = resolve("\(Format.significant(x)) \(spec.x.unit)", size: PlotStyle.readoutValueSize, font: PlotStyle.readoutValueFont, color: palette.text)
        let values = rows.map { resolve(Format.significant($0.value), size: PlotStyle.readoutValueSize, font: PlotStyle.readoutValueFont, color: palette.text) }
        let names = rows.map { resolve($0.series.name, size: PlotStyle.readoutNameSize, font: PlotStyle.readoutNameFont, color: palette.textSecondary) }
        let valueWidth = values.map { $0.measure(in: unbounded).width }.max() ?? 0
        let nameWidth = showNames ? (names.map { $0.measure(in: unbounded).width }.max() ?? 0) : 0
        let keyColumn = showKeys ? keyWidth + 5 : 0
        let rowWidth = keyColumn + valueWidth + (showNames ? 5 + nameWidth : 0)
        let width = ceil(max(header.measure(in: unbounded).width, rowWidth) + 2 * padding)
        let height = ceil(CGFloat(rows.count + 1) * rowHeight + 2 * padding - 2)

        let card = place(width: width, height: height, crosshair: cx, rows: rows, frame: f, spec: spec)
        return Layout(x: cx, rows: rows, card: card, header: header, values: values, names: names,
                      valueWidth: valueWidth, showKeys: showKeys, showNames: showNames)
    }

    /// The least-covering of the four places beside the crosshair and the four corners of
    /// the plot (which cost a little more, since the eye must travel to them).
    static func place(width: CGFloat, height: CGFloat, crosshair cx: CGFloat, rows: [Row], frame f: PlotFrame, spec: PlotSpec) -> CGRect {
        let span = f.plotSpan
        let roomRight = span.maxX - cx, roomLeft = cx - span.minX
        let sides: [Bool] = roomRight >= roomLeft ? [true, false] : [false, true]
        // Hovered points high in the plot: the top corners cover the feature being read.
        let high = rows.contains { $0.point.y < span.minY + span.height * 0.4 }
        // The curves in figure points, to count how much of them a card would hide.
        var curvePoints: [CGPoint] = []
        for (i, panel) in f.panels.enumerated() {
            for series in spec.panels[i].series {
                curvePoints += series.points(in: spec.x.domain).map { CGPoint(x: f.xScale($0.x), y: panel.yScale($0.y)) }
            }
        }
        var best: (rect: CGRect, cost: Double)?
        let verticals = high ? [false, true] : [true, false]
        var candidates: [(right: Bool, top: Bool, corner: Bool, rank: Double)] = []
        for (order, top) in verticals.enumerated() {
            for (sideOrder, right) in sides.enumerated() {
                candidates.append((right, top, false, Double(order) * 0.5 + Double(sideOrder) * 0.25))
                candidates.append((right, top, true, 3 + Double(order) * 0.5 + Double(sideOrder) * 0.25))
            }
        }
        for c in candidates {
            do {
                let (right, top) = (c.right, c.top)
                var originX = c.corner ? (right ? span.maxX - width - 4 : span.minX + 4) : (right ? cx + 6 : cx - 6 - width)
                originX = min(max(originX, span.minX + 2), f.size.width - width - 1)
                let originY = top ? span.minY + 4 : span.maxY - height - 4
                let rect = CGRect(x: originX, y: originY, width: width, height: height)
                let guarded = rect.insetBy(dx: -4, dy: -4)
                var cost = Double(rows.filter { $0.onScale && guarded.contains($0.point) }.count) * 1000
                cost += Double(f.labels.filter { $0.rect.intersects(rect.insetBy(dx: -2, dy: -2)) }.count) * 100
                cost += Double(curvePoints.filter { rect.contains($0) }.count)
                // The crosshair itself: a card across it hides what is being read.
                if rect.minX < cx && rect.maxX > cx { cost += 500 }
                // Ties keep the preferred place.
                cost += c.rank
                if best == nil || cost < best!.cost { best = (rect, cost) }
            }
        }
        return best?.rect ?? .zero
    }

    /// The crosshair, the markers and the card. The crosshair is a full-strength hairline
    /// in the label colour, so it is never mistaken for the grey λ0 rule (which dims while
    /// the crosshair shows).
    static func draw(_ l: Layout, frame f: PlotFrame, palette: PlotStyle.Palette, hair: CGFloat, opacity: Double,
                     in context: inout GraphicsContext) {
        let span = f.plotSpan
        var rule = Path()
        rule.move(to: CGPoint(x: l.x, y: span.minY))
        rule.addLine(to: CGPoint(x: l.x, y: span.maxY))
        context.stroke(rule, with: .color(palette.text.opacity(0.55)), lineWidth: hair)

        for row in l.rows where row.onScale {
            var m = context
            m.opacity = max(opacity, 0.6)
            PlotMarks.marker(at: row.point, color: row.series.color(palette), in: &m, palette: palette)
        }

        let card = l.card
        let shape = Path(roundedRect: card, cornerRadius: 5)
        context.fill(shape, with: .color(palette.surface))
        context.stroke(shape, with: .color(palette.grid), lineWidth: hair)

        let left = card.minX + padding
        let keyColumn = l.showKeys ? keyWidth + 5 : 0
        context.draw(l.header, at: CGPoint(x: left, y: card.minY + padding + rowHeight / 2), anchor: .leading)
        for (i, row) in l.rows.enumerated() {
            let y = card.minY + padding + rowHeight * (CGFloat(i) + 1.5)
            if l.showKeys {
                PlotMarks.key(row.series.style, from: CGPoint(x: left, y: y), to: CGPoint(x: left + keyWidth, y: y), in: &context, palette: palette)
            }
            context.draw(l.values[i], at: CGPoint(x: left + keyColumn + l.valueWidth, y: y), anchor: .trailing)
            if l.showNames {
                context.draw(l.names[i], at: CGPoint(x: left + keyColumn + l.valueWidth + 5, y: y), anchor: .leading)
            }
        }
    }
}
