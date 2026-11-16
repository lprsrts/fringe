import Foundation

/// Readouts in the units the inspector uses, with the user's decimal separator.
enum Format {
    static func number(_ value: Double, digits: ClosedRange<Int>, locale: Locale = .current) -> String {
        value.formatted(.number.precision(.fractionLength(digits)).grouping(.never).locale(locale))
    }

    static func wavelength(_ metres: Double) -> String {
        "\(number(metres * 1e9, digits: 0...1)) nm"
    }

    static func millimetres(_ metres: Double, digits: Int = 1) -> String {
        "\(number(metres * 1000, digits: digits...digits)) mm"
    }

    static func centimetres(_ metres: Double) -> String {
        "\(number(metres * 100, digits: 1...1)) cm"
    }

    /// Picks m, mm or µm so the number stays short.
    static func length(_ metres: Double, locale: Locale = .current) -> String {
        if abs(metres) >= 1.0 {
            return "\(number(metres, digits: 3...3, locale: locale)) m"
        } else if abs(metres) >= 1e-3 {
            return "\(number(metres * 1000, digits: 2...2, locale: locale)) mm"
        } else {
            return "\(number(metres * 1e6, digits: 1...1, locale: locale)) µm"
        }
    }
}
