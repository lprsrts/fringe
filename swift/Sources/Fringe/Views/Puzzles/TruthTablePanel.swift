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
            TableFootnote(model: model, puzzle: puzzle, report: report, stale: stale)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The metric in a sentence under the table; during a reveal it waits for the verdict,
/// keeping its height.
private struct TableFootnote: View {
    let model: AppState
    let puzzle: Puzzle
    let report: PuzzleReport
    let stale: Bool

    var body: some View {
        let _ = PerfProbe.body("TableFootnote")
        let evaluation = model.puzzles.session?.evaluation
        if model.puzzles.isChecking {
            Text("Measuring every case…")
        } else if let evaluation, !evaluation.valid, !stale {
            Text("Not scored: the design breaks a rule (see Goal).")
        } else if let evaluation, let summary = evaluation.summary(scale: puzzle.scoreScale) {
            let opacity = model.reveal.plan != nil ? model.reveal.stage.verdictOpacity : 1
            Text(summary)
                .opacity((stale ? 0.6 : 1) * opacity)
                .accessibilityHidden(opacity == 0)
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
        // While a reveal steps through the cases the switches show the case being measured,
        // dimmed (display only: the inputs do not change).
        let focus = model.reveal.plan != nil ? model.reveal.focus : nil
        let measured = focus?.inputsDimmed == true ? focus?.highlightedCase.flatMap { puzzle.allCases.indices.contains($0) ? puzzle.allCases[$0] : nil } : nil
        let bits = measured ?? model.puzzleInputBits
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
                Text(measured != nil ? "Measuring case \(k + 1) of \(puzzle.allCases.count)" : "Showing case \(k + 1) of \(puzzle.allCases.count)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
        .opacity(measured != nil ? 0.55 : 1)
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
        let revealing = model.reveal.plan != nil
        let highlighted = revealing ? model.reveal.focus.highlightedCase : nil
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
                // The case being measured during a reveal, else the case shown.
                let shown = highlighted.map { $0 == row.id } ?? (row.bits == bits)
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
                            MeasuredCell(model: model, report: report, cell: cell, caseIndex: row.id, output: j,
                                         stale: stale, revealing: revealing, bold: cell.decisive)
                                .frame(width: Columns.measured, alignment: .trailing)
                        }
                        CaseVerdict(model: model, passes: row.passes, caseIndex: row.id, stale: stale, revealing: revealing)
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
                .accessibilityLabel(revealing ? report.letters.enumerated().map { "\($1) \(row.bits[$0] ? 1 : 0)" }.joined(separator: ", ") + ": not yet revealed"
                                    : report.accessibilityLabel(row))
                .accessibilityAddTraits(shown ? [.isSelected, .isButton] : .isButton)
                .help("Show this case")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

}

/// One measured value of the table. Before a Check, "—": a goal detector shows no number
/// until a Check measures it. During a reveal it counts up to its value (a delta reveal
/// starts from the previous value, dimmed), reading only the reveal's case values.
private struct MeasuredCell: View {
    let model: AppState
    let report: PuzzleReport
    let cell: PuzzleReport.Cell
    let caseIndex: Int
    let output: Int
    let stale: Bool
    let revealing: Bool
    var bold = false

    var body: some View {
        if revealing {
            let cases = model.reveal.cases
            let value = cases.values.indices.contains(caseIndex) && cases.values[caseIndex].indices.contains(output)
                ? cases.values[caseIndex][output] : nil
            let dimmed = cases.dimmed.indices.contains(caseIndex) && cases.dimmed[caseIndex]
            let opacity = cases.opacity.indices.contains(caseIndex) ? cases.opacity[caseIndex] : 1
            if let value {
                Text(report.valueStyle.format(value))
                    .fontWeight(bold && !dimmed ? .semibold : .regular)
                    .opacity((dimmed ? 0.5 : 1) * opacity)
            } else {
                Text("—")
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Not yet revealed")
            }
        } else if !report.isChecked || cell.value == nil {
            Text("—")
                .foregroundStyle(.secondary)
                .help("Check to measure")
                .accessibilityLabel("Not measured; Check to measure")
        } else {
            Text(report.valueStyle.format(cell.value))
                .fontWeight(bold ? .semibold : .regular)
                .opacity(stale ? 0.5 : 1)
                .help(ifAny: cell.decisive ? "This value sets the contrast" : nil)
        }
    }
}

/// A case's ✓ or ✗; during a reveal it appears when its count ends.
private struct CaseVerdict: View {
    let model: AppState
    let passes: Bool?
    let caseIndex: Int
    let stale: Bool
    let revealing: Bool

    var body: some View {
        let shown: Bool = {
            guard revealing else { return true }
            let v = model.reveal.cases.verdictShown
            return v.indices.contains(caseIndex) && v[caseIndex]
        }()
        if let passes, !stale, shown {
            Image(systemName: passes ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(passes ? .green : .red)
                .accessibilityLabel(passes ? "Passes" : "Fails")
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }
}

/// A puzzle with one case: Detector · Measured · Goal · verdict.
private struct DetectorResultTable: View {
    let model: AppState
    let report: PuzzleReport
    let stale: Bool

    var body: some View {
        let _ = PerfProbe.body("DetectorResultTable")
        let revealing = model.reveal.plan != nil
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
            ForEach(Array(report.detectorRows.enumerated()), id: \.element.id) { j, row in
                GridRow {
                    Text(row.name).lineLimit(1)
                    MeasuredCell(model: model, report: report, cell: PuzzleReport.Cell(value: row.value),
                                 caseIndex: 0, output: j, stale: stale, revealing: revealing)
                        .monospacedDigit()
                    Text(row.goal).foregroundStyle(.secondary).monospacedDigit()
                    CaseVerdict(model: model, passes: row.passes, caseIndex: 0, stale: stale, revealing: revealing)
                        .frame(minWidth: 14)
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
                    Text(model.puzzles.isChecking ? "Measuring…" : (model.isPuzzleCheckCurrent && model.puzzles.session?.evaluation?.valid == false
                            ? "Not scored: the design breaks a rule."
                            : (report.isTruthTable ? "Check to measure every case." : "Check to score the design.")))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.reveal.plan != nil {
                    RevealChart(model: model, puzzle: puzzle, report: report, chart: chart)
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

/// The chart while a reveal runs: bars grow with their cases, the contrast plot shows the
/// cases measured so far, and the gap and its size wait for the verdict.
private struct RevealChart: View {
    let model: AppState
    let puzzle: Puzzle
    let report: PuzzleReport
    let chart: PuzzleResultChart

    var body: some View {
        let _ = PerfProbe.body("RevealChart")
        let reveal = model.reveal
        let cases = reveal.cases
        let highlighted = reveal.focus.highlightedCase
        let verdict = reveal.stage.verdictOpacity > 0
        func value(_ k: Int, _ j: Int) -> Double? {
            cases.values.indices.contains(k) && cases.values[k].indices.contains(j) ? cases.values[k][j] : nil
        }
        func verdictShown(_ k: Int) -> Bool { cases.verdictShown.indices.contains(k) && cases.verdictShown[k] }
        if chart == .contrast, report.isTruthTable,
           var spec = report.contrastSpec(puzzle: puzzle, evaluation: model.puzzles.session?.evaluation, stale: false) {
            // The axis covers the cases shown so far (their final values), so it does not
            // hint at a case before it plays and changes only when a case lands.
            var landedValues: [Double] = []
            for (r, c) in report.contrasts.enumerated() where spec.rows.indices.contains(r) {
                guard let j = report.outputs.firstIndex(where: { $0.id == c.output.id }) else { continue }
                let ones = c.ones.compactMap { o in value(o.case, j).map { (o.case, max($0, PuzzleReport.floor)) } }
                let zeros = c.zeros.compactMap { z in value(z.case, j).map { (z.case, max($0, PuzzleReport.floor)) } }
                spec.rows[r].ones = ones.map(\.1)
                spec.rows[r].oneCases = ones.map(\.0)
                spec.rows[r].zeros = zeros.map(\.1)
                spec.rows[r].zeroCases = zeros.map(\.0)
                let landed = (c.ones + c.zeros).filter { verdictShown($0.case) }
                landedValues += landed.map { max($0.value, PuzzleReport.floor) }
            }
            spec.axisValues = landedValues
            spec.showsGap = verdict
            if !verdict {
                spec.status = nil
                spec.passes = nil
            }
            return AnyView(PuzzleContrastPlot(spec: spec))
        }
        var spec = report.barSpec(puzzle: puzzle, shownBits: [], stale: false)
        // The axis grows with the bars as they count, so its top does not give the result
        // away. A minimize goal's bars shrink from the reference, so its axis holds that.
        let starts = reveal.plan?.cases.flatMap(\.from) ?? []
        spec.axisMax = spec.panels.map { _ in
            report.isTruthTable ? 0 : (starts.max().map(spec.plotted) ?? 0)
        }
        for p in spec.panels.indices {
            for k in spec.panels[p].bars.indices {
                // Truth tables: a panel per output, a bar per case. Otherwise one panel, a
                // bar per goal detector of the one case.
                let (caseIndex, output) = report.isTruthTable ? (k, p) : (0, k)
                let v = value(caseIndex, output)
                spec.panels[p].bars[k].value = v
                if !verdictShown(caseIndex) { spec.panels[p].bars[k].passes = nil }
                spec.panels[p].bars[k].isShown = report.isTruthTable && highlighted == k
                if !verdict { spec.panels[p].bars[k].aim = nil }
            }
            if !verdict {
                spec.panels[p].gap = nil
                spec.panels[p].gapLabel = nil
            }
        }
        return AnyView(PuzzleBarChart(spec: spec))
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
