import CoreGraphics
import Foundation
import Observation
import os

/// One render of a solved field: what to show, at what size, of which part of the plane.
public struct RenderRequest {
    public var field: FieldHandle
    public var viewJSON: String
    public var viewRect: RectUm
    public var width: Int
    public var height: Int

    func same(as other: RenderRequest) -> Bool {
        field === other.field && viewJSON == other.viewJSON && viewRect == other.viewRect
            && width == other.width && height == other.height
    }
}

/// A rendered image and the plane rectangle it covers, so the canvas can place it
/// correctly even while a newer render for a moved view is still running.
public struct RenderedImage {
    public var image: CGImage
    public var viewRect: RectUm
    public var field: FieldHandle
}

/// Renders fields off the main thread, latest wins: one render runs, and of the requests
/// that arrive meanwhile only the newest is rendered next. The core's render cannot be
/// interrupted, so this keeps the canvas from falling behind.
@MainActor
@Observable
public final class RenderController {
    public private(set) var rendered: RenderedImage?
    /// How long the last render took.
    public private(set) var lastDuration: Duration = .zero

    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var pending: RenderRequest?
    @ObservationIgnored private var last: RenderRequest?

    nonisolated private static let log = Logger(subsystem: "com.asympton.beam-bg", category: "render")

    public init() {}

    public func submit(_ request: RenderRequest) {
        if let last, last.same(as: request), pending == nil { return }
        guard !inFlight else {
            pending = request
            return
        }
        run(request)
    }

    /// Drops the image, for example when there is no result to show.
    public func clear() {
        rendered = nil
        last = nil
        pending = nil
    }

    private func run(_ request: RenderRequest) {
        inFlight = true
        last = request
        Task {
            let start = ContinuousClock.now
            let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                do {
                    return try request.field.render(viewJSON: request.viewJSON, width: request.width, height: request.height)
                } catch {
                    RenderController.log.error("Render failed: \(error.localizedDescription)")
                    return nil
                }
            }.value
            lastDuration = ContinuousClock.now - start
            if let image {
                rendered = RenderedImage(image: image, viewRect: request.viewRect, field: request.field)
            }
            inFlight = false
            if let next = pending {
                pending = nil
                if !next.same(as: request) { run(next) }
            }
        }
    }
}
