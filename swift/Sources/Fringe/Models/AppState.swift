import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import os

public enum SidebarItem: Hashable, Sendable {
    case source
    case element(String)
    case simulation
    case display
    case output
}

/// What the pointer is over in the canvas, for the status bar.
public struct HoverReadout: Equatable {
    public var xUm: Double
    public var yUm: Double
    /// |E|² / A² of the shown part, nil outside the solved grid.
    public var intensity: Double?
    /// arg(E e^{jφ}) in degrees.
    public var phaseDeg: Double?
    /// "Lens (n 1.50)".
    public var body: String?
}

@MainActor
@Observable
public final class AppState {
    /// Every edit goes through here.
    public var document: FringeDocument {
        didSet { documentChanged(from: oldValue) }
    }

    public var selection: SidebarItem = .source
    public var isInspectorPresented = true

    // Export and file panels.
    public var isExporterPresented = false {
        // Snapshot the frame when the panel opens, so playback neither changes what gets
        // written nor re-evaluates the window every frame while the panel is up.
        didSet {
            if isExporterPresented, !oldValue {
                presentedExport = pngExport
            } else if !isExporterPresented {
                presentedExport = nil
            }
        }
    }
    /// What the open export panel writes.
    public private(set) var presentedExport: PNGExport?
    public var isExportChoicePresented = false
    public var isSceneImporterPresented = false
    public var isSceneExporterPresented = false
    public var isExporting = false
    public var lastExportURL: URL?
    public var exportErrorMessage: String?
    public var openErrorMessage: String?
    public var animationFrameCount = 24

    /// A short notice at the bottom of the canvas ("Final solve cancelled by edit").
    public private(set) var notice: String?

    /// Size of the canvas area in points.
    public var containerSize: CGSize = .zero {
        didSet {
            guard containerSize != oldValue else { return }
            if document.output.aspect == .window { enforceShapeLock() }
            scheduleRender()
        }
    }
    public var displayScale: CGFloat = 2 {
        didSet { if displayScale != oldValue { scheduleRender() } }
    }
    /// Drags, slider scrubs and canvas gestures in progress. Pinch and drag can overlap,
    /// so this is a count; while it is above zero the preview renders at half resolution.
    public private(set) var trackingDepth = 0 {
        didSet { if (trackingDepth > 0) != (oldValue > 0) { scheduleRender() } }
    }
    /// The plane rectangle shown while a pan or pinch is in progress; committed to the
    /// domain when the gesture ends.
    public var viewOverride: RectUm? {
        didSet { if viewOverride != oldValue { scheduleRender() } }
    }
    public var hover: HoverReadout?
    /// The animated phase while playback runs. Kept out of the document so a frame tick
    /// redraws the field without touching every view that reads the document; written back
    /// when playback stops.
    public private(set) var playbackPhase: Double?

    public let solver = SolveController()
    public let renderer = RenderController()
    /// Body outlines and source placement for the current scene.
    public private(set) var outlines: SceneOutlines?
    /// Body outlines of the scene the shown field was solved for. Conductors are filled
    /// from these, so the grey sits on the field's zero region even when the image is out
    /// of date and the current outlines have moved on.
    public private(set) var shownOutlines: SceneOutlines?
    @ObservationIgnored private weak var shownOutlinesField: FieldHandle?
    @ObservationIgnored private weak var shownFocusField: FieldHandle?
    @ObservationIgnored private var shownFocusPoints: [[Double]] = []
    public let examples: [ExampleInfo] = FringeBridge.examples()

    @ObservationIgnored public var undoManager: UndoManager?
    /// The document as it was when the first of the current drags or gestures began.
    @ObservationIgnored private var trackingSnapshot: FringeDocument?
    @ObservationIgnored private var lastEdit: (name: String, key: AnyHashable, time: Date)?
    @ObservationIgnored private var persistTask: Task<Void, Never>?
    /// False after a launch with overrides until the user changes something, so a
    /// scripted run never replaces the saved document.
    @ObservationIgnored private var persistsDocument = true
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var exportAfterFinal = false
    @ObservationIgnored private var lutCache: (name: String, wavelength: Double, lut: [UInt8])?

    private static let maxPreviewEdge: CGFloat = 4096
    static let log = Logger(subsystem: "com.asympton.fringe", category: "app")

    /// UserDefaults key of the saved document.
    public static let documentKey = "fringe.document.v2"

    public init() {
        var document = Self.restoredDocument() ?? FringeDocument(scene: FringeBridge.defaultScene())
        let launch = LaunchOptions.read(examples: examples)
        launch.apply(to: &document)
        self.document = document
        persistsDocument = !launch.hasOverrides
        if let selection = launch.selection(in: document.scene) {
            self.selection = selection
        }

        solver.onResult = { [weak self] in self?.solveResultChanged() }
        solver.onNotice = { [weak self] message in self?.showNotice(message) }
        outlines = FringeBridge.outlines(document.scene)
        enforceShapeLock()
        solver.update(scene: self.document.scene, tracking: false)
        if launch.runFinal {
            solver.runFinal()
        } else {
            solver.previewNow()
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.persistsDocument else { return }
                self.saveNow()
            }
        }
    }

    // MARK: Convenience

    public var scene: SimScene { document.scene }
    public var display: DisplaySettings { document.display }
    public var output: OutputFormat { document.output }

    public var selectedElementID: String? {
        if case .element(let id) = selection, scene[element: id] != nil { return id }
        return nil
    }

    public var selectedElement: Element? {
        selectedElementID.flatMap { scene[element: $0] }
    }

    /// Aspect of the canvas area, used when the output follows the window.
    public var windowAspect: Double {
        guard containerSize.width > 0, containerSize.height > 0 else { return 16.0 / 9.0 }
        return Double(containerSize.width / containerSize.height)
    }

    /// Width over height of the image; the domain has the same shape. The exact ratio, not
    /// the rounded pixel size, so a 16:9 domain stays exactly 16:9.
    public var imageAspect: Double {
        output.aspect.ratio ?? windowAspect
    }

    public var outputSummary: String {
        output.summary(windowAspect: windowAspect)
    }

    public var outputPixelSize: (width: Int, height: Int) {
        output.pixelSize(windowAspect: windowAspect)
    }

    /// PML thickness in µm.
    public var pmlUm: Double { scene.domain.pmlWl * scene.lambdaB }

    /// The interior the image shows: the domain, or the pan or pinch in progress.
    public var interiorRect: RectUm { viewOverride ?? scene.domain.rect }

    /// The plane rectangle the image covers: the interior, or the interior and PML when the
    /// PML is shown.
    public var viewRect: RectUm {
        let interior = interiorRect
        guard display.showPML else { return interior }
        return interior.insetBy(-pmlUm).grown(toAspect: imageAspect)
    }

    public var geometry: CanvasGeometry {
        CanvasGeometry(container: containerSize, aspect: output.aspect, viewRect: viewRect)
    }

    public var isTracking: Bool { trackingDepth > 0 }

    public var checkReport: CheckReport? { solver.currentReport ?? solver.report }

    // MARK: Editing and undo

    /// Applies a discrete change as one undo step named `name`.
    ///
    /// Changes with the same name and `coalescingKey` less than a second apart become one
    /// step, so typing a value or clicking zoom repeatedly is not one step per key or click.
    /// Pass a key that identifies the target (an element and property), so edits to two
    /// different elements never merge.
    public func edit(_ name: String, coalescingKey: AnyHashable? = nil, _ change: (inout FringeDocument) -> Void) {
        let before = document
        var after = document
        change(&after)
        lockShape(&after)
        guard after != before else { return }
        persistsDocument = true
        document = after
        let now = Date()
        guard let key = coalescingKey else {
            lastEdit = nil
            registerUndo(name, restoring: before)
            return
        }
        if let last = lastEdit, last.name == name, last.key == key, now.timeIntervalSince(last.time) < 1,
           undoManager?.undoActionName == name {
            lastEdit = (name, key, now)
            return
        }
        lastEdit = (name, key, now)
        registerUndo(name, restoring: before)
    }

    /// A binding that records each set as one undo step, except while a slider or
    /// gesture is tracking, when the whole drag becomes one step on release.
    public func binding<Value>(_ name: String, _ keyPath: WritableKeyPath<FringeDocument, Value>) -> Binding<Value> {
        Binding(
            get: { self.document[keyPath: keyPath] },
            set: { newValue in
                if self.trackingSnapshot != nil {
                    var doc = self.document
                    doc[keyPath: keyPath] = newValue
                    self.lockShape(&doc)
                    self.persistsDocument = true
                    self.document = doc
                } else {
                    self.edit(name, coalescingKey: keyPath) { $0[keyPath: keyPath] = newValue }
                }
            }
        )
    }

    public func elementBinding<Value>(
        _ id: String,
        _ name: String,
        _ keyPath: WritableKeyPath<Element, Value>,
        fallback: Value
    ) -> Binding<Value> {
        Binding(
            get: { self.scene[element: id]?[keyPath: keyPath] ?? fallback },
            set: { newValue in
                if self.trackingSnapshot != nil {
                    self.document.scene[element: id]?[keyPath: keyPath] = newValue
                } else {
                    self.edit(name, coalescingKey: [AnyHashable(id), AnyHashable(keyPath)]) {
                        $0.scene[element: id]?[keyPath: keyPath] = newValue
                    }
                }
            }
        )
    }

    /// For `Slider(onEditingChanged:)`: one drag is one undo step.
    public func editingChanged(_ name: String) -> (Bool) -> Void {
        { [weak self] isEditing in
            if isEditing {
                self?.beginTracking()
            } else {
                self?.endTracking(name)
            }
        }
    }

    /// Starts a drag or gesture. Every call must be balanced by one `endTracking`; the
    /// changes made until the last one ends become a single undo step.
    public func beginTracking() {
        if trackingDepth == 0 {
            trackingSnapshot = document
        }
        trackingDepth += 1
        solver.update(scene: scene, tracking: true)
    }

    public func endTracking(_ name: String) {
        guard trackingDepth > 0 else { return }
        trackingDepth -= 1
        guard trackingDepth == 0, let before = trackingSnapshot else { return }
        trackingSnapshot = nil
        lastEdit = nil
        registerUndo(name, restoring: before)
        solver.update(scene: scene, tracking: false)
    }

    private func registerUndo(_ name: String, restoring snapshot: FringeDocument) {
        guard snapshot != document, let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                let current = model.document
                var restored = snapshot
                restored.display.isPlaying = current.display.isPlaying
                if current.display.isPlaying { model.playbackPhase = restored.display.phaseDeg }
                model.lastEdit = nil
                model.persistsDocument = true
                model.document = restored
                model.enforceShapeLock()
                if model.selectedElementID == nil, case .element = model.selection {
                    model.selection = .source
                }
                model.registerUndo(name, restoring: current)
            }
        }
        undoManager.setActionName(name)
    }

    // MARK: Reacting to changes

    private func documentChanged(from old: FringeDocument) {
        if document.scene != old.scene {
            if document.scene.elements != old.scene.elements || document.scene.source != old.scene.source
                || document.scene.domain != old.scene.domain || document.scene.wavelengthUm != old.scene.wavelengthUm
                || document.scene.background != old.scene.background {
                outlines = FringeBridge.outlines(document.scene)
            }
            solver.update(scene: document.scene, tracking: isTracking)
        }
        if document.display.isPlaying != old.display.isPlaying || document != old {
            scheduleRender()
        }
        if document != old {
            schedulePersist()
        }
    }

    /// The shape lock: domain height = width / image aspect.
    private func lockShape(_ doc: inout FringeDocument) {
        let aspect = doc.output.aspect.ratio ?? windowAspect
        if abs(doc.scene.domain.aspect - aspect) > 1e-9 * aspect {
            doc.applyShapeLock(imageAspect: aspect)
        }
    }

    /// Applies the shape lock outside an edit, for a window resize under the Window aspect.
    private func enforceShapeLock() {
        var doc = document
        lockShape(&doc)
        if doc != document { document = doc }
    }

    private func solveResultChanged() {
        if let shown = solver.shown {
            if shown.field !== shownOutlinesField {
                shownOutlinesField = shown.field
                shownOutlines = FringeBridge.outlines(shown.scene)
            }
        } else {
            shownOutlinesField = nil
            shownOutlines = nil
        }
        scheduleRender()
        if exportAfterFinal, !solver.isRunning {
            exportAfterFinal = false
            if let shown = solver.shown, shown.quality == .final, !solver.isShownStale {
                isExporterPresented = true
            }
        }
    }

    public func showNotice(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: Rendering

    /// Raster size in pixels for the current canvas, display and tracking state.
    public var viewportPixelSize: (width: Int, height: Int) {
        let rect = geometry.imageRect
        guard rect.width >= 1, rect.height >= 1 else { return (0, 0) }
        var scale = displayScale
        // Half resolution while dragging, and while playing if a full render is slow.
        if isTracking || (display.isPlaying && renderer.lastDuration > .milliseconds(30)) {
            scale *= 0.5
        }
        let longEdge = max(rect.width, rect.height) * scale
        if longEdge > Self.maxPreviewEdge {
            scale *= Self.maxPreviewEdge / longEdge
        }
        return (max(1, Int((rect.width * scale).rounded())), max(1, Int((rect.height * scale).rounded())))
    }

    func scheduleRender() {
        guard let result = solver.shown else {
            renderer.clear()
            return
        }
        let size = viewportPixelSize
        guard size.width > 0, size.height > 0 else { return }
        let rect = viewRect
        let json = display.viewJSON(viewRect: rect, incidentAmplitude: result.info.incidentPeak, phaseDeg: playbackPhase)
        renderer.submit(RenderRequest(field: result.field, viewJSON: json, viewRect: rect, width: size.width, height: size.height))
    }

    /// The colour legend's lookup table for the current colormap.
    public var legendLUT: [UInt8] {
        let name = display.colormap.rawValue
        let wavelength = scene.wavelengthUm
        if let cache = lutCache, cache.name == name, cache.wavelength == wavelength { return cache.lut }
        let lut = FringeBridge.colormapLUT(name, wavelengthUm: wavelength)
        lutCache = (name, wavelength, lut)
        return lut
    }

    /// The canvas overlays. Outlines, handles and the source glyph follow the scene being
    /// edited; conductors are filled where the shown field was solved with them.
    /// It does not read the animated phase, which the overlays don't draw, so playback
    /// does not redraw them every frame.
    public func overlayModel(viewRect: RectUm) -> OverlayModel {
        OverlayModel(
            viewRect: viewRect,
            interior: interiorRect,
            pmlUm: pmlUm,
            outlines: outlines,
            source: scene.source,
            focusPoints: paraxialFocusPoints,
            display: display,
            caption: caption,
            legend: display.showLegend ? Legend(lut: legendLUT, display: display) : nil,
            selectedID: selectedElementID,
            showsHandles: true,
            anchors: Dictionary(scene.elements.map { ($0.id, [$0.xUm, $0.yUm]) }, uniquingKeysWith: { a, _ in a }),
            conductors: solver.shown == nil ? outlines : shownOutlines
        )
    }

    /// The scene the exported image shows: the one the shown field was solved for, so an
    /// out-of-date export draws its outlines, conductors and source where the field has them.
    private var exportScene: SimScene { solver.shown?.scene ?? scene }

    /// The export overlays, all taken from `exportScene`, at the frame on screen.
    private func exportOverlayModel(viewRect: RectUm) -> OverlayModel {
        let source = exportScene
        let stale = solver.isShownStale
        var display = self.display
        display.phaseDeg = playbackPhase ?? display.phaseDeg
        let lut = stale
            ? FringeBridge.colormapLUT(display.colormap.rawValue, wavelengthUm: source.wavelengthUm)
            : legendLUT
        // Disabled elements are not part of the solve, so the export leaves out their
        // dashed outlines (the canvas still shows them).
        var bodies = stale ? shownOutlines : outlines
        bodies?.bodies.removeAll { !$0.enabled }
        return OverlayModel(
            viewRect: viewRect,
            interior: source.domain.rect,
            pmlUm: source.domain.pmlWl * source.lambdaB,
            outlines: bodies,
            source: source.source,
            focusPoints: stale ? shownSceneFocusPoints : paraxialFocusPoints,
            display: display,
            caption: caption,
            legend: display.showLegend ? Legend(lut: lut, display: display) : nil,
            selectedID: nil,
            showsHandles: false,
            anchors: [:],
            conductors: bodies
        )
    }

    /// Focus points of the shown field's scene, checked once per result.
    private var shownSceneFocusPoints: [[Double]] {
        guard let shown = solver.shown else { return [] }
        if shown.field !== shownFocusField {
            shownFocusField = shown.field
            shownFocusPoints = Self.focusPoints(in: shown.scene, derived: FringeBridge.check(shown.scene).derived)
        }
        return shownFocusPoints
    }

    /// Paraxial focus points of enabled lenses and curved mirrors.
    public var paraxialFocusPoints: [[Double]] {
        Self.focusPoints(in: scene, derived: checkReport?.derived)
    }

    private static func focusPoints(in scene: SimScene, derived: Derived?) -> [[Double]] {
        guard let derived else { return [] }
        var points: [[Double]] = []
        for element in scene.elements where element.enabled {
            guard let info = derived.element(element.id) else { continue }
            if let focus = info.lens?.paraxialFocusUm, focus.count == 2 {
                points.append(focus)
            } else if let f = info.mirror?.focalUm, f > 0 {
                // The mirror faces −x in its own frame.
                let a = element.rotationDeg * .pi / 180
                points.append([element.xUm - f * cos(a), element.yUm - f * sin(a)])
            }
        }
        return points
    }

    /// "FDTD · $\lambda$ 1.00 µm · 24/$\lambda$ · final · 3.1 s", with "not converged" when it
    /// applies. The math is typeset on the canvas; `MathTypesetter.plain` gives the plain form.
    public var caption: String? {
        guard let shown = solver.shown else { return nil }
        let info = shown.info
        var parts = [
            info.method.title,
            #"$\lambda$ "# + "\(SceneFormat.fixed(info.wavelengthUm, 2)) µm",
            "\(Format.number(info.meta.ppw, digits: 0...1))/" + #"$\lambda$"#,
            info.quality.rawValue,
        ]
        if info.quality == .final { parts.append(SceneFormat.seconds(info.meta.wallS)) }
        if !info.meta.converged { parts.append("not converged") }
        return parts.joined(separator: " · ")
    }

    // MARK: Persistence

    private func schedulePersist() {
        persistTask?.cancel()
        guard persistsDocument else { return }
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    public func saveNow() {
        persistTask?.cancel()
        do {
            let data = try JSONEncoder().encode(document)
            UserDefaults.standard.set(data, forKey: Self.documentKey)
        } catch {
            Self.log.error("Could not save the document: \(error.localizedDescription)")
        }
    }

    /// Where the app saved its document while it was called Beam.
    private static let legacyDomain = "com.asympton.beam-bg"
    private static let legacyDocumentKey = "beam.document.v2"

    private static func restoredDocument() -> FringeDocument? {
        var data = UserDefaults.standard.data(forKey: documentKey)
        if data == nil, let legacy = UserDefaults(suiteName: legacyDomain)?.data(forKey: legacyDocumentKey) {
            // Copied once, before any launch override applies; the old domain is left as it was.
            UserDefaults.standard.set(legacy, forKey: documentKey)
            data = legacy
        }
        guard let data else { return nil }
        do {
            return try JSONDecoder().decode(FringeDocument.self, from: data)
        } catch {
            log.error("The saved document could not be read, starting from the default scene: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Elements

    public func addElement(_ kind: ShapeKind) {
        let domain = scene.domain
        let element = kind.makeElement(at: (domain.centerX, domain.centerY))
        edit("Add \(kind.title)") { $0.scene.elements.append(element) }
        selection = .element(element.id)
    }

    public func duplicateSelectedElement() {
        guard let original = selectedElement else { return }
        var copy = original
        copy.id = UUID().uuidString
        // Beside the original, clear of it.
        let width = outlines.flatMap { bodyBounds($0.bodies(of: original.id))?.width } ?? 1
        copy.xUm += width + scene.lambdaB
        edit("Duplicate Element") { $0.scene.elements.append(copy) }
        selection = .element(copy.id)
    }

    public func deleteSelectedElement() {
        guard let id = selectedElementID else { return }
        deleteElement(id)
    }

    public func deleteElement(_ id: String) {
        edit("Delete Element") { $0.scene[element: id] = nil }
        if case .element(let selected) = selection, selected == id { selection = .source }
    }

    public func toggleEnabled(_ id: String) {
        guard let element = scene[element: id] else { return }
        edit(element.enabled ? "Disable Element" : "Enable Element") {
            $0.scene[element: id]?.enabled.toggle()
        }
    }

    public func toggleSelectedElementEnabled() {
        if let id = selectedElementID { toggleEnabled(id) }
    }

    func bodyBounds(_ bodies: [SceneOutlines.Body]) -> RectUm? {
        var box: RectUm?
        for body in bodies {
            for p in body.outline where p.count == 2 {
                let r = RectUm(xMin: p[0], xMax: p[0], yMin: p[1], yMax: p[1])
                box = box.map { $0.union(r) } ?? r
            }
        }
        return box
    }

    // MARK: Domain

    public static let zoomStep = 1.25

    /// Zooms by `factor` about a point of the plane (the domain centre by default). The
    /// width stays within 2…400 background wavelengths.
    public func zoom(by factor: Double, about anchor: (x: Double, y: Double)? = nil) {
        let rect = zoomed(scene.domain.rect, by: factor, about: anchor)
        edit(factor > 1 ? "Zoom In" : "Zoom Out", coalescingKey: "zoom") { $0.scene.domain.set(rect) }
    }

    /// `rect` scaled by 1/`factor` about `anchor`, with its width clamped.
    public func zoomed(_ rect: RectUm, by factor: Double, about anchor: (x: Double, y: Double)? = nil) -> RectUm {
        let lambdaB = scene.lambdaB
        let width = min(400 * lambdaB, max(2 * lambdaB, rect.width / max(1e-6, factor)))
        let s = width / rect.width
        let ax = anchor?.x ?? rect.centerX
        let ay = anchor?.y ?? rect.centerY
        let height = rect.height * s
        let xMin = ax - (ax - rect.xMin) * s
        let yMin = ay - (ay - rect.yMin) * s
        return RectUm(xMin: xMin, xMax: xMin + width, yMin: yMin, yMax: yMin + height)
    }

    public func fitDomainToElements() {
        let aspect = imageAspect
        let outlines = self.outlines
        edit("Fit Domain to Elements") { $0.fitDomain(outlines: outlines, imageAspect: aspect) }
    }

    public func setAspect(_ aspect: OutputAspect) {
        edit("Change Aspect Ratio") { $0.output.aspect = aspect }
    }

    /// Sets the domain width about its centre; the height follows the aspect.
    public func setDomainWidth(_ width: Double) {
        let lambdaB = scene.lambdaB
        let w = min(400 * lambdaB, max(2 * lambdaB, width))
        edit("Change Domain Width", coalescingKey: "domain.width") {
            let d = $0.scene.domain
            $0.scene.domain.set(centerX: d.centerX, centerY: d.centerY, width: w, height: d.height)
        }
    }

    public func setDomainCenter(x: Double? = nil, y: Double? = nil) {
        edit("Move Domain", coalescingKey: "domain.center") {
            let d = $0.scene.domain
            $0.scene.domain.set(centerX: x ?? d.centerX, centerY: y ?? d.centerY, width: d.width, height: d.height)
        }
    }

    // MARK: Solving

    public func setMethod(_ method: SolverMethod) {
        edit("Change Solver") { $0.scene.solver.method = method }
    }

    public func runFinal() {
        solver.runFinal()
    }

    public func cancelSolve() {
        exportAfterFinal = false
        solver.cancel()
    }

    // MARK: Display

    public func setQuantity(_ quantity: Quantity) {
        edit("Change Quantity", coalescingKey: "quantity") { $0.display.quantity = quantity }
    }

    public func setColormap(_ colormap: ColormapName) {
        edit("Change Colormap", coalescingKey: "colormap") { $0.display.colormap = colormap }
    }

    /// Colormaps that suit the current quantity.
    public var availableColormaps: [ColormapName] {
        ColormapName.all(of: display.quantity.colormapKind)
    }

    public func nextColormap() { stepColormap(by: 1) }

    public func previousColormap() { stepColormap(by: -1) }

    private func stepColormap(by step: Int) {
        let all = availableColormaps
        guard !all.isEmpty else { return }
        let index = all.firstIndex(of: display.colormap) ?? 0
        setColormap(all[(index + step + all.count) % all.count])
    }

    public func togglePlaying() {
        if display.isPlaying {
            // Keep the phase where the animation stopped. Not an undo step.
            var doc = document
            doc.display.isPlaying = false
            if let phase = playbackPhase { doc.display.phaseDeg = (phase * 10).rounded() / 10 }
            playbackPhase = nil
            persistsDocument = true
            document = doc
        } else {
            if !display.quantity.dependsOnPhase {
                // Only the real part and the phase move with φ.
                setQuantity(.real)
            }
            playbackPhase = display.phaseDeg
            document.display.isPlaying = true
        }
    }

    /// Advances the phase during playback by `seconds` of wall time.
    public func advancePhase(by seconds: Double) {
        guard display.isPlaying, seconds > 0, let phase = playbackPhase else { return }
        let degrees = 360 * display.playbackSpeed * min(seconds, 0.25)
        playbackPhase = (phase + degrees).truncatingRemainder(dividingBy: 360)
        scheduleRender()
    }

    public func stepPhase(by degrees: Double) {
        var phase = (display.phaseDeg + degrees).truncatingRemainder(dividingBy: 360)
        if phase < 0 { phase += 360 }
        edit("Change Phase", coalescingKey: "phase") { $0.display.phaseDeg = phase }
    }

    // MARK: Scenes and templates

    /// Replaces the scene, keeping its domain shape by switching the output aspect to match.
    public func loadScene(_ newScene: SimScene, name: String, suggested: ExampleInfo? = nil) {
        edit(name) { doc in
            doc.scene = newScene
            doc.adoptDomainAspect()
            if let suggested { LaunchOptions.applySuggestedDisplay(suggested, to: &doc.display) }
        }
        selection = .source
    }

    public func loadExample(_ info: ExampleInfo) {
        guard let scene = FringeBridge.example(info.name) else { return }
        loadScene(scene, name: "Open Template", suggested: info)
    }

    public func openScene(at url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            // The core reports unknown keys and old schema versions precisely.
            let report = FringeBridge.check(json: text)
            if let parse = report.issues.first(where: { $0.code == "parse" || $0.code == "schema_version" }) {
                openErrorMessage = parse.sentence
                return
            }
            let scene = try SimScene.decode(json: text)
            loadScene(scene, name: "Open Scene")
        } catch {
            openErrorMessage = error.localizedDescription
        }
    }

    public var sceneFile: SceneFile {
        SceneFile(json: scene.jsonString(pretty: true))
    }

    public var suggestedSceneFilename: String {
        let name = scene.elements.first?.displayName.lowercased().replacingOccurrences(of: " ", with: "-") ?? "fringe"
        return "\(name)-scene"
    }

    // MARK: Export

    public var suggestedFilename: String {
        let method = solver.shown?.info.method ?? scene.solver.method
        return "fringe-\(method.rawValue)-\(display.quantity.fileTag)-\(output.aspect.fileTag)-\(output.longEdge.pixels)"
    }

    /// ⌘E: asks first when the image is a preview or out of date.
    public func requestExportImage() {
        guard let shown = solver.shown else {
            exportErrorMessage = "There is no solved field to export yet."
            return
        }
        if shown.quality == .preview || solver.isShownStale {
            isExportChoicePresented = true
        } else {
            isExporterPresented = true
        }
    }

    public func runFinalAndExport() {
        guard solver.canRunFinal else {
            exportErrorMessage = solver.finalTooLarge?.sentence ?? "The scene can't be solved at final quality."
            return
        }
        exportAfterFinal = true
        solver.runFinal()
    }

    /// A snapshot of the shown field at the output size, at the phase on screen.
    public var pngExport: PNGExport {
        let size = outputPixelSize
        let rect = exportViewRect
        return PNGExport(
            field: solver.shown?.field,
            viewJSON: display.viewJSON(
                viewRect: rect,
                incidentAmplitude: solver.shown?.info.incidentPeak ?? 1,
                phaseDeg: playbackPhase
            ),
            overlay: exportOverlayModel(viewRect: rect),
            width: size.width,
            height: size.height,
            onBusyChange: { @MainActor [weak self] busy in
                self?.isExporting = busy
            }
        )
    }

    /// The committed view of `exportScene` (no gesture in progress), at the output aspect.
    private var exportViewRect: RectUm {
        let source = exportScene
        let interior = source.domain.rect
        guard display.showPML else { return interior.grown(toAspect: imageAspect) }
        return interior.insetBy(-source.domain.pmlWl * source.lambdaB).grown(toAspect: imageAspect)
    }

    public func finishExport(_ result: Result<URL, Error>) {
        isExporting = false
        switch result {
        case .success(let url):
            lastExportURL = url
        case .failure(let error):
            exportErrorMessage = error.localizedDescription
        }
    }

    /// Writes the current image over the last exported file, without a save panel.
    public func exportAgain() {
        guard let url = lastExportURL, url.pathExtension.lowercased() == "png" else { return }
        runExport { data in try data.write(to: url, options: .atomic) }
    }

    public func copyImage() {
        runExport { data in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setData(data, forType: .png)
        }
    }

    private func runExport(_ deliver: @escaping @MainActor (Data) throws -> Void) {
        guard solver.shown != nil else {
            exportErrorMessage = "There is no solved field to export yet."
            return
        }
        let export = pngExport
        Task {
            do {
                let data = try await export.pngData()
                try deliver(data)
            } catch {
                exportErrorMessage = error.localizedDescription
            }
        }
    }

    /// Saves the shown part as complex128 .npy plus a JSON grid sidecar.
    public func exportFieldData() {
        guard let shown = solver.shown else {
            exportErrorMessage = "There is no solved field to export yet."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "npy") ?? .data]
        panel.nameFieldStringValue = "fringe-\(shown.info.method.rawValue)-\(display.part.rawValue).npy"
        panel.message = "Saves the \(display.part.title.lowercased()) field as complex numbers, with a .json file describing the grid."
        let part = display.part
        let field = shown.field
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                self?.isExporting = true
                Task {
                    let error = await Task.detached(priority: .userInitiated) { () -> String? in
                        do {
                            try field.exportNPY(part: part, to: url)
                            return nil
                        } catch {
                            return error.localizedDescription
                        }
                    }.value
                    self?.isExporting = false
                    if let error { self?.exportErrorMessage = error }
                }
            }
        }
    }

    /// Writes `animationFrameCount` PNGs over φ ∈ [0, 360°) into a folder.
    public func exportAnimationFrames() {
        guard let shown = solver.shown else {
            exportErrorMessage = "There is no solved field to export yet."
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Frames"
        panel.message = "Choose a folder for \(animationFrameCount) frames (frame_000.png, frame_001.png, …)."
        let base = pngExport
        let count = max(1, animationFrameCount)
        let display = self.display
        let rect = exportViewRect
        let amplitude = shown.info.incidentPeak
        panel.begin { [weak self] response in
            guard response == .OK, let folder = panel.url else { return }
            MainActor.assumeIsolated {
                self?.isExporting = true
                Task {
                    let error = await Task.detached(priority: .userInitiated) { () -> String? in
                        do {
                            for k in 0..<count {
                                var frame = base
                                let phase = 360.0 * Double(k) / Double(count)
                                frame.viewJSON = display.viewJSON(viewRect: rect, incidentAmplitude: amplitude, phaseDeg: phase)
                                frame.overlay.display.phaseDeg = phase
                                let data = try ImageExportService.renderPNG(frame)
                                let name = String(format: "frame_%03d.png", k)
                                try data.write(to: folder.appendingPathComponent(name), options: .atomic)
                            }
                            return nil
                        } catch {
                            return error.localizedDescription
                        }
                    }.value
                    self?.isExporting = false
                    if let error { self?.exportErrorMessage = error }
                }
            }
        }
    }

    // MARK: Hover

    public func updateHover(at point: CGPoint?) {
        guard let point, geometry.imageRect.contains(point) else {
            hover = nil
            return
        }
        let plane = geometry.planePoint(point)
        var readout = HoverReadout(xUm: plane.x, yUm: plane.y)
        if let shown = solver.shown, let value = shown.field.sample(x: plane.x, y: plane.y, part: display.part) {
            let a = max(1e-300, shown.info.incidentPeak)
            readout.intensity = (value.re * value.re + value.im * value.im) / (a * a)
            var phase = (atan2(value.im, value.re) * 180 / .pi + (playbackPhase ?? display.phaseDeg)).truncatingRemainder(dividingBy: 360)
            if phase > 180 { phase -= 360 }
            if phase <= -180 { phase += 360 }
            readout.phaseDeg = phase
        }
        if let id = hitTestElement(x: plane.x, y: plane.y, tolerancePoints: 0, includeDisabled: false),
           let element = scene[element: id] {
            readout.body = "\(MathTypesetter.escaped(element.displayName)) (\(element.material.badge))"
        }
        hover = readout
    }

    /// The element whose outline contains the point, or whose edge is within
    /// `tolerancePoints` of it. Disabled elements can be selected on the canvas
    /// but are not bodies of the solved field.
    public func hitTestElement(x: Double, y: Double, tolerancePoints: CGFloat = 6,
                               includeDisabled: Bool = true) -> String? {
        guard let outlines else { return nil }
        let tolerance = geometry.micrometres(forPoints: tolerancePoints)
        var best: (id: String, distance: Double)?
        for body in outlines.bodies where includeDisabled || body.enabled {
            let inside = PlaneGeometry.contains(body.outline, x: x, y: y)
            let distance = inside ? 0 : PlaneGeometry.distance(body.outline, x: x, y: y)
            if distance <= tolerance, best.map({ distance < $0.distance }) ?? true {
                best = (body.elementId, distance)
            }
        }
        return best?.id
    }
}

/// A scene as a JSON file for Save Scene…, readable by `fringe-cli`.
public struct SceneFile: Transferable, Sendable {
    public var json: String

    public static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { file in
            Data(file.json.utf8)
        }
    }
}

/// Small plane-geometry helpers on [x, y] polylines.
public enum PlaneGeometry {
    /// Even-odd point-in-polygon test.
    public static func contains(_ polygon: [[Double]], x: Double, y: Double) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i]
            let b = polygon[j]
            if a.count == 2, b.count == 2, (a[1] > y) != (b[1] > y) {
                let t = (y - a[1]) / (b[1] - a[1])
                if x < a[0] + t * (b[0] - a[0]) { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    /// Distance from a point to a closed polyline.
    public static func distance(_ polygon: [[Double]], x: Double, y: Double) -> Double {
        var best = Double.infinity
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[j]
            let b = polygon[i]
            j = i
            guard a.count == 2, b.count == 2 else { continue }
            let dx = b[0] - a[0]
            let dy = b[1] - a[1]
            let len2 = dx * dx + dy * dy
            let t = len2 > 0 ? max(0, min(1, ((x - a[0]) * dx + (y - a[1]) * dy) / len2)) : 0
            let px = a[0] + t * dx - x
            let py = a[1] + t * dy - y
            best = min(best, (px * px + py * py).squareRoot())
        }
        return best
    }
}
