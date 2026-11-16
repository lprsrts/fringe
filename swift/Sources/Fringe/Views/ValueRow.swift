import SwiftUI

/// A labelled number with its unit, edited with a slider or typed in. The title and unit
/// may contain `$…$` math.
/// `value` is in display units; the caller converts from the model's units.
struct ValueRow: View {
    let title: String
    let value: Binding<Double>
    /// Slider range. The field accepts anything within `limits`.
    let range: ClosedRange<Double>
    var limits: ClosedRange<Double> = -Double.greatestFiniteMagnitude...Double.greatestFiniteMagnitude
    /// Smallest magnitude allowed, for quantities such as a focal length that the core
    /// rejects at zero. Values closer to zero snap out to this, keeping their sign.
    var minimumMagnitude: Double?
    var unit = ""
    var digits = 2
    var neutral: Double?
    var ticks: [Double] = []
    /// Maps the slider logarithmically, for ranges that span decades.
    var logarithmic = false
    var onEditingChanged: (Bool) -> Void = { _ in }

    /// The title without math markup, for the field's and slider's accessibility labels.
    private var plainTitle: String { MathTypesetter.plain(title) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent {
                HStack(spacing: 4) {
                    TextField(plainTitle, value: fieldValue, format: .number.precision(.fractionLength(digits)).grouping(.never))
                        .labelsHidden()
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 72)
                    if !unit.isEmpty {
                        MathText(unit)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 20, alignment: .leading)
                    }
                }
            } label: {
                MathText(title)
            }
            slider
                .labelsHidden()
        }
    }

    @ViewBuilder
    private var slider: some View {
        if ticks.isEmpty {
            Slider(
                value: sliderValue,
                in: sliderRange,
                neutralValue: neutral.map(toSlider),
                label: { Text(plainTitle) },
                onEditingChanged: onEditingChanged
            )
        } else {
            Slider(
                value: sliderValue,
                in: sliderRange,
                neutralValue: neutral.map(toSlider),
                label: { Text(plainTitle) },
                ticks: { SliderTickContentForEach(ticks.map(toSlider), id: \.self) { SliderTick($0) } },
                onEditingChanged: onEditingChanged
            )
        }
    }

    private var fieldValue: Binding<Double> {
        Binding(
            get: { value.wrappedValue },
            set: { value.wrappedValue = constrained($0) }
        )
    }

    private func constrained(_ newValue: Double) -> Double {
        var result = min(limits.upperBound, max(limits.lowerBound, newValue))
        if let minimum = minimumMagnitude, abs(result) < minimum {
            // An exact zero has no sign of its own, so it keeps the side the value was on.
            let positive = result == 0 ? value.wrappedValue >= 0 : result > 0
            result = positive ? minimum : -minimum
        }
        return result
    }

    private var sliderRange: ClosedRange<Double> {
        toSlider(range.lowerBound)...toSlider(range.upperBound)
    }

    private var sliderValue: Binding<Double> {
        Binding(
            get: { toSlider(value.wrappedValue) },
            set: { value.wrappedValue = constrained(fromSlider($0)) }
        )
    }

    private func toSlider(_ value: Double) -> Double {
        logarithmic ? log10(max(1e-12, value)) : value
    }

    private func fromSlider(_ position: Double) -> Double {
        logarithmic ? pow(10, position) : position
    }
}

extension Binding where Value == Double {
    /// The same value multiplied by `factor`, for showing micrometres as nanometres and so on.
    func scaled(by factor: Double) -> Binding<Double> {
        Binding(
            get: { wrappedValue * factor },
            set: { wrappedValue = $0 / factor }
        )
    }
}
