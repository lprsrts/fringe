import SwiftUI

/// A label whose `$…$` spans are set as math (see `MathTypesetter`), at the size of the
/// font around it. VoiceOver reads the plain Unicode form.
struct MathText: View {
    let source: String
    /// The size of the surrounding text where the environment has no font, which is
    /// otherwise taken as body size.
    var defaultPointSize: CGFloat?

    @Environment(\.font) private var font
    @Environment(\.fontResolutionContext) private var fontContext

    init(_ source: String, defaultPointSize: CGFloat? = nil) {
        self.source = source
        self.defaultPointSize = defaultPointSize
    }

    /// For a section footer in a grouped form, which is set at the small system size
    /// without putting that font in the environment.
    static func footer(_ source: String) -> MathText {
        MathText(source, defaultPointSize: NSFont.smallSystemFontSize)
    }

    var body: some View {
        let _ = PerfProbe.body("MathText")
        let size = font.map { $0.resolve(in: fontContext).pointSize }
            ?? defaultPointSize
            ?? Font.body.resolve(in: fontContext).pointSize
        Text(MathTypesetter.styled(source, pointSize: size))
            .accessibilityLabel(MathTypesetter.plain(source))
    }
}

extension MathTypesetter {
    /// `source` for a SwiftUI `Text`: text runs carry no font, so they follow the
    /// environment; math runs are STIX Two at a size matched to `pointSize`.
    static func styled(_ source: String, pointSize: CGFloat) -> AttributedString {
        var out = AttributedString()
        let mathSize = pointSize * mathScale
        for segment in segments(source) {
            switch segment {
            case .text(let text):
                out += AttributedString(text)
            case .math(let runs):
                for run in runs {
                    let size = run.position == .base ? mathSize : mathSize * scriptScale
                    var piece = AttributedString(run.text)
                    piece.font = switch run.shape {
                    case .italic: .custom(italicFontName, fixedSize: size)
                    case .upright: .custom(uprightFontName, fixedSize: size)
                    case .symbol: .custom(symbolFontName, fixedSize: size)
                    }
                    piece.baselineOffset = baselineShift(run.position) * mathSize
                    out += piece
                }
            }
        }
        return out
    }
}
