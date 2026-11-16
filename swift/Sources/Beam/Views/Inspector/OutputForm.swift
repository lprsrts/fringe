import SwiftUI

struct OutputForm: View {
    let model: AppState

    var body: some View {
        let output = model.output
        let size = model.outputPixelSize
        let megapixels = Double(size.width * size.height) / 1_000_000

        Section {
            Picker("Aspect Ratio", selection: model.binding("Change Aspect Ratio", \.output.aspect)) {
                ForEach(OutputAspect.presets, id: \.self) { Text($0.title).tag($0) }
                Text("Custom").tag(output.aspect.asCustom)
            }
            if case .custom(let width, let height) = output.aspect {
                LabeledContent("Ratio") {
                    HStack(spacing: 4) {
                        ratioField("Ratio Width", value: width, alignment: .trailing) { .custom(width: $0, height: height) }
                        Text(":").foregroundStyle(.secondary)
                        ratioField("Ratio Height", value: height, alignment: .leading) { .custom(width: width, height: $0) }
                    }
                }
            }
            Picker("Size", selection: model.binding("Change Size", \.output.longEdge)) {
                ForEach(LongEdge.presets, id: \.self) { Text("\($0.pixels) px").tag($0) }
                Text("Custom").tag(LongEdge.custom(output.longEdge.pixels))
            }
            if output.longEdge.isCustom {
                LabeledContent("Long Edge") {
                    HStack(spacing: 4) {
                        TextField("Long Edge", value: customLongEdge, format: .number.grouping(.never))
                            .labelsHidden()
                            .monospacedDigit()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 72)
                        Text("px").foregroundStyle(.secondary)
                    }
                }
            }
            LabeledContent("Pixels", value: "\(size.width) × \(size.height) · \(Format.number(megapixels, digits: 1...1)) MP")
                .monospacedDigit()
        } header: {
            Text("Format")
        } footer: {
            Text("The domain keeps this shape: changing the ratio changes its height, not its width.")
                .foregroundStyle(.secondary)
        }

        Section("Animation") {
            Stepper(value: Binding(get: { model.animationFrameCount }, set: { model.animationFrameCount = $0 }), in: 2...360) {
                LabeledContent("Frames per Period", value: "\(model.animationFrameCount)")
                    .monospacedDigit()
            }
            Button("Export Animation Frames…") { model.exportAnimationFrames() }
                .disabled(model.solver.shown == nil)
        }

        Section("Field Data") {
            Button("Export Field Data (.npy)…") { model.exportFieldData() }
                .disabled(model.solver.shown == nil)
            Text("Complex Ez of the \(model.display.part.title.lowercased()) field on the solver's grid, with a .json file describing the grid.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func ratioField(_ title: String, value: Int, alignment: TextAlignment, aspect: @escaping (Int) -> OutputAspect) -> some View {
        TextField(title, value: Binding(
            get: { value },
            set: { term in
                let term = min(OutputAspect.customTermRange.upperBound, max(OutputAspect.customTermRange.lowerBound, term))
                model.edit("Change Aspect Ratio") { $0.output.aspect = aspect(term) }
            }
        ), format: .number.grouping(.never))
        .labelsHidden()
        .monospacedDigit()
        // The width sits against the colon from the left and the height from the right,
        // so the pair reads "4 : 1".
        .multilineTextAlignment(alignment)
        .frame(width: 44)
    }

    private var customLongEdge: Binding<Int> {
        Binding(
            get: { model.output.longEdge.pixels },
            set: { pixels in model.edit("Change Size") { $0.output.longEdge = .custom(pixels) } }
        )
    }
}
