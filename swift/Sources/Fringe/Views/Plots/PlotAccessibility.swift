import Accessibility
import SwiftUI

/// VoiceOver's view of a figure: a title, a one-line summary and every value, so the
/// chart's audio graph and data table work.
struct PlotAccessibility: AXChartDescriptorRepresentable {
    var title: String
    var summary: String
    var xTitle: String
    var xUnit: String
    var yTitle: String
    var series: [PlotSeries]

    func makeChartDescriptor() -> AXChartDescriptor {
        let xs = series.flatMap(\.x).filter(\.isFinite)
        let ys = series.flatMap(\.y).filter(\.isFinite)
        let xRange = (xs.min() ?? 0)...max(xs.min() ?? 0, xs.max() ?? 1)
        let yRange = (ys.min() ?? 0)...max(ys.min() ?? 0, ys.max() ?? 1)
        let unit = xUnit
        let xAxis = AXNumericDataAxisDescriptor(title: xTitle, range: xRange, gridlinePositions: []) { "\(Format.significant($0)) \(unit)" }
        let yAxis = AXNumericDataAxisDescriptor(title: yTitle, range: yRange, gridlinePositions: []) { Format.significant($0) }
        let data = series.map { s in
            AXDataSeriesDescriptor(name: MathTypesetter.plain(s.name), isContinuous: true,
                                   dataPoints: zip(s.x, s.y).filter { $0.0.isFinite && $0.1.isFinite }.map { AXDataPoint(x: $0.0, y: $0.1) })
        }
        return AXChartDescriptor(title: title, summary: summary, xAxis: xAxis, yAxis: yAxis, additionalAxes: [], series: data)
    }
}
