import SwiftUI

/// What the open puzzle asks for and how the design does: the goal in one line, the pass
/// level, the score on its star scale and, after a Check, the verdict and the next star.
/// While a reveal runs, the score bar and the verdict follow it (each in its own small view,
/// so a reveal frame re-evaluates only what it changes).
struct GoalCard: View {
    let model: AppState
    let puzzle: Puzzle

    var body: some View {
        let _ = PerfProbe.body("GoalCard")
        let session = model.puzzles.session
        let evaluation = session?.evaluation
        let current = model.isPuzzleCheckCurrent
        let scale = puzzle.scoreScale
        let progress = model.shownProgress(puzzle.id)
        let revealing = model.reveal.plan?.puzzleID == puzzle.id
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Goal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(puzzle.taskLine)
                    .font(.body.weight(.semibold))
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                if let pass = puzzle.passLine {
                    Text(pass)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            GoalScoreBar(
                model: model,
                score: evaluation?.valid == true ? evaluation?.score : nil,
                puzzle: puzzle,
                dimmed: !current,
                best: progress.bestScore,
                revealing: revealing
            )
            verdict(evaluation: evaluation, current: current, scale: scale, progress: progress, revealing: revealing)
                .font(.callout)
                .monospacedDigit()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.fill.quaternary))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Goal")
    }

    @ViewBuilder
    private func verdict(evaluation: PuzzleEvaluation?, current: Bool, scale: PuzzleScoreScale, progress: PuzzleProgress, revealing: Bool) -> some View {
        if model.puzzles.isChecking {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Measuring…").foregroundStyle(.secondary)
            }
        } else if let error = model.puzzles.session?.checkError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
        } else if let evaluation, current {
            if evaluation.valid {
                RevealedVerdict(model: model, puzzle: puzzle, evaluation: evaluation, revealing: revealing)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    VerdictLine(text: "Not scored: the design breaks a rule.", passes: false)
                    ForEach(Array(issueLines(evaluation).enumerated()), id: \.offset) { _, line in
                        MathText(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } else if evaluation != nil {
            VStack(alignment: .leading, spacing: 2) {
                Text("Out of date. Check again to score.")
                    .foregroundStyle(.orange)
                best(progress, scale: scale)
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("Not checked yet. Check (⌘R) scores your design.")
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                best(progress, scale: scale)
            }
        }
    }

    @ViewBuilder
    private func best(_ progress: PuzzleProgress, scale: PuzzleScoreScale) -> some View {
        if let best = progress.bestScore {
            Text("Best so far: \(scale.format(best)), \(progress.stars) of 3 stars")
                .foregroundStyle(.secondary)
        }
    }

    /// The rule issues of an unscored design, each with the name of the part it is about.
    private func issueLines(_ evaluation: PuzzleEvaluation) -> [String] {
        evaluation.issues.filter(\.isError).map { issue in
            // The core's sentence often names the part already ("\"Slab\" lies outside…").
            if let i = issue.elementIndex, model.scene.elements.indices.contains(i),
               !issue.sentence.contains(model.scene.elements[i].displayName) {
                return MathTypesetter.escaped(model.scene.elements[i].displayName) + ": " + issue.mathSentence
            }
            return issue.mathSentence
        }
    }
}

/// The goal card's score bar. During a reveal it reads the meter's part of the frame alone.
private struct GoalScoreBar: View {
    let model: AppState
    let score: Double?
    let puzzle: Puzzle
    let dimmed: Bool
    let best: Double?
    let revealing: Bool

    var body: some View {
        let _ = PerfProbe.body("GoalScoreBar")
        let reveal = model.reveal
        let look: ScoreBar.RevealLook? = revealing ? {
            let m = reveal.meter
            return ScoreBar.RevealLook(x: m.x, opacity: m.opacity, starLand: m.starLand, starsFadeOnly: m.starsFadeOnly,
                                       best: m.bestScore, verdictShown: reveal.scoreRevealed)
        }() : nil
        ScoreBar(score: score, thresholds: puzzle.stars, pass: puzzle.passScore, scale: puzzle.scoreScale,
                 dimmed: dimmed, best: best, reveal: look)
            .plotSurface(Color(nsColor: .controlBackgroundColor))
            // A click on the bar during a reveal skips it without doing anything else.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { reveal.scoreBarFrame = $0 }
            // Gone from the window (the sidebar collapsed): its old spot is the canvas's again.
            .onDisappear { reveal.scoreBarFrame = nil }
            .help(revealing ? "Click, Space or Esc shows the result at once" : "")
    }
}

/// The verdict of a scored Check: "Measuring…" until a reveal reaches it, then the lines
/// fading in, and the extras of the result (a first solve, a new best, a chapter done).
private struct RevealedVerdict: View {
    let model: AppState
    let puzzle: Puzzle
    let evaluation: PuzzleEvaluation
    let revealing: Bool

    var body: some View {
        let _ = PerfProbe.body("RevealedVerdict")
        let reveal = model.reveal
        let stage = revealing ? reveal.stage : nil
        let opacity = stage?.verdictOpacity ?? 1
        let extras = stage?.extras ?? (reveal.settled?.puzzleID == puzzle.id ? reveal.settled?.extras ?? [] : [])
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                // The lines keep their height while hidden, so nothing below moves.
                checked
                    .opacity(opacity)
                    .accessibilityHidden(opacity == 0)
                if opacity == 0 {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Measuring…")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Revealing the result")
                        if stage?.showSkipHint == true {
                            Text("Space to skip")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .help("Click, Space or Esc shows the result at once")
                }
            }
            if !extras.isEmpty {
                ExtrasLine(model: model, puzzle: puzzle, extras: extras)
            }
        }
    }

    /// The verdict once: the stars are on the track above, so the lines say whether it
    /// passed, the score and what the next star needs.
    @ViewBuilder
    private var checked: some View {
        let scale = puzzle.scoreScale
        let score = evaluation.score
        VStack(alignment: .leading, spacing: 3) {
            if evaluation.passed {
                VerdictLine(text: "Passed. \(evaluation.stars) of 3 stars.", passes: true)
                if let score {
                    let next = nextStar(after: score, thresholds: evaluation.starThresholds.isEmpty ? puzzle.stars : evaluation.starThresholds, scale: scale)
                    Text("\(scale.label.capitalizedFirst) \(scale.format(score))" + (next.map { " · \($0)" } ?? ""))
                        .foregroundStyle(.secondary)
                }
            } else {
                let short = score.flatMap { RevealPlanner.shortfall(puzzle: puzzle, score: $0, passed: false) }
                VerdictLine(text: "Not passed yet: \(scale.label) \(score.map { scale.format($0) } ?? "—"), needs \(puzzle.passScore.map { scale.formatThreshold($0) } ?? "—")" + (short.map { " (\($0))" } ?? "") + ".", passes: false)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "next star at 15 dB", nil with every star.
    private func nextStar(after score: Double, thresholds: [Double], scale: PuzzleScoreScale) -> String? {
        thresholds.first(where: { $0 > score }).map { "next star at \(scale.formatThreshold($0))" }
    }
}

/// What a result adds: "Solved" the first time, "New best" when it beats the best, and the
/// chapter line when it is the last puzzle of its chapter to be solved. A new best is not
/// said beside a first solve.
private struct ExtrasLine: View {
    let model: AppState
    let puzzle: Puzzle
    let extras: Set<RevealExtra>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if extras.contains(.firstSolve) || extras.contains(.newBest) {
                HStack(spacing: 8) {
                    if extras.contains(.firstSolve) {
                        HStack(spacing: 5) {
                            // Both layers named, as in VerdictLine: the sidebar would draw
                            // the symbol in its own grey.
                            Image(systemName: "checkmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Color.white, Color.green)
                                .accessibilityHidden(true)
                            Text("Solved")
                        }
                        .font(.callout.weight(.semibold))
                        .accessibilityElement(children: .combine)
                    } else {
                        Text("New best")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if extras.contains(.chapterComplete) {
                let chapter = model.puzzles.chapters.first { $0.id == puzzle.chapter }
                HStack(spacing: 6) {
                    Text("\(chapter?.title ?? puzzle.chapter.capitalizedFirst): all \(chapter?.puzzles.count ?? 0) solved")
                        .font(.callout)
                    Button("Back to Puzzles") { model.closePuzzle() }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
        }
    }
}

/// A pass or fail symbol in its colour beside text in the label colour.
struct VerdictLine: View {
    let text: String
    let passes: Bool

    var body: some View {
        let _ = PerfProbe.body("VerdictLine")
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            // Palette rendering with both layers named: the sidebar would otherwise draw
            // the symbol in its own grey.
            Image(systemName: passes ? "checkmark.circle.fill" : "xmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.white, passes ? Color.green : Color.red)
                .accessibilityHidden(true)
            Text(text)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
