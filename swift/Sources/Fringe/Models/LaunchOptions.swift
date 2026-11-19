import Foundation
import os

/// Scene and display overrides read from UserDefaults at launch, so a scripted run can open
/// the app on a given scene without any input (for screenshots). Each key can be set with
/// `defaults write com.asympton.fringe <Key> <value>` or passed as launch arguments,
/// `open Fringe.app --args -FringeLaunchScene double_slit -FringeLaunchQuality final`.
///
/// - `FringeLaunchScene`: an example name (`lens`, `nanojet`, `mie_pec`, …), a path to a
///   scene .json file, or scene JSON itself.
/// - `FringeLaunchSolver`: `fdtd`, `fem` or `mom`.
/// - `FringeLaunchQuality`: `preview` (default) or `final`, which runs a final solve at launch.
/// - `FringeLaunchQuantity`: `intensity`, `magnitude`, `real` or `phase`.
/// - `FringeLaunchColormap`: a colormap name, such as `inferno` or `rdbu`.
/// - `FringeLaunchPhase`: φ in degrees.
/// - `FringeLaunchSelection`: `illumination`, `source:N`, `element:N`, `detector:N` (N an
///   index), `simulation`, `display`, `output`, or a bare element index. `source` alone
///   selects the first source.
/// - `FringeLaunchMode`: `simulator` or `puzzles`.
/// - `FringeLaunchPuzzle`: a puzzle id to open in puzzle mode, such as `logic-xor`.
///
/// Overrides are not saved: after a launch with overrides, the saved document changes only
/// once the user edits.
///
/// Plain arguments for checking puzzle reveals: `--reveal-self-test` runs the reveal plan's
/// checks and exits (FringeMain), `--reveal-at <ms>` holds every reveal at that moment
/// instead of playing it, for screenshots, and `--sound off` keeps the app silent: no sound
/// engine is built, nothing plays and a long Run Final does not bounce the Dock icon.
/// `--sound mute` runs the sound engine with its output at 0, for the profiler.
struct LaunchOptions {
    /// `--reveal-at <ms>`, in seconds.
    static let revealAtSeconds: Double? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--reveal-at"), i + 1 < args.count,
              let ms = Double(args[i + 1]), ms.isFinite, ms >= 0 else { return nil }
        return ms / 1000
    }()

    /// `--sound off` or `--sound mute`. The test harnesses set it before the model exists.
    nonisolated(unsafe) static var sound: SoundEngine.Output = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--sound"), i + 1 < args.count else { return .normal }
        switch args[i + 1] {
        case "off": return .off
        case "mute": return .muted
        default: return .normal
        }
    }()

    private static let log = Logger(subsystem: "com.asympton.fringe", category: "launch")
    static let sceneKey = "FringeLaunchScene"
    static let solverKey = "FringeLaunchSolver"
    static let qualityKey = "FringeLaunchQuality"
    static let quantityKey = "FringeLaunchQuantity"
    static let colormapKey = "FringeLaunchColormap"
    static let phaseKey = "FringeLaunchPhase"
    static let selectionKey = "FringeLaunchSelection"
    static let modeKey = "FringeLaunchMode"
    static let puzzleKey = "FringeLaunchPuzzle"

    var scene: SimScene?
    var suggested: ExampleInfo?
    var solver: SolverMethod?
    var runFinal = false
    var quantity: Quantity?
    var colormap: ColormapName?
    var phaseDeg: Double?
    var selectionText: String?
    var mode: AppMode?
    var puzzleID: String?

    /// Whether any override changes the document (a selection alone does not).
    var hasOverrides: Bool {
        scene != nil || solver != nil || runFinal || quantity != nil || colormap != nil || phaseDeg != nil
    }

    static func read(examples: [ExampleInfo], defaults: UserDefaults = .standard) -> LaunchOptions {
        var options = LaunchOptions()
        if let text = defaults.string(forKey: sceneKey)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            if text.hasPrefix("{") {
                options.scene = try? SimScene.decode(json: text)
            } else if let info = examples.first(where: { $0.name == text }) {
                options.scene = FringeBridge.example(info.name)
                options.suggested = info
            } else {
                let path = (text as NSString).expandingTildeInPath
                options.scene = (try? String(contentsOfFile: path, encoding: .utf8)).flatMap { try? SimScene.decode(json: $0) }
            }
            if options.scene == nil {
                log.error("\(sceneKey) \(text, privacy: .public) is not an example, a readable scene file or scene JSON")
            }
        }
        options.solver = defaults.string(forKey: solverKey).flatMap(SolverMethod.init(rawValue:))
        options.runFinal = defaults.string(forKey: qualityKey) == "final"
        options.quantity = defaults.string(forKey: quantityKey).flatMap(Quantity.init(rawValue:))
        options.colormap = defaults.string(forKey: colormapKey).flatMap(ColormapName.init(rawValue:))
        if defaults.object(forKey: phaseKey) != nil {
            options.phaseDeg = defaults.double(forKey: phaseKey)
        }
        options.selectionText = defaults.string(forKey: selectionKey)
        options.puzzleID = defaults.string(forKey: puzzleKey)
        options.mode = defaults.string(forKey: modeKey).flatMap(AppMode.init(rawValue:))
            ?? (options.puzzleID != nil ? .puzzles : nil)
        return options
    }

    func apply(to document: inout FringeDocument) {
        if let scene {
            document.scene = scene
            document.adoptDomainAspect()
            if let suggested { Self.applySuggestedDisplay(suggested, to: &document.display) }
        }
        if let solver { document.scene.solver.method = solver }
        if let quantity { document.display.quantity = quantity }
        if let colormap, colormap.kind == document.display.quantity.colormapKind {
            document.display.colormap = colormap
        }
        if let phaseDeg { document.display.phaseDeg = phaseDeg }
    }

    func selection(in scene: SimScene) -> SidebarItem? {
        switch selectionText {
        case "illumination": return .illumination
        case "source": return scene.sources.first.map { .source($0.id) }
        case "simulation": return .simulation
        case "display": return .display
        case "output": return .output
        case let text?:
            let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, let index = Int(parts[1]) {
                switch parts[0] {
                case "source": return scene.sources.indices.contains(index) ? .source(scene.sources[index].id) : nil
                case "element": return scene.elements.indices.contains(index) ? .element(scene.elements[index].id) : nil
                case "detector": return scene.detectors.indices.contains(index) ? .detector(scene.detectors[index].id) : nil
                default: return nil
                }
            }
            if let index = Int(text), scene.elements.indices.contains(index) {
                return .element(scene.elements[index].id)
            }
            return nil
        case nil:
            return nil
        }
    }

    /// An example's suggested quantity and colormap.
    static func applySuggestedDisplay(_ info: ExampleInfo, to display: inout DisplaySettings) {
        if let quantity = info.quantity.flatMap(Quantity.init(rawValue:)) {
            display.quantity = quantity
        }
        if let colormap = info.colormap.flatMap(ColormapName.init(rawValue:)), colormap.kind == display.quantity.colormapKind {
            display.colormap = colormap
        }
    }
}
