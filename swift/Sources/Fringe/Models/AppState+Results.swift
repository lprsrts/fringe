import Foundation

/// One row of the results table: a detector and its reading on the shown field.
public struct DetectorResultRow: Identifiable, Equatable {
    public var id: String
    public var name: String
    public var kind: DetectorKind
    public var enabled: Bool
    /// A line's net power per µm in z over A², or a box's mean |E|² over A².
    public var total: Double?
    public var incident: Double?
    /// Total over incident; nil where the incident value is too small to divide by.
    public var ratio: Double?
}

// The results area: the detector table and the |E|² profile along a line detector.
extension AppState {
    public func toggleResults() {
        isResultsPresented.toggle()
    }

    /// A scene that arrives with detectors (an opened file, a template, the document at
    /// launch) shows their readings: the results open and follow the first one. At launch
    /// this happens only once, so results the user hid stay hidden; opening a scene always
    /// shows them.
    func showResultsForLoadedDetectors(onlyOnce: Bool) {
        guard let first = scene.detectors.first(where: \.enabled) ?? scene.detectors.first else { return }
        if resultsDetector == nil { resultsSelection = first.id }
        if onlyOnce, UserDefaults.standard.bool(forKey: Self.resultsOpenedKey) { return }
        UserDefaults.standard.set(true, forKey: Self.resultsOpenedKey)
        isResultsPresented = true
    }

    /// The detector the results area is about, if it still exists.
    public var resultsDetector: Detector? {
        resultsSelection.flatMap { scene[detector: $0] }
    }

    /// One row per detector in scene order, with the readings of the shown field.
    public var resultRows: [DetectorResultRow] {
        let a2 = readingAmplitude * readingAmplitude
        return scene.detectors.map { detector in
            var row = DetectorResultRow(id: detector.id, name: detector.displayName, kind: detector.kind, enabled: detector.enabled)
            if detector.enabled, let reading = detectorReadings[detector.id] {
                row.total = reading.totalValue.map { $0 / a2 }
                row.incident = reading.incidentValue.map { $0 / a2 }
                row.ratio = meaningfulRatio(reading)
            }
            return row
        }
    }

    /// The profile key for a line on the shown field, nil without a field.
    public func profileKey(for line: LineGeometry) -> ProfileKey? {
        solver.shown.map { ProfileKey(field: ObjectIdentifier($0.field), line: line) }
    }

    /// Samples |E|² along `line` on the shown field in the background, once per field and
    /// line; the result lands in `profiles`. Profiles of older fields are dropped.
    public func requestProfile(for line: LineGeometry) {
        guard let shown = solver.shown, let key = profileKey(for: line) else { return }
        // Only the shown field's profiles are kept: a freed field's identifier can be reused.
        for old in profiles.keys where old.field != key.field { profiles[old] = nil }
        for (old, task) in profileTasks where old.field != key.field {
            task.cancel()
            profileTasks[old] = nil
        }
        guard profiles[key] == nil, profileTasks[key] == nil else { return }
        // A dragged endpoint asks for many lines: keep only the newest few.
        if profiles.count > 16 { profiles.removeAll() }
        let field = shown.field
        let amplitude = readingAmplitude
        profileTasks[key] = Task { [weak self] in
            let points = await Task.detached(priority: .userInitiated) {
                PerfProbe.time("profile.sample") { LineProfile.sample(field: field, line: line, amplitude: amplitude) }
            }.value
            guard let self else { return }
            self.profileTasks[key] = nil
            guard !Task.isCancelled else { return }
            self.profiles[key] = points
        }
    }
}
