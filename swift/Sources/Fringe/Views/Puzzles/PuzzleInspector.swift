import SwiftUI

/// The materials a puzzle's palette allows for one kind of part, by palette name.
struct MaterialChoices: Equatable {
    struct Choice: Equatable, Identifiable {
        /// The palette name ("pec", "silver", "dense-glass").
        var id: String
        /// "Silver", "Dense glass (n = 2)".
        var title: String
        var material: Material
    }

    var choices: [Choice]
    /// False for a part of a kind the palette does not have: its material stays as it is.
    var kindAllowed = true

    /// The choice `material` is, if any.
    func choice(for material: Material) -> Choice? {
        choices.first { $0.material.sameSubstance(as: material) }
    }
}

extension AppState {
    /// The materials the open puzzle allows for `element`'s kind; nil when one of its
    /// palette entries allows any material (then the full editor shows). A kind the palette
    /// does not have keeps its material.
    func materialChoices(for element: Element) -> MaterialChoices? {
        guard let puzzle = activePuzzle else { return nil }
        let entries = puzzle.rules.palette.filter { $0.kind == element.shape.kind }
        if entries.isEmpty {
            return MaterialChoices(choices: [.init(id: "", title: "Fixed", material: element.material)], kindAllowed: false)
        }
        guard !entries.contains(where: { $0.materials.isEmpty }) else { return nil }
        var seen: Set<String> = []
        var choices: [MaterialChoices.Choice] = []
        for name in entries.flatMap(\.materials) where seen.insert(name).inserted {
            if let material = puzzle.material(named: name) {
                choices.append(.init(id: name, title: puzzle.materialTitle(named: name), material: material))
            }
        }
        return choices.isEmpty ? nil : MaterialChoices(choices: choices)
    }
}

/// The inspector in a puzzle: the player's element with its material restricted to the
/// palette, a summary of anything the puzzle fixes, or, with nothing of the player's
/// selected, how to start and how the design is scored.
struct PuzzleInspector: View {
    let model: AppState

    var body: some View {
        let _ = PerfProbe.body("PuzzleInspector")
        if let puzzle = model.activePuzzle {
            switch model.selection {
            case .element(let id) where model.scene[element: id] != nil:
                if model.isLockedElement(id), let element = model.scene[element: id] {
                    FixedPartSummary(title: element.displayName, symbol: element.kind.symbol, rows: [
                        ("Kind", element.kind.title),
                        ("Material", element.material.badge),
                    ])
                } else if let element = model.scene[element: id] {
                    ElementForm(model: model, id: id, choices: model.materialChoices(for: element))
                        .id(id)
                }
            case .source(let id) where model.scene[source: id] != nil:
                let source = model.scene[source: id]!
                let index = puzzle.inputs.firstIndex(of: id)
                FixedPartSummary(title: index.map { "Input \(puzzle.inputLetters[$0])" } ?? source.displayName,
                                 symbol: source.kind.symbol, rows: sourceRows(source, input: index != nil))
            case .detector(let id) where model.scene[detector: id] != nil:
                let detector = model.scene[detector: id]!
                FixedPartSummary(title: detector.displayName, symbol: detector.kind.symbol, rows: [
                    ("Kind", detector.kind.title),
                    ("Role", puzzle.goalDetectorIDs.contains(id) ? "Scored by the goal" : "For reference"),
                ] + liveRows(id))
            default:
                PuzzleInfo(model: model, puzzle: puzzle)
            }
        }
    }

    /// Another detector's raw reading. A goal detector shows no number: a Check measures it.
    private func liveRows(_ id: String) -> [(String, String)] {
        if model.activePuzzle?.goalDetectorIDs.contains(id) ?? false {
            return [("Reading", "Check to measure")]
        }
        let text = model.detectorReadings[id].flatMap { model.readingSummary($0) }
        return text.map { [("Live Reading", $0)] } ?? []
    }

    private func sourceRows(_ source: Source, input: Bool) -> [(String, String)] {
        var rows: [(String, String)] = [("Kind", source.kind.title)]
        if input { rows.append(("State", source.enabled ? "On" : "Off")) }
        rows.append(("Amplitude $A$", Format.number(source.amplitude, digits: 2...2)))
        rows.append(("Phase $\\varphi$", Format.degrees(source.phaseDeg, digits: 0)))
        return rows
    }
}

/// A part the puzzle fixes: what it is, read only.
private struct FixedPartSummary: View {
    let title: String
    let symbol: String
    let rows: [(String, String)]

    var body: some View {
        let _ = PerfProbe.body("FixedPartSummary")
        Section {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                LabeledContent {
                    MathText(row.1).monospacedDigit()
                } label: {
                    MathText(row.0)
                }
            }
        } header: {
            Label(title, systemImage: symbol)
        } footer: {
            Label("This part is fixed by the puzzle.", systemImage: "lock.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// Nothing of the player's selected: how to begin, and what a Check solves.
private struct PuzzleInfo: View {
    let model: AppState
    let puzzle: Puzzle

    var body: some View {
        let _ = PerfProbe.body("PuzzleInfo")
        let scene = model.scene
        Section {
            Text(model.puzzleDesign.isEmpty
                 ? "Add a part from Parts in the sidebar, then select it here to change it."
                 : "Select one of your elements to edit it.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        Section {
            LabeledContent("Solver", value: puzzle.scoring?.method.title ?? scene.solver.method.title)
            LabeledContent {
                MathText("\(Format.number(puzzle.scoring?.ppw ?? scene.solver.ppw(final: false), digits: 0...1))/" + #"$\lambda$"#)
                    .monospacedDigit()
            } label: {
                Text("Resolution")
            }
            LabeledContent {
                Text(Format.wavelength(scene.wavelengthUm)).monospacedDigit()
            } label: {
                MathText(#"Wavelength $\lambda_0$"#)
            }
            if let stars = puzzle.starsLine {
                LabeledContent("Stars", value: stars.replacingOccurrences(of: "Stars at ", with: ""))
                    .monospacedDigit()
            }
        } header: {
            Text("Scoring")
        } footer: {
            Text("The canvas previews at the scoring resolution, so what you see is what Check scores.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        Section {
            if let region = puzzle.rules.region {
                LabeledContent("Region") {
                    MathText("$x$ \(Format.number(region.xMin, digits: 0...2)) to \(Format.number(region.xMax, digits: 0...2)) µm, $y$ \(Format.number(region.yMin, digits: 0...2)) to \(Format.number(region.yMax, digits: 0...2)) µm")
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                }
            }
            if let max = puzzle.rules.maxElements {
                LabeledContent("Parts", value: "Up to \(max)")
            }
        } header: {
            Text("Rules")
        } footer: {
            Text("Parts must lie inside the dashed region. Outlined parts are outside it.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// A puzzle part's material: one of the palette's, picked by name.
struct PuzzleMaterialSection: View {
    let model: AppState
    let id: String
    let element: Element
    let choices: MaterialChoices

    var body: some View {
        let _ = PerfProbe.body("PuzzleMaterialSection")
        let current = choices.choice(for: element.material)
        Section {
            if choices.choices.count == 1, let only = choices.choices.first {
                LabeledContent("Material", value: only.title)
            } else {
                Picker("Material", selection: Binding(
                    get: { current?.id ?? "" },
                    set: { name in
                        guard let choice = choices.choices.first(where: { $0.id == name }) else { return }
                        model.edit("Change Material") { $0.scene[element: id]?.setMaterial(choice.material) }
                    }
                )) {
                    if current == nil { Text("Other").tag("") }
                    ForEach(choices.choices) { Text($0.title).tag($0.id) }
                }
            }
            LabeledContent {
                MathText(element.material.badge).monospacedDigit()
            } label: {
                Text("Model")
            }
        } header: {
            Text("Material")
        } footer: {
            Text(!choices.kindAllowed ? "This puzzle has no parts of this kind, so a Check will not accept it."
                 : choices.choices.count == 1 ? "The puzzle allows only this material for this part." : "The puzzle allows these materials for this part.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
