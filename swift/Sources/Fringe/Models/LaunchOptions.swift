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
/// - `FringeLaunchSelection`: `source`, `simulation`, `display`, `output`, or an element index.
///
/// Overrides are not saved: after a launch with overrides, the saved document changes only
/// once the user edits.
struct LaunchOptions {
    private static let log = Logger(subsystem: "com.asympton.fringe", category: "launch")
    static let sceneKey = "FringeLaunchScene"
    static let solverKey = "FringeLaunchSolver"
    static let qualityKey = "FringeLaunchQuality"
    static let quantityKey = "FringeLaunchQuantity"
    static let colormapKey = "FringeLaunchColormap"
    static let phaseKey = "FringeLaunchPhase"
    static let selectionKey = "FringeLaunchSelection"

    var scene: SimScene?
    var suggested: ExampleInfo?
    var solver: SolverMethod?
    var runFinal = false
    var quantity: Quantity?
    var colormap: ColormapName?
    var phaseDeg: Double?
    var selectionText: String?

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
        case "source": return .source
        case "simulation": return .simulation
        case "display": return .display
        case "output": return .output
        case let text?:
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
