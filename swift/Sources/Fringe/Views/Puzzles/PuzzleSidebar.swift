import SwiftUI

/// The open puzzle's sidebar: the brief, the goal card, the parts the player may place,
/// their elements (the only rows that select), the puzzle's fixed parts and the hints.
struct PuzzleSidebar: View {
    @Environment(AppState.self) private var model

    var body: some View {
        let _ = PerfProbe.body("PuzzleSidebar")
        if let puzzle = model.activePuzzle {
            content(puzzle)
        } else {
            Color.clear
        }
    }

    private func content(_ puzzle: Puzzle) -> some View {
        let design = model.puzzleDesign
        let usage = model.paletteUsage
        let report = model.checkReport
        let ruleIssues = currentRuleIssues
        return List(selection: selection) {
            Section {
                PuzzleBrief(puzzle: puzzle)
                    .selectionDisabled()
                GoalCard(model: model, puzzle: puzzle)
                    .selectionDisabled()
                    .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
            } header: {
                Text("\(chapterTitle(puzzle)) · \(puzzle.order)")
            }

            Section {
                ForEach(Array(puzzle.rules.palette.enumerated()), id: \.offset) { index, entry in
                    PaletteRow(model: model, puzzle: puzzle, entry: entry, index: index,
                               used: usage.indices.contains(index) ? usage[index] : 0)
                        .selectionDisabled()
                }
            } header: {
                Text("Parts")
            } footer: {
                if let max = puzzle.rules.maxElements, puzzle.rules.palette.count > 1 || puzzle.rules.palette.first?.max != max {
                    Text("Up to \(max) \(max == 1 ? "part" : "parts") in all.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Your Elements") {
                if design.isEmpty {
                    Text("Add a part to start.")
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                } else {
                    ForEach(design, id: \.id) { element in
                        let index = model.scene.elementIndex(element.id) ?? -1
                        let errors = (report?.issues(forElement: index).contains(where: \.isError) ?? false) || ruleIssues.contains(index)
                        ElementRow(model: model, element: element, hasErrors: errors)
                            .tag(SidebarItem.element(element.id))
                            .contextMenu { ItemContextMenu(model: model, item: .element(element.id)) }
                    }
                }
            }

            let fixed = model.scene.elements.filter { puzzle.lockedIDs.contains($0.id) }
            if !fixed.isEmpty {
                Section("Fixed Parts") {
                    ForEach(fixed, id: \.id) { element in
                        Label {
                            HStack {
                                Text(element.displayName).lineLimit(1)
                                Spacer(minLength: 4)
                                MathText(element.material.badge)
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                Image(systemName: "lock.fill")
                                    .imageScale(.small)
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("Fixed")
                            }
                        } icon: {
                            Image(systemName: element.kind.symbol)
                        }
                        .tag(SidebarItem.element(element.id))
                        .help("Fixed by the puzzle")
                    }
                }
            }

            if !puzzle.hints.isEmpty {
                Section("Hints") {
                    HintRows(model: model, hints: puzzle.hints)
                        .selectionDisabled()
                }
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand(perform: model.selectedElementID.map { model.isPlayerItem(.element($0)) } == true ? { model.deleteSelectedItem() } : nil)
    }

    /// Indices of elements a current Check found breaking a rule.
    private var currentRuleIssues: Set<Int> {
        guard model.isPuzzleCheckCurrent, let evaluation = model.puzzles.session?.evaluation else { return [] }
        return Set(evaluation.issues.filter(\.isError).compactMap(\.elementIndex))
    }

    private func chapterTitle(_ puzzle: Puzzle) -> String {
        model.puzzles.chapters.first { $0.id == puzzle.chapter }?.title ?? puzzle.chapter.capitalizedFirst
    }

    private var selection: Binding<SidebarItem?> {
        Binding(
            get: { model.selection },
            set: { if let item = $0 { model.selection = item } }
        )
    }
}

/// Title and summary of the open puzzle.
private struct PuzzleBrief: View {
    let puzzle: Puzzle

    var body: some View {
        let _ = PerfProbe.body("PuzzleBrief")
        VStack(alignment: .leading, spacing: 6) {
            Text(puzzle.title.titleCased)
                .font(.title3.weight(.semibold))
            Text(puzzle.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// One palette entry: the kind, its materials, how many are left and an add button.
private struct PaletteRow: View {
    let model: AppState
    let puzzle: Puzzle
    let entry: PaletteEntry
    let index: Int
    let used: Int

    var body: some View {
        let _ = PerfProbe.body("PaletteRow")
        let canAdd = model.canAddPart(index)
        HStack(spacing: 6) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.kind.title)
                    Text(materials)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } icon: {
                Image(systemName: entry.kind.symbol)
            }
            Spacer(minLength: 4)
            Text(left)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            Button("Add \(entry.kind.title)", systemImage: "plus.circle") { model.addPart(index) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(!canAdd)
                .help(canAdd ? "Add a \(entry.kind.title.lowercased()) inside the allowed region" : "No more of these fit the puzzle's rules")
        }
        .accessibilityElement(children: .combine)
    }

    private var materials: String {
        entry.materials.isEmpty ? "Any material" : entry.materials.map { puzzle.materialTitle(named: $0) }.joined(separator: ", ")
    }

    /// "1 of 2 left", "No limit".
    private var left: String {
        guard let max = entry.max else { return "No limit" }
        return "\(Swift.max(0, max - used)) of \(max) left"
    }
}

/// The hints shown so far, numbered, and a button for the next one.
private struct HintRows: View {
    let model: AppState
    let hints: [String]

    var body: some View {
        let _ = PerfProbe.body("HintRows")
        let shown = model.puzzles.hintsShown
        ForEach(0..<shown, id: \.self) { i in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(i + 1).")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(hints[i])
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)
            .accessibilityElement(children: .combine)
        }
        if shown < hints.count {
            Button("Show Hint \(shown + 1) of \(hints.count)", systemImage: "lightbulb") { model.puzzles.showHint() }
                .buttonStyle(.borderless)
                .help("Show the next hint (⇧⌘H)")
        }
    }
}
