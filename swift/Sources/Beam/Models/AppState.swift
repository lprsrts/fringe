import AppKit
import Observation
import SwiftUI
import os

public enum SidebarItem: Hashable, Sendable {
    case beam
    case element(UUID)
    case appearance
    case output
}

@MainActor
@Observable
public final class AppState {
    /// Every edit goes through here. Only changes to what the raster depends on re-render it.
    public var scene = BeamScene() {
        didSet {
            if scene.rasterInputs(windowAspect: windowAspect) != oldValue.rasterInputs(windowAspect: windowAspect) {
                scheduleRender()
            }
        }
    }

    public var selection: SidebarItem = .beam
    public var isInspectorPresented = true
    public var isExporterPresented = false
    public var isExporting = false
    public var lastExportURL: URL?
    public var exportErrorMessage: String?

    /// Size of the canvas area in points.
    public var containerSize: CGSize = .zero {
        didSet { if containerSize != oldValue { scheduleRender() } }
    }
    public var displayScale: CGFloat = 2 {
        didSet { if displayScale != oldValue { scheduleRender() } }
    }
    /// Number of slider drags and canvas gestures in progress. Pinch and drag can overlap,
    /// so this is a count; while it is above zero the preview renders at half resolution.
    public private(set) var trackingDepth = 0 {
        didSet { if (trackingDepth > 0) != (oldValue > 0) { scheduleRender() } }
    }

    public private(set) var rasterImage: CGImage?

    /// The solved field the canvas shows. Until the v2 scene model lands this is the
    /// core's default scene, solved once at preview quality.
    @ObservationIgnored private var field: FieldHandle?
    @ObservationIgnored private var fieldGeneration = 0

    @ObservationIgnored public var undoManager: UndoManager?
    @ObservationIgnored private var isRenderInFlight = false
    @ObservationIgnored private var isRenderPending = false
    @ObservationIgnored private var lastRenderKey: RenderKey?
    /// The scene as it was when the first of the current drags or gestures began.
    @ObservationIgnored private var trackingSnapshot: BeamScene?
    @ObservationIgnored private var lastEdit: (name: String, key: AnyHashable, time: Date)?

    private static let maxPreviewEdge: CGFloat = 4096
    private static let log = Logger(subsystem: "com.asympton.beam-bg", category: "render")

    public init() {
        scene.zoomToFit(aspect: imageAspect)
        solveDefaultScene()
    }

    /// Solves the core's default scene at preview quality, polling the job every 50 ms.
    private func solveDefaultScene() {
        let job: JobHandle
        do {
            job = try JobHandle(sceneJSON: BeamBridge.defaultSceneJSON(), quality: .preview)
        } catch {
            Self.log.error("Could not start the solve: \(error.localizedDescription)")
            return
        }
        Task {
            while job.isRunning {
                try? await Task.sleep(for: .milliseconds(50))
            }
            do {
                field = try job.takeResult()
                fieldGeneration += 1
                scheduleRender()
            } catch {
                Self.log.error("The solve failed: \(error.localizedDescription)")
            }
        }
    }

    /// View JSON (spec §3.6) for the current display settings.
    private var viewJSON: String {
        let view: [String: Any] = ["colormap": style.colormap.coreName, "gamma": style.gamma]
        guard let data = try? JSONSerialization.data(withJSONObject: view, options: .sortedKeys) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }


    public var beam: BeamParameters { scene.beam }
    public var elements: [PlacedElementModel] { scene.elements }
    public var style: RenderStyleModel { scene.style }
    public var framing: FramingModel { scene.framing }
    public var output: OutputFormat { scene.output }

    public var selectedElementID: UUID? {
        if case .element(let id) = selection, scene[element: id] != nil { return id }
        return nil
    }

    public var selectedElement: PlacedElementModel? {
        selectedElementID.flatMap { scene[element: $0] }
    }

    public var geometry: CanvasGeometry {
        CanvasGeometry(container: containerSize, aspect: output.aspect, window: window)
    }

    /// Aspect of the canvas area, used when the output follows the window.
    public var windowAspect: Double {
        guard containerSize.width > 0, containerSize.height > 0 else { return 16.0 / 9.0 }
        return Double(containerSize.width / containerSize.height)
    }

    /// Width over height of the output in pixels, which sets how much of the axis is shown.
    public var imageAspect: Double {
        output.pixelAspect(windowAspect: windowAspect)
    }

    /// What the preview and exports show.
    public var window: FrameWindow {
        scene.window(windowAspect: windowAspect)
    }

    public var outputSummary: String {
        output.summary(windowAspect: windowAspect)
    }

    public var outputPixelSize: (width: Int, height: Int) {
        output.pixelSize(windowAspect: windowAspect)
    }


    /// Applies a discrete change as one undo step named `name`.
    ///
    /// Changes with the same name and `coalescingKey` less than a second apart become one
    /// step, so typing a name or clicking zoom repeatedly is not one step per key or click.
    /// Pass a key that identifies the target (an element and property), so edits to two
    /// different elements never merge.
    public func edit(_ name: String, coalescingKey: AnyHashable? = nil, _ change: (inout BeamScene) -> Void) {
        let before = scene
        change(&scene)
        scene.sortElements()
        guard before != scene else { return }
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
    public func binding<Value>(_ name: String, _ keyPath: WritableKeyPath<BeamScene, Value>) -> Binding<Value> {
        Binding(
            get: { self.scene[keyPath: keyPath] },
            set: { newValue in
                if self.trackingSnapshot != nil {
                    self.scene[keyPath: keyPath] = newValue
                } else {
                    self.edit(name, coalescingKey: keyPath) { $0[keyPath: keyPath] = newValue }
                }
            }
        )
    }

    public func elementBinding<Value>(
        _ id: UUID,
        _ name: String,
        _ keyPath: WritableKeyPath<PlacedElementModel, Value>,
        fallback: Value
    ) -> Binding<Value> {
        Binding(
            get: { self.scene[element: id]?[keyPath: keyPath] ?? fallback },
            set: { newValue in
                if self.trackingSnapshot != nil {
                    self.scene[element: id]?[keyPath: keyPath] = newValue
                } else {
                    self.edit(name, coalescingKey: [AnyHashable(id), AnyHashable(keyPath)]) {
                        $0[element: id]?[keyPath: keyPath] = newValue
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

    public var isTracking: Bool { trackingDepth > 0 }

    /// Starts a drag or gesture. Every call must be balanced by one `endTracking`; the
    /// changes made until the last one ends become a single undo step.
    public func beginTracking() {
        if trackingDepth == 0 {
            trackingSnapshot = scene
        }
        trackingDepth += 1
    }

    public func endTracking(_ name: String) {
        guard trackingDepth > 0 else { return }
        trackingDepth -= 1
        guard trackingDepth == 0, let before = trackingSnapshot else { return }
        trackingSnapshot = nil
        scene.sortElements()
        lastEdit = nil
        registerUndo(name, restoring: before)
    }

    private func registerUndo(_ name: String, restoring snapshot: BeamScene) {
        guard snapshot != scene, let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            let current = model.scene
            model.lastEdit = nil
            model.scene = snapshot
            if model.selectedElementID == nil, case .element = model.selection {
                model.selection = .beam
            }
            model.registerUndo(name, restoring: current)
        }
        undoManager.setActionName(name)
    }


    public func addElement(_ type: OpticalElementType) {
        let element = type.makeElement(at: framing.centerZ)
        edit("Add Element") { $0.elements.append(element) }
        selection = .element(element.id)
    }

    public func duplicateSelectedElement() {
        guard let original = selectedElement else { return }
        let copy = PlacedElementModel(
            z: original.z + 0.05 * window.spanZ,
            type: original.type,
            param1: original.param1,
            param2: original.param2,
            isEnabled: original.isEnabled,
            name: original.name
        )
        edit("Duplicate Element") { $0.elements.append(copy) }
        selection = .element(copy.id)
    }

    public func deleteSelectedElement() {
        guard let id = selectedElementID else { return }
        edit("Delete Element") { $0[element: id] = nil }
        selection = .beam
    }

    public func toggleSelectedElementEnabled() {
        guard let id = selectedElementID, let element = scene[element: id] else { return }
        edit(element.isEnabled ? "Disable Element" : "Enable Element") {
            $0[element: id]?.isEnabled.toggle()
        }
    }


    public func zoom(by factor: Double) {
        let aspect = imageAspect
        edit(factor > 1 ? "Zoom In" : "Zoom Out", coalescingKey: \BeamScene.framing) {
            $0.framing.zoom(by: factor, aspect: aspect)
        }
    }

    public func zoomToFit() {
        let aspect = imageAspect
        edit("Zoom to Fit") { $0.zoomToFit(aspect: aspect) }
    }

    /// Makes the image show exactly `start...end` at the current aspect.
    public func setAxialRange(start: Double, end: Double) {
        let aspect = imageAspect
        edit("Change Axial Range") { $0.framing.setVisibleRange(start: start, end: end, aspect: aspect) }
    }

    public func setAspect(_ aspect: OutputAspect) {
        edit("Change Aspect Ratio") { $0.output.aspect = aspect }
    }

    public func setColormap(_ colormap: ColormapOption) {
        edit("Change Colormap", coalescingKey: \BeamScene.style.colormap) { $0.style.colormap = colormap }
    }

    public func nextColormap() { stepColormap(by: 1) }

    public func previousColormap() { stepColormap(by: -1) }

    private func stepColormap(by step: Int) {
        let all = ColormapOption.allCases
        let index = all.firstIndex(of: style.colormap) ?? 0
        setColormap(all[(index + step + all.count) % all.count])
    }


    public var suggestedFilename: String {
        let nm = Int((beam.wavelength * 1e9).rounded())
        return "beam-\(nm)nm-\(style.colormap.fileTag)-\(output.aspect.fileTag)-\(output.longEdge.pixels)"
    }

    /// A snapshot of the current scene at the output size.
    public var pngExport: PNGExport {
        let size = outputPixelSize
        return PNGExport(
            field: field,
            viewJSON: viewJSON,
            beam: beam,
            elements: elements,
            style: style,
            window: window,
            width: size.width,
            height: size.height,
            onBusyChange: { @MainActor [weak self] busy in
                self?.isExporting = busy
            }
        )
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

    /// Writes the current scene over the last exported file, without a save panel.
    public func exportAgain() {
        guard let url = lastExportURL else { return }
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


    private struct RenderKey: Equatable {
        var inputs: BeamScene.RasterInputs
        var field: Int
        var width: Int
        var height: Int
    }

    /// Raster size in pixels for the current canvas, display and tracking state.
    public var viewportPixelSize: (width: Int, height: Int) {
        let rect = geometry.imageRect
        guard rect.width >= 1, rect.height >= 1 else { return (0, 0) }
        var scale = displayScale * (isTracking ? 0.5 : 1.0)
        let longEdge = max(rect.width, rect.height) * scale
        if longEdge > Self.maxPreviewEdge {
            scale *= Self.maxPreviewEdge / longEdge
        }
        return (max(1, Int((rect.width * scale).rounded())), max(1, Int((rect.height * scale).rounded())))
    }

    /// Renders the raster off the main thread, one render at a time. Changes that arrive
    /// while a render runs are folded into a single follow-up render of the latest state,
    /// since the core's render cannot be cancelled once started.
    private func scheduleRender() {
        guard !isRenderInFlight else {
            isRenderPending = true
            return
        }

        let size = viewportPixelSize
        guard size.width > 0, size.height > 0, let field else { return }
        let key = RenderKey(
            inputs: scene.rasterInputs(windowAspect: windowAspect),
            field: fieldGeneration,
            width: size.width,
            height: size.height
        )
        guard key != lastRenderKey else { return }
        lastRenderKey = key
        isRenderInFlight = true

        let viewJSON = viewJSON

        Task {
            let start = ContinuousClock.now
            let image = await Task.detached(priority: .userInitiated) {
                try? field.render(viewJSON: viewJSON, width: size.width, height: size.height)
            }.value

            if let image {
                Self.log.debug("Rendered \(size.width)×\(size.height) in \(ContinuousClock.now - start)")
                rasterImage = image
            } else {
                // Keep showing the last good image rather than going blank.
                Self.log.error("The core rejected the scene at \(size.width)×\(size.height)")
            }

            isRenderInFlight = false
            if isRenderPending {
                isRenderPending = false
                scheduleRender()
            }
        }
    }
}
