import AppKit
import SwiftUI

/// The one look of every plot in the app: thin ink, L-axes with short ticks, a recessive
/// grid, system greys for everything that is not data. Colours resolve per appearance
/// (`Palette(scheme)`), so a plot drawn offscreen in either appearance matches the app.
enum PlotStyle {
    struct Palette {
        /// The main series: n, k, Total. Fixed to system blue (the default accent): a
        /// graphite accent would read as the grey reference, a yellow one fails 3:1 on white.
        var ink: Color
        /// A second peer series on the same axis (only the puzzle contrast plot).
        var ink2: Color
        /// The Incident reference curve, the λ0 rule and the crosshair.
        var reference: Color
        /// Axes and ticks.
        var frame: Color
        /// Horizontal gridlines.
        var grid: Color
        /// Out-of-range shade and gap bands.
        var wash: Color
        var text: Color
        var textSecondary: Color
        /// The background the plot sits on, for marker rings and the readout card.
        var surface: Color

        init(_ scheme: ColorScheme, surface: Color? = nil) {
            let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
            func resolve(_ color: NSColor) -> Color {
                var out = Color.gray
                appearance.performAsCurrentDrawingAppearance {
                    if let c = color.usingColorSpace(.sRGB) {
                        out = Color(.sRGB, red: c.redComponent, green: c.greenComponent, blue: c.blueComponent, opacity: c.alphaComponent)
                    }
                }
                return out
            }
            ink = resolve(.systemBlue)
            ink2 = scheme == .dark ? Color(.sRGB, red: 0xD9 / 255, green: 0x59 / 255, blue: 0x26 / 255)
                : Color(.sRGB, red: 0xD9 / 255, green: 0x54 / 255, blue: 0x1E / 255)
            // Light: systemGray's darker step (#6E6E73), 4.6:1 on #F5F5F5, where the
            // secondary label grey falls just under 3:1. Dark: the secondary label grey.
            reference = scheme == .dark ? resolve(.secondaryLabelColor)
                : Color(.sRGB, red: 0x6E / 255, green: 0x6E / 255, blue: 0x73 / 255)
            frame = resolve(.tertiaryLabelColor)
            grid = resolve(.separatorColor)
            // Faint: it marks a range as less certain, so it must never outweigh the data,
            // even when it covers most of the plot. Its edge carries a hairline.
            wash = scheme == .dark ? Color.white.opacity(0.035) : Color.black.opacity(0.03)
            text = resolve(.labelColor)
            textSecondary = resolve(.secondaryLabelColor)
            self.surface = surface ?? resolve(.windowBackgroundColor)
        }
    }

    /// The band between a puzzle's 0-cases and 1-cases: a little stronger than the wash,
    /// since it is the point of the plot; its dotted edges carry the meaning.
    static func gapFill(_ palette: Palette) -> Color { palette.text.opacity(0.07) }

    // MARK: Strokes (points)

    static let dataWidth: CGFloat = 1.5
    static let referenceWidth: CGFloat = 1.25
    static let referenceDash: [CGFloat] = [4, 3]
    static let tickLength: CGFloat = 3
    static let markerRadius: CGFloat = 3
    static let markerRing: CGFloat = 1.5

    static func data(_ width: CGFloat = dataWidth) -> StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
    }

    static var reference: StrokeStyle {
        StrokeStyle(lineWidth: referenceWidth, lineCap: .butt, lineJoin: .round, dash: referenceDash)
    }

    // MARK: Type (sizes fixed so layout can measure them)

    static let tickSize: CGFloat = 10
    static let titleSize: CGFloat = 10
    static let panelLabelSize: CGFloat = 12
    static let curveLabelSize: CGFloat = 11
    static let readoutValueSize: CGFloat = 11
    static let readoutNameSize: CGFloat = 10

    static var tickFont: Font { .system(size: tickSize).monospacedDigit() }
    static var titleFont: Font { .system(size: titleSize).monospacedDigit() }
    static var curveLabelFont: Font { .system(size: curveLabelSize, weight: .medium) }
    static var readoutValueFont: Font { .system(size: readoutValueSize, weight: .semibold).monospacedDigit() }
    static var readoutNameFont: Font { .system(size: readoutNameSize) }

    static var tickNSFont: NSFont { .monospacedDigitSystemFont(ofSize: tickSize, weight: .regular) }
    static var titleNSFont: NSFont { .monospacedDigitSystemFont(ofSize: titleSize, weight: .regular) }
    static var curveLabelNSFont: NSFont { .systemFont(ofSize: curveLabelSize, weight: .medium) }

    /// Width of `source` (with `$…$` math) in `font`.
    static func width(_ source: String, font: NSFont) -> CGFloat {
        ceil(MathTypesetter.attributed(source, font: font).size().width)
    }

    // MARK: Spacing

    /// Gap between a tick's end and its label.
    static let labelGap: CGFloat = 4
    /// Height of the row above a panel for its label or y title.
    static let titleRow: CGFloat = 18
    /// Height of the x tick-label row and the x title row.
    static let tickRow: CGFloat = 15
    static let xTitleRow: CGFloat = 15
    static let noteRow: CGFloat = 14
    /// Room between panels, so the next panel's title clears the bottom tick label above it.
    static let panelGap: CGFloat = 14
    /// Below this plot width the narrow layout applies.
    static let narrowWidth: CGFloat = 260
}

/// The background a plot sits on (the inspector row or the results panel), for marker
/// rings and the readout card. Written by hand: the CLT toolchain has no `@Entry` macro.
private struct PlotSurfaceKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

extension EnvironmentValues {
    var plotSurface: Color? {
        get { self[PlotSurfaceKey.self] }
        set { self[PlotSurfaceKey.self] = newValue }
    }
}

extension View {
    func plotSurface(_ color: Color?) -> some View {
        environment(\.plotSurface, color)
    }
}
