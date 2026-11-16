import SwiftUI

struct SourceForm: View {
    let model: AppState

    private static let laserLines: [(nm: Double, name: String)] = [
        (405, "405 nm"), (488, "488 nm"), (532, "532 nm"), (633, "633 nm (He-Ne)"),
        (780, "780 nm"), (1064, "1064 nm (Nd:YAG)"), (1550, "1550 nm"),
    ]

    var body: some View {
        let scene = model.scene
        let source = scene.source
        let lambda = scene.lambdaB
        let domain = scene.domain

        Section("Source") {
            Picker("Kind", selection: model.binding("Change Source", \.scene.source.kind)) {
                ForEach(SourceKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            ValueRow(
                title: "Wavelength",
                value: model.binding("Change Wavelength", \.scene.wavelengthUm).scaled(by: 1000),
                range: 380...1600,
                limits: 100...100_000,
                unit: "nm",
                digits: 1,
                ticks: Self.laserLines.map(\.nm),
                onEditingChanged: model.editingChanged("Change Wavelength")
            )
            IssueLines(issues: model.issues(at: "wavelength_um"))
            LabeledContent("Laser Line") {
                Menu(currentLine ?? "Other") {
                    ForEach(Self.laserLines, id: \.nm) { line in
                        Button(line.name) {
                            model.edit("Change Wavelength") { $0.scene.wavelengthUm = line.nm / 1000 }
                        }
                    }
                }
                .fixedSize()
            }
            ValueRow(
                title: "Background Index",
                value: model.binding("Change Background Index", \.scene.background.n),
                range: 1...2.5,
                limits: 1...4,
                digits: 3,
                onEditingChanged: model.editingChanged("Change Background Index")
            )
            IssueLines(issues: model.issues(at: "background.n"))
        }

        if source.kind == .gaussianBeam {
            Section("Gaussian Beam") {
                LengthField(
                    title: "Waist Radius w₀",
                    value: model.binding("Change Waist Radius", \.scene.source.waistUm),
                    lambda: lambda,
                    range: 0.1 * lambda...max(10 * lambda, min(domain.width, domain.height) / 2),
                    limits: 0.01...1e4,
                    issues: model.issues(at: "source.waist_um"),
                    onEditingChanged: model.editingChanged("Change Waist Radius")
                )
                LengthField(
                    title: "Waist x",
                    value: model.binding("Move Waist", \.scene.source.waistXUm),
                    lambda: lambda,
                    range: domain.xMinUm...domain.xMaxUm,
                    issues: model.issues(at: "source.waist_x_um"),
                    onEditingChanged: model.editingChanged("Move Waist")
                )
                LengthField(
                    title: "Waist y",
                    value: model.binding("Move Waist", \.scene.source.waistYUm),
                    lambda: lambda,
                    range: domain.yMinUm...domain.yMaxUm,
                    issues: model.issues(at: "source.waist_y_um"),
                    onEditingChanged: model.editingChanged("Move Waist")
                )
                angleRow
            }
        } else {
            Section("Plane Wave") {
                angleRow
            }
        }

        Section {
            ValueRow(
                title: "Amplitude",
                value: model.binding("Change Amplitude", \.scene.source.amplitude),
                range: 0.1...5,
                limits: 1e-6...1e6,
                digits: 2,
                neutral: 1,
                onEditingChanged: model.editingChanged("Change Amplitude")
            )
            ValueRow(
                title: "Phase",
                value: model.binding("Change Source Phase", \.scene.source.phaseDeg),
                range: 0...360,
                limits: -360...720,
                unit: "°",
                digits: 0,
                onEditingChanged: model.editingChanged("Change Source Phase")
            )
            IssueLines(issues: model.issues(at: "source.amplitude") + model.issues(at: "source"))
        } footer: {
            Text("Defined in the background as if no elements were present. Ez polarisation (out of plane). 2D: elements are infinite extrusions.")
                .foregroundStyle(.secondary)
        }

        if source.kind == .gaussianBeam, let derived = model.checkReport?.derived?.source {
            Section("Derived") {
                if let zR = derived.rayleighRangeUm {
                    LabeledContent("Rayleigh Range", value: Format.micrometres(zR))
                }
                if let theta = derived.divergenceDeg {
                    LabeledContent("Divergence", value: Format.degrees(theta, digits: 2))
                }
            }
            .monospacedDigit()
        }
    }

    private var angleRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            ValueRow(
                title: "Angle",
                value: model.binding("Change Beam Angle", \.scene.source.angleDeg),
                range: -90...90,
                limits: -360...360,
                unit: "°",
                digits: 1,
                neutral: 0,
                onEditingChanged: model.editingChanged("Change Beam Angle")
            )
            IssueLines(issues: model.issues(at: "source.angle_deg"))
        }
    }

    private var currentLine: String? {
        let nm = model.scene.wavelengthUm * 1000
        return Self.laserLines.first { abs($0.nm - nm) < 0.05 }?.name
    }
}
