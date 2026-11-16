import AppKit

/// Math in labels, set the way TeX sets it. A string marks math with `$…$`, as in
/// "Waist Radius $w_0$", and the math is set in STIX Two, the fonts macOS ships for
/// TeX-style mathematics: italic variables, upright digits, operators and function
/// names, raised and lowered scripts, and TeX's spacing around operators.
///
/// The subset: letters, digits and punctuation; `^` and `_` followed by one character
/// or a `{group}`; `\operatorname{…}` and `\mathrm{…}` for upright words; the commands
/// in `symbols` and `functions`; `\,` for a thin space. Spaces inside math are ignored,
/// as in TeX. A `$` outside math that is not a delimiter can be written `\$`.
enum MathTypesetter {
    /// Italic and upright come from STIX Two Text; symbols it lacks, such as ∠, from STIX Two Math.
    enum Shape: Equatable { case italic, upright, symbol }
    enum Position: Equatable { case base, superscript, `subscript` }

    struct Run: Equatable {
        var text: String
        var shape: Shape
        var position: Position
    }

    enum Segment: Equatable {
        case text(String)
        case math([Run])
    }

    static let italicFontName = "STIXTwoText-Italic"
    static let uprightFontName = "STIXTwoText"
    static let symbolFontName = "STIXTwoMath-Regular"

    /// STIX Two's x-height is about 7 % below San Francisco's, so math is set this much
    /// larger to read as the same size as the text around it.
    static let mathScale: CGFloat = 1.07
    static let scriptScale: CGFloat = 0.7

    /// Script baseline shift as a fraction of the math size.
    static func baselineShift(_ position: Position) -> CGFloat {
        switch position {
        case .base: 0
        case .superscript: 0.36
        case .subscript: -0.18
        }
    }

    // MARK: Parsing

    private static let symbols: [String: (String, Shape)] = [
        "lambda": ("λ", .italic), "varphi": ("φ", .italic), "phi": ("ϕ", .italic), "theta": ("θ", .italic),
        "beta": ("β", .italic), "pi": ("π", .italic), "omega": ("ω", .italic), "varepsilon": ("ε", .italic),
        "epsilon": ("ϵ", .italic), "mu": ("µ", .upright), "angle": ("∠", .symbol), "cdot": ("·", .upright),
        "times": ("×", .upright), "approx": ("≈", .symbol), "pm": ("±", .upright), "infty": ("∞", .symbol),
        "dagger": ("†", .upright),
    ]

    private static let functions: Set<String> = ["exp", "arg", "Re", "Im", "sin", "cos", "log", "ln"]

    /// Binary operators get a medium space each side, relations a thick one, as in TeX.
    private static let binaryOperators: Set<String> = ["+", "−", "×", "·", "±"]
    private static let relations: Set<String> = ["=", "≈", "<", ">"]
    private static let mediumSpace = "\u{2005}"
    private static let thickSpace = "\u{2004}"
    private static let thinSpace = "\u{2009}"
    /// Italic correction: an italic letter leans into a superscript after it.
    private static let hairSpace = "\u{200A}"

    /// One parsed atom before spacing: an operator name gets a thin space before an
    /// ordinary atom that follows it.
    private struct Atom {
        var run: Run
        var isOperatorName = false
    }

    /// Splits `source` into plain text and math.
    static func segments(_ source: String) -> [Segment] {
        var segments: [Segment] = []
        var text = ""
        var math: String?
        var chars = Array(source)[...]
        while let c = chars.popFirst() {
            if c == "\\", chars.first == "$" {
                chars.removeFirst()
                if math != nil { math! += "\\$" } else { text.append("$") }
            } else if c == "$" {
                if let tex = math {
                    segments.append(.math(runs(tex)))
                    math = nil
                } else {
                    if !text.isEmpty { segments.append(.text(text)) }
                    text = ""
                    math = ""
                }
            } else if math != nil {
                math!.append(c)
            } else {
                text.append(c)
            }
        }
        // An unclosed `$` is kept as written.
        if let tex = math { text += "$" + tex }
        if !text.isEmpty { segments.append(.text(text)) }
        return segments
    }

    /// The runs of one math expression (the part between the `$`s).
    static func runs(_ tex: String) -> [Run] {
        var chars = Array(tex)[...]
        let atoms = parseList(&chars, position: .base, upright: false, closing: nil)
        return merged(spaced(atoms))
    }

    private static func parseList(_ chars: inout ArraySlice<Character>, position: Position, upright: Bool, closing: Character?) -> [Atom] {
        var atoms: [Atom] = []
        while let c = chars.first {
            if c == closing {
                chars.removeFirst()
                break
            }
            if c == " " {
                chars.removeFirst()
                continue
            }
            if c == "^" || c == "_" {
                chars.removeFirst()
                atoms += parseAtom(&chars, position: c == "^" ? .superscript : .subscript, upright: upright)
            } else {
                atoms += parseAtom(&chars, position: position, upright: upright)
            }
        }
        return atoms
    }

    private static func parseAtom(_ chars: inout ArraySlice<Character>, position: Position, upright: Bool) -> [Atom] {
        while chars.first == " " { chars.removeFirst() }
        guard let c = chars.popFirst() else { return [] }
        switch c {
        case "{":
            return parseList(&chars, position: position, upright: upright, closing: "}")
        case "\\":
            return parseCommand(&chars, position: position, upright: upright)
        case "-":
            return [Atom(run: Run(text: "−", shape: .upright, position: position))]
        default:
            let shape: Shape = c.isLetter && !upright ? .italic : .upright
            return [Atom(run: Run(text: String(c), shape: shape, position: position))]
        }
    }

    private static func parseCommand(_ chars: inout ArraySlice<Character>, position: Position, upright: Bool) -> [Atom] {
        guard let first = chars.first else { return [Atom(run: Run(text: "\\", shape: .upright, position: position))] }
        guard first.isLetter else {
            chars.removeFirst()
            switch first {
            case ",": return [Atom(run: Run(text: thinSpace, shape: .upright, position: position))]
            case " ": return [Atom(run: Run(text: " ", shape: .upright, position: position))]
            default: return [Atom(run: Run(text: String(first), shape: .upright, position: position))]
            }
        }
        var name = ""
        while let c = chars.first, c.isLetter {
            name.append(c)
            chars.removeFirst()
        }
        if name == "operatorname" || name == "mathrm" {
            var word = parseAtom(&chars, position: position, upright: true)
            if name == "operatorname", !word.isEmpty { word[word.count - 1].isOperatorName = true }
            return word
        }
        if functions.contains(name) {
            return [Atom(run: Run(text: name, shape: .upright, position: position), isOperatorName: true)]
        }
        if let (symbol, shape) = symbols[name] {
            return [Atom(run: Run(text: symbol, shape: upright && shape == .italic ? .upright : shape, position: position))]
        }
        return [Atom(run: Run(text: "\\" + name, shape: .upright, position: position))]
    }

    /// Adds TeX's spacing: around binary operators and relations (not when an operator is
    /// unary, at the start or after an opening bracket or another operator), and after an
    /// operator name that is followed by an ordinary atom rather than a bracket.
    private static func spaced(_ atoms: [Atom]) -> [Run] {
        var runs: [Run] = []
        for (index, atom) in atoms.enumerated() {
            var run = atom.run
            // The atom before this one at the same level, as parsed, before any spacing.
            let previous = atoms[..<index].last { $0.run.position == run.position && !$0.run.text.allSatisfy(\.isWhitespace) }?.run
            let isBinary = binaryOperators.contains(run.text)
            let isRelation = relations.contains(run.text)
            if isBinary || isRelation, run.position == .base {
                let unary = previous.map { binaryOperators.contains($0.text) || relations.contains($0.text) || ["(", "[", "{"].contains($0.text) } ?? true
                if !(isBinary && unary) {
                    let space = isRelation ? thickSpace : mediumSpace
                    run.text = space + run.text + space
                }
            }
            if run.position == .superscript, let last = runs.last, last.position == .base, last.shape == .italic {
                runs.append(Run(text: hairSpace, shape: .upright, position: .base))
            }
            runs.append(run)
            if atom.isOperatorName, index + 1 < atoms.count {
                let next = atoms[index + 1].run
                if next.position == run.position, !"([{".contains(next.text.first ?? " ") {
                    runs.append(Run(text: thinSpace, shape: .upright, position: run.position))
                }
            }
        }
        return runs
    }

    /// Joins neighbouring runs with the same shape and position.
    private static func merged(_ runs: [Run]) -> [Run] {
        var out: [Run] = []
        for run in runs {
            if var last = out.last, last.shape == run.shape, last.position == run.position {
                last.text += run.text
                out[out.count - 1] = last
            } else {
                out.append(run)
            }
        }
        return out
    }

    /// `text` with its `$` escaped, for putting user text such as an element name into a
    /// string that is typeset.
    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "$", with: "\\$")
    }

    // MARK: Output

    /// `source` with its math flattened to plain Unicode, for accessibility labels, menu
    /// items, tooltips and other places that cannot show styled text: "$w_0$" becomes
    /// "w₀", "$|E|^2$" becomes "|E|²", "$e^{j\varphi}$" becomes "e^(jφ)".
    static func plain(_ source: String) -> String {
        segments(source).map { segment in
            switch segment {
            case .text(let text):
                return text
            case .math(let runs):
                return runs.map { run in
                    let text = run.text.replacingOccurrences(of: mediumSpace, with: " ")
                        .replacingOccurrences(of: thickSpace, with: " ")
                        .replacingOccurrences(of: thinSpace, with: " ")
                        .replacingOccurrences(of: hairSpace, with: "")
                    switch run.position {
                    case .base: return text
                    case .superscript: return scripted(text, superscripts) ?? "^" + (text.count > 1 ? "(\(text))" : text)
                    case .subscript: return scripted(text, subscripts) ?? text
                    }
                }.joined()
            }
        }.joined()
    }

    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "−": "⁻", "n": "ⁿ", "i": "ⁱ",
    ]
    private static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "−": "₋", "a": "ₐ", "e": "ₑ", "o": "ₒ", "x": "ₓ", "h": "ₕ", "k": "ₖ", "l": "ₗ", "m": "ₘ",
        "n": "ₙ", "p": "ₚ", "s": "ₛ", "t": "ₜ", "i": "ᵢ", "j": "ⱼ", "r": "ᵣ", "u": "ᵤ", "v": "ᵥ",
    ]

    /// `text` in Unicode script characters, or nil when Unicode lacks one of them.
    private static func scripted(_ text: String, _ table: [Character: Character]) -> String? {
        let mapped = text.compactMap { table[$0] }
        return mapped.count == text.count ? String(mapped) : nil
    }

    /// STIX Two at `size`, semibold to sit with semibold text.
    static func mathFont(_ shape: Shape, size: CGFloat, semibold: Bool = false) -> NSFont {
        let name = switch (shape, semibold) {
        case (.italic, false): italicFontName
        case (.upright, false): uprightFontName
        case (.italic, true): "STIXTwoText-Italic_SemiBold-Italic"
        case (.upright, true): "STIXTwoText_SemiBold"
        case (.symbol, _): symbolFontName
        }
        return NSFont(name: name, size: size)
            ?? NSFontManager.shared.convert(.systemFont(ofSize: size, weight: semibold ? .semibold : .regular),
                                            toHaveTrait: shape == .italic ? .italicFontMask : [])
    }

    /// `source` as an attributed string for AppKit and CoreText drawing: text in `font`,
    /// math in STIX Two sized to match it.
    static func attributed(_ source: String, font: NSFont, color: NSColor? = nil) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var base: [NSAttributedString.Key: Any] = [.font: font]
        if let color { base[.foregroundColor] = color }
        let mathSize = font.pointSize * mathScale
        // NSFontManager weights run 0–15: regular is 5, semibold 8.
        let semibold = NSFontManager.shared.weight(of: font) >= 8
        for segment in segments(source) {
            switch segment {
            case .text(let text):
                out.append(NSAttributedString(string: text, attributes: base))
            case .math(let runs):
                for run in runs {
                    let size = run.position == .base ? mathSize : mathSize * scriptScale
                    var attributes = base
                    attributes[.font] = mathFont(run.shape, size: size, semibold: semibold)
                    attributes[.baselineOffset] = baselineShift(run.position) * mathSize
                    out.append(NSAttributedString(string: run.text, attributes: attributes))
                }
            }
        }
        return out
    }
}
