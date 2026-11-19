import Foundation

/// What a set of detector readings was measured on.
struct ReadingsKey: Equatable {
    var field: ObjectIdentifier
    var detectors: [Detector]
}

// Detector readings on the shown field. The core measures them again for the current
// detectors (`fringe_field_measure`), so moving a detector needs no new solve.
extension AppState {
    func refreshReadings() {
        PerfProbe.count("readings.refresh")
        guard let shown = solver.shown else {
            readingsTask?.cancel()
            readingsKey = nil
            if !detectorReadings.isEmpty { detectorReadings = [:] }
            return
        }
        let detectors = scene.detectors.filter(\.enabled)
        let key = ReadingsKey(field: ObjectIdentifier(shown.field), detectors: detectors)
        guard key != readingsKey else { return }
        readingsKey = key
        readingsTask?.cancel()
        guard !detectors.isEmpty else {
            detectorReadings = [:]
            return
        }
        let field = shown.field
        readingsTask = Task { [weak self] in
            let readings = await Task.detached(priority: .userInitiated) { () -> [DetectorReading] in
                let all = PerfProbe.time("readings.measure") { field.measure(detectors) }
                if !all.isEmpty || detectors.count == 1 { return all }
                // One detector the field cannot measure (outside its domain) fails the whole
                // call; measure the others one by one.
                return detectors.flatMap { field.measure([$0]) }
            }.value
            guard !Task.isCancelled, let self, self.readingsKey == key else { return }
            self.detectorReadings = Dictionary(readings.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    /// The incident amplitude readings are normalised by: A of the shown field.
    var readingAmplitude: Double {
        max(1e-300, solver.shown?.info.incidentPeak ?? 1)
    }

    /// A reading's total value over A² (a line's flux, a box's mean |E|²).
    func normalizedTotal(_ reading: DetectorReading) -> Double? {
        reading.totalValue.map { $0 / (readingAmplitude * readingAmplitude) }
    }

    /// The ratio total/incident when the incident part is large enough to divide by:
    /// 10⁻⁶ of the largest incident value among the readings.
    func meaningfulRatio(_ reading: DetectorReading) -> Double? {
        guard let incident = reading.incidentValue, let ratio = reading.ratio else { return nil }
        let largest = detectorReadings.values.compactMap { $0.kind == reading.kind ? $0.incidentValue.map(abs) : nil }.max() ?? 0
        guard abs(incident) > 1e-6 * largest, abs(incident) > 1e-12 * readingAmplitude * readingAmplitude else { return nil }
        return ratio
    }

    /// A short reading for the sidebar badge and the canvas label: a line's total/incident
    /// ratio ("0.82×"), or its power in A²·µm when nothing is incident on it; a box's mean
    /// |E|² in A².
    func readingSummary(_ reading: DetectorReading) -> String? {
        switch reading.kind {
        case .line:
            if let ratio = meaningfulRatio(reading) {
                return Format.number(ratio, digits: 2...2) + "×"
            }
            return normalizedTotal(reading).map { Format.number($0, digits: 2...2) + " $A^2$·µm" }
        case .box:
            return normalizedTotal(reading).map { Format.number($0, digits: 2...2) + " $A^2$" }
        }
    }

    /// Whether the readings belong to a field older than the scene.
    var readingsAreStale: Bool { solver.isShownStale }
}
