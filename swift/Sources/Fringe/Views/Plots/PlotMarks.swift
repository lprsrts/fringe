import SwiftUI

/// One curve. `name` may carry `$…$` math ("$n$").
struct PlotSeries: Identifiable, Equatable {
    enum Style: Equatable {
        /// The main ink, 1.5 pt solid.
        case data
        /// The second ink, for a peer series on the same axis.
        case data2
        /// A grey dashed reference (Incident).
        case reference
    }

    var name: String
    var x: [Double]
    var y: [Double]
    var style: Style = .data
    /// Named on the plot (direct label); single-series panels are named by the panel label.
    var labelled = true
    var id: String { name }

    /// The points inside an x domain, in order.
    func points(in domain: ClosedRange<Double>) -> [(x: Double, y: Double)] {
        zip(x, y).filter { $0.0 >= domain.lowerBound - 1e-12 && $0.0 <= domain.upperBound + 1e-12 && $0.1.isFinite }
            .map { (x: $0.0, y: $0.1) }
    }

    /// The value at `at` by linear interpolation, nil outside the samples.
    func value(at: Double) -> Double? {
        guard let first = x.first, let last = x.last, at >= first - 1e-12, at <= last + 1e-12 else { return nil }
        guard let i = x.firstIndex(where: { $0 >= at }) else { return y.last }
        if i == 0 { return y[0] }
        let t = (at - x[i - 1]) / max(1e-300, x[i] - x[i - 1])
        return y[i - 1] + t * (y[i] - y[i - 1])
    }

    /// The index of the sample nearest `at`.
    func nearestIndex(to at: Double) -> Int? {
        guard !x.isEmpty else { return nil }
        var best = 0
        for i in x.indices where abs(x[i] - at) < abs(x[best] - at) { best = i }
        return best
    }
}

/// A vertical rule at an x value through every panel (λ0), labelled above the first panel,
/// with ring markers where it crosses each curve.
struct PlotRule: Equatable {
    enum Style: Equatable {
        /// A hairline in the reference grey (λ0).
        case reference
        /// A dotted hairline where a curve is cut (an undamped resonance).
        case pole
    }

    var x: Double
    var label: String?
    var markers = true
    var style: Style = .reference
    /// The exact value of a series at `x`, by series name, where the caller has it (the
    /// core's value at λ0); otherwise the marker interpolates between samples.
    var exact: [String: Double] = [:]
}

/// A shaded x range in every panel (outside a fitted range).
struct PlotBand: Equatable {
    var x: ClosedRange<Double>
}

/// One of the vertically stacked panels that share the figure's x axis.
struct PlotPanel: Equatable {
    /// The panel's name in math italic at the top left ("$n$"), for dimensionless panels.
    var label: String?
    /// The y axis title over the axis ("$|E|^2/A^2$"), when there is no panel label.
    var title: String?
    var series: [PlotSeries]
    var minSpan: Double = 0
    var fromZero = false
    /// Plot height in points; nil takes the height left over.
    var height: CGFloat?
    var minHeight: CGFloat = 100
    var minSpacing: CGFloat = 20
    /// The values the y axis spans, when not all of the data (a curve running off to a
    /// pole is cut at the panel edge rather than scaling the axis to wherever its samples
    /// happen to land).
    var dataRange: ClosedRange<Double>?
}

struct PlotXAxis: Equatable {
    var title: String
    /// For the narrow layout ("Position (µm)").
    var shortTitle: String?
    /// For the readout ("µm").
    var unit: String
    var domain: ClosedRange<Double>
    var minSpacing: CGFloat = 36
    /// Label a non-round end exactly when it reads cleanly (a detector's length); off for
    /// the λ range, whose ends are only where the sampling starts and stops.
    var exactEnds = true
}

/// What a figure draws: one x axis, its panels and the annotations.
struct PlotSpec: Equatable {
    var x: PlotXAxis
    var panels: [PlotPanel]
    var rules: [PlotRule] = []
    var bands: [PlotBand] = []
    /// Lines under the x title, with math.
    var notes: [String] = []
    /// The x axis ends at a detector's end: a long end tick, and its value there when unlabelled.
    var endMarkers = false
    /// The one label for two curves that coincide ("Total = Incident").
    var mergedLabel: String?
    /// Curve names may sit past the right end of the plot. Off for a plot whose shape
    /// changes as it is edited (a detector being dragged), so its axis length stays put.
    var endLabels = true
    /// Least left gutter (tick labels, ticks).
    var minLeftGutter: CGFloat = 30

    /// The height the figure needs when every panel has a fixed height.
    var fixedHeight: CGFloat? {
        var h: CGFloat = 0
        for (i, panel) in panels.enumerated() {
            guard let ph = panel.height else { return nil }
            h += PlotStyle.titleRow + ph + (i > 0 ? PlotStyle.panelGap : 0)
        }
        return h + PlotStyle.tickLength + PlotStyle.tickRow + PlotStyle.xTitleRow + CGFloat(notes.count) * PlotStyle.noteRow
    }
}

/// What the figure is showing.
enum PlotState: Equatable {
    case live
    /// Marks at this opacity, frame and text at full strength (stale data, or the last
    /// curve held while a new one is sampled).
    case dimmed(Double)
    /// The last curve held at 40 % while a new one is sampled, with "Updating…" in the
    /// corner after a moment, so it never reads as merely stale.
    case updating
    /// Axes with no data yet; "Sampling…" after a moment.
    case pending
    /// No axes, only this text.
    case message(String)
}

// MARK: Drawing

extension PlotSeries {
    /// The curve as a path, broken at non-finite values.
    func path(x xs: PlotScale, y ys: PlotScale) -> Path {
        var path = Path()
        var open = false
        for (xv, yv) in zip(x, y) {
            guard xv.isFinite, yv.isFinite else { open = false; continue }
            let p = CGPoint(x: xs(xv), y: ys(yv))
            if open { path.addLine(to: p) } else { path.move(to: p); open = true }
        }
        return path
    }

    func draw(in context: inout GraphicsContext, x xs: PlotScale, y ys: PlotScale, palette: PlotStyle.Palette) {
        let path = path(x: xs, y: ys)
        switch style {
        case .data: context.stroke(path, with: .color(palette.ink), style: PlotStyle.data())
        case .data2: context.stroke(path, with: .color(palette.ink2), style: PlotStyle.data())
        case .reference: context.stroke(path, with: .color(palette.reference), style: PlotStyle.reference)
        }
    }

    func color(_ palette: PlotStyle.Palette) -> Color {
        switch style {
        case .data: palette.ink
        case .data2: palette.ink2
        case .reference: palette.reference
        }
    }
}

enum PlotMarks {
    /// A filled dot with a ring in the surface colour, so it stands off the line.
    static func marker(at p: CGPoint, color: Color, in context: inout GraphicsContext, palette: PlotStyle.Palette) {
        let r = PlotStyle.markerRadius
        let outer = CGRect(x: p.x - r - PlotStyle.markerRing, y: p.y - r - PlotStyle.markerRing,
                           width: 2 * (r + PlotStyle.markerRing), height: 2 * (r + PlotStyle.markerRing))
        context.fill(Path(ellipseIn: outer), with: .color(palette.surface))
        context.fill(Path(ellipseIn: outer.insetBy(dx: PlotStyle.markerRing, dy: PlotStyle.markerRing)), with: .color(color))
    }

    /// A short line in the series' style, as a key in the readout.
    static func key(_ style: PlotSeries.Style, from a: CGPoint, to b: CGPoint, in context: inout GraphicsContext, palette: PlotStyle.Palette) {
        var path = Path()
        path.move(to: a)
        path.addLine(to: b)
        switch style {
        case .data: context.stroke(path, with: .color(palette.ink), style: PlotStyle.data())
        case .data2: context.stroke(path, with: .color(palette.ink2), style: PlotStyle.data())
        case .reference: context.stroke(path, with: .color(palette.reference), style: StrokeStyle(lineWidth: PlotStyle.referenceWidth, dash: [3, 2]))
        }
    }
}
