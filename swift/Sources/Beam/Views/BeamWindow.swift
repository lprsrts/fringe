import SwiftUI

struct BeamWindow: View {
    @Environment(AppState.self) private var model
    @Environment(\.undoManager) private var undoManager
    @UIState private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var model = model

        NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            CanvasView()
                .inspector(isPresented: $model.isInspectorPresented) {
                    InspectorView()
                        .inspectorColumnWidth(min: 280, ideal: 310, max: 400)
                }
        }
        .navigationTitle("Beam")
        .navigationSubtitle(model.outputSummary)
        .toolbar(id: "main") { MainToolbar(model: model) }
        .toolbarRole(.editor)
        .fileExporter(
            isPresented: $model.isExporterPresented,
            item: model.isExporterPresented ? model.pngExport : nil,
            contentTypes: [.png],
            defaultFilename: model.suggestedFilename
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
                    defaultFilename: model.suggestedSceneFilename
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
            "Export a Preview?",
            isPresented: $model.isExportChoicePresented
        ) {
            Button("Run Final and Export") { model.runFinalAndExport() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.solver.canRunFinal)
            Button("Export Preview") { model.isExporterPresented = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.solver.isShownStale
                 ? "The image is out of date: it shows the scene before your last edits."
                 : "The image is a quick preview. A final solve is more accurate.")
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
        .frame(minWidth: 1000, minHeight: 620)
        .onAppear { model.undoManager = undoManager }
        .task {
            // AppKit hands initial focus to the inspector's first text field, which
            // then sits there with its value selected. Start with nothing focused.
            try? await Task.sleep(for: .milliseconds(100))
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        .onChange(of: undoManager) { _, newValue in model.undoManager = newValue }
    }
}
