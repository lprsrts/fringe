import CFringeCore
import Foundation
import Observation

/// One chapter of the browser: its puzzles in order.
public struct PuzzleChapter: Identifiable, Equatable, Sendable {
    public var id: String
    /// "Steering Light".
    public var title: String
    public var puzzles: [PuzzleSummary]
}

/// The puzzle that is open, and its last Check.
public struct PuzzleSession {
    public var puzzle: Puzzle
    /// The JSON part of the last Check.
    public var evaluation: PuzzleEvaluation?
    /// Its per-source fields, in the order of `evaluation.sources`.
    public var fields: [FieldHandle] = []
    /// The design revision (`Puzzle.designRevision`) the Check belongs to.
    public var evaluatedRevision: Data?
    /// The field combined from `fields` that the canvas shows, if it shows one.
    public var shownField: FieldHandle?
    /// Why the last Check could not run, in a sentence.
    public var checkError: String?

    public var id: String { puzzle.id }
}

/// A Check that came back, with what the reveal needs to know about it.
struct CheckOutcome {
    var puzzleID: String
    var evaluation: PuzzleEvaluation
    var revision: Data
    /// Progress before and after the Check was taken in.
    var before: PuzzleProgress
    var after: PuzzleProgress
    var record: PuzzleProgress.RecordOutcome
    /// The last result a reveal showed for this puzzle since it was opened.
    var previous: RevealedResult?
    var firstCheckThisSession: Bool
    /// This Check passed the last unpassed puzzle of its chapter, not celebrated before.
    var chapterCompleted: Bool
}

/// Puzzle mode's state: the catalog, the player's progress, the open puzzle and the Check
/// job. `AppState` (AppState+Puzzles.swift) puts it together with the document and the
/// solver.
@MainActor
@Observable
public final class PuzzleController {
    /// Every bundled puzzle, by chapter then order.
    public let catalog: [PuzzleSummary]
    /// The catalog by chapter, in catalog order.
    public let chapters: [PuzzleChapter]
    /// By puzzle id, from the store; ids the core no longer lists are kept.
    public private(set) var progress: [String: PuzzleProgress]
    /// The open puzzle; nil shows the browser.
    public private(set) var session: PuzzleSession?
    /// The browser sidebar's selection: a chapter id, nil for all.
    public var browserChapter: String?
    public private(set) var checkJob: PuzzleJobHandle?
    /// The chart beside the truth table.
    public var resultChart = PuzzleResultChart.readings
    /// Reset's confirmation dialog.
    public var isResetConfirmationPresented = false
    public private(set) var checkProgress = FringeProgress()

    /// One short line per puzzle saying what to do, for the cards.
    @ObservationIgnored public let taskLines: [String: String]
    @ObservationIgnored private var puzzles: [String: Puzzle] = [:]
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var designTask: Task<Void, Never>?
    /// The open puzzle's design while it waits to be taken into `progress`.
    @ObservationIgnored private var pendingDesign: (id: String, design: [Element])?
    /// The last result a reveal showed, by puzzle, since the puzzle was opened.
    @ObservationIgnored private var lastRevealed: [String: RevealedResult] = [:]
    /// Puzzles checked in this app session.
    @ObservationIgnored private var checkedThisSession: Set<String> = []

    /// The puzzle open last, reopened when puzzle mode comes back.
    static let currentKey = "fringe.puzzles.current"

    /// The store this controller reads and writes: one store for both.
    let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let catalog = FringeBridge.puzzleList()
        self.catalog = catalog
        var chapters: [PuzzleChapter] = []
        for summary in catalog {
            if let last = chapters.indices.last, chapters[last].id == summary.chapter {
                chapters[last].puzzles.append(summary)
            } else {
                let title = (summary.chapterTitle?.isEmpty == false ? summary.chapterTitle! : summary.chapter.capitalizedFirst)
                chapters.append(PuzzleChapter(id: summary.chapter, title: title.titleCased, puzzles: [summary]))
            }
        }
        self.chapters = chapters
        progress = PuzzleProgressStore.load(from: defaults)
        var puzzles: [String: Puzzle] = [:]
        var lines: [String: String] = [:]
        for summary in catalog {
            guard let puzzle = FringeBridge.puzzle(summary.id) else { continue }
            puzzles[summary.id] = puzzle
            lines[summary.id] = puzzle.taskLine
        }
        self.puzzles = puzzles
        taskLines = lines
    }

    // MARK: Catalog

    public func puzzle(_ id: String) -> Puzzle? {
        if let cached = puzzles[id] { return cached }
        let loaded = FringeBridge.puzzle(id)
        if let loaded { puzzles[id] = loaded }
        return loaded
    }

    public func summary(_ id: String) -> PuzzleSummary? {
        catalog.first { $0.id == id }
    }

    public func taskLine(_ id: String) -> String {
        taskLines[id] ?? summary(id)?.title ?? id
    }

    public func progress(_ id: String) -> PuzzleProgress {
        var entry = progress[id] ?? PuzzleProgress()
        if let pending = pendingDesign, pending.id == id { entry.design = pending.design }
        return entry
    }

    /// Passed puzzles among `puzzles` (all by default).
    public func solvedCount(_ puzzles: [PuzzleSummary]? = nil) -> Int {
        (puzzles ?? catalog).filter { progress[$0.id]?.passed == true }.count
    }

    public func starCount(_ puzzles: [PuzzleSummary]? = nil) -> Int {
        (puzzles ?? catalog).reduce(0) { $0 + (progress[$1.id]?.stars ?? 0) }
    }

    /// Three stars a puzzle.
    public func maxStars(_ puzzles: [PuzzleSummary]? = nil) -> Int {
        3 * (puzzles ?? catalog).count
    }

    /// The puzzle before or after `id` in the catalog.
    public func neighbour(of id: String, by step: Int) -> PuzzleSummary? {
        guard let i = catalog.firstIndex(where: { $0.id == id }), catalog.indices.contains(i + step) else { return nil }
        return catalog[i + step]
    }

    // MARK: Session

    func begin(_ puzzle: Puzzle) {
        cancelCheck()
        // A puzzle just opened (or reset) has no revealed result: its next Check plays in full.
        lastRevealed[puzzle.id] = nil
        session = PuzzleSession(puzzle: puzzle)
        defaults.set(puzzle.id, forKey: Self.currentKey)
    }

    /// Back to the browser. The puzzle stays the one puzzle mode reopens.
    func end() {
        cancelCheck()
        flushDesign()
        session = nil
    }

    /// Forgets which puzzle was open, so puzzle mode opens on the browser.
    func forgetCurrent() {
        defaults.removeObject(forKey: Self.currentKey)
    }

    var currentPuzzleID: String? {
        defaults.string(forKey: Self.currentKey)
    }

    /// Updates the shown combined field and the Check of the session.
    func updateSession(_ change: (inout PuzzleSession) -> Void) {
        guard var s = session else { return }
        change(&s)
        session = s
    }

    /// Hints revealed so far in the open puzzle.
    public var hintsShown: Int {
        guard let session else { return 0 }
        return min(session.puzzle.hints.count, progress(session.id).hintsShown)
    }

    public func showHint() {
        guard let session, hintsShown < session.puzzle.hints.count else { return }
        progress[session.id, default: PuzzleProgress()].hintsShown = hintsShown + 1
        PuzzleProgressStore.save(progress, to: defaults)
    }

    // MARK: Design

    /// Keeps the player's elements; taken into `progress` and written to the store a second
    /// after the last change. Until then the design waits outside the observed progress, so
    /// a drag does not invalidate every view that reads progress at each move.
    func saveDesign(_ design: [Element], for id: String) {
        guard progress(id).design != design else { return }
        if let pending = pendingDesign, pending.id != id { commitPendingDesign() }
        pendingDesign = (id, design)
        designTask?.cancel()
        designTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            self.flushDesign()
        }
    }

    private func commitPendingDesign() {
        guard let pending = pendingDesign else { return }
        pendingDesign = nil
        if progress[pending.id]?.design != pending.design {
            progress[pending.id, default: PuzzleProgress()].design = pending.design
        }
    }

    /// Writes a pending design now.
    func flushDesign() {
        designTask?.cancel()
        designTask = nil
        guard pendingDesign != nil else { return }
        commitPendingDesign()
        PuzzleProgressStore.save(progress, to: defaults)
    }

    /// Removes the player's elements from the store; the best score stays.
    func clearDesign(for id: String) {
        if pendingDesign?.id == id {
            pendingDesign = nil
            designTask?.cancel()
            designTask = nil
        }
        guard progress[id]?.design != nil else { return }
        progress[id]?.design = nil
        PuzzleProgressStore.save(progress, to: defaults)
    }

    // MARK: Check

    public var isChecking: Bool { checkJob != nil }

    /// Scores `design` in the open puzzle off the main thread; `done` runs on the main actor
    /// with the session updated (or not, if the puzzle closed meanwhile), and with the
    /// outcome when a result came back.
    func startCheck(design: [Element], revision: Data, done: @escaping @MainActor (CheckOutcome?) -> Void) {
        guard let session, checkJob == nil else { return }
        let id = session.id
        let job: PuzzleJobHandle
        do {
            job = try PuzzleJobHandle(puzzleID: id, solutionJSON: FringeBridge.encode(design))
        } catch {
            updateSession { $0.checkError = Self.sentence(error) }
            return
        }
        updateSession { $0.checkError = nil }
        checkJob = job
        checkProgress = FringeProgress()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: SolveController.pollInterval)
                guard let self, self.checkJob === job else { return }
                PerfProbe.count("puzzle.poll")
                let progress = job.poll()
                self.checkProgress = progress
                if progress.state != FRINGE_JOB_RUNNING {
                    let outcome = self.finishCheck(job, puzzleID: id, revision: revision)
                    done(outcome)
                    return
                }
            }
        }
    }

    public func cancelCheck() {
        guard let job = checkJob else { return }
        job.cancel()
        poller?.cancel()
        poller = nil
        checkJob = nil
    }

    /// Takes the result in: the session's evaluation and the progress change at once (the
    /// data is never delayed; only what the views show is, by the reveal).
    private func finishCheck(_ job: PuzzleJobHandle, puzzleID: String, revision: Data) -> CheckOutcome? {
        checkJob = nil
        poller = nil
        let result: PuzzleResultHandle
        do {
            guard let taken = try job.takeResult() else { return nil }
            result = taken
        } catch {
            let error = error as? FringeError
            if error?.code != "cancelled", session?.id == puzzleID {
                updateSession { $0.checkError = error.map(Self.sentence) ?? "The check stopped without a result." }
            }
            return nil
        }
        guard session?.id == puzzleID else { return nil }
        guard let evaluation = result.evaluation else {
            AppState.log.error("Unreadable puzzle result: \(result.decodingError ?? "?", privacy: .public)")
            updateSession { $0.checkError = "The result of the check could not be read." }
            return nil
        }
        updateSession {
            $0.evaluation = evaluation
            $0.fields = result.fields
            $0.evaluatedRevision = revision
            $0.shownField = nil
        }
        let before = progress(puzzleID)
        let chapter = summary(puzzleID)?.chapter ?? puzzle(puzzleID)?.chapter
        let chapterWasDone = chapter.map(isChapterSolved) ?? true
        var record = PuzzleProgress.RecordOutcome()
        if evaluation.valid {
            record = progress[puzzleID, default: PuzzleProgress()].record(score: evaluation.score, stars: evaluation.stars, passed: evaluation.passed)
            if record.changed { PuzzleProgressStore.save(progress, to: defaults) }
        }
        let after = progress(puzzleID)
        var chapterCompleted = false
        if let chapter, !chapterWasDone, isChapterSolved(chapter),
           !PuzzleProgressStore.celebratedChapters(in: defaults).contains(chapter) {
            chapterCompleted = true
        }
        let first = !checkedThisSession.contains(puzzleID)
        checkedThisSession.insert(puzzleID)
        return CheckOutcome(puzzleID: puzzleID, evaluation: evaluation, revision: revision, before: before, after: after,
                            record: record, previous: lastRevealed[puzzleID], firstCheckThisSession: first,
                            chapterCompleted: chapterCompleted)
    }

    /// Keeps the result a reveal showed (or skipped to), for the next Check's comparison,
    /// and marks a celebrated chapter so it is celebrated only once.
    func noteRevealed(_ result: RevealedResult, puzzleID: String, celebratedChapter: Bool) {
        lastRevealed[puzzleID] = result
        if celebratedChapter, let chapter = summary(puzzleID)?.chapter ?? puzzle(puzzleID)?.chapter {
            PuzzleProgressStore.markCelebrated(chapter, in: defaults)
        }
    }

    /// Every puzzle of `chapter` passed.
    func isChapterSolved(_ chapter: String) -> Bool {
        guard let puzzles = chapters.first(where: { $0.id == chapter })?.puzzles, !puzzles.isEmpty else { return false }
        return puzzles.allSatisfy { progress[$0.id]?.passed == true }
    }

    public func chapterTitle(_ chapter: String) -> String? {
        chapters.first { $0.id == chapter }?.title
    }

    /// The field of one input case, combined from the Check's per-source fields; nil without
    /// a Check or when the case is not in it.
    func combinedField(bits: [Bool]) -> FieldHandle? {
        guard let session, let evaluation = session.evaluation, evaluation.valid,
              !session.fields.isEmpty, session.fields.count == evaluation.sources.count,
              let match = evaluation.case(bits: bits), match.weights.count == session.fields.count else { return nil }
        let weights = match.weights.map { (re: $0.first ?? 0, im: $0.count > 1 ? $0[1] : 0) }
        do {
            return try FieldHandle.combine(session.fields, weights: weights)
        } catch {
            AppState.log.error("Combining the checked fields failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func sentence(_ error: Error) -> String {
        if let error = error as? FringeError {
            let text = error.message.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? "The check failed (\(error.code))." : text.capitalizedFirst + (text.hasSuffix(".") ? "" : ".")
        }
        return error.localizedDescription
    }

    // MARK: Testing

    /// Replaces the progress (the shot harness seeds it); saved to the store.
    func setProgress(_ new: [String: PuzzleProgress]) {
        progress = new
        PuzzleProgressStore.save(new, to: defaults)
    }
}
