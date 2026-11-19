import AppKit
import Observation
import QuartzCore

/// Plays reveals: holds the running plan, keeps a clock while one runs (and only then), and
/// publishes its frame in parts, so each view is invalidated only by the part it reads: the
/// table cells by `cases`, the row highlight and canvas by `focus`, the score bar by
/// `meter`, the verdict lines by `stage`.
@MainActor
@Observable
final class RevealController {
    struct CaseState: Equatable {
        var values: [[Double?]] = []
        var dimmed: [Bool] = []
        var verdictShown: [Bool] = []
        var opacity: [Double] = []
    }

    struct FocusState: Equatable {
        var highlightedCase: Int?
        var canvasCase: Int?
        var inputsDimmed = false
    }

    struct MeterState: Equatable {
        var x: Double?
        var opacity = 1.0
        var starLand: [Double] = []
        var starsFadeOnly = false
        var bestScore: Double?
    }

    struct StageState: Equatable {
        var verdictOpacity = 0.0
        var extras: Set<RevealExtra> = []
        var showsAfterProgress = false
        var showSkipHint = false
        var shortfall: String?
    }

    /// The running reveal; nil when none runs (views then show the result as it is).
    private(set) var plan: RevealPlan?
    private(set) var cases = CaseState()
    private(set) var focus = FocusState()
    private(set) var meter = MeterState()
    private(set) var stage = StageState()
    /// The extras of the last reveal of `puzzleID`, still shown on the goal card after it
    /// ended, until the design changes or the puzzle closes.
    private(set) var settled: (puzzleID: String, extras: Set<RevealExtra>)?

    var isActive: Bool { plan != nil }
    /// False while a running reveal has not reached its verdict: the score is not shown yet.
    /// Its own property, so what reads it (the canvas labels) changes once per reveal.
    private(set) var scoreRevealed = true

    // Hooks for sound. Each runs on the main actor.
    /// A reveal begins (every kind, the instant ones too); sound schedules its score from the plan.
    @ObservationIgnored var onBegin: ((RevealPlan) -> Void)?
    /// A reveal was skipped `at` seconds in; sound fades out and plays the verdict tone.
    @ObservationIgnored var onSkip: ((_ plan: RevealPlan, _ at: Double) -> Void)?
    /// A reveal was dropped without its verdict (the puzzle closed, Reset); sound fades out.
    @ObservationIgnored var onCancel: (() -> Void)?
    /// A Check came back unscored (the design breaks a rule): no reveal (§1.5 "Invalid design").
    @ObservationIgnored var onInvalidDesign: (() -> Void)?
    /// The player showed checked case `index` (§1.9): its values and whether each goal
    /// detector is wrong there. Not called without a current Check or under VoiceOver.
    @ObservationIgnored var onShowCheckedCase: ((_ index: Int, _ values: [Double?], _ wrong: [Bool]) -> Void)?
    /// Sound's output latency in seconds: the picture waits this long so it meets its tone.
    @ObservationIgnored var outputLatency = 0.0

    /// The canvas case changed (nil: back to the player's case).
    @ObservationIgnored var onCanvasCase: ((Int?) -> Void)?
    /// A reveal ended, was skipped or dropped.
    @ObservationIgnored var onEnd: (() -> Void)?
    /// The score bar's frame in its window, top-left origin: a click there is the reveal's own.
    @ObservationIgnored var scoreBarFrame: CGRect?

    /// Skips in a row this session (a reveal played to its end resets it).
    @ObservationIgnored private(set) var skipsInARow = 0
    /// Set by the third skip in a row: checks use the delta form until the next pass/fail
    /// flip (§1.6), even if a reveal plays to its end in between.
    @ObservationIgnored private(set) var shortened = false
    @ObservationIgnored private(set) var revealsThisSession = 0
    /// Holds every reveal at this time instead of running a clock (`--reveal-at`, shots).
    @ObservationIgnored var frozenTime: Double?

    @ObservationIgnored private var clock: RevealClock?
    /// Ends the reveal if the display link stops ticking (a sleeping display): one wake-up
    /// shortly after the plan's end, cancelled when the reveal ends normally.
    @ObservationIgnored private var backstop: Task<Void, Never>?
    @ObservationIgnored private var startTime: CFTimeInterval = 0
    @ObservationIgnored private var lastFrame: RevealFrame?

    init(frozenTime: Double? = nil) {
        self.frozenTime = frozenTime
    }

    /// The options a new reveal starts with: `animate` is the "Animate puzzle results"
    /// setting, `soundOn` whether puzzle sound will play.
    func options(animate: Bool, soundOn: Bool) -> RevealOptions {
        let workspace = NSWorkspace.shared
        return RevealOptions(reduceMotion: workspace.accessibilityDisplayShouldReduceMotion,
                             voiceOver: workspace.isVoiceOverEnabled,
                             soundOn: soundOn,
                             animate: animate,
                             skipsInARow: shortened ? max(skipsInARow, 3) : skipsInARow,
                             showSkipHint: revealsThisSession < 3)
    }

    /// Starts `plan` (a running reveal is skipped first).
    func begin(_ plan: RevealPlan) {
        if isActive { skip() }
        settled = nil
        if plan.passFlip {
            skipsInARow = 0
            shortened = false
        }
        if plan.kind == .full || plan.kind == .delta { revealsThisSession += 1 }
        onBegin?(plan)
        if plan.kind == .voiceOver { announce(plan.announcement) }
        guard plan.visualEnd > 0 || frozenTime != nil else {
            settle(plan)
            return
        }
        self.plan = plan
        lastFrame = nil
        if let frozenTime {
            apply(plan.frame(at: frozenTime))
            return
        }
        apply(plan.frame(at: 0))
        startTime = CACurrentMediaTime()
        let clock = clock ?? RevealClock { [weak self] in self?.tick() }
        self.clock = clock
        clock.start()
        let deadline = plan.visualEnd + outputLatency + 0.5
        backstop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(deadline))
            guard !Task.isCancelled, let self, let plan = self.plan, self.frozenTime == nil else { return }
            self.skipsInARow = 0
            self.settle(plan)
        }
    }

    /// Jumps to the end at once (a click, Space, Esc, ⌘R, an edit). Sound fades and plays
    /// the verdict tone through `onSkip`.
    func skip() {
        guard let plan else { return }
        let t = elapsed
        skipsInARow += 1
        if skipsInARow >= 3 { shortened = true }
        onSkip?(plan, t)
        settle(plan)
    }

    /// Drops the reveal and its extras without a verdict tone: the puzzle closed, Reset, a
    /// mode switch.
    func cancel() {
        settled = nil
        guard plan != nil else { return }
        stopClock()
        plan = nil
        lastFrame = nil
        if !scoreRevealed { scoreRevealed = true }
        onCanvasCase?(nil)
        onCancel?()
        onEnd?()
    }

    /// Forgets the extras kept after a reveal (the design changed).
    func clearSettled() {
        if settled != nil { settled = nil }
    }

    /// Holds the running reveal at `t` seconds (shots), or lets it run again (nil).
    func freeze(at t: Double?) {
        frozenTime = t
        guard let plan else { return }
        if let t {
            stopClock()
            apply(plan.frame(at: t))
        } else {
            startTime = CACurrentMediaTime()
            clock?.start()
        }
    }

    /// Seconds into the running reveal, the picture's own clock.
    var elapsed: Double {
        if let frozenTime { return frozenTime }
        return max(0, CACurrentMediaTime() - startTime - outputLatency)
    }

    private func tick() {
        guard let plan else {
            stopClock()
            return
        }
        let t = elapsed
        PerfProbe.count("reveal.tick")
        if t >= plan.visualEnd {
            skipsInARow = 0
            settle(plan)
        } else {
            apply(plan.frame(at: t))
        }
    }

    /// The end: the final frame, the extras kept, the clock stopped.
    private func settle(_ plan: RevealPlan) {
        stopClock()
        apply(plan.final)
        self.plan = nil
        lastFrame = nil
        settled = (plan.puzzleID, Set(plan.extras.map(\.extra)))
        onCanvasCase?(nil)
        onEnd?()
    }

    private func stopClock() {
        clock?.stop()
        backstop?.cancel()
        backstop = nil
    }

    /// Assigns each part only when it changed.
    private func apply(_ f: RevealFrame) {
        guard f != lastFrame else { return }
        let old = lastFrame
        lastFrame = f
        let c = CaseState(values: f.values, dimmed: f.dimmed, verdictShown: f.caseVerdictShown, opacity: f.caseOpacity)
        if c != cases { cases = c }
        let fo = FocusState(highlightedCase: f.highlightedCase, canvasCase: f.canvasCase, inputsDimmed: f.inputsDimmed)
        if fo != focus { focus = fo }
        let m = MeterState(x: f.meterX, opacity: f.meterOpacity, starLand: f.starLand,
                           starsFadeOnly: f.starsFadeOnly, bestScore: f.bestScore)
        if m != meter { meter = m }
        let s = StageState(verdictOpacity: f.verdictOpacity, extras: f.extrasShown, showsAfterProgress: f.showsAfterProgress,
                           showSkipHint: f.showSkipHint, shortfall: f.nearMissShortfall)
        if s != stage { stage = s }
        if old?.canvasCase != f.canvasCase || old == nil { onCanvasCase?(f.canvasCase) }
        let revealed = f.verdictShown || plan == nil
        if revealed != scoreRevealed { scoreRevealed = revealed }
    }

    private func announce(_ text: String) {
        guard !text.isEmpty else { return }
        let element: Any = NSApp.mainWindow ?? NSApp as Any
        NSAccessibility.post(element: element, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

}

/// The reveal's clock: the main screen's display link while a reveal runs, stopped (not
/// paused) otherwise, so nothing ticks between reveals. A timer stands in when there is no
/// screen.
@MainActor
final class RevealClock: NSObject {
    private let action: @MainActor () -> Void
    private var link: CADisplayLink?
    private var timer: Timer?

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    func start() {
        guard link == nil, timer == nil else { return }
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let link = screen.displayLink(target: self, selector: #selector(step(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        } else {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.action() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    func stop() {
        link?.invalidate()
        link = nil
        timer?.invalidate()
        timer = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        action()
    }
}
