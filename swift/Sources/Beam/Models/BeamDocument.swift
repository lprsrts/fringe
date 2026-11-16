import Foundation

/// Everything the user edits. Undo snapshots this whole value, and it is what is saved
/// between launches.
public struct BeamDocument: Codable, Equatable, Sendable {
    public var scene: SimScene
    public var display: DisplaySettings
    public var output: OutputFormat

    public init(scene: SimScene, display: DisplaySettings = DisplaySettings(), output: OutputFormat = OutputFormat()) {
        self.scene = scene
        self.display = display
        self.output = output
    }

    enum CodingKeys: String, CodingKey {
        case scene
        case display
        case output
    }

    /// The width over height of the domain a pixel aspect asks for.
    public mutating func applyShapeLock(imageAspect: Double) {
        scene.domain.applyAspect(imageAspect)
    }

    /// Makes the output aspect match the domain, so a loaded scene keeps the shape it was
    /// made with. A ratio that is not a preset becomes a custom ratio.
    public mutating func adoptDomainAspect() {
        let ratio = scene.domain.aspect
        if let current = output.aspect.ratio, abs(current - ratio) < 1e-6 * ratio { return }
        output.aspect = OutputAspect.matching(ratio: ratio)
    }

    /// Fits the domain around every enabled body outline and the waist, with a margin of
    /// max(2 λ_b, 10 %), at `imageAspect`.
    public mutating func fitDomain(outlines: SceneOutlines?, imageAspect: Double) {
        var box: RectUm?
        func include(_ x: Double, _ y: Double) {
            let p = RectUm(xMin: x, xMax: x, yMin: y, yMax: y)
            box = box.map { $0.union(p) } ?? p
        }
        for body in outlines?.bodies ?? [] where body.enabled {
            for point in body.outline where point.count == 2 {
                include(point[0], point[1])
            }
        }
        if scene.source.kind == .gaussianBeam {
            include(scene.source.waistXUm, scene.source.waistYUm)
        }
        guard var rect = box else { return }
        let lambdaB = scene.lambdaB
        let margin = max(2 * lambdaB, 0.1 * max(rect.width, rect.height))
        rect = rect.insetBy(-margin)
        let minWidth = 2 * lambdaB
        if rect.width < minWidth {
            rect = RectUm(xMin: rect.centerX - minWidth / 2, xMax: rect.centerX + minWidth / 2, yMin: rect.yMin, yMax: rect.yMax)
        }
        if rect.height < minWidth {
            rect = RectUm(xMin: rect.xMin, xMax: rect.xMax, yMin: rect.centerY - minWidth / 2, yMax: rect.centerY + minWidth / 2)
        }
        rect = rect.grown(toAspect: imageAspect)
        let width = min(400 * lambdaB, rect.width)
        scene.domain.set(centerX: rect.centerX, centerY: rect.centerY, width: width, height: width / imageAspect)
    }
}
