import Foundation
import SwiftUI

/// A source, element or detector of the scene, by id.
public enum SceneItem: Hashable, Sendable {
    case source(String)
    case element(String)
    case detector(String)

    public var id: String {
        switch self {
        case .source(let id), .element(let id), .detector(let id): return id
        }
    }

    /// "Source", "Element", "Detector", for menu items and undo names.
    public var noun: String {
        switch self {
        case .source: return "Source"
        case .element: return "Element"
        case .detector: return "Detector"
        }
    }

    public var sidebarItem: SidebarItem {
        switch self {
        case .source(let id): return .source(id)
        case .element(let id): return .element(id)
        case .detector(let id): return .detector(id)
        }
    }
}

// Adding, duplicating, deleting and enabling sources, elements and detectors, bindings for
// the source and detector forms, and canvas hit tests for sources and detectors.
extension AppState {
    // MARK: Adding

    public func addSource(_ kind: SourceKind) {
        let scene = self.scene
        let domain = scene.domain
        let lambdaB = scene.lambdaB
        var source = Source(id: scene.freeID(prefix: kind.idPrefix), kind: kind)
        switch kind {
        case .gaussianBeam:
            // In the middle of the domain's left third, travelling along +x.
            source.xUm = domain.xMinUm + domain.width / 6
            source.yUm = domain.centerY
            source.waistUm = max(0.5 * lambdaB, min(3 * lambdaB, domain.height / 6))
        case .planeWave:
            source.angleDeg = 0
        case .lineSource:
            let p = emitterPlacement()
            source.xUm = p.x
            source.yUm = p.y
        }
        edit("Add \(kind.title)") { $0.scene.sources.append(source) }
        selection = .source(source.id)
    }

    /// The domain centre, or the nearest point to it at least 2 λ_b from every enabled body
    /// and inside the domain; the centre when there is none.
    func emitterPlacement() -> (x: Double, y: Double) {
        let domain = scene.domain
        let lambdaB = scene.lambdaB
        let bodies = (outlines?.bodies ?? []).filter(\.enabled)
        let centre = (x: domain.centerX, y: domain.centerY)
        func clear(_ x: Double, _ y: Double) -> Bool {
            let inset = domain.rect.insetBy(lambdaB / 2)
            guard inset.contains(x: x, y: y) else { return false }
            return bodies.allSatisfy { body in
                !PlaneGeometry.contains(body.outline, x: x, y: y)
                    && PlaneGeometry.distance(body.outline, x: x, y: y) >= 2 * lambdaB
            }
        }
        if clear(centre.x, centre.y) { return centre }
        let step = lambdaB / 2
        let maxRing = Int((max(domain.width, domain.height) / 2 / step).rounded(.up))
        guard maxRing > 0 else { return centre }
        for ring in 1...maxRing {
            let r = Double(ring) * step
            let count = max(8, ring * 8)
            for k in 0..<count {
                let a = 2 * Double.pi * Double(k) / Double(count) + .pi
                let p = (x: centre.x + r * cos(a), y: centre.y + r * sin(a))
                if clear(p.x, p.y) { return p }
            }
        }
        return centre
    }

    public func addDetector(_ kind: DetectorKind) {
        let scene = self.scene
        let domain = scene.domain
        let id = scene.freeID(prefix: "detector")
        let shape: DetectorShape
        switch kind {
        case .line:
            // Vertical at three quarters of the width, drawn bottom to top so the flux
            // counts positive along +x.
            // Rounded to the length fields' two decimals, so the form reads 7.5 µm, not 7.4783.
            func r(_ v: Double) -> Double { (v * 100).rounded() / 100 }
            let x = r(domain.xMinUm + 0.75 * domain.width)
            let half = 0.3 * domain.height
            shape = .line(LineGeometry(x1Um: x, y1Um: r(domain.centerY - half), x2Um: x, y2Um: r(domain.centerY + half)))
        case .box:
            func r(_ v: Double) -> Double { (v * 100).rounded() / 100 }
            let side = r(scene.lambdaB)
            shape = .box(BoxGeometry(xUm: r(domain.centerX), yUm: r(domain.centerY), widthUm: side, heightUm: side))
        }
        let detector = Detector(id: id, shape: shape)
        edit("Add \(kind.title)") { $0.scene.detectors.append(detector) }
        selection = .detector(id)
        // The first detector ever added opens the results; after that they stay as the
        // user left them.
        if !UserDefaults.standard.bool(forKey: Self.resultsOpenedKey) {
            UserDefaults.standard.set(true, forKey: Self.resultsOpenedKey)
            isResultsPresented = true
        }
    }

    // MARK: Duplicating, deleting, enabling

    public func duplicate(_ item: SceneItem) {
        if isInPuzzle, !isPlayerItem(item) {
            showNotice("This is fixed by the puzzle")
            return
        }
        let lambdaB = scene.lambdaB
        switch item {
        case .element(let id):
            selection = .element(id)
            duplicateSelectedElement()
        case .source(let id):
            guard var copy = scene[source: id] else { return }
            copy.id = scene.freeID(prefix: copy.kind.idPrefix)
            if copy.kind != .planeWave {
                // Beside the original, across the beam for a beam.
                let a = copy.kind == .gaussianBeam ? (copy.angleDeg + 90) * .pi / 180 : 0
                let offset = copy.kind == .gaussianBeam ? 2 * copy.waistUm + lambdaB : 2 * lambdaB
                copy.xUm += offset * cos(a)
                copy.yUm += offset * sin(a)
            }
            edit("Duplicate Source") { $0.scene.sources.append(copy) }
            selection = .source(copy.id)
        case .detector(let id):
            guard let original = scene[detector: id] else { return }
            var copy: Detector
            switch original.shape {
            case .line:
                // One background wavelength further along its normal.
                let a = (original.normalAngleDeg ?? 0) * .pi / 180
                copy = original.moved(by: lambdaB * cos(a), lambdaB * sin(a))
            case .box(let g):
                copy = original.moved(by: g.widthUm + lambdaB / 2, 0)
            }
            copy.id = scene.freeID(prefix: "detector")
            edit("Duplicate Detector") { $0.scene.detectors.append(copy) }
            selection = .detector(copy.id)
        }
    }

    /// Deletes the item. The last enabled source is kept: a scene needs one.
    public func delete(_ item: SceneItem) {
        switch item {
        case .element(let id):
            deleteElement(id)
            return
        case .source(let id):
            guard let source = scene[source: id] else { return }
            if source.enabled, scene.enabledSources.count == 1 {
                showNotice("A scene needs at least one enabled source")
                return
            }
            edit("Delete Source") { $0.scene[source: id] = nil }
        case .detector(let id):
            guard scene[detector: id] != nil else { return }
            edit("Delete Detector") { $0.scene[detector: id] = nil }
        }
        // A puzzle refuses to delete its own sources and detectors: the selection stays.
        let removed: Bool
        switch item {
        case .element: removed = true
        case .source(let id): removed = scene[source: id] == nil
        case .detector(let id): removed = scene[detector: id] == nil
        }
        if removed, selection == item.sidebarItem { selection = .illumination }
    }

    public func toggleEnabled(_ item: SceneItem) {
        switch item {
        case .element(let id):
            toggleEnabled(id)
        case .source(let id):
            guard let source = scene[source: id] else { return }
            edit(source.enabled ? "Disable Source" : "Enable Source") { $0.scene[source: id]?.enabled.toggle() }
        case .detector(let id):
            guard let detector = scene[detector: id] else { return }
            edit(detector.enabled ? "Disable Detector" : "Enable Detector") { $0.scene[detector: id]?.enabled.toggle() }
        }
    }

    public func isEnabled(_ item: SceneItem) -> Bool {
        switch item {
        case .element(let id): return scene[element: id]?.enabled ?? false
        case .source(let id): return scene[source: id]?.enabled ?? false
        case .detector(let id): return scene[detector: id]?.enabled ?? false
        }
    }

    public func deleteSelectedItem() {
        if let item = selectedItem { delete(item) }
    }

    public func duplicateSelectedItem() {
        if let item = selectedItem { duplicate(item) }
    }

    public func toggleSelectedItemEnabled() {
        if let item = selectedItem { toggleEnabled(item) }
    }

    // MARK: Bindings

    /// Like `elementBinding`, for a source.
    public func sourceBinding<Value>(
        _ id: String,
        _ name: String,
        _ keyPath: WritableKeyPath<Source, Value>,
        fallback: Value,
        live: Bool = false
    ) -> Binding<Value> {
        Binding(
            get: {
                self.inspectorValue(self.scene[source: id], id: id, keyPath, isLive: live) { live, source in
                    switch live {
                    case .source(_, let x, let y): source.xUm = x; source.yUm = y
                    case .sourceAngle(_, let angle): source.angleDeg = angle
                    default: break
                    }
                } ?? fallback
            },
            set: { newValue in
                if self.isTracking {
                    self.track { $0.scene[source: id]?[keyPath: keyPath] = newValue }
                } else {
                    self.edit(name, coalescingKey: [AnyHashable(id), AnyHashable(keyPath)]) {
                        $0.scene[source: id]?[keyPath: keyPath] = newValue
                    }
                }
            }
        )
    }

    /// Like `elementBinding`, for a detector.
    public func detectorBinding<Value>(
        _ id: String,
        _ name: String,
        _ keyPath: WritableKeyPath<Detector, Value>,
        fallback: Value,
        live: Bool = false
    ) -> Binding<Value> {
        Binding(
            get: {
                self.inspectorValue(self.scene[detector: id], id: id, keyPath, isLive: live) { live, detector in
                    if case .detector(let dragged) = live { detector = dragged }
                } ?? fallback
            },
            set: { newValue in
                if self.isTracking {
                    self.track { $0.scene[detector: id]?[keyPath: keyPath] = newValue }
                } else {
                    self.edit(name, coalescingKey: [AnyHashable(id), AnyHashable(keyPath)]) {
                        $0.scene[detector: id]?[keyPath: keyPath] = newValue
                    }
                }
            }
        )
    }

    // MARK: Hit testing

    /// The detector whose line is within `tolerancePoints` of the point, or whose box
    /// contains it (or whose edge is that close). The nearest wins. `enabled` limits the
    /// search to enabled (true) or disabled (false) detectors; nil takes both.
    public func hitTestDetector(x: Double, y: Double, tolerancePoints: CGFloat = 6, enabled: Bool? = nil) -> String? {
        let tolerance = geometry.micrometres(forPoints: tolerancePoints)
        var best: (id: String, distance: Double)?
        for detector in scene.detectors where enabled.map({ detector.enabled == $0 }) ?? true {
            let d: Double
            switch detector.shape {
            case .line(let g):
                d = PlaneGeometry.segmentDistance(x: x, y: y, x1: g.x1Um, y1: g.y1Um, x2: g.x2Um, y2: g.y2Um)
            case .box:
                let corners = detector.points.map { [$0.x, $0.y] }
                d = PlaneGeometry.contains(corners, x: x, y: y) ? 0 : PlaneGeometry.distance(corners, x: x, y: y)
            }
            if d <= tolerance, best.map({ d < $0.distance }) ?? true {
                best = (detector.id, d)
            }
        }
        return best?.id
    }

    /// The emitter or beam waist within `tolerancePoints` of the point. Plane waves have no
    /// position on the canvas. `includeDisabled: false` skips disabled sources.
    public func hitTestSource(x: Double, y: Double, tolerancePoints: CGFloat = 8, includeDisabled: Bool = true) -> String? {
        let tolerance = geometry.micrometres(forPoints: tolerancePoints)
        var best: (id: String, distance: Double)?
        for source in scene.sources where source.kind != .planeWave && (includeDisabled || source.enabled) {
            let d = hypot(source.xUm - x, source.yUm - y)
            if d <= tolerance, best.map({ d < $0.distance }) ?? true {
                best = (source.id, d)
            }
        }
        return best?.id
    }
}

extension PlaneGeometry {
    /// Distance from a point to the segment from (x1, y1) to (x2, y2).
    public static func segmentDistance(x: Double, y: Double, x1: Double, y1: Double, x2: Double, y2: Double) -> Double {
        let dx = x2 - x1
        let dy = y2 - y1
        let len2 = dx * dx + dy * dy
        let t = len2 > 0 ? max(0, min(1, ((x - x1) * dx + (y - y1) * dy) / len2)) : 0
        return hypot(x1 + t * dx - x, y1 + t * dy - y)
    }
}
