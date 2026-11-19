import AppKit

// The reveal of a Check result as the window uses it: planning and beginning it when a
// result arrives, the canvas stepping through the cases, and the progress the goal card
// shows while it runs.
extension AppState {
    /// A Check came back: plan its reveal from the result and the last revealed one, and
    /// begin it. The data is already in place; the reveal only delays what views show.
    func beginReveal(_ outcome: CheckOutcome) {
        guard isInPuzzle, let puzzle = activePuzzle, puzzle.id == outcome.puzzleID else { return }
        let evaluation = outcome.evaluation
        guard evaluation.valid else {
            reveal.onInvalidDesign?()
            return
        }
        // The design changed while it was checked: the result is out of date, nothing to reveal.
        guard isPuzzleCheckCurrent else { return }
        let options = reveal.options(animate: soundSettings.animateResults,
                                     soundOn: revealAssumesSoundForTesting || sound.isAllowed)
        guard let plan = RevealPlanner.plan(
            evaluation: evaluation, revision: outcome.revision, previous: outcome.previous, puzzle: puzzle,
            shownBits: puzzleInputBits, before: outcome.before, after: outcome.after,
            firstCheckThisSession: outcome.firstCheckThisSession, chapterCompleted: outcome.chapterCompleted,
            options: options) else { return }
        let shown = RevealPlanner.revealed(report: PuzzleReport(puzzle: puzzle, evaluation: evaluation),
                                           evaluation: evaluation, revision: outcome.revision)
        puzzles.noteRevealed(shown, puzzleID: puzzle.id, celebratedChapter: plan.extras.contains { $0.extra == .chapterComplete })
        prepareRevealCanvas(plan)
        reveal.begin(plan)
    }

    /// The case fields the canvas steps through, combined from the Check's fields and drawn
    /// with one colour scale for all of them (the largest), so a dark case looks dark beside
    /// a bright one. Uploads start now, during the 80 ms hold; a case whose upload is not
    /// done when its turn comes leaves the canvas where it is.
    private func prepareRevealCanvas(_ plan: RevealPlan) {
        viewport.revealCaseFields = []
        guard plan.canvasSteps, !viewportUsesCPU, let gpu = FieldGPU.shared else { return }
        let display = self.display
        var fields: [FieldHandle?] = []
        var scale = 0.0
        PerfProbe.time("reveal.prepareCanvas") {
            for c in plan.cases {
                let field = puzzles.combinedField(bits: c.bits)
                fields.append(field)
                guard let field else { continue }
                let s = field.colourScale(viewJSON: display.viewJSON(viewRect: nil, incidentAmplitude: field.info?.incidentPeak ?? 1))
                if s.isFinite, s > 0 { scale = max(scale, s) }
            }
        }
        guard scale > 0 else { return }
        viewport.revealCaseFields = fields
        viewport.revealScale = scale
        gpu.extraParts = fields.count
        for field in fields.compactMap({ $0 }) {
            _ = gpu.buffer(for: field, part: display.part) {}
        }
    }

    /// The canvas shows case `index` of the running reveal, or the player's case (nil).
    func showRevealCase(_ index: Int?) {
        let fields = viewport.revealCaseFields
        let next = index.flatMap { fields.indices.contains($0) ? fields[$0] : nil }
            .map { RevealCanvasCase(field: $0, scale: viewport.revealScale) }
        if next?.field !== viewport.revealCase?.field { viewport.revealCase = next }
    }

    func revealEnded() {
        if viewport.revealCase != nil { viewport.revealCase = nil }
        viewport.revealCaseFields = []
        FieldGPU.shared?.extraParts = 0
    }

    /// A puzzle's progress as the window shows it: during a reveal, as it was before the
    /// Check until the verdict, so a new best or a first solve is not given away early.
    func shownProgress(_ id: String) -> PuzzleProgress {
        if !reveal.scoreRevealed, let plan = reveal.plan, plan.puzzleID == id { return plan.before }
        return puzzles.progress(id)
    }

    /// Case `index`'s checked values and wrong outputs, for the toggle tone (§1.9).
    func noteShownCheckedCase(bits: [Bool]) {
        guard let hook = reveal.onShowCheckedCase, isPuzzleCheckCurrent, !NSWorkspace.shared.isVoiceOverEnabled,
              let report = puzzleReport, report.isTruthTable, let k = report.rowIndex(bits: bits) else { return }
        PerfProbe.count("sound.checkedCase")
        let row = report.rows[k]
        hook(k, row.cells.map(\.value), row.cells.map { $0.passes == false })
    }
}

/// A case the canvas shows during a reveal, with the colour scale shared by every case.
struct RevealCanvasCase {
    let field: FieldHandle
    let scale: Double
}
