import SwiftUI

/// One Drude or Lorentz pole of a Lorentz–Drude material: its kind, a remove button and its
/// parameters as photon energies in eV.
struct PoleEditor: View {
    let model: AppState
    let elementID: String
    let index: Int
    let pole: Pole
    var issues: [Issue] = []

    private func binding(_ keyPath: WritableKeyPath<Pole, Double>, _ name: String) -> Binding<Double> {
        model.elementBinding(elementID, name, (\Element.material).appending(path: \Material[pole: index]).appending(path: keyPath), fallback: 0)
    }

    var body: some View {
        let _ = PerfProbe.body("PoleEditor")
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(pole.isDrude ? "Drude" : "Lorentz")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Remove Pole", systemImage: "minus.circle") {
                    model.edit("Remove Pole") { doc in
                        guard var material = doc.scene[element: elementID]?.material,
                              material.poles.indices.contains(index) else { return }
                        material.poles.remove(at: index)
                        doc.scene[element: elementID]?.material = material
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Remove this pole")
            }
            switch pole {
            case .drude:
                CompactNumberField(title: #"Plasma $\hbar\omega_p$"#, value: binding(\.plasmaEv, "Change Plasma Energy"), limits: 0...1000, unit: "eV")
                CompactNumberField(title: #"Damping $\hbar\gamma$"#, value: binding(\.gammaEv, "Change Damping"), limits: 0...1000, unit: "eV")
            case .lorentz:
                CompactNumberField(title: #"Strength $\Delta\varepsilon$"#, value: binding(\.strength, "Change Pole Strength"), limits: 0...10_000)
                CompactNumberField(title: #"Resonance $\hbar\omega_0$"#, value: binding(\.resonanceEv, "Change Resonance"), limits: 1e-6...1000, unit: "eV")
                CompactNumberField(title: #"Damping $\hbar\gamma$"#, value: binding(\.gammaEv, "Change Damping"), limits: 0...1000, unit: "eV")
            }
            IssueLines(issues: issues)
        }
        .padding(.vertical, 2)
    }
}
