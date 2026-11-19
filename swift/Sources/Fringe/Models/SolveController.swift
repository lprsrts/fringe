import CFringeCore
import Foundation
import Observation
import os

/// A finished solve and the scene it was solved for.
public struct SolveResult {
    public var field: FieldHandle
    public var info: FieldInfo
    public var revision: Data
    public var scene: SimScene
    public var quality: QualityName
    public var finishedAt: Date
    /// A drag's preview, at a capped resolution: the scene still owes a full preview.
    public var tracking = false

    public var id: ObjectIdentifier { ObjectIdentifier(field) }
}

/// A solve that failed, kept until the next result or edit.
public struct SolveFailure: Equatable {
    public var code: String
    public var message: String
    public var details: String
    public var quality: QualityName
    public var revision: Data
}

/// What the sidebar and the canvas badge say about the image.
public enum SolveStatus: Equatable {
    case none
    case preview
    case final(seconds: Double)
    case updating
    case outOfDate
    case error(QualityName)
    case notConverged

    public var title: String {
        switch self {
        case .none: return "Not solved"
        case .preview: return "Preview"
        case .final(let s): return "Final · \(SceneFormat.seconds(s))"
        case .updating: return "Updating…"
        case .outOfDate: return "Out of date"
        case .error(let quality): return "\(quality.title) failed"
        case .notConverged: return "Not converged"
        }
    }

    public var isError: Bool {
        if case .error = self { return true }
        return false
    }

    /// Amber states: the image does not show the current scene as it should.
    public var isWarning: Bool {
        switch self {
        case .outOfDate, .notConverged: return true
        default: return false
        }
    }
}

/// Runs previews and finals for the current scene.
///
/// Every physics edit is checked off the main thread. 250 ms after the last edit a preview
/// starts if the check passed, replacing any preview still running. While a slider or a
/// drag is tracking, a running preview is left to finish and only the newest scene runs
/// after it. Run Final suppresses previews until it ends; an edit cancels it.
@MainActor
@Observable
public final class SolveController {
    /// The scene check's report as the views see it, and the check revision it belongs to
    /// (`SimScene.checkRevision`). While `holdsReport` is set, a new report reaches these
    /// only when its verdict or issues differ; the controller's own decisions use the
    /// newest one (`latestReport`).
    public private(set) var report: CheckReport?
    public private(set) var reportRevision: Data?
    @ObservationIgnored private var latestReport: CheckReport?
    @ObservationIgnored private var latestReportRevision: Data?
    /// Set during a canvas drag: the solver checks the dragged scene several times a second,
    /// and its derived values (focal points, estimates) change at each step. Publishing
    /// each report re-evaluated every view that shows an issue. The views see the newest
    /// report again when this is cleared.
    @ObservationIgnored public var holdsReport = false {
        didSet { if holdsReport != oldValue { publishReport() } }
    }
    public private(set) var lastPreview: SolveResult?
    public private(set) var lastFinal: SolveResult?
    public private(set) var failure: SolveFailure?

    public private(set) var runningQuality: QualityName?
    public private(set) var progress = FringeProgress()

    /// Called on the main actor when the shown result changes.
    @ObservationIgnored public var onResult: () -> Void = {}
    /// Short notices such as "Final solve cancelled by edit".
    @ObservationIgnored public var onNotice: (String) -> Void = { _ in }

    @ObservationIgnored private var scene = SimScene()
    @ObservationIgnored public private(set) var revision = Data()
    /// The revision checks are keyed by: `revision` plus the detectors, which the core
    /// validates but which do not change the field.
    @ObservationIgnored public private(set) var checkRevision = Data()
    @ObservationIgnored private var tracking = false
    @ObservationIgnored private var previewDue = false
    @ObservationIgnored private var debounce: Task<Void, Never>?
    /// The quiet period after the last edit has passed.
    @ObservationIgnored private var debounceFired = true
    @ObservationIgnored private var job: JobHandle?
    @ObservationIgnored private var jobRevision = Data()
    @ObservationIgnored private var jobScene = SimScene()
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var userCancelled = false
    @ObservationIgnored private var checkInFlight = false
    @ObservationIgnored private var checkPending = false
    /// Shown result id, to tell `onResult` apart from no-op updates.
    @ObservationIgnored private var shownID: ObjectIdentifier?

    private static let log = Logger(subsystem: "com.asympton.fringe", category: "solve")
    public static let debounceInterval: Duration = .milliseconds(250)
    /// Polling runs only while a job does; 10 Hz is enough for the progress bar.
    public static let pollInterval: Duration = .milliseconds(100)
    /// The least time between two previews a drag starts.
    public static let trackingInterval: Duration = .milliseconds(500)
    @ObservationIgnored private var lastTrackingStart: ContinuousClock.Instant?
    @ObservationIgnored private var trackingRetry: Task<Void, Never>?
    @ObservationIgnored private var jobTracking = false

    public init() {}

    // MARK: Inputs

    /// Tells the controller about the scene. Only a new physics revision (anything but
    /// element names) marks the result stale and leads to a solve.
    public func update(scene: SimScene, tracking: Bool) {
        let wasTracking = self.tracking
        self.tracking = tracking
        self.scene = scene
        let newRevision = scene.physicsRevision
        let newCheckRevision = scene.checkRevision
        guard newRevision != revision else {
            if newCheckRevision != checkRevision {
                // Only the detectors changed: check again (they may now be outside the
                // domain), but the field stays. A scene that was blocked by a detector and
                // has no result yet gets its preview once the check passes.
                checkRevision = newCheckRevision
                requestCheck()
                if lastFinal?.revision != revision, lastPreview?.revision != revision, runningQuality == nil {
                    previewDue = true
                    if !tracking { schedulePreview() }
                }
            }
            // The end of a drag with no further change still owes the drag's last scene a
            // solve, also when a drag preview (capped resolution) already showed it.
            if wasTracking && !tracking {
                if let p = lastPreview, p.tracking, p.revision == revision, lastFinal?.revision != revision { previewDue = true }
                if previewDue { schedulePreview() }
            }
            return
        }
        revision = newRevision
        checkRevision = newCheckRevision
        PerfProbe.count("solve.newRevision")

        if runningQuality == .final {
            cancelJob()
            onNotice("Final solve cancelled by edit")
        }
        requestCheck()
        previewDue = true
        if tracking {
            debounce?.cancel()
            maybeStartPreview()
        } else {
            schedulePreview()
        }
        publishShown()
    }

    /// Solves the scene at final quality now.
    public func runFinal() {
        guard canRunFinal else { return }
        debounce?.cancel()
        debounceFired = true
        previewDue = false
        cancelJob()
        start(.final)
    }

    /// Cancels the running solve and keeps the last image.
    public func cancel() {
        guard job != nil else { return }
        userCancelled = true
        job?.cancel()
    }

    /// Starts a preview of the current scene right away, as at launch.
    public func previewNow() {
        debounce?.cancel()
        debounceFired = true
        previewDue = true
        if latestReport == nil || latestReportRevision != checkRevision { requestCheck() }
        maybeStartPreview()
    }

    // MARK: Outputs

    public var isRunning: Bool { runningQuality != nil }

    public var currentReport: CheckReport? {
        // While held, the shown report stands for the dragged scene.
        holdsReport || reportRevision == checkRevision ? report : nil
    }

    /// The final, when it shows the current scene; otherwise the newest result.
    public var shown: SolveResult? {
        if let f = lastFinal, f.revision == revision { return f }
        if let p = lastPreview, p.revision == revision { return p }
        switch (lastPreview, lastFinal) {
        case let (p?, f?): return p.finishedAt > f.finishedAt ? p : f
        case let (p?, nil): return p
        case let (nil, f?): return f
        default: return nil
        }
    }

    public var isShownStale: Bool {
        guard let shown else { return false }
        return shown.revision != revision
    }

    public var canRunFinal: Bool {
        guard runningQuality != .final else { return false }
        if let report = currentReport, report.isBlocked(.final) { return false }
        return true
    }

    /// The `too_large` issue that blocks a final, if any.
    public var finalTooLarge: Issue? {
        currentReport?.issues.first { $0.code == "too_large" && $0.isError && $0.applies(to: .final) }
    }

    public var currentFailure: SolveFailure? {
        guard let failure, failure.revision == revision else { return nil }
        return failure
    }

    public var status: SolveStatus {
        if let report = currentReport, !report.ok { return .error(.preview) }
        if let failure = currentFailure { return .error(failure.quality) }
        guard let shown else { return isRunning || previewDue ? .updating : .none }
        if shown.revision != revision {
            return isRunning || previewDue ? .updating : .outOfDate
        }
        if !shown.info.meta.converged { return .notConverged }
        if shown.quality == .final { return .final(seconds: shown.info.meta.wallS) }
        return .preview
    }

    /// "Solving · 42 % · 1.3 s" for the Run Final tooltip.
    public var progressDescription: String {
        guard let quality = runningQuality else { return "Run Final (⌘R)" }
        let stage: String
        switch progress.stage {
        case 0: stage = "Setting up"
        case 1: stage = "Building geometry"
        case 2: stage = "Assembling"
        case 3: stage = "Solving"
        case 4: stage = "Sampling"
        default: stage = "Finishing"
        }
        let percent = Int((progress.fraction * 100).rounded())
        return "\(quality.title) · \(stage) · \(percent) % · \(SceneFormat.fixed(progress.elapsed_s, 1)) s"
    }

    // MARK: Checking

    private func requestCheck() {
        guard !checkInFlight else {
            checkPending = true
            return
        }
        checkInFlight = true
        PerfProbe.count("solve.check")
        let scene = self.scene
        let revision = self.checkRevision
        Task {
            let report = await Task.detached(priority: .userInitiated) { FringeBridge.check(scene) }.value
            self.checkInFlight = false
            self.latestReport = report
            self.latestReportRevision = revision
            self.publishReport()
            if self.checkPending {
                self.checkPending = false
                self.requestCheck()
            }
            self.maybeStartPreview()
        }
    }

    /// Hands the newest report to the views, unless held and its verdict and issues are
    /// those already shown. Unchanged values are not written, so they invalidate nothing.
    private func publishReport() {
        guard let latest = latestReport else { return }
        if holdsReport, let shown = report, shown.ok == latest.ok, shown.issues == latest.issues { return }
        if report != latest { report = latest }
        if reportRevision != latestReportRevision { reportRevision = latestReportRevision }
    }

    // MARK: Previews

    private func schedulePreview() {
        debounce?.cancel()
        debounceFired = false
        debounce = Task { [weak self] in
            try? await Task.sleep(for: SolveController.debounceInterval)
            guard !Task.isCancelled, let self else { return }
            self.debounceFired = true
            self.maybeStartPreview()
        }
    }

    private func maybeStartPreview() {
        guard previewDue, runningQuality != .final else { return }
        // Outside a drag, wait for the quiet period after the last edit.
        if !tracking, !debounceFired { return }
        // A result for this scene already exists (for example after undoing back to it); a
        // drag's capped preview counts only while the drag goes on.
        if lastFinal?.revision == revision || (lastPreview?.revision == revision && (tracking || lastPreview?.tracking == false)) {
            previewDue = false
            return
        }
        if tracking {
            // Never cancel during a drag; the newest scene runs when this one ends, and
            // drag previews start at most every `trackingInterval`.
            if job != nil { return }
            if let report = latestReport, !report.ok, latestReportRevision == checkRevision { return }
            if let last = lastTrackingStart, ContinuousClock.now - last < Self.trackingInterval {
                guard trackingRetry == nil else { return }
                let wait = Self.trackingInterval - (ContinuousClock.now - last)
                trackingRetry = Task { [weak self] in
                    try? await Task.sleep(for: wait)
                    guard let self else { return }
                    self.trackingRetry = nil
                    self.maybeStartPreview()
                }
                return
            }
        } else {
            guard latestReportRevision == checkRevision, let report = latestReport else { return }
            guard report.ok else {
                previewDue = false
                return
            }
            if job != nil {
                if jobRevision == revision {
                    previewDue = false
                    return
                }
                cancelJob()
            }
        }
        previewDue = false
        if tracking { lastTrackingStart = .now }
        start(.preview, tracking: tracking)
    }

    // MARK: Jobs

    private func start(_ quality: QualityName, tracking: Bool = false) {
        let scene = self.scene
        let revision = self.revision
        let job: JobHandle
        do {
            job = try tracking ? JobHandle(trackingScene: scene) : JobHandle(scene: scene, quality: quality)
        } catch let error as FringeError {
            recordFailure(error, quality: quality, revision: revision)
            return
        } catch {
            recordFailure(FringeError(code: "internal", message: error.localizedDescription), quality: quality, revision: revision)
            return
        }
        PerfProbe.count("solve.start.\(tracking ? "tracking" : quality.rawValue)")
        self.job = job
        jobTracking = tracking
        jobRevision = revision
        jobScene = scene
        runningQuality = quality
        userCancelled = false
        progress = FringeProgress()
        Self.log.debug("Started \(quality.rawValue) \(scene.solver.method.rawValue)")
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: SolveController.pollInterval)
                guard let self, self.job === job else { return }
                PerfProbe.count("solve.poll")
                let progress = job.poll()
                self.progress = progress
                if progress.state != FRINGE_JOB_RUNNING {
                    self.finish(job, quality: quality)
                    return
                }
            }
        }
    }

    private func finish(_ job: JobHandle, quality: QualityName) {
        let revision = jobRevision
        let scene = jobScene
        let wasUserCancel = userCancelled
        self.job = nil
        poller = nil
        runningQuality = nil
        userCancelled = false
        do {
            guard let field = try job.takeResult() else {
                throw FringeError(code: "internal", message: "The solver stopped without a result.")
            }
            guard let info = field.info else {
                Self.log.error("Unreadable field info: \(field.infoJSON, privacy: .public)")
                throw FringeError(code: "internal", message: "Could not read the solved field's info.")
            }
            var result = SolveResult(field: field, info: info, revision: revision, scene: scene, quality: quality, finishedAt: Date())
            result.tracking = jobTracking
            if quality == .final { lastFinal = result } else { lastPreview = result }
            if failure?.revision == revision || failure?.quality == quality { failure = nil }
            Self.log.debug("Finished \(quality.rawValue) in \(info.meta.wallS) s")
        } catch let error as FringeError {
            if error.code == "cancelled" {
                if wasUserCancel { onNotice("\(quality.title) solve cancelled") }
            } else {
                recordFailure(error, quality: quality, revision: revision)
            }
        } catch {
            recordFailure(FringeError(code: "internal", message: error.localizedDescription), quality: quality, revision: revision)
        }
        publishShown(force: true)
        if previewDue { maybeStartPreview() }
    }

    /// Set by `restoreResults` when the parked results had a final running.
    @ObservationIgnored private var resumesFinal = false

    private func cancelJob() {
        guard let job else { return }
        PerfProbe.count("solve.cancel")
        job.cancel()
        poller?.cancel()
        poller = nil
        self.job = nil
        runningQuality = nil
        // Freed here; the worker thread finishes on its own.
    }

    private func recordFailure(_ error: FringeError, quality: QualityName, revision: Data) {
        // An invalid scene is already on screen through the check report.
        if error.code == "invalid" || error.code == "parse" { return }
        let details = (try? FringeBridge.encode(["code": error.code, "message": error.message]))
            ?? "\(error.code): \(error.message)"
        failure = SolveFailure(code: error.code, message: error.message, details: details, quality: quality, revision: revision)
        Self.log.error("\(quality.rawValue) solve failed: \(error.code) \(error.message)")
    }

    private func publishShown(force: Bool = false) {
        let id = shown?.id
        if force || id != shownID {
            shownID = id
            onResult()
        }
    }

    public func dismissFailure() {
        failure = nil
    }

    // MARK: Results from elsewhere

    /// Shows `field` as the preview of `scene`, as if it had been solved for it: a field
    /// combined from a puzzle's per-source fields. Call it before the document takes
    /// `scene`, so the coming update finds a result and starts no preview.
    public func adopt(_ field: FieldHandle, for scene: SimScene) {
        guard let info = field.info else { return }
        let revision = scene.physicsRevision
        if job != nil, jobRevision == revision { cancelJob() }
        lastPreview = SolveResult(field: field, info: info, revision: revision, scene: scene, quality: info.quality, finishedAt: Date())
        if failure?.revision == revision { failure = nil }
        if revision == self.revision { previewDue = false }
        publishShown(force: true)
    }

    /// The results kept for one document while another one is shown.
    public struct Results {
        var preview: SolveResult?
        var final: SolveResult?
        var failure: SolveFailure?
        /// A final was solving when the results were parked; it runs again on return.
        var finalWasRunning = false
    }

    /// Stops any solve and hands over the results, leaving none: for switching to a
    /// document of another mode. `restoreResults` puts them back.
    public func parkResults() -> Results {
        debounce?.cancel()
        debounceFired = true
        previewDue = false
        let finalWasRunning = runningQuality == .final
        cancelJob()
        let parked = Results(preview: lastPreview, final: lastFinal, failure: failure, finalWasRunning: finalWasRunning)
        lastPreview = nil
        lastFinal = nil
        failure = nil
        publishShown(force: true)
        return parked
    }

    /// Puts parked results back. Call it before the document they belong to comes back,
    /// so the coming update finds them and solves nothing again.
    public func restoreResults(_ results: Results) {
        cancelJob()
        lastPreview = results.preview
        lastFinal = results.final
        failure = results.failure
        resumesFinal = results.finalWasRunning
        publishShown(force: true)
    }

    /// After `restoreResults` and the document's return: starts a preview when the parked
    /// results hold none for the current scene (the parked solve was cancelled, or an edit
    /// came after it) and no solve is running or due.
    public func resumeIfUnsolved() {
        guard !revision.isEmpty, !isRunning else { return }
        // A final the switch stopped runs again, unless one for this scene is already here.
        if resumesFinal {
            resumesFinal = false
            if lastFinal?.revision != revision, canRunFinal {
                runFinal()
                return
            }
        }
        if lastFinal?.revision == revision || lastPreview?.revision == revision { return }
        if failure?.revision == revision { return }
        if previewDue, !debounceFired { return }
        previewNow()
    }

    /// Peak memory of the shown solve in MB: what the core measured, or else the check's
    /// estimate for the shown quality (`estimated` is then true).
    public var shownMemoryMb: (value: Double, estimated: Bool)? {
        guard let shown else { return nil }
        if let measured = shown.info.meta.memoryMb, measured.isFinite, measured > 0 { return (measured, false) }
        let estimates = currentReport?.estimates
        let estimate = shown.quality == .final ? estimates?.final : estimates?.preview
        guard let mb = estimate?.memoryMb, mb.isFinite, mb > 0 else { return nil }
        return (mb, true)
    }
}
