// Offscreen shots of app window states for checking the UI without opening the app: drives
// AppState headlessly, renders FringeWindow in an NSWindow that is never ordered front, made
// key or sent input, captures it at 2x and writes target/ui-shots/<name>.png. The capture
// code below "MARK: - Capture" is copied from appstore/screenshots/Screenshots.swift (which
// is left as it is), with the window size passed per shot.
//
// Compiled together with the app sources (minus FringeMain.swift) by scripts/ui-shots.sh.
// usage: fringe-ui-shots OUT_DIR [NAME_PREFIX]
import AppKit
import QuartzCore
import SwiftUI

// MARK: - Shots

struct UIShot {
    var name: String
    var size = CGSize(width: 1440, height: 900)
    /// Writes into the harness's own defaults before the model is created (a saved document,
    /// puzzle progress).
    var defaults: (@MainActor (UserDefaults) -> Void)? = nil
    /// Sets up the model; return when the window should be captured.
    var setup: @MainActor (AppState) async throws -> Void
    /// Accessibility label of a view in the inspector to scroll into view.
    var scrollInspectorTo: String? = nil
    /// Where to scroll the inspector, 0 top … 1 bottom, when no label is given or found.
    var scrollInspectorFraction: Double? = nil
    /// Light appearance for the window (the capture's glass stand-ins follow it).
    var light = false
}

@MainActor let shots: [UIShot] = [
    // The default scene with the wavelength and medium selected.
    UIShot(name: "sim-default") { m in
        m.selection = .illumination
        // Number fields show U+2212 and read it back, as well as a typed "-".
        let style = LenientMinusFormat(digits: 1)
        let shown = style.format(-45), back = try? style.parseStrategy.parse(shown), typed = try? style.parseStrategy.parse("-2.5")
        let length = LengthField.parse("\u{2212}2 µm", lambda: 1)
        print("  minus: shown \(shown) back \(back ?? .nan) typed \(typed ?? .nan) length \(length ?? .nan)")
        guard shown == "\u{2212}45.0", back == -45, typed == -2.5, length == -2 else { throw ShotError(description: "minus sign round trip failed") }
        await settle(m)
    },
    // The Window aspect: the field fills the canvas column and stops at its edges, with
    // nothing mirrored under the toolbar or the inspector.
    UIShot(name: "sim-window-aspect") { m in
        m.setAspect(.window)
        m.selection = .output
        await settle(m)
    },
    // A document saved by a schema version 2 build opens: its scene is upgraded to a source
    // list. The saved scene is the default one at 633 nm with the beam tilted by 10°, so the
    // shot shows it was this document that opened.
    UIShot(name: "sim-v2-document", defaults: saveV2Document) { m in
        let s = m.scene
        let ok = s.version == SimScene.schemaVersion && s.sources.map(\.id) == [SimScene.upgradedSourceID]
            && abs(s.wavelengthUm - 0.633) < 1e-12 && abs((s.sources.first?.angleDeg ?? 0) - 10) < 1e-12
        print("  sim-v2-document: \(ok ? "upgraded" : "NOT UPGRADED") version=\(s.version) sources=\(s.sources.map(\.id)) λ0=\(s.wavelengthUm) angle=\(s.sources.first?.angleDeg ?? .nan)")
        guard ok else { throw ShotError(description: "the version 2 document did not open as expected") }
        m.selection = .source(SimScene.upgradedSourceID)
        await settle(m)
        // Saving writes the new key and leaves the old one for an older build.
        m.saveNow()
        let saved = UserDefaults.standard.data(forKey: AppState.documentKey) != nil
        let kept = UserDefaults.standard.data(forKey: AppState.previousDocumentKey) != nil
        print("  sim-v2-document: saved as v3 \(saved), v2 key kept \(kept)")
    },
    // A version 3 document that cannot be decoded, beside a version 2 one: the v2 document
    // opens, and the unreadable one is kept under its own key.
    UIShot(name: "sim-v3-unreadable", defaults: { defaults in
        saveV2Document(defaults)
        defaults.set(Data(#"{"scene": {"version": 3, "elements": "not a list"}}"#.utf8), forKey: AppState.documentKey)
    }) { m in
        let s = m.scene
        let ok = s.sources.map(\.id) == [SimScene.upgradedSourceID] && abs(s.wavelengthUm - 0.633) < 1e-12
        let kept = UserDefaults.standard.data(forKey: AppState.unreadableDocumentKey) != nil
        print("  sim-v3-unreadable: v2 opened \(ok), unreadable kept \(kept), λ0=\(s.wavelengthUm)")
        guard ok, kept else { throw ShotError(description: "the v2 document did not open after the v3 one failed") }
        await settle(m)
    },
    // A scene with an emitter and a line detector (schema 3), which step A only has to open.
    UIShot(name: "sim-example-emitter-mirror") { m in
        try open("emitter_mirror", in: m)
        m.selection = m.scene.sources.first.map { .source($0.id) } ?? .illumination
        print("  sim-example-emitter-mirror: detectors \(m.scene.detectors.count), results open \(m.isResultsPresented), shows \(m.resultsDetector?.displayName ?? "-")")
        guard m.isResultsPresented, m.resultsDetector != nil else { throw ShotError(description: "a template with a detector did not open the results") }
        await settle(m)
    },
    // A Lorentz–Drude element selected (silver), which step A shows read-only.
    UIShot(name: "sim-example-silver-dimer") { m in
        try open("silver_dimer", in: m)
        m.selection = m.scene.elements.first.map { .element($0.id) } ?? .illumination
        await settle(m)
    },

    // B1/B3: several sources. An emitter at (2, 3) µm, selected (with its handles), and a
    // disabled plane wave, dashed.
    UIShot(name: "sim-sources") { m in
        try open("lens", in: m)
        await settle(m)
        m.addSource(.planeWave)
        if let wave = m.scene.sources.last { m.toggleEnabled(.source(wave.id)) }
        m.addSource(.lineSource)
        guard let emitter = m.scene.sources.last, emitter.kind == .lineSource else { throw ShotError(description: "no emitter added") }
        m.edit("Move Source") { $0.scene[source: emitter.id]?.xUm = 2; $0.scene[source: emitter.id]?.yUm = 3 }
        m.selection = .source(emitter.id)
        await settle(m)
        print("  sim-sources: \(m.scene.sources.map { "\($0.id) \($0.kind.rawValue) \($0.enabled ? "on" : "off")" })")
    },
    // B1/B3/B4: a line detector through the lens focus, selected, with its reading, the
    // results table and the profile; the pointer over the focus for the status bar readout.
    UIShot(name: "sim-detector-line") { m in
        try await addDetectorAtFocus(.line, in: m)
        try await showResults(in: m)
    },
    // The same in light appearance: the profile on the light results panel.
    UIShot(name: "sim-detector-line-light", setup: { m in
        try await addDetectorAtFocus(.line, in: m)
        try await showResults(in: m)
    }, light: true),
    // A line end being dragged: the profile keeps its last curve, dimmed, for the whole
    // drag instead of blinking each time a new curve is sampled.
    UIShot(name: "sim-detector-drag") { m in
        try await addDetectorAtFocus(.line, in: m)
        try await showResults(in: m)
        guard let id = m.selectedDetectorID else { return }
        m.beginTracking()
        for step in 1...3 {
            m.track { doc in
                if case .line(var line) = doc.scene[detector: id]?.shape {
                    line.y2Um += 0.3
                    doc.scene[detector: id]?.shape = .line(line)
                }
            }
            try? await Task.sleep(for: .milliseconds(120))
            print("  sim-detector-drag: step \(step) tracking \(m.isTracking)")
        }
    },
    // A lens dragged on the canvas, captured mid-drag: the live layer draws the lens where
    // the pointer has it, the inspector's position fields follow at 4 Hz, and the document
    // takes the drag when it ends, as one undo step.
    UIShot(name: "sim-live-drag") { m in
        await settle(m)
        guard let e = m.scene.elements.first else { throw ShotError(description: "no element") }
        let undo = UndoManager()
        m.undoManager = undo
        m.selection = .element(e.id)
        m.beginTracking()
        for step in 1...6 {
            m.trackLive(.element(id: e.id, xUm: e.xUm + 0.5 * Double(step), yUm: e.yUm + 0.3 * Double(step)))
            try? await Task.sleep(for: .milliseconds(40))
        }
        let lagging = m.scene[element: e.id]?.xUm ?? .nan
        print("  sim-live-drag: live x \(e.xUm + 3), document x \(lagging) mid-drag")
        try? await Task.sleep(for: .milliseconds(300))
        let shown = m.elementBinding(e.id, "Move Element", \.xUm, fallback: .nan, live: true).wrappedValue
        print("  sim-live-drag: inspector x \(shown) mid-drag (want \(e.xUm + 3))")

        // Captured with the drag still open: then end it and check the undo step.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            m.flushLiveEdit()
            m.endTracking("Move Element")
            let x = m.scene[element: e.id]?.xUm ?? .nan
            print("  sim-live-drag: after the drag x \(x) (want \(e.xUm + 3)), undo steps \(undo.canUndo ? 1 : 0) \(undo.undoActionName)")
            undo.undo()
            print("  sim-live-drag: after undo x \(m.scene[element: e.id]?.xUm ?? .nan) (want \(e.xUm)), can undo again \(undo.canUndo)")
        }
    },
    // B3: a box detector at the focus.
    UIShot(name: "sim-detector-box") { m in
        try await addDetectorAtFocus(.box, in: m)
        try await showResults(in: m)
    },
    // B4: the results area with no detectors: the empty state with its two buttons.
    UIShot(name: "sim-results-empty") { m in
        m.isResultsPresented = true
        m.selection = .illumination
        await settle(m)
    },
    // B4: the line detector shot in the smallest window: the results stack.
    UIShot(name: "sim-narrow", size: CGSize(width: 1000, height: 620)) { m in
        try await addDetectorAtFocus(.line, in: m)
        try await showResults(in: m)
    },
    // B4/B5: two line detectors and a disabled box after Run Final: the status bar's Final
    // state, and the table's ratio, disabled and selection states.
    UIShot(name: "sim-final") { m in
        try await addDetectorAtFocus(.line, in: m)
        guard let focus = m.selectedDetectorID else { return }
        m.addDetector(.line)
        if let id = m.selectedDetectorID {
            m.edit("Rename Detector") { $0.scene[detector: id]?.name = "Back" }
        }
        m.addDetector(.box)
        if let id = m.selectedDetectorID {
            m.edit("Rename Detector") { $0.scene[detector: id]?.name = "Off" }
            m.toggleEnabled(.detector(id))
        }
        m.selection = .detector(focus)
        await settle(m)
        m.runFinal()
        await settle(m)
        try await showResults(in: m)
        // The disabled box at the focus is not named by the hover readout; the enabled line wins
        // the hit test there.
        if let off = m.scene.detectors.first(where: { !$0.enabled }), case .box(let box) = off.shape {
            let enabledHit = m.hitTestDetector(x: box.xUm, y: box.yUm, enabled: true)
            let anyHit = m.hitTestDetector(x: box.xUm, y: box.yUm, enabled: false)
            m.updateHover(at: m.geometry.viewPoint(x: box.xUm, y: box.yUm))
            let readout = m.hover?.body ?? "-"
            print("  sim-final: at the disabled box: enabled hit \(enabledHit ?? "-"), disabled hit \(anyHit ?? "-"), readout \(readout)")
            guard !readout.contains("Off") else { throw ShotError(description: "the readout names a disabled detector") }
            m.updateHover(at: nil)
        }
        print("  sim-final: status=\(m.solver.status.title) memory=\(String(describing: m.solver.shownMemoryMb)) rows=\(m.resultRows.map { "\($0.name) \($0.total ?? .nan) \($0.ratio ?? .nan)" })")
    },
    // B3: an emitter inside the lens: the invalid-scene card and the issue under the
    // emitter's position.
    UIShot(name: "sim-invalid") { m in
        try open("lens", in: m)
        await settle(m)
        guard let lens = m.scene.elements.first else { throw ShotError(description: "no lens") }
        m.addSource(.lineSource)
        guard let emitter = m.scene.sources.last else { throw ShotError(description: "no emitter") }
        m.edit("Move Source") { $0.scene[source: emitter.id]?.xUm = lens.xUm; $0.scene[source: emitter.id]?.yUm = lens.yUm }
        m.selection = .source(emitter.id)
        _ = await wait(20) { m.solver.currentReport != nil }
        try? await Task.sleep(for: .milliseconds(800))
        let issues = m.checkReport?.issues.map { "\($0.path) \($0.code)" } ?? []
        let fix = m.checkReport?.firstError.flatMap { m.fix(for: $0) }?.title ?? "-"
        print("  sim-invalid: ok=\(m.checkReport?.ok ?? true) issues=\(issues) fix=\(fix)")
    },

    // B2: a constant-index element (the prism).
    UIShot(name: "sim-material-index") { m in
        try open("prism", in: m)
        m.selection = m.scene.elements.first.map { .element($0.id) } ?? .illumination
        await settle(m)
    },
    // B2: a gold cylinder (r 0.1 µm at 550 nm, FEM), scrolled to the chart.
    UIShot(name: "sim-material-gold", setup: { m in
        try await goldCylinder(in: m)
        let name = m.selectedElement?.name ?? "-"
        print("  sim-material-gold: name \(name)")
        guard name == "Gold cylinder" else { throw ShotError(description: "the gold cylinder is called \(name)") }
    }, scrollInspectorFraction: 1),
    // B2: the same, scrolled to the poles, with one γ edited so the preset reads "(edited)".
    UIShot(name: "sim-material-poles", setup: { m in
        try await goldCylinder(in: m)
        guard let id = m.selectedElementID else { return }
        m.edit("Change Damping") { $0.scene[element: id]?.material[pole: 0].gammaEv = 0.08 }
        await settle(m)
        print("  sim-material-poles: preset=\(m.selectedElement?.material.preset ?? "-") γ0=\(m.selectedElement?.material.poles.first?.gammaEv ?? .nan)")
    }, scrollInspectorFraction: 0.22),

    // C2: the browser with progress seeded: three puzzles passed with 3, 2 and 1 stars, one
    // tried without passing.
    UIShot(name: "puzzle-browser", defaults: seedProgress) { m in
        m.setMode(.puzzles)
        try expectBrowser(m)
        try? await Task.sleep(for: .milliseconds(400))
        let p = m.puzzles
        print("  puzzle-browser: \(p.solvedCount()) of \(p.catalog.count) solved, \(p.starCount()) of \(p.maxStars()) stars; chapters \(p.chapters.map { "\($0.title) \(p.solvedCount($0.puzzles))/\($0.puzzles.count)" })")
        print("  task lines: \(p.catalog.map { "\($0.id): \(p.taskLine($0.id))" })")
    },
    // C2: the same at the smallest window size.
    UIShot(name: "puzzle-browser-narrow", size: CGSize(width: 1000, height: 620), defaults: seedProgress) { m in
        m.setMode(.puzzles)
        try expectBrowser(m)
        try? await Task.sleep(for: .milliseconds(400))
    },
    // C2: the sidebar's Logic chapter selected: the grid scrolled to it.
    UIShot(name: "puzzle-browser-chapter", defaults: seedProgress) { m in
        m.setMode(.puzzles)
        try expectBrowser(m)
        try? await Task.sleep(for: .milliseconds(300))
        m.puzzles.browserChapter = "logic"
        try? await Task.sleep(for: .milliseconds(800))
    },
    // C1: switching modes keeps the simulator exactly, never saves a puzzle document, and
    // clears undo; a puzzle's fixed parts refuse edits, its design is kept.
    UIShot(name: "puzzle-mode-switch") { m in
        try await modeSwitchChecks(m)
    },
    // Launched in the puzzle browser (the launch preview is parked while it runs), then ⌘1:
    // the simulator solves its scene again instead of showing "Nothing solved yet".
    UIShot(name: "puzzle-return-unsolved", defaults: { $0.set("puzzles", forKey: "fringe.mode") }) { m in
        try expectBrowser(m)
        m.setMode(.simulator)
        try require(m.solver.isRunning || m.solver.status == .updating, "⌘1 from the browser starts a solve at once")
        await settle(m)
        try require(m.solver.shown != nil && !m.solver.isShownStale, "the simulator shows a field for its scene after ⌘1")
    },
    // An edit, then ⌘2 and ⌘1 inside the 250 ms debounce: the edited scene is still solved.
    UIShot(name: "puzzle-quick-switch") { m in
        await settle(m)
        m.edit("Change Wavelength") { $0.scene.wavelengthUm = 0.7 }
        m.setMode(.puzzles)
        m.setMode(.simulator)
        await settle(m)
        try require(m.solver.shown?.scene.wavelengthUm == 0.7 && !m.solver.isShownStale, "the edit made before ⌘2 ⌘1 is solved")
    },
    // C1: logic-xor with the reference slab, checked, then input A switched off: the case
    // is combined from the checked fields and no preview job runs.
    UIShot(name: "puzzle-xor-case") { m in
        try await xorCaseChecks(m)
    },
    // C3: logic-xor as it opens: brief, goal card, one part to place, empty table, region.
    UIShot(name: "puzzle-xor-start") { m in
        m.setMode(.puzzles, puzzle: "logic-xor")
        try require(m.isInPuzzle && m.puzzleDesign.isEmpty, "logic-xor opens with nothing placed")
        try require(m.puzzleReport?.rows.count == 4 && m.puzzleReport?.isChecked == false, "the table lists the four cases, unchecked")
        try require(m.canAddPart(0) && m.paletteUsage == [0], "one slab may be added")
        await settle(m)
        try require(m.selection == .illumination, "nothing of the player's is selected")
    },
    // C3: a part added from the palette: sized into the region, the palette's material,
    // the material picker restricted (one choice), the palette used up.
    UIShot(name: "puzzle-xor-part-added") { m in
        m.setMode(.puzzles, puzzle: "logic-xor")
        m.addPart(0)
        guard let part = m.puzzleDesign.first else { throw ShotError(description: "no part added") }
        try require(m.selection == .element(part.id), "the new part is selected")
        try require(m.outOfRegionElementIDs.isEmpty, "the new part lies inside the region")
        try require(part.material.sameSubstance(as: .glass(2.0)), "the new part is made of the palette's dense glass")
        try require(!m.canAddPart(0) && m.paletteUsage == [1], "the palette's one slab is used")
        try require(m.materialChoices(for: part)?.choices.map(\.id) == ["dense-glass"], "the inspector offers only the palette's material")
        // The palette holds: no duplicate past its max, no kind it lacks, no other material.
        let before = m.document
        try require(!m.canDuplicate(.element(part.id)), "Duplicate is off with the palette used up")
        m.duplicate(.element(part.id))
        try require(m.document == before && m.selection == .element(part.id), "a duplicate past the palette's max is refused")
        let cylinder = ShapeKind.cylinder.makeElement(at: (0, 0))
        m.edit("Add Cylinder") { $0.scene.elements.append(cylinder) }
        try require(m.document == before, "a kind the palette lacks is refused")
        m.edit("Change Material") { $0.scene[element: part.id]?.material = .pec }
        try require(m.document == before, "a material the palette lacks is refused")
        await settle(m)
    },
    // C3: logic-xor with the reference slab, checked: every case solved and scored.
    UIShot(name: "puzzle-xor-checked") { m in
        let e = try await openChecked("logic-xor", in: m)
        try require(e.valid && e.passed && e.stars == 3, "the reference passes with 3 stars (\(e.score.map { Format.decibels($0) } ?? "-"))")
        let report = m.puzzleReport
        try require(report?.rows.allSatisfy { $0.passes == true } == true, "every row of the table passes")
        try require(abs((report?.contrasts.first?.decibels ?? 0) - (e.score ?? 0)) < 1e-6, "the table's contrast is the core's score")
        try require(m.showsCheckedCase, "the canvas shows the checked case")
    },
    // The same window in light appearance.
    UIShot(name: "puzzle-xor-checked-light", setup: { m in
        _ = try await openChecked("logic-xor", in: m)
    }, light: true),
    // After a passing Check, the case with every input off: "Checked" and neutral, with the
    // row passing (a 0 at the floor is as dark as a case can be).
    UIShot(name: "puzzle-xor-checked-00") { m in
        _ = try await openChecked("logic-xor", in: m)
        m.setPuzzleInputs([false, false])
        try? await Task.sleep(for: .milliseconds(400))
        try require(m.showsCheckedCase && !m.showsDarkCase, "the checked case 0 0 shows the combined field")
        try require(m.puzzleReport?.rows.first?.passes == true, "row 0 0 passes")
        m.selection = .illumination
    },
    // logic-or with no part: the 0 0 row (no light) passes and is not the deciding case.
    UIShot(name: "puzzle-or-empty") { m in
        m.setMode(.puzzles, puzzle: "logic-or")
        try await checkPuzzle(m)
        let row = m.puzzleReport?.rows.first
        try require(row?.passes == true && row?.cells.first?.decisive == false, "row 0 0 passes and does not set the contrast")
        print("  rows \(m.puzzleReport?.rows.map { "\($0.bits.map { $0 ? 1 : 0 }) \($0.passes.map { $0 ? "ok" : "x" } ?? "-")\($0.cells.first?.decisive == true ? "*" : "")" } ?? [])")
        m.selection = .illumination
    },
    // The contrast chart beside the table, case A 0 B 1 shown.
    UIShot(name: "puzzle-xor-contrast") { m in
        _ = try await openChecked("logic-xor", in: m)
        m.puzzles.resultChart = .contrast
        m.setPuzzleInputs([false, true])
        try require(!m.solver.isRunning && m.showsCheckedCase, "clicking a row shows its case with no solve")
        m.selection = .illumination
        try? await Task.sleep(for: .milliseconds(300))
    },
    // C3 at the smallest window: the stacked results.
    UIShot(name: "puzzle-xor-checked-narrow", size: CGSize(width: 1000, height: 620)) { m in
        _ = try await openChecked("logic-xor", in: m)
    },
    // Two outputs: the half adder's panels per output.
    UIShot(name: "puzzle-half-adder-checked") { m in
        let e = try await openChecked("logic-half-adder", in: m)
        try require(e.valid && e.passed, "the half adder's reference passes")
        try require(m.puzzleReport?.contrasts.count == 2, "both outputs have a contrast")
        m.selection = .illumination
    },
    UIShot(name: "puzzle-half-adder-contrast") { m in
        _ = try await openChecked("logic-half-adder", in: m)
        m.puzzles.resultChart = .contrast
        m.selection = .illumination
    },
    // C3: two of three hints shown, nothing selected (the inspector's scoring info).
    UIShot(name: "puzzle-hints") { m in
        m.setMode(.puzzles, puzzle: "steering-split")
        m.puzzles.showHint()
        m.puzzles.showHint()
        try require(m.puzzles.hintsShown == 2, "two hints are shown")
        try require(PuzzleProgressStore.load()["steering-split"]?.hintsShown == 2, "the hints shown are kept in the progress")
        await settle(m)
        let live = ["right", "up"].map { m.puzzleLiveLabel($0) ?? "-" }
        try require(live.allSatisfy { $0.hasSuffix("%") }, "before a Check both detectors read in % of source power (\(live))")
    },
    // One checked puzzle per chapter. Steering: a 50/50 split (target).
    UIShot(name: "puzzle-steering-split-checked") { m in
        let e = try await openChecked("steering-split", in: m)
        try require(e.valid && e.passed, "steering-split's reference passes (\(e.score.map { Format.number($0, digits: 1...1) } ?? "-")%)")
        try require(m.puzzleReport?.detectorRows.count == 2, "the table lists Right and Up")
    },
    // Interference (maximize): the Bragg mirror, nothing selected.
    UIShot(name: "puzzle-maximize") { m in
        let e = try await openChecked("interference-bragg-mirror", in: m)
        try require(e.valid && e.passed, "the Bragg mirror's reference passes (\(e.score.map { Format.number($0, digits: 1...1) } ?? "-")%)")
        m.selection = .illumination
        try? await Task.sleep(for: .milliseconds(300))
    },
    // Metals and emitters: the silver mirror behind the emitter.
    UIShot(name: "puzzle-metals-emitter-mirror-checked") { m in
        let e = try await openChecked("metals-emitter-mirror", in: m)
        try require(e.valid && e.passed, "metals-emitter-mirror's reference passes (\(e.score.map { Format.number($0, digits: 1...1) } ?? "-")%)")
    },
    // C3: a slab outside the region, checked: not scored, the rule named in the goal card.
    UIShot(name: "puzzle-rule-issue") { m in
        m.setMode(.puzzles, puzzle: "logic-xor")
        var slab = ShapeKind.slab.makeElement(at: (3.3, 0))
        slab.name = "Slab"
        slab.material = .glass(2.0)
        slab.shape = .slab(Slab(thicknessUm: 0.36, heightUm: 2))
        m.edit("Add Slab") { $0.scene.elements.append(slab) }
        m.selection = .element(slab.id)
        try require(m.outOfRegionElementIDs == [slab.id], "the slab is outlined as outside the region before a Check")
        await settle(m)
        try await checkPuzzle(m)
        let e = m.puzzles.session?.evaluation
        try require(e?.valid == false && e?.score == nil, "the design is not scored")
        try require(e?.issues.contains { $0.code == "rule_region" && $0.elementIndex == 0 } == true, "the core names the region rule for the slab")
    },
    // C4: a puzzle with a fixed part: hatched with a padlock; selecting it shows a summary,
    // and it refuses to move.
    UIShot(name: "puzzle-locked") { m in
        m.setMode(.puzzles, puzzle: "steering-hidden")
        guard let wall = m.scene.elements.first(where: { m.isLockedElement($0.id) }) else { throw ShotError(description: "no locked element") }
        try require(!m.isPlayerItem(.element(wall.id)) && !m.isPlayerItem(.source(m.scene.sources[0].id)), "fixed parts and sources are not the player's")
        let before = m.document
        m.edit("Move Element") { $0.scene[element: wall.id]?.xUm += 0.5 }
        try require(m.document == before, "the fixed wall refuses to move")
        m.selection = .element(wall.id)
        try require(!m.canDuplicate(.element(wall.id)), "a fixed part cannot be duplicated")
        m.duplicate(.element(wall.id))
        try require(m.document == before, "Duplicate on the fixed wall adds nothing")
        await settle(m)
        // Before a Check the empty design reads in the goal's unit, as the core scores it
        // (0.0003 % of the source power), not as total over a near-zero incident flux.
        let live = m.puzzleLiveValue("target") ?? .nan
        try require(live.isFinite && live < 1e-3, "the empty design's live value is about 0 % (\(live))")
    },
    // Before a Check the live value of a design is the core's value: steering-hidden's
    // reference, read live and then checked.
    UIShot(name: "puzzle-live-value") { m in
        m.setMode(.puzzles, puzzle: "steering-hidden")
        guard let puzzle = m.puzzles.session?.puzzle else { throw ShotError(description: "no puzzle") }
        m.edit("Add Reference") { $0.scene.elements = puzzle.compose(design: puzzle.reference).elements }
        m.selection = .illumination
        await settle(m)
        _ = await wait(5) { m.puzzleLiveValue("target") != nil }
        let live = m.puzzleLiveValue("target") ?? .nan
        try require(m.detectorLabels["target"]?.contains("≈") == true, "the plate shows the live share (\(m.detectorLabels["target"] ?? "-"))")
        try await checkPuzzle(m)
        let scored = m.puzzles.session?.evaluation?.cases.first?.outputs.first?.value ?? .nan
        try require(abs(live - scored) < 0.005 * scored, "the live value \(live) is the checked value \(scored)")
    },
    // Every input off before a Check: the puzzle's own words and a fix that turns input A on.
    UIShot(name: "puzzle-inputs-off") { m in
        m.setMode(.puzzles, puzzle: "logic-xor")
        m.addPart(0)
        await settle(m)
        m.setPuzzleInputs([false, false])
        await settle(m)
        guard let issue = m.solver.currentReport?.firstError else { throw ShotError(description: "no issue with every input off") }
        guard case .turnOnInput(0, "A")? = m.fix(for: issue) else { throw ShotError(description: "the fix is not Turn On Input A") }
        try require(m.puzzleSentence(for: issue) != nil, "the card uses the puzzle's wording")
        try require(m.showsDarkCase && m.caption == nil, "the canvas shows the case as dark, with no caption of another case")
        m.selection = .illumination
        try? await Task.sleep(for: .milliseconds(300))
    },
    // The fix applied: input A comes on.
    UIShot(name: "puzzle-inputs-off-fixed") { m in
        m.setMode(.puzzles, puzzle: "logic-xor")
        m.setPuzzleInputs([false, false])
        await settle(m)
        guard let issue = m.solver.currentReport?.firstError, let fix = m.fix(for: issue) else { throw ShotError(description: "no fix") }
        m.apply(fix)
        try require(m.puzzleInputBits == [true, false], "Turn On Input A switches A on")
        await settle(m)
    },
]

/// Opens `id`, places its reference elements, selects the first and runs Check.
@MainActor func openChecked(_ id: String, in m: AppState) async throws -> PuzzleEvaluation {
    m.setMode(.puzzles, puzzle: id)
    guard let puzzle = m.puzzles.session?.puzzle else { throw ShotError(description: "\(id) did not open") }
    m.edit("Add Reference") { doc in
        doc.scene.elements = puzzle.compose(design: puzzle.reference).elements
    }
    if let first = puzzle.reference.first { m.selection = .element(first.id) }
    await settle(m)
    try await checkPuzzle(m)
    guard let evaluation = m.puzzles.session?.evaluation else { throw ShotError(description: "\(id): no evaluation") }
    print("  \(id): valid \(evaluation.valid) passed \(evaluation.passed) stars \(evaluation.stars) score \(evaluation.score.map { Format.significant($0) } ?? "-") \(evaluation.summary(scale: puzzle.scoreScale) ?? "")")
    return evaluation
}

/// Runs Check and waits for it and the shown case.
@MainActor func checkPuzzle(_ m: AppState) async throws {
    m.checkPuzzle()
    try require(m.puzzles.isChecking || m.puzzles.session?.evaluation != nil, "Check starts")
    _ = await wait(120) { !m.puzzles.isChecking }
    await settle(m)
}

/// Progress for the browser shots: three passed (3, 2, 1 stars) and one tried.
@MainActor func seedProgress(_ defaults: UserDefaults) {
    let progress: [String: PuzzleProgress] = [
        "steering-mirror": PuzzleProgress(bestScore: 84, stars: 3, passed: true, solvedAt: Date()),
        "steering-split": PuzzleProgress(bestScore: 93, stars: 2, passed: true, solvedAt: Date()),
        "logic-xor": PuzzleProgress(bestScore: 7.1, stars: 1, passed: true, hintsShown: 2, solvedAt: Date()),
        "interference-dark-spot": PuzzleProgress(bestScore: 4.2, hintsShown: 1),
    ]
    PuzzleProgressStore.save(progress, to: defaults)
}

@MainActor func expectBrowser(_ m: AppState) throws {
    guard m.mode == .puzzles, m.isPuzzleBrowser else {
        throw ShotError(description: "puzzle mode did not open on the browser (mode \(m.mode), session \(m.puzzles.session?.id ?? "none"))")
    }
    guard !m.puzzles.catalog.isEmpty else { throw ShotError(description: "no puzzles") }
}

@MainActor func require(_ ok: Bool, _ what: String) throws {
    print("  \(ok ? "ok  " : "FAIL") \(what)")
    if !ok { throw ShotError(description: what) }
}

@MainActor func modeSwitchChecks(_ m: AppState) async throws {
    try open("lens", in: m)
    await settle(m)
    m.addDetector(.line)
    await settle(m)
    m.saveNow()
    let simulator = m.document
    let selection = m.selection
    let shownField = m.solver.shown?.field
    let saved = UserDefaults.standard.data(forKey: AppState.documentKey)
    try require(m.undoManager != nil, "the window gives the model an undo manager")
    try require(m.undoManager?.canUndo == true, "the simulator edits are undoable before the switch")

    m.setMode(.puzzles, puzzle: "logic-xor")
    try require(m.isInPuzzle && m.puzzles.session?.id == "logic-xor", "⌘2 with a puzzle id opens it")
    try require(m.undoManager?.canUndo == false, "the switch cleared undo")
    try require(m.scene.solver.method == .fem && m.scene.solver.fem.previewPpw == 9, "the puzzle scene solves at the scoring method and resolution")
    await settle(m)

    // Fixed parts refuse edits; the player's own parts do not.
    let before = m.document
    m.edit("Change Wavelength") { $0.scene.wavelengthUm = 0.8 }
    m.edit("Move Detector") { $0.scene.detectors[0].shape = .line(LineGeometry(x1Um: 3, y1Um: -3, x2Um: 3, y2Um: 3)) }
    m.setMethod(.fdtd)
    try require(m.document == before, "wavelength, detector and solver edits are refused in a puzzle")
    m.addElement(.slab)
    try require(m.scene.elements.isEmpty, "a slab of a material the palette lacks is refused")
    m.addPart(0)
    try require(m.scene.elements.count == 1, "the player can add a part from the palette")
    try? await Task.sleep(for: .milliseconds(1400))
    m.saveNow()
    let savedNow = UserDefaults.standard.data(forKey: AppState.documentKey).flatMap { try? JSONDecoder().decode(FringeDocument.self, from: $0) }
    let savedBefore = saved.flatMap { try? JSONDecoder().decode(FringeDocument.self, from: $0) }
    try require(savedNow != nil && savedNow == savedBefore && savedNow == simulator, "saving in puzzle mode leaves the simulator document as it was")
    try require(PuzzleProgressStore.load()["logic-xor"]?.design?.count == 1, "the player's element is saved with the puzzle's progress")

    m.closePuzzle()
    try require(m.isPuzzleBrowser, "All Puzzles goes back to the browser")
    m.edit("Change Wavelength") { $0.scene.wavelengthUm = 0.8 }
    try require(m.document.scene.wavelengthUm != 0.8, "nothing edits the parked simulator scene from the browser")

    m.setMode(.simulator)
    try require(m.mode == .simulator && m.document == simulator, "⌘1 restores the simulator document exactly")
    try require(m.selection == selection, "⌘1 restores the selection")
    try require(m.solver.shown?.field === shownField && !m.solver.isShownStale, "⌘1 restores the simulator's solved field, with no new solve")
    try require(m.undoManager?.canUndo == false, "the switch back cleared undo")

    // Puzzle mode comes back on the puzzle open last, with the saved element.
    m.setMode(.puzzles)
    try require(m.puzzles.session?.id == "logic-xor" && m.scene.elements.count == 1, "⌘2 reopens the last puzzle with its design")
    m.setMode(.simulator)
    try require(m.document == simulator, "the second round trip keeps the simulator document")
    await settle(m)
}

@MainActor func xorCaseChecks(_ m: AppState) async throws {
    m.setMode(.puzzles, puzzle: "logic-xor")
    guard let puzzle = m.puzzles.session?.puzzle else { throw ShotError(description: "logic-xor did not open") }
    m.edit("Add Reference") { $0.scene.elements += puzzle.reference }
    if let first = puzzle.reference.first { m.selection = .element(first.id) }
    await settle(m)
    m.checkPuzzle()
    _ = await wait(120) { !m.puzzles.isChecking }
    await settle(m)
    let evaluation = m.puzzles.session?.evaluation
    try require(evaluation?.valid == true && evaluation?.passed == true, "the reference passes: score \(evaluation?.score.map { Format.decibels($0) } ?? "-"), \(evaluation?.stars ?? 0) stars")
    try require(m.puzzles.progress("logic-xor").stars == evaluation?.stars, "the Check is recorded in the progress")
    try require(m.isPuzzleCheckCurrent, "the Check is current")
    try require(m.solver.shown?.field === m.puzzles.session?.shownField, "after the Check the canvas shows the combined field of the shown case (A 1, B 1)")

    m.setPuzzleInput(0, on: false)
    let combined = m.puzzles.session?.shownField
    try require(m.puzzleInputBits == [false, true], "input A is off")
    try require(combined != nil && m.solver.shown?.field === combined, "the shown field is the combined one at once")
    try require(!m.solver.isRunning && !m.solver.isShownStale, "no preview job right after the toggle")
    try? await Task.sleep(for: .milliseconds(800))
    try require(!m.solver.isRunning && m.solver.shown?.field === combined, "no preview job after the debounce either")
    try require(m.isPuzzleCheckCurrent, "switching an input keeps the Check current")
    let output = m.solver.shown?.info.detectors.first { $0.id == "out" }?.totalValue
    let expected = evaluation?.case(bits: [false, true])?.readings.first { $0.id == "out" }?.totalValue
    print("  Output on the combined field \(output ?? .nan), the core's case 01 \(expected ?? .nan)")
    if let output, let expected {
        try require(abs(output - expected) <= 1e-6 * max(1, abs(expected)), "the combined field reads like the core's case")
    }

    // Moving the slab makes the Check out of date; the next toggle solves a preview.
    if let id = puzzle.reference.first?.id {
        m.edit("Move Element") { $0.scene[element: id]?.xUm += 0.05 }
    }
    try require(!m.isPuzzleCheckCurrent, "moving the slab makes the Check out of date")
    m.edit("Move Element") { doc in
        if let id = puzzle.reference.first?.id { doc.scene[element: id]?.xUm -= 0.05 }
    }
    try require(m.isPuzzleCheckCurrent, "moving it back makes the Check current again")
    await settle(m)
}

/// The mie_dielectric example with its cylinder made of the gold preset, radius 0.1 µm, at
/// 550 nm with FEM; the cylinder selected.
@MainActor func goldCylinder(in m: AppState) async throws {
    try open("mie_dielectric", in: m)
    guard let cylinder = m.scene.elements.first, let gold = m.materialLibrary.first(where: { $0.id == "gold" }) else {
        throw ShotError(description: "no cylinder or no gold preset")
    }
    m.edit("Gold") { doc in
        doc.scene[element: cylinder.id]?.setMaterial(gold.material)
        doc.scene[element: cylinder.id]?.shape.cylinder.radiusUm = 0.1
        doc.scene.wavelengthUm = 0.55
        doc.scene.solver.method = .fem
    }
    m.fitDomainToElements()
    m.selection = .element(cylinder.id)
    await settle(m)
}

/// Component snapshots of the plots alone (ImageRenderer draws `Canvas` correctly; never
/// use it for forms), each in an explicit appearance on the surface it sits on in the app:
/// the inspector row (#232323 dark, #FFFFFF light) or the results panel (#1E1E1E, #F5F5F5).
struct ChartShot {
    enum Host { case inspector, results }
    var name: String
    var scheme: ColorScheme = .dark
    var host: Host = .inspector
    var width: CGFloat
    /// Figure height for flexible plots (the profile); fixed plots size themselves.
    var height: CGFloat? = nil
    var view: @MainActor () -> AnyView?

    var surface: Color {
        switch (host, scheme) {
        case (.inspector, .dark): Color(.sRGB, red: 0x23 / 255, green: 0x23 / 255, blue: 0x23 / 255)
        case (.inspector, _): .white
        case (.results, .dark): Color(.sRGB, red: 0x1E / 255, green: 0x1E / 255, blue: 0x1E / 255)
        case (.results, _): Color(.sRGB, red: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF5 / 255)
        }
    }
}

@MainActor func materialChart(_ id: String, lambda0: Double, hover: Double? = nil, edited: Bool = false) -> AnyView? {
    guard let entry = MaterialLibrary.entry(id) else { print("FAIL: no preset \(id)"); return nil }
    var material = entry.material
    if edited { material[pole: 0].gammaEv = 0.08 }
    guard let curve = MaterialChart.sample(material, lambda0: lambda0) else {
        print("FAIL: no curve for \(id)"); return nil
    }
    print("  \(id) λ0=\(lambda0): \(curve.wavelengthUm.first ?? 0)–\(curve.wavelengthUm.last ?? 0) µm, n \(curve.n.min() ?? .nan)–\(curve.n.max() ?? .nan), k max \(curve.k.max() ?? .nan), fit \(String(describing: entry.rangeUm)), poles \(MaterialChart.poles(curve)), notes \(MaterialChart(curve: curve, lambda0: lambda0, validRange: edited ? nil : entry.rangeUm).spec.notes)")
    return AnyView(MaterialChart(curve: curve, lambda0: lambda0, validRange: edited ? nil : entry.rangeUm, materialName: entry.name, hoverX: hover))
}

/// A user Lorentz pole (strength 1, ħω0 = 2 eV, so near 0.62 µm) with damping `gamma`.
@MainActor func lorentzChart(gamma: Double, lambda0: Double = 0.633, hover: Double? = nil) -> AnyView? {
    let material = Material(preset: nil, epsInf: 1, poles: [.lorentz(strength: 1, resonanceEv: 2, gammaEv: gamma)])
    guard let curve = MaterialChart.sample(material, lambda0: lambda0) else {
        print("FAIL: no curve for Lorentz γ=\(gamma)"); return nil
    }
    let finiteN = curve.n.filter(\.isFinite)
    print("  lorentz γ=\(gamma): n \(finiteN.min() ?? .nan)–\(finiteN.max() ?? .nan), poles \(MaterialChart.poles(curve)), at \(String(describing: curve.at))")
    return AnyView(MaterialChart(curve: curve, lambda0: lambda0, hoverX: hover))
}

/// A synthetic focus profile on a line of length L: a Gaussian total over a broad incident.
func focusProfile(length: Double, count: Int = 200, flat: Bool = false) -> [ProfilePoint] {
    (0..<count).map { i in
        let x = length * Double(i) / Double(count - 1)
        let u = (x - length / 2) / length
        let incident = 0.12 + 0.43 * exp(-pow(u / 0.45, 2))
        let total = flat ? incident : 0.15 + 1.9 * exp(-pow(u / 0.22, 2))
        return ProfilePoint(positionUm: x, total: total, incident: incident)
    }
}

func profile(_ points: [ProfilePoint], length: Double, state: PlotState = .live, hover: Double? = nil, name: String = "Focus") -> AnyView {
    AnyView(LineProfileChart(points: points, detectorName: name, lengthUm: length, state: state, hoverX: hover, captionDelay: .zero))
}

@MainActor let chartShots: [ChartShot] = [
    ChartShot(name: "chart-gold-dark", width: 280) { materialChart("gold", lambda0: 0.55) },
    ChartShot(name: "chart-gold-light", scheme: .light, width: 280) { materialChart("gold", lambda0: 0.55) },
    ChartShot(name: "chart-gold-narrow", width: 240) { materialChart("gold", lambda0: 0.55) },
    ChartShot(name: "chart-gold-outside", width: 280) { materialChart("gold", lambda0: 0.2) },
    ChartShot(name: "chart-gold-hover", width: 280) { materialChart("gold", lambda0: 0.55, hover: 0.71) },
    ChartShot(name: "chart-bk7-dark", width: 280) { materialChart("bk7", lambda0: 0.633) },
    ChartShot(name: "chart-bk7-light", scheme: .light, width: 280) { materialChart("bk7", lambda0: 0.633) },
    ChartShot(name: "chart-index-dark", width: 280) {
        let lambda = (0..<MaterialCurveCache.pointCount).map { 0.3 + 1.7 * Double($0) / Double(MaterialCurveCache.pointCount - 1) }
        let curve = MaterialCurve(wavelengthUm: lambda, n: lambda.map { _ in 1.5 }, k: lambda.map { _ in 0 },
                                  eps1: lambda.map { _ in 2.25 }, eps2: lambda.map { _ in 0 }, at: nil)
        return AnyView(MaterialChart(curve: curve, lambda0: 0.633))
    },
    ChartShot(name: "chart-poles-edited-dark", width: 280) { materialChart("gold", lambda0: 0.55, edited: true) },
    ChartShot(name: "chart-gold-1064", width: 280) { materialChart("gold", lambda0: 1.064) },
    ChartShot(name: "chart-aluminium", width: 280) { materialChart("aluminium", lambda0: 0.633) },
    ChartShot(name: "chart-pole-bk7-10", width: 280) { materialChart("bk7", lambda0: 10) },
    ChartShot(name: "chart-pole-silica-10", width: 280) { materialChart("fused_silica", lambda0: 10) },
    ChartShot(name: "chart-pole-lorentz-g0", width: 280) { lorentzChart(gamma: 0) },
    ChartShot(name: "chart-pole-lorentz-g0005", width: 280) { lorentzChart(gamma: 0.005) },
    ChartShot(name: "chart-pole-lorentz-g0-light", scheme: .light, width: 280) { lorentzChart(gamma: 0, hover: 0.7) },
    ChartShot(name: "chart-profile-dark", host: .results, width: 560, height: 220) { profile(focusProfile(length: 4), length: 4) },
    ChartShot(name: "chart-profile-light", scheme: .light, host: .results, width: 560, height: 220) { profile(focusProfile(length: 4), length: 4) },
    ChartShot(name: "chart-profile-end", host: .results, width: 560, height: 220) { profile(focusProfile(length: 4.37), length: 4.37) },
    ChartShot(name: "chart-profile-long", host: .results, width: 560, height: 220) { profile(focusProfile(length: 37.5), length: 37.5) },
    ChartShot(name: "chart-profile-long-300", host: .results, width: 300, height: 200) { profile(focusProfile(length: 37.5), length: 37.5) },
    ChartShot(name: "chart-profile-short", host: .results, width: 300, height: 200) { profile(focusProfile(length: 0.35), length: 0.35) },
    ChartShot(name: "chart-profile-flat", host: .results, width: 560, height: 220) { profile(focusProfile(length: 4, flat: true), length: 4) },
    ChartShot(name: "chart-profile-hover", host: .results, width: 560, height: 220) { profile(focusProfile(length: 4), length: 4, hover: 2.13) },
    ChartShot(name: "chart-profile-hover-end", host: .results, width: 560, height: 220) { profile(focusProfile(length: 4), length: 4, hover: 3.85) },
    ChartShot(name: "chart-profile-hover-light", scheme: .light, host: .results, width: 560, height: 220) { profile(focusProfile(length: 4), length: 4, hover: 1.2) },
    ChartShot(name: "chart-profile-hover-peak-light", scheme: .light, host: .results, width: 560, height: 220) { profile(focusProfile(length: 4), length: 4, hover: 2.0) },
    ChartShot(name: "chart-profile-hover-left", host: .results, width: 560, height: 220) { profile(focusProfile(length: 4), length: 4, hover: 1.6) },
    ChartShot(name: "chart-profile-stale", host: .results, width: 560, height: 220) { profile(focusProfile(length: 4), length: 4, state: .dimmed(0.45)) },
    ChartShot(name: "chart-profile-updating", host: .results, width: 560, height: 220) { profile(focusProfile(length: 4), length: 4, state: .updating) },
    ChartShot(name: "chart-profile-pending", host: .results, width: 560, height: 220) { profile([], length: 4, state: .pending) },
    ChartShot(name: "chart-profile-narrow", host: .results, width: 260, height: 200) { profile(focusProfile(length: 4), length: 4) },
    ChartShot(name: "chart-profile-short-height", host: .results, width: 560, height: 130) { profile(focusProfile(length: 4), length: 4) },
    // Step C: puzzle charts from synthetic XOR results, one passing (17.5 dB) and one failing
    // (the 0-cases above the weakest 1).
    ChartShot(name: "chart-puzzle-bars-dark", host: .results, width: 420, height: 200) { puzzleBars(xorPass, shown: [true, false]) },
    ChartShot(name: "chart-puzzle-bars-fail-dark", host: .results, width: 420, height: 200) { puzzleBars(xorFail, shown: [true, true]) },
    ChartShot(name: "chart-puzzle-bars-light", scheme: .light, host: .results, width: 420, height: 200) { puzzleBars(xorPass, shown: [true, false]) },
    ChartShot(name: "chart-puzzle-bars-stale", host: .results, width: 420, height: 200) { puzzleBars(xorPass, shown: [true, false], stale: true) },
    ChartShot(name: "chart-puzzle-contrast-dark", host: .results, width: 420, height: 150) { puzzleContrast(xorPass) },
    ChartShot(name: "chart-puzzle-contrast-fail-dark", host: .results, width: 420, height: 150) { puzzleContrast(xorFail) },
    ChartShot(name: "chart-puzzle-contrast-light", scheme: .light, host: .results, width: 420, height: 150) { puzzleContrast(xorPass) },
    ChartShot(name: "chart-puzzle-score-dark", width: 210) { puzzleScore(17.5) },
    ChartShot(name: "chart-puzzle-score-low", width: 210) { puzzleScore(-60) },
    ChartShot(name: "chart-puzzle-score-light", scheme: .light, width: 210) { puzzleScore(8.2) },
    ChartShot(name: "chart-puzzle-score-percent", width: 210) {
        AnyView(ScoreBar(score: 95.5, thresholds: [80, 88, 92], pass: 80, scale: PuzzleScoreScale(label: "power", unit: "%")))
    },
]

/// A passing XOR result (the reference's numbers) and a failing one.
let xorPass: [Double] = [0, 0.506508650785045, 0.49493504610758715, 0.008759614810697206]
let xorFail: [Double] = [0.02, 0.31, 0.12, 0.18]

/// A synthetic evaluation of logic-xor with output values per case (00, 01, 10, 11).
@MainActor func xorEvaluation(_ values: [Double]) -> (Puzzle, PuzzleEvaluation)? {
    guard let puzzle = FringeBridge.puzzle("logic-xor") else { print("FAIL: no logic-xor"); return nil }
    let bits = [[false, false], [false, true], [true, false], [true, true]]
    let ones = [values[1], values[2]].min()!, zeros = max([values[0], values[3]].max()!, 1e-6)
    let score = 10 * log10(ones / zeros)
    let cases = zip(bits, values).enumerated().map { k, c -> [String: Any] in
        ["bits": c.0, "weights": [[c.0[0] ? 1 : 0, 0], [c.0[1] ? 1 : 0, 0]], "readings": [],
         "outputs": [["detector": "out", "target": k == 1 || k == 2, "value": c.1]]]
    }
    let json: [String: Any] = [
        "puzzle": "logic-xor", "valid": true, "issues": [], "sources": ["in-a", "in-b"], "inputs": ["in-a", "in-b"],
        "cases": cases, "metric": ["label": "contrast", "unit": "dB", "value": score, "text": "weakest 1 is \(Format.significant(ones)), strongest 0 is \(Format.significant(zeros))"],
        "score": score, "pass": 6.0, "passed": score >= 6, "stars": [6.0, 10, 15].filter { score >= $0 }.count,
        "star_thresholds": [6.0, 10, 15],
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: json),
          let evaluation = try? JSONDecoder().decode(PuzzleEvaluation.self, from: data) else { print("FAIL: synthetic evaluation"); return nil }
    return (puzzle, evaluation)
}

@MainActor func puzzleBars(_ values: [Double], shown: [Bool], stale: Bool = false) -> AnyView? {
    guard let (puzzle, evaluation) = xorEvaluation(values) else { return nil }
    let report = PuzzleReport(puzzle: puzzle, evaluation: evaluation)
    print("  bars \(values): rows pass \(report.rows.map { $0.passes.map { $0 ? "y" : "n" } ?? "-" }) contrast \(report.contrasts.map { Format.decibels($0.decibels) })")
    return AnyView(PuzzleBarChart(spec: report.barSpec(puzzle: puzzle, shownBits: shown, stale: stale)))
}

@MainActor func puzzleContrast(_ values: [Double]) -> AnyView? {
    guard let (puzzle, evaluation) = xorEvaluation(values),
          let spec = PuzzleReport(puzzle: puzzle, evaluation: evaluation).contrastSpec(puzzle: puzzle, evaluation: evaluation, stale: false) else { return nil }
    return AnyView(PuzzleContrastPlot(spec: spec))
}

func puzzleScore(_ score: Double) -> AnyView {
    AnyView(ScoreBar(score: score, thresholds: [6, 10, 15], pass: 6, scale: PuzzleScoreScale(label: "contrast", unit: "dB"), best: 17.5))
}

@MainActor func renderCharts(out: String, prefix: String?) throws {
    if prefix.map({ "chart-ticks".hasPrefix($0) || $0.hasPrefix("chart-ticks") }) ?? true { printTicks() }
    for shot in chartShots {
        guard prefix.map({ shot.name.hasPrefix($0) }) ?? true else { continue }
        guard let content = shot.view() else { print("FAIL \(shot.name): nothing to draw"); continue }
        let view = content
            .frame(width: shot.width, height: shot.height)
            .padding(12)
            .environment(\.colorScheme, shot.scheme)
            .environment(\.displayScale, 2)
            .plotSurface(shot.surface)
            .background(shot.surface)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else { print("FAIL \(shot.name): nothing rendered"); continue }
        try writePNG(image, to: "\(out)/\(shot.name).png")
    }
}

/// `chart-ticks`: the tick lists of the axes the plot style specifies, to stdout.
@MainActor func printTicks() {
    func show(_ name: String, _ axis: PlotAxis) {
        let l = axis.layout(measure: PlotFrame.measureTick)
        let exp = l.exponent.map { " " + PlotAxis.exponentLabel($0) } ?? ""
        print("  ticks \(name): [\(l.domain.lowerBound), \(l.domain.upperBound)] \(l.ticks.map(\.label).joined(separator: " "))\(exp)")
    }
    print("chart-ticks:")
    show("x 0…4 @516", PlotAxis(domain: 0...4, length: 516, minSpacing: 36, ends: .labelExact))
    show("x 0…4.37 @516", PlotAxis(domain: 0...4.37, length: 516, minSpacing: 36, ends: .labelExact))
    show("x 0…37.5 @516", PlotAxis(domain: 0...37.5, length: 516, minSpacing: 36, ends: .labelExact))
    show("x 0…37.5 @256", PlotAxis(domain: 0...37.5, length: 256, minSpacing: 36, ends: .labelExact))
    show("x 0…0.35 @256", PlotAxis(domain: 0...0.35, length: 256, minSpacing: 36, ends: .labelExact))
    show("x 0.3…2 @240", PlotAxis(domain: 0.3...2, length: 240, minSpacing: 36, ends: .labelExact))
    show("x 0.16…2 @240", PlotAxis(domain: 0.16...2, length: 240, minSpacing: 36, ends: .labelExact))
    show("x 0.3…2 @200", PlotAxis(domain: 0.3...2, length: 200, minSpacing: 36, ends: .labelExact))
    show("λ 0.3…2 @240", PlotAxis(domain: 0.3...2, length: 240, minSpacing: 36, ends: .labelExact, exactEnds: false))
    show("λ 0.3…2 @200", PlotAxis(domain: 0.3...2, length: 200, minSpacing: 36, ends: .labelExact, exactEnds: false))
    show("λ 0.3…12 @240", PlotAxis(domain: 0.3...12, length: 240, minSpacing: 36, ends: .labelExact, exactEnds: false))
    show("λ 0.3…13 @240", PlotAxis(domain: 0.3...13, length: 240, minSpacing: 36, ends: .labelExact, exactEnds: false))
    show("λ 0.1…2 @240", PlotAxis(domain: 0.1...2, length: 240, minSpacing: 36, ends: .labelExact, exactEnds: false))
    show("λ 0.3…3 @240", PlotAxis(domain: 0.3...3, length: 240, minSpacing: 36, ends: .labelExact, exactEnds: false))
    show("n 1.4995…1.5528 @84", PlotAxis(domain: 1.4995...1.5528, length: 84, minSpacing: 20, ends: .snapOut, minSpan: 0.1))
    show("n 0.13…1.6 @84", PlotAxis(domain: 0.13...1.6, length: 84, minSpacing: 20, ends: .snapOut, minSpan: 0.1))
    show("k 0…12.5 @84", PlotAxis(domain: 0...12.5, length: 84, minSpacing: 20, ends: .snapOut, fromZero: true))
    show("k 0…0.0005 @84", PlotAxis(domain: 0...0.0005, length: 84, minSpacing: 20, ends: .snapOut, fromZero: true))
    show("y 0…2.06 @120", PlotAxis(domain: 0...2.06, length: 120, minSpacing: 20, ends: .snapOut, fromZero: true))
    show("y 0…2.06 @80", PlotAxis(domain: 0...2.06, length: 80, minSpacing: 20, ends: .snapOut, fromZero: true))
    show("y 0…18000 @120", PlotAxis(domain: 0...18000, length: 120, minSpacing: 20, ends: .snapOut, fromZero: true))
    show("y −0.4…1.2 @120", PlotAxis(domain: -0.4...1.2, length: 120, minSpacing: 20, ends: .snapOut))
}

/// Opens the lens example and adds a detector named for what it measures at the paraxial
/// focus: a vertical 4 µm line ("Focus") or a 1 µm box ("Spot").
@MainActor func addDetectorAtFocus(_ kind: DetectorKind, in m: AppState) async throws {
    try open("lens", in: m)
    await settle(m)
    guard let exact = m.paraxialFocusPoints.first, exact.count == 2 else { throw ShotError(description: "no focus") }
    // Placed as a user would type it: to the field's two decimals.
    let focus = exact.map { ($0 * 100).rounded() / 100 }
    m.addDetector(kind)
    guard let id = m.selectedDetectorID else { throw ShotError(description: "no detector added") }
    m.edit("Move Detector") { doc in
        switch kind {
        case .line:
            doc.scene[detector: id]?.shape = .line(LineGeometry(x1Um: focus[0], y1Um: focus[1] - 2, x2Um: focus[0], y2Um: focus[1] + 2))
            doc.scene[detector: id]?.name = "Focus"
        case .box:
            doc.scene[detector: id]?.shape = .box(BoxGeometry(xUm: focus[0], yUm: focus[1], widthUm: 1, heightUm: 1))
            doc.scene[detector: id]?.name = "Spot"
        }
    }
    await settle(m)
    _ = await wait(10) { m.detectorReadings[id] != nil }
    let reading = m.detectorReadings[id]
    print("  \(kind.rawValue) detector at (\(focus[0]), \(focus[1])): total=\(reading?.totalValue ?? .nan) incident=\(reading?.incidentValue ?? .nan) label=\(m.detectorLabels[id] ?? "-") solver revision unchanged by detector edits: \(m.solver.isShownStale == false)")
}

/// Shows the results area, waits for the readings and the selected line's profile, and
/// puts the pointer over the middle of the image so the status bar has a readout.
@MainActor func showResults(in m: AppState) async throws {
    m.isResultsPresented = true
    await settle(m)
    _ = await wait(10) { m.scene.detectors.filter(\.enabled).allSatisfy { m.detectorReadings[$0.id] != nil } }
    if let detector = m.resultsDetector, case .line(let line) = detector.shape, let key = m.profileKey(for: line) {
        m.requestProfile(for: line)
        _ = await wait(10) { m.profiles[key] != nil }
        print("  profile \(detector.displayName): \(m.profiles[key]?.count ?? 0) points, peak total \(m.profiles[key]?.map(\.total).max() ?? .nan)")
    }
    let rect = m.geometry.imageRect
    m.updateHover(at: CGPoint(x: rect.midX, y: rect.midY))
    print("  rows: \(m.resultRows.map { "\($0.name) total=\($0.total.map { Format.significant($0) } ?? "-") ratio=\($0.ratio.map { Format.significant($0) } ?? "-")" }) hover=\(m.hover.map { MathTypesetter.plain(StatusBar.readout($0)) } ?? "-")")
}

/// Window size in points of the shot being captured.
@MainActor var windowSize = CGSize(width: 1440, height: 900)
/// The unified toolbar's height, which the panes scroll under.
let toolbarHeight: CGFloat = 52

/// Symbols the redesign uses (ui-plan §6.4); the harness prints any this system lacks.
let plannedSymbols = [
    "light.beacon.max", "water.waves", "dot.radiowaves.left.and.right", "line.diagonal", "square.dashed",
    "rainbow", "wave.3.right", "chart.xyaxis.line", "checkmark.seal", "arrow.counterclockwise", "lightbulb",
    "star.fill", "star", "checkmark.circle.fill", "xmark.circle.fill", "lock.fill", "scope", "plus", "minus.circle",
    "chevron.backward", "chevron.left", "chevron.right", "plus.circle",
    "square.grid.2x2", "arrow.turn.up.right", "wave.3.right", "switch.2", "circle.lefthalf.filled", "puzzlepiece",
    "chevron.left.chevron.right", "stop.fill",
]

@MainActor func open(_ example: String, in m: AppState) throws {
    guard let info = m.examples.first(where: { $0.name == example }) else { throw ShotError(description: "no example \(example)") }
    m.loadExample(info)
}

/// Waits until the preview is solved and rendered.
@MainActor func settle(_ m: AppState) async {
    _ = await wait(120) { !m.solver.isRunning && m.solver.shown != nil && !m.solver.isShownStale }
    _ = await wait(30) { m.isViewportCurrent }
    try? await Task.sleep(for: .milliseconds(600))
}

/// The inspector's scroll view: the rightmost SwiftUI scroll view.
@MainActor func inspectorScrollView(_ root: NSView) -> NSScrollView? {
    findViews(root) { typeName($0) == "HostingScrollView" }
        .max { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX } as? NSScrollView
}

// MARK: - Entry

/// The harness's defaults domain: its own, never the app's.
let defaultsDomain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName

@main
enum UIShots {
    static func main() {
        // Positional arguments come before the first option (the -Apple... defaults).
        let args = Array(CommandLine.arguments.prefix { !$0.hasPrefix("-") })
        guard args.count >= 2 else {
            FileHandle.standardError.write("usage: fringe-ui-shots OUT_DIR [NAME_PREFIX]\n".data(using: .utf8)!)
            exit(2)
        }
        guard defaultsDomain == "fringe-ui-shots" else {
            FileHandle.standardError.write("refusing to run with defaults domain \(defaultsDomain)\n".data(using: .utf8)!)
            exit(2)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // Only what a shot writes into the harness's own domain may be restored.
        MainActor.assumeIsolated { AppState.readsLegacyDocument = false }
        let missing = plannedSymbols.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }
        print(missing.isEmpty ? "symbols: all \(plannedSymbols.count) found" : "symbols missing: \(missing.joined(separator: ", "))")
        _ = MainActor.assumeIsolated {
            Task {
                var failed = false
                let prefix = args.count >= 3 ? args[2] : nil
                let selected = shots.filter { prefix == nil || $0.name.hasPrefix(prefix!) }
                let charts = prefix.map { "chart-".hasPrefix($0) || $0.hasPrefix("chart-") } ?? true
                if selected.isEmpty && !charts { print("no shot matches \(args[2])"); failed = true }
                if charts {
                    do { try renderCharts(out: args[1], prefix: prefix) } catch { print("FAIL charts: \(error)"); failed = true }
                }
                for shot in selected {
                    do { try await render(shot, out: args[1]) } catch {
                        print("FAIL \(shot.name): \(error)"); failed = true
                    }
                }
                resetDefaults()
                exit(failed ? 1 : 0)
            }
        }
        RunLoop.main.run()
    }
}

/// A document as a schema version 2 build saved it: the default scene at 633 nm with the
/// beam tilted by 10°.
@MainActor func saveV2Document(_ defaults: UserDefaults) {
    guard var scene = try? JSONSerialization.jsonObject(with: Data(SchemaSelfTest.v2Fixture.utf8)) as? [String: Any],
          var source = scene["source"] as? [String: Any],
          let display = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(DisplaySettings())),
          let output = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(OutputFormat())) else { return }
    scene["wavelength_um"] = 0.633
    source["angle_deg"] = 10.0
    scene["source"] = source
    let document: [String: Any] = ["scene": scene, "display": display, "output": output]
    if let data = try? JSONSerialization.data(withJSONObject: document) {
        defaults.set(data, forKey: AppState.previousDocumentKey)
    }
}

/// Clears everything the app saves, in the harness's own domain only.
@MainActor func resetDefaults() {
    let d = UserDefaults.standard
    d.removePersistentDomain(forName: defaultsDomain)
    for key in [AppState.documentKey, AppState.previousDocumentKey, AppState.unreadableDocumentKey, "fringe.puzzles.progress.v1"] {
        d.removeObject(forKey: key)
    }
    d.synchronize()
}

/// Draws as the active window, as in a screenshot of the app in use, without ever being
/// ordered front or made key.
final class OffscreenKeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

struct ShotError: Error, CustomStringConvertible { var description: String }

@MainActor func wait(_ seconds: Double, until done: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while !done() {
        if Date() > end { return false }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return true
}

@MainActor func render(_ shot: UIShot, out: String) async throws {
    resetDefaults()
    shot.defaults?(UserDefaults.standard)
    windowSize = shot.size
    Appearance.light = shot.light
    NSApp.appearance = NSAppearance(named: shot.light ? .aqua : .darkAqua)
    defer { NSApp.appearance = NSAppearance(named: .darkAqua); Appearance.light = false }
    let model = AppState()

    let host = NSHostingView(rootView: FringeWindow().environment(model))
    host.sceneBridgingOptions = [.toolbars, .title]
    let window = OffscreenKeyWindow(
        contentRect: NSRect(origin: .zero, size: shot.size),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: shot.light ? .aqua : .darkAqua)
    window.toolbarStyle = .unified
    window.title = "Fringe"
    window.contentView = host
    window.setContentSize(shot.size)
    // Never ordered front: the window lives offscreen and is only drawn into a bitmap.
    defer {
        window.contentView = nil
        window.close()
    }

    _ = await wait(10) { model.containerSize.width > 0 }
    try? await Task.sleep(for: .milliseconds(400))
    try await shot.setup(model)
    if let label = shot.scrollInspectorTo, let sv = inspectorScrollView(host), let doc = sv.documentView {
        if let target = findViews(doc, where: { $0.accessibilityLabel() == label }).first {
            target.scrollToVisible(target.bounds)
            try? await Task.sleep(for: .milliseconds(300))
        } else {
            print("  \(shot.name): no inspector view labelled \(label)")
        }
    } else if let fraction = shot.scrollInspectorFraction, let sv = inspectorScrollView(host), let doc = sv.documentView {
        let travel = max(0, doc.frame.height - sv.contentView.bounds.height)
        // Flipped document views count y from the top.
        let y = doc.isFlipped ? travel * fraction : travel * (1 - fraction)
        sv.contentView.scroll(to: NSPoint(x: 0, y: y))
        sv.reflectScrolledClipView(sv.contentView)
        try? await Task.sleep(for: .milliseconds(300))
    }
    try? await Task.sleep(for: .seconds(1))
    let status = model.solver.status.title
    print("\(shot.name): \(status) caption=\(model.caption.map(MathTypesetter.plain) ?? "-") container=\(model.containerSize)")

    // The canvas's Metal layer is invisible to renderInContext: show the same frame as an
    // image while capturing.
    let viewports = findViews(host) { $0 is ViewportView }.compactMap { $0 as? ViewportView }
    viewports.forEach { $0.bakeForCapture() }
    let windowImage = try captureWindow(window)
    viewports.forEach { $0.unbakeAfterCapture() }
    try writePNG(try flatten(windowImage), to: "\(out)/\(shot.name).png")
}

// MARK: - Capture

func findViews(_ root: NSView, where test: (NSView) -> Bool) -> [NSView] {
    (test(root) ? [root] : []) + root.subviews.flatMap { findViews($0, where: test) }
}

func typeName(_ v: Any) -> String { String(describing: type(of: v)) }

/// renderInContext (what cacheDisplay uses) cannot draw Liquid Glass: backdrop layers
/// blank their whole parent, and colour-matrix filters, which SwiftUI uses to tint its
/// white chrome, are ignored. Hide the backdrops and bake each matrix into its layer.
@MainActor enum Bake {
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// A Core Animation filter's type; nil for anything else (a CIFilter has no "type").
    static func type(_ f: AnyObject) -> String? {
        guard let filterClass = NSClassFromString("CAFilter"), f.isKind(of: filterClass) else { return nil }
        return f.value(forKey: "type") as? String
    }

    static func isVibrant(_ f: AnyObject) -> Bool { type(f)?.hasPrefix("vibrantColorMatrix") ?? false }

    static func matrix(_ f: AnyObject) -> [Float]? {
        guard let t = type(f), t == "colorMatrix" || t.hasPrefix("vibrantColorMatrix"),
              let v = f.value(forKey: "inputColorMatrix") as? NSValue else { return nil }
        var m = [Float](repeating: 0, count: 20)
        m.withUnsafeMutableBytes { v.getValue($0.baseAddress!, size: 80) }
        return m
    }

    static func apply(_ m: [Float], _ c: [CGFloat]) -> [CGFloat] {
        let r = Float(c[0]), g = Float(c[1]), b = Float(c[2]), a = Float(c[3])
        return (0..<4).map { i in
            CGFloat(min(1, max(0, m[i*5]*r + m[i*5+1]*g + m[i*5+2]*b + m[i*5+3]*a + m[i*5+4])))
        }
    }

    /// What a vibrant fill tints: the glass behind the layer, about this grey.
    static var backdrop: [CGFloat] { Appearance.light ? [0.93, 0.93, 0.94, 1] : [0.16, 0.16, 0.17, 1] }

    /// A plain colour matrix recolours the layer's own pixels. A vibrant matrix is an
    /// identity plus a lift that on screen applies to the glass behind: a fill (a grouped
    /// form row, a track) becomes the lifted backdrop masked by the fill's alpha. (Vibrant
    /// text and symbols, drawn as black masks, are mapped to label greys in `run`.)
    static func filtered(_ m: [Float], vibrant: Bool, _ c: [CGFloat]) -> [CGFloat] {
        guard vibrant else { return apply(m, c) }
        let o = apply(m, backdrop)
        return [o[0], o[1], o[2], c[3] * (o[3] > 0 ? o[3] : 0)]
    }

    static func color(_ m: [Float], vibrant: Bool, _ color: CGColor?) -> CGColor? {
        guard let color, let rgb = color.converted(to: srgb, intent: .defaultIntent, options: nil),
              let c = rgb.components, c.count == 4 else { return color }
        let o = filtered(m, vibrant: vibrant, c)
        return CGColor(srgbRed: o[0], green: o[1], blue: o[2], alpha: o[3])
    }

    static func hideBackdrops(_ layer: CALayer) {
        if typeName(layer).contains("Backdrop") { layer.isHidden = true }
        for s in layer.sublayers ?? [] { hideBackdrops(s) }
    }

    /// Hides the large glass shapes and tints of a pane (it is painted flat instead).
    static func hideGlassTint(_ layer: CALayer) {
        let name = typeName(layer)
        let big = layer.bounds.width >= 200 && layer.bounds.height >= 200
        let tint = layer.backgroundColor != nil && (layer.filters ?? []).contains { isVibrant($0 as AnyObject) }
        if big && (name == "CAChameleonLayer" || name == "CASDFLayer" || name == "SDFLayer" || tint) {
            layer.isHidden = true
            return
        }
        for s in layer.sublayers ?? [] { hideGlassTint(s) }
    }

    /// Window regions (points, origin bottom-left) for the label levels below.
    static var sidebarMaxX: CGFloat = 0
    static var toolbarMinY: CGFloat = .infinity

    /// The grey a vibrant label shows on screen, from the lift of its matrix: about 0.95 for
    /// primary text, 0.3 for secondary, 0.2 for tertiary and 0.08 for quaternary. The
    /// sidebar and the toolbar draw their primary labels at the lower lifts over brighter
    /// glass, so they map higher there.
    static func labelGray(lift: CGFloat, in rect: CGRect) -> CGFloat {
        if Appearance.light { return lightLabelGray(lift: lift) }
        if rect.minY >= toolbarMinY { return 0.92 }
        if rect.maxX <= sidebarMaxX + 1 {
            switch lift {
            case 0.5...: return 0.92
            case 0.25...: return 0.86
            case 0.15...: return 0.56
            default: return 0.40
            }
        }
        switch lift {
        case 0.5...: return 0.92
        case 0.25...: return 0.56
        case 0.15...: return 0.42
        default: return 0.30
        }
    }

    /// Bakes each colour matrix into its layer and every layer below it, since a filter on
    /// a container recolours what its sublayers draw too.
    /// The accent (blue, dark appearance) that sidebar icons, switches and slider fills show
    /// in an active window.
    static var accent: [CGFloat] { Appearance.light ? [0, 122 / 255, 1, 1] : [10 / 255, 132 / 255, 1, 1] }

    /// Light appearance: label levels as greys on the light glass.
    static func lightLabelGray(lift: CGFloat) -> CGFloat {
        switch abs(lift) {
        case 0.5...: 0.1
        case 0.25...: 0.45
        case 0.15...: 0.6
        default: 0.75
        }
    }
    static var accentColor: CGColor { CGColor(srgbRed: accent[0], green: accent[1], blue: accent[2], alpha: 1) }

    static func run(_ layer: CALayer, scale: CGFloat, inherited: (m: [Float], vibrant: Bool)? = nil) {
        let filters = layer.filters ?? []
        // A matrix can also come as the compositing filter (vibrant symbols: the sidebar icons).
        var sidebarIcon = false
        if let comp = layer.compositingFilter as? NSObject, let filterClass = NSClassFromString("CAFilter"),
           comp.isKind(of: filterClass), matrix(comp) != nil, layer.convert(layer.bounds, to: nil).maxX <= sidebarMaxX + 1 {
            layer.compositingFilter = nil
            layer.filters = filters + [comp]
            sidebarIcon = typeName(layer) == "ImageLayer"
        }
        let own = (layer.filters ?? []).first(where: { matrix($0 as AnyObject) != nil })
        let current = own.flatMap { f in matrix(f as AnyObject).map { (m: $0, vibrant: isVibrant(f as AnyObject)) } } ?? inherited
        for s in layer.sublayers ?? [] { run(s, scale: scale, inherited: current) }
        guard let (m, vibrant) = current else { return }
        layer.backgroundColor = color(m, vibrant: vibrant, layer.backgroundColor)
        if layer.borderWidth > 0 { layer.borderColor = color(m, vibrant: vibrant, layer.borderColor) }
        if let shape = layer as? CAShapeLayer {
            shape.fillColor = color(m, vibrant: vibrant, shape.fillColor)
            shape.strokeColor = color(m, vibrant: vibrant, shape.strokeColor)
        }
        if layer.contents != nil, layer.bounds.width >= 1, layer.bounds.height >= 1 {
            let w = Int(ceil(layer.bounds.width * scale)), h = Int(ceil(layer.bounds.height * scale))
            if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: srgb,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                let savedBG = layer.backgroundColor, savedSubs = layer.sublayers, savedFilters = layer.filters
                layer.backgroundColor = nil; layer.sublayers = nil; layer.filters = nil
                // Render top-down, the way the layer's contents are stored.
                ctx.translateBy(x: 0, y: CGFloat(h))
                ctx.scaleBy(x: scale, y: -scale)
                ctx.translateBy(x: -layer.bounds.minX, y: -layer.bounds.minY)
                layer.render(in: ctx)
                layer.backgroundColor = savedBG; layer.sublayers = savedSubs; layer.filters = savedFilters
                let p = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
                let rect = layer.convert(layer.bounds, to: nil)
                // Sidebar symbols: a tinting matrix (not an identity plus a lift) over a faint mask.
                let symbol = sidebarIcon || (vibrant && m[0] < 0.9)
                let gray = symbol ? 0.72 : vibrant ? labelGray(lift: CGFloat(m[4]), in: rect) : 0
                var maxAlpha: CGFloat = 0
                if symbol { for i in 0..<(w * h) { maxAlpha = max(maxAlpha, CGFloat(p[i*4+3]) / 255) } }
                let alphaGain = symbol && maxAlpha > 0 ? 1 / maxAlpha : 1
                for i in 0..<(w * h) {
                    let a = CGFloat(p[i*4+3]) / 255
                    guard a > 0 else { continue }
                    let c = [CGFloat(p[i*4]) / 255 / a, CGFloat(p[i*4+1]) / 255 / a, CGFloat(p[i*4+2]) / 255 / a, a]
                    // Vibrant text and symbols are drawn as black masks; on screen the glass
                    // behind shows through them, lifted to the label's level.
                    let o = sidebarIcon ? [accent[0], accent[1], accent[2], min(1, a * alphaGain)]
                        : vibrant && c[0] + c[1] + c[2] < 1.5 ? [gray, gray, gray, min(1, a * alphaGain)] : filtered(m, vibrant: vibrant, c)
                    p[i*4] = UInt8((o[0] * o[3] * 255).rounded()); p[i*4+1] = UInt8((o[1] * o[3] * 255).rounded())
                    p[i*4+2] = UInt8((o[2] * o[3] * 255).rounded()); p[i*4+3] = UInt8((o[3] * 255).rounded())
                }
                if symbol, let superlayer = layer.superlayer {
                    // Symbol image layers redraw their own contents; show the baked image in
                    // a plain layer next to it instead.
                    let baked = CALayer()
                    baked.frame = layer.frame
                    baked.contents = ctx.makeImage()
                    baked.contentsScale = scale
                    baked.contentsGravity = .resize
                    superlayer.insertSublayer(baked, above: layer)
                    layer.isHidden = true
                } else {
                    layer.contents = ctx.makeImage()
                    layer.contentsScale = scale
                    layer.contentsGravity = .resize
                    layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
                    layer.contentsCenter = CGRect(x: 0, y: 0, width: 1, height: 1)
                }
            }
        }
        if own != nil { layer.filters = (layer.filters ?? []).filter { matrix($0 as AnyObject) == nil } }
    }
}

// Colours of the parts of the window that are Liquid Glass and so cannot be captured.
/// The appearance of the window being captured.
@MainActor enum Appearance {
    static var light = false
}

@MainActor var windowBase: CGColor { Appearance.light ? CGColor(srgbRed: 0.96, green: 0.96, blue: 0.965, alpha: 1) : CGColor(srgbRed: 0.110, green: 0.110, blue: 0.118, alpha: 1) }
@MainActor var inspectorFill: CGColor { Appearance.light ? CGColor(srgbRed: 0.985, green: 0.985, blue: 0.99, alpha: 1) : CGColor(srgbRed: 0.137, green: 0.137, blue: 0.145, alpha: 1) }
@MainActor var platterSelected: CGColor { Appearance.light ? CGColor(gray: 1, alpha: 1) : CGColor(srgbRed: 0.36, green: 0.36, blue: 0.38, alpha: 1) }
@MainActor var rowSelected: CGColor { Appearance.light ? CGColor(srgbRed: 0.86, green: 0.86, blue: 0.87, alpha: 1) : CGColor(srgbRed: 0.27, green: 0.27, blue: 0.29, alpha: 1) }

/// Captures the whole window (title bar, toolbar, sidebar, canvas, inspector) at 2x and
/// paints in what renderInContext leaves out: the selected sidebar row, the prominent
/// Export button, the selected toolbar segment and the traffic lights.
@MainActor func captureWindow(_ window: NSWindow) throws -> CGImage {
    let scale: CGFloat = 2
    guard let frameView = window.contentView?.superview, let rootLayer = frameView.layer else {
        throw ShotError(description: "no frame view")
    }
    frameView.layoutSubtreeIfNeeded()
    frameView.displayIfNeeded()
    let size0 = frameView.bounds.size
    let all = findViews(frameView) { _ in true }
    func rect(_ v: NSView) -> CGRect { v.convert(v.bounds, to: nil) } // window coords, origin bottom-left

    // Gather what has to be painted before the glass is stripped.
    let glass = all.filter { typeName($0) == "NSGlassEffectView" }
    let panes = glass.filter { $0.frame.height > 300 }.map(rect).sorted { $0.minX < $1.minX }
    // The prominent Export button: the one toolbar item that is not on a glass capsule.
    func onGlass(_ v: NSView) -> Bool { v.superview.map { typeName($0) == "NSGlassEffectView" || onGlass($0) } ?? false }
    let exportButton = all.first { v in
        typeName(v).hasPrefix("ToolbarItemHostingView") && rect(v).width > 60 && rect(v).width < 120
            && rect(v).minY > windowSize.height - 60 && !onGlass(v)
    }
    let selectedRows = all.filter { v in
        typeName(v) == "NSVisualEffectView" && v.superview.map(typeName) == "ListTableRowView"
    }
    for v in selectedRows { v.isHidden = true }
    // The window's own material and the split-view shadows draw as opaque grey offscreen.
    for v in all where (typeName(v) == "NSVisualEffectView" && v.superview === frameView) || typeName(v) == "_NSSplitViewShadowView" {
        v.isHidden = true
    }

    Bake.hideBackdrops(rootLayer)
    Bake.sidebarMaxX = panes.first?.maxX ?? 0
    Bake.toolbarMinY = size0.height - toolbarHeight
    // Inspector content scrolled under the toolbar is hidden there on screen by the scroll
    // edge effect; offscreen it would draw over the toolbar, so clip it at the toolbar.
    if let sv = inspectorScrollView(frameView), let clipLayer = sv.contentView.layer {
        let mask = CALayer()
        mask.frame = clipLayer.convert(CGRect(x: 0, y: 0, width: size0.width, height: size0.height - toolbarHeight), from: rootLayer)
        mask.backgroundColor = CGColor(gray: 1, alpha: 1)
        clipLayer.mask = mask
    }
    Bake.run(rootLayer, scale: scale)

    // Switches that are on and the filled part of slider tracks show the accent, as in an
    // active window; offscreen their fills are vibrant greys.
    func sublayers(_ l: CALayer) -> [CALayer] { (l.sublayers ?? []).flatMap { [$0] + sublayers($0) } }
    for v in all where typeName(v) == "PlatformSwitch" {
        guard let layer = v.layer else { continue }
        let r = rect(v)
        let filled = sublayers(layer).filter { $0.backgroundColor != nil }
        let tracks = filled.filter { abs($0.bounds.width - r.width) < 2 && abs($0.bounds.height - r.height) < 2 }
        guard let knob = filled.first(where: { $0.bounds.width < r.width * 0.8 }) else { continue }
        // A new accent track over the switch's own tracks, which AppKit redraws over any
        // colour set on their layers.
        guard knob.convert(knob.bounds, to: nil).midX > r.midX, let track = tracks.last, let parent = knob.superlayer,
              let at = parent.sublayers?.firstIndex(where: { $0.frame == knob.frame }) else { continue }
        let fill = CALayer()
        fill.frame = parent.convert(track.bounds, from: track)
        fill.cornerRadius = max(track.cornerRadius, fill.frame.height / 2)
        fill.cornerCurve = .continuous
        fill.backgroundColor = Bake.accentColor
        parent.insertSublayer(fill, at: UInt32(at))
        // The knob draws below the new track offscreen: set a white knob on top.
        let thumb = CALayer()
        thumb.frame = knob.frame
        thumb.cornerRadius = knob.frame.height / 2
        thumb.cornerCurve = .continuous
        thumb.backgroundColor = CGColor(gray: 1, alpha: 1)
        parent.insertSublayer(thumb, above: fill)
    }
    for l in [rootLayer] + sublayers(rootLayer) {
        let kids = (l.sublayers ?? []).filter { !$0.isHidden && $0.backgroundColor != nil }
        for track in kids where track.frame.height >= 2 && track.frame.height <= 8 && track.frame.width >= 60 {
            guard let knob = kids.first(where: { k in
                k !== track && (k.filters ?? []).isEmpty && (12...30).contains(k.frame.width) && (12...30).contains(k.frame.height)
                    && abs(k.frame.midY - track.frame.midY) < 3 && k.frame.midX >= track.frame.minX && k.frame.midX <= track.frame.maxX
            }) else { continue }
            let fill = CALayer()
            fill.frame = CGRect(x: track.frame.minX, y: track.frame.minY, width: knob.frame.midX - track.frame.minX, height: track.frame.height)
            fill.cornerRadius = track.cornerRadius
            fill.cornerCurve = track.cornerCurve
            fill.backgroundColor = Bake.accentColor
            // Below the knob (and its shadow) but above the track and any fill drawn on it.
            let at = (l.sublayers ?? []).firstIndex { $0.frame == knob.frame } ?? (l.sublayers ?? []).count
            l.insertSublayer(fill, at: UInt32(at))
        }
    }

    // Paint glass shapes in place, inside the view tree, below the controls drawn on them.
    // (The sidebar and inspector panes themselves are drawn by the capture as flat dark
    // panels; a floating Liquid Glass sidebar cannot be reproduced offscreen.)
    func underlay(_ host: NSView, frame: CGRect, color: CGColor, radius: CGFloat) {
        guard let layer = host.layer else { return }
        let fill = CALayer()
        fill.frame = frame
        fill.backgroundColor = color
        fill.cornerRadius = radius
        fill.cornerCurve = .continuous
        layer.insertSublayer(fill, at: 0)
    }
    let paneViews = glass.filter { $0.frame.height > 300 }.sorted { rect($0).minX < rect($1).minX }
    for pane in paneViews { if let l = pane.layer { Bake.hideGlassTint(l) } }
    if paneViews.count > 1, let inspector = paneViews.last {
        underlay(inspector, frame: inspector.bounds, color: inspectorFill, radius: 0)
    }
    for v in selectedRows {
        if let row = v.superview { underlay(row, frame: v.frame, color: rowSelected, radius: 10) }
    }
    // The prominent Export button's accent capsule is glass too.
    if let exportButton {
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB)!.cgColor
        underlay(exportButton, frame: exportButton.bounds, color: accent, radius: exportButton.bounds.height / 2)
    }

    let size = frameView.bounds.size
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
        throw ShotError(description: "no bitmap")
    }
    rep.size = size
    frameView.cacheDisplay(in: frameView.bounds, to: rep)
    guard let ui = rep.cgImage else { throw ShotError(description: "capture failed") }

    let w = Int(size.width * scale), h = Int(size.height * scale)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: Bake.srgb,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ShotError(description: "no context") }
    ctx.scaleBy(x: scale, y: scale)
    let bounds = CGRect(origin: .zero, size: size)
    ctx.setFillColor(windowBase); ctx.fill(bounds)

    ctx.draw(ui, in: bounds)

    /// The colour of the capture at a point (window coordinates).
    func sample(_ p: CGPoint) -> CGColor {
        var px = [UInt8](repeating: 0, count: 4)
        let c = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: Bake.srgb,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(ui, in: CGRect(x: -p.x * scale, y: -p.y * scale, width: CGFloat(ui.width), height: CGFloat(ui.height)))
        return CGColor(srgbRed: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
    }

    // The selected segment of the toolbar's solver picker is a glass platter, and its label
    // is drawn on the glass: both are set again on top of the capture.
    for seg in all where typeName(seg) == "SwiftUISegmentedControl" && rect(seg).minY > size.height - 52 {
        guard let control = findViews(seg, where: { $0 is NSSegmentedControl }).first as? NSSegmentedControl else { continue }
        let r = rect(seg)
        let n = max(1, control.segmentCount), i = max(0, control.selectedSegment)
        let inner = r.insetBy(dx: 4, dy: 4)
        let segW = inner.width / CGFloat(n)
        let pill = CGRect(x: inner.minX + CGFloat(i) * segW, y: inner.minY, width: segW, height: inner.height)
        func drawLabel(_ k: Int, in box: CGRect, color: NSColor) {
            let attr = NSAttributedString(string: control.label(forSegment: k) ?? "", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: color,
            ])
            let line = CTLineCreateWithAttributedString(attr)
            let b = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
            ctx.textPosition = CGPoint(x: box.midX - b.width / 2 - b.minX, y: box.midY - 4.5)
            CTLineDraw(line, ctx)
        }
        // The unselected labels draw at varying greys offscreen: set them again at one grey,
        // over the capsule's own colour.
        for k in 0..<n where k != i {
            let box = CGRect(x: inner.minX + CGFloat(k) * segW, y: inner.minY, width: segW, height: inner.height)
            let probe = CGPoint(x: k == 0 ? box.maxX - 2 : box.minX + 2, y: box.midY)
            ctx.setFillColor(sample(probe))
            ctx.fill(box.insetBy(dx: 3, dy: 3))
            drawLabel(k, in: box, color: NSColor(white: Appearance.light ? 0.35 : 0.62, alpha: 1))
        }
        ctx.setFillColor(platterSelected)
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil)); ctx.fillPath()
        drawLabel(i, in: pill, color: Appearance.light ? .black : .white)
    }

    // Traffic lights as in an active window (offscreen they draw as inactive grey).
    let lights: [String: (CGColor, CGColor)] = [
        "_NSThemeCloseWidget": (CGColor(srgbRed: 1.0, green: 0.373, blue: 0.341, alpha: 1), CGColor(srgbRed: 0.88, green: 0.27, blue: 0.24, alpha: 1)),
        "_NSThemeWidget": (CGColor(srgbRed: 0.996, green: 0.737, blue: 0.180, alpha: 1), CGColor(srgbRed: 0.87, green: 0.62, blue: 0.13, alpha: 1)),
        "_NSThemeZoomWidget": (CGColor(srgbRed: 0.157, green: 0.784, blue: 0.251, alpha: 1), CGColor(srgbRed: 0.10, green: 0.66, blue: 0.19, alpha: 1)),
    ]
    for v in all {
        guard let (fill, rim) = lights[typeName(v)] else { continue }
        let r = rect(v).insetBy(dx: 0.5, dy: 0.5)
        ctx.setFillColor(fill); ctx.fillEllipse(in: r)
        ctx.setStrokeColor(rim); ctx.setLineWidth(0.5); ctx.strokeEllipse(in: r)
    }
    guard let image = ctx.makeImage() else { throw ShotError(description: "compose window failed") }
    return image
}

// MARK: - Output

/// The window as an opaque sRGB image: App Store Connect rejects an alpha channel.
@MainActor func flatten(_ window: CGImage) throws -> CGImage {
    let w = window.width, h = window.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: Bake.srgb,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ShotError(description: "no canvas") }
    let full = CGRect(x: 0, y: 0, width: w, height: h)
    ctx.setFillColor(windowBase); ctx.fill(full)
    ctx.draw(window, in: full)
    guard let image = ctx.makeImage() else { throw ShotError(description: "flatten failed") }
    return image
}

func writePNG(_ image: CGImage, to path: String) throws {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else {
        throw ShotError(description: "cannot write \(path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw ShotError(description: "cannot write \(path)") }
    print("wrote \(path)")
}
