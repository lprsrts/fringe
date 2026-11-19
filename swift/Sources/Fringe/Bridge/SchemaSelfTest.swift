import Foundation

/// `Fringe --self-test-schema`: checks that the Swift scene model and the core agree on the
/// JSON schema, without opening a window.
///
/// For the default scene, every example and every puzzle scene it decodes the core's JSON
/// into `SimScene`, re-encodes it, compares the two JSON trees, runs the core's check on the
/// re-encoded scene (it must be free of errors), decodes it again (it must equal the first
/// decode) and decodes the core's overlay outlines for it. It also round-trips every
/// material of the core's preset library, upgrades a version 2 scene and document as the
/// core does, and checks the puzzles' reference solutions and palettes.
public enum SchemaSelfTest {
    public struct Failure: Sendable {
        public var scene: String
        public var message: String
    }

    /// Runs the test and returns the failures; empty means it passed.
    public static func run(log: (String) -> Void = { print($0) }) -> [Failure] {
        var failures: [Failure] = []
        func report(_ name: String, _ problem: String?) {
            if let problem {
                failures.append(Failure(scene: name, message: problem))
                log("FAIL \(name): \(problem)")
            } else {
                log("ok   \(name)")
            }
        }

        // Puzzles, field measuring and combining, and the core's own upgrade came with ABI 3.
        let abi = FringeBridge.abiVersion
        let neededABI: UInt32 = 3
        report("abi \(abi)", abi >= neededABI ? nil : "the core's ABI version is \(abi), the app needs \(neededABI)")

        var cases: [(String, String?)] = [("default", FringeBridge.defaultSceneJSON())]
        let examples = FringeBridge.examples()
        if examples.isEmpty {
            report("examples", "the core lists no examples")
        }
        for example in examples {
            cases.append((example.name, FringeBridge.exampleSceneJSON(example.name)))
        }
        for (name, json) in cases {
            guard let json else {
                report(name, "the core returned no JSON")
                continue
            }
            report(name, check(json: json))
        }

        for (name, problem) in checkMaterialLibrary() {
            report(name, problem)
        }
        report("upgrade v2 scene", checkUpgrade())
        report("upgrade v2 document", checkDocumentUpgrade())

        let puzzles = FringeBridge.puzzleList()
        report("puzzle list", checkPuzzleList(puzzles))
        for summary in puzzles {
            for (name, problem) in checkPuzzle(summary.id) {
                report(name, problem)
            }
        }
        // One with a locked element, so its design can carry an element with a locked id.
        let invalid = puzzles.first { FringeBridge.puzzle($0.id).map { !$0.lockedIDs.isEmpty } ?? false } ?? puzzles.first
        if let invalid {
            report("puzzle \(invalid.id) invalid design", checkInvalidDesign(invalid.id))
        }
        return failures
    }

    /// nil when the scene round-trips; otherwise what went wrong. `coreTree`, when given, is
    /// the core's scene as parsed from its own text, for a `json` that was re-serialised
    /// from it (re-serialising writes 17 digits, which parse back as decimals, not doubles).
    public static func check(json: String, coreTree: Any? = nil) -> String? {
        let first: SimScene
        do {
            first = try SimScene.decode(json: json)
        } catch {
            return "decoding failed: \(error)"
        }
        let encoded = first.jsonString()
        if let difference = treeDifference(coreTree ?? json, encoded, what: "re-encoding changed the JSON") {
            return difference
        }
        let report = FringeBridge.check(json: encoded)
        if !report.ok {
            let messages = report.errors.map { "\($0.path): \($0.message)" }.joined(separator: "; ")
            return "the core rejected the re-encoded scene: \(messages)"
        }
        let second: SimScene
        do {
            second = try SimScene.decode(json: encoded)
        } catch {
            return "decoding the re-encoded scene failed: \(error)"
        }
        if second != first {
            return "the second decode differs from the first"
        }
        // The overlay geometry decodes too, and its enabled bodies belong to exactly
        // the enabled elements (disabled ones are listed as well, flagged).
        guard let outlines = try? FringeBridge.decode(SceneOutlines.self, from: FringeBridge.outlinesJSON(encoded)) else {
            return "the core's outlines JSON does not decode"
        }
        let enabledIDs = Set(first.elements.filter(\.enabled).map(\.id))
        if Set(outlines.bodies.filter(\.enabled).map(\.elementId)) != enabledIDs {
            return "the outlines do not match the enabled elements"
        }
        // Every element the core describes is one of the scene's.
        if let derived = report.derived, !Set(derived.elements.map(\.id)).isSubset(of: Set(first.elements.map(\.id))) {
            return "the derived values name elements the scene does not have"
        }
        if let derived = report.derived, !first.enabledSources.isEmpty,
           !Set(derived.sources.map(\.id)).isSubset(of: Set(first.sources.map(\.id))) {
            return "the derived values name sources the scene does not have"
        }
        return nil
    }

    // MARK: Materials

    /// Each preset's material round-trips through `Material` and passes the core's check
    /// on a cylinder; its curve over 0.3–2 µm is finite with k ≥ 0.
    static func checkMaterialLibrary() -> [(String, String?)] {
        guard let entries = try? JSONSerialization.jsonObject(with: Data(FringeBridge.materialLibraryJSON().utf8)) as? [[String: Any]],
              !entries.isEmpty else {
            return [("presets", "the core's preset library is empty or not a JSON array")]
        }
        let library = FringeBridge.materialLibrary()
        if library.count != entries.count {
            return [("presets", "\(entries.count) presets in the JSON, \(library.count) decoded")]
        }
        var results: [(String, String?)] = []
        for (raw, entry) in zip(entries, library) {
            let name = "preset \(entry.id)"
            guard let materialObject = raw["material"], let encoded = try? FringeBridge.encode(entry.material) else {
                results.append((name, "no material object"))
                continue
            }
            if let difference = treeDifference(materialObject, encoded, what: "re-encoding changed the material") {
                results.append((name, difference))
                continue
            }
            if entry.material.kind != .dispersive || entry.material.preset != entry.id {
                results.append((name, "expected a Lorentz–Drude material labelled \(entry.id)"))
                continue
            }
            var scene = FringeBridge.defaultScene()
            scene.elements = [ShapeKind.cylinder.makeElement(at: (4, 0))]
            scene.elements[0].material = entry.material
            if let problem = check(json: scene.jsonString()) {
                results.append((name, "on a cylinder: \(problem)"))
                continue
            }
            guard let curve = FringeBridge.materialCurve(entry.material, range: 0.3...2, count: 171, lambda0: 0.633),
                  curve.n.count == 171, let at = curve.at else {
                results.append((name, "no curve from fringe_material_evaluate"))
                continue
            }
            let values = curve.n + curve.k + curve.eps1 + curve.eps2 + [at.n, at.k, at.eps1, at.eps2]
            if !values.allSatisfy(\.isFinite) || (curve.k + [at.k]).contains(where: { $0 < 0 }) || (curve.n + [at.n]).contains(where: { $0 < 0 }) {
                results.append((name, "the curve has non-finite values, n < 0 or k < 0"))
                continue
            }
            results.append((name, nil))
        }
        return results
    }

    // MARK: Version 2

    /// tests/fixtures/scenes/default.json: the default scene in schema version 2.
    static let v2Fixture = #"{"background":{"n":1.0},"domain":{"pml_wl":1.0,"x_max_um":20.0,"x_min_um":-12.0,"y_max_um":9.0,"y_min_um":-9.0},"elements":[{"enabled":true,"id":"lens-1","material":{"k":0.0,"n":1.5,"type":"dielectric"},"name":"Lens","rotation_deg":0.0,"shape":{"aperture_um":10.0,"center_thickness_um":3.0,"kind":"lens","r1_um":12.0,"r2_um":-12.0},"x_um":-4.0,"y_um":0.0}],"polarization":"ez","solver":{"fdtd":{"courant":0.6,"dispersion_correction":true,"final_ppw":null,"max_periods":null,"preview_ppw":null,"steady_tol":null,"subpixel":true},"fem":{"final_ppw":null,"order":3,"pml_reflection":1e-06,"preview_ppw":null},"memory_limit_mb":null,"method":"fdtd","mom":{"cfie_beta_scale":1.0,"corner_grading":true,"final_ppw":null,"pec_formulation":"auto","preview_ppw":null},"output":{"final_ppw":null,"preview_ppw":null}},"source":{"amplitude":1.0,"angle_deg":0.0,"phase_deg":0.0,"type":"gaussian_beam","waist_um":3.0,"waist_x_um":-6.0,"waist_y_um":0.0},"version":2,"wavelength_um":1.0}"#

    /// What the core makes of `v2Fixture`: the source gets id "source-1", an empty name and
    /// `enabled`, and the scene an empty detector list.
    static let v2FixtureUpgraded = #"{"background":{"n":1.0},"detectors":[],"domain":{"pml_wl":1.0,"x_max_um":20.0,"x_min_um":-12.0,"y_max_um":9.0,"y_min_um":-9.0},"elements":[{"enabled":true,"id":"lens-1","material":{"k":0.0,"n":1.5,"type":"dielectric"},"name":"Lens","rotation_deg":0.0,"shape":{"aperture_um":10.0,"center_thickness_um":3.0,"kind":"lens","r1_um":12.0,"r2_um":-12.0},"x_um":-4.0,"y_um":0.0}],"polarization":"ez","solver":{"fdtd":{"courant":0.6,"dispersion_correction":true,"final_ppw":null,"max_periods":null,"preview_ppw":null,"steady_tol":null,"subpixel":true},"fem":{"final_ppw":null,"order":3,"pml_reflection":1e-06,"preview_ppw":null},"memory_limit_mb":null,"method":"fdtd","mom":{"cfie_beta_scale":1.0,"corner_grading":true,"final_ppw":null,"pec_formulation":"auto","preview_ppw":null},"output":{"final_ppw":null,"preview_ppw":null}},"sources":[{"amplitude":1.0,"angle_deg":0.0,"enabled":true,"id":"source-1","name":"","phase_deg":0.0,"type":"gaussian_beam","waist_um":3.0,"waist_x_um":-6.0,"waist_y_um":0.0}],"version":3,"wavelength_um":1.0}"#

    /// The Swift upgrade of a version 2 scene gives the core's version 3 JSON, and the core
    /// reads the version 2 file itself.
    static func checkUpgrade() -> String? {
        let report = FringeBridge.check(json: v2Fixture)
        if !report.ok || !report.errors.isEmpty {
            return "the core does not read the version 2 fixture: \(report.errors.map(\.message).joined(separator: "; "))"
        }
        let scene: SimScene
        do {
            scene = try SimScene.decode(json: v2Fixture)
        } catch {
            return "decoding the version 2 fixture failed: \(error)"
        }
        let expected = FringeBridge.sceneUpgradeJSON(v2Fixture) ?? v2FixtureUpgraded
        if let difference = treeDifference(expected, scene.jsonString(), what: "the upgrade differs from the core's") {
            return difference
        }
        return check(json: scene.jsonString())
    }

    /// A document saved by a version 2 build (`fringe.document.v2`) opens.
    static func checkDocumentUpgrade() -> String? {
        guard let display = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(DisplaySettings())),
              let output = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(OutputFormat())),
              let scene = try? JSONSerialization.jsonObject(with: Data(v2Fixture.utf8)),
              let data = try? JSONSerialization.data(withJSONObject: ["scene": scene, "display": display, "output": output]) else {
            return "could not build the version 2 document"
        }
        do {
            let document = try JSONDecoder().decode(FringeDocument.self, from: data)
            guard document.scene.sources.map(\.id) == [SimScene.upgradedSourceID], document.scene.version == SimScene.schemaVersion else {
                return "the upgraded document has sources \(document.scene.sources.map(\.id)), version \(document.scene.version)"
            }
            return nil
        } catch {
            return "decoding failed: \(error)"
        }
    }

    // MARK: Puzzles

    /// The list decodes entry for entry, ids are unique, and each id gets its puzzle.
    static func checkPuzzleList(_ puzzles: [PuzzleSummary]) -> String? {
        guard let raw = try? JSONSerialization.jsonObject(with: Data(FringeBridge.puzzleListJSON().utf8)) as? [Any] else {
            return "the puzzle list is not a JSON array"
        }
        if puzzles.isEmpty { return "the core lists no puzzles" }
        if raw.count != puzzles.count { return "\(raw.count) puzzles in the JSON, \(puzzles.count) decoded" }
        if Set(puzzles.map(\.id)).count != puzzles.count { return "puzzle ids repeat" }
        let missing = puzzles.filter { FringeBridge.puzzleJSON($0.id) == nil }.map(\.id)
        if !missing.isEmpty { return "no puzzle JSON for \(missing)" }
        if puzzles.contains(where: { $0.chapterTitle?.isEmpty ?? true }) { return "a puzzle has no chapter title" }
        return nil
    }

    /// The puzzle's scene round-trips; its reference solution round-trips, passes the core's
    /// check in the scene as the app composes it, fits the palette and scores as passing
    /// (decoding the core's result, and combining its per-source fields into each case);
    /// its inputs and goal detectors are in the scene and its palette materials resolve.
    static func checkPuzzle(_ id: String) -> [(String, String?)] {
        let name = "puzzle \(id)"
        guard let json = FringeBridge.puzzleJSON(id),
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let sceneObject = object["scene"],
              let sceneData = try? JSONSerialization.data(withJSONObject: sceneObject) else {
            return [(name, "the core returned no puzzle JSON with a scene")]
        }
        // Compared on the core's own tree for the scene.
        if let problem = check(json: String(decoding: sceneData, as: UTF8.self), coreTree: sceneObject) {
            return [(name, problem)]
        }
        let puzzle: Puzzle
        do {
            puzzle = try FringeBridge.decode(Puzzle.self, from: json)
        } catch {
            return [(name, "decoding the puzzle failed: \(error)")]
        }
        var results: [(String, String?)] = [(name, puzzle.taskLine.isEmpty ? "no task line" : nil)]
        results.append(("\(name) reference", checkReference(puzzle, coreReference: object["reference"])))
        results.append(("\(name) rules", checkRules(puzzle, rulesObject: object["rules"] as? [String: Any])))
        results.append(("\(name) score", checkScore(puzzle)))
        return results
    }

    private static func checkReference(_ puzzle: Puzzle, coreReference: Any?) -> String? {
        if puzzle.reference.isEmpty { return "no reference solution" }
        guard let coreReference, let encoded = try? FringeBridge.encode(puzzle.reference) else {
            return "the reference does not encode"
        }
        if let difference = treeDifference(coreReference, encoded, what: "re-encoding changed the reference") {
            return difference
        }
        // The empty design is the scene as the puzzle has it.
        if puzzle.compose(design: puzzle.startingParts).elements != puzzle.scene.elements {
            return "composing the starting parts changes the scene's elements"
        }
        let composed = puzzle.compose(design: puzzle.reference)
        if let scoring = puzzle.scoring, composed.solver.method != scoring.method
            || (scoring.ppw != nil && composed.solver.ppwOverride(final: false) != scoring.ppw) {
            return "the composed scene does not solve with the scoring method and resolution"
        }
        if let problem = check(json: composed.jsonString()) {
            return "in the composed scene: \(problem)"
        }
        let misfits = puzzle.design(in: composed).filter { puzzle.paletteEntry(for: $0) == nil }.map(\.displayName)
        return misfits.isEmpty ? nil : "reference elements outside the palette: \(misfits)"
    }

    private static func checkRules(_ puzzle: Puzzle, rulesObject: [String: Any]?) -> String? {
        var problems: [String] = []
        let sourceIDs = Set(puzzle.scene.sources.map(\.id))
        let missing = puzzle.inputs.filter { !sourceIDs.contains($0) }
        if !missing.isEmpty { problems.append("inputs that are not sources: \(missing)") }
        let detectorIDs = Set(puzzle.scene.detectors.map(\.id))
        let goalDetectors = puzzle.goal.outputs.map(\.detector) + puzzle.goal.detectors + [puzzle.goal.detector].compactMap { $0 }
        let missingDetectors = goalDetectors.filter { !detectorIDs.contains($0) }
        if !missingDetectors.isEmpty { problems.append("goal detectors not in the scene: \(missingDetectors)") }
        let elementIDs = Set(puzzle.scene.elements.map(\.id))
        let missingLocked = puzzle.rules.locked.filter { !elementIDs.contains($0) }
        if !missingLocked.isEmpty { problems.append("locked ids not in the scene: \(missingLocked)") }
        let unresolved = puzzle.rules.palette.flatMap(\.materials).filter { puzzle.material(named: $0) == nil }
        if !unresolved.isEmpty { problems.append("palette materials that do not resolve: \(unresolved)") }
        // The puzzle's own materials round-trip (their display name aside).
        let own = rulesObject?["materials"] as? [String: Any] ?? [:]
        for (key, value) in own {
            guard var tree = value as? [String: Any], let material = puzzle.rules.materials[key],
                  let encoded = try? FringeBridge.encode(material) else {
                problems.append("material \(key) does not decode")
                continue
            }
            tree["name"] = nil
            if let difference = treeDifference(tree, encoded, what: "re-encoding changed material \(key)") {
                problems.append(difference)
            }
        }
        if puzzle.rules.palette.isEmpty { problems.append("an empty palette") }
        if puzzle.goal.text?.isEmpty ?? true { problems.append("no goal text") }
        return problems.isEmpty ? nil : problems.joined(separator: "; ")
    }

    /// Runs a puzzle evaluation to the end, off the main thread's run loop.
    static func evaluate(_ id: String, design: [Element]) throws -> PuzzleResultHandle? {
        let job = try PuzzleJobHandle(puzzleID: id, solutionJSON: FringeBridge.encode(design))
        let deadline = Date().addingTimeInterval(120)
        while job.isRunning {
            if Date() > deadline {
                job.cancel()
                throw FringeError(code: "timeout", message: "the evaluation took over 120 s")
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return try job.takeResult()
    }

    private static func checkScore(_ puzzle: Puzzle) -> String? {
        let result: PuzzleResultHandle
        do {
            guard let taken = try evaluate(puzzle.id, design: puzzle.reference) else { return "no result" }
            result = taken
        } catch {
            return "scoring the reference failed: \(error)"
        }
        guard let evaluation = result.evaluation else {
            return "the result does not decode: \(result.decodingError ?? "?")"
        }
        guard evaluation.valid, evaluation.passed, evaluation.stars >= 1, let score = evaluation.score, score.isFinite else {
            return "the reference does not pass: valid \(evaluation.valid), score \(evaluation.score.map { "\($0)" } ?? "null"), stars \(evaluation.stars), issues \(evaluation.issues.map(\.message))"
        }
        let expectedCases = 1 << puzzle.inputs.count
        guard evaluation.cases.count == expectedCases, result.fields.count == evaluation.sources.count else {
            return "\(evaluation.cases.count) cases (expected \(expectedCases)), \(result.fields.count) fields for \(evaluation.sources.count) sources"
        }
        // The core's composed scene has the app's element order: its bodies follow the
        // enabled elements of the app's composed scene.
        if let info = result.fields.first?.info {
            var bodyIDs: [String] = []
            for body in info.bodies where bodyIDs.last != body.elementId { bodyIDs.append(body.elementId) }
            let mine = puzzle.compose(design: puzzle.reference).elements.filter(\.enabled).map(\.id)
            if bodyIDs != mine { return "the core composed the elements \(bodyIDs), the app \(mine)" }
        }
        // Each case combined from the per-source fields reads like the core's case, and
        // the case is found by the bits the app's scene shows.
        for item in evaluation.cases {
            let composed = puzzle.compose(design: puzzle.reference, bits: item.bits)
            guard evaluation.case(bits: puzzle.bits(in: composed)) != nil else { return "no case for bits \(item.bits)" }
            guard item.weights.allSatisfy({ !$0.isEmpty }), item.weights.contains(where: { $0[0] != 0 || ($0.count > 1 && $0[1] != 0) }) else {
                continue // nothing on (case 00 without a bias): nothing to combine
            }
            let combined: FieldHandle
            do {
                combined = try FieldHandle.combine(result.fields, weights: item.weights.map { (re: $0[0], im: $0.count > 1 ? $0[1] : 0) })
            } catch {
                return "combining case \(item.bits) failed: \(error)"
            }
            guard combined.info != nil else { return "the combined field of case \(item.bits) has no readable info" }
            let goalIDs = Set(item.outputs.map(\.detector))
            let detectors = puzzle.scene.detectors.filter { goalIDs.contains($0.id) }
            let measured = Dictionary(combined.measure(detectors).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for reading in item.readings where goalIDs.contains(reading.id) {
                guard let core = reading.totalValue, let mine = measured[reading.id]?.totalValue else {
                    return "case \(item.bits): no reading of \(reading.id) on the combined field"
                }
                if abs(core - mine) > 1e-6 * max(1, abs(core)) {
                    return "case \(item.bits): \(reading.id) reads \(mine) on the combined field, the core's case \(core)"
                }
            }
        }
        return nil
    }

    /// A design the core refuses (a part outside the domain) decodes with the values the
    /// core leaves null: no score, no metric, no cases, no fields.
    static func checkInvalidDesign(_ id: String) -> String? {
        guard let puzzle = FringeBridge.puzzle(id) else { return "no puzzle" }
        let domain = puzzle.scene.domain
        var part = ShapeKind.cylinder.makeElement(at: (domain.xMaxUm + 10 * puzzle.scene.wavelengthUm, domain.centerY))
        part.material = .glass(1.5)
        // The first design element with a locked id stands for the locked element; a
        // second one is the player's and goes after the puzzle's elements, as in the core.
        let lockedElements = puzzle.scene.elements.filter { puzzle.lockedIDs.contains($0.id) }
        var design = puzzle.startingParts + lockedElements + lockedElements.prefix(1)
        design.append(part)
        do {
            guard let result = try evaluate(id, design: design) else { return "no result" }
            guard let evaluation = result.evaluation else {
                return "the result does not decode: \(result.decodingError ?? "?")"
            }
            if evaluation.valid || evaluation.passed || evaluation.score != nil || evaluation.metric != nil || !evaluation.cases.isEmpty || !result.fields.isEmpty {
                return "expected an invalid result with no score: \(result.json)"
            }
            if !evaluation.issues.contains(where: \.isError) { return "the invalid result has no error issue" }
            // Issue paths index the composed scene: the part's issues point at it in the
            // app's composition too (after a duplicate of a starting part, as the core keeps).
            let composed = puzzle.compose(design: design)
            let index = composed.elements.lastIndex { $0.id == part.id }
            let paths = evaluation.issues.filter { $0.code == "outside_domain" }.map(\.path)
            guard let index, paths == ["elements[\(index)]"] else {
                return "issue paths \(evaluation.issues.map(\.path)) do not point at the part, elements[\(index.map(String.init) ?? "?")] in the app's composition"
            }
            return nil
        } catch {
            return "scoring failed: \(error)"
        }
    }

    // MARK: Helpers

    /// nil when the two hold the same JSON tree. `core` is JSON text or an already parsed
    /// tree.
    static func treeDifference(_ core: Any, _ swift: String, what: String) -> String? {
        let a: Any? = (core as? String).map { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } ?? core
        guard let a, let b = try? JSONSerialization.jsonObject(with: Data(swift.utf8)) else {
            return "the JSON does not parse"
        }
        if (a as AnyObject).isEqual(b) { return nil }
        let coreText = (core as? String)
            ?? (try? JSONSerialization.data(withJSONObject: a, options: .sortedKeys)).map { String(decoding: $0, as: UTF8.self) } ?? "?"
        return "\(what):\n  core:  \(coreText)\n  swift: \(swift)"
    }
}
