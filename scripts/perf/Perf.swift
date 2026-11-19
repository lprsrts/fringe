// Headless profiler: builds the real window (FringeWindow + AppState) in an NSWindow that is
// never ordered front, shown, activated or sent input, drives one scenario through the
// model's own API for a fixed time, and reports CPU (getrusage, and the main thread alone),
// frames, renders, solves, the PerfProbe counters, memory over time, and pass/fail against
// the budgets of the viewport design (§2).
//
// The display cycle is emulated: a display link on the main screen (or a timer) calls
// `window.displayIfNeeded()` each frame, as AppKit's display cycle does for a visible window.
// The canvas's own display link does not tick in a window that is never shown, so playback
// frames are driven through `ViewportView.tickForTesting(at:)` at the same rate; whether a
// frame is drawn is still decided by the view (visibility, quantity, frame cap).
//
// usage: fringe-perf OUT_DIR SCENARIO [SECONDS]      (see `scenarios` below)
//        fringe-perf OUT_DIR parity                  (GPU vs CPU colouring, §12)

import AppKit
import Darwin
import SwiftUI

// MARK: - Scenarios

struct Scenario {
    var name: String
    var summary: String
    var size = CGSize(width: 1440, height: 900)
    /// The CPU renderer instead of the GPU viewport.
    var cpu = false
    /// The window counts as visible (the offscreen window is never really on screen).
    var visible = true
    /// The app counts as active (the harness never is).
    var active = true
    /// No window at all: the harness's own cost.
    var noWindow = false
    /// Run the emulated display cycle. Off for idle: an idle app's window has nothing to
    /// display, and AppKit runs no display cycle for it.
    var drives = true
    /// Brings the model to the state to measure; runs before the clock starts.
    var setup: @MainActor (AppState) async throws -> Void = { _ in }
    /// Called every display frame while measuring: `t` seconds since the start.
    var tick: (@MainActor (AppState, NSWindow, ViewportView?, Double) -> Void)? = nil
    /// Called once when measuring ends.
    var teardown: @MainActor (AppState) -> Void = { _ in }
    var plays = false
    /// Playback at this rate instead of the motion-derived one (comparisons at 60 fps).
    var forcedRate: Float?
    /// Budget checks; see `checks(for:)`.
    var kind: Kind = .idle
    /// A different window content, for the resize floor diagnostics (`diagRoot`).
    var root: String?

    enum Kind { case null, idle, play, playInactive, playHidden, playOcclusion, drag, pan, resize, resizeFixed, hover, puzzle, colours, other }
}

@MainActor func playing(_ example: String, size: CGSize, tag: String, cpu: Bool = false, rate: Float? = nil) -> Scenario {
    Scenario(name: "play-\(example)-\(tag)\(cpu ? "-cpu" : "")\(rate.map { "-\(Int($0))fps" } ?? "")",
             summary: "Phase animation playing, \(example), window \(Int(size.width))x\(Int(size.height)) pt\(cpu ? ", CPU renderer (--viewport cpu)" : "")\(rate.map { ", forced to \(Int($0)) fps" } ?? "")",
             size: size, cpu: cpu, setup: { m in
        try open(example, in: m)
        await settle(m)
        m.togglePlaying()
    }, teardown: { m in if m.display.isPlaying { m.togglePlaying() } }, plays: true, forcedRate: rate, kind: .play)
}

nonisolated(unsafe) var dragState: (id: String, x: Double, y: Double)?
nonisolated(unsafe) var panStart: RectUm?
nonisolated(unsafe) var puzzleTick = -1
nonisolated(unsafe) var resizeEdits = (during: 0, after: 0)

@MainActor let scenarios: [Scenario] = [
    Scenario(name: "harness-null", summary: "The harness's display cycle with no window: its own cost, subtracted from the others", noWindow: true, kind: .null),
    Scenario(name: "idle", summary: "Default scene, solved, not playing (no emulated display cycle)", drives: false, setup: { m in await settle(m) }),
    Scenario(name: "idle-driven", summary: "Default scene, solved, not playing, with the harness's display cycle running (compare with harness-null)", setup: { m in await settle(m) }),
    Scenario(name: "idle-window", summary: "Default scene with the Window aspect, solved, not playing (no emulated display cycle)", drives: false, setup: { m in
        m.setAspect(.window)
        await settle(m)
    }),
    playing("lens", size: CGSize(width: 1920, height: 1080), tag: "1920"),
    playing("lens", size: CGSize(width: 1440, height: 900), tag: "1440"),
    playing("talbot", size: CGSize(width: 1920, height: 1080), tag: "1920"),
    playing("talbot", size: CGSize(width: 1440, height: 900), tag: "1440"),
    playing("lens", size: CGSize(width: 1440, height: 900), tag: "1440", cpu: true),
    playing("lens", size: CGSize(width: 1440, height: 900), tag: "1440", rate: 60),
    playing("lens", size: CGSize(width: 1920, height: 1080), tag: "1920", rate: 60),
    Scenario(name: "play-inactive", summary: "Phase animation playing, lens, 1440x900 pt, visible but the app not active (30 fps)", active: false, setup: { m in
        try open("lens", in: m)
        await settle(m)
        m.togglePlaying()
    }, teardown: { m in if m.display.isPlaying { m.togglePlaying() } }, plays: true, kind: .playInactive),
    Scenario(name: "play-hidden", summary: "Phase animation playing, lens, 1440x900 pt, in a window that is not visible (occluded / never shown)", visible: false, setup: { m in
        try open("lens", in: m)
        await settle(m)
        m.togglePlaying()
    }, teardown: { m in if m.display.isPlaying { m.togglePlaying() } }, plays: true, kind: .playHidden),
    Scenario(name: "play-occlusion", summary: "Phase animation playing, lens, 1440x900 pt, in a shown window that every 2 s is covered, minimised, hidden with the app (⌘H), on a display that sleeps, in a session that is switched away from, and shown again in between (the notifications posted as AppKit and NSWorkspace would)", setup: { m in
        try open("lens", in: m)
        await settle(m)
        m.togglePlaying()
    }, tick: { _, w, v, t in
        guard let w = w as? OffscreenKeyWindow, let v else { return }
        let frames = PerfProbe.snapshot()["viewport.frame"]?.count ?? 0
        let phase = Int(t / 2) % 10
        if occlusionResumeTicks >= 0 {
            occlusionResumeTicks += 1
            if frames > occlusionFrameMark { occlusionTicksToResume.append(occlusionResumeTicks); occlusionResumeTicks = -1 }
        }
        if phase != occlusionPhase {
            if occlusionPhase >= 0 { occlusionFrames.append(frames - occlusionFrameMark) }
            let previous = occlusionPhase
            occlusionPhase = phase
            occlusionFrameMark = frames
            let center = NotificationCenter.default
            let workspace = NSWorkspace.shared.notificationCenter
            // Undo the previous hidden phase.
            switch previous {
            case 1:
                w.occludedForTesting = false
                center.post(name: NSWindow.didChangeOcclusionStateNotification, object: w)
            case 3:
                w.miniaturizedForTesting = false
                center.post(name: NSWindow.didDeminiaturizeNotification, object: w)
            case 5:
                appHiddenForTesting = false
                center.post(name: NSApplication.didUnhideNotification, object: NSApp)
            case 7:
                workspace.post(name: NSWorkspace.screensDidWakeNotification, object: NSWorkspace.shared)
            case 9:
                workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: NSWorkspace.shared)
            default:
                break
            }
            if previous >= 0, previous % 2 == 1 { occlusionResumeTicks = 0 }
            switch phase {
            case 1:
                w.occludedForTesting = true
                center.post(name: NSWindow.didChangeOcclusionStateNotification, object: w)
            case 3:
                w.miniaturizedForTesting = true
                center.post(name: NSWindow.didMiniaturizeNotification, object: w)
            case 5:
                appHiddenForTesting = true
                center.post(name: NSApplication.didHideNotification, object: NSApp)
            case 7:
                workspace.post(name: NSWorkspace.screensDidSleepNotification, object: NSWorkspace.shared)
            case 9:
                workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: NSWorkspace.shared)
            default:
                break
            }
        }
        // The notification alone must have stopped the display link.
        if phase % 2 == 1, v.hasDisplayLink { occlusionLinkWhileHidden += 1 }
    }, teardown: { m in if m.display.isPlaying { m.togglePlaying() } }, plays: true, kind: .playOcclusion),
    Scenario(name: "drag", summary: "Dragging the default scene's first element in a circle every frame (beginTracking/trackLive/flushLiveEdit/endTracking), with the element selected so its inspector is up", setup: { m in
        await settle(m)
        guard let e = m.scene.elements.first else { throw PerfError("no element") }
        m.selection = .element(e.id)
        dragState = (e.id, e.xUm, e.yUm)
        m.beginTracking()
    }, tick: { m, _, _, t in
        guard let d = dragState else { return }
        let r = 0.15 * m.scene.domain.width
        m.trackLive(.element(id: d.id, xUm: d.x + r * (cos(t * 1.5) - 1), yUm: d.y + r * sin(t * 1.5) * 0.6))
    }, teardown: { m in
        m.flushLiveEdit()
        m.endTracking("Move Element")
    }, kind: .drag),
    Scenario(name: "drag-noinspector", summary: "Diagnostic: the drag with the inspector's live fields not following it", setup: { m in
        AppState.liveInspectorInterval = .seconds(1000)
        await settle(m)
        guard let e = m.scene.elements.first else { throw PerfError("no element") }
        m.selection = .element(e.id)
        dragState = (e.id, e.xUm, e.yUm)
        m.beginTracking()
        m.trackLive(.element(id: e.id, xUm: e.xUm, yUm: e.yUm))
    }, tick: { m, _, _, t in
        guard let d = dragState else { return }
        let r = 0.15 * m.scene.domain.width
        m.trackLive(.element(id: d.id, xUm: d.x + r * (cos(t * 1.5) - 1), yUm: d.y + r * sin(t * 1.5) * 0.6))
    }, teardown: { m in
        m.flushLiveEdit()
        m.endTracking("Move Element")
    }, kind: .drag),
    Scenario(name: "drag-nosolve", summary: "Diagnostic: the drag with no preview solves (the solver never sees the dragged scene)", setup: { m in
        AppState.liveSolveInterval = .seconds(1000)
        await settle(m)
        guard let e = m.scene.elements.first else { throw PerfError("no element") }
        m.selection = .element(e.id)
        dragState = (e.id, e.xUm, e.yUm)
        m.beginTracking()
        m.trackLive(.element(id: e.id, xUm: e.xUm, yUm: e.yUm))
    }, tick: { m, _, _, t in
        guard let d = dragState else { return }
        let r = 0.15 * m.scene.domain.width
        m.trackLive(.element(id: d.id, xUm: d.x + r * (cos(t * 1.5) - 1), yUm: d.y + r * sin(t * 1.5) * 0.6))
    }, teardown: { m in
        m.flushLiveEdit()
        m.endTracking("Move Element")
    }, kind: .drag),
    Scenario(name: "pan", summary: "Panning the default scene in a circle every frame (viewOverride), committed at the end", setup: { m in
        await settle(m)
        panStart = m.scene.domain.rect
        m.beginTracking()
    }, tick: { m, _, _, t in
        guard let s = panStart else { return }
        let r = 0.1 * s.width
        let dx = r * (cos(t) - 1), dy = r * sin(t)
        m.viewOverride = RectUm(xMin: s.xMin + dx, xMax: s.xMax + dx, yMin: s.yMin + dy, yMax: s.yMax + dy)
    }, teardown: { m in m.commitViewOverride("Pan") }, kind: .pan),
    Scenario(name: "pinch", summary: "Zooming the default scene in and out every frame (viewOverride), committed at the end", setup: { m in
        await settle(m)
        panStart = m.scene.domain.rect
        m.beginTracking()
    }, tick: { m, _, _, t in
        guard let s = panStart else { return }
        m.viewOverride = m.zoomed(s, by: 1 + 0.4 * sin(t * 1.3), about: (s.centerX, s.centerY))
    }, teardown: { m in m.commitViewOverride("Zoom") }, kind: .pan),
    Scenario(name: "resize-window", summary: "Window aspect, window width swept 1100-1700 pt and height 700-1000 pt every frame, inside a live resize, which then ends", setup: { m in
        m.setAspect(.window)
        await settle(m)
        resizeEdits = (0, 0)
        m.isLiveResizing = true
    }, tick: resizeSweep, teardown: { m in m.isLiveResizing = false }, kind: .resize),
    Scenario(name: "resize-programmatic", summary: "Window aspect, the same sweep with no live resize (programmatic frame changes; the domain follows 300 ms after the last)", setup: { m in
        m.setAspect(.window)
        await settle(m)
    }, tick: resizeSweep, kind: .resize),
    Scenario(name: "resize-fixed-aspect", summary: "16:9 output, the same window sweep inside a live resize", setup: { m in
        await settle(m)
        m.isLiveResizing = true
    }, tick: resizeSweep, teardown: { m in m.isLiveResizing = false }, kind: .resizeFixed),
    Scenario(name: "hover", summary: "Pointer readout: a pointer move every frame along a Lissajous path over the image, through the canvas's tracking-area entry point", setup: { m in
        await settle(m)
    }, tick: { m, _, v, t in
        let r = m.geometry.imageRect
        let p = CGPoint(x: r.midX + 0.45 * r.width * sin(t * 1.3), y: r.midY + 0.45 * r.height * sin(t * 1.7))
        if let v { v.pointerMoved(to: p) } else { m.updateHover(at: p) }
    }, teardown: { m in m.updateHover(at: nil) }, kind: .hover),
    Scenario(name: "puzzle", summary: "logic-xor with the reference design, checked, switching the inputs every 2 s", setup: { m in
        m.setMode(.puzzles, puzzle: "logic-xor")
        guard let puzzle = m.puzzles.session?.puzzle else { throw PerfError("logic-xor did not open") }
        m.edit("Add Reference") { $0.scene.elements = puzzle.compose(design: puzzle.reference).elements }
        await settle(m)
        m.checkPuzzle()
        _ = await wait(180) { !m.puzzles.isChecking }
        await settle(m)
        print("  checked: \(m.puzzles.session?.evaluation != nil)")
    }, tick: { m, _, _, t in
        let step = Int(t / 2)
        guard step != puzzleTick, let puzzle = m.activePuzzle, !puzzle.inputs.isEmpty else { return }
        puzzleTick = step
        let n = puzzle.inputs.count
        let bits = (0..<n).map { (step + 1) >> $0 & 1 == 1 }
        m.setPuzzleInputs(bits)
    }, kind: .puzzle),
    Scenario(name: "diag-extension", summary: "Diagnostic: the layers SwiftUI adds for the canvas's background extension effect, Window aspect against 16:9", drives: false, setup: { m in
        @MainActor func report(_ label: String) async {
            try? await Task.sleep(for: .seconds(1))
            guard let root = NSApp.windows.first(where: { $0.title == "Fringe" })?.contentView?.superview?.layer else { print("  no window layer"); return }
            var counts: [String: Int] = [:]
            func walk(_ l: CALayer) {
                let name = String(describing: type(of: l))
                if name.contains("Portal") || name.contains("Replicator") || name.contains("Extension") || name.contains("Mirror") || (l.filters?.isEmpty == false) {
                    counts[name + ((l.filters?.isEmpty == false) ? " (filters: \(l.filters!.map { ($0 as AnyObject).value(forKey: "name") as? String ?? "?" }.joined(separator: ",")))" : ""), default: 0] += 1
                }
                (l.sublayers ?? []).forEach(walk)
            }
            walk(root)
            print("  \(label): " + counts.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: "; "))
        }
        await settle(m)
        m.setAspect(.window)
        await settle(m)
        await report("Window aspect")
        m.setAspect(.r16x9)
        await settle(m)
        await report("16:9")
    }, kind: .other),
    // Floors for the live-resize cost: the same sweep in windows that hold less than Fringe's.
    Scenario(name: "resize-floor-empty", summary: "Diagnostic: the resize sweep in a window holding only an empty SwiftUI view (NSWindow and WindowServer floor)",
             setup: { m in await settle(m); m.isLiveResizing = true }, tick: resizeSweep, teardown: { m in m.isLiveResizing = false }, kind: .other, root: "empty"),
    Scenario(name: "resize-floor-stub", summary: "Diagnostic: the resize sweep in a plain SwiftUI window of the same shape: split view, 8-row list, toolbar of 8 buttons, 20-row grouped form in an inspector",
             setup: { m in await settle(m); m.isLiveResizing = true }, tick: resizeSweep, teardown: { m in m.isLiveResizing = false }, kind: .other, root: "stub"),
    Scenario(name: "resize-floor-nocanvas", summary: "Diagnostic: the resize sweep in Fringe's window with the canvas and status bar replaced by an empty view (sidebar, toolbar, inspector as in the app)",
             setup: { m in await settle(m); m.isLiveResizing = true }, tick: resizeSweep, teardown: { m in m.isLiveResizing = false }, kind: .other, root: "nocanvas"),
    Scenario(name: "resize-floor-notoolbar", summary: "Diagnostic: the resize sweep in Fringe's window without its toolbar",
             setup: { m in m.setAspect(.window); await settle(m); m.isLiveResizing = true }, tick: resizeSweep, teardown: { m in m.isLiveResizing = false }, kind: .other, root: "notoolbar"),
    Scenario(name: "resize-floor-noinspector", summary: "Diagnostic: the resize sweep in Fringe's window without its inspector",
             setup: { m in m.setAspect(.window); await settle(m); m.isLiveResizing = true }, tick: resizeSweep, teardown: { m in m.isLiveResizing = false }, kind: .other, root: "noinspector"),
    Scenario(name: "diag-minsize", summary: "Diagnostic: the minimum and ideal sizes of the window's columns' content, as AppKit's minimum-size query sees them", drives: false, setup: { m in
        await settle(m)
        func report(_ label: String, _ view: some View) {
            let c = NSHostingController(rootView: view.environment(m))
            let zero = c.sizeThatFits(in: .zero)
            let ideal = c.view.fittingSize
            print("  \(label): size for a zero proposal \(Int(zero.width))x\(Int(zero.height)), fitting \(Int(ideal.width))x\(Int(ideal.height))")
        }
        report("detail (canvas + status bar)", VStack(spacing: 0) { CanvasView(); StatusBar(model: m) })
        report("status bar", StatusBar(model: m))
        report("canvas", CanvasView())
        report("sidebar", SidebarView())
        report("inspector", InspectorView())
    }, kind: .other),
    Scenario(name: "colours", summary: "The selection's colours: the window's appearance switched to light and back, then the system colours (accent) changing, a second apart; each must redraw the overlay layers", setup: { m in
        await settle(m)
        if let e = m.scene.elements.first { m.selection = .element(e.id) }
    }, tick: { _, w, _, t in
        let step = Int(t)
        guard step != colourStep, (1...3).contains(step) else { return }
        colourStep = step
        let c = PerfProbe.snapshot()
        let draws = (c["viewport.sceneDraw"]?.count ?? 0) + (c["viewport.chromeDraw"]?.count ?? 0)
        colourDraws.append(draws)
        switch step {
        case 1: w.appearance = NSAppearance(named: .aqua)
        case 2: w.appearance = NSAppearance(named: .darkAqua)
        default: NotificationCenter.default.post(name: NSColor.systemColorsDidChangeNotification, object: nil)
        }
    }, kind: .colours),
    Scenario(name: "idle-long", summary: "Default scene, solved, not playing, 5 minutes (no emulated display cycle)", drives: false, setup: { m in await settle(m) }),
    Scenario(name: "play-lens-long", summary: "Phase animation playing, lens, 1440x900 pt, 5 minutes", setup: { m in
        try open("lens", in: m)
        await settle(m)
        m.togglePlaying()
    }, teardown: { m in if m.display.isPlaying { m.togglePlaying() } }, plays: true, kind: .play),
]

// MARK: - Helpers

/// The live-resize sweep: width 1100-1700 pt, height 700-1000 pt, a step every display tick.
@MainActor func resizeSweep(_ m: AppState, _ w: NSWindow, _ v: ViewportView?, _ t: Double) {
    let width = 1400 + 300 * sin(t * 2 * .pi / 4)
    let height = 850 + 150 * sin(t * 2 * .pi / 5.3)
    let size = CGSize(width: width.rounded(), height: height.rounded())
    if w.contentRect(forFrameRect: w.frame).size != size { PerfProbe.count("harness.resizeStep") }
    w.setContentSize(size)
}

/// Window contents for the resize floor diagnostics.
@MainActor func diagRoot(_ name: String, _ m: AppState) -> AnyView {
    let frame = { (v: AnyView) in AnyView(v.frame(minWidth: 1000, idealWidth: 1440, maxWidth: .infinity, minHeight: 620, idealHeight: 860, maxHeight: .infinity)) }
    switch name {
    case "empty":
        return frame(AnyView(Color.clear))
    case "stub":
        return frame(AnyView(StubWindow()))
    default:
        return frame(AnyView(DiagWindow(variant: name).environment(m)))
    }
}

/// A plain SwiftUI window of Fringe's shape, with nothing of Fringe in it.
struct StubWindow: View {
    @UIState private var inspector = true
    var body: some View {
        NavigationSplitView {
            List(0..<8, id: \.self) { i in Label("Row \(i)", systemImage: "circle") }
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            Color.black
                .toolbar {
                    ForEach(0..<8, id: \.self) { i in
                        ToolbarItem { Button("B\(i)", systemImage: "star") {} }
                    }
                }
                .inspector(isPresented: $inspector) {
                    Form {
                        Section("Section") {
                            ForEach(0..<20, id: \.self) { i in LabeledContent("Field \(i)", value: "\(i).0 µm") }
                        }
                    }
                    .formStyle(.grouped)
                    .frame(minWidth: 300, idealWidth: 320, maxWidth: 400, minHeight: 0, maxHeight: .infinity)
                    .inspectorColumnWidth(min: 300, ideal: 320, max: 400)
                }
        }
    }
}

/// Fringe's window with one part left out.
struct DiagWindow: View {
    let variant: String
    @Environment(AppState.self) private var model
    @UIState private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columns) {
            HeldHeight(model: model) { SidebarView() }
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            detail
                .modifier(OptionalToolbar(model: model, shows: variant != "notoolbar"))
                .modifier(OptionalInspector(model: model, shows: variant != "noinspector"))
        }
        .toolbar(removing: .title)
        .toolbarRole(.editor)
    }

    @ViewBuilder private var detail: some View {
        if variant == "nocanvas" {
            Color.black
        } else {
            VStack(spacing: 0) {
                CanvasView()
                StatusBar(model: model)
            }
            .frame(minWidth: 120, maxWidth: .infinity, minHeight: 24, maxHeight: .infinity)
        }
    }
}

struct OptionalToolbar: ViewModifier {
    let model: AppState
    let shows: Bool
    func body(content: Content) -> some View {
        if shows { content.toolbar(id: "main") { MainToolbar(model: model) } } else { content }
    }
}

struct OptionalInspector: ViewModifier {
    let model: AppState
    let shows: Bool
    func body(content: Content) -> some View {
        @Bindable var model = model
        if shows {
            content.inspector(isPresented: $model.isInspectorPresented) {
                HeldHeight(model: model) { InspectorView() }
                    .frame(minWidth: 300, idealWidth: 320, maxWidth: 400, minHeight: 0, maxHeight: .infinity)
                    .inspectorColumnWidth(min: 300, ideal: 320, max: 400)
            }
        } else {
            content
        }
    }
}

struct PerfError: Error, CustomStringConvertible {
    var description: String
    init(_ d: String) { description = d }
}

@MainActor func open(_ example: String, in m: AppState) throws {
    guard let info = m.examples.first(where: { $0.name == example }) else { throw PerfError("no example \(example)") }
    m.loadExample(info)
}

@MainActor func wait(_ seconds: Double, until done: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while !done() {
        if Date() > end { return false }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return true
}

/// Waits until the preview is solved and on the canvas.
@MainActor func settle(_ m: AppState) async {
    _ = await wait(180) { !m.solver.isRunning && m.solver.shown != nil && !m.solver.isShownStale }
    _ = await wait(30) { m.isViewportCurrent }
    try? await Task.sleep(for: .milliseconds(1500))
}

/// Draws as the active, visible window without ever being ordered front: SwiftUI and AppKit
/// skip drawing for a window they think is hidden, which the real app's window is not.
final class OffscreenKeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var isVisible: Bool { true }
    /// For the occlusion scenario: what AppKit would report for a covered or minimised window.
    var occludedForTesting = false
    var miniaturizedForTesting = false
    override var occlusionState: NSWindow.OcclusionState { occludedForTesting ? [] : .visible }
    override var isMiniaturized: Bool { miniaturizedForTesting }
}

/// The occlusion scenario's phases: visible, covered, visible, minimised, visible, every 2 s,
/// with the frames and display-link state seen in each.
nonisolated(unsafe) var occlusionPhase = -1
nonisolated(unsafe) var occlusionFrames: [Int] = []
nonisolated(unsafe) var occlusionLinkWhileHidden = 0
nonisolated(unsafe) var occlusionFrameMark = 0
nonisolated(unsafe) var occlusionTicksToResume: [Int] = []
nonisolated(unsafe) var occlusionResumeTicks = -1
nonisolated(unsafe) var appHiddenForTesting = false
nonisolated(unsafe) var colourStep = 0
nonisolated(unsafe) var colourDraws: [Int] = []

/// System (kernel) CPU seconds of the process: Metal's command submission and drawable
/// handling largely run there.
func systemSeconds() -> Double {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
}

func cpuSeconds() -> Double {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
}

nonisolated(unsafe) var mainThreadPort: thread_act_t = 0

func mainThreadCPUSeconds() -> Double {
    var info = thread_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(mainThreadPort, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
    }
    guard kr == KERN_SUCCESS else { return 0 }
    return Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1e6
        + Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1e6
}

func memoryMB() -> (rss: Double, footprint: Double) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    guard kr == KERN_SUCCESS else { return (0, 0) }
    return (Double(info.resident_size) / 1_048_576, Double(info.phys_footprint) / 1_048_576)
}

func threadCount() -> Int {
    var list: thread_act_array_t?
    var count: mach_msg_type_number_t = 0
    guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return 0 }
    for i in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[i]) }
    vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(count) * MemoryLayout<thread_act_t>.stride))
    return Int(count)
}

/// Drives the emulated display cycle: the main screen's display link, or, while that does
/// not tick (no screen, or the display asleep), a 120 Hz timer in its place.
@MainActor final class Ticker: NSObject {
    var onFrame: (CFTimeInterval) -> Void = { _ in }
    private var link: CADisplayLink?
    private var timer: Timer?
    private var lastLinkFrame: CFTimeInterval = 0
    private(set) var source = ""
    private(set) var linkFrames = 0
    private(set) var timerFrames = 0

    func start() {
        if let screen = NSScreen.main {
            let link = screen.displayLink(target: self, selector: #selector(frame(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
            source = "CADisplayLink on \(screen.localizedName) (max \(screen.maximumFramesPerSecond) Hz), 120 Hz timer while it does not tick"
        } else {
            source = "120 Hz timer (no screen)"
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = CACurrentMediaTime()
                if now - self.lastLinkFrame > 0.1 {
                    self.timerFrames += 1
                    self.onFrame(now)
                }
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    @objc func frame(_ link: CADisplayLink) {
        lastLinkFrame = CACurrentMediaTime()
        linkFrames += 1
        onFrame(link.targetTimestamp)
    }

    func stop() {
        link?.invalidate()
        timer?.invalidate()
    }
}

/// For the CPU renderer only: what a visible window would draw that an offscreen one never
/// does with SwiftUI's prepared image (a premultiplied copy of each new image). The GPU
/// viewport's overlay layers draw for real (counted as viewport.sceneDraw/chromeDraw).
@MainActor final class DrawEmulator {
    private var lastImage: ObjectIdentifier?
    private var imageContext: CGContext?

    func frame(_ model: AppState) {
        if let image = model.renderer.rendered?.image, ObjectIdentifier(image) != lastImage {
            lastImage = ObjectIdentifier(image)
            if imageContext?.width != image.width || imageContext?.height != image.height {
                imageContext = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            }
            if let ctx = imageContext {
                PerfProbe.time("emu.image_upload") { ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height)) }
            }
        }
    }
}

func findViews(_ root: NSView, where test: (NSView) -> Bool) -> [NSView] {
    (test(root) ? [root] : []) + root.subviews.flatMap { findViews($0, where: test) }
}

/// Animation keys on any layer of the window, for the idle check: a stuck spinner would
/// keep WindowServer compositing at the display rate.
func animatedLayers(_ layer: CALayer) -> [String] {
    let own = (layer.animationKeys() ?? []).map { "\(type(of: layer)):\($0)" }
    return own + (layer.sublayers ?? []).flatMap(animatedLayers)
}

// MARK: - Run

struct Sample: Codable {
    var t: Double
    var cpuPct: Double
    var mainPct: Double
    var rssMB: Double
    var footprintMB: Double
    var threads: Int
    var frames: Int
    var viewportFrames: Int
}

struct Check {
    var name: String
    var value: Double
    var limit: Double
    var pass: Bool { value <= limit }
}

@MainActor func run(_ scenario: Scenario, seconds: Double, out: String) async throws {
    PerfProbe.enabled = true
    ViewportMode.override = scenario.cpu ? .cpu : .gpu
    ViewportView.assumeActiveForTesting = scenario.active
    ViewportView.isAppHidden = { appHiddenForTesting }
    ViewportView.forcedRate = scenario.forcedRate
    let launchCPU0 = cpuSeconds()
    let launchWall0 = Date()
    var model: AppState?
    var window: NSWindow?
    var host: NSView?
    if !scenario.noWindow {
        let m = AppState()
        model = m
        let h = NSHostingView(rootView: scenario.root.map { diagRoot($0, m) } ?? AnyView(FringeWindow().environment(m)))
        h.sceneBridgingOptions = [.toolbars, .title]
        let windowClass: NSWindow.Type = scenario.visible ? OffscreenKeyWindow.self : NSWindow.self
        let w = windowClass.init(
            contentRect: NSRect(origin: .zero, size: scenario.size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        w.isReleasedWhenClosed = false
        w.toolbarStyle = .unified
        w.title = "Fringe"
        w.contentView = h
        w.setContentSize(scenario.size)
        window = w
        host = h
    }
    // Never ordered front.
    let ticker = Ticker()
    var frames = 0
    var measuring = false
    var containerSizes: [CGSize] = []
    var splitFrames: [String] = []
    var t0: CFTimeInterval = 0
    var viewport: ViewportView?
    // Wall time between display ticks while measuring: a main-thread stall shows as a long one.
    // With the time of the tick (since the measurement began), so the ticks during `sample`'s
    // run, which suspends the process about a thousand times a second, can be left out.
    var tickIntervals: [Double] = []
    var tickTimes: [Double] = []
    var lastTickWall: CFTimeInterval = 0
    let emulator = DrawEmulator()
    ticker.onFrame = { ts in
        frames += 1
        guard let model, let window else { return }
        if measuring {
            let now = CACurrentMediaTime()
            if lastTickWall > 0 { tickIntervals.append(now - lastTickWall); tickTimes.append(now - t0) }
            lastTickWall = now
            if containerSizes.last != model.containerSize {
                containerSizes.append(model.containerSize)
                // Which column moved: the frames of the split view's items.
                if let host, containerSizes.count > 1 {
                    let splits = findViews(host) { $0 is NSSplitView }.compactMap { $0 as? NSSplitView }
                    let desc = splits.map { s in s.arrangedSubviews.map { "\(Int($0.frame.minX))+\(Int($0.frame.width))" }.joined(separator: "|") }.joined(separator: " / ")
                    splitFrames.append("\(Int(model.containerSize.width))x\(Int(model.containerSize.height)): \(desc)")
                }
            }
            scenario.tick?(model, window, viewport, ts - t0)
            // Both the GPU viewport and the CPU fallback play through the canvas's own
            // display link, which decides whether and at what rate to draw.
            if scenario.plays { viewport?.tickForTesting(at: ts) }
        }
        // As AppKit's display cycle: only when something in the window needs it (the
        // baseline harness called this every tick, which cost about 1 % of a core idle).
        if window.viewsNeedDisplay || (window.contentView?.superview?.needsLayout ?? false) || (window.contentView?.needsLayout ?? false) {
            PerfProbe.count("harness.display")
            window.displayIfNeeded()
        }
        if model.viewportUsesCPU { emulator.frame(model) }
    }
    ticker.start()

    if let model {
        _ = await wait(10) { model.containerSize.width > 0 }
        viewport = host.flatMap { findViews($0) { $0 is ViewportView }.first as? ViewportView }
        print("  viewport: \(model.viewportUsesCPU ? "CPU renderer" : "GPU (Metal)"), view found \(viewport != nil)")
        try await scenario.setup(model)
        // Let what the setup changed land (a quantity switch on play, for one).
        try? await Task.sleep(for: .seconds(1))
    } else {
        try? await Task.sleep(for: .seconds(2))
    }
    let launchCPU = cpuSeconds() - launchCPU0
    let launchWall = Date().timeIntervalSince(launchWall0)
    if scenario.kind == .resize { resizeEdits = (0, 0) }

    if !scenario.drives { ticker.stop() }
    // Measure.
    let c0 = PerfProbe.snapshot()
    let cpu0 = cpuSeconds()
    let sys0 = systemSeconds()
    let main0 = mainThreadCPUSeconds()
    let wall0 = Date()
    let frames0 = frames
    t0 = CACurrentMediaTime()
    measuring = true
    var samples: [Sample] = []
    var lastCPU = cpu0, lastMain = main0, lastWall = wall0, lastFrames = frames
    var lastVP = c0["viewport.frame"]?.count ?? 0
    let mem0 = memoryMB()
    samples.append(Sample(t: 0, cpuPct: 0, mainPct: 0, rssMB: mem0.rss, footprintMB: mem0.footprint, threads: threadCount(), frames: 0, viewportFrames: 0))
    var sampler: Process?
    var sampleWindow: (start: Double, end: Double)?
    let samples10s = ProcessInfo.processInfo.environment["FRINGE_PERF_NOSAMPLE"] == nil
    let samplePath = "\(out)/\(scenario.name).sample.txt"
    var maxAnimated: [String] = []
    while Date().timeIntervalSince(wall0) < seconds {
        try? await Task.sleep(for: .seconds(1))
        let now = Date(), cpu = cpuSeconds(), main = mainThreadCPUSeconds(), mem = memoryMB()
        let dt = now.timeIntervalSince(lastWall)
        let vp = PerfProbe.snapshot()["viewport.frame"]?.count ?? 0
        samples.append(Sample(t: now.timeIntervalSince(wall0), cpuPct: 100 * (cpu - lastCPU) / dt, mainPct: 100 * (main - lastMain) / dt,
                              rssMB: mem.rss, footprintMB: mem.footprint, threads: threadCount(),
                              frames: frames - lastFrames, viewportFrames: vp - lastVP))
        lastCPU = cpu; lastMain = main; lastWall = now; lastFrames = frames; lastVP = vp
        if let root = window?.contentView?.superview?.layer {
            let animated = animatedLayers(root)
            if animated.count > maxAnimated.count { maxAnimated = animated }
        }
        if let sampler, !sampler.isRunning, let w = sampleWindow, w.end == .infinity {
            sampleWindow = (w.start, CACurrentMediaTime() - t0)
        }
        if sampler == nil, samples10s, now.timeIntervalSince(wall0) >= 20 {
            sampleWindow = (CACurrentMediaTime() - t0, .infinity)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            p.arguments = ["\(getpid())", "10", "1", "-mayDie", "-file", samplePath]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            sampler = p
        }
    }
    measuring = false
    let wall = Date().timeIntervalSince(wall0)
    let cpu = cpuSeconds() - cpu0
    let sysCPU = systemSeconds() - sys0
    let mainCPU = mainThreadCPUSeconds() - main0
    let c1 = PerfProbe.snapshot()
    let docDuring = (c1["doc.changed"]?.count ?? 0) - (c0["doc.changed"]?.count ?? 0)
    let solvesDuring = c1.filter { $0.key.hasPrefix("solve.start.") }.map(\.value.count).reduce(0, +) - c0.filter { $0.key.hasPrefix("solve.start.") }.map(\.value.count).reduce(0, +)
    if let model { scenario.teardown(model) }
    // What follows the end of a gesture or resize: at most one edit and one preview.
    var docAfter = 0, solvesAfter = 0
    if scenario.kind == .resize || scenario.kind == .resizeFixed || scenario.kind == .drag || scenario.kind == .pan, let model {
        let a0 = c1
        try? await Task.sleep(for: .seconds(1.5))
        _ = await wait(60) { !model.solver.isRunning }
        let a1 = PerfProbe.snapshot()
        docAfter = (a1["doc.changed"]?.count ?? 0) - (a0["doc.changed"]?.count ?? 0)
        for k in a1.keys.sorted() where k.hasPrefix("solve.") || k.hasPrefix("doc.") || k.hasPrefix("canvas.") {
            let n = (a1[k]?.count ?? 0) - (a0[k]?.count ?? 0)
            if n != 0 { print("  after: \(k) \(n)") }
        }
        solvesAfter = a1.filter { $0.key.hasPrefix("solve.start.") }.map(\.value.count).reduce(0, +) - a0.filter { $0.key.hasPrefix("solve.start.") }.map(\.value.count).reduce(0, +)
    }
    var undoSteps = -1
    if scenario.kind == .drag, let model, let undo = model.undoManager {
        undoSteps = undo.canUndo ? 1 : 0
        _ = undo
    }
    ticker.stop()
    if let sampler {
        sampler.waitUntilExit()
        if let w = sampleWindow, w.end == .infinity { sampleWindow = (w.start, wall) }
    }

    // Report.
    var deltas: [(String, Int, Double)] = []
    for (k, v) in c1 {
        let b = c0[k] ?? PerfProbe.Entry()
        let n = v.count - b.count
        let ms = Double(v.nanos - b.nanos) / 1e6
        if n != 0 || ms != 0 { deltas.append((k, n, ms)) }
    }
    deltas.sort { $0.0 < $1.0 }
    func delta(_ k: String) -> Int { (c1[k]?.count ?? 0) - (c0[k]?.count ?? 0) }
    let measured = samples.dropFirst()
    let avg = 100 * cpu / wall
    let peak = measured.map(\.cpuPct).max() ?? 0
    // The harness's own cost, from a harness-null run in the same directory.
    var nullCPU = 0.0
    if let data = FileManager.default.contents(atPath: "\(out)/harness-null.json"),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let v = json["cpuAvg"] as? Double {
        nullCPU = v
    }
    // With a window, driving its display cycle costs more than with none: when idle and
    // idle-driven ran in the same directory, their difference is the driver's cost for a
    // window, which is what a driven scenario subtracts.
    func cpuOf(_ name: String) -> Double? {
        guard let data = FileManager.default.contents(atPath: "\(out)/\(name).json"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["cpuAvg"] as? Double
    }
    var harnessSource = "harness-null"
    if scenario.kind != .null, scenario.name != "idle-driven", let driven = cpuOf("idle-driven"), let quiet = cpuOf("idle") {
        nullCPU = max(nullCPU, driven - quiet)
        harnessSource = "idle-driven − idle"
    }
    if !scenario.drives { nullCPU = 0; harnessSource = "none (not driven)" }
    let net = scenario.kind == .null ? avg : max(0, avg - nullCPU)
    let vpFrames = delta("viewport.frame")
    let gpuFrames = delta("viewport.gpu_frames")
    let gpuMsPerFrame = gpuFrames > 0 ? Double(delta("viewport.gpu_ns")) / 1e6 / Double(gpuFrames) : 0
    let footprints = measured.map(\.footprintMB)
    let swing = (footprints.max() ?? 0) - (footprints.min() ?? 0)
    // Growth: the most the footprint rose above where the measurement began (a footprint
    // that shrinks is not growth).
    let growth = max(0, (footprints.max() ?? 0) - (footprints.first ?? 0))
    // The tick statistics leave out `sample`'s run (and half a second after it): it stops the
    // process for each of its samples, which shows as long ticks the app did not cause.
    let unsampled = zip(tickTimes, tickIntervals).filter { t, _ in
        guard let w = sampleWindow else { return true }
        return t < w.start || t > w.end + 0.5
    }.map(\.1)
    func stats(_ intervals: [Double]) -> (p95: Double, p99: Double, max: Double, long: Double) {
        let sorted = intervals.sorted()
        func pct(_ p: Double) -> Double { sorted.isEmpty ? 0 : 1000 * sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        let long = intervals.isEmpty ? 0 : 100 * intervals.filter { $0 > 1.0 / 60 }.reduce(0, +) / intervals.reduce(0, +)
        return (pct(0.95), pct(0.99), 1000 * (sorted.last ?? 0), long)
    }
    let allTicks = stats(tickIntervals)
    let (p95, p99, maxInterval, longShare) = stats(unsampled)
    // The viewport's own main-thread work: field draws, overlay updates and layer drawing.
    let viewportMainMs = ["viewport.fieldMain", "viewport.overlayMain", "viewport.layerDrawMain"]
        .map { Double((c1[$0]?.nanos ?? 0) - (c0[$0]?.nanos ?? 0)) / 1e6 }.reduce(0, +)
    let renders = delta("render.run")
    let overlayDraws = delta("viewport.sceneDraw") + delta("viewport.chromeDraw")
    var lines: [String] = []
    lines.append("scenario: \(scenario.name) — \(scenario.summary)")
    if let model, let window {
        lines.append("viewport: \(model.viewportUsesCPU ? "CPU renderer" : "GPU (Metal)"); display: \(ticker.source); window \(Int(window.frame.width))x\(Int(window.frame.height)) pt, backing scale \(window.backingScaleFactor), canvas \(Int(model.containerSize.width))x\(Int(model.containerSize.height)) pt")
    } else {
        lines.append("no window; display: \(ticker.source)")
    }
    lines.append("frames from display link \(ticker.linkFrames), from fallback timer \(ticker.timerFrames)")
    lines.append(String(format: "CPU split: user %.2f %%, system %.2f %%; main thread %.2f %%, other threads %.2f %%",
                        100 * (cpu - sysCPU) / wall, 100 * sysCPU / wall, 100 * mainCPU / wall, 100 * (cpu - mainCPU) / wall))
    let distinct = Set(containerSizes.map { "\(Int($0.width))x\(Int($0.height))" })
    lines.append("canvas size changes seen at frame boundaries: \(max(0, containerSizes.count - 1)), distinct sizes \(distinct.count): \(distinct.sorted().prefix(8).joined(separator: " "))")
    for f in splitFrames.prefix(6) { lines.append("  split items at \(f)") }
    lines.append(String(format: "setup (launch + solve + settle): %.1f s wall, %.1f s CPU", launchWall, launchCPU))
    lines.append("harness cost subtracted: \(harnessSource)")
    lines.append(String(format: "measured %.1f s: CPU avg %.2f %% (peak %.1f %%), net of harness (%.2f %%) %.2f %%, main thread avg %.2f %%; display ticks %.1f /s; canvas frames %.1f /s (GPU %.3f ms/frame); CPU renders %.1f /s; overlay layer draws %d; document changes %d during (+%d after); solves started %d during (+%d after)",
                        wall, avg, peak, nullCPU, net, 100 * mainCPU / wall, Double(frames - frames0) / wall, Double(vpFrames) / wall, gpuMsPerFrame,
                        Double(renders) / wall, overlayDraws, docDuring, docAfter, solvesDuring, solvesAfter))
    let mem = samples.map { String(format: "%.0f:%.0f/%.0f", $0.t, $0.rssMB, $0.footprintMB) }
    lines.append("memory t:rss/footprint MB: " + mem.enumerated().filter { $0.offset % max(1, mem.count / 12) == 0 || $0.offset == mem.count - 1 }.map(\.element).joined(separator: " ") + String(format: "  (footprint swing %.1f MB)", swing))
    lines.append("threads: \(samples.first?.threads ?? 0) -> \(samples.last?.threads ?? 0); layers with animations (max seen): \(maxAnimated.count) \(maxAnimated.prefix(4).joined(separator: ", "))")
    if scenario.plays, let viewport, vpFrames > 0 {
        lines.append(String(format: "playback: %.0f fps chosen%@; pattern motion %.1f device px/s, %.2f px per frame", viewport.rate,
                            scenario.forcedRate == nil ? " (motion-derived)" : " (forced)", viewport.motionPixelsPerSecond,
                            viewport.motionPixelsPerSecond / Double(viewport.rate)))
    }
    if scenario.drives {
        lines.append(String(format: "display tick intervals (outside sample's run): p95 %.1f ms, p99 %.1f ms, max %.1f ms; %.1f %% of the time in ticks longer than 16.7 ms; footprint growth %.1f MB",
                            p95, p99, maxInterval, longShare, growth))
        if let w = sampleWindow {
            lines.append(String(format: "  all ticks, sample's run (%.1f-%.1f s) included: p95 %.1f ms, p99 %.1f ms, max %.1f ms, %.1f %% in long ticks",
                                w.start, w.end, allTicks.p95, allTicks.p99, allTicks.max, allTicks.long))
        }
    }
    if viewportMainMs > 0 {
        var line = String(format: "viewport main-thread work %.1f ms/s (%.2f %% of a core)", viewportMainMs / wall, viewportMainMs / wall / 10)
        if containerSizes.count > 1 {
            line += String(format: "; main thread %.2f ms per canvas size change", 1000 * mainCPU / Double(containerSizes.count - 1))
        }
        lines.append(line)
    }
    if delta("harness.resizeStep") > 0 {
        lines.append(String(format: "window resize steps %.1f /s; main thread %.2f ms per step", Double(delta("harness.resizeStep")) / wall,
                            1000 * mainCPU / Double(delta("harness.resizeStep"))))
    }
    if scenario.kind == .playOcclusion {
        lines.append("occlusion phases (visible, covered, visible, minimised, visible, app hidden, visible, displays asleep, visible, session inactive, …) frames: \(occlusionFrames.map(String.init).joined(separator: " ")); display link alive while hidden: \(occlusionLinkWhileHidden) ticks; ticks to the first frame after showing again: \(occlusionTicksToResume.map(String.init).joined(separator: " "))")
    }
    if undoSteps >= 0 { lines.append("undo after the drag: \(undoSteps == 1 ? "one step" : "none") (\(model?.undoManager?.undoActionName ?? "-"))") }

    // Budgets (§2).
    var checks: [Check] = []
    let perSec = { (n: Int) in Double(n) / wall }
    switch scenario.kind {
    case .idle:
        checks = [Check(name: "CPU net of harness %", value: net, limit: 0.3),
                  Check(name: "canvas frames", value: Double(vpFrames), limit: 0),
                  Check(name: "CPU renders", value: Double(renders), limit: 0),
                  Check(name: "polls", value: Double(delta("solve.poll") + delta("puzzle.poll")), limit: 0),
                  Check(name: "body evaluations", value: Double(c1.filter { $0.key.hasPrefix("body.") }.map(\.value.count).reduce(0, +) - c0.filter { $0.key.hasPrefix("body.") }.map(\.value.count).reduce(0, +)), limit: 0),
                  Check(name: "animated layers", value: Double(maxAnimated.count), limit: 0),
                  Check(name: "footprint growth MB", value: growth, limit: 5)]
    case .play where !scenario.cpu:
        checks = [Check(name: "CPU net of harness % (budget 2, hard 5)", value: net, limit: 5),
                  Check(name: "GPU ms per frame", value: gpuMsPerFrame, limit: 1),
                  Check(name: "CPU renders", value: Double(renders), limit: 0),
                  Check(name: "overlay draws", value: Double(overlayDraws), limit: 0),
                  Check(name: "frames per second short of the chosen rate (-8 % allowed)", value: 0.92 * Double(viewport?.rate ?? 60) - perSec(vpFrames), limit: 0)]
    case .playInactive:
        checks = [Check(name: "CPU net of harness %", value: net, limit: 1.5),
                  Check(name: "frames per second (<= 31)", value: perSec(vpFrames), limit: 31),
                  Check(name: "CPU renders", value: Double(renders), limit: 0)]
    case .playHidden:
        checks = [Check(name: "canvas frames", value: Double(vpFrames), limit: 0),
                  Check(name: "CPU renders", value: Double(renders), limit: 0),
                  Check(name: "CPU net of harness %", value: net, limit: 0.3)]
    case .playOcclusion:
        let hidden = occlusionFrames.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
        let shown = occlusionFrames.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        let expected = 2 * Double(viewport?.rate ?? 30)
        checks = [Check(name: "frames while covered or minimised", value: Double(hidden.reduce(0, +)), limit: 0),
                  Check(name: "ticks with a display link while hidden", value: Double(occlusionLinkWhileHidden), limit: 0),
                  Check(name: "visible phases short of 90 % of their frames", value: Double(shown.filter { Double($0) < 0.9 * expected }.count), limit: 0),
                  Check(name: "resumptions without a frame", value: Double(hidden.count - occlusionTicksToResume.count), limit: 0),
                  Check(name: "ticks to the first frame after showing", value: Double(occlusionTicksToResume.max() ?? 99), limit: 2)]
    case .drag:
        checks = [Check(name: "main thread %", value: 100 * mainCPU / wall, limit: 35),
                  Check(name: "document changes per second", value: perSec(docDuring), limit: 10.5),
                  Check(name: "solves per second", value: perSec(solvesDuring), limit: 2),
                  Check(name: "process CPU % (solves included)", value: avg, limit: 250),
                  Check(name: "CPU renders", value: Double(renders), limit: 0),
                  Check(name: "canvas size changes", value: Double(max(0, containerSizes.count - 1)), limit: 0),
                  Check(name: "display tick interval p95 ms", value: p95, limit: 16.7),
                  // The drag's working set: the newest preview field and its parts on the GPU,
                  // the solver's buffers between previews. A 180 s drag levels off at
                  // about 40 MB above where it began.
                  Check(name: "footprint growth MB (working set, levels off)", value: growth, limit: 60)]
    case .pan:
        checks = [Check(name: "CPU net of harness %", value: net, limit: 15),
                  Check(name: "document changes", value: Double(docDuring), limit: 0),
                  Check(name: "solves", value: Double(solvesDuring), limit: 0),
                  Check(name: "CPU renders", value: Double(renders), limit: 0),
                  Check(name: "display tick interval p95 ms", value: p95, limit: 16.7)]
    case .resize, .resizeFixed:
        checks = [Check(name: "document changes during", value: Double(docDuring), limit: 0),
                  Check(name: "solves during", value: Double(solvesDuring), limit: 0),
                  Check(name: "document changes after", value: Double(docAfter), limit: scenario.kind == .resize ? 1 : 0),
                  Check(name: "solves after", value: Double(solvesAfter), limit: scenario.kind == .resize ? 1 : 0),
                  Check(name: "main thread %", value: 100 * mainCPU / wall, limit: 30),
                  Check(name: "CPU renders", value: Double(renders), limit: 0),
                  Check(name: "footprint swing MB", value: swing, limit: 30),
                  Check(name: "viewport's own main-thread %", value: viewportMainMs / wall / 10, limit: 30)]
        if scenario.name == "resize-programmatic" {
            // No live resize: the domain follows each time the size pauses for 300 ms.
            checks.removeAll { $0.name.hasPrefix("document changes during") || $0.name.hasPrefix("solves during") }
        }
    case .colours:
        // Draws between each change and the next (the last up to the end).
        let end = delta("viewport.sceneDraw") + delta("viewport.chromeDraw") + ((c0["viewport.sceneDraw"]?.count ?? 0) + (c0["viewport.chromeDraw"]?.count ?? 0))
        let marks = colourDraws + [end]
        let perChange = zip(marks, marks.dropFirst()).map { $1 - $0 }
        lines.append("overlay layer draws after: light appearance, dark appearance, accent change: \(perChange.map(String.init).joined(separator: ", "))")
        checks = [Check(name: "changes that redrew no overlay layer", value: Double(perChange.filter { $0 < 1 }.count) + Double(3 - perChange.count), limit: 0)]
    case .hover:
        checks = [Check(name: "CPU net of harness %", value: net, limit: 5),
                  Check(name: "readout updates per second (<= 31)", value: perSec(delta("hover.update")), limit: 31)]
    default:
        break
    }
    if !checks.isEmpty {
        lines.append("budgets:")
        for c in checks {
            lines.append(String(format: "  %@ %-48@ %10.3f (limit %g)", c.pass ? "PASS" : "FAIL", c.name as NSString, c.value, c.limit))
        }
    }
    lines.append("counters (count, per second, total ms, ms per second):")
    for (k, n, ms) in deltas {
        lines.append(String(format: "  %-34@ %12ld  %10.1f/s  %10.1f ms  %7.1f ms/s", k as NSString, n, Double(n) / wall, ms, ms / wall))
    }
    let text = lines.joined(separator: "\n")
    print(text)
    try text.write(toFile: "\(out)/\(scenario.name).txt", atomically: true, encoding: .utf8)
    let json: [String: Any] = [
        "name": scenario.name, "wall": wall, "cpuAvg": avg, "sysPct": 100 * sysCPU / wall, "cpuNet": net, "cpuPeak": peak, "mainAvg": 100 * mainCPU / wall,
        "ticksPerSec": Double(frames - frames0) / wall, "framesPerSec": Double(vpFrames) / wall, "gpuMsPerFrame": gpuMsPerFrame,
        "rendersPerSec": Double(renders) / wall, "overlayDraws": overlayDraws, "docDuring": docDuring, "docAfter": docAfter,
        "solvesDuring": solvesDuring, "solvesAfter": solvesAfter, "footprintSwing": swing, "animatedLayers": maxAnimated.count,
        "canvasSizeChanges": max(0, containerSizes.count - 1), "footprintGrowth": growth, "tickP95": p95, "tickP99": p99, "tickMax": maxInterval, "tickLongShare": longShare, "tickP95All": allTicks.p95,
        "viewportMainPct": viewportMainMs / wall / 10,
        "checks": checks.map { ["name": $0.name, "value": $0.value, "limit": $0.limit, "pass": $0.pass] },
        "samples": samples.map { ["t": $0.t, "cpu": $0.cpuPct, "main": $0.mainPct, "rss": $0.rssMB, "footprint": $0.footprintMB, "threads": $0.threads, "frames": $0.frames, "viewportFrames": $0.viewportFrames] },
        "counters": Dictionary(uniqueKeysWithValues: deltas.map { ($0.0, ["count": $0.1, "ms": $0.2]) }),
    ]
    try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: "\(out)/\(scenario.name).json"))
    window?.contentView = nil
    window?.close()
    if checks.contains(where: { !$0.pass }) { throw PerfError("\(checks.filter { !$0.pass }.count) budget check(s) failed") }
}

/// The harness's defaults domain: its own, never the app's.
let defaultsDomain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName

@MainActor func resetDefaults() {
    let d = UserDefaults.standard
    d.removePersistentDomain(forName: defaultsDomain)
    for key in [AppState.documentKey, AppState.previousDocumentKey, "fringe.document.v3.unreadable", "fringe.puzzles.progress.v1", AppState.modeKey] {
        d.removeObject(forKey: key)
    }
    d.synchronize()
}

/// Suspect check: whether `isPlaying` survives a save and a restore.
@MainActor func playStatePersists() -> Bool {
    var doc = FringeDocument(scene: FringeBridge.defaultScene())
    doc.display.isPlaying = true
    guard let data = try? JSONEncoder().encode(doc),
          let back = try? JSONDecoder().decode(FringeDocument.self, from: data) else { return false }
    return back.display.isPlaying
}

@main
enum Perf {
    static func main() {
        let args = Array(CommandLine.arguments.prefix { !$0.hasPrefix("-") })
        guard args.count >= 3 else {
            FileHandle.standardError.write("usage: fringe-perf OUT_DIR SCENARIO [SECONDS]\n".data(using: .utf8)!)
            exit(2)
        }
        guard defaultsDomain == "fringe-perf" else {
            FileHandle.standardError.write("refusing to run with defaults domain \(defaultsDomain)\n".data(using: .utf8)!)
            exit(2)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        mainThreadPort = mach_thread_self()
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let out = args[1]
        let seconds = args.count >= 4 ? Double(args[3]) ?? 60 : 60
        MainActor.assumeIsolated {
            AppState.readsLegacyDocument = false
            Task {
                if args[2] == "export" {
                    let ok = await ExportCheck.run(out: out)
                    exit(ok ? 0 : 1)
                }
                if args[2] == "transform" {
                    exit(TransformCheck.run() ? 0 : 1)
                }
                if args[2] == "look" {
                    exit(LookCheck.run(out: out) ? 0 : 1)
                }
                if args[2] == "parity" {
                    let ok = await Parity.run(out: out)
                    exit(ok ? 0 : 1)
                }
                guard let scenario = scenarios.first(where: { $0.name == args[2] }) else {
                    print("no scenario \(args[2]); known: parity \(scenarios.map(\.name).joined(separator: " "))")
                    exit(2)
                }
                print("isPlaying survives save/restore: \(playStatePersists())")
                resetDefaults()
                var failed = false
                do { try await run(scenario, seconds: seconds, out: out) } catch {
                    print("FAIL \(scenario.name): \(error)"); failed = true
                }
                resetDefaults()
                exit(failed ? 1 : 0)
            }
        }
        RunLoop.main.run()
    }
}
