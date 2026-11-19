import Foundation

/// Readouts in the units the inspector uses, with the user's decimal separator.
enum Format {
    static func number(_ value: Double, digits: ClosedRange<Int>, locale: Locale = .current) -> String {
        guard value.isFinite else { return "—" }
        let text = value.formatted(.number.precision(.fractionLength(digits)).grouping(.never).locale(locale))
        guard text.hasPrefix("-") else { return text }
        // A value that rounds to zero prints without a sign: "0.0", never "−0.0".
        let digitsOnly = text.dropFirst()
        return digitsOnly.contains(where: { $0.isNumber && $0 != "0" }) ? "−" + digitsOnly : String(digitsOnly)
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

    /// `digits` significant digits: "0.412", "3.10", "−0.0310"; "1.23×10⁻⁷" outside
    /// 10⁻³…10⁵, where plain digits would run long.
    static func significant(_ value: Double, digits: Int = 3, locale: Locale = .current) -> String {
        guard value.isFinite else { return "—" }
        guard value != 0 else { return "0" }
        let magnitude = abs(value)
        if magnitude < 1e-3 || magnitude >= 1e5 {
            var exponent = Int(floor(log10(magnitude)))
            var mantissa = value / pow(10, Double(exponent))
            // 9.996 rounds up to 10.0 at three digits: carry into the exponent.
            if abs((mantissa * pow(10, Double(digits - 1))).rounded()) >= pow(10, Double(digits)) {
                exponent += 1
                mantissa /= 10
            }
            return number(mantissa, digits: (digits - 1)...(digits - 1), locale: locale) + "×10" + superscript(exponent)
        }
        let text = value.formatted(.number.precision(.significantDigits(digits)).grouping(.never).locale(locale))
        return text.hasPrefix("-") ? "−" + text.dropFirst() : text
    }

    private static func superscript(_ n: Int) -> String {
        let digits: [Character] = ["⁰", "¹", "²", "³", "⁴", "⁵", "⁶", "⁷", "⁸", "⁹"]
        let body = String(abs(n)).map { digits[Int(String($0))!] }
        return (n < 0 ? "⁻" : "") + String(body)
    }

    /// A line detector's power per µm in z, in units of A²: "0.412 $A^2$·µm" (math, for
    /// `MathText`).
    static func power(_ value: Double) -> String {
        "\(significant(value)) $A^2$·µm"
    }

    /// "7.87 eV".
    static func electronVolts(_ value: Double) -> String {
        "\(significant(value)) eV"
    }

    /// "12.1 dB".
    static func decibels(_ value: Double) -> String {
        "\(number(value, digits: 1...1)) dB"
    }

    /// A fraction as "42%", with no space before the sign as in the rest of the app.
    static func percent(_ fraction: Double, digits: Int = 0) -> String {
        "\(number(fraction * 100, digits: 0...digits))%"
    }
}

