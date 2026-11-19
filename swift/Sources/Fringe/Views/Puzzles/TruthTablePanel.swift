import SwiftUI

/// The results slot in a puzzle: the input switches, the truth table (or the goal
/// detectors' table) with each row's verdict, the metric in a sentence, and the result
/// charts beside them. Its top edge resizes it, like the simulator's results.
struct TruthTablePanel: View {
    let model: AppState
    let columnHeight: CGFloat
    @AppStorage("fringe.puzzle.panel.height") private var storedHeight = TruthTablePanel.defaultHeight
    @UIState private var dragStartHeight: CGFloat?

    static let defaultHeight: CGFloat = 250
    static let minimumHeight: CGFloat = 170

    var body: some View {
        let _ = PerfProbe.body("TruthTablePanel")
        let height = clamped(storedHeight)
        VStack(spacing: 0) {
            handle(height: height)
            if let puzzle = model.activePuzzle, let report = model.puzzleReport {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 0) {
                        TableSection(model: model, puzzle: puzzle, report: report)
                            .padding(12)
                            .frame(minWidth: 330, idealWidth: 380, maxWidth: 440, alignment: .topLeading)
                        Divider()
                        ChartSection(model: model, puzzle: puzzle, report: report)
                            .padding(12)
                            .frame(minWidth: 300, maxWidth: .infinity)
                    }
                    .frame(minWidth: 640)
                    StackedPuzzleResults(model: model, puzzle: puzzle, report: report)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(height: height)
        .background(.background)
    }

    private var maximumHeight: CGFloat { max(Self.minimumHeight, columnHeight * 0.5) }

    private func clamped(_ value: CGFloat) -> CGFloat {
        min(maximumHeight, max(Self.minimumHeight, value))
    }

    private func handle(height: CGFloat) -> some View {
        Divider()
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartHeight ?? height
                        if dragStartHeight == nil { dragStartHeight = height }
                        storedHeight = clamped(start - value.translation.height)
                    }
                    .onEnded { _ in dragStartHeight = nil }
            )
            .pointerStyle(.rowResize)
            .accessibilityHidden(true)
            .padding(.vertical, -3)
    }
}

/// The header with the out-of-date note, the input switches and the table.
private struct TableSection: View {
    let model: AppState
    let puzzle: Puzzle
    let report: PuzzleReport
    var showsHeader = true

    var body: some View {
        let _ = PerfProbe.body("TableSection")
        let stale = report.isChecked && !model.isPuzzleCheckCurrent
        VStack(alignment: .leading, spacing: 8) {
            if showsHeader {
                PanelTitle(title: report.isTruthTable ? "Truth Table" : "Result", stale: stale)
            }
            if !puzzle.inputs.isEmpty {
                InputsBar(model: model, puzzle: puzzle)
            }
            if report.isTruthTable {
                CaseTable(model: model, puzzle: puzzle, report: report, stale: stale)
            } else {
                DetectorResultTable(model: model, report: report, stale: stale)
            }
            footnote(stale: stale)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func footnote(stale: Bool) -> some View {
        let evaluation = model.puzzles.session?.evaluation
        if model.puzzles.isChecking {
            Text("Checking every case…")
        } else if let evaluation, !evaluation.valid, !stale {
            Text("Not scored: the design breaks a rule (see Goal).")
        } else if let evaluation, let summary = evaluation.summary(scale: puzzle.scoreScale) {
            Text(summary).opacity(stale ? 0.6 : 1)
        } else {
            Text(report.isTruthTable ? "Check (⌘R) solves every case and fills in the table." : "Check (⌘R) solves the design and scores it.")
        }
    }
}

/// A panel title with an "Out of date" capsule.
private struct PanelTitle: View {
    let title: String
    var stale = false

    var body: some View {
        let _ = PerfProbe.body("PanelTitle")
        HStack(spacing: 8) {
            Text(title)
                .font(.headline)
            if stale {
                Text("Out of date")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color(red: 1, green: 0.75, blue: 0.2).opacity(0.92), in: Capsule())
                    .help("Out of date. Check again to score.")
            }
            Spacer(minLength: 0)
        }
        .frame(height: 22)
    }
}

/// One button-style toggle per input, and which case is shown.
private struct InputsBar: View {
    let model: AppState
    let puzzle: Puzzle

    var body: some View {
        let _ = PerfProbe.body("InputsBar")
        let bits = model.puzzleInputBits
        HStack(spacing: 6) {
            Text("Inputs")
                .foregroundStyle(.secondary)
            ForEach(Array(puzzle.inputs.enumerated()), id: \.offset) { i, id in
                let name = puzzle.scene[source: id]?.displayName ?? id
                Toggle(isOn: Binding(get: { bits.indices.contains(i) && bits[i] }, set: { model.setPuzzleInput(i, on: $0) })) {
                    Text("\(puzzle.inputLetters[i]) \(bits.indices.contains(i) && bits[i] ? "on" : "off")")
                        .monospacedDigit()
                }
                .toggleStyle(.button)
                .help(model.isPuzzleCheckCurrent
                      ? "Switch \(name); shows the checked case at once (⌃⌥\(i + 1))"
                      : "Switch \(name) (⌃⌥\(i + 1))")
                .accessibilityLabel("Input \(puzzle.inputLetters[i]), \(name)")
            }
            Spacer(minLength: 8)
            if let k = puzzle.allCases.firstIndex(of: bits) {
                Text("Showing case \(k + 1) of \(puzzle.allCases.count)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
    }
}

/// Column widths of the case table.
private enum Columns {
    static let input: CGFloat = 22
    static let target: CGFloat = 60
    static let measured: CGFloat = 68
    static let verdict: CGFloat = 22
}

/// The truth table: inputs, then per output the wanted bit and the measured value, then
/// the verdict. The shown case is highlighted; clicking a row shows that case.
private struct CaseTable: View {
    let model: AppState
    let puzzle: Puzzle
    let report: PuzzleReport
    let stale: Bool

    var body: some View {
        let _ = PerfProbe.body("CaseTable")
        let bits = model.puzzleInputBits
        let live = liveValues(bits: bits)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(report.letters, id: \.self) { letter in
                    MathText("$\(letter)$").frame(width: Columns.input)
                }
                ForEach(report.outputs) { output in
                    Text(output.name).lineLimit(1).frame(width: Columns.target, alignment: .center)
                    Text("Measured").lineLimit(1).frame(width: Columns.measured, alignment: .trailing)
                }
                Spacer(minLength: 0).frame(width: Columns.verdict)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.bottom, 3)
            Divider()
            ForEach(report.rows) { row in
                let shown = row.bits == bits
                Button {
                    model.setPuzzleInputs(row.bits)
                } label: {
                    HStack(spacing: 0) {
                        ForEach(Array(row.bits.enumerated()), id: \.offset) { _, bit in
                            Text(bit ? "1" : "0").frame(width: Columns.input)
                        }
                        ForEach(Array(row.cells.enumerated()), id: \.offset) { j, cell in
                            Text(cell.target.map { $0 ? "1" : "0" } ?? "—")
                                .frame(width: Columns.target)
                            measured(cell, live: shown && !report.isChecked ? live[report.outputs[j].id] : nil)
                                .frame(width: Columns.measured, alignment: .trailing)
                        }
                        verdict(row.passes)
                            .frame(width: Columns.verdict)
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 22)
                    .background {
                        if shown {
                            RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.22))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .monospacedDigit()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(report.accessibilityLabel(row))
                .accessibilityAddTraits(shown ? [.isSelected, .isButton] : .isButton)
                .help("Show this case")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private func measured(_ cell: PuzzleReport.Cell, live: String?) -> some View {
        if let live {
            Text(live)
                .foregroundStyle(.secondary)
                .help("Live reading on the shown case, as the puzzle scores it; Check to score every case")
        } else if !report.isChecked {
            Text("—")
                .foregroundStyle(.secondary)
                .help("Check to measure this case")
        } else {
            Text(report.valueStyle.format(cell.value))
                .fontWeight(cell.decisive ? .semibold : .regular)
                .opacity(stale ? 0.5 : 1)
                .help(ifAny: cell.decisive ? "This value sets the contrast" : nil)
        }
    }

    @ViewBuilder
    private func verdict(_ passes: Bool?) -> some View {
        if let passes, !stale {
            Image(systemName: passes ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(passes ? .green : .red)
                .accessibilityLabel(passes ? "Passes" : "Fails")
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }

    /// The shown field's own readings of the outputs, before any Check.
    private func liveValues(bits: [Bool]) -> [String: String] {
        guard !report.isChecked else { return [:] }
        var out: [String: String] = [:]
        for output in report.outputs {
            if let live = model.puzzleLiveLabel(output.id) { out[output.id] = live }
        }
        return out
    }
}

/// A puzzle with one case: Detector · Measured · Goal · verdict.
private struct DetectorResultTable: View {
    let model: AppState
    let report: PuzzleReport
    let stale: Bool

    var body: some View {
        let _ = PerfProbe.body("DetectorResultTable")
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            GridRow {
                Text("Detector")
                Text("Measured").gridColumnAlignment(.trailing)
                Text("Goal")
                Color.clear.frame(width: 14, height: 1)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(report.detectorRows) { row in
                GridRow {
                    Text(row.name).lineLimit(1)
                    Group {
                        if let value = row.value {
                            Text(report.valueStyle.format(value)).opacity(stale ? 0.5 : 1)
                        } else if let live = model.puzzleLiveLabel(row.id) {
                            Text(live)
                                .foregroundStyle(.secondary)
                                .help("Live reading, as the puzzle scores it; Check to score it")
                        } else {
                            Text("—").foregroundStyle(.secondary)
                                .help("Check to measure this")
                        }
                    }
                    .monospacedDigit()
                    Text(row.goal).foregroundStyle(.secondary).monospacedDigit()
                    if let passes = row.passes, !stale {
                        Image(systemName: passes ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(passes ? .green : .red)
                            .accessibilityLabel(passes ? "Passes" : "Fails")
                    } else {
                        Color.clear.frame(width: 14, height: 1)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// The result charts with their picker.
private struct ChartSection: View {
    let model: AppState
    let puzzle: Puzzle
    let report: PuzzleReport
    var showsHeader = true

    var body: some View {
        let _ = PerfProbe.body("ChartSection")
        let stale = report.isChecked && !model.isPuzzleCheckCurrent
        let chart = report.isTruthTable ? model.puzzles.resultChart : .readings
        VStack(alignment: .leading, spacing: 6) {
            if showsHeader {
                HStack(spacing: 8) {
                    // "Chart", as the narrow layout's Table | Chart picker calls it.
                    Text("Chart")
                        .font(.headline)
                    Spacer(minLength: 8)
                    if report.isTruthTable {
                        ChartPicker(model: model)
                    }
                }
                .frame(height: 22)
            }
            Group {
                if !report.isChecked {
                    Text(model.puzzles.isChecking ? "Checking…" : (model.isPuzzleCheckCurrent && model.puzzles.session?.evaluation?.valid == false
                            ? "Not scored: the design breaks a rule."
                            : (report.isTruthTable ? "Check to measure every case." : "Check to score the design.")))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if chart == .contrast, let spec = report.contrastSpec(puzzle: puzzle, evaluation: model.puzzles.session?.evaluation, stale: stale) {
                    PuzzleContrastPlot(spec: spec)
                } else {
                    PuzzleBarChart(spec: report.barSpec(puzzle: puzzle, shownBits: model.puzzleInputBits, stale: stale))
                }
            }
            .plotSurface(Color(nsColor: .windowBackgroundColor))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ChartPicker: View {
    let model: AppState

    var body: some View {
        let _ = PerfProbe.body("ChartPicker")
        Picker("Chart", selection: Binding(get: { model.puzzles.resultChart }, set: { model.puzzles.resultChart = $0 })) {
            ForEach(PuzzleResultChart.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .help("Bars per case, or the contrast between the 1s and the 0s")
    }
}

/// A narrow column: the table or the chart, one at a time.
private struct StackedPuzzleResults: View {
    enum Part: Hashable { case table, chart }

    let model: AppState
    let puzzle: Puzzle
    let report: PuzzleReport
    @UIState private var part = Part.table

    var body: some View {
        let _ = PerfProbe.body("StackedPuzzleResults")
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("Results", selection: $part) {
                    Text(report.isTruthTable ? "Table" : "Result").tag(Part.table)
                    Text("Chart").tag(Part.chart)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Show the table or the chart")
                if report.isChecked && !model.isPuzzleCheckCurrent {
                    PanelTitle(title: "", stale: true).fixedSize()
                }
                Spacer(minLength: 8)
                if part == .chart, report.isTruthTable {
                    ChartPicker(model: model)
                }
            }
            switch part {
            case .table: TableSection(model: model, puzzle: puzzle, report: report, showsHeader: false)
            case .chart: ChartSection(model: model, puzzle: puzzle, report: report, showsHeader: false)
            }
        }
        .padding(12)
    }
}
