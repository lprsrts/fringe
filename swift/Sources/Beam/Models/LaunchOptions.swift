import Foundation
import os

/// Scene and display overrides read from UserDefaults at launch, so a scripted run can open
/// the app on a given scene without any input (for screenshots). Each key can be set with
/// `defaults write com.asympton.beam-bg <Key> <value>` or passed as launch arguments,
/// `open Beam.app --args -BeamLaunchScene double_slit -BeamLaunchQuality final`.
///
/// - `BeamLaunchScene`: an example name (`lens`, `nanojet`, `mie_pec`, …), a path to a
///   scene .json file, or scene JSON itself.
/// - `BeamLaunchSolver`: `fdtd`, `fem` or `mom`.
/// - `BeamLaunchQuality`: `preview` (default) or `final`, which runs a final solve at launch.
/// - `BeamLaunchQuantity`: `intensity`, `magnitude`, `real` or `phase`.
/// - `BeamLaunchColormap`: a colormap name, such as `inferno` or `rdbu`.
/// - `BeamLaunchPhase`: φ in degrees.
/// - `BeamLaunchSelection`: `source`, `simulation`, `display`, `output`, or an element index.
///
/// Overrides are not saved: the saved document changes only when the user edits.
struct LaunchOptions {
    private static let log = Logger(subsystem: "com.asympton.beam-bg", category: "launch")
    static let sceneKey = "BeamLaunchScene"
    static let solverKey = "BeamLaunchSolver"
    static let qualityKey = "BeamLaunchQuality"
    static let quantityKey = "BeamLaunchQuantity"
    static let colormapKey = "BeamLaunchColormap"
    static let phaseKey = "BeamLaunchPhase"
    static let selectionKey = "BeamLaunchSelection"

    var scene: SimScene?
    var suggested: ExampleInfo?
    var solver: SolverMethod?
    var runFinal = false
    var quantity: Quantity?
    var colormap: ColormapName?
    var phaseDeg: Double?
    var selectionText: String?

    static func read(examples: [ExampleInfo], defaults: UserDefaults = .standard) -> LaunchOptions {
        var options = LaunchOptions()
        if let text = defaults.string(forKey: sceneKey)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            if text.hasPrefix("{") {
                options.scene = try? SimScene.decode(json: text)
            } else if let info = examples.first(where: { $0.name == text }) {
                options.scene = BeamBridge.example(info.name)
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

    func apply(to document: inout BeamDocument) {
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
