import AppKit
import Observation

// The Sound settings (design 3.1 and 3.3), stored in UserDefaults.standard. The Settings pane,
// the View menu's "Puzzle Sounds" item and SoundEngine all read this one object.

@MainActor
@Observable
final class SoundSettings {
    enum Key {
        static let puzzleSounds = "fringe.sound.puzzles"
        static let volume = "fringe.sound.volume"
        static let finalSolve = "fringe.sound.finalSolve"
        static let ignoreSystem = "fringe.sound.ignoreSystem"
        static let animateResults = "fringe.reveal.animate"
    }

    /// What a sound is for: puzzle reveals and toggles, or the simulator's opt-in final-solve tone.
    enum Purpose: Sendable { case puzzle, finalSolve }

    nonisolated static let defaultVolume = 0.5

    /// "Play sounds in puzzles", default on.
    var puzzleSoundsOn: Bool {
        didSet { defaults.set(puzzleSoundsOn, forKey: Key.puzzleSounds) }
    }

    /// The Volume slider, 0…1, default 0.5. 0 mutes.
    var volume: Double {
        didSet {
            let v = Self.clampVolume(volume)
            if v != volume { volume = v }
            defaults.set(v, forKey: Key.volume)
        }
    }

    /// "Sound when a final solve finishes", default off.
    var finalSolveSoundOn: Bool {
        didSet { defaults.set(finalSolveSoundOn, forKey: Key.finalSolve) }
    }

    /// "Play anyway" when the system's sound effects are off, default off.
    var ignoreSystemSetting: Bool {
        didSet { defaults.set(ignoreSystemSetting, forKey: Key.ignoreSystem) }
    }

    /// "Animate puzzle results", default on. Off gives the instant reveal.
    var animateResults: Bool {
        didSet { defaults.set(animateResults, forKey: Key.animateResults) }
    }

    @ObservationIgnored private let defaults: UserDefaults
    /// Shots: the system preference as if read, instead of reading it.
    var systemForTesting: SystemUISoundsSetting?

    /// "Play user interface sound effects" as the app sees it now.
    var system: SystemUISoundsSetting {
        _ = systemChanges
        return systemForTesting ?? SystemSoundPreferences.readUISounds()
    }

    /// Bumped when the system preference reads differently on app activation (the user may have
    /// changed it in System Settings), so an open Settings pane redraws.
    private var systemChanges = 0
    @ObservationIgnored private var lastSystem: SystemUISoundsSetting?
    @ObservationIgnored private var activation: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        puzzleSoundsOn = defaults.object(forKey: Key.puzzleSounds) as? Bool ?? true
        volume = Self.clampVolume(defaults.object(forKey: Key.volume) as? Double ?? Self.defaultVolume)
        finalSolveSoundOn = defaults.object(forKey: Key.finalSolve) as? Bool ?? false
        ignoreSystemSetting = defaults.object(forKey: Key.ignoreSystem) as? Bool ?? false
        animateResults = defaults.object(forKey: Key.animateResults) as? Bool ?? true
        lastSystem = SystemSoundPreferences.readUISounds()
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemMayHaveChanged() }
        }
    }

    isolated deinit {
        if let activation { NotificationCenter.default.removeObserver(activation) }
    }

    private func systemMayHaveChanged() {
        let now = SystemSoundPreferences.readUISounds()
        guard now != lastSystem else { return }
        lastSystem = now
        systemChanges += 1
    }

    /// The slider's gain relative to the calibrated default: 24·(v − 0.5) dB, so −12…+12 dB.
    /// Nil at v = 0 (muted).
    nonisolated static func gainDB(volume: Double) -> Double? {
        let v = clampVolume(volume)
        return v > 0 ? 24 * (v - 0.5) : nil
    }

    /// Linear master gain for the engine; 1 is the calibrated default, 0 is muted.
    nonisolated static func masterGain(volume: Double) -> Double {
        gainDB(volume: volume).map { pow(10, $0 / 20) } ?? 0
    }

    var masterGain: Double { Self.masterGain(volume: volume) }

    /// The effective rule of design 3.3:
    /// on && volume > 0 && (system UI sounds on || "Play anyway" || the system key unreadable).
    func isSoundAllowed(for purpose: Purpose, system: SystemUISoundsSetting) -> Bool {
        let on = purpose == .puzzle ? puzzleSoundsOn : finalSolveSoundOn
        return on && volume > 0 && (system.isEnabled || ignoreSystemSetting || !system.isReadable)
    }

    /// The same rule with the system preference read now (it is read at each reveal start).
    func isSoundAllowed(for purpose: Purpose = .puzzle) -> Bool {
        isSoundAllowed(for: purpose, system: system)
    }

    /// Whether Settings shows the footnote and "Play anyway": only when the system key could be
    /// read and says sound effects are off.
    var isBlockedBySystem: Bool {
        let system = self.system
        return system.isReadable && !system.isEnabled
    }

    nonisolated private static func clampVolume(_ v: Double) -> Double {
        v.isFinite ? min(1, max(0, v)) : defaultVolume
    }
}
