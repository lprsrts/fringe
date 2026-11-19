import SwiftUI

/// A length in micrometres. Typing accepts `nm`, `µm` (or `um`), `mm` and `λ` suffixes,
/// where λ is the background wavelength; a bare number is in µm. Below the field it shows
/// the value in wavelengths and any issues the core reported for it.
struct LengthField: View {
    let title: String
    let value: Binding<Double>
    /// Background wavelength in µm.
    let lambda: Double
    /// Slider range in µm; no slider when nil.
    var range: ClosedRange<Double>?
    var limits: ClosedRange<Double> = -1e6...1e6
    var issues: [Issue] = []
    var onEditingChanged: (Bool) -> Void = { _ in }

    @UIState private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        let _ = PerfProbe.body("LengthField")
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent {
                HStack(spacing: 4) {
                    TextField(MathTypesetter.plain(title), text: $text)
                        .labelsHidden()
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 72)
                        .focused($isFocused)
                        .onSubmit(commit)
                    Text("µm")
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 20, alignment: .leading)
                }
            } label: {
                MathText(title)
            }
            if let range {
                Slider(
                    value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = clamp($0) }),
                    in: range,
                    label: { Text(MathTypesetter.plain(title)) },
                    onEditingChanged: onEditingChanged
                )
                .labelsHidden()
            }
            HStack {
                Spacer()
                MathText("= \(Format.waves(value.wrappedValue, lambda: lambda))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            IssueLines(issues: issues)
        }
        .onAppear { text = Self.format(value.wrappedValue) }
        .onChange(of: value.wrappedValue) { _, newValue in
            if !isFocused { text = Self.format(newValue) }
        }
        .onChange(of: isFocused) { _, focused in
            if !focused { commit() }
        }
    }

    private func clamp(_ v: Double) -> Double {
        min(limits.upperBound, max(limits.lowerBound, v))
    }

    private func commit() {
        if let parsed = Self.parse(text, lambda: lambda) {
            let v = clamp(parsed)
            if v != value.wrappedValue { value.wrappedValue = v }
            text = Self.format(v)
        } else {
            text = Self.format(value.wrappedValue)
        }
    }

    static func format(_ um: Double) -> String {
        Format.number(um, digits: 0...4)
    }

    /// Parses "3.2", "3.2 µm", "450nm", "2λ", "0,5 mm" to micrometres.
    static func parse(_ text: String, lambda: Double) -> Double? {
        var s = text.trimmingCharacters(in: .whitespaces).lowercased()
        s = s.replacingOccurrences(of: "−", with: "-")
        var factor = 1.0
        let suffixes: [(String, Double)] = [("nm", 1e-3), ("µm", 1), ("μm", 1), ("um", 1), ("mm", 1e3), ("λ", lambda), ("wl", lambda)]
        for (suffix, f) in suffixes where s.hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            factor = f
            break
        }
        if s.isEmpty, factor == lambda { s = "1" }
        let decimal = Locale.current.decimalSeparator ?? "."
        if decimal != "." { s = s.replacingOccurrences(of: decimal, with: ".") }
        s = s.replacingOccurrences(of: ",", with: ".")
        guard let number = Double(s), number.isFinite else { return nil }
        return number * factor
    }
}

/// Issues from the check report, shown under the field they are about.
struct IssueLines: View {
    let issues: [Issue]

    var body: some View {
        let _ = PerfProbe.body("IssueLines")
        ForEach(issues, id: \.self) { issue in
            Label {
                MathText(issue.mathSentence)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: issue.isError ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(issue.isError ? .red : .orange)
            }
            .font(.caption)
            .foregroundStyle(issue.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        }
    }
}
