import Foundation

/// |E|² at one point along a line detector, over A².
public struct ProfilePoint: Equatable, Sendable {
    /// Distance from the start of the line in µm.
    public var positionUm: Double
    public var total: Double
    public var incident: Double
}

/// What a profile was sampled from: the field and the line, so moving the detector or a
/// new solve asks for a new one.
public struct ProfileKey: Hashable, Sendable {
    public var field: ObjectIdentifier
    public var line: LineGeometry
}

/// |E|² along a line detector, sampled from a solved field. Foundation only.
public enum LineProfile {
    /// The default number of samples from start to end.
    public static let sampleCount = 200

    /// `count` evenly spaced samples of |E|²/A² of the total and incident parts from the
    /// line's start to its end, with A = `amplitude`. Points off the solved grid are left
    /// out. Bicubic samples; safe to call off the main thread.
    public static func sample(field: FieldHandle, line: LineGeometry, count: Int = sampleCount, amplitude: Double) -> [ProfilePoint] {
        let n = max(2, count)
        let length = hypot(line.x2Um - line.x1Um, line.y2Um - line.y1Um)
        let a2 = max(1e-300, amplitude * amplitude)
        var points: [ProfilePoint] = []
        points.reserveCapacity(n)
        for i in 0..<n {
            let t = Double(i) / Double(n - 1)
            let x = line.x1Um + t * (line.x2Um - line.x1Um)
            let y = line.y1Um + t * (line.y2Um - line.y1Um)
            guard let total = field.sample(x: x, y: y, part: .total),
                  let incident = field.sample(x: x, y: y, part: .incident) else { continue }
            points.append(ProfilePoint(
                positionUm: t * length,
                total: (total.re * total.re + total.im * total.im) / a2,
                incident: (incident.re * incident.re + incident.im * incident.im) / a2
            ))
        }
        return points
    }
}
