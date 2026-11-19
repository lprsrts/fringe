import AppKit
import SwiftUI

struct CanvasView: View {
    @Environment(AppState.self) private var model
    // Gesture state resets when a gesture ends and also when it is cancelled, which
    // `onEnded` never hears about; `onChange` below closes the undo step either way.
    @GestureState private var drag: CanvasDrag?
    @GestureState private var pinch: CanvasPinch?

    // The body reads only the output shape: the image, overlays, hover, phase and drag
    // steps live in `ViewportView`, and the chrome is placed by layout, so neither a resize
    // step nor a frame re-evaluates it.
    var body: some View {
        let _ = PerfProbe.body("CanvasView")
        let aspect = model.canvasAspect

        // No background extension effect: under the Window aspect it mirrored the field
        // under the sidebar and inspector, which read as the image bleeding under the panels.
        ViewportRepresentable(model: model)
            .overlay {
                ImageRectLayout(aspect: aspect) {
                    CanvasChrome(model: model)
                }
            }
            // At the top: at the bottom it covered the image's caption, colour bar and scale bar.
            .overlay(alignment: .top) {
                NoticeOverlay(model: model)
                    .padding(.top, 10)
            }
            .background {
                Color(white: 0.11)
                    .ignoresSafeArea()
            }
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .simultaneousGesture(magnifyGesture)
            // A single tap recogniser reads the click count itself; stacking a double-tap
            // recogniser on top would hold every single click back by the double-click interval.
            .onTapGesture { location in
                guard model.geometry.imageRect.contains(location) else { return }
                let target = model.canvasTarget(at: location)
                if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                    // A puzzle's domain is part of its score: no fitting.
                    if target == nil, model.mode == .simulator { model.fitDomainToElements() }
                } else if let target {
                    model.selection = target.item.sidebarItem
                }
            }
            .onChange(of: drag) { old, new in
                guard new == nil, let old else { return }
                model.flushLiveEdit()
                switch old {
                case .element: model.endTracking("Move Element")
                case .source: model.endTracking("Move Source")
                case .sourceAngle: model.endTracking("Change Beam Angle")
                case .detector: model.endTracking("Move Detector")
                case .detectorHandle: model.endTracking("Resize Detector")
                case .pan: model.commitViewOverride("Pan")
                case .outside: break
                }
            }
            .onChange(of: pinch) { old, new in
                if new == nil, old != nil {
                    model.commitViewOverride("Zoom")
                }
            }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .updating($drag) { value, drag, _ in
                let geometry = model.geometry
                if drag == nil {
                    drag = startDrag(at: value.startLocation, geometry)
                }
                let flags = NSEvent.modifierFlags
                let fine = flags.contains(.option) ? 0.1 : 1.0
                let delta = geometry.planeDelta(value.translation)
                let dx = delta.dx * fine
                let dy = delta.dy * fine
                switch drag {
                case .pan(let start, let scale):
                    // The scale when the pan began: the plane stays under the pointer.
                    guard scale > 0 else { break }
                    let pdx = Double(value.translation.width) / scale
                    let pdy = -Double(value.translation.height) / scale
                    let moved = RectUm(xMin: start.xMin - pdx, xMax: start.xMax - pdx,
                                       yMin: start.yMin - pdy, yMax: start.yMax - pdy)
                    // A pan begun in the simulator ends there: after a switch to a puzzle
                    // (⌘2 mid-drag) the puzzle's domain must not move.
                    if model.mode == .simulator { model.viewOverride = moved }
                case .element(let id, let x, let y):
                    model.trackLive(.element(id: id, xUm: x + dx, yUm: y + dy))
                case .source(let id, let x, let y):
                    model.trackLive(.source(id: id, xUm: x + dx, yUm: y + dy))
                case .sourceAngle(let id):
                    guard let source = model.scene[source: id] else { break }
                    let p = geometry.planePoint(value.location)
                    var angle = atan2(p.y - source.yUm, p.x - source.xUm) * 180 / .pi
                    if flags.contains(.shift) { angle = (angle / 15).rounded() * 15 }
                    model.trackLive(.sourceAngle(id: id, angleDeg: (angle * 10).rounded() / 10))
                case .detector(let start):
                    model.trackLive(.detector(start.moved(by: dx, dy)))
                case .detectorHandle(let start, let handle):
                    model.trackLive(.detector(Self.reshaped(start, handle: handle, dx: dx, dy: dy, snap: flags.contains(.shift))))
                case .outside, nil:
                    break
                }
            }
    }

    /// `detector` with one handle moved by (dx, dy): a line's end (with `snap`, the segment
    /// turned to the nearest 15° about its other end), or a box's corner with the opposite
    /// corner fixed.
    static func reshaped(_ detector: Detector, handle: DetectorHandle, dx: Double, dy: Double, snap: Bool) -> Detector {
        var copy = detector
        switch (detector.shape, handle) {
        case (.line(var g), .start), (.line(var g), .end):
            let isStart = handle == .start
            var x = (isStart ? g.x1Um : g.x2Um) + dx
            var y = (isStart ? g.y1Um : g.y2Um) + dy
            let ox = isStart ? g.x2Um : g.x1Um
            let oy = isStart ? g.y2Um : g.y1Um
            if snap {
                let length = hypot(x - ox, y - oy)
                let angle = (atan2(y - oy, x - ox) * 180 / .pi / 15).rounded() * 15 * .pi / 180
                x = ox + length * cos(angle)
                y = oy + length * sin(angle)
            }
            if isStart { g.x1Um = x; g.y1Um = y } else { g.x2Um = x; g.y2Um = y }
            copy.shape = .line(g)
        case (.box, .corner(let i)):
            let corners = detector.points
            guard corners.indices.contains(i) else { return detector }
            let opposite = corners[(i + 2) % 4]
            let x = corners[i].x + dx
            let y = corners[i].y + dy
            // Never thinner than a hundredth of a micrometre, so it never flips through zero.
            let width = max(0.01, abs(x - opposite.x))
            let height = max(0.01, abs(y - opposite.y))
            let cx = opposite.x + (x >= opposite.x ? width : -width) / 2
            let cy = opposite.y + (y >= opposite.y ? height : -height) / 2
            copy.shape = .box(BoxGeometry(xUm: cx, yUm: cy, widthUm: width, heightUm: height))
        default:
            break
        }
        return copy
    }

    private func startDrag(at location: CGPoint, _ geometry: CanvasGeometry) -> CanvasDrag {
        guard geometry.imageRect.contains(location) else { return .outside }
        let scene = model.scene
        let hit = model.canvasTarget(at: location)
        let pan = CanvasDrag.pan(start: scene.domain.rect, scale: Double(geometry.scale))
        if model.isInPuzzle {
            // Only the player's own elements move; a drag on anything else selects it, and
            // the empty canvas does not pan (the domain is part of the score).
            guard let hit, model.isPlayerItem(hit.item) else {
                if let hit { model.selection = hit.item.sidebarItem }
                return .outside
            }
        } else if model.mode != .simulator {
            return .outside
        }
        model.beginTracking()
        switch hit {
        case .element(let id):
            model.selection = .element(id)
            let element = scene[element: id]
            return .element(id: id, startX: element?.xUm ?? 0, startY: element?.yUm ?? 0)
        case .source(let id):
            model.selection = .source(id)
            let source = scene[source: id]
            return .source(id: id, startX: source?.xUm ?? 0, startY: source?.yUm ?? 0)
        case .sourceAngle(let id):
            model.selection = .source(id)
            return .sourceAngle(id: id)
        case .detector(let id):
            model.selection = .detector(id)
            guard let detector = scene[detector: id] else { return pan }
            return .detector(start: detector)
        case .detectorHandle(let id, let handle):
            guard let detector = scene[detector: id] else { return pan }
            return .detectorHandle(start: detector, handle: handle)
        case nil:
            return pan
        }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .updating($pinch) { value, pinch, _ in
                // A puzzle's view is its domain: no zoom.
                guard model.mode == .simulator else { return }
                if pinch == nil {
                    let anchor = model.geometry.planePoint(value.startLocation)
                    pinch = CanvasPinch(start: model.viewOverride ?? model.scene.domain.rect, anchorX: anchor.x, anchorY: anchor.y)
                    model.beginTracking()
                }
                guard let pinch else { return }
                model.viewOverride = model.zoomed(pinch.start, by: Double(value.magnification), about: (pinch.anchorX, pinch.anchorY))
            }
    }
}

/// A handle of the selected detector: a line's ends, or a box's corners (counter-clockwise
/// from the lower left, as `Detector.points`).
enum DetectorHandle: Equatable {
    case start
    case end
    case corner(Int)
}

enum CanvasTarget: Equatable {
    case element(String)
    case source(String)
    /// A Gaussian beam's angle handle.
    case sourceAngle(String)
    case detector(String)
    case detectorHandle(String, DetectorHandle)

    var item: SceneItem {
        switch self {
        case .element(let id): return .element(id)
        case .source(let id), .sourceAngle(let id): return .source(id)
        case .detector(let id), .detectorHandle(let id, _): return .detector(id)
        }
    }
}

private enum CanvasDrag: Equatable {
    /// The domain when the pan began and the points per micrometre then.
    case pan(start: RectUm, scale: Double)
    case element(id: String, startX: Double, startY: Double)
    case source(id: String, startX: Double, startY: Double)
    case sourceAngle(id: String)
    case detector(start: Detector)
    case detectorHandle(start: Detector, handle: DetectorHandle)
    /// Started on the letterbox around the image; does nothing.
    case outside
}

private struct CanvasPinch: Equatable {
    var start: RectUm
    var anchorX: Double
    var anchorY: Double
}

extension AppState {
    /// What is under `point`, in this order: the selected detector's handles, beam angle
    /// handles, emitters and beam waists, enabled detectors, elements, then disabled
    /// detectors. Only what is drawn can be hit.
    func canvasTarget(at point: CGPoint) -> CanvasTarget? {
        let geometry = self.geometry
        guard geometry.imageRect.contains(point) else { return nil }
        let display = self.display
        guard display.showOverlays else { return nil }
        // A puzzle's sources and detectors have no handles.
        let handles = !isInPuzzle
        if handles, display.showDetectors, let detector = selectedDetector {
            for (i, p) in VectorRenderer.detectorHandles(detector).enumerated()
            where distance(point, geometry.viewPoint(x: p.x, y: p.y)) <= 7 {
                switch detector.shape {
                case .line: return .detectorHandle(detector.id, i == 0 ? .start : .end)
                case .box: return .detectorHandle(detector.id, .corner(i))
                }
            }
        }
        let plane = geometry.planePoint(point)
        if display.showSourceGlyph {
            for source in scene.sources.reversed() where handles && source.kind == .gaussianBeam {
                let handle = VectorRenderer.angleHandle(source: source, viewRect: viewRect)
                if distance(point, geometry.viewPoint(x: handle.x, y: handle.y)) <= 8 { return .sourceAngle(source.id) }
            }
            if let id = hitTestSource(x: plane.x, y: plane.y) { return .source(id) }
        }
        if display.showDetectors, let id = hitTestDetector(x: plane.x, y: plane.y, enabled: true) {
            return .detector(id)
        }
        // A disabled detector (drawn dashed) can still be picked, but never over an element.
        if display.showOutlines, let id = hitTestElement(x: plane.x, y: plane.y) { return .element(id) }
        if display.showDetectors, let id = hitTestDetector(x: plane.x, y: plane.y, enabled: false) {
            return .detector(id)
        }
        return nil
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    /// Ends a pan or pinch: the view becomes the domain, as one undo step.
    func commitViewOverride(_ name: String) {
        if let rect = viewOverride {
            // Only the simulator's domain follows the view; a puzzle's is part of its score.
            if mode == .simulator { document.scene.domain.set(rect) }
            viewOverride = nil
        }
        endTracking(name)
    }
}

/// Places its content over the image rect of a canvas of the proposed size (rounded to
/// whole points, as the canvas reports its size to the model).
private struct ImageRectLayout: Layout {
    let aspect: OutputAspect

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let container = CGSize(width: bounds.width.rounded(), height: bounds.height.rounded())
        let rect = CanvasGeometry(container: container, aspect: aspect, viewRect: RectUm(xMin: 0, xMax: 1, yMin: 0, yMax: 1)).imageRect
        for view in subviews {
            view.place(at: CGPoint(x: bounds.minX + rect.minX, y: bounds.minY + rect.minY), anchor: .topLeading,
                       proposal: ProposedViewSize(rect.size))
        }
    }
}

/// What SwiftUI draws over the image: the progress bar, the status badge, the failure
/// banner and the invalid-scene card. The image and the vector overlays are layers of
/// `ViewportView` underneath.
private struct CanvasChrome: View {
    let model: AppState

    var body: some View {
        let _ = PerfProbe.body("CanvasChrome")
        let solver = model.solver
        // A checked case with every input off has no source, which is fine: it shows the
        // combined (dark) field the Check scored.
        let isDark = model.showsDarkCase
        let report = model.showsCheckedCase || isDark ? nil : solver.currentReport

        Color.clear
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Field image")
            .accessibilityValue(model.caption.map(MathTypesetter.plain) ?? solver.status.title)
            .accessibilityAddTraits(.isImage)
            .allowsHitTesting(false)
            .overlay(alignment: .top) {
                if solver.isRunning {
                    ProgressView(value: min(1, max(0, solver.progress.fraction)))
                        .progressViewStyle(.linear)
                        .controlSize(.mini)
                        .tint(.accentColor)
                        .padding(.horizontal, 2)
                }
            }
            .overlay(alignment: .topTrailing) {
                // A checked case and a case with no light are normal states, whatever the
                // scene check says about a scene with every source off.
                StatusBadge(status: solver.status, isRunning: solver.isRunning,
                            neutralTitle: model.showsCheckedCase ? "Checked" : isDark ? "No Light" : nil)
                    .padding(10)
            }
            .overlay(alignment: .top) {
                if let failure = solver.currentFailure {
                    FailureBanner(model: model, failure: failure)
                        .padding(.top, 36)
                        .padding(.horizontal, 16)
                }
            }
            .overlay {
                if isDark, let puzzle = model.activePuzzle {
                    DarkCaseNote(model: model, puzzle: puzzle)
                        .padding(24)
                } else if let report, !report.ok, let issue = report.firstError {
                    InvalidSceneCard(model: model, issue: issue, count: report.errors.count)
                        .padding(24)
                } else if solver.shown == nil, !solver.isRunning {
                    Text("Nothing solved yet")
                        .foregroundStyle(.secondary)
                }
            }
    }
}

private struct StatusBadge: View {
    let status: SolveStatus
    let isRunning: Bool
    /// A normal state the status does not describe ("Checked", "No Light"), drawn neutral.
    var neutralTitle: String? = nil

    var body: some View {
        let _ = PerfProbe.body("StatusBadge")
        if status != .none || neutralTitle != nil {
            HStack(spacing: 5) {
                if isRunning || (neutralTitle == nil && status == .updating) {
                    ProgressView().controlSize(.mini)
                }
                Text(neutralTitle ?? status.title)
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(foreground)
            .background(background, in: Capsule())
        }
    }

    private var foreground: Color {
        if neutralTitle != nil { return .white.opacity(0.92) }
        switch status {
        case .outOfDate, .notConverged: return .black
        case .error: return .white
        default: return .white.opacity(0.92)
        }
    }

    private var background: Color {
        if neutralTitle != nil { return Color.black.opacity(0.55) }
        switch status {
        case .outOfDate, .notConverged: return Color(red: 1, green: 0.75, blue: 0.2).opacity(0.92)
        case .error: return Color.red.opacity(0.85)
        case .final: return Color(red: 0.15, green: 0.45, blue: 0.3).opacity(0.85)
        default: return Color.black.opacity(0.55)
        }
    }
}

private struct FailureBanner: View {
    let model: AppState
    let failure: SolveFailure

    var body: some View {
        let _ = PerfProbe.body("FailureBanner")
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("The \(failure.quality.rawValue) solve failed")
                    .font(.callout.weight(.semibold))
                Text(failure.message.capitalizedFirst)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Spacer(minLength: 8)
            Button("Copy Details") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(failure.details, forType: .string)
            }
            Button("Dismiss", systemImage: "xmark") { model.solver.dismissFailure() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .padding(10)
        .frame(maxWidth: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct InvalidSceneCard: View {
    let model: AppState
    let issue: Issue
    let count: Int

    var body: some View {
        let _ = PerfProbe.body("InvalidSceneCard")
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.title2)
                .foregroundStyle(.red)
            MathText(model.puzzleSentence(for: issue) ?? issue.mathSentence)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if count > 1 {
                Text("\(count - 1) more \(count == 2 ? "problem" : "problems") in the inspector.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let fix = model.fix(for: issue) {
                Button(fix.title) { model.apply(fix) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(maxWidth: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// A logic puzzle's case with every input off: a plain note on the dark canvas, not a
/// failure, with a way to turn an input on.
private struct DarkCaseNote: View {
    let model: AppState
    let puzzle: Puzzle

    var body: some View {
        let _ = PerfProbe.body("DarkCaseNote")
        VStack(spacing: 10) {
            Image(systemName: "lightbulb.slash")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Every input is off in this case, so there is no light. A Check scores this case too.")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Turn On Input \(puzzle.inputLetters[0])") { model.setPuzzleInput(0, on: true) }
                .help("Show a case with light (⌃⌥1)")
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(18)
        .frame(maxWidth: 380)
        // An opaque dark plate: the overlays' lines must not run through the text.
        .background(Color(white: 0.14).opacity(0.96), in: RoundedRectangle(cornerRadius: 14))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
    }
}

/// Short notices ("Final solve cancelled by edit") floating at the top of the canvas.
/// The pointer readout lives in the status bar.
private struct NoticeOverlay: View {
    let model: AppState

    var body: some View {
        let _ = PerfProbe.body("NoticeOverlay")
        VStack {
            if let notice = model.notice {
                Text(notice)
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .transition(.opacity)
            }
        }
        .animation(.default, value: model.notice)
        .allowsHitTesting(false)
    }
}

// MARK: - Fixes for common problems

enum IssueFix {
    case setCenterThickness(id: String, value: Double)
    case select(id: String)
    case selectItem(SceneItem)
    case enableSource(id: String, name: String)
    case turnOnInput(index: Int, letter: String)
    case fitDomain
    case makePEC(id: String)

    var title: String {
        switch self {
        case .setCenterThickness(_, let value): return "Set Center Thickness to \(Format.micrometres(value))"
        case .select: return "Select Element"
        case .selectItem(let item): return "Select \(item.noun)"
        case .enableSource(_, let name): return "Enable \(name)"
        case .turnOnInput(_, let letter): return "Turn On Input \(letter)"
        case .fitDomain: return "Fit Domain to Elements"
        case .makePEC: return "Make It PEC"
        }
    }
}

extension AppState {
    /// The puzzle's own wording for an issue a player meets by switching inputs.
    func puzzleSentence(for issue: Issue) -> String? {
        guard issue.code == "no_enabled_source", let puzzle = activePuzzle, !puzzle.inputs.isEmpty else { return nil }
        return "Every input is off in this case, so there is no light to show. A Check scores this case too."
    }

    func fix(for issue: Issue) -> IssueFix? {
        if issue.code == "no_enabled_source", let puzzle = activePuzzle, !puzzle.inputs.isEmpty {
            // The sources are the puzzle's; only an input may be switched.
            return .turnOnInput(index: 0, letter: puzzle.inputLetters[0])
        }
        if issue.code == "no_enabled_source", let first = scene.sources.first {
            return .enableSource(id: first.id, name: first.displayName)
        }
        if let index = issue.index(in: "sources"), scene.sources.indices.contains(index) {
            let source = scene.sources[index]
            switch issue.code {
            case "outside_domain": return .fitDomain
            default: return .selectItem(.source(source.id))
            }
        }
        if let index = issue.index(in: "detectors"), scene.detectors.indices.contains(index) {
            let detector = scene.detectors[index]
            switch issue.code {
            case "outside_domain": return .fitDomain
            default: return .selectItem(.detector(detector.id))
            }
        }
        guard let index = issue.elementIndex, scene.elements.indices.contains(index) else {
            return issue.code == "domain_size" ? .fitDomain : nil
        }
        let element = scene.elements[index]
        switch issue.code {
        case "lens_thickness":
            guard case .lens(let lens) = element.shape else { return nil }
            return .setCenterThickness(id: element.id, value: Self.minimumCenterThickness(lens, lambdaB: scene.lambdaB))
        case "overlap":
            return .select(id: element.id)
        case "outside_domain":
            return .fitDomain
        case "pec_required":
            return .makePEC(id: element.id)
        default:
            return .select(id: element.id)
        }
    }

    func apply(_ fix: IssueFix) {
        switch fix {
        case .setCenterThickness(let id, let value):
            edit("Change Center Thickness") { $0.scene[element: id]?.shape.lens.centerThicknessUm = value }
            selection = .element(id)
        case .select(let id):
            selection = .element(id)
            isInspectorPresented = true
        case .selectItem(let item):
            selection = item.sidebarItem
            isInspectorPresented = true
        case .enableSource(let id, _):
            edit("Enable Source") { $0.scene[source: id]?.enabled = true }
            selection = .source(id)
        case .turnOnInput(let index, _):
            setPuzzleInput(index, on: true)
        case .fitDomain:
            fitDomainToElements()
        case .makePEC(let id):
            edit("Change Material") { doc in
                guard var m = doc.scene[element: id]?.material else { return }
                m.kind = .pec
                doc.scene[element: id]?.setMaterial(m)
            }
        }
    }

    /// The smallest centre thickness that keeps the lens at least 0.05 λ_b thick everywhere,
    /// rounded up to 0.01 µm.
    static func minimumCenterThickness(_ lens: Lens, lambdaB: Double) -> Double {
        func sag(_ r: Double?, _ y: Double) -> Double {
            guard let r else { return 0 }
            return r - (r < 0 ? -1 : 1) * max(0, r * r - y * y).squareRoot()
        }
        let half = lens.apertureUm / 2
        var minExtra = Double.infinity
        for i in 0...128 {
            let y = -half + lens.apertureUm * Double(i) / 128
            minExtra = min(minExtra, sag(lens.r2Um, y) - sag(lens.r1Um, y))
        }
        let needed = 0.05 * lambdaB - minExtra
        return (max(needed, 0.05 * lambdaB) * 100 + 1).rounded(.up) / 100
    }
}
