import SwiftUI

/// The strip under the canvas: what the image is (state, solver, resolution, size, time,
/// memory) on the left, the value under the pointer on the right.
struct StatusBar: View {
    let model: AppState

    static let height: CGFloat = 24

    var body: some View {
        let _ = PerfProbe.body("StatusBar")
        VStack(spacing: 0) {
            Divider()
            // In a narrow column the summary drops its last parts first, and the readout
            // shortens to the position, then goes; neither is ever cut mid-word.
            HStack(spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    SolveSummary(model: model, detail: .full).fixedSize()
                    SolveSummary(model: model, detail: .short).fixedSize()
                    SolveSummary(model: model, detail: .state).fixedSize()
                }
                .layoutPriority(1)
                Spacer(minLength: 12)
                HoverReadoutView(viewport: model.viewport)
                    .frame(maxWidth: .infinity, minHeight: 14, maxHeight: 14)
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(maxHeight: .infinity)
        }
        .frame(height: Self.height)
        .background(.bar)
    }

    /// The readout's parts, joined by three spaces in `readout`.
    static func readoutParts(_ hover: HoverReadout, positionOnly: Bool = false) -> [String] {
        var parts = ["$x$ \(Format.number(hover.xUm, digits: 2...2)) µm", "$y$ \(Format.number(hover.yUm, digits: 2...2)) µm"]
        if positionOnly { return parts }
        if let intensity = hover.intensity {
            parts.append("$|E|^2$ \(Format.number(intensity, digits: 2...2))")
        }
        if let phase = hover.phaseDeg {
            parts.append(#"$\angle E$ "# + Format.degrees(phase, digits: 0))
        }
        if let body = hover.body {
            parts.append(body)
        }
        return parts
    }

    /// "$x$ 1.20 µm  $y$ −0.40 µm  $|E|^2$ 0.82  $\angle E$ 35°  Lens ($n$ 1.50)".
    static func readout(_ hover: HoverReadout, positionOnly: Bool = false) -> String {
        readoutParts(hover, positionOnly: positionOnly).joined(separator: "   ")
    }
}

/// The value under the pointer: an AppKit text field that the canvas model updates
/// directly, with a width set by the status bar, so a pointer move changes one field's text
/// and re-evaluates or lays out nothing else. Shows the full readout when it fits, else the
/// position, else nothing (as `ViewThatFits` did).
private struct HoverReadoutView: NSViewRepresentable {
    let viewport: ViewportModel

    func makeNSView(context: Context) -> HoverReadoutField {
        let field = HoverReadoutField()
        viewport.hoverSinks.removeAll { $0.value == nil }
        viewport.hoverSinks.append(.init(value: field))
        field.show(viewport.hover)
        return field
    }

    func updateNSView(_ field: HoverReadoutField, context: Context) {}
}

/// The readout draws into a layer of its own, outside AppKit's view display: a pointer
/// move redraws that one layer (no `displayIfNeeded` of the window, no vibrancy pass).
final class HoverReadoutField: NSView, CALayerDelegate {
    private var readout: HoverReadout?
    /// The laid-out segments for the current readout and width.
    private var lines: [CTLine]?
    private let textLayer = CALayer()
    private var shownText: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        textLayer.delegate = self
        // 8-bit sRGB: the default on an XDR display is half-float, four times the work.
        textLayer.contentsFormat = .RGBA8Uint
        // The text is right-aligned: a width change keeps the drawn text at the right edge
        // and redraws only when another set of parts fits (see `setFrameSize`), so a
        // window resize redraws nothing.
        textLayer.needsDisplayOnBoundsChange = false
        textLayer.contentsGravity = .right
        textLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(textLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated func action(for layer: CALayer, forKey event: String) -> CAAction? { NSNull() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 14) }
    override var isFlipped: Bool { true }
    override var allowsVibrancy: Bool { false }

    func show(_ hover: HoverReadout?) {
        // A move that leaves the text as it was (the same hundredth of a micrometre) draws
        // nothing.
        let text = hover.map { StatusBar.readout($0) }
        guard text != shownText else { return }
        shownText = text
        readout = hover
        lines = nil
        textLayer.setNeedsDisplay()
        let tip = hover == nil ? nil : "Position, field and element under the pointer"
        if toolTip != tip { toolTip = tip }
    }

    override func accessibilityValue() -> Any? { readout.map { MathTypesetter.plain(StatusBar.readout($0)) } }

    override func setFrameSize(_ newSize: NSSize) {
        let old = bounds.size
        super.setFrameSize(newSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textLayer.frame = bounds
        CATransaction.commit()
        guard newSize != old else { return }
        if newSize.height != old.height {
            lines = nil
            textLayer.setNeedsDisplay()
            return
        }
        // Nothing shown: nothing to draw. Otherwise only when the parts that fit change.
        guard readout != nil else { lines = nil; return }
        let before = lines
        lines = nil
        let after = layoutLines()
        if before.map({ $0.map { ObjectIdentifier($0) } }) != after.map({ ObjectIdentifier($0) }) { textLayer.setNeedsDisplay() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        viewDidChangeBackingProperties()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        textLayer.contentsScale = window?.backingScaleFactor ?? 2
        textLayer.setNeedsDisplay()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        textLayer.setNeedsDisplay()
    }

    /// Three spaces, as the readout string joins its parts.
    private static let gap: CGFloat = CTLineGetTypographicBounds(line("   "), nil, nil, nil)
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
    private static let cache: NSCache<NSString, CTLine> = {
        let c = NSCache<NSString, CTLine>()
        c.countLimit = 4096
        return c
    }()
    private static var labels: [String: NSAttributedString] = [:]

    /// One readout part ("$x$ 1.20 µm") as a line, cached: positions repeat as the pointer
    /// moves back and forth. Only the label ("$x$") is typeset as math, once; the number
    /// after it is plain text.
    private static func line(_ part: String) -> CTLine {
        let key = part as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let text: NSAttributedString
        if part.hasPrefix("$"), let close = part.dropFirst().firstIndex(of: "$"), part[part.index(after: close)...].hasPrefix(" "),
           !part[part.index(after: close)...].contains("$") {
            let label = String(part[...close])
            let math = labels[label] ?? MathTypesetter.attributed(label, font: font, color: .secondaryLabelColor)
            labels[label] = math
            let joined = NSMutableAttributedString(attributedString: math)
            joined.append(NSAttributedString(string: String(part[part.index(after: close)...]),
                                             attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
            text = joined
        } else {
            text = MathTypesetter.attributed(part, font: font, color: .secondaryLabelColor)
        }
        let line = CTLineCreateWithAttributedString(text)
        cache.setObject(line, forKey: key)
        return line
    }

    private func layoutLines() -> [CTLine] {
        if let lines { return lines }
        guard let readout else { return [] }
        for positionOnly in [false, true] {
            let parts = StatusBar.readoutParts(readout, positionOnly: positionOnly).map(Self.line)
            let width = parts.reduce(0) { $0 + CTLineGetTypographicBounds($1, nil, nil, nil) } + Self.gap * CGFloat(max(0, parts.count - 1))
            if width <= bounds.width {
                lines = parts
                return parts
            }
        }
        lines = []
        return []
    }

    nonisolated func draw(_ layer: CALayer, in ctx: CGContext) {
        MainActor.assumeIsolated {
            PerfProbe.count("hover.readoutDraw")
            let parts = layoutLines()
            guard !parts.isEmpty else { return }
            var widths: [CGFloat] = []
            var ascent: CGFloat = 0, descent: CGFloat = 0
            for p in parts {
                var a: CGFloat = 0, d: CGFloat = 0
                widths.append(CTLineGetTypographicBounds(p, &a, &d, nil))
                ascent = max(ascent, a)
                descent = max(descent, d)
            }
            let size = layer.bounds.size
            var x = size.width - widths.reduce(0, +) - Self.gap * CGFloat(parts.count - 1)
            // Distance of the baseline from the top, as the view drew it.
            let baseline = (size.height + ascent - descent) / 2
            ctx.saveGState()
            // Core Text draws y-up; a layer's context is y-up unless its contents are flipped.
            if layer.contentsAreFlipped() {
                ctx.translateBy(x: 0, y: size.height)
                ctx.scaleBy(x: 1, y: -1)
            }
            ctx.textMatrix = .identity
            ctx.setAllowsFontSmoothing(true)
            ctx.setShouldSmoothFonts(true)
            // The dynamic colour resolves for this view's appearance.
            effectiveAppearance.performAsCurrentDrawingAppearance {
                for (p, w) in zip(parts, widths) {
                    ctx.textPosition = CGPoint(x: x, y: size.height - baseline)
                    CTLineDraw(p, ctx)
                    x += w + Self.gap
                }
            }
            ctx.restoreGState()
        }
    }
}

/// The state of the shown image: a dot and a word (never the colour alone), then solver,
/// resolution, unknowns, time and memory; while solving, the progress instead.
private struct SolveSummary: View {
    enum Detail { case full, short, state }

    let model: AppState
    /// How much to say: everything; state, solver and resolution; the state alone.
    let detail: Detail

    var body: some View {
        let _ = PerfProbe.body("SolveSummary")
        let solver = model.solver
        HStack(spacing: 6) {
            if solver.isRunning {
                ProgressView(value: min(1, max(0, solver.progress.fraction)))
                    .progressViewStyle(.linear)
                    .controlSize(.mini)
                    .frame(width: 56)
                    .accessibilityLabel("Solve progress")
                Text(solver.progressDescription)
                    .lineLimit(1)
                    .help("The solve in progress; Cancel (⌘.) stops it")
            } else if model.puzzles.isChecking, model.isInPuzzle {
                ProgressView(value: min(1, max(0, model.puzzles.checkProgress.fraction)))
                    .progressViewStyle(.linear)
                    .controlSize(.mini)
                    .frame(width: 56)
                    .accessibilityLabel("Check progress")
                Text("Checking every case…")
                    .lineLimit(1)
            } else if model.isInPuzzle, model.showsCheckedCase {
                // The canvas shows a case put together from the Check's fields.
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text("Checked")
                    .lineLimit(1)
                    .help("The field of the last Check")
                if let puzzle = model.activePuzzle, !puzzle.inputs.isEmpty, detail != .state {
                    segment("Case \(puzzle.caseLabel(model.puzzleInputBits))" + (detail == .full ? " · combined from checked fields" : ""),
                            help: "The shown case is combined from the fields the Check solved, with no new solve")
                }
            } else if model.showsDarkCase {
                // Every input off: a normal case of a logic puzzle, not a failed preview.
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text("No light in this case")
                    .lineLimit(1)
                    .help("Every input is off, so there is nothing to solve; a Check scores this case too")
            } else {
                Circle()
                    .fill(dotColor(solver.status))
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(solver.status.title)
                    .foregroundStyle(statusStyle(solver.status))
                    .lineLimit(1)
                    .help(statusHelp(solver.status))
            }
            if detail != .state, let shown = solver.shown, !model.showsDarkCase {
                let info = shown.info
                let meta = info.meta
                segment(info.method.title, help: "Solver of the shown image")
                segment("\(Format.number(meta.ppw, digits: 0...1))/" + #"$\lambda$"#, help: "Resolution: grid points per wavelength in the medium")
                if detail == .full, meta.unknowns > 0 {
                    segment("\(SceneFormat.count(meta.unknowns)) \(info.method.unknownsNoun)", help: "Unknowns: cells, DOFs or MoM unknowns")
                }
                if detail == .full, !statusSaysTime {
                    segment(SceneFormat.seconds(meta.wallS), help: "Wall time of the solve")
                }
                if detail == .full, let memory = solver.shownMemoryMb {
                    segment((memory.estimated ? "≈ " : "") + Self.megabytes(memory.value),
                            help: memory.estimated ? "Estimated peak memory of the solve" : "Peak memory of the solve")
                }
            }
        }
        .lineLimit(1)
    }

    /// "Final · 1.5 s" already says the wall time.
    private var statusSaysTime: Bool {
        if !model.solver.isRunning, case .final = model.solver.status { return true }
        return false
    }

    private func segment(_ text: String, help: String) -> some View {
        HStack(spacing: 6) {
            Text("·").accessibilityHidden(true)
            MathText(text)
                .help(help)
        }
    }

    /// "410 MB", "1.2 GB".
    static func megabytes(_ mb: Double) -> String {
        mb >= 1000 ? "\(Format.number(mb / 1000, digits: 1...1)) GB" : "\(Format.number(mb, digits: 0...0)) MB"
    }

    private func dotColor(_ status: SolveStatus) -> Color {
        switch status {
        case .final: return .green
        // The label colour, so the dot reads on the light bar as well as the dark one.
        case .preview: return Color.primary.opacity(0.8)
        case .outOfDate, .notConverged, .updating: return Color(red: 1, green: 0.75, blue: 0.2)
        case .error: return .red
        case .none: return .secondary
        }
    }

    private func statusStyle(_ status: SolveStatus) -> AnyShapeStyle {
        switch status {
        case .error: return AnyShapeStyle(.red)
        case .outOfDate, .notConverged: return AnyShapeStyle(.orange)
        default: return AnyShapeStyle(.primary)
        }
    }

    private func statusHelp(_ status: SolveStatus) -> String {
        switch status {
        case .none: return "Nothing has been solved yet"
        case .preview: return "A quick preview of the current scene; Run Final (⌘R) for the accurate image"
        case .final: return "The final solve of the current scene"
        case .updating: return "The image shows the scene before your last edits; a new preview is on its way"
        case .outOfDate: return "The image shows the scene before your last edits"
        case .error: return "The scene cannot be solved as it is; the inspector says why"
        case .notConverged: return "The solver stopped before it converged; the image may be inaccurate"
        }
    }
}
