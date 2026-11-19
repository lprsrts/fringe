import AVFoundation
import Foundation
import Observation
import os

// Plays SoundScores (design 4.2). One AVAudioEngine with one AVAudioSourceNode (stereo Float32 at
// the device rate) whose render callback runs SynthRenderer: a preallocated voice bank fed by a
// single-producer, single-consumer ring of 64 commands. Nothing exists until the first prewarm or
// play while sound is allowed; once no voice has sounded for 4 s the engine stops, and the next
// prewarm (at the Check press) starts it again. A configuration or device change tears the graph
// down and the next use rebuilds it. Any error is logged once and sound becomes a no-op for the
// session: sound can never break a Check.

@MainActor
final class SoundEngine {
    nonisolated private static let log = Logger(subsystem: "com.asympton.fringe", category: "sound")
    /// The engine stops once nothing has sounded for this long.
    private static let idleDelay: Duration = .seconds(4)
    /// While voices sound, the idle check looks again this often (main actor, a few seconds
    /// after each reveal at most).
    private static let idleRecheck: Duration = .milliseconds(500)

    /// How the engine is run, fixed at launch.
    enum Output: Sendable {
        /// Plays through the sound-effects device.
        case normal
        /// Never builds the engine or plays anything (`--sound off`: scripted runs, shots).
        case off
        /// Runs the engine and its render callback as usual, with the mixer's output at 0, so
        /// a harness can measure it without a sound (`--sound mute`).
        case muted
    }

    let settings: SoundSettings
    let systemPreferences: SystemSoundPreferences
    let output: Output
    /// Engine life-cycle events ("build", "start", "stop", "teardown"), for the perf probe.
    var onLifecycle: ((String) -> Void)?

    private var engine: AVAudioEngine?
    private var source: AVAudioSourceNode?
    private var renderer: SynthRenderer?
    private var configurationObserver: (any NSObjectProtocol)?
    private var idleTask: Task<Void, Never>?
    private var batch: UInt32 = 0
    private var failed = false
    private var loggedRingFull = false
    /// When a voice was last seen sounding (or a score was last handed over).
    private var lastSounding = ContinuousClock.now
    private var wasSounding = false

    init(settings: SoundSettings, systemPreferences: SystemSoundPreferences? = nil, output: Output = .normal) {
        let preferences = systemPreferences ?? SystemSoundPreferences()
        self.settings = settings
        self.systemPreferences = preferences
        self.output = output
        preferences.onSystemOutputDeviceChange = { [weak self] in self?.handleConfigurationChange() }
        observeSettings()
    }

    isolated deinit {
        idleTask?.cancel()
        tearDown()
        systemPreferences.stopObservingOutputDevice()
        renderer?.deallocate()
        renderer = nil
    }

    // MARK: Public

    /// The effective rule of design 3.3, with the system preference read now, and no earlier
    /// engine failure in this session.
    var isAllowed: Bool { output != .off && !failed && settings.isSoundAllowed(for: .puzzle) }

    /// Builds and starts the engine if sound is allowed, so the first reveal sound is not late.
    /// Call it at the Check press, where the solve hides the start-up.
    func prewarm() {
        guard isAllowed else { return }
        _ = ensureRunning()
    }

    /// Plays a score now: its t = 0 is the first render callback after this call.
    func play(_ score: SoundScore, purpose: SoundSettings.Purpose = .puzzle) {
        guard !score.isEmpty, output != .off, !failed, settings.isSoundAllowed(for: purpose) else { return }
        guard ensureRunning(), let r = renderer else { return }
        r.setMasterGain(settings.masterGain)
        batch &+= 1
        if batch == 0 { batch = 1 }
        if r.ring.freeCount < score.notes.count, !loggedRingFull {
            loggedRingFull = true
            Self.log.error("Sound queue full; \(score.notes.count, privacy: .public) notes did not all fit")
        }
        for note in score.notes {
            var n = note.sanitized()
            n.batch = batch
            if !r.ring.push(SynthCommand(op: .play, note: n)) { break }
        }
        lastSounding = .now
        wasSounding = true
        // Follow the voices while they sound, so the stop counts from the last one.
        scheduleIdleCheck(after: Self.idleRecheck)
    }

    /// Fades every sounding voice out over `seconds` and drops notes that have not started.
    func fadeOutAll(_ seconds: Double = 0.06) {
        guard let engine, engine.isRunning, let r = renderer else { return }
        r.ring.push(SynthCommand(op: .fadeOutAll, seconds: seconds))
    }

    /// Skipping a reveal: all voices fade out in 60 ms, then the verdict tone plays.
    func skip(_ input: SoundRevealInput) {
        fadeOutAll(0.06)
        play(SoundPalette.skipTone(for: input))
    }

    /// Seconds between handing audio to the engine and hearing it, for the visual clock offset.
    var outputLatency: Double {
        guard let engine else { return 0 }
        let latency = engine.outputNode.presentationLatency
        return latency.isFinite ? min(max(latency, 0), 0.2) : 0
    }

    /// Whether the AVAudioEngine exists, and whether it runs (for the perf probe).
    var isEngineBuilt: Bool { engine != nil }
    var isEngineRunning: Bool { engine?.isRunning ?? false }
    /// Whether a voice sounds or waits to start, as of the last render callback.
    var isSounding: Bool {
        guard isEngineRunning, let r = renderer else { return false }
        return r.busyCount > 0 || !r.ring.isEmpty
    }

    // MARK: Engine life cycle

    private func ensureRunning() -> Bool {
        if failed { return false }
        if engine == nil { build() }
        guard let engine else { return false }
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                fail("start", error)
                return false
            }
            onLifecycle?("start")
        }
        lastSounding = .now
        scheduleIdleCheck(after: Self.idleDelay)
        return true
    }

    private func build() {
        let e = AVAudioEngine()
        let output = e.outputNode
        systemPreferences.routeToSystemOutput(output.auAudioUnit)
        systemPreferences.startObservingOutputDevice()
        let deviceRate = output.outputFormat(forBus: 0).sampleRate
        let rate = deviceRate.isFinite && deviceRate >= 8000 ? deviceRate : 48000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else {
            fail("format", nil)
            return
        }
        // The previous graph is stopped, so the render state can be reused or replaced safely.
        if let r = renderer, r.sampleRate == rate {
            r.bank.pointee.reset()
            while r.ring.peek() != nil { r.ring.advance() }
        } else {
            renderer?.deallocate()
            renderer = SynthRenderer.allocate(sampleRate: rate)
        }
        guard let r = renderer else { return }
        // The render loop reads these lazily initialised constants; initialise them here so
        // that never happens on the audio thread.
        _ = (SynthFieldMap.aMax, SynthFieldMap.aFloor, SynthFieldMap.atSilent)
        r.setMasterGain(settings.masterGain)
        let node = Self.makeSourceNode(renderer: r, format: format)
        e.attach(node)
        e.connect(node, to: e.mainMixerNode, format: format)
        if self.output == .muted { e.mainMixerNode.outputVolume = 0 }
        e.prepare()
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: e, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.handleConfigurationChange() }
        }
        engine = e
        source = node
        onLifecycle?("build")
    }

    /// The source node that runs `renderer` in its render callback. Internal so the offline check
    /// can drive the same node through AVAudioEngine's manual rendering mode.
    nonisolated static func makeSourceNode(renderer r: SynthRenderer, format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format, renderBlock: makeRenderBlock(r))
    }

    /// The render callback. Built outside the main actor so it carries no actor isolation: it runs
    /// on the audio thread and only touches the renderer's preallocated memory.
    nonisolated private static func makeRenderBlock(_ r: SynthRenderer) -> AVAudioSourceNodeRenderBlock {
        { _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count > 0, let left = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let right = buffers.count > 1 ? (buffers[1].mData?.assumingMemoryBound(to: Float.self) ?? left) : left
            r.render(frames: Int(frameCount), left: left, right: right)
            return noErr
        }
    }

    private func tearDown() {
        idleTask?.cancel()
        idleTask = nil
        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
            configurationObserver = nil
        }
        if let e = engine {
            e.stop()
            if let node = source { e.detach(node) }
            onLifecycle?("teardown")
        }
        source = nil
        engine = nil
    }

    private func handleConfigurationChange() {
        guard engine != nil else { return }
        tearDown()
    }

    private func fail(_ step: String, _ error: (any Error)?) {
        if !failed {
            Self.log.error("Sound is off for this session (\(step, privacy: .public)): \(error?.localizedDescription ?? "no format", privacy: .public)")
        }
        failed = true
        tearDown()
    }

    // MARK: Idle stop

    private func scheduleIdleCheck(after delay: Duration) {
        idleTask?.cancel()
        idleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.idleCheck()
        }
    }

    /// Stops the engine once no voice has sounded for `idleDelay`. While voices sound it looks
    /// every `idleRecheck`; the first look that finds them silent starts the 4 s, so the stop
    /// comes 4 to 4.5 s after the last voice ends.
    private func idleCheck() {
        idleTask = nil
        guard let engine, engine.isRunning, let r = renderer else { return }
        let now = ContinuousClock.now
        if r.busyCount > 0 || !r.ring.isEmpty {
            wasSounding = true
            scheduleIdleCheck(after: Self.idleRecheck)
        } else if wasSounding {
            // The first silent look: the last voice ended since the previous one.
            wasSounding = false
            lastSounding = now
            scheduleIdleCheck(after: Self.idleDelay)
        } else if now - lastSounding >= Self.idleDelay {
            engine.stop()
            onLifecycle?("stop")
        } else {
            scheduleIdleCheck(after: Self.idleDelay - (now - lastSounding))
        }
    }

    // MARK: Settings

    /// Follows the volume slider (smoothed in the render block) and fades out when sound is
    /// switched off mid-reveal. Observation only: nothing runs until a setting changes.
    private func observeSettings() {
        withObservationTracking {
            _ = settings.masterGain
            _ = settings.puzzleSoundsOn
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.renderer?.setMasterGain(self.settings.masterGain)
                if !self.settings.puzzleSoundsOn || self.settings.masterGain == 0 { self.fadeOutAll(0.06) }
                self.observeSettings()
            }
        }
    }
}
