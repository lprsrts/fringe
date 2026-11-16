import AppKit
import SwiftUI

struct CanvasView: View {
    @Environment(AppState.self) private var model
    @Environment(\.displayScale) private var displayScale
    // Gesture state resets when a gesture ends and also when it is cancelled, which
    // `onEnded` never hears about; `onChange` below closes the undo step either way.
    @GestureState private var drag: CanvasDrag?
    @GestureState private var pinch: CanvasPinch?
    @UIState private var hoverTarget: CanvasTarget?

    var body: some View {
        let geometry = model.geometry
        let rect = geometry.imageRect
        let isWindowAspect = model.output.aspect == .window

        // The image sits in an overlay so its size never feeds back into the column's layout.
        Color.clear
            .overlay(alignment: .topLeading) {
                ImageLayer(model: model, geometry: geometry, fillsWindow: isWindowAspect)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }
            .overlay(alignment: .bottom) {
                StatusBar(model: model)
                    .padding(.bottom, 6)
            }
            .background {
                Color(white: 0.11)
                    .ignoresSafeArea()
            }
            .background {
                if model.display.isPlaying {
                    PhaseClock(model: model)
                }
            }
            .contentShape(Rectangle())
            .onGeometryChange(for: CGSize.self) { $0.size } action: { model.containerSize = $0 }
            .onChange(of: displayScale, initial: true) { _, scale in model.displayScale = scale }
            .gesture(dragGesture(geometry))
            .simultaneousGesture(magnifyGesture(geometry))
            // A single tap recogniser reads the click count itself; stacking a double-tap
            // recogniser on top would hold every single click back by the double-click interval.
            .onTapGesture { location in
                guard rect.contains(location) else { return }
                let target = target(at: location, geometry)
                if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                    if target == nil { model.fitDomainToElements() }
                } else {
                    switch target {
                    case .element(let id): model.selection = .element(id)
                    case .waist, .angle: model.selection = .source
                    case nil: break
                    }
                }
            }
            .onChange(of: drag) { old, new in
                guard new == nil, let old else { return }
                switch old {
                case .element: model.endTracking("Move Element")
                case .waist: model.endTracking("Move Waist")
                case .angle: model.endTracking("Change Beam Angle")
                case .pan: model.commitViewOverride("Pan")
                case .outside: break
                }
            }
            .onChange(of: pinch) { old, new in
                if new == nil, old != nil {
                    model.commitViewOverride("Zoom")
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoverTarget = target(at: location, geometry)
                    model.updateHover(at: location)
                case .ended:
                    hoverTarget = nil
                    model.updateHover(at: nil)
                }
            }
            .pointerStyle(pointerStyle)
    }

    private var pointerStyle: PointerStyle? {
        switch drag {
        case .element, .waist, .angle, .pan:
            return .grabActive
        case .outside:
            return nil
        case nil:
            return hoverTarget == nil ? .grabIdle : .link
        }
    }

    /// What is under `point`: a beam handle first, then an element. Handles can only be hit
    /// while they are drawn.
    private func target(at point: CGPoint, _ geometry: CanvasGeometry) -> CanvasTarget? {
        guard geometry.imageRect.contains(point) else { return nil }
        let display = model.display
        let source = model.scene.source
        if display.showOverlays, display.showSourceGlyph, source.kind == .gaussianBeam {
            let handle = VectorRenderer.angleHandle(source: source, viewRect: model.viewRect)
            if distance(point, geometry.viewPoint(x: handle.x, y: handle.y)) <= 8 { return .angle }
            if distance(point, geometry.viewPoint(x: source.waistXUm, y: source.waistYUm)) <= 8 { return .waist }
        }
        guard display.showOverlays, display.showOutlines else { return nil }
        let plane = geometry.planePoint(point)
        return model.hitTestElement(x: plane.x, y: plane.y).map { .element($0) }
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private func dragGesture(_ geometry: CanvasGeometry) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .updating($drag) { value, drag, _ in
                if drag == nil {
                    drag = startDrag(at: value.startLocation, geometry)
                }
                let fine = NSEvent.modifierFlags.contains(.option) ? 0.1 : 1.0
                let delta = geometry.planeDelta(value.translation)
                switch drag {
                case .pan(let start):
                    let moved = RectUm(xMin: start.xMin - delta.dx, xMax: start.xMax - delta.dx,
                                       yMin: start.yMin - delta.dy, yMax: start.yMax - delta.dy)
                    model.viewOverride = moved
                case .element(let id, let x, let y):
                    model.document.scene[element: id]?.xUm = x + delta.dx * fine
                    model.document.scene[element: id]?.yUm = y + delta.dy * fine
                case .waist(let x, let y):
                    model.document.scene.source.waistXUm = x + delta.dx * fine
                    model.document.scene.source.waistYUm = y + delta.dy * fine
                case .angle:
                    let source = model.scene.source
                    let p = geometry.planePoint(value.location)
                    var angle = atan2(p.y - source.waistYUm, p.x - source.waistXUm) * 180 / .pi
                    if NSEvent.modifierFlags.contains(.shift) { angle = (angle / 15).rounded() * 15 }
                    model.document.scene.source.angleDeg = (angle * 10).rounded() / 10
                case .outside, nil:
                    break
                }
            }
    }

    private func startDrag(at location: CGPoint, _ geometry: CanvasGeometry) -> CanvasDrag {
        guard geometry.imageRect.contains(location) else { return .outside }
        model.beginTracking()
        switch target(at: location, geometry) {
        case .element(let id):
            model.selection = .element(id)
            let element = model.scene[element: id]
            return .element(id: id, startX: element?.xUm ?? 0, startY: element?.yUm ?? 0)
        case .waist:
            model.selection = .source
            return .waist(startX: model.scene.source.waistXUm, startY: model.scene.source.waistYUm)
        case .angle:
            model.selection = .source
            return .angle
        case nil:
            return .pan(start: model.scene.domain.rect)
        }
    }

    private func magnifyGesture(_ geometry: CanvasGeometry) -> some Gesture {
        MagnifyGesture()
            .updating($pinch) { value, pinch, _ in
                if pinch == nil {
                    let anchor = geometry.planePoint(value.startLocation)
                    pinch = CanvasPinch(start: model.viewOverride ?? model.scene.domain.rect, anchorX: anchor.x, anchorY: anchor.y)
                    model.beginTracking()
                }
                guard let pinch else { return }
                model.viewOverride = model.zoomed(pinch.start, by: Double(value.magnification), about: (pinch.anchorX, pinch.anchorY))
            }
    }
}

private enum CanvasTarget: Equatable {
    case element(String)
    case waist
    case angle
}

private enum CanvasDrag: Equatable {
    case pan(start: RectUm)
    case element(id: String, startX: Double, startY: Double)
    case waist(startX: Double, startY: Double)
    case angle
    /// Started on the letterbox around the image; does nothing.
    case outside
}

private struct CanvasPinch: Equatable {
    var start: RectUm
    var anchorX: Double
    var anchorY: Double
}

extension AppState {
    /// Ends a pan or pinch: the view becomes the domain, as one undo step.
    func commitViewOverride(_ name: String) {
        if let rect = viewOverride {
            document.scene.domain.set(rect)
            viewOverride = nil
        }
        endTracking(name)
    }
}

/// Advances the phase once per display frame while the animation plays.
private struct PhaseClock: View {
    let model: AppState

    var body: some View {
        TimelineView(.animation) { context in
            Color.clear
                .onChange(of: context.date) { old, new in
                    model.advancePhase(by: new.timeIntervalSince(old))
                }
        }
    }
}

/// The rendered field with the overlays, badges and messages drawn over it.
private struct ImageLayer: View {
    let model: AppState
    let geometry: CanvasGeometry
    let fillsWindow: Bool

    var body: some View {
        let solver = model.solver
        let report = solver.currentReport
        let isInvalid = report.map { !$0.ok } ?? false
        let origin = geometry.imageRect.origin

        ZStack(alignment: .topLeading) {
            Color.black.opacity(fillsWindow ? 0 : 0.25)
            if let rendered = model.renderer.rendered {
                let frame = geometry.viewRect(for: rendered.viewRect)
                // Only a full-bleed image may be mirrored under the sidebar and toolbar; a
                // letterboxed one would suggest a wider crop than the export has.
                Image(decorative: rendered.image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX - origin.x, y: frame.minY - origin.y)
                    .saturation(isInvalid ? 0 : 1)
                    .opacity(solver.isShownStale || isInvalid ? 0.85 : 1)
            }
            // Built here rather than in the Canvas closure, so observation sees what it reads.
            let overlay = model.overlayModel(viewRect: model.viewRect)
            Canvas { context, size in
                context.withCGContext { cg in
                    VectorRenderer.drawOverlays(in: cg, size: size, flipped: false, model: overlay, minimumTextScale: 1)
                }
            }
            .allowsHitTesting(false)
        }
        .clipped()
        .backgroundExtensionEffect(isEnabled: fillsWindow)
        .shadow(color: .black.opacity(fillsWindow ? 0 : 0.35), radius: 12, y: 4)
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
            StatusBadge(status: solver.status, isRunning: solver.isRunning)
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
            if let report, !report.ok, let issue = report.firstError {
                InvalidSceneCard(model: model, issue: issue, count: report.errors.count)
                    .padding(24)
            } else if model.renderer.rendered == nil, !solver.isRunning, solver.shown == nil {
                Text("Nothing solved yet")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct StatusBadge: View {
    let status: SolveStatus
    let isRunning: Bool

    var body: some View {
        if status != .none {
            HStack(spacing: 5) {
                if isRunning || status == .updating {
                    ProgressView().controlSize(.mini)
                }
                Text(status.title)
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
        switch status {
        case .outOfDate, .notConverged: return .black
        case .error: return .white
        default: return .white.opacity(0.92)
        }
    }

    private var background: Color {
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
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.title2)
                .foregroundStyle(.red)
            Text(issue.sentence)
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

/// The pointer readout and short notices along the bottom of the canvas.
private struct StatusBar: View {
    let model: AppState

    var body: some View {
        VStack(spacing: 6) {
            if let notice = model.notice {
                Text(notice)
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .transition(.opacity)
            }
            if let hover = model.hover {
                Text(readout(hover))
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
            }
        }
        .animation(.default, value: model.notice)
        .allowsHitTesting(false)
    }

    private func readout(_ hover: HoverReadout) -> String {
        var parts = ["x \(Format.number(hover.xUm, digits: 2...2)) µm  y \(Format.number(hover.yUm, digits: 2...2)) µm"]
        if let intensity = hover.intensity {
            parts.append("|E|² \(Format.number(intensity, digits: 2...2))")
        }
        if let phase = hover.phaseDeg {
            parts.append("∠E \(Format.degrees(phase, digits: 0))")
        }
        if let body = hover.body {
            parts.append(body)
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Fixes for common problems

enum IssueFix {
    case setCenterThickness(id: String, value: Double)
    case select(id: String)
    case fitDomain
    case makePEC(id: String)

    var title: String {
        switch self {
        case .setCenterThickness(_, let value): return "Set Center Thickness to \(Format.micrometres(value))"
        case .select: return "Select Element"
        case .fitDomain: return "Fit Domain to Elements"
        case .makePEC: return "Make It PEC"
        }
    }
}

extension AppState {
    func fix(for issue: Issue) -> IssueFix? {
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
        case .fitDomain:
            fitDomainToElements()
        case .makePEC(let id):
            edit("Change Material") { $0.scene[element: id]?.material.kind = .pec }
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
