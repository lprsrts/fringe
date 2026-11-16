import AppKit
import SwiftUI

struct FringeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @UIState private var model = AppState()

    var body: some Scene {
        Window("Fringe", id: "main") {
            FringeWindow()
                .environment(model)
        }
        .defaultSize(width: 1440, height: 860)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands {
            ToolbarCommands()
            FringeCommands(model: model)
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
