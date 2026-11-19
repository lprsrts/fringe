import SwiftUI

struct FringeWindow: View {
    @Environment(AppState.self) private var model
    @Environment(\.undoManager) private var undoManager
    @UIState private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        let _ = PerfProbe.body("FringeWindow")
        @Bindable var model = model

        NavigationSplitView(columnVisibility: $columns) {
            if model.isPuzzleBrowser {
                HeldHeight(model: model) { ChapterSidebar() }
                    .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
            } else if model.isInPuzzle {
                HeldHeight(model: model) { PuzzleSidebar() }
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
            } else {
                HeldHeight(model: model) { SidebarView() }
                    .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
            }
        } detail: {
            if model.isPuzzleBrowser {
                // No inspector in the browser: there is nothing to inspect.
                PuzzleBrowser()
                    .toolbar(id: "main") { MainToolbar(model: model) }
            } else {
                // The inspector belongs to the whole column, so it runs full height and the
                // results and status bar span the canvas only.
                DetailColumn(model: model)
                // On the column, not the split view, so the items sit over the canvas and
                // the inspector gets its own toolbar section for its toggle.
                .toolbar(id: "main") { MainToolbar(model: model) }
                .inspector(isPresented: $model.isInspectorPresented) {
                    HeldHeight(model: model) { InspectorView() }
                        // The column's width must not follow its content: numbers changing
                        // during a drag widened it from 320 to 383 pt and back, resizing the
                        // canvas several times a second. Its height is bounded on both sides
                        // too, so AppKit's minimum-size query at each layout of the window
                        // (every resize step, every inspector change) is answered without
                        // measuring the form.
                        .frame(minWidth: 300, idealWidth: 320, maxWidth: 400, minHeight: 0, maxHeight: .infinity)
                        .inspectorColumnWidth(min: 300, ideal: 320, max: 400)
                        .toolbar {
                            ToolbarSpacer(.flexible)
                            ToolbarItem { InspectorToggle(model: model) }
                        }
                }
            }
        }
        .navigationTitle("Fringe")
        .navigationSubtitle(subtitle)
        // The mode picker takes the title's place (ui-plan §1.2), so every simulator item
        // still fits at 1440 pt; the title and subtitle stay for the Window menu and
        // VoiceOver, and the output summary is in the sidebar's Output row.
        .toolbar(removing: .title)
        .toolbarRole(.editor)
        .fileExporter(
            isPresented: $model.isExporterPresented,
            item: model.presentedExport,
            contentTypes: [.png],
            // Read only while the panel is up: the window's body must not depend on the
            // document, or every edit and drag step re-evaluates the whole window.
            defaultFilename: model.isExporterPresented ? model.suggestedFilename : nil
        ) { result in
            model.finishExport(result)
        }
        .fileExporterFilenameLabel("Export As:")
        .fileDialogConfirmationLabel("Export")
        // Each file panel gets its own view: one view presents one of each kind reliably.
        .background {
            Color.clear
                .fileExporter(
                    isPresented: $model.isSceneExporterPresented,
                    item: model.isSceneExporterPresented ? model.sceneFile : nil,
                    contentTypes: [.json],
                    defaultFilename: model.isSceneExporterPresented ? model.suggestedSceneFilename : nil
                ) { result in
                    if case .failure(let error) = result { model.exportErrorMessage = error.localizedDescription }
                }
                .fileDialogConfirmationLabel("Save")
        }
        .background {
            Color.clear
                .fileImporter(isPresented: $model.isSceneImporterPresented, allowedContentTypes: [.json]) { result in
                    switch result {
                    case .success(let url): model.openScene(at: url)
                    case .failure(let error): model.openErrorMessage = error.localizedDescription
                    }
                }
        }
        .confirmationDialog(
            !model.isExportChoicePresented ? "" : model.solver.isShownStale ? "Export an Out-of-Date Image?" : "Export a Preview?",
            isPresented: $model.isExportChoicePresented
        ) {
            // Their own views: what they read (solver state) must not re-evaluate the window.
            ExportChoiceActions(model: model)
        } message: {
            ExportChoiceMessage(model: model)
        }
        .confirmationDialog(
            "Reset This Puzzle?",
            isPresented: Binding(get: { model.puzzles.isResetConfirmationPresented }, set: { model.puzzles.isResetConfirmationPresented = $0 })
        ) {
            Button("Reset", role: .destructive) { model.resetPuzzle() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your elements are removed. Your best score is kept.")
        }
        .alert(
            "Couldn't Export",
            isPresented: Binding(
                get: { model.exportErrorMessage != nil },
                set: { if !$0 { model.exportErrorMessage = nil } }
            ),
            presenting: model.exportErrorMessage
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
        .alert(
            "Couldn't Open the Scene",
            isPresented: Binding(
                get: { model.openErrorMessage != nil },
                set: { if !$0 { model.openErrorMessage = nil } }
            ),
            presenting: model.openErrorMessage
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
        // Every dimension bounded on both sides (and an ideal), so the window's size limits
        // are known without measuring the window's content: AppKit asks the hosting view for
        // its minimum size at every layout, and an open `.frame(minWidth:minHeight:)` had it
        // measure the whole tree (sidebar, canvas, inspector form) each time, a large part of
        // every live-resize step and of every document change.
        .frame(minWidth: 1000, idealWidth: 1440, maxWidth: .infinity, minHeight: 620, idealHeight: 860, maxHeight: .infinity)
        .onAppear { model.undoManager = undoManager }
        .task {
            // AppKit hands initial focus to the inspector's first text field, which
            // then sits there with its value selected. Start with nothing focused.
            try? await Task.sleep(for: .milliseconds(100))
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        .onChange(of: undoManager) { _, newValue in model.undoManager = newValue }
    }

    /// The output format in the simulator, "Puzzles" in the browser, the puzzle's title in
    /// a puzzle.
    private var subtitle: String {
        guard model.mode == .puzzles else { return model.windowSubtitle }
        return model.puzzles.session.map { $0.puzzle.title.titleCased } ?? "Puzzles"
    }
}

/// The canvas, the results or truth table under it, and the status bar. Its own view, so
/// the column height it follows for the results area re-evaluates only this body at each
/// resize step, not the window's.
private struct DetailColumn: View {
    let model: AppState
    @UIState private var height: CGFloat = 0

    var body: some View {
        let _ = PerfProbe.body("DetailColumn")
        VStack(spacing: 0) {
            CanvasView()
            if model.isInPuzzle {
                // A puzzle always shows its table in the results slot.
                TruthTablePanel(model: model, columnHeight: height)
            } else if model.isResultsPresented {
                ResultsPanel(model: model, columnHeight: height)
            }
            StatusBar(model: model)
        }
        // Bounded on both sides, as the window's frame: AppKit's minimum-size query at each
        // layout otherwise measured the status bar's three summaries (a text layout each) at
        // every live-resize step. The content's own minimum is about 110 x 24 pt, which the
        // window's minimum width always leaves room for.
        .frame(minWidth: 120, maxWidth: .infinity, minHeight: 24, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
    }
}

private struct ExportChoiceActions: View {
    let model: AppState

    var body: some View {
        Button("Run Final and Export") { model.runFinalAndExport() }
            .keyboardShortcut(.defaultAction)
            .disabled(!model.solver.canRunFinal)
        Button(model.solver.shown?.quality == .final ? "Export Anyway" : "Export Preview") {
            model.isExporterPresented = true
        }
        Button("Cancel", role: .cancel) {}
    }
}

private struct ExportChoiceMessage: View {
    let model: AppState

    var body: some View {
        Text(model.solver.isShownStale
             ? "The image is out of date: it shows the scene before your last edits."
             : "The image is a quick preview. A final solve is more accurate.")
    }
}

/// A column's content that keeps the tallest height seen while the window's size keeps
/// changing (`AppState.holdsColumnHeights`), anchored at the top: the window clips what
/// lies below its edge. A live-resize step then lays out the column's frame only, not the
/// list or form inside it, whose height is all a window resize changes. When the size
/// settles, the content takes the column's height again.
struct HeldHeight<Content: View>: View {
    let model: AppState
    @ViewBuilder let content: () -> Content

    var body: some View {
        HeldHeightLayout(holds: model.holdsColumnHeights) { content() }
    }
}

private struct HeldHeightLayout: Layout {
    var holds: Bool
    /// Held heights grow in steps of this many points, so a window growing a point at a
    /// time lays the content out again only every so often.
    static let step: CGFloat = 128

    struct Cache { var height: CGFloat = 0 }

    func makeCache(subviews: Subviews) -> Cache { Cache() }
    // Kept across layout passes; only `holds` turning off resets it.
    func updateCache(_ cache: inout Cache, subviews: Subviews) {}

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        guard let child = subviews.first else { return proposal.replacingUnspecifiedDimensions() }
        guard holds, let width = proposal.width, let height = proposal.height else { return child.sizeThatFits(proposal) }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        guard let child = subviews.first else { return }
        var height = bounds.height
        if holds {
            if height > cache.height { cache.height = (height / Self.step).rounded(.up) * Self.step }
            height = cache.height
        } else {
            cache.height = 0
        }
        child.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: height))
    }
}
