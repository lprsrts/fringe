import SwiftUI

/// A figure of vertically stacked panels sharing one x axis, drawn on a `Canvas`: L-axes
/// with short outward ticks, a hairline grid at the y ticks, curves in the plot ink, named
/// where they are drawn. Hovering (no click) shows a crosshair through every panel and a
/// readout; ← → move it when the plot has focus. The figure never changes height and
/// never spins: stale or held data dims only the marks.
struct PlotFigure: View {
    let spec: PlotSpec
    var state: PlotState = .live
    /// Puts the crosshair here regardless of the pointer (the harness's hover shots).
    var hoverX: Double?
    /// How long `.pending` waits before saying "Sampling…".
    var captionDelay: Duration = .milliseconds(400)
    var accessibility: PlotAccessibility?

    @Environment(\.colorScheme) private var scheme
    @Environment(\.plotSurface) private var surface
    @Environment(\.displayScale) private var displayScale
    @UIState private var pointerX: Double?
    @UIState private var captionShown = false

    var body: some View {
        let _ = PerfProbe.body("PlotFigure")
        Group {
            if case .message(let text) = state {
                MathText(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geo in
                    let frame = PlotFrame(spec: spec, size: geo.size, hasData: state != .pending)
                    let palette = PlotStyle.Palette(scheme, surface: surface)
                    let crosshair = state == .pending ? nil : (hoverX ?? pointerX).flatMap { snapped($0) }
                    let caption = waits && (captionShown || captionDelay == .zero)
                    Canvas { context, _ in
                        draw(frame, palette: palette, crosshair: crosshair, caption: caption, in: &context)
                    }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p):
                            let span = frame.plotSpan.insetBy(dx: -4, dy: -4)
                            pointerX = span.contains(p) ? frame.xScale.invert(min(max(p.x, span.minX + 4), span.maxX - 4)) : nil
                        case .ended:
                            pointerX = nil
                        }
                    }
                }
            }
        }
        .frame(height: spec.fixedHeight)
        .frame(minHeight: spec.fixedHeight == nil ? minimumHeight : nil)
        .task(id: waits) {
            captionShown = false
            guard waits, captionDelay > .zero else { return }
            try? await Task.sleep(for: captionDelay)
            if !Task.isCancelled { captionShown = true }
        }
        .focusable(state != .pending)
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            step(press.key == .leftArrow ? -1 : 1) ? .handled : .ignored
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility?.title ?? MathTypesetter.plain(spec.x.title))
        .accessibilityValue(accessibility?.summary ?? "")
        .modifier(ChartDescriptor(descriptor: accessibility))
    }

    /// Waiting for a curve: "Sampling…" or "Updating…" shows after `captionDelay`.
    private var waits: Bool { state == .pending || state == .updating }

    private var minimumHeight: CGFloat {
        spec.panels.reduce(0) { $0 + ($1.height ?? $1.minHeight) + PlotStyle.titleRow } + PlotStyle.tickRow + PlotStyle.xTitleRow
    }

    /// The sample series the crosshair snaps to: the first with data.
    private var guide: PlotSeries? {
        spec.panels.lazy.flatMap(\.series).first { !$0.points(in: spec.x.domain).isEmpty }
    }

    private func snapped(_ x: Double) -> Double? {
        guard let g = guide else { return nil }
        let inside = g.points(in: spec.x.domain)
        return inside.min { abs($0.x - x) < abs($1.x - x) }?.x
    }

    /// Moves the crosshair one sample; false when there is nothing to move.
    private func step(_ by: Int) -> Bool {
        guard let g = guide else { return false }
        let xs = g.points(in: spec.x.domain).map(\.x)
        guard !xs.isEmpty else { return false }
        let current = (hoverX ?? pointerX).flatMap { x in xs.indices.min { abs(xs[$0] - x) < abs(xs[$1] - x) } }
        let next = current.map { min(max(0, $0 + by), xs.count - 1) } ?? (by > 0 ? 0 : xs.count - 1)
        pointerX = xs[next]
        return true
    }

    // MARK: Drawing

    private func draw(_ f: PlotFrame, palette: PlotStyle.Palette, crosshair: Double?, caption: Bool, in context: inout GraphicsContext) {
        let s = max(1, displayScale)
        let hair = 1 / s
        /// A hairline's centre on the pixel grid.
        func snap(_ v: CGFloat) -> CGFloat { (floor(v * s) + 0.5) / s }
        func line(_ a: CGPoint, _ b: CGPoint, _ color: Color, width: CGFloat? = nil) {
            var p = Path()
            p.move(to: a)
            p.addLine(to: b)
            context.stroke(p, with: .color(color), lineWidth: width ?? hair)
        }
        func text(_ source: String, size: CGFloat, font: Font, color: Color) -> GraphicsContext.ResolvedText {
            context.resolve(Text(MathTypesetter.styled(source, pointSize: size)).font(font).foregroundStyle(color))
        }
        let hasData = state != .pending
        let marksOpacity: Double = switch state {
        case .dimmed(let o): o
        case .updating: 0.4
        default: 1
        }
        // The readout is placed first, so curve names it would cover can be left out
        // rather than clipped by the card.
        // Names placed inside the plot move along their curves away from the crosshair, so
        // the hovered markers and the names never crowd each other.
        var f = f
        if let crosshair { f.labels = f.labels(avoiding: f.xScale(crosshair)) }
        let readout = crosshair.flatMap { PlotReadout.layout(at: $0, frame: f, spec: spec, palette: palette, snap: snap, context: context) }
        let lastIndex = f.panels.count - 1

        for (i, panel) in f.panels.enumerated() {
            let r = panel.rect
            let spec = self.spec.panels[i]
            // Bands: a faint wash, and a hairline where it meets the unshaded range, so the
            // edge carries the meaning and the wash stays quiet however much it covers.
            for band in self.spec.bands {
                let x0 = max(r.minX, f.xScale(band.x.lowerBound)), x1 = min(r.maxX, f.xScale(band.x.upperBound))
                guard x1 > x0 else { continue }
                context.fill(Path(CGRect(x: x0, y: r.minY, width: x1 - x0, height: r.height)), with: .color(palette.wash))
                for edge in [x0, x1] where edge > r.minX + 0.5 && edge < r.maxX - 0.5 {
                    let e = snap(edge)
                    line(CGPoint(x: e, y: r.minY), CGPoint(x: e, y: r.maxY), palette.grid)
                }
            }
            // Grid at the y ticks above the axis; a zero line when the domain straddles 0.
            if hasData {
                for tick in panel.y.ticks where tick.value > panel.y.domain.lowerBound + 1e-12 {
                    let y = snap(panel.yScale(tick.value))
                    let isZero = abs(tick.value) < 1e-12
                    line(CGPoint(x: r.minX, y: y), CGPoint(x: r.maxX, y: y), isZero ? palette.frame : palette.grid)
                }
            }
            // Marks.
            if hasData {
                var marks = context
                marks.opacity = marksOpacity
                marks.clip(to: Path(r.insetBy(dx: 0, dy: -1)))
                // The reference first, so the data line sits on top.
                for series in spec.series.filter({ $0.style == .reference }) + spec.series.filter({ $0.style != .reference }) {
                    series.draw(in: &marks, x: f.xScale, y: panel.yScale, palette: palette)
                }
            }
            // L-axes.
            let ax = snap(r.minX) - hair, ay = snap(r.maxY)
            line(CGPoint(x: ax, y: r.minY), CGPoint(x: ax, y: ay + hair / 2), palette.frame)
            line(CGPoint(x: ax - hair / 2, y: ay), CGPoint(x: r.maxX, y: ay), palette.frame)
            // y ticks and labels.
            if hasData {
                for tick in panel.y.ticks {
                    let y = snap(panel.yScale(tick.value))
                    line(CGPoint(x: ax - PlotStyle.tickLength, y: y), CGPoint(x: ax, y: y), palette.frame)
                    context.draw(text(tick.label, size: PlotStyle.tickSize, font: PlotStyle.tickFont, color: palette.textSecondary),
                                 at: CGPoint(x: ax - PlotStyle.tickLength - PlotStyle.labelGap, y: panel.yScale(tick.value)), anchor: .trailing)
                }
            }
            // x ticks under every panel, labels under the last.
            for tick in f.x.ticks {
                let x = snap(f.xScale(tick.value))
                line(CGPoint(x: x, y: ay), CGPoint(x: x, y: ay + PlotStyle.tickLength), palette.frame)
                if i == lastIndex {
                    context.draw(text(tick.label, size: PlotStyle.tickSize, font: PlotStyle.tickFont, color: palette.textSecondary),
                                 at: CGPoint(x: f.xScale(tick.value), y: f.xTickTop), anchor: .top)
                }
            }
            // Panel label or y title over the tick column.
            if let title = panel.title {
                let resolved = spec.label != nil
                    ? text(title, size: PlotStyle.panelLabelSize, font: .system(size: PlotStyle.panelLabelSize), color: palette.text)
                    : text(title, size: PlotStyle.titleSize, font: PlotStyle.titleFont, color: palette.textSecondary)
                context.draw(resolved, at: CGPoint(x: 0, y: r.minY - 7), anchor: .bottomLeading)
            }
        }

        // The detector's end: the x axis stops at L with a tick half again as long, in
        // the frame colour like every other tick. When L is not a labelled value it gets its
        // value under that tick if there is room beside the round labels.
        if spec.endMarkers, hasData, let last = f.panels.last {
            let ay = snap(last.rect.maxY)
            let end = f.x.domain.upperBound
            let x = snap(f.xScale(end))
            line(CGPoint(x: x, y: ay), CGPoint(x: x, y: ay + 1.5 * PlotStyle.tickLength), palette.frame)
            if !f.x.ticks.contains(where: { abs($0.value - end) < 1e-9 * max(1, end) }) {
                // The length itself ("4.98"), not a bare "L".
                let resolved = text(Format.number(end, digits: 0...2), size: PlotStyle.tickSize, font: PlotStyle.tickFont, color: palette.textSecondary)
                let w = resolved.measure(in: CGSize(width: 100, height: 100)).width
                let clear = f.x.ticks.allSatisfy { t in
                    abs(f.xScale(t.value) - x) - (PlotFrame.measureTick(t.label) + w) / 2 >= 4
                }
                if clear {
                    context.draw(resolved, at: CGPoint(x: f.xScale(end), y: f.xTickTop + PlotStyle.tickLength / 2), anchor: .top)
                }
            }
        }

        // Rules (λ0) through every panel, with their label over the first.
        let span = f.plotSpan
        for rule in spec.rules where rule.x >= f.x.domain.lowerBound && rule.x <= f.x.domain.upperBound {
            let x = snap(f.xScale(rule.x))
            // While the crosshair shows, the λ0 rule steps back so the two never look alike.
            var ruleContext = context
            ruleContext.opacity = readout != nil && rule.style == .reference ? 0.35 : 1
            switch rule.style {
            case .reference:
                var p = Path()
                p.move(to: CGPoint(x: x, y: span.minY))
                p.addLine(to: CGPoint(x: x, y: span.maxY))
                ruleContext.stroke(p, with: .color(palette.reference), lineWidth: hair)
            case .pole:
                for panel in f.panels {
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: panel.rect.minY))
                    p.addLine(to: CGPoint(x: x, y: panel.rect.maxY))
                    ruleContext.stroke(p, with: .color(palette.frame), style: StrokeStyle(lineWidth: 1, dash: [1, 2]))
                }
            }
            if let label = rule.label {
                let resolved = text(label, size: PlotStyle.titleSize, font: PlotStyle.titleFont, color: palette.textSecondary)
                let w = resolved.measure(in: CGSize(width: 1000, height: 100)).width
                let cx = min(max(x, span.minX + w / 2), f.size.width - w / 2)
                ruleContext.draw(resolved, at: CGPoint(x: cx, y: span.minY - 7), anchor: .bottom)
            }
            if rule.markers, hasData {
                for (i, panel) in f.panels.enumerated() {
                    for series in spec.panels[i].series {
                        guard let y = rule.exact[series.name] ?? series.value(at: rule.x), y.isFinite,
                              y >= panel.y.domain.lowerBound, y <= panel.y.domain.upperBound else { continue }
                        var m = ruleContext
                        m.opacity = marksOpacity * ruleContext.opacity
                        PlotMarks.marker(at: CGPoint(x: f.xScale(rule.x), y: panel.yScale(y)), color: series.color(palette), in: &m, palette: palette)
                    }
                }
            }
        }

        // Curve names, as faint as the marks they name: a dimmed curve must not be
        // outweighed by its own label.
        var names = context
        names.opacity = marksOpacity
        for label in f.labels where !(readout.map { label.rect.intersects($0.card.insetBy(dx: -2, dy: -2)) } ?? false) {
            let resolved = names.resolve(Text(MathTypesetter.styled(label.text, pointSize: PlotStyle.curveLabelSize))
                .font(PlotStyle.curveLabelFont).foregroundStyle(label.secondary ? palette.textSecondary : palette.text))
            names.draw(resolved, at: CGPoint(x: label.rect.minX, y: label.rect.midY), anchor: .leading)
        }

        // x title and notes.
        context.draw(text(f.xTitle, size: PlotStyle.titleSize, font: PlotStyle.titleFont, color: palette.textSecondary),
                     at: CGPoint(x: span.midX, y: f.xTitleTop), anchor: .top)
        for (i, note) in spec.notes.enumerated() {
            context.draw(text(note, size: PlotStyle.titleSize, font: PlotStyle.titleFont, color: palette.textSecondary),
                         at: CGPoint(x: span.minX, y: f.noteTop + CGFloat(i) * PlotStyle.noteRow), anchor: .topLeading)
        }

        if case .dimmed = state, hasData {
            // Stale: said in the plot as well as the header, which the stacked layout lacks.
            context.draw(text("Out of date", size: PlotStyle.titleSize, font: PlotStyle.titleFont, color: palette.textSecondary),
                         at: CGPoint(x: span.maxX - 4, y: span.minY + 4), anchor: .topTrailing)
        }
        if caption {
            if state == .updating {
                // In the corner, over the held curve: it is the old line's, a new one is coming.
                context.draw(text("Updating…", size: PlotStyle.titleSize, font: PlotStyle.titleFont, color: palette.textSecondary),
                             at: CGPoint(x: span.maxX - 4, y: span.minY + 4), anchor: .topTrailing)
            } else {
                context.draw(text("Sampling…", size: 13, font: .callout, color: palette.textSecondary),
                             at: CGPoint(x: span.midX, y: span.midY), anchor: .center)
            }
        }

        if let readout {
            PlotReadout.draw(readout, frame: f, palette: palette, hair: hair, opacity: marksOpacity, in: &context)
        }
    }
}

/// Attaches the chart descriptor when there is one.
private struct ChartDescriptor: ViewModifier {
    var descriptor: PlotAccessibility?

    func body(content: Content) -> some View {
        if let descriptor {
            content.accessibilityChartDescriptor(descriptor)
        } else {
            content
        }
    }
}
