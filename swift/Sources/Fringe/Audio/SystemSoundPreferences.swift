import AudioToolbox
import CoreAudio
import Foundation
import os

// The system side of sound (design 3.3): the "Play user interface sound effects" preference and
// the output device macOS uses for sound effects, which may differ from the default output.
//
// Still to verify in a signed, sandboxed build: that the preference key returns the user's value
// rather than a container default, and that setDeviceID works on the sandboxed output unit. Both
// have fallbacks here: an unreadable key is reported as such (and then ignored by the effective
// rule), and a failed setDeviceID leaves the default output in place.

/// The "Play user interface sound effects" setting as far as the app can see it.
struct SystemUISoundsSetting: Sendable, Equatable {
    /// False when the global preferences could not be read; the setting is then ignored.
    var isReadable: Bool
    /// The user's choice; a missing key means on.
    var isEnabled: Bool
}

@MainActor
final class SystemSoundPreferences {
    nonisolated static let uiSoundsKey = "com.apple.sound.uiaudio.enabled"
    nonisolated private static let log = Logger(subsystem: "com.asympton.fringe", category: "sound")

    /// Called on the main thread when the system sound-effects device changes.
    var onSystemOutputDeviceChange: (@MainActor () -> Void)?

    private var listener: AudioObjectPropertyListenerBlock?
    private var loggedRoutingFailure = false

    init() {}

    isolated deinit {
        stopObservingOutputDevice()
    }

    // MARK: The preference

    /// Reads `com.apple.sound.uiaudio.enabled` (Int 0/1) from the global domain, or from
    /// `com.apple.systemsound`, where some macOS versions keep it. Readable means the key was
    /// found, or the global domain could be read at all (then a missing key is on).
    nonisolated static func readUISounds(defaults: UserDefaults = .standard) -> SystemUISoundsSetting {
        let global = defaults.persistentDomain(forName: UserDefaults.globalDomain)
        let systemSound = defaults.persistentDomain(forName: "com.apple.systemsound")
        let value = global?[uiSoundsKey] ?? systemSound?[uiSoundsKey] ?? defaults.object(forKey: uiSoundsKey)
        let readable = value != nil || !(global?.isEmpty ?? true)
        let enabled: Bool
        switch value {
        case let n as NSNumber: enabled = n.intValue != 0
        case let s as String: enabled = (Int(s) ?? 1) != 0
        default: enabled = true
        }
        return SystemUISoundsSetting(isReadable: readable, isEnabled: enabled)
    }

    // MARK: The output device

    nonisolated private static var deviceAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// The device macOS plays sound effects on, or nil if it cannot be read.
    nonisolated static func systemOutputDeviceID() -> AudioDeviceID? {
        var address = deviceAddress
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        guard status == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }

    /// Points an output unit at the sound-effects device. On failure the unit keeps the default
    /// output, the failure is logged once, and false is returned.
    @discardableResult
    func routeToSystemOutput(_ unit: AUAudioUnit) -> Bool {
        guard let id = Self.systemOutputDeviceID() else {
            logRoutingFailure("the system output device could not be read")
            return false
        }
        if unit.deviceID == id { return true }
        do {
            try unit.setDeviceID(id)
            return true
        } catch {
            logRoutingFailure("setDeviceID failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Starts listening for changes of the sound-effects device (a HAL property listener on the
    /// main queue). Calls `onSystemOutputDeviceChange`.
    func startObservingOutputDevice() {
        guard listener == nil else { return }
        let block = Self.makeListener { [weak self] in self?.onSystemOutputDeviceChange?() }
        var address = Self.deviceAddress
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        if status == noErr {
            listener = block
        } else {
            Self.log.error("Could not observe the system output device (\(status, privacy: .public))")
        }
    }

    func stopObservingOutputDevice() {
        guard let block = listener else { return }
        var address = Self.deviceAddress
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        listener = nil
    }

    /// Built outside the main actor so the block carries no actor isolation of its own; it runs
    /// on the main queue, where it hops onto the main actor.
    nonisolated private static func makeListener(_ handler: @escaping @MainActor @Sendable () -> Void)
        -> AudioObjectPropertyListenerBlock {
        { _, _ in
            MainActor.assumeIsolated { handler() }
        }
    }

    private func logRoutingFailure(_ message: String) {
        guard !loggedRoutingFailure else { return }
        loggedRoutingFailure = true
        Self.log.error("Sound uses the default output: \(message, privacy: .public)")
    }
}
