import Foundation

// How the app reads a puzzle: the scene it scores (the core's rules.rs, mirrored so issue
// paths `elements[i]` point at the same element), the palette's materials and the goal in
// one line. Foundation only (the self-test and the shot harness use it).

extension Puzzle {
    /// Ids of the scene elements the player cannot change.
    public var lockedIDs: Set<String> { Set(rules.locked) }

    /// The puzzle's own elements the player may move or delete.
    public var startingParts: [Element] {
        scene.elements.filter { !lockedIDs.contains($0.id) }
    }

    /// "A", "B", … for the inputs, most significant first.
    public var inputLetters: [String] {
        inputs.indices.map { String(UnicodeScalar(UInt8(65 + min($0, 25)))) }
    }

    /// The scene a design is scored in, as the core composes it: locked elements from the
    /// puzzle; the puzzle's other elements from the design when it has them (same id) and
    /// dropped otherwise; then the design's other elements in its order. Input sources are
    /// on where `bits` says so (missing bits are on; other sources stay as the puzzle has
    /// them), and the solver is the scoring method at the scoring resolution, so the live
    /// preview is exactly what a Check solves.
    public func compose(design: [Element], bits: [Bool] = []) -> SimScene {
        var composed = scene
        let locked = lockedIDs
        // As rules.rs: each puzzle element takes the first unused design element with its
        // id (a locked one keeps the puzzle's), then every unused design element follows
        // in the design's order, duplicate ids included, so issue paths `elements[i]`
        // point at the same element in the app and in the core.
        var used = [Bool](repeating: false, count: design.count)
        var elements: [Element] = []
        for element in scene.elements {
            let found = design.indices.first { !used[$0] && design[$0].id == element.id }
            if let found { used[found] = true }
            if locked.contains(element.id) {
                elements.append(element)
            } else if let found {
                elements.append(design[found])
            }
        }
        for (k, element) in design.enumerated() where !used[k] {
            elements.append(element)
        }
        composed.elements = elements
        for (i, id) in inputs.enumerated() {
            composed[source: id]?.enabled = i < bits.count ? bits[i] : true
        }
        if let scoring {
            composed.solver.method = scoring.method
            switch scoring.method {
            case .fdtd: composed.solver.fdtd.previewPpw = scoring.ppw
            case .fem: composed.solver.fem.previewPpw = scoring.ppw
            case .mom: composed.solver.mom.previewPpw = scoring.ppw
            }
        }
        return composed
    }

    /// The player's part of a composed scene: every element that is not locked.
    public func design(in scene: SimScene) -> [Element] {
        scene.elements.filter { !lockedIDs.contains($0.id) }
    }

    /// The input bits a composed scene shows, from its sources' enabled flags.
    public func bits(in scene: SimScene) -> [Bool] {
        inputs.map { scene[source: $0]?.enabled ?? false }
    }

    /// What a Check result belongs to: the scene's physics with every input on, so
    /// switching inputs never makes a Check out of date and moving an element does.
    public func designRevision(of scene: SimScene) -> Data {
        var all = scene
        for id in inputs { all[source: id]?.enabled = true }
        return all.physicsRevision
    }

    /// Everything in `new` the player may not change is as in `old`: sources, detectors,
    /// wavelength, background, domain, solver and the locked elements. Input switching goes
    /// around this check.
    public func allowsChange(from old: SimScene, to new: SimScene) -> Bool {
        fixedPart(of: old) == fixedPart(of: new)
    }

    private func fixedPart(of scene: SimScene) -> SimScene {
        var fixed = scene
        let locked = lockedIDs
        fixed.elements = scene.elements.filter { locked.contains($0.id) }
        return fixed
    }

    // MARK: Palette

    /// How far a design breaks the palette, counted as the core's rules.rs does: enabled
    /// parts of a kind the palette lacks, of a material no entry of their kind allows, with
    /// no room left in any entry they fit, and over `max_elements`.
    public struct PaletteBreaches: Equatable, Sendable {
        public var kind = 0
        public var material = 0
        public var full = 0
        public var tooMany = 0

        /// Whether `other` breaks a rule more often than this.
        public func isExceeded(by other: PaletteBreaches) -> Bool {
            other.kind > kind || other.material > material || other.full > full || other.tooMany > tooMany
        }
    }

    public func paletteBreaches(of design: [Element]) -> PaletteBreaches {
        var breaches = PaletteBreaches()
        let palette = rules.palette
        var fitting: [[Int]] = []
        var enabled = 0
        for element in design where element.enabled {
            enabled += 1
            let kindFound = palette.contains { $0.kind == element.shape.kind }
            let fits = palette.indices.filter { k in
                palette[k].kind == element.shape.kind
                    && (palette[k].materials.isEmpty || paletteName(of: element.material, in: palette[k]) != nil)
            }
            if !kindFound {
                breaches.kind += 1
            } else if fits.isEmpty {
                breaches.material += 1
            } else {
                fitting.append(fits)
            }
        }
        // Parts matched to entries so that as many as possible fit (augmenting paths).
        let capacity = palette.map { $0.max ?? fitting.count }
        var holders = [[Int]](repeating: [], count: palette.count)
        func place(_ part: Int, _ seen: inout Set<Int>) -> Bool {
            for k in fitting[part] where seen.insert(k).inserted {
                if holders[k].count < capacity[k] {
                    holders[k].append(part)
                    return true
                }
                for (slot, other) in holders[k].enumerated() where place(other, &seen) {
                    holders[k][slot] = part
                    return true
                }
            }
            return false
        }
        for part in fitting.indices {
            var seen: Set<Int> = []
            if !place(part, &seen) { breaches.full += 1 }
        }
        if let max = rules.maxElements, enabled > max { breaches.tooMany = enabled - max }
        return breaches
    }

    /// Why a change that adds breaches is refused, for the notice.
    public func breachNotice(from old: PaletteBreaches, to new: PaletteBreaches) -> String {
        if new.kind > old.kind { return "This puzzle has no parts of this kind" }
        if new.material > old.material { return "This puzzle does not allow that material here" }
        if new.tooMany > old.tooMany, let max = rules.maxElements {
            return "This puzzle allows at most \(max) part\(max == 1 ? "" : "s")"
        }
        return "No parts of this kind are left"
    }

    /// The material a palette name stands for: "pec", a preset id or one of the puzzle's
    /// own materials.
    public func material(named name: String) -> Material? {
        if name == "pec" { return .pec }
        if let own = rules.materials[name] { return own }
        return MaterialLibrary.entry(name)?.material
    }

    /// "PEC", "Gold", "Dense glass (n = 2)".
    public func materialTitle(named name: String) -> String {
        if name == "pec" { return "PEC" }
        if let own = rules.materialNames[name] { return own }
        if rules.materials[name] != nil {
            return name.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ").capitalizedFirst
        }
        return MaterialLibrary.displayName(of: name)
    }

    /// The palette name of `material` within `entry`, if the entry allows it (as the core
    /// matches: same kind and numbers; a preset label does not matter).
    public func paletteName(of material: Material, in entry: PaletteEntry) -> String? {
        entry.materials.first { name in self.material(named: name).map { $0.sameSubstance(as: material) } ?? false }
    }

    /// Whether `element` fits a palette entry by kind and material.
    public func paletteEntry(for element: Element) -> PaletteEntry? {
        rules.palette.first { entry in
            entry.kind == element.shape.kind && (entry.materials.isEmpty || paletteName(of: element.material, in: entry) != nil)
        }
    }

    // MARK: Copy

    /// One short line saying what to do, for the browser's cards and the goal card: the
    /// core's `goal.text`, else one built from the goal, else the title.
    public var taskLine: String {
        if let text = goal.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { return text }
        let names = Dictionary(scene.detectors.map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        return goal.displayText(detectorNames: names, inputLetters: inputLetters) ?? title
    }
}

extension PuzzleGoal {
    /// A goal line built from the goal's type, for a puzzle without `goal.text`.
    public func displayText(detectorNames: [String: String], inputLetters: [String]) -> String? {
        func name(_ id: String) -> String { detectorNames[id].flatMap { $0.isEmpty ? nil : $0 } ?? id }
        switch type {
        case "truth_table":
            guard let output = outputs.first else { return nil }
            let target = outputs.count == 1 ? name(output.detector) : "Output"
            if let formula = Self.formula(bits: output.bits, letters: inputLetters) {
                return "\(target) = \(formula)"
            }
            return "\(target) follows the table"
        case "maximize":
            return detector.map { "Send as much power as possible into \(name($0))" }
        case "minimize":
            return "Scatter as little as possible"
        case "target":
            guard detectors.count == 2 else { return nil }
            let share = Int(((ratio ?? 0.5) * 100).rounded())
            return "Split \(share)/\(100 - share) between \(name(detectors[0])) and \(name(detectors[1]))"
        default:
            return nil
        }
    }

    /// "A ⊕ B", "A ∧ B", "A ∨ B", "¬A", "¬(A ∧ B)" for the gates the bits match.
    static func formula(bits: [Int], letters: [String]) -> String? {
        switch (letters.count, bits) {
        case (1, [1, 0]): return "¬\(letters[0])"
        case (1, [0, 1]): return letters[0]
        case (2, [0, 1, 1, 0]): return "\(letters[0]) ⊕ \(letters[1])"
        case (2, [0, 0, 0, 1]): return "\(letters[0]) ∧ \(letters[1])"
        case (2, [0, 1, 1, 1]): return "\(letters[0]) ∨ \(letters[1])"
        case (2, [1, 1, 1, 0]): return "¬(\(letters[0]) ∧ \(letters[1]))"
        default: return nil
        }
    }
}

extension Material {
    /// The same material as far as the physics goes: same kind and numbers. The preset
    /// label and the values a kind does not use are ignored.
    public func sameSubstance(as other: Material) -> Bool {
        guard kind == other.kind else { return false }
        func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= 1e-9 * max(1, abs(a), abs(b)) }
        switch kind {
        case .pec:
            return true
        case .dielectric:
            return close(n, other.n) && close(k, other.k)
        case .dispersive:
            guard close(epsInf, other.epsInf), poles.count == other.poles.count else { return false }
            return zip(poles, other.poles).allSatisfy { a, b in
                a.isDrude == b.isDrude && close(a.plasmaEv, b.plasmaEv) && close(a.gammaEv, b.gammaEv)
                    && close(a.strength, b.strength) && close(a.resonanceEv, b.resonanceEv)
            }
        }
    }
}

extension String {
    /// Title case for a UI label made from sentence-case content: "Hit the Target",
    /// "Logic with Light" (the rule the Templates menu uses).
    var titleCased: String { ExampleInfo.titleCased(self) }
}
