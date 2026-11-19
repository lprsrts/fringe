import Foundation
import Observation

/// What a drag shows before it reaches the document: the dragged item's current geometry.
/// The canvas draws it at once; the document follows at most every 100 ms (see
/// `AppState.trackLive`).
public enum LiveEdit: Equatable {
    case element(id: String, xUm: Double, yUm: Double)
    case source(id: String, xUm: Double, yUm: Double)
    case sourceAngle(id: String, angleDeg: Double)
    case detector(Detector)

    /// Applies the edit to a document.
    func apply(to doc: inout FringeDocument) {
        switch self {
        case .element(let id, let x, let y):
            doc.scene[element: id]?.xUm = x
            doc.scene[element: id]?.yUm = y
        case .source(let id, let x, let y):
            doc.scene[source: id]?.xUm = x
            doc.scene[source: id]?.yUm = y
        case .sourceAngle(let id, let angle):
            doc.scene[source: id]?.angleDeg = angle
        case .detector(let detector):
            doc.scene[detector: detector.id] = detector
        }
    }
}

/// Canvas-only state: the pointer readout, the live drag and the animated phase. Only the
/// canvas and the status bar's readout read it, so pointer and frame traffic never
/// re-evaluates the sidebar, the inspector or the results.
@MainActor
@Observable
public final class ViewportModel {
    /// What the pointer is over. Not observed: the status bar's readout is an AppKit text
    /// field that takes each new value directly, so a pointer move lays out nothing.
    @ObservationIgnored public var hover: HoverReadout? {
        didSet { if hover != oldValue { hoverSinks.forEach { $0.value?.show(hover) } } }
    }
    @ObservationIgnored var hoverSinks: [WeakReadout] = []

    struct WeakReadout {
        weak var value: HoverReadoutField?
    }
    /// The dragged item's current geometry, ahead of the document.
    public var liveEdit: LiveEdit?

    /// The animated phase while playback runs. Not observed: the canvas reads it each
    /// frame, the readout and the export on demand.
    @ObservationIgnored public var phase: Double = 0
    /// Bumped when a new field buffer is ready on the GPU; for the harnesses.
    @ObservationIgnored public var fieldGeneration = 0
    /// The field the canvas last drew, for the harnesses' "rendered" checks.
    @ObservationIgnored public weak var drawnField: FieldHandle?
    /// Frames drawn, for the harnesses.
    @ObservationIgnored public var framesDrawn = 0

    public init() {}
}
