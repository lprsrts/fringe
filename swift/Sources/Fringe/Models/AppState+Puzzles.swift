import Foundation

// Puzzle mode: switching modes, opening and leaving puzzles, Check, and switching inputs.
//
// The simulator's document, selection and results are parked when puzzle mode takes the
// window and put back exactly when it returns. Every switch replaces the document outside
// undo and clears the undo actions, so an undo can never bring a document of the other mode
// (or of another puzzle) back. Saving writes only the simulator document; a puzzle keeps
// the player's elements in its progress instead.
extension AppState {
    /// Whether the window shows the puzzle browser (puzzle mode with no puzzle open).
    public var isPuzzleBrowser: Bool { mode == .puzzles && puzzles.session == nil }

    /// Whether the window shows a puzzle.
    public var isInPuzzle: Bool { mode == .puzzles && puzzles.session != nil }

    /// Switches mode. Puzzle mode opens `puzzle`, else the puzzle open last time, else the
    /// browser.
    public func setMode(_ new: AppMode, puzzle id: String? = nil) {
        if new == mode {
            if new == .puzzles, let id { openPuzzle(id) }
            return
        }
        clearNotice()
        switch new {
        case .puzzles:
            endTrackingForSwitch()
            let results = solver.parkResults()
            parkedSimulator = ParkedSimulator(document: document, selection: selection, results: results)
            if results.finalWasRunning {
                showNotice("Run Final stopped. It starts again when you return to the simulator.")
            }
            if persistsDocument { saveNow() }
            mode = .puzzles
            UserDefaults.standard.set(AppMode.puzzles.rawValue, forKey: Self.modeKey)
            undoManager?.removeAllActions(withTarget: self)
            if let id = id ?? puzzles.currentPuzzleID, puzzles.puzzle(id) != nil {
                openPuzzle(id)
            }
        case .simulator:
            leavePuzzle()
            mode = .simulator
            UserDefaults.standard.set(AppMode.simulator.rawValue, forKey: Self.modeKey)
            if let parked = parkedSimulator {
                parkedSimulator = nil
                solver.restoreResults(parked.results)
                replaceDocument(parked.document, selection: parked.selection)
                solver.resumeIfUnsolved()
            } else {
                undoManager?.removeAllActions(withTarget: self)
            }
        }
    }

    /// Opens a puzzle with the player's saved elements (or its starting parts) and every
    /// input on.
    public func openPuzzle(_ id: String) {
        guard let puzzle = puzzles.puzzle(id) else {
            showNotice("There is no puzzle \(id)")
            return
        }
        if mode != .puzzles {
            setMode(.puzzles, puzzle: id)
            return
        }
        leavePuzzle()
        let design = puzzles.progress(id).design ?? puzzle.startingParts
        let document = Self.puzzleDocument(puzzle, design: design, display: self.document.display)
        puzzles.begin(puzzle)
        _ = solver.parkResults()
        replaceDocument(document, selection: Self.firstSelection(in: puzzle, scene: document.scene))
    }

    /// Back to the browser; the design is saved and the puzzle stays the one ⌘2 reopens.
    public func closePuzzle() {
        guard isInPuzzle else { return }
        leavePuzzle()
        // The browser shows no canvas: stop the closed puzzle's preview.
        _ = solver.parkResults()
        clearNotice()
        undoManager?.removeAllActions(withTarget: self)
    }

    /// Opens the puzzle before (−1) or after (+1) the open one.
    public func openNeighbourPuzzle(_ step: Int) {
        guard let id = puzzles.session?.id, let next = puzzles.neighbour(of: id, by: step) else { return }
        openPuzzle(next.id)
    }

    /// Removes the player's elements and the last Check; the best score stays.
    public func resetPuzzle() {
        guard isInPuzzle, let puzzle = puzzles.session?.puzzle else { return }
        puzzles.cancelCheck()
        puzzles.clearDesign(for: puzzle.id)
        puzzles.begin(puzzle)
        let document = Self.puzzleDocument(puzzle, design: puzzle.startingParts, display: self.document.display)
        replaceDocument(document, selection: Self.firstSelection(in: puzzle, scene: document.scene))
    }

    private func leavePuzzle() {
        guard let puzzle = puzzles.session?.puzzle else { return }
        endTrackingForSwitch()
        puzzles.saveDesign(puzzle.design(in: document.scene), for: puzzle.id)
        puzzles.end()
    }

    /// A drag still in progress ends without an undo step of its own.
    private func endTrackingForSwitch() {
        while isTracking { endTracking("") }
    }

    /// The document of a puzzle: its scene composed with `design`, the image the shape of
    /// its domain (which is fixed: it is part of the score).
    static func puzzleDocument(_ puzzle: Puzzle, design: [Element], display: DisplaySettings) -> FringeDocument {
        var document = FringeDocument(scene: puzzle.compose(design: design), display: display)
        document.display.isPlaying = false
        document.display.showDetectors = true
        document.adoptDomainAspect()
        return document
    }

    private static func firstSelection(in puzzle: Puzzle, scene: SimScene) -> SidebarItem {
        puzzle.design(in: scene).first.map { .element($0.id) } ?? .illumination
    }

    // MARK: Inputs

    /// The input bits the scene shows, most significant first.
    public var puzzleInputBits: [Bool] {
        guard let puzzle = puzzles.session?.puzzle else { return [] }
        return puzzle.bits(in: scene)
    }

    /// Whether the last Check belongs to the current design (inputs aside).
    public var isPuzzleCheckCurrent: Bool {
        guard let session = puzzles.session, session.evaluation != nil, let revision = session.evaluatedRevision else { return false }
        return revision == session.puzzle.designRevision(of: scene)
    }

    /// Switches one input. With a current Check the case is combined from its per-source
    /// fields and shown at once, with no solve; otherwise the preview solves the new case.
    /// Not an undo step.
    public func setPuzzleInput(_ index: Int, on: Bool) {
        guard isInPuzzle, let puzzle = puzzles.session?.puzzle, puzzle.inputs.indices.contains(index) else { return }
        var new = document
        new.scene[source: puzzle.inputs[index]]?.enabled = on
        guard new != document else { return }
        if isPuzzleCheckCurrent, let field = puzzles.combinedField(bits: puzzle.bits(in: new.scene)) {
            // Before the document changes, so the solver finds a result for the new scene.
            solver.adopt(field, for: new.scene)
            puzzles.updateSession { $0.shownField = field }
        } else {
            puzzles.updateSession { $0.shownField = nil }
        }
        setDocumentQuietly(new)
    }

    public func togglePuzzleInput(_ index: Int) {
        guard puzzleInputBits.indices.contains(index) else { return }
        setPuzzleInput(index, on: !puzzleInputBits[index])
    }

    // MARK: Check

    /// Scores the current design (⌘R in a puzzle).
    public func checkPuzzle() {
        // Not during a drag: the drag's undo step and the scored design would part ways.
        guard isInPuzzle, let puzzle = puzzles.session?.puzzle, !puzzles.isChecking, !isTracking else { return }
        let design = puzzle.design(in: scene)
        let revision = puzzle.designRevision(of: scene)
        puzzles.startCheck(design: design, revision: revision) { [weak self] in
            self?.showCheckedCase()
        }
    }

    public func cancelPuzzleCheck() {
        puzzles.cancelCheck()
    }

    /// After a Check: the canvas shows the current case combined from the checked fields,
    /// if the design has not changed meanwhile.
    private func showCheckedCase() {
        guard isPuzzleCheckCurrent, let puzzle = puzzles.session?.puzzle,
              let field = puzzles.combinedField(bits: puzzle.bits(in: scene)) else { return }
        solver.adopt(field, for: scene)
        puzzles.updateSession { $0.shownField = field }
    }
}
