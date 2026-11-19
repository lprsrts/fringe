import AppKit

// Puzzle sounds as the window uses them (design 1.7, 1.9, 3.2): a reveal's sound starts with
// its picture, a skip fades it and plays the verdict tone, switching inputs after a Check
// plays the case's tone, and a long Run Final can say it is done.
extension AppState {
    /// Run Final solves shorter than this finish without a signal.
    static let finalSolveSignalSeconds = 5.0

    func connectSound() {
        reveal.onBegin = { [weak self] plan in self?.playRevealSound(plan) }
        reveal.onSkip = { [weak self] plan, at in self?.revealSkipped(plan, at: at) }
        reveal.onCancel = { [weak self] in
            self?.revealSound = nil
            self?.sound.fadeOutAll()
        }
        reveal.onInvalidDesign = { [weak self] in self?.sound.play(SoundPalette.invalidDesign()) }
        reveal.onShowCheckedCase = { [weak self] _, values, wrong in self?.playToggleTone(values: values, wrong: wrong) }
        solver.onFinalFinished = { [weak self] seconds in self?.finalSolveFinished(seconds: seconds) }
        sound.onLifecycle = { event in PerfProbe.count("sound.engine." + event) }
    }

    /// At the Check press: start the audio engine while the solve runs, so the first tone is
    /// on time. Nothing sounds here.
    func prewarmSound() {
        sound.prewarm()
    }

    /// A reveal begins: its sound is scheduled now, and the picture waits for the output
    /// latency so that the two meet.
    private func playRevealSound(_ plan: RevealPlan) {
        revealSound = nil
        reveal.outputLatency = 0
        guard plan.options.soundOn, let puzzle = activePuzzle, puzzle.id == plan.puzzleID else { return }
        let input = SoundRevealInput(plan: plan, puzzle: puzzle)
        let score = SoundPalette.reveal(input)
        revealSound = input
        guard !score.isEmpty else { return }
        sound.play(score)
        reveal.outputLatency = sound.outputLatency
    }

    /// Before the verdict, all voices fade out in 60 ms and the verdict tone plays once. After
    /// it, the chord and the extras already sounding are left to ring out.
    private func revealSkipped(_ plan: RevealPlan, at t: Double) {
        lastRevealSkip = .now
        guard let input = revealSound else { return }
        revealSound = nil
        if t < plan.verdictAt { sound.skip(input) }
    }

    /// Switching inputs with a current Check: one tone per goal detector at the case's
    /// measured value, rough on a wrong output; the tap only on the first. Silent right after
    /// the switch's own click skipped a reveal, which already played the verdict tone.
    private func playToggleTone(values: [Double?], wrong: [Bool]) {
        if let skipped = lastRevealSkip, ContinuousClock.now - skipped < .milliseconds(250) { return }
        PerfProbe.count("sound.toggle")
        var score = SoundScore()
        for j in values.indices {
            var tone = SoundPalette.toggleTone(value: values[j] ?? 0, wrong: j < wrong.count && wrong[j], output: j)
            if j > 0 { for k in tone.notes.indices { tone.notes[k].tickAmp = 0 } }
            score.append(contentsOf: tone)
        }
        sound.play(score)
    }

    /// Run Final finished (design 3.2): after 5 s or more, the Dock icon bounces once if the
    /// app is in the background, and the opt-in tone plays either way. Silent under
    /// `--sound off`.
    private func finalSolveFinished(seconds: Double) {
        guard seconds >= Self.finalSolveSignalSeconds, sound.output != .off else { return }
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        sound.play(SoundPalette.finalSolveDone(), purpose: .finalSolve)
    }
}
