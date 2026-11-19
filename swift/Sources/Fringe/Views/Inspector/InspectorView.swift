import SwiftUI

struct InspectorView: View {
    @Environment(AppState.self) private var model

    var body: some View {
        let _ = PerfProbe.body("InspectorView")
        Form {
            if model.isInPuzzle {
                PuzzleInspector(model: model)
            } else {
                simulatorForms
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var simulatorForms: some View {
            switch model.selection {
            case .illumination:
                IlluminationForm(model: model)
            case .source(let id):
                if model.scene[source: id] != nil {
                    // A fresh identity per item, so text fields never show another item's
                    // half-typed value.
                    SourceForm(model: model, id: id)
                        .id(id)
                } else {
                    IlluminationForm(model: model)
                }
            case .element(let id):
                if model.scene[element: id] != nil {
                    ElementForm(model: model, id: id)
                        .id(id)
                } else {
                    IlluminationForm(model: model)
                }
            case .detector(let id):
                if model.scene[detector: id] != nil {
                    DetectorForm(model: model, id: id)
                        .id(id)
                } else {
                    IlluminationForm(model: model)
                }
            case .simulation:
                SimulationForm(model: model)
            case .display:
                DisplayForm(model: model)
            case .output:
                OutputForm(model: model)
            }
    }
}

/// Fields that follow a canvas drag (bindings made with `live: true`). A binding reads its
/// value when it is made, so the fields are made here, in this view's own body: the drag's
/// updates then re-evaluate these fields, not the form around them.
struct LiveFields<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        let _ = PerfProbe.body("LiveFields")
        content()
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

    /// Issues for source `index`, as `elementIssues` does for elements.
    func sourceIssues(_ index: Int, key: String?) -> [Issue] {
        itemIssues(checkReport?.issues(forSource: index) ?? [], whole: "sources[\(index)]", key: key)
    }

    /// Issues for detector `index`, as `elementIssues` does for elements.
    func detectorIssues(_ index: Int, key: String?) -> [Issue] {
        itemIssues(checkReport?.issues(forDetector: index) ?? [], whole: "detectors[\(index)]", key: key)
    }

    private func itemIssues(_ issues: [Issue], whole: String, key: String?) -> [Issue] {
        issues.filter { issue in
            let isWhole = issue.path == whole
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
        let _ = PerfProbe.body("OptionalNumberField")
        LabeledContent {
            HStack(spacing: 4) {
                TextField(MathTypesetter.plain(title), text: $text, prompt: Text(placeholder))
                    .labelsHidden()
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                    .focused($isFocused)
                    .onSubmit(commit)
                if !unit.isEmpty {
                    MathText(unit)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 20, alignment: .leading)
                }
            }
        } label: {
            MathText(title)
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
            .replacingOccurrences(of: "\u{2212}", with: "-")
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
            let text = String(format: "%g", value)
            return text.hasPrefix("-") ? "\u{2212}" + text.dropFirst() : text
        }
        return Format.number(value, digits: 0...4)
    }
}
