import CBeamCore
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
    case error
    case notConverged

    public var title: String {
        switch self {
        case .none: return "Not solved"
        case .preview: return "Preview"
        case .final(let s): return "Final · \(SceneFormat.seconds(s))"
        case .updating: return "Updating…"
        case .outOfDate: return "Out of date"
        case .error: return "Error"
        case .notConverged: return "Not converged"
        }
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
    public private(set) var report: CheckReport?
    /// The revision `report` belongs to.
    public private(set) var reportRevision: Data?
    public private(set) var lastPreview: SolveResult?
    public private(set) var lastFinal: SolveResult?
    public private(set) var failure: SolveFailure?

    public private(set) var runningQuality: QualityName?
    public private(set) var progress = BeamProgress()

    /// Called on the main actor when the shown result changes.
    @ObservationIgnored public var onResult: () -> Void = {}
    /// Short notices such as "Final solve cancelled by edit".
    @ObservationIgnored public var onNotice: (String) -> Void = { _ in }

    @ObservationIgnored private var scene = SimScene()
    @ObservationIgnored public private(set) var revision = Data()
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

    private static let log = Logger(subsystem: "com.asympton.beam-bg", category: "solve")
    public static let debounceInterval: Duration = .milliseconds(250)
    public static let pollInterval: Duration = .milliseconds(50)

    public init() {}

    // MARK: Inputs

    /// Tells the controller about the scene. Only a new physics revision (anything but
    /// element names) marks the result stale and leads to a solve.
    public func update(scene: SimScene, tracking: Bool) {
        let wasTracking = self.tracking
        self.tracking = tracking
        self.scene = scene
        let newRevision = scene.physicsRevision
        guard newRevision != revision else {
            // The end of a drag with no further change still owes the drag's last scene a solve.
            if wasTracking && !tracking && previewDue { schedulePreview() }
            return
        }
        revision = newRevision

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
        if report == nil || reportRevision != revision { requestCheck() }
        maybeStartPreview()
    }

    // MARK: Outputs

    public var isRunning: Bool { runningQuality != nil }

    public var currentReport: CheckReport? {
        reportRevision == revision ? report : nil
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
        if let report = currentReport, !report.ok { return .error }
        if currentFailure != nil { return .error }
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
        let scene = self.scene
        let revision = self.revision
        Task {
            let report = await Task.detached(priority: .userInitiated) { BeamBridge.check(scene) }.value
            self.checkInFlight = false
            self.report = report
            self.reportRevision = revision
            if self.checkPending {
                self.checkPending = false
                self.requestCheck()
            }
            self.maybeStartPreview()
        }
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
        // A result for this scene already exists (for example after undoing back to it).
        if lastFinal?.revision == revision || lastPreview?.revision == revision {
            previewDue = false
            return
        }
        if tracking {
            // Never cancel during a drag; the newest scene runs when this one ends.
            if job != nil { return }
            if let report, !report.ok, reportRevision == revision { return }
        } else {
            guard reportRevision == revision, let report else { return }
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
        start(.preview)
    }

    // MARK: Jobs

    private func start(_ quality: QualityName) {
        let scene = self.scene
        let revision = self.revision
        let job: JobHandle
        do {
            job = try JobHandle(scene: scene, quality: quality)
        } catch let error as BeamError {
            recordFailure(error, quality: quality, revision: revision)
            return
        } catch {
            recordFailure(BeamError(code: "internal", message: error.localizedDescription), quality: quality, revision: revision)
            return
        }
        self.job = job
        jobRevision = revision
        jobScene = scene
        runningQuality = quality
        userCancelled = false
        progress = BeamProgress()
        Self.log.debug("Started \(quality.rawValue) \(scene.solver.method.rawValue)")
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: SolveController.pollInterval)
                guard let self, self.job === job else { return }
                let progress = job.poll()
                self.progress = progress
                if progress.state != BEAM_JOB_RUNNING {
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
                throw BeamError(code: "internal", message: "The solver stopped without a result.")
            }
            guard let info = field.info else {
                Self.log.error("Unreadable field info: \(field.infoJSON, privacy: .public)")
                throw BeamError(code: "internal", message: "Could not read the solved field's info.")
            }
            let result = SolveResult(field: field, info: info, revision: revision, scene: scene, quality: quality, finishedAt: Date())
            if quality == .final { lastFinal = result } else { lastPreview = result }
            if failure?.revision == revision || failure?.quality == quality { failure = nil }
            Self.log.debug("Finished \(quality.rawValue) in \(info.meta.wallS) s")
        } catch let error as BeamError {
            if error.code == "cancelled" {
                if wasUserCancel { onNotice("\(quality.title) solve cancelled") }
            } else {
                recordFailure(error, quality: quality, revision: revision)
            }
        } catch {
            recordFailure(BeamError(code: "internal", message: error.localizedDescription), quality: quality, revision: revision)
        }
        publishShown(force: true)
        if previewDue { maybeStartPreview() }
    }

    private func cancelJob() {
        guard let job else { return }
        job.cancel()
        poller?.cancel()
        poller = nil
        self.job = nil
        runningQuality = nil
        // Freed here; the worker thread finishes on its own.
    }

    private func recordFailure(_ error: BeamError, quality: QualityName, revision: Data) {
        // An invalid scene is already on screen through the check report.
        if error.code == "invalid" || error.code == "parse" { return }
        let details = (try? BeamBridge.encode(["code": error.code, "message": error.message]))
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
}
