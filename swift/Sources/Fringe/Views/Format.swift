import Foundation

/// Readouts in the units the inspector uses, with the user's decimal separator.
enum Format {
    static func number(_ value: Double, digits: ClosedRange<Int>, locale: Locale = .current) -> String {
        guard value.isFinite else { return "—" }
        let text = value.formatted(.number.precision(.fractionLength(digits)).grouping(.never).locale(locale))
        return text.hasPrefix("-") ? "−" + text.dropFirst() : text
    }

    /// "3.20 µm", or "450 nm" below a micrometre.
    static func micrometres(_ um: Double, digits: Int = 2) -> String {
        if abs(um) < 1, um != 0 {
            return "\(number(um * 1000, digits: 0...0)) nm"
        }
        return "\(number(um, digits: digits...digits)) µm"
    }

    static func wavelength(_ um: Double) -> String {
        "\(number(um * 1000, digits: 0...1)) nm"
    }

    static func degrees(_ value: Double, digits: Int = 1) -> String {
        "\(number(value, digits: 0...digits))°"
    }

    /// "3.20 $\lambda$", for `MathText`.
    static func waves(_ um: Double, lambda: Double) -> String {
        guard lambda > 0 else { return "" }
        return "\(number(um / lambda, digits: 2...2))" + #" $\lambda$"#
    }
}
