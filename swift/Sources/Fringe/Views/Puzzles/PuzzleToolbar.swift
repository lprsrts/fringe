import SwiftUI

/// The open puzzle's toolbar items, under their own ids: back to all puzzles, previous and
/// next, Check (with progress and Stop while it runs), Reset, then the quantity, play and
/// the inspector. No solver, Run Final, export, output or zoom: the puzzle fixes them.
struct PuzzleToolbarItems: CustomizableToolbarContent {
    let model: AppState

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "puzzle.back", placement: .navigation) {
            Button("All Puzzles", systemImage: "chevron.backward") { model.closePuzzle() }
                .labelStyle(.titleAndIcon)
                .help("Back to all puzzles (⌘[)")
        }

        ToolbarItem(id: "puzzle.neighbours", placement: .navigation) {
            let id = model.puzzles.session?.id ?? ""
            ControlGroup {
                Button("Previous Puzzle", systemImage: "chevron.left") { model.openNeighbourPuzzle(-1) }
                    .disabled(model.puzzles.neighbour(of: id, by: -1) == nil)
                    .help("Previous puzzle (⇧⌘[)")
                Button("Next Puzzle", systemImage: "chevron.right") { model.openNeighbourPuzzle(1) }
                    .disabled(model.puzzles.neighbour(of: id, by: 1) == nil)
                    .help("Next puzzle (⇧⌘])")
            } label: {
                Label("Previous and Next Puzzle", systemImage: "chevron.left.chevron.right")
            }
        }

        ToolbarItem(id: "puzzle.check") {
            CheckControl(model: model)
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarItem(id: "puzzle.reset") {
            Button("Reset", systemImage: "arrow.counterclockwise") {
                model.puzzles.isResetConfirmationPresented = true
            }
            .disabled(model.puzzleDesign.isEmpty && model.puzzles.session?.evaluation == nil)
            .help("Remove your elements and start again; your best score is kept")
        }

        ToolbarSpacer(.flexible)

        ToolbarItem(id: "puzzle.quantity") {
            Menu {
                Picker("Quantity", selection: Binding(get: { model.display.quantity }, set: { model.setQuantity($0) })) {
                    ForEach(Quantity.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label(model.display.quantity.title, systemImage: model.display.quantity.systemImage)
                    .labelStyle(.titleAndIcon)
            }
            .help("Quantity (⌃1–⌃4)")
        }

        ToolbarItem(id: "puzzle.play") {
            Button(model.display.isPlaying ? "Pause" : "Play", systemImage: model.display.isPlaying ? "pause.fill" : "play.fill") {
                model.togglePlaying()
            }
            .help(model.display.isPlaying ? "Pause the phase animation (⌥⌘P)" : "Animate the phase (⌥⌘P)")
        }

        if !model.isInspectorPresented {
            ToolbarItem(id: "puzzle.inspector") {
                InspectorToggle(model: model)
            }
        }
    }
}

/// Check, which turns into a progress ring and a stop button while the design is scored.
struct CheckControl: View {
    let model: AppState

    var body: some View {
        let _ = PerfProbe.body("CheckControl")
        let puzzles = model.puzzles
        if puzzles.isChecking {
            HStack(spacing: 6) {
                ProgressView(value: min(1, max(0, puzzles.checkProgress.fraction)))
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                Text("Measuring…")
                    .foregroundStyle(.secondary)
                Button("Stop", systemImage: "stop.fill") { model.cancelPuzzleCheck() }
                    .labelStyle(.iconOnly)
            }
            .help("Measuring every case. Stop with ⌘.")
        } else {
            Button("Check", systemImage: "checkmark.seal") { model.checkPuzzle() }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.glassProminent)
                .help("Score this design (⌘R)")
        }
    }
}
