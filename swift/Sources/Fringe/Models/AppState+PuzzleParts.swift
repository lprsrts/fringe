import Foundation

// The open puzzle as the sidebar, the canvas and the inspector use it: the palette's parts
// and what is left of them, which items the player may touch, where parts break the region
// rule, the input cases, and the overlay the canvas draws.
extension AppState {
    /// The open puzzle.
    public var activePuzzle: Puzzle? { isInPuzzle ? puzzles.session?.puzzle : nil }

    /// Whether `id` is an element the puzzle fixes.
    public func isLockedElement(_ id: String) -> Bool {
        activePuzzle?.lockedIDs.contains(id) ?? false
    }

    /// Whether the player may select and move `item`: anything in the simulator; in a
    /// puzzle only their own elements.
    public func isPlayerItem(_ item: SceneItem) -> Bool {
        guard isInPuzzle else { return mode == .simulator }
        if case .element(let id) = item { return !isLockedElement(id) }
        return false
    }

    /// Whether `item` may be duplicated: anything in the simulator; in a puzzle only the
    /// player's own elements, and only while the palette has room for the copy.
    public func canDuplicate(_ item: SceneItem) -> Bool {
        guard isPlayerItem(item) else { return false }
        guard let puzzle = activePuzzle else { return true }
        guard case .element(let id) = item, let element = scene[element: id] else { return false }
        let design = puzzleDesign
        return !puzzle.paletteBreaches(of: design).isExceeded(by: puzzle.paletteBreaches(of: design + [element]))
    }

    /// The player's elements, in scene order.
    public var puzzleDesign: [Element] {
        activePuzzle.map { $0.design(in: scene) } ?? []
    }

    // MARK: Parts

    /// How many enabled parts each palette entry holds: each part goes to the first entry
    /// it fits that still has room, else to the first it fits.
    public var paletteUsage: [Int] {
        guard let puzzle = activePuzzle else { return [] }
        var used = [Int](repeating: 0, count: puzzle.rules.palette.count)
        for element in puzzleDesign where element.enabled {
            let fits = puzzle.rules.palette.indices.filter { i in
                let entry = puzzle.rules.palette[i]
                return entry.kind == element.shape.kind && (entry.materials.isEmpty || puzzle.paletteName(of: element.material, in: entry) != nil)
            }
            if let i = fits.first(where: { i in puzzle.rules.palette[i].max.map { used[i] < $0 } ?? true }) ?? fits.first {
                used[i] += 1
            }
        }
        return used
    }

    /// Enabled parts the player has placed.
    public var enabledPartCount: Int { puzzleDesign.filter(\.enabled).count }

    /// Whether one more part of palette entry `index` may be added.
    public func canAddPart(_ index: Int) -> Bool {
        guard let puzzle = activePuzzle, puzzle.rules.palette.indices.contains(index) else { return false }
        if let max = puzzle.rules.maxElements, enabledPartCount >= max { return false }
        if let max = puzzle.rules.palette[index].max, paletteUsage[index] >= max { return false }
        return true
    }

    /// Adds a part of palette entry `index` at the centre of the allowed region, made of the
    /// entry's first material and sized to fit the region; selects it.
    public func addPart(_ index: Int) {
        guard let puzzle = activePuzzle, canAddPart(index) else { return }
        let entry = puzzle.rules.palette[index]
        let region = puzzle.rules.region ?? scene.domain.rect
        var element = entry.kind.makeElement(at: (region.centerX, region.centerY))
        if let name = entry.materials.first, let material = puzzle.material(named: name) {
            element.material = material
        }
        element.name = entry.kind.title
        // Clear of the parts already there: one background wavelength lower per part.
        let others = puzzleDesign.filter { abs($0.xUm - element.xUm) < 1e-9 && abs($0.yUm - element.yUm) < 1e-9 }.count
        element.yUm -= Double(others) * scene.lambdaB
        element = fitted(element, into: region)
        edit("Add \(entry.kind.title)") { $0.scene.elements.append(element) }
        if scene[element: element.id] != nil { selection = .element(element.id) }
    }

    /// `element` scaled down until its outline lies inside 90 % of `region`.
    private func fitted(_ element: Element, into region: RectUm) -> Element {
        var element = element
        let target = region.insetBy(0.05 * min(region.width, region.height))
        for _ in 0..<8 {
            var probe = scene
            probe.elements = [element]
            guard let box = FringeBridge.outlines(probe).flatMap({ bodyBounds($0.bodies(of: element.id)) }) else { break }
            let fx = target.width / max(1e-9, box.width), fy = target.height / max(1e-9, box.height)
            let factor = min(fx, fy)
            if factor >= 1 {
                // Inside after scaling: centre it again (a lens's outline is not centred on x).
                element.xUm += region.centerX - box.centerX
                element.yUm += max(target.yMin - box.yMin, min(0, target.yMax - box.yMax))
                break
            }
            element.shape = element.shape.scaled(by: factor * 0.98)
        }
        return element
    }

    // MARK: Region

    /// The player's enabled elements whose outline leaves the allowed region: drawn amber
    /// before a Check (the core's rule_region decides).
    public var outOfRegionElementIDs: Set<String> {
        guard let puzzle = activePuzzle, let region = puzzle.rules.region, let outlines else { return [] }
        let slack = 1e-6
        var ids: Set<String> = []
        for element in puzzle.design(in: scene) where element.enabled {
            guard let box = bodyBounds(outlines.bodies(of: element.id)) else { continue }
            if box.xMin < region.xMin - slack || box.xMax > region.xMax + slack || box.yMin < region.yMin - slack || box.yMax > region.yMax + slack {
                ids.insert(element.id)
            }
        }
        return ids
    }

    // MARK: Inputs and cases

    /// Sets every input at once (a click on a truth-table row).
    public func setPuzzleInputs(_ bits: [Bool]) {
        guard let puzzle = activePuzzle, bits.count == puzzle.inputs.count else { return }
        var new = document
        for (i, id) in puzzle.inputs.enumerated() { new.scene[source: id]?.enabled = bits[i] }
        guard new != document else { return }
        if isPuzzleCheckCurrent, let field = puzzles.combinedField(bits: bits) {
            solver.adopt(field, for: new.scene)
            puzzles.updateSession { $0.shownField = field }
        } else {
            puzzles.updateSession { $0.shownField = nil }
        }
        setDocumentQuietly(new)
    }

    /// Whether the canvas shows a case combined from the checked fields.
    public var showsCheckedCase: Bool {
        guard let combined = puzzles.session?.shownField else { return false }
        return solver.shown?.field === combined
    }

    /// A case of a logic puzzle with every source off: no light, which is a normal case and
    /// not a failure, whatever the scene check says about it.
    public var isDarkPuzzleCase: Bool {
        guard let puzzle = activePuzzle, !puzzle.inputs.isEmpty else { return false }
        return !scene.sources.contains(where: \.enabled)
    }

    /// The canvas shows such a case with no field of its own: dark, with a neutral note.
    /// After a Check the combined (dark) field of the case is shown instead.
    public var showsDarkCase: Bool { isDarkPuzzleCase && !showsCheckedCase }

    /// The last Check, read for the table and charts.
    public var puzzleReport: PuzzleReport? {
        guard let puzzle = activePuzzle else { return nil }
        return PuzzleReport(puzzle: puzzle, evaluation: puzzles.session?.evaluation)
    }

    // MARK: Canvas

    /// A goal detector's scored value in the shown checked case ("77.3%", "0.495").
    func scoredLabel(_ detectorID: String) -> String? {
        guard showsCheckedCase, let puzzle = activePuzzle, let evaluation = puzzles.session?.evaluation,
              let value = evaluation.case(bits: puzzle.bits(in: scene))?.outputs.first(where: { $0.detector == detectorID })?.value
        else { return nil }
        return puzzle.valueStyle.format(value)
    }

    /// A goal detector's live reading as the puzzle scores it (over its reference), before a
    /// Check; nil when the app cannot tell the reference.
    func puzzleLiveValue(_ detectorID: String) -> Double? {
        guard let puzzle = activePuzzle else { return nil }
        // Every source off (a case with all inputs off): no light, so the core reads 0.
        if !scene.sources.contains(where: \.enabled) { return 0 }
        // Readings of an older field would be another design's or another case's.
        guard !readingsAreStale, let reading = detectorReadings[detectorID] else { return nil }
        return puzzle.liveValue(reading, in: scene)
    }

    /// The same, formatted as the table prints scored values: "≈ 41%".
    func puzzleLiveLabel(_ detectorID: String) -> String? {
        guard let puzzle = activePuzzle, let value = puzzleLiveValue(detectorID) else { return nil }
        return "≈ " + puzzle.valueStyle.format(value)
    }

    /// What the canvas draws for the open puzzle: the region, locked bodies, input labels
    /// and parts outside the region.
    var puzzleOverlay: PuzzleOverlay? {
        guard let puzzle = activePuzzle else { return nil }
        var labels: [String: String] = [:]
        for (i, id) in puzzle.inputs.enumerated() { labels[id] = puzzle.inputLetters[i] }
        for source in scene.sources where labels[source.id] == nil && source.enabled {
            labels[source.id] = source.displayName
        }
        return PuzzleOverlay(region: puzzle.rules.region, lockedIDs: puzzle.lockedIDs, sourceLabels: labels,
                             outOfRegionIDs: isPuzzleCheckCurrent && puzzles.session?.evaluation?.valid == true ? [] : outOfRegionElementIDs)
    }
}

extension Shape {
    /// Every length scaled by `factor` (angles and counts kept).
    func scaled(by f: Double) -> Shape {
        switch self {
        case .lens(var v):
            v.r1Um = v.r1Um.map { $0 * f }; v.r2Um = v.r2Um.map { $0 * f }
            v.centerThicknessUm *= f; v.apertureUm *= f
            return .lens(v)
        case .slab(var v): v.thicknessUm *= f; v.heightUm *= f; return .slab(v)
        case .wedge(var v): v.thickUm *= f; v.thinUm *= f; v.heightUm *= f; return .wedge(v)
        case .prism(var v): v.baseUm *= f; return .prism(v)
        case .mirror(var v):
            v.apertureUm *= f; v.thicknessUm *= f; v.radiusUm = v.radiusUm.map { $0 * f }
            return .mirror(v)
        case .slits(var v):
            v.slitWidthUm *= f; v.pitchUm *= f; v.screenHeightUm *= f; v.thicknessUm *= f
            return .slits(v)
        case .grating(var v): v.periodUm *= f; v.depthUm *= f; v.substrateUm *= f; return .grating(v)
        case .cylinder(var v): v.radiusUm *= f; return .cylinder(v)
        case .waveguide(var v): v.widthUm *= f; v.lengthUm *= f; return .waveguide(v)
        case .polygon(var v): v.verticesUm = v.verticesUm.map { $0.map { $0 * f } }; return .polygon(v)
        }
    }
}
