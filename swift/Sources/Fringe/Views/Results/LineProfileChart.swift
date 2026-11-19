import SwiftUI

/// |E|²/A² along a line detector from its start (0) to its end (L): the total field in the
/// plot ink, the incident field as a grey dashed reference behind it, both named on their
/// curves. Hovering shows the values at the nearest sample.
struct LineProfileChart: View {
    let points: [ProfilePoint]
    let detectorName: String
    let lengthUm: Double
    var state: PlotState = .live
    /// The harness's hover override.
    var hoverX: Double?
    var captionDelay: Duration = .milliseconds(400)

    var body: some View {
        let _ = PerfProbe.body("LineProfileChart")
        PlotFigure(spec: spec, state: state, hoverX: hoverX, captionDelay: captionDelay, accessibility: accessibility)
    }

    var spec: PlotSpec {
        let x = points.map(\.positionUm)
        let name = MathTypesetter.escaped(detectorName)
        return PlotSpec(
            x: PlotXAxis(title: "Position along \(name) (µm)", shortTitle: "Position (µm)", unit: "µm",
                         domain: 0...max(lengthUm, 1e-6)),
            panels: [PlotPanel(
                title: "$|E|^2/A^2$",
                series: [
                    PlotSeries(name: "Incident", x: x, y: points.map(\.incident), style: .reference),
                    PlotSeries(name: "Total", x: x, y: points.map(\.total)),
                ],
                fromZero: true, minHeight: 60
            )],
            endMarkers: true,
            mergedLabel: "Total = Incident",
            // Names inside the plot only, so the axis keeps its length while a detector is
            // dragged and the curve changes shape.
            endLabels: false,
            minLeftGutter: 36
        )
    }

    private var accessibility: PlotAccessibility {
        var summary = ""
        if let peak = points.max(by: { $0.total < $1.total }) {
            let inc = points.map(\.incident)
            summary = "Peak total \(Format.significant(peak.total)) at \(Format.significant(peak.positionUm)) µm; incident \(Format.significant(inc.min() ?? .nan)) to \(Format.significant(inc.max() ?? .nan))"
        }
        let x = points.map(\.positionUm)
        return PlotAccessibility(
            title: "Intensity along \(detectorName)", summary: summary,
            xTitle: "Position along \(detectorName)", xUnit: "µm", yTitle: "|E|²/A²",
            series: [PlotSeries(name: "Total", x: x, y: points.map(\.total)),
                     PlotSeries(name: "Incident", x: x, y: points.map(\.incident))]
        )
    }
}
