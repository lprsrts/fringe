import SwiftUI

struct BeamWindow: View {
    @Environment(AppState.self) private var model
    @Environment(\.undoManager) private var undoManager
    @UIState private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var model = model

        NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            CanvasView()
                .inspector(isPresented: $model.isInspectorPresented) {
                    InspectorView()
                        .inspectorColumnWidth(min: 270, ideal: 300, max: 380)
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
        .alert(
            "Couldn't Export the Image",
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
        .frame(minWidth: 960, minHeight: 600)
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
