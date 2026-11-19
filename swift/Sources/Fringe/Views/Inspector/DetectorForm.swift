import SwiftUI

/// One detector: a line that counts the power through it, or a box that averages |E|².
struct DetectorForm: View {
    let model: AppState
    let id: String

    var body: some View {
        let _ = PerfProbe.body("DetectorForm")
        if let detector = model.scene[detector: id], let index = model.scene.detectorIndex(id) {
            let lambda = model.scene.lambdaB

            Section {
                TextField("Name", text: model.detectorBinding(id, "Rename Detector", \.name, fallback: ""), prompt: Text(detector.kind.rowTitle))
                Toggle("Enabled", isOn: model.detectorBinding(id, detector.enabled ? "Disable Detector" : "Enable Detector", \.enabled, fallback: true))
                    .toggleStyle(.switch)
                    .help("Disabled detectors stay in the scene but are not measured (⇧⌘D)")
                Picker("Kind", selection: Binding(
                    get: { detector.kind },
                    set: { kind in
                        model.edit("Change Detector Kind") { doc in
                            doc.scene[detector: id] = doc.scene[detector: id]?.converted(to: kind, lambdaB: lambda)
                        }
                    }
                )) {
                    Text("Line").tag(DetectorKind.line)
                    Text("Box").tag(DetectorKind.box)
                }
                .pickerStyle(.segmented)
                .help("Switching keeps the centre")
                IssueLines(issues: model.detectorIssues(index, key: nil) + model.detectorIssues(index, key: "id"))
            } header: {
                Label(detector.kind.title, systemImage: detector.kind.symbol)
            }

            switch detector.shape {
            case .line:
                Section {
                    length("Start $x$", \.line.x1Um, key: "x1_um", index: index, horizontal: true)
                    length("Start $y$", \.line.y1Um, key: "y1_um", index: index, horizontal: false)
                    length("End $x$", \.line.x2Um, key: "x2_um", index: index, horizontal: true)
                    length("End $y$", \.line.y2Um, key: "y2_um", index: index, horizontal: false)
                    LabeledContent("Length") {
                        Text(Format.micrometres(detector.length))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Normal") {
                        HStack(spacing: 8) {
                            if let angle = detector.normalAngleDeg {
                                Image(systemName: "arrow.right")
                                    .rotationEffect(.degrees(-angle))
                                    .accessibilityHidden(true)
                                Text(Format.degrees(angle))
                                    .monospacedDigit()
                            } else {
                                Text("None")
                                    .foregroundStyle(.secondary)
                            }
                            Button("Flip") {
                                model.edit("Flip Detector") { doc in
                                    doc.scene[detector: id] = doc.scene[detector: id]?.flipped()
                                }
                            }
                            .help("Swap the start and end, which reverses the normal")
                        }
                    }
                } header: {
                    Text("Geometry")
                } footer: {
                    MathText.footer("Net time-averaged power through the segment per µm in $z$, positive along the normal (to the right of start → end). A plane wave of amplitude $A$ in vacuum carries $A^2/2$ per µm.")
                        .foregroundStyle(.secondary)
                }
            case .box:
                Section {
                    length("Center $x$", \.box.xUm, key: "x_um", index: index, horizontal: true)
                    length("Center $y$", \.box.yUm, key: "y_um", index: index, horizontal: false)
                    size("Width", \.box.widthUm, key: "width_um", index: index)
                    size("Height", \.box.heightUm, key: "height_um", index: index)
                } header: {
                    Text("Geometry")
                } footer: {
                    MathText.footer("Mean and integral of $|E|^2$ over the box. Readings are in units of $A^2$.")
                        .foregroundStyle(.secondary)
                }
            }

            if detector.enabled, model.solver.shown != nil {
                ReadingSection(model: model, detector: detector)
            }

            Section {
                Button("Duplicate Detector") { model.duplicate(.detector(id)) }
                    .help("Add a copy of this detector (⌘D)")
                Button("Delete Detector", role: .destructive) { model.delete(.detector(id)) }
                    .help("Remove this detector from the scene; ⌫ in the sidebar does the same")
            }
        }
    }

    private func length(_ title: String, _ path: WritableKeyPath<DetectorShape, Double>, key: String, index: Int, horizontal: Bool) -> some View {
        let domain = model.scene.domain
        let lambda = model.scene.lambdaB
        let issues = model.detectorIssues(index, key: key)
        return LiveFields {
            LengthField(
                title: title,
                value: model.detectorBinding(id, "Move Detector", (\Detector.shape).appending(path: path), fallback: 0, live: true),
                lambda: lambda,
                range: horizontal ? domain.xMinUm...domain.xMaxUm : domain.yMinUm...domain.yMaxUm,
                issues: issues,
                onEditingChanged: model.editingChanged("Move Detector")
            )
        }
    }

    private func size(_ title: String, _ path: WritableKeyPath<DetectorShape, Double>, key: String, index: Int) -> some View {
        let domain = model.scene.domain
        let lambda = model.scene.lambdaB
        let issues = model.detectorIssues(index, key: key)
        return LiveFields {
            LengthField(
                title: title,
                value: model.detectorBinding(id, "Resize Detector", (\Detector.shape).appending(path: path), fallback: 1, live: true),
                lambda: lambda,
                range: 0.05 * lambda...max(lambda, max(domain.width, domain.height)),
                limits: 1e-3...1e5,
                issues: issues,
                onEditingChanged: model.editingChanged("Resize Detector")
            )
        }
    }
}

/// The detector's reading on the shown field, dimmed when that field is out of date.
private struct ReadingSection: View {
    let model: AppState
    let detector: Detector

    var body: some View {
        let _ = PerfProbe.body("ReadingSection")
        let reading = model.detectorReadings[detector.id]
        let a2 = model.readingAmplitude * model.readingAmplitude
        let stale = model.readingsAreStale
        Section {
            if let reading {
                switch reading.kind {
                case .line:
                    if let flux = reading.flux {
                        row("Power (Total)", Format.power(flux.total / a2), help: "Power through the segment per µm in z; positive along the normal")
                        row("Power (Incident)", Format.power(flux.incident / a2), help: "The same for the incident field alone, without the elements")
                        row("Power (Scattered)", Format.power(flux.scattered / a2), help: "Power carried by the scattered field alone, the part the elements add")
                    }
                    row("Ratio", model.meaningfulRatio(reading).map { Format.number($0, digits: 2...2) } ?? "—",
                        help: "Total over incident power")
                case .box:
                    if let total = reading.total {
                        row("Mean $|E|^2$ (Total)", Format.significant(total.mean / a2) + " $A^2$", help: "Mean intensity over the box")
                    }
                    if let incident = reading.incident {
                        row("Mean $|E|^2$ (Incident)", Format.significant(incident.mean / a2) + " $A^2$", help: "The same for the incident field alone, without the elements")
                    }
                    if let integral = reading.total?.integral {
                        row("Integral of $|E|^2$", Format.significant(integral / a2) + " $A^2$·µm²", help: "Intensity integrated over the box")
                    }
                }
            } else {
                Text("Measuring…")
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("Reading")
                if stale {
                    Spacer()
                    Text("Out of date")
                        .foregroundStyle(.orange)
                }
            }
        }
        .opacity(stale ? 0.5 : 1)
    }

    private func row(_ title: String, _ value: String, help: String) -> some View {
        LabeledContent {
            MathText(value)
                .monospacedDigit()
        } label: {
            MathText(title)
        }
        .help(help)
    }
}
