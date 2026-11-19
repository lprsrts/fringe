import SwiftUI

/// The wavelength and background medium every source shares.
struct IlluminationForm: View {
    let model: AppState

    static let laserLines: [(nm: Double, name: String)] = [
        (405, "405 nm"), (488, "488 nm"), (532, "532 nm"), (633, "633 nm (He-Ne)"),
        (780, "780 nm"), (1064, "1064 nm (Nd:YAG)"), (1550, "1550 nm"),
    ]

    var body: some View {
        let _ = PerfProbe.body("IlluminationForm")
        let scene = model.scene

        Section {
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
                .help("Set the wavelength to a common laser line")
            }
        } header: {
            Label("Wavelength", systemImage: "rainbow")
        } footer: {
            Text("All sources share this wavelength and are coherent.")
                .foregroundStyle(.secondary)
        }

        Section {
            ValueRow(
                title: "Background Index $n_b$",
                value: model.binding("Change Background Index", \.scene.background.n),
                range: 1...2.5,
                limits: 1...4,
                digits: 3,
                onEditingChanged: model.editingChanged("Change Background Index")
            )
            IssueLines(issues: model.issues(at: "background.n"))
            LabeledContent {
                Text(Format.wavelength(scene.lambdaB))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } label: {
                MathText(#"$\lambda_b = \lambda_0 / n_b$"#)
                    .foregroundStyle(.secondary)
            }
            IssueLines(issues: model.issues(at: "sources") + model.issues(at: "polarization"))
        } header: {
            Text("Medium")
        } footer: {
            MathText.footer("$E_z$ polarization (out of plane, s). 2D: elements are infinite extrusions.")
                .foregroundStyle(.secondary)
        }
    }

    private var currentLine: String? {
        let nm = model.scene.wavelengthUm * 1000
        return Self.laserLines.first { abs($0.nm - nm) < 0.05 }?.name
    }
}
