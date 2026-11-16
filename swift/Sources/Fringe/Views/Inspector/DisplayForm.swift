import SwiftUI

struct DisplayForm: View {
    let model: AppState

    var body: some View {
        let display = model.display
        let quantity = display.quantity

        Section("Field") {
            Picker("Quantity", selection: Binding(get: { quantity }, set: { model.setQuantity($0) })) {
                ForEach(Quantity.allCases) { Text("\($0.title) (\($0.symbol))").tag($0) }
            }
            Picker("Part", selection: model.binding("Change Field Part", \.display.part)) {
                ForEach(FieldPartName.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Colormap", selection: Binding(get: { display.colormap }, set: { model.setColormap($0) })) {
                ForEach(model.availableColormaps) { Text($0.title).tag($0) }
            }
            if quantity != .phase {
                ValueRow(
                    title: "Gamma",
                    value: model.binding("Change Gamma", \.display.gamma),
                    range: 0.3...2.5,
                    limits: 0.05...10,
                    digits: 2,
                    neutral: 1,
                    onEditingChanged: model.editingChanged("Change Gamma")
                )
                .disabled(display.usesLogScale)
            }
        }

        if quantity != .phase || display.phaseWeighted {
            Section {
                Picker("Scale", selection: model.binding("Change Normalization", \.display.normalization)) {
                    ForEach(NormalizationMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if display.normalization == .fixed {
                    ValueRow(
                        title: "Full Scale",
                        value: model.binding("Change Full Scale", \.display.normalizationValue),
                        range: 0.1...5,
                        limits: 1e-6...1e6,
                        unit: "× A",
                        digits: 2,
                        onEditingChanged: model.editingChanged("Change Full Scale")
                    )
                }
                if quantity == .intensity || quantity == .magnitude {
                    Toggle("Logarithmic scale", isOn: Binding(
                        get: { display.logDb != nil },
                        set: { on in model.edit("Change Log Scale") { $0.display.logDb = on ? 30 : nil } }
                    ))
                    if let db = display.logDb {
                        ValueRow(
                            title: "Range",
                            value: Binding(
                                get: { db },
                                set: { v in model.binding("Change Log Range", \.display.logDb).wrappedValue = v }
                            ),
                            range: 10...80,
                            limits: 1...200,
                            unit: "dB",
                            digits: 0,
                            onEditingChanged: model.editingChanged("Change Log Range")
                        )
                    }
                }
            } header: {
                Text("Normalization")
            } footer: {
                Text(normalizationFootnote(display.normalization))
                    .foregroundStyle(.secondary)
            }
        }

        Section {
            ValueRow(
                title: "Phase φ",
                value: model.binding("Change Phase", \.display.phaseDeg),
                range: 0...360,
                limits: -3600...3600,
                unit: "°",
                digits: 0,
                onEditingChanged: model.editingChanged("Change Phase")
            )
            .disabled(display.isPlaying)
            HStack {
                Button(display.isPlaying ? "Pause" : "Play", systemImage: display.isPlaying ? "pause.fill" : "play.fill") {
                    model.togglePlaying()
                }
                Spacer()
            }
            ValueRow(
                title: "Speed",
                value: model.binding("Change Playback Speed", \.display.playbackSpeed),
                range: DisplaySettings.playbackSpeedRange,
                limits: DisplaySettings.playbackSpeedRange,
                unit: "periods/s",
                digits: 2,
                neutral: 0.5,
                onEditingChanged: model.editingChanged("Change Playback Speed")
            )
            if quantity == .phase {
                Toggle("Dim weak fields", isOn: model.binding("Change Phase Weighting", \.display.phaseWeighted))
            }
        } header: {
            Text("Phase")
        } footer: {
            Text(quantity.dependsOnPhase
                 ? "Shows Re(E·exp(jφ)) or arg(E·exp(jφ)); increasing φ moves wavefronts forward."
                 : "Intensity and magnitude don't change with φ. Play switches to the real part.")
                .foregroundStyle(.secondary)
        }

        Section("Overlays") {
            OverlayToggles(model: model, inMenu: false)
        }
    }

    private func normalizationFootnote(_ mode: NormalizationMode) -> String {
        switch mode {
        case .auto: return "Full scale is the 99.5th percentile of the field, so a few hot spots don't wash out the rest."
        case .incident: return "Full scale is the source amplitude A."
        case .fixed: return "Full scale is a multiple of the source amplitude A."
        }
    }
}

/// "Show Overlays" and the overlay toggles, shared by the View menu, the toolbar and the
/// inspector. Menu items are title case; the inspector's checkboxes are sentence case.
struct OverlayToggles: View {
    let model: AppState
    var inMenu = true
    var showsShortcut = false

    var body: some View {
        Toggle(title("Show Overlays", "Show overlays"), isOn: showHide("Overlays", \.display.showOverlays))
            .keyboardShortcut(showsShortcut ? KeyboardShortcut("o", modifiers: [.command, .shift]) : nil)

        if inMenu {
            Divider()
        }

        Group {
            Toggle(title("Outlines", "Outlines"), isOn: model.binding("Change Overlays", \.display.showOutlines))
            Toggle(title("Source", "Source"), isOn: model.binding("Change Overlays", \.display.showSourceGlyph))
            Toggle(title("Paraxial Focus", "Paraxial focus"), isOn: model.binding("Change Overlays", \.display.showParaxialFocus))
            Toggle(title("Scale Bar", "Scale bar"), isOn: model.binding("Change Overlays", \.display.showScaleBar))
            Toggle(title("Caption", "Caption"), isOn: model.binding("Change Overlays", \.display.showCaption))
            Toggle(title("Color Legend", "Color legend"), isOn: model.binding("Change Overlays", \.display.showLegend))
        }
        .disabled(!model.display.showOverlays)

        if inMenu {
            Divider()
        }
        Toggle(title("Show PML", "Show absorbing layer (PML)"), isOn: showHide("PML", \.display.showPML))
    }

    /// A binding whose undo name says what the change did: "Show PML" or "Hide PML".
    private func showHide(_ what: String, _ keyPath: WritableKeyPath<FringeDocument, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.binding("Show \(what)", keyPath).wrappedValue },
            set: { newValue in model.binding(newValue ? "Show \(what)" : "Hide \(what)", keyPath).wrappedValue = newValue }
        )
    }

    private func title(_ menuTitle: String, _ checkboxTitle: String) -> String {
        inMenu ? menuTitle : checkboxTitle
    }
}
