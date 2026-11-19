// Checks the AVFoundation side without a speaker: the settings' stored keys, volume map and
// effective rule, the system preference and device reads, and SoundEngine's real source node
// driven through AVAudioEngine's offline manual rendering mode (no output device is opened),
// compared sample for sample with SynthRenderer called directly.

import AVFoundation
import Foundation

var failures: [String] = []
func check(_ ok: Bool, _ what: String) { print("- \(ok ? "ok" : "FAIL"): \(what)"); if !ok { failures.append(what) } }

MainActor.assumeIsolated {
    let suite = "fringe.sound.offline-check.\(getpid())"
    let defaults = UserDefaults(suiteName: suite)!
    defer {
        // Removing the domain leaves an empty plist behind; remove that too.
        defaults.removePersistentDomain(forName: suite)
        CFPreferencesAppSynchronize(suite as CFString)
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Preferences/\(suite).plist")
        try? FileManager.default.removeItem(at: file)
    }
    let s = SoundSettings(defaults: defaults)
    check(s.puzzleSoundsOn && s.volume == 0.5 && !s.finalSolveSoundOn && !s.ignoreSystemSetting && s.animateResults,
          "defaults: puzzle sounds on, volume 0.5, final solve off, play anyway off, animate on")
    check(abs(s.masterGain - 1) < 1e-12, "volume 0.5 is the calibrated default (gain 1)")
    check(abs(SoundSettings.gainDB(volume: 1)! - 12) < 1e-12 && abs(SoundSettings.gainDB(volume: 0.25)! + 6) < 1e-12,
          "gain_dB = 24·(v − 0.5): v = 1 → +12 dB, v = 0.25 → −6 dB")
    check(SoundSettings.gainDB(volume: 0) == nil && SoundSettings.masterGain(volume: 0) == 0, "v = 0 mutes")
    s.volume = 7
    check(s.volume == 1 && defaults.double(forKey: SoundSettings.Key.volume) == 1, "volume clamps to 1 and is stored")
    s.puzzleSoundsOn = false
    check(defaults.object(forKey: SoundSettings.Key.puzzleSounds) as? Bool == false, "fringe.sound.puzzles stored")
    s.puzzleSoundsOn = true
    let off = SystemUISoundsSetting(isReadable: true, isEnabled: false)
    let unreadable = SystemUISoundsSetting(isReadable: false, isEnabled: false)
    let on = SystemUISoundsSetting(isReadable: true, isEnabled: true)
    check(s.isSoundAllowed(for: .puzzle, system: on), "allowed when system sound effects are on")
    check(!s.isSoundAllowed(for: .puzzle, system: off), "silent when system sound effects are off")
    check(s.isSoundAllowed(for: .puzzle, system: unreadable), "an unreadable system key is ignored")
    s.ignoreSystemSetting = true
    check(s.isSoundAllowed(for: .puzzle, system: off), "\"Play anyway\" overrides the system setting")
    check(!s.isSoundAllowed(for: .finalSolve, system: on), "final-solve sound is opt-in")
    s.volume = 0
    check(!s.isSoundAllowed(for: .puzzle, system: on), "volume 0 is silent")
    let fresh = SoundSettings(defaults: defaults)
    check(fresh.volume == 0 && fresh.ignoreSystemSetting, "settings read back from UserDefaults")

    // The engine is lazy: nothing is built by creating SoundEngine, and with `--sound off`
    // (Output.off) not even by a play. No sound can come from these checks: the default
    // engine is never asked to play.
    let lazy = SoundEngine(settings: fresh)
    check(!lazy.isEngineBuilt && !lazy.isEngineRunning, "creating SoundEngine builds no audio engine")
    s.volume = 0.5
    let silent = SoundEngine(settings: SoundSettings(defaults: defaults), output: .off)
    silent.prewarm()
    silent.play(SoundPalette.sample())
    check(!silent.isEngineBuilt && !silent.isAllowed, "with --sound off, prewarm and play build nothing")
    s.systemForTesting = off
    check(s.isBlockedBySystem && s.isSoundAllowed(for: .puzzle),
          "the Settings footnote shows when the system key reads off, and Play anyway (on here) lets sound through")
    s.systemForTesting = nil

    let ui = SystemSoundPreferences.readUISounds()
    print("- this machine: com.apple.sound.uiaudio.enabled readable \(ui.isReadable), enabled \(ui.isEnabled) (unsandboxed command-line read)")
    print("- this machine: system sound-effects device id \(SystemSoundPreferences.systemOutputDeviceID().map(String.init) ?? "unreadable")")
}

// The real source node in manual rendering mode.
do {
    let fs = 48000.0
    let format = AVAudioFormat(standardFormatWithSampleRate: fs, channels: 2)!
    let engine = AVAudioEngine()
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    let r = SynthRenderer.allocate(sampleRate: fs)
    let node = SoundEngine.makeSourceNode(renderer: r, format: format)
    engine.attach(node)
    engine.connect(node, to: engine.mainMixerNode, format: format)
    try engine.start()
    let score = SoundPalette.sample()
    for n in score.notes { var n = n.sanitized(); n.batch = 1; r.ring.push(SynthCommand(op: .play, note: n)) }
    let total = Int((score.end + 0.1) * fs)
    let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512)!
    var viaEngine: [Float] = []
    while viaEngine.count < total {
        let status = try engine.renderOffline(512, to: buffer)
        guard status == .success else { failures.append("renderOffline status \(status.rawValue)"); break }
        let l = buffer.floatChannelData![0], rr = buffer.floatChannelData![1]
        for i in 0..<Int(buffer.frameLength) { viaEngine.append(l[i]); viaEngine.append(rr[i]) }
    }
    engine.stop()
    r.deallocate()

    let d = SynthRenderer.allocate(sampleRate: fs)
    for n in score.notes { var n = n.sanitized(); n.batch = 1; d.ring.push(SynthCommand(op: .play, note: n)) }
    var L = [Float](repeating: 0, count: 512), R = L
    var direct: [Float] = []
    while direct.count < viaEngine.count {
        L.withUnsafeMutableBufferPointer { lb in R.withUnsafeMutableBufferPointer { rb in d.render(frames: 512, left: lb.baseAddress!, right: rb.baseAddress!) } }
        for i in 0..<512 { direct.append(L[i]); direct.append(R[i]) }
    }
    d.deallocate()
    var maxDiff: Float = 0, peak: Float = 0
    for i in 0..<min(direct.count, viaEngine.count) { maxDiff = max(maxDiff, abs(direct[i] - viaEngine[i])); peak = max(peak, abs(direct[i])) }
    let diffDB = maxDiff > 0 ? 20 * log10(Double(maxDiff / peak)) : -200
    check(peak > 0 && diffDB < -100, "AVAudioSourceNode through AVAudioEngine (manual rendering, 48 kHz stereo Float32) equals SynthRenderer: peak \(String(format: "%.1f", 20 * log10(Double(peak)))) dBFS, max difference \(diffDB <= -200 ? "0 (bit-exact)" : String(format: "%.1f dB re peak", diffDB))")
} catch {
    check(false, "manual rendering: \(error)")
}

exit(failures.isEmpty ? 0 : 1)
