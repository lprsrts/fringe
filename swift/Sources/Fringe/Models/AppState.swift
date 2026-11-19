import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import os

/// What the sidebar and the inspector show: the shared wavelength and medium, one source,
/// element or detector by id, or one of the settings pages.
public enum SidebarItem: Hashable, Sendable {
    case illumination
    case source(String)
    case element(String)
    case detector(String)
    case simulation
    case display
    case output
}

/// The simulator edits the user's own scene; puzzle mode shows the puzzle browser or one
/// puzzle. Each mode has its own document.
public enum AppMode: String, Codable, Sendable {
    case simulator
    case puzzles
}

/// The simulator as it was when puzzle mode took over the window, put back exactly on the
/// way out.
struct ParkedSimulator {
    var document: FringeDocument
    var selection: SidebarItem
    var results: SolveController.Results
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

    /// Simulator or puzzles; set through `setMode` (AppState+Puzzles.swift).
    public internal(set) var mode: AppMode = .simulator
    /// The simulator's document, selection and results while puzzle mode is active.
    var parkedSimulator: ParkedSimulator?
    /// Puzzle catalog, progress, the open puzzle and its Check.
    public let puzzles = PuzzleController()

    public var selection: SidebarItem = .illumination {
        didSet {
            if case .detector(let id) = selection, resultsSelection != id { resultsSelection = id }
        }
    }
    public var isInspectorPresented = true
    /// The results area under the canvas (detector table and line profile).
    public var isResultsPresented = UserDefaults.standard.bool(forKey: AppState.resultsVisibleKey) {
        didSet {
            if isResultsPresented != oldValue { UserDefaults.standard.set(isResultsPresented, forKey: Self.resultsVisibleKey) }
        }
    }
    /// The detector the results table highlights and the profile shows. Follows the
    /// sidebar when a detector is selected there, and stays when something else is.
    public var resultsSelection: String?

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

    /// Size of the canvas area in points. Under the Window aspect a size change does not
    /// edit the domain at once: the canvas shows the field letterboxed to the new shape
    /// (see `viewRect`) and the domain follows once, when a live resize ends or the size has
    /// been still for `shapeLockDelay`.
    public var containerSize: CGSize = .zero {
        didSet {
            guard containerSize != oldValue else { return }
            PerfProbe.count("canvas.containerSize")
            if document.output.aspect == .window { scheduleShapeLock() }
            // The subtitle and the sidebar's Output badge follow once the size settles: under
            // the Window aspect they name the pixel size, and each change re-evaluates the
            // window's body.
            if oldValue == .zero { refreshSubtitle() } else { refreshSubtitleSoon() }
            scheduleRender()
        }
    }
    /// A live resize of the window is in progress (from the canvas view).
    @ObservationIgnored public var isLiveResizing = false {
        // Not at once: the canvas reports its last size asynchronously, possibly after the
        // live resize ended, and that report must fold into the same single domain change.
        didSet {
            if isLiveResizing, !holdsColumnHeights { holdsColumnHeights = true }
            if !isLiveResizing, oldValue, document.output.aspect == .window { scheduleShapeLock() }
        }
    }
    /// While the window's size keeps changing (a live resize, or size changes in quick
    /// succession), the sidebar and the inspector keep the tallest height seen and are
    /// clipped by the window instead of laid out again at every step (`HeldHeight`). Set
    /// by the canvas view, which also clears it once the size has settled.
    public internal(set) var holdsColumnHeights = false
    @ObservationIgnored private var shapeLockTask: Task<Void, Never>?
    static let shapeLockDelay: Duration = .milliseconds(300)
    /// Canvas-only state: hover, live drag, animated phase.
    public let viewport = ViewportModel()
    /// The reveal of a puzzle's Check result (AppState+Reveal.swift).
    let reveal = RevealController(frozenTime: LaunchOptions.revealAtSeconds)
    /// Settings ▸ Sound and "Animate puzzle results".
    let soundSettings: SoundSettings
    /// Puzzle sounds (AppState+Sound.swift). Its audio engine is built at the first Check
    /// with sound on, not at launch, and stops once nothing has sounded for 4 s.
    let sound: SoundEngine
    /// The reveal sound being played, kept for a skip's verdict tone.
    @ObservationIgnored var revealSound: SoundRevealInput?
    /// When a reveal was last skipped: an input switch right after it (the click that
    /// skipped it) plays no toggle tone over the verdict tone.
    @ObservationIgnored var lastRevealSkip: ContinuousClock.Instant?
    /// Shots: plan reveals as if sound were on (the design's times) while nothing plays.
    @ObservationIgnored var revealAssumesSoundForTesting = false
    /// The canvas colours with the CPU renderer: no Metal, the shader did not compile, or
    /// `--viewport cpu`.
    public private(set) var viewportUsesCPU = FieldGPU.shared == nil
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
    /// What the pointer is over; lives in the canvas-only `viewport` model.
    public var hover: HoverReadout? {
        get { viewport.hover }
        set { if viewport.hover != newValue { viewport.hover = newValue } }
    }
    /// The animated phase while playback runs. Kept out of the document and out of
    /// observation (it lives in `viewport`), so a frame never re-evaluates a view; written
    /// back when playback stops.
    public var playbackPhase: Double? {
        get { display.isPlaying ? viewport.phase : nil }
        set { if let newValue { viewport.phase = newValue } }
    }
    /// Rate limits for a drag's solver updates and the inspector's copy of the drag.
    @ObservationIgnored private let liveSolve = Throttle()
    @ObservationIgnored private let liveInspector = Throttle()
    nonisolated(unsafe) static var liveSolveInterval: Duration = .milliseconds(500)
    /// The inspector's position fields follow a canvas drag at this rate. Each update lays
    /// out the inspector form again (about 10 ms of main thread in the harness), so at
    /// 10 Hz the canvas missed frames; 4 Hz keeps the numbers live and the canvas smooth.
    nonisolated(unsafe) static var liveInspectorInterval: Duration = .milliseconds(250)
    /// The canvas drag as the inspector shows it: `viewport.liveEdit`, at most every
    /// `liveInspectorInterval`. Only the bindings of the dragged item's position fields
    /// read it, so a drag re-evaluates those fields and nothing else. The document itself
    /// takes the drag once, when it ends: each document change re-evaluates and lays out
    /// the sidebar and the inspector (50–100 ms of main thread), which stalled the canvas.
    public private(set) var inspectorLive: LiveEdit?

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
    /// Readings of the scene's detectors on the shown field, by detector id. Measured again
    /// when a detector or the shown field changes, without a solve.
    public internal(set) var detectorReadings: [String: DetectorReading] = [:]
    /// The field and detectors `detectorReadings` were measured for.
    @ObservationIgnored var readingsKey: ReadingsKey?
    @ObservationIgnored var readingsTask: Task<Void, Never>?
    /// |E|² profiles along line detectors on the shown field, by field and line.
    public internal(set) var profiles: [ProfileKey: [ProfilePoint]] = [:]
    @ObservationIgnored var profileTasks: [ProfileKey: Task<Void, Never>] = [:]
    /// The core's Lorentz–Drude presets, read once at launch.
    public let materialLibrary: [MaterialLibraryEntry] = MaterialLibrary.entries

    @ObservationIgnored public var undoManager: UndoManager?
    /// The document as it was when the first of the current drags or gestures began.
    @ObservationIgnored private var trackingSnapshot: FringeDocument?
    @ObservationIgnored private var lastEdit: (name: String, key: AnyHashable, time: Date)?
    @ObservationIgnored private var persistTask: Task<Void, Never>?
    /// False after a launch with overrides until the user changes something, so a
    /// scripted run never replaces the saved document.
    @ObservationIgnored var persistsDocument = true
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var exportAfterFinal = false
    @ObservationIgnored private var lutCache: (name: String, wavelength: Double, lut: [UInt8])?

    private static let maxPreviewEdge: CGFloat = 4096
    static let log = Logger(subsystem: "com.asympton.fringe", category: "app")

    /// UserDefaults key of the saved document.
    public static let documentKey = "fringe.document.v3"
    /// Where builds before the source list saved it. Read when there is no version 3
    /// document, or it cannot be decoded (its scene is upgraded on decoding), and left in
    /// place, so an older build still finds its own document.
    public static let previousDocumentKey = "fringe.document.v2"
    /// A copy of a version 3 document that could not be decoded, kept before it is replaced.
    static let unreadableDocumentKey = "fringe.document.v3.unreadable"
    /// Whether the results area is shown.
    public static let resultsVisibleKey = "fringe.results.visible"
    /// Set once the results area has opened by itself for a first detector.
    static let resultsOpenedKey = "fringe.results.opened"
    /// Simulator or puzzles, as the app was left.
    public static let modeKey = "fringe.mode"

    public init() {
        let soundSettings = SoundSettings()
        self.soundSettings = soundSettings
        sound = SoundEngine(settings: soundSettings, output: LaunchOptions.sound)
        var document = Self.restoredDocument() ?? FringeDocument(scene: FringeBridge.defaultScene())
        let launch = LaunchOptions.read(examples: examples)
        launch.apply(to: &document)
        self.document = document
        canvasAspect = document.output.aspect
        refreshToolbarDocument()
        windowSubtitle = document.output.summary(windowAspect: 16.0 / 9.0)
        persistsDocument = !launch.hasOverrides
        if let selection = launch.selection(in: document.scene) {
            self.selection = selection
        } else if let first = document.scene.sources.first {
            self.selection = .source(first.id)
        }

        showResultsForLoadedDetectors(onlyOnce: true)

        solver.onResult = { [weak self] in self?.solveResultChanged() }
        FieldGPU.shared?.whenFailed { [weak self] in
            self?.viewportUsesCPU = true
            self?.scheduleRender()
        }
        solver.onNotice = { [weak self] message in self?.showNotice(message) }
        reveal.onCanvasCase = { [weak self] index in self?.showRevealCase(index) }
        reveal.onEnd = { [weak self] in self?.revealEnded() }
        connectSound()
        outlines = FringeBridge.outlines(document.scene)
        enforceShapeLock()
        solver.update(scene: self.document.scene, tracking: false)
        if launch.runFinal {
            solver.runFinal()
        } else {
            solver.previewNow()
        }
        // Puzzle mode as it was left (or as a launch option asks), on the browser or the
        // puzzle that was open.
        let savedMode = UserDefaults.standard.string(forKey: Self.modeKey).flatMap(AppMode.init(rawValue:))
        if launch.mode ?? savedMode == .puzzles, !launch.hasOverrides || launch.mode == .puzzles {
            setMode(.puzzles, puzzle: launch.puzzleID)
        }
        if Self.savedDocumentWasUnreadable, !launch.hasOverrides || mode == .simulator {
            // The newer document is kept under its own key; the user should know it was set aside.
            showNotice("Your last scene could not be read, so an earlier one is open")
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.puzzles.flushDesign()
                guard self.persistsDocument else { return }
                self.saveNow()
            }
        }
    }

    // MARK: Convenience

    /// What the toolbar shows from the document, stored and set only when it changes: read
    /// from `document`, every committed drag step re-evaluated each toolbar item and made
    /// SwiftUI rebuild the whole toolbar (about a quarter of the main thread in a drag).
    public struct ToolbarDocument: Equatable {
        public var method: SolverMethod
        public var display: DisplaySettings
        /// Not part of `DisplaySettings`'s `==`.
        public var isPlaying: Bool
        public var output: OutputFormat
    }

    public private(set) var toolbarDocument = ToolbarDocument(method: .fdtd, display: DisplaySettings(), isPlaying: false, output: OutputFormat())

    private func refreshToolbarDocument() {
        let t = ToolbarDocument(method: document.scene.solver.method, display: document.display, isPlaying: document.display.isPlaying,
                                output: document.output)
        if t != toolbarDocument { toolbarDocument = t }
    }

    /// Whether a result is on the canvas, stored: the toolbar's Export button reads it, and
    /// `solver.shown` changes with every preview.
    public private(set) var hasShownResult = false

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

    public var selectedSourceID: String? {
        if case .source(let id) = selection, scene[source: id] != nil { return id }
        return nil
    }

    public var selectedSource: Source? {
        selectedSourceID.flatMap { scene[source: $0] }
    }

    public var selectedDetectorID: String? {
        if case .detector(let id) = selection, scene[detector: id] != nil { return id }
        return nil
    }

    public var selectedDetector: Detector? {
        selectedDetectorID.flatMap { scene[detector: $0] }
    }

    /// The selected source, element or detector, if the selection is one that exists.
    public var selectedItem: SceneItem? {
        switch selection {
        case .source(let id) where scene[source: id] != nil: return .source(id)
        case .element(let id) where scene[element: id] != nil: return .element(id)
        case .detector(let id) where scene[detector: id] != nil: return .detector(id)
        default: return nil
        }
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

    /// `outputSummary`, stored, and set only when it changes: the window's subtitle reads it,
    /// so a drag step or a resize step that leaves it alone re-evaluates nothing.
    public private(set) var windowSubtitle = ""

    @ObservationIgnored private var subtitleTask: Task<Void, Never>?

    private func refreshSubtitleSoon() {
        subtitleTask?.cancel()
        subtitleTask = Task { [weak self] in
            try? await Task.sleep(for: AppState.shapeLockDelay)
            guard !Task.isCancelled else { return }
            self?.refreshSubtitle()
        }
    }

    private func refreshSubtitle() {
        let s = outputSummary
        if s != windowSubtitle { windowSubtitle = s }
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
        var interior = interiorRect
        // Under the Window aspect, while the domain has not yet followed a new canvas
        // shape, the field is shown letterboxed in it.
        if output.aspect == .window, mode == .simulator, interior.height > 0,
           abs(interior.width / interior.height - windowAspect) > 1e-6 * windowAspect {
            interior = interior.grown(toAspect: windowAspect)
        }
        guard display.showPML else { return interior }
        return interior.insetBy(-pmlUm).grown(toAspect: imageAspect)
    }

    public var geometry: CanvasGeometry {
        CanvasGeometry(container: containerSize, aspect: output.aspect, viewRect: viewRect)
    }

    /// The output shape, kept apart from the document so the canvas view does not
    /// re-evaluate for every document change (a drag step, for one).
    public private(set) var canvasAspect: OutputAspect = .window

    public var isTracking: Bool { trackingDepth > 0 }

    /// The canvas shows the current result (for the harnesses' waits).
    public var isViewportCurrent: Bool {
        guard let shown = solver.shown else { return true }
        return viewportUsesCPU ? renderer.rendered?.field === shown.field : viewport.drawnField === shown.field
    }

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
        guard after != before, admits(after, from: before) else { return }
        // A puzzle edit leaves the simulator document as it is: after a launch with
        // overrides it must still not be saved over the user's own.
        if mode == .simulator { persistsDocument = true }
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
                    self.track { $0[keyPath: keyPath] = newValue }
                } else {
                    self.edit(name, coalescingKey: keyPath) { $0[keyPath: keyPath] = newValue }
                }
            }
        )
    }

    /// A binding to element `id`'s `keyPath`. With `live`, it shows a canvas drag of the
    /// element as it goes (`inspectorLive`): build such a binding inside `LiveFields`, as a
    /// binding reads its value when it is made, so the view that makes it follows the drag.
    public func elementBinding<Value>(
        _ id: String,
        _ name: String,
        _ keyPath: WritableKeyPath<Element, Value>,
        fallback: Value,
        live: Bool = false
    ) -> Binding<Value> {
        Binding(
            get: {
                self.inspectorValue(self.scene[element: id], id: id, keyPath, isLive: live) { live, element in
                    if case .element(_, let x, let y) = live { element.xUm = x; element.yUm = y }
                } ?? fallback
            },
            set: { newValue in
                if self.trackingSnapshot != nil {
                    self.track { $0.scene[element: id]?[keyPath: keyPath] = newValue }
                } else {
                    self.edit(name, coalescingKey: [AnyHashable(id), AnyHashable(keyPath)]) {
                        $0.scene[element: id]?[keyPath: keyPath] = newValue
                    }
                }
            }
        )
    }

    /// A change while a drag or slider is tracking: applied at once, with no undo step of
    /// its own (the drag's step is registered when it ends).
    public func track(_ change: (inout FringeDocument) -> Void) {
        var after = document
        change(&after)
        lockShape(&after)
        guard after != document, admits(after, from: document) else { return }
        // A puzzle edit leaves the simulator document as it is: after a launch with
        // overrides it must still not be saved over the user's own.
        if mode == .simulator { persistsDocument = true }
        document = after
    }

    /// Whether a change may happen in this mode: in a puzzle, the sources, detectors,
    /// wavelength, background, domain, solver, output shape and locked elements are the
    /// puzzle's.
    private func admits(_ after: FringeDocument, from before: FringeDocument) -> Bool {
        guard mode == .puzzles else { return true }
        // The browser shows no document; nothing edits the parked simulator scene.
        guard let puzzle = puzzles.session?.puzzle else { return false }
        guard after.output == before.output, puzzle.allowsChange(from: before.scene, to: after.scene) else {
            showNotice("This is fixed by the puzzle")
            return false
        }
        // No change may add a part the palette has no room for: a duplicate, an extra kind,
        // a material the puzzle does not offer. Breaches already there may stay.
        let old = puzzle.paletteBreaches(of: puzzle.design(in: before.scene))
        let new = puzzle.paletteBreaches(of: puzzle.design(in: after.scene))
        if old.isExceeded(by: new) {
            showNotice(puzzle.breachNotice(from: old, to: new))
            return false
        }
        return true
    }

    /// Replaces the whole document outside undo, and clears this model's undo actions, so
    /// an undo can never put a document from the other mode (or another puzzle) back.
    func replaceDocument(_ new: FringeDocument, selection: SidebarItem) {
        undoManager?.removeAllActions(withTarget: self)
        lastEdit = nil
        trackingSnapshot = nil
        trackingDepth = 0
        viewOverride = nil
        hover = nil
        document = new
        self.selection = selection
        enforceShapeLock()
    }

    /// Writes the document with no undo step and no puzzle check: switching a puzzle's
    /// inputs.
    func setDocumentQuietly(_ new: FringeDocument) {
        guard new != document else { return }
        document = new
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
        // A drag that ended without `flushLiveEdit` (a mode switch ends every drag) must not
        // leave the check report held.
        if solver.holdsReport { solver.holdsReport = false }
        registerUndo(name, restoring: before)
        solver.update(scene: scene, tracking: false)
    }

    private func registerUndo(_ name: String, restoring snapshot: FringeDocument) {
        guard snapshot != document, let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                let current = model.document
                var restored = snapshot
                // A puzzle's inputs are not part of undo: they stay as they are.
                if model.mode == .puzzles, let puzzle = model.puzzles.session?.puzzle {
                    for id in puzzle.inputs { restored.scene[source: id]?.enabled = current.scene[source: id]?.enabled ?? true }
                }
                restored.display.isPlaying = current.display.isPlaying
                if current.display.isPlaying { model.playbackPhase = restored.display.phaseDeg }
                model.lastEdit = nil
                if model.mode == .simulator { model.persistsDocument = true }
                model.document = restored
                model.enforceShapeLock()
                model.dropMissingSelection()
                model.registerUndo(name, restoring: current)
            }
        }
        undoManager.setActionName(name)
    }

    /// After an undo: a selected item that no longer exists gives way to the
    /// wavelength and medium.
    func dropMissingSelection() {
        switch selection {
        case .source, .element, .detector:
            if selectedItem == nil { selection = .illumination }
        default:
            break
        }
    }

    // MARK: Reacting to changes

    private func documentChanged(from old: FringeDocument) {
        PerfProbe.count("doc.changed")
        // Any edit, input switch or display change first ends a running reveal; a design
        // change also drops the extras it left on the goal card.
        if reveal.isActive { reveal.skip() }
        if document.scene != old.scene { reveal.clearSettled() }
        refreshToolbarDocument()
        if canvasAspect != document.output.aspect { canvasAspect = document.output.aspect }
        refreshSubtitle()
        if document.scene != old.scene {
            if document.scene.elements != old.scene.elements || document.scene.sources != old.scene.sources
                || document.scene.detectors != old.scene.detectors || document.scene.domain != old.scene.domain || document.scene.wavelengthUm != old.scene.wavelengthUm
                || document.scene.background != old.scene.background {
                PerfProbe.count("doc.outlinesRebuilt")
                outlines = FringeBridge.outlines(document.scene)
            }
            solver.update(scene: document.scene, tracking: isTracking)
            if document.scene.detectors != old.scene.detectors { refreshReadings() }
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
        // A puzzle's domain is part of its scoring: the image follows it, never the reverse.
        if mode == .puzzles { return }
        let aspect = doc.output.aspect.ratio ?? windowAspect
        if abs(doc.scene.domain.aspect - aspect) > 1e-9 * aspect {
            doc.applyShapeLock(imageAspect: aspect)
        }
    }

    /// Under the Window aspect: the domain follows the canvas shape once the resize is
    /// over, never per size step.
    private func scheduleShapeLock() {
        shapeLockTask?.cancel()
        guard !isLiveResizing else { return }
        shapeLockTask = Task { [weak self] in
            try? await Task.sleep(for: AppState.shapeLockDelay)
            guard !Task.isCancelled else { return }
            self?.applyPendingShapeLock()
        }
    }

    private func applyPendingShapeLock() {
        shapeLockTask?.cancel()
        shapeLockTask = nil
        guard document.output.aspect == .window else { return }
        enforceShapeLock()
    }

    /// Applies the shape lock outside an edit, for a window resize under the Window aspect.
    private func enforceShapeLock() {
        var doc = document
        lockShape(&doc)
        if doc != document { PerfProbe.count("canvas.shapeLock"); document = doc }
    }

    private func solveResultChanged() {
        if hasShownResult != (solver.shown != nil) { hasShownResult = solver.shown != nil }
        // Profiles of any other field go now, even with the results hidden: a freed field's
        // identifier can be reused by the next one, and its old profile would pass as current.
        let current = solver.shown.map { ObjectIdentifier($0.field) }
        for old in profiles.keys where old.field != current { profiles[old] = nil }
        for (old, task) in profileTasks where old.field != current {
            task.cancel()
            profileTasks[old] = nil
        }
        if let shown = solver.shown {
            if shown.field !== shownOutlinesField {
                shownOutlinesField = shown.field
                shownOutlines = FringeBridge.outlines(shown.scene)
            }
        } else {
            shownOutlinesField = nil
            shownOutlines = nil
        }
        refreshReadings()
        scheduleRender()
        if exportAfterFinal, !solver.isRunning {
            exportAfterFinal = false
            if let shown = solver.shown, shown.quality == .final, !solver.isShownStale {
                isExporterPresented = true
            }
        }
    }

    /// Removes the notice at once: a mode switch takes it away with the mode it was about.
    public func clearNotice() {
        noticeTask?.cancel()
        noticeTask = nil
        notice = nil
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
        // The GPU viewport follows the model itself; the CPU renderer is the fallback.
        guard viewportUsesCPU else { return }
        PerfProbe.count("render.schedule")
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
        PerfProbe.count("legend.lutMiss")
        let lut = FringeBridge.colormapLUT(name, wavelengthUm: wavelength)
        lutCache = (name, wavelength, lut)
        return lut
    }

    /// The canvas overlays. Outlines, handles and the source glyph follow the scene being
    /// edited; conductors are filled where the shown field was solved with them.
    /// It does not read the animated phase, which the overlays don't draw, so playback
    /// does not redraw them every frame.
    public func overlayModel(viewRect: RectUm) -> OverlayModel {
        PerfProbe.time("overlay.model") { overlayModelBody(viewRect: viewRect) }
    }

    private func overlayModelBody(viewRect: RectUm) -> OverlayModel {
        OverlayModel(
            viewRect: viewRect,
            interior: interiorRect,
            pmlUm: pmlUm,
            outlines: outlines,
            sources: scene.sources,
            detectors: scene.detectors,
            detectorLabels: detectorLabels,
            readingsStale: readingsAreStale,
            focusPoints: paraxialFocusPoints,
            focusIDs: paraxialFocusIDs,
            display: display,
            caption: caption,
            legend: display.showLegend && !showsDarkCase ? Legend(lut: legendLUT, display: display) : nil,
            selection: overlaySelection,
            showsHandles: true,
            anchors: Dictionary(scene.elements.map { ($0.id, [$0.xUm, $0.yUm]) }, uniquingKeysWith: { a, _ in a }),
            conductors: solver.shown == nil ? outlines : shownOutlines,
            puzzle: puzzleOverlay
        )
    }

    /// The selection as the overlays draw it.
    private var overlaySelection: OverlaySelection? {
        switch selectedItem {
        case .element(let id)?: return .element(id)
        case .source(let id)?: return .source(id)
        case .detector(let id)?: return .detector(id)
        case nil: return nil
        }
    }

    /// "Output 0.82×" for each enabled detector: its name and, after a solve, its reading.
    var detectorLabels: [String: String] {
        var labels: [String: String] = [:]
        for detector in scene.detectors where detector.enabled {
            var label = MathTypesetter.escaped(detector.displayName)
            if let scored = scoredLabel(detector.id) {
                // A checked case: the value the puzzle scores, as the table shows it.
                label += "  " + scored
            } else if activePuzzle?.goalDetectorIDs.contains(detector.id) == true {
                // A goal detector shows no number before a Check (or before the reveal's
                // verdict): the Check reveals it. Just the name.
            } else if let reading = detectorReadings[detector.id], let summary = readingSummary(reading) {
                label += "  " + summary
            }
            labels[detector.id] = label
        }
        return labels
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
            // Disabled sources and detectors are not part of the result; the readings are
            // those of the current detectors on the shown field, as on screen.
            sources: source.sources.filter(\.enabled),
            detectors: scene.detectors.filter(\.enabled),
            detectorLabels: detectorLabels,
            readingsStale: stale,
            focusPoints: stale ? shownSceneFocusPoints : paraxialFocusPoints,
            display: display,
            caption: caption,
            legend: display.showLegend ? Legend(lut: lut, display: display) : nil,
            selection: nil,
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
        Self.focus(in: scene, derived: checkReport?.derived).map(\.point)
    }

    /// The elements `paraxialFocusPoints` belong to, in the same order.
    var paraxialFocusIDs: [String] {
        Self.focus(in: scene, derived: checkReport?.derived).map(\.id)
    }

    private static func focusPoints(in scene: SimScene, derived: Derived?) -> [[Double]] {
        focus(in: scene, derived: derived).map(\.point)
    }

    private static func focus(in scene: SimScene, derived: Derived?) -> [(id: String, point: [Double])] {
        guard let derived else { return [] }
        var points: [(id: String, point: [Double])] = []
        for element in scene.elements where element.enabled {
            guard let info = derived.element(element.id) else { continue }
            if let focus = info.lens?.paraxialFocusUm, focus.count == 2 {
                points.append((element.id, focus))
            } else if let f = info.mirror?.focalUm, f > 0 {
                // The mirror faces −x in its own frame.
                let a = element.rotationDeg * .pi / 180
                points.append((element.id, [element.xUm - f * cos(a), element.yUm - f * sin(a)]))
            }
        }
        return points
    }

    /// "FDTD · $\lambda$ 1.00 µm · 24/$\lambda$ · final · 3.1 s", with "not converged" when it
    /// applies. The math is typeset on the canvas; `MathTypesetter.plain` gives the plain form.
    public var caption: String? {
        guard let shown = solver.shown, !showsDarkCase else { return nil }
        let info = shown.info
        var parts = [
            info.method.title,
            #"$\lambda$ "# + "\(SceneFormat.fixed(info.wavelengthUm, 2)) µm",
            "\(Format.number(info.meta.ppw, digits: 0...1))/" + #"$\lambda$"#,
            // A case combined from a Check's fields is what the Check scored.
            showsCheckedCase ? "checked" : info.quality.rawValue,
        ]
        if info.quality == .final { parts.append(SceneFormat.seconds(info.meta.wallS)) }
        if !info.meta.converged { parts.append("not converged") }
        return parts.joined(separator: " · ")
    }

    // MARK: Persistence

    /// The simulator's document, wherever it is: the window's document in simulator mode,
    /// the parked one in puzzle mode.
    public var simulatorDocument: FringeDocument {
        mode == .simulator ? document : parkedSimulator?.document ?? document
    }

    private func schedulePersist() {
        // In a puzzle the document is the puzzle's: only the player's elements are kept,
        // and the saved simulator document stays as it is.
        if mode == .puzzles {
            if let puzzle = puzzles.session?.puzzle {
                puzzles.saveDesign(puzzle.design(in: document.scene), for: puzzle.id)
            }
            return
        }
        persistTask?.cancel()
        guard persistsDocument else { return }
        PerfProbe.count("doc.persistScheduled")
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Saves the simulator document (never a puzzle's) and any pending puzzle design.
    public func saveNow() {
        persistTask?.cancel()
        puzzles.flushDesign()
        do {
            let data = try PerfProbe.time("doc.save") { try JSONEncoder().encode(simulatorDocument) }
            UserDefaults.standard.set(data, forKey: Self.documentKey)
        } catch {
            Self.log.error("Could not save the document: \(error.localizedDescription)")
        }
    }

    /// Where the app saved its document while it was called Beam.
    private static let legacyDomain = "com.asympton.beam-bg"
    /// Off in the offscreen shot harness, so a Beam document on the machine does not
    /// replace the scene a shot asks for.
    static var readsLegacyDocument = true
    private static let legacyDocumentKey = "beam.document.v2"

    /// Set when the saved document could not be read at launch, so the window can say so.
    private static var savedDocumentWasUnreadable = false

    private static func restoredDocument() -> FringeDocument? {
        savedDocumentWasUnreadable = false
        let defaults = UserDefaults.standard
        var current = defaults.data(forKey: documentKey)
        let previous = defaults.data(forKey: previousDocumentKey)
        if current == nil, previous == nil, readsLegacyDocument,
           let legacy = UserDefaults(suiteName: legacyDomain)?.data(forKey: legacyDocumentKey) {
            // Copied once, before any launch override applies; the old domain is left as it was.
            defaults.set(legacy, forKey: documentKey)
            current = legacy
        }
        if let current {
            do {
                return try JSONDecoder().decode(FringeDocument.self, from: current)
            } catch {
                // Kept once, as the next save replaces it; then the v2 document, if any.
                if defaults.data(forKey: unreadableDocumentKey) == nil {
                    defaults.set(current, forKey: unreadableDocumentKey)
                }
                savedDocumentWasUnreadable = true
                log.error("The saved document could not be read: \(error.localizedDescription)")
            }
        }
        guard let previous else { return nil }
        do {
            return try JSONDecoder().decode(FringeDocument.self, from: previous)
        } catch {
            log.error("The previous saved document could not be read, starting from the default scene: \(error.localizedDescription)")
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
        if scene[element: copy.id] != nil { selection = .element(copy.id) }
    }

    public func deleteSelectedElement() {
        guard let id = selectedElementID else { return }
        deleteElement(id)
    }

    public func deleteElement(_ id: String) {
        edit("Delete Element") { $0.scene[element: id] = nil }
        if case .element(let selected) = selection, selected == id { selection = .illumination }
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
            if mode == .simulator { persistsDocument = true }
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

    public func stepPhase(by degrees: Double) {
        var phase = (display.phaseDeg + degrees).truncatingRemainder(dividingBy: 360)
        if phase < 0 { phase += 360 }
        edit("Change Phase", coalescingKey: "phase") { $0.display.phaseDeg = phase }
    }

    // MARK: Scenes and templates

    /// Replaces the scene, keeping its domain shape by switching the output aspect to match.
    public func loadScene(_ newScene: SimScene, name: String, suggested: ExampleInfo? = nil) {
        guard mode == .simulator else { return }
        edit(name) { doc in
            doc.scene = newScene
            doc.adoptDomainAspect()
            if let suggested { LaunchOptions.applySuggestedDisplay(suggested, to: &doc.display) }
        }
        selection = newScene.sources.first.map { .source($0.id) } ?? .illumination
        showResultsForLoadedDetectors(onlyOnce: false)
    }

    public func loadExample(_ info: ExampleInfo) {
        guard let scene = FringeBridge.example(info.name) else { return }
        loadScene(scene, name: "Open Template", suggested: info)
    }

    public func openScene(at url: URL) {
        guard mode == .simulator else { return }
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

    /// Saves the shown part as a single .npz: the sandbox lets the app write only the
    /// file chosen in the panel, so there is no sidecar or temporary sibling.
    public func exportFieldData() {
        guard let shown = solver.shown else {
            exportErrorMessage = "There is no solved field to export yet."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "npz") ?? .data]
        panel.nameFieldStringValue = "fringe-\(shown.info.method.rawValue)-\(display.part.rawValue).npz"
        panel.message = "Saves the \(display.part.title.lowercased()) field as complex numbers in a NumPy archive, with its x and y coordinates and the run info."
        let part = display.part
        let field = shown.field
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                self?.isExporting = true
                Task {
                    let error = await Task.detached(priority: .userInitiated) { () -> String? in
                        do {
                            // Foundation's atomic write stays inside the granted file's scope.
                            try field.npzData(part: part).write(to: url, options: .atomic)
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
        PerfProbe.time("hover.update") { updateHoverBody(at: point) }
    }

    // MARK: Live drags

    /// A drag step. The canvas shows `edit` at once. The solver gets the dragged scene at
    /// most every `liveSolveInterval` (its drag previews are rate-limited on their own) and
    /// the inspector's position fields at most every `liveInspectorInterval`; neither goes
    /// through the document, which takes the drag once, in `flushLiveEdit`. While the drag
    /// runs, the scene check's report reaches the views only when its verdict or issues
    /// change (`SolveController.holdsReport`). Call `flushLiveEdit` before `endTracking`.
    public func trackLive(_ edit: LiveEdit) {
        PerfProbe.count("drag.liveStep")
        if viewport.liveEdit != edit { viewport.liveEdit = edit }
        if !solver.holdsReport { solver.holdsReport = true }
        liveSolve.request(Self.liveSolveInterval) { [weak self] in self?.solveLiveEdit() }
        liveInspector.request(Self.liveInspectorInterval) { [weak self] in
            guard let self, let live = self.viewport.liveEdit, self.inspectorLive != live else { return }
            self.inspectorLive = live
        }
    }

    /// Writes the live drag into the document now, and ends it.
    public func flushLiveEdit() {
        liveSolve.cancel()
        liveInspector.cancel()
        commitLiveEdit()
        viewport.liveEdit = nil
        if inspectorLive != nil { inspectorLive = nil }
        if solver.holdsReport { solver.holdsReport = false }
        // A dragged detector was measured where the pointer had it; measure the document's.
        refreshReadings()
    }

    private func commitLiveEdit() {
        guard let edit = viewport.liveEdit else { return }
        PerfProbe.count("drag.commit")
        track { edit.apply(to: &$0) }
    }

    /// The solver sees the dragged scene without a document change; a dragged detector is
    /// measured where it is.
    private func solveLiveEdit() {
        guard let edit = viewport.liveEdit, isTracking else { return }
        var doc = document
        edit.apply(to: &doc)
        lockShape(&doc)
        guard doc.scene != document.scene, admitsQuietly(doc, from: document) else { return }
        PerfProbe.count("drag.solverUpdate")
        solver.update(scene: doc.scene, tracking: true)
        if case .detector = edit { refreshReadings() }
    }

    /// `value` of the item `id` as the inspector shows it: `inspectorLive` applied when it
    /// drags that item and `isLive` (the field is one the drag changes). Only then is
    /// `inspectorLive` read, so other fields do not follow the drag's updates.
    func inspectorValue<Item, Value>(_ item: Item?, id: String, _ keyPath: KeyPath<Item, Value>, isLive: Bool,
                                     apply: (LiveEdit, inout Item) -> Void) -> Value? {
        guard var item else { return nil }
        if isLive, let live = inspectorLive, live.itemID == id { apply(live, &item) }
        return item[keyPath: keyPath]
    }

    /// `admits` without its notices (the commit shows them).
    private func admitsQuietly(_ after: FringeDocument, from before: FringeDocument) -> Bool {
        guard mode == .puzzles else { return true }
        guard let puzzle = puzzles.session?.puzzle else { return false }
        return after.output == before.output && puzzle.allowsChange(from: before.scene, to: after.scene)
    }

    private func updateHoverBody(at point: CGPoint?) {
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
        // Like disabled elements, disabled sources and detectors are not part of the field,
        // so the readout does not name them.
        if let id = hitTestSource(x: plane.x, y: plane.y, includeDisabled: false), let source = scene[source: id] {
            readout.body = MathTypesetter.escaped(source.displayName)
        } else if let id = hitTestDetector(x: plane.x, y: plane.y, enabled: true), let detector = scene[detector: id] {
            var text = MathTypesetter.escaped(detector.displayName)
            // Same rule as detectorLabels: a goal detector shows only the scored value of a
            // checked case after the verdict, never its live reading.
            if let scored = scoredLabel(id) {
                text += " (\(scored))"
            } else if activePuzzle?.goalDetectorIDs.contains(id) == true {
            } else if let reading = detectorReadings[id], let summary = readingSummary(reading) {
                text += " (\(summary))"
            }
            readout.body = text
        } else if let id = hitTestElement(x: plane.x, y: plane.y, tolerancePoints: 0, includeDisabled: false),
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

/// Runs an action at most once per interval: at once if the last run is long enough ago,
/// else once at the end of the interval (with whatever state is current then).
@MainActor
final class Throttle {
    private var last: ContinuousClock.Instant?
    private var pending: Task<Void, Never>?

    func request(_ interval: Duration, _ action: @escaping @MainActor () -> Void) {
        guard pending == nil else { return }
        let now = ContinuousClock.now
        if let last, now - last < interval {
            let wait = interval - (now - last)
            pending = Task { @MainActor [weak self] in
                try? await Task.sleep(for: wait)
                guard !Task.isCancelled, let self else { return }
                self.pending = nil
                self.last = .now
                action()
            }
            return
        }
        last = now
        action()
    }

    func cancel() {
        pending?.cancel()
        pending = nil
        last = nil
    }
}
