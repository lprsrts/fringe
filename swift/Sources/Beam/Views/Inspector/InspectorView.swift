import SwiftUI

struct InspectorView: View {
    @Environment(AppState.self) private var model

    var body: some View {
        Form {
            switch model.selection {
            case .source:
                SourceForm(model: model)
            case .element(let id):
                if model.scene[element: id] != nil {
                    ElementForm(model: model, id: id)
                } else {
                    SourceForm(model: model)
                }
            case .simulation:
                SimulationForm(model: model)
            case .display:
                DisplayForm(model: model)
            case .output:
                OutputForm(model: model)
            }
        }
        .formStyle(.grouped)
    }
}

extension AppState {
    /// Issues at `path` exactly, or below it with the given last key.
    func issues(at path: String) -> [Issue] {
        checkReport?.issues.filter { $0.path == path } ?? []
    }

    /// Issues for element `index` whose path ends in `key`; nil `key` gives the ones about
    /// the element as a whole.
    func elementIssues(_ index: Int, key: String?) -> [Issue] {
        (checkReport?.issues(forElement: index) ?? []).filter { issue in
            let isWhole = issue.path == "elements[\(index)]"
            guard let key else { return isWhole }
            return !isWhole && issue.fieldKey == key
        }
    }
}

/// A numeric override that is either a number or the default, shown as a placeholder.
struct OptionalNumberField: View {
    let title: String
    let value: Binding<Double?>
    let placeholder: String
    var unit = ""
    var limits: ClosedRange<Double> = 0...1e12

    @UIState private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField(title, text: $text, prompt: Text(placeholder))
                    .labelsHidden()
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                    .focused($isFocused)
                    .onSubmit(commit)
                if !unit.isEmpty {
                    Text(unit)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 20, alignment: .leading)
                }
            }
        }
        .onAppear { text = Self.format(value.wrappedValue) }
        .onChange(of: value.wrappedValue) { _, newValue in
            if !isFocused { text = Self.format(newValue) }
        }
        .onChange(of: isFocused) { _, focused in
            if !focused { commit() }
        }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            if value.wrappedValue != nil { value.wrappedValue = nil }
            return
        }
        let normalized = trimmed.replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: ".")
        if let number = Double(normalized), number.isFinite {
            let v = min(limits.upperBound, max(limits.lowerBound, number))
            if v != value.wrappedValue { value.wrappedValue = v }
            text = Self.format(v)
        } else {
            text = Self.format(value.wrappedValue)
        }
    }

    static func format(_ value: Double?) -> String {
        guard let value else { return "" }
        if value != 0, abs(value) < 1e-3 || abs(value) >= 1e6 {
            return String(format: "%g", value)
        }
        return Format.number(value, digits: 0...4).replacingOccurrences(of: "−", with: "-")
    }
}
