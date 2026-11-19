import AppKit
import SwiftUI

/// Skipping a reveal (sound design §1.7, §4.4). While a reveal runs, an event monitor on
/// this window:
/// - Esc or Space, when the window is key and no text is being edited: skip, and the key
///   does nothing else;
/// - any other key with ⌘ or with ⌃⌥ (Check, menu commands, input switches): skip, then the
///   key does what it does;
/// - any mouse-down: skip, then the click does what it does, except on the goal card's score
///   bar, the reveal's own surface, where the click only skips.
/// VoiceOver starting during a reveal skips it too. Nothing is installed between reveals.
struct RevealSkipCatcher: NSViewRepresentable {
    let model: AppState

    func makeNSView(context: Context) -> RevealSkipCatcherView { RevealSkipCatcherView(reveal: model.reveal) }
    func updateNSView(_ view: RevealSkipCatcherView, context: Context) {}
}

final class RevealSkipCatcherView: NSView {
    private let reveal: RevealController
    private var monitor: Any?
    private var voiceOver: NSKeyValueObservation?

    init(reveal: RevealController) {
        self.reveal = reveal
        super.init(frame: .zero)
        observe()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Follows `reveal.plan` (set at the start and the end of a reveal only).
    private func observe() {
        withObservationTracking {
            _ = reveal.plan
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.observe()
                    self.update()
                }
            }
        }
        update()
    }

    private func update() {
        if reveal.isActive, window != nil {
            install()
        } else {
            remove()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        update()
    }

    private func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            // Local monitors run on the main thread.
            nonisolated(unsafe) let main = event
            let consumed = MainActor.assumeIsolated { self?.consumes(main) ?? false }
            return consumed ? nil : event
        }
        voiceOver = NSWorkspace.shared.observe(\.isVoiceOverEnabled, options: [.new]) { [weak self] _, change in
            guard change.newValue == true else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.reveal.skip() }
            }
        }
    }

    private func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        voiceOver?.invalidate()
        voiceOver = nil
    }

    /// Skips the reveal when `event` should; true when the event goes no further.
    private func consumes(_ event: NSEvent) -> Bool {
        guard reveal.isActive, let window, event.window === window else { return false }
        switch event.type {
        case .keyDown:
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53 || event.keyCode == 49, flags.isDisjoint(with: [.command, .control, .option]) {
                // Esc or Space: not while text is being edited.
                guard window.isKeyWindow, !(window.firstResponder is NSText) else { return false }
                reveal.skip()
                return true
            }
            if flags.contains(.command) || flags.isSuperset(of: [.control, .option]) {
                reveal.skip()
            }
            return false
        case .leftMouseDown:
            reveal.skip()
            if let bar = reveal.scoreBarFrame, let content = window.contentView {
                let p = event.locationInWindow
                let top = CGPoint(x: p.x, y: content.bounds.height - p.y)
                if bar.contains(top) { return true }
            }
            return false
        default:
            reveal.skip()
            return false
        }
    }
}
