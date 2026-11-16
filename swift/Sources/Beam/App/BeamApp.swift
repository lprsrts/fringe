import AppKit
import SwiftUI

@main
struct BeamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @UIState private var model = AppState()

    var body: some Scene {
        Window("Beam", id: "main") {
            BeamWindow()
                .environment(model)
        }
        .defaultSize(width: 1320, height: 820)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands {
            ToolbarCommands()
            BeamCommands(model: model)
            SidebarCommands()
            InspectorCommands()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Without a bundle, as under `swift run`, the app would get no Dock icon or menu bar.
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
