import SwiftUI

/// What the open puzzle asks for and how the design does: the goal in one line, the pass
/// level, the score on its star scale and, after a Check, the verdict and the next star.
struct GoalCard: View {
    let model: AppState
    let puzzle: Puzzle

    var body: some View {
        let _ = PerfProbe.body("GoalCard")
        let session = model.puzzles.session
        let evaluation = session?.evaluation
        let current = model.isPuzzleCheckCurrent
        let scale = puzzle.scoreScale
        let progress = model.puzzles.progress(puzzle.id)
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
            ScoreBar(
                score: evaluation?.valid == true ? evaluation?.score : nil,
                thresholds: puzzle.stars,
                pass: puzzle.passScore,
                scale: scale,
                dimmed: !current,
                best: progress.bestScore
            )
            .plotSurface(Color(nsColor: .controlBackgroundColor))
            verdict(evaluation: evaluation, current: current, scale: scale, progress: progress)
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
    private func verdict(evaluation: PuzzleEvaluation?, current: Bool, scale: PuzzleScoreScale, progress: PuzzleProgress) -> some View {
        if model.puzzles.isChecking {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            }
        } else if let error = model.puzzles.session?.checkError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
        } else if let evaluation, current {
            if evaluation.valid {
                checked(evaluation, scale: scale)
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

    /// The verdict once: the stars are on the track above, so the lines say whether it
    /// passed, the score and what the next star needs.
    @ViewBuilder
    private func checked(_ evaluation: PuzzleEvaluation, scale: PuzzleScoreScale) -> some View {
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
                VerdictLine(text: "Not passed yet: \(scale.label) \(score.map { scale.format($0) } ?? "—"), needs \(puzzle.passScore.map { scale.formatThreshold($0) } ?? "—").", passes: false)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "next star at 15 dB", nil with every star.
    private func nextStar(after score: Double, thresholds: [Double], scale: PuzzleScoreScale) -> String? {
        thresholds.first(where: { $0 > score }).map { "next star at \(scale.formatThreshold($0))" }
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
