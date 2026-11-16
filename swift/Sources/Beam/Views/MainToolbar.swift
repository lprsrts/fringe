import SwiftUI

struct MainToolbar: CustomizableToolbarContent {
    let model: AppState

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "add", placement: .navigation) {
            AddElementMenu(model: model)
                .help("Add an optical element")
        }

        ToolbarSpacer(.flexible)

        ToolbarItem(id: "output") {
            OutputFormatMenu(model: model)
                .help("Output format")
        }

        ToolbarSpacer(.fixed)

        ToolbarItem(id: "look") {
            ControlGroup {
                Menu("Overlays", systemImage: "square.3.layers.3d") {
                    OverlayToggles(model: model)
                }
                .help("Overlays (⇧⌘O)")
                Picker("Colormap", systemImage: "paintpalette", selection: model.binding("Change Colormap", \.style.colormap)) {
                    ForEach(ColormapOption.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.menu)
                .help("Colormap (⌥⌘[ / ⌥⌘])")
            } label: {
                Label("Overlays and Colormap", systemImage: "square.3.layers.3d")
            }
        }

        ToolbarSpacer(.fixed)

        ToolbarItem(id: "zoom") {
            ControlGroup {
                Button("Zoom Out", systemImage: "minus.magnifyingglass") { model.zoom(by: 0.8) }
                    .help("Zoom out (⌘−)")
                Button("Zoom to Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass") { model.zoomToFit() }
                    .help("Zoom to fit (⌘0)")
                Button("Zoom In", systemImage: "plus.magnifyingglass") { model.zoom(by: 1.25) }
                    .help("Zoom in (⌘=)")
            } label: {
                Label("Zoom", systemImage: "plus.magnifyingglass")
            }
        }

        if model.isExporting {
            ToolbarItem(id: "progress") {
                ProgressView()
                    .controlSize(.small)
            }
            .sharedBackgroundVisibility(.hidden)
        }

        ToolbarSpacer(.fixed)

        ToolbarItem(id: "export", placement: .primaryAction) {
            Button("Export…") { model.isExporterPresented = true }
                .buttonStyle(.glassProminent)
                .help("Export PNG (⌘E)")
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarItem(id: "inspector") {
            Button("Inspector", systemImage: "sidebar.trailing") {
                model.isInspectorPresented.toggle()
            }
            .help("Show or hide the inspector (⌃⌘I)")
        }
    }
}

struct AddElementMenu: View {
    let model: AppState

    var body: some View {
        Menu("Add Element", systemImage: "plus") {
            ForEach(OpticalElementType.allCases) { type in
                Button(type.displayName, systemImage: type.symbol) { model.addElement(type) }
            }
        }
    }
}

struct OutputFormatMenu: View {
    let model: AppState

    var body: some View {
        Menu {
            Picker("Aspect Ratio", selection: model.binding("Change Aspect Ratio", \.output.aspect)) {
                ForEach(OutputAspect.presets, id: \.self) { Text($0.title).tag($0) }
                if model.output.aspect.isCustom {
                    Text(model.output.aspect.title).tag(model.output.aspect)
                }
            }
            .pickerStyle(.inline)

            Picker("Size", selection: model.binding("Change Size", \.output.longEdge)) {
                ForEach(LongEdge.presets, id: \.self) { Text("\($0.pixels) px").tag($0) }
                if model.output.longEdge.isCustom {
                    Text("\(model.output.longEdge.pixels) px").tag(model.output.longEdge)
                }
            }
            .pickerStyle(.inline)

            Divider()

            Button("Custom Ratio…") {
                if !model.output.aspect.isCustom {
                    model.setAspect(model.output.aspect.asCustom)
                }
                model.selection = .output
                model.isInspectorPresented = true
            }

            Button("Custom Size…") {
                model.selection = .output
                model.isInspectorPresented = true
            }
        } label: {
            Label(model.output.aspect.title, systemImage: "aspectratio")
                .labelStyle(.titleAndIcon)
        }
    }
}
