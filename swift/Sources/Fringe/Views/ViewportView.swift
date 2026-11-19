import AppKit
import Metal
import QuartzCore
import SwiftUI

/// The canvas's field image and vector overlays, as Core Animation layers in one AppKit
/// view, created once:
///
/// - the field: a `CAMetalLayer` coloured by `FieldGPU` (or, as a fallback, a plain layer
///   showing the CPU renderer's image);
/// - the scene overlays (outlines, sources, detectors, labels, selection) and the chrome
///   (colour bar, scale bar, caption), each a layer that redraws only when its own inputs
///   change, never because the image or the phase did;
/// - a frame layer with the letterbox tint and a fixed-rectangle shadow.
///
/// It watches the model with Observation itself, so nothing here re-evaluates a SwiftUI
/// body. Phase playback runs on the view's own display link, only while it is playing and
/// visible, and writes nothing to the model per frame. Hover goes through a tracking area
/// and sets the cursor directly. Clicks and drags pass through to the SwiftUI gestures.
struct ViewportRepresentable: NSViewRepresentable {
    let model: AppState

    func makeNSView(context: Context) -> ViewportView { ViewportView(model: model) }
    func updateNSView(_ view: ViewportView, context: Context) {}
}

@MainActor
final class ViewportView: NSView, CALayerDelegate {
    let model: AppState
    private let gpu: FieldGPU?

    private let frameLayer = CALayer()
    private let contentLayer = CALayer()
    private let metalLayer = CAMetalLayer()
    private let cpuLayer = CALayer()
    private let sceneLayer = CALayer()
    private let chromeLayer = CALayer()
    /// The item being dragged, drawn on its own so a move only shifts this layer.
    private let liveLayer = CALayer()
    /// Stands in for the Metal layer while an offscreen harness captures the window.
    private let captureLayer = CALayer()

    // Field state.
    private var currentPart: FieldPartBuffer?
    private var stencils: FieldStencils?
    /// The colour scale and what it was computed for. The field is compared by identity as
    /// well: a freed field's address can be reused by the next one.
    private var scaleKey: String?
    private weak var scaleField: FieldHandle?
    private var scaleValue = 1.0
    /// The playback path's resampled field (see `FieldGPU.resample`), only while playing.
    private var resampled: FieldResampled?
    private var fieldDirty = true
    private var drawnInputs: FieldInputs?

    // Overlay state.
    private var sceneDrawn: OverlayKey?
    private var chromeDrawn: OverlayKey?
    private var overlay: OverlayModel?
    private var overlaySize: CGSize = .zero

    // Playback.
    private var displayLink: CADisplayLink?
    private var playStart: (time: CFTimeInterval, phase: Double)?
    private var lastTick: CFTimeInterval = 0
    private var screensAsleep = false
    private var observers: [NSObjectProtocol] = []

    // Hover.
    private var trackingArea: NSTrackingArea?
    private var pendingHover: CGPoint??
    private var lastCursor: NSCursor?

    /// The harnesses' app is never active; this stands in for an active app.
    static var assumeActiveForTesting = false
    /// Whether the app is hidden (⌘H); the harness stands in for `NSApp.isHidden`.
    static var isAppHidden: @MainActor () -> Bool = { NSApp.isHidden }

    init(model: AppState) {
        self.model = model
        gpu = model.viewportUsesCPU ? nil : FieldGPU.shared
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        let root = CALayer()
        root.delegate = self
        layer = root
        for l in [frameLayer, contentLayer, metalLayer, cpuLayer, sceneLayer, chromeLayer, liveLayer, captureLayer] {
            l.delegate = self
            l.actions = Self.noActions
        }
        frameLayer.shadowColor = CGColor(gray: 0, alpha: 1)
        frameLayer.shadowRadius = 12
        frameLayer.shadowOffset = CGSize(width: 0, height: 4)
        contentLayer.masksToBounds = true
        metalLayer.device = gpu?.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false
        metalLayer.maximumDrawableCount = 2
        metalLayer.presentsWithTransaction = false
        metalLayer.isHidden = true
        cpuLayer.contentsGravity = .resize
        cpuLayer.minificationFilter = .trilinear
        cpuLayer.magnificationFilter = .linear
        cpuLayer.isHidden = true
        captureLayer.isHidden = true
        sceneLayer.drawsAsynchronously = true
        chromeLayer.drawsAsynchronously = true
        liveLayer.drawsAsynchronously = true
        // 8-bit sRGB backing stores: on an XDR display the default is half-float, twice the
        // memory and the fill work, and the overlays are sRGB colours anyway.
        for l in [sceneLayer, chromeLayer, liveLayer] { l.contentsFormat = .RGBA8Uint }
        liveLayer.isHidden = true
        sceneLayer.needsDisplayOnBoundsChange = false
        chromeLayer.needsDisplayOnBoundsChange = false
        root.addSublayer(frameLayer)
        root.addSublayer(contentLayer)
        contentLayer.addSublayer(metalLayer)
        contentLayer.addSublayer(cpuLayer)
        contentLayer.addSublayer(captureLayer)
        contentLayer.addSublayer(sceneLayer)
        contentLayer.addSublayer(liveLayer)
        contentLayer.addSublayer(chromeLayer)
        trackField()
        trackOverlays()
        trackPlayback()
        gpu?.whenReady { [weak self] in self?.setFieldDirty() }
        if !model.viewportUsesCPU {
            FieldGPU.shared?.whenFailed { [weak self] in self?.setFieldDirty() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static let noActions: [String: CAAction] = [
        "bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "contents": NSNull(), "hidden": NSNull(),
        "opacity": NSNull(), "shadowPath": NSNull(), "shadowOpacity": NSNull(), "backgroundColor": NSNull(),
        "sublayers": NSNull(), "onOrderIn": NSNull(), "onOrderOut": NSNull(), "contentsScale": NSNull(), "filters": NSNull(),
    ]

    nonisolated func action(for layer: CALayer, forKey event: String) -> CAAction? { NSNull() }

    override var isFlipped: Bool { true }
    /// Clicks, drags and pinches belong to the SwiftUI gestures around this view.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var backingScale: CGFloat { window?.backingScaleFactor ?? model.displayScale }
    private var usesGPU: Bool { gpu != nil && !model.viewportUsesCPU }

    // MARK: Size

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reportSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeVisibility()
        reportSize()
        viewDidChangeBackingProperties()
        updatePlayback()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = backingScale
        for l in [metalLayer, cpuLayer, captureLayer] where l.contentsScale != scale {
            l.contentsScale = scale
        }
        applyOverlayScale()
        if model.displayScale != scale { model.displayScale = scale }
        sceneDrawn = nil
        chromeDrawn = nil
        setFieldDirty()
        updateOverlays()
    }

    /// The canvas size goes to the model in whole points, and only when it changed by half
    /// a point or more, so sub-point jitter in a column's width never resizes the field.
    private func reportSize() {
        let size = CGSize(width: bounds.width.rounded(), height: bounds.height.rounded())
        let old = model.containerSize
        guard abs(size.width - old.width) >= 0.5 || abs(size.height - old.height) >= 0.5 else { return }
        PerfProbe.count("viewport.sizeReport")
        sizeChanged()
        // Not during AppKit's layout pass: the model change re-renders SwiftUI views.
        DispatchQueue.main.async { [model] in
            MainActor.assumeIsolated { if model.containerSize != size { model.containerSize = size } }
        }
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        model.isLiveResizing = true
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        model.isLiveResizing = false
        endResizing()
    }

    // MARK: Resizing

    /// While the size keeps changing (a live resize, or size changes less than
    /// `settleDelay` apart, as in a zoom animation), the field, overlay and drawable layers
    /// keep one size that covers every size seen, anchored at the image's top-left corner
    /// and clipped by the content layer: the field and overlays redraw at most 15 and 10
    /// times a second into the same buffers, instead of allocating new ones for each size.
    /// When the size settles they return to the exact size.
    private var resizeBucket: CGSize?
    private var lastSizeChange: CFTimeInterval = 0
    private var settleWork: DispatchWorkItem?
    static let settleDelay: CFTimeInterval = 0.3
    /// Buffer sizes grow in steps of this many points.
    static let bucketStep: CGFloat = 64

    var isResizing: Bool { resizeBucket != nil || model.isLiveResizing }

    /// Field and overlay pixels per point: the display's, or one while resizing (a quarter
    /// of the memory and fill for each buffer; the sharp frame follows when the size
    /// settles, as AppKit suggests for drawing during a live resize).
    private var fieldScale: CGFloat { resizeBucket != nil ? 1 : backingScale }
    private var overlayScale: CGFloat { fieldScale }

    private func applyOverlayScale() {
        let scale = overlayScale
        for l in [sceneLayer, chromeLayer, liveLayer] where l.contentsScale != scale {
            l.contentsScale = scale
        }
    }

    private func sizeChanged() {
        let now = CACurrentMediaTime()
        if (model.isLiveResizing || now - lastSizeChange < Self.settleDelay), resizeBucket == nil, window != nil {
            resizeBucket = .zero
            PerfProbe.count("viewport.resizeBegin")
            if !model.holdsColumnHeights { model.holdsColumnHeights = true }
            // Redrawn at once at the new scale and size, not stretched until the next
            // scheduled redraw.
            applyOverlayScale()
            sceneDrawn = nil
            chromeDrawn = nil
            liveBase = nil
        }
        lastSizeChange = now
        scheduleSettle()
    }

    private func scheduleSettle() {
        settleWork?.cancel()
        guard resizeBucket != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // A live resize held still: look again later.
                if self.model.isLiveResizing { self.scheduleSettle() } else { self.endResizing() }
            }
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    /// Back to buffers of the exact size, drawn once.
    private func endResizing() {
        settleWork?.cancel()
        settleWork = nil
        guard resizeBucket != nil else {
            if model.holdsColumnHeights, !model.isLiveResizing { model.holdsColumnHeights = false }
            return
        }
        resizeBucket = nil
        PerfProbe.count("viewport.resizeEnd")
        if model.holdsColumnHeights { model.holdsColumnHeights = false }
        applyOverlayScale()
        sceneDrawn = nil
        chromeDrawn = nil
        liveBase = nil
        setFieldDirty()
        updateOverlays()
    }

    /// The size of the field and overlay layers for an image of `size` points.
    private func layerSize(for size: CGSize) -> CGSize {
        guard var bucket = resizeBucket else { return size }
        func up(_ v: CGFloat) -> CGFloat { (v / Self.bucketStep).rounded(.up) * Self.bucketStep }
        if size.width > bucket.width || size.height > bucket.height {
            bucket.width = max(bucket.width, up(size.width))
            bucket.height = max(bucket.height, up(size.height))
            // The overlay layers grow: redraw them now rather than show them stretched.
            sceneDrawn = nil
            chromeDrawn = nil
            liveBase = nil
        }
        resizeBucket = bucket
        return bucket
    }

    // MARK: Observation

    /// Re-arms after each change; changes within one run loop turn coalesce.
    private func observe(_ read: @escaping @MainActor () -> Void, changed: @escaping @MainActor () -> Void) {
        withObservationTracking {
            read()
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Re-arm first: its read is the current state `changed` acts on.
                    self.observe(read, changed: changed)
                    changed()
                }
            }
        }
    }

    private func trackField() {
        observe({ [weak self] in _ = self?.fieldInputs() }, changed: { [weak self] in self?.setFieldDirty() })
        setFieldDirty()
    }

    private func trackOverlays() {
        observe({ [weak self] in self?.readOverlay() }, changed: { [weak self] in self?.updateOverlays() })
        updateOverlays()
    }

    private func trackPlayback() {
        observe({ [weak self] in
            guard let self else { return }
            _ = self.model.display.isPlaying
            _ = self.model.display.quantity
            _ = self.model.display.playbackSpeed
        }, changed: { [weak self] in self?.updatePlayback() })
    }

    // MARK: Field

    /// Everything the field image depends on except the phase during playback.
    struct FieldInputs: Equatable {
        var field: ObjectIdentifier?
        var display: DisplaySettings
        var isPlaying: Bool
        var viewRect: RectUm
        var imageRect: CGRect
        var stale: Bool
        var invalid: Bool
        var incidentPeak: Double
        var cpuImage: ObjectIdentifier?
        var cpuViewRect: RectUm?
    }

    private func fieldInputs() -> FieldInputs {
        let m = model
        let solver = m.solver
        let isDark = m.showsDarkCase
        let report = m.showsCheckedCase || isDark ? nil : solver.currentReport
        let shown = isDark ? nil : solver.shown
        let rendered = m.viewportUsesCPU ? m.renderer.rendered : nil
        return FieldInputs(
            field: shown.map { ObjectIdentifier($0.field) },
            display: m.display,
            isPlaying: m.display.isPlaying,
            viewRect: m.viewRect,
            imageRect: m.geometry.imageRect,
            stale: solver.isShownStale,
            invalid: report.map { !$0.ok } ?? false,
            incidentPeak: shown?.info.incidentPeak ?? 1,
            cpuImage: rendered.map { ObjectIdentifier($0.image) },
            cpuViewRect: rendered?.viewRect
        )
    }

    /// A model change: draw now, or at most 60 times a second (a pan on a 120 Hz display
    /// asks for more).
    private func setFieldDirty() {
        fieldDirty = true
        // While resizing, at most 15 a second, into the same drawables (see `layerSize`).
        let rate: Double = isResizing ? 15 : 60
        let wait = lastFieldDraw + 1.0 / rate * 0.9 - CACurrentMediaTime()
        guard wait > 0 else {
            lastFieldDraw = CACurrentMediaTime()
            drawField()
            return
        }
        guard !fieldDrawScheduled else { return }
        fieldDrawScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.fieldDrawScheduled = false
                self.lastFieldDraw = CACurrentMediaTime()
                self.drawField()
            }
        }
    }

    private var lastFieldDraw: CFTimeInterval = 0
    private var fieldDrawScheduled = false

    /// The image's size on whole device pixels, as last laid out: what the overlays draw in.
    private var imageSize: CGSize = .zero

    private func layoutFrame(_ rect: CGRect) {
        // On whole device pixels, as SwiftUI places views. `rect` is measured from the top;
        // the layers measure y down (`layersAreYDown`: the view is flipped), or up.
        let s = backingScale
        func snap(_ v: CGFloat) -> CGFloat { (v * s).rounded() / s }
        let x0 = snap(rect.minX), x1 = snap(rect.maxX), y0 = snap(rect.minY), y1 = snap(rect.maxY)
        let imageRect = CGRect(x: x0, y: layersAreYDown ? y0 : bounds.height - y1, width: x1 - x0, height: y1 - y0)
        let local = CGRect(origin: .zero, size: imageRect.size)
        imageSize = local.size
        // At the image's top-left corner; larger than the image (extending right and down)
        // while resizing.
        let size = layerSize(for: local.size)
        let position = CGPoint(x: size.width / 2, y: layersAreYDown ? size.height / 2 : local.height - size.height / 2)
        for l in [sceneLayer, chromeLayer, liveLayer] where l.bounds.size != size || l.position != position {
            // Set through bounds and position: `frame` is undefined under a transform.
            l.bounds = CGRect(origin: .zero, size: size)
            l.position = position
        }
        let fills = model.output.aspect == .window
        if frameLayer.frame != imageRect { frameLayer.frame = imageRect }
        if contentLayer.frame != imageRect { contentLayer.frame = imageRect }
        frameLayer.backgroundColor = CGColor(gray: 0, alpha: fills ? 0 : 0.25)
        frameLayer.shadowOpacity = fills ? 0 : 0.35
        let path = CGPath(rect: local, transform: nil)
        if frameLayer.shadowPath.map({ !$0.boundingBox.equalTo(local) }) ?? true { frameLayer.shadowPath = path }
    }

    /// Draws the field if anything it depends on changed (or `force`, for a phase tick).
    private func drawField(force: Bool = false) {
        PerfProbe.time("viewport.fieldMain") { drawFieldNow(force: force) }
    }

    private func drawFieldNow(force: Bool) {
        guard fieldDirty || force else { return }
        let inputs = fieldInputs()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        layoutFrame(inputs.imageRect)
        // The overlay layers just grew (resizing): redraw them rather than show them stretched.
        if overlay != nil, sceneDrawn == nil || chromeDrawn == nil { updateOverlays() }
        if usesGPU {
            cpuLayer.isHidden = true
            guard drawGPU(inputs) else { return }
        } else {
            metalLayer.isHidden = true
            drawCPU(inputs)
        }
        fieldDirty = false
        drawnInputs = inputs
        if displayLink != nil { updateRate() }
    }

    /// The CPU fallback's invalid-scene image and the image it was made from.
    private var greyed: (source: CGImage, image: CGImage)?

    private func drawCPU(_ inputs: FieldInputs) {
        guard let rendered = model.renderer.rendered, inputs.field != nil else {
            cpuLayer.isHidden = true
            cpuLayer.contents = nil
            return
        }
        let down = model.geometry.viewRect(for: rendered.viewRect).offsetBy(dx: -inputs.imageRect.minX, dy: -inputs.imageRect.minY)
        // `down` is measured from the image's top.
        cpuLayer.frame = CGRect(x: down.minX, y: layersAreYDown ? down.minY : contentLayer.bounds.height - down.maxY,
                                width: down.width, height: down.height)
        // The invalid-scene look: the shader's desaturation, made once per image.
        var image = rendered.image
        if inputs.invalid {
            if let g = greyed, g.source === image {
                image = g.image
            } else if let made = FieldLook.desaturated(image) {
                greyed = (image, made)
                image = made
            }
        } else {
            greyed = nil
        }
        if cpuLayer.contents as! CGImage? !== image { cpuLayer.contents = image }
        cpuLayer.opacity = inputs.stale || inputs.invalid ? 0.85 : 1
        cpuLayer.isHidden = false
        model.viewport.drawnField = rendered.field
        PerfProbe.count("viewport.cpuFrame")
    }

    /// The GPU frame for the current inputs, or nil (nothing to show, or still uploading).
    private func currentFrame(_ inputs: FieldInputs) -> FieldFrame? {
        guard let gpu, gpu.isReady, inputs.field != nil, let shown = model.solver.shown else { return nil }
        var display = inputs.display
        if let ready = gpu.buffer(for: shown.field, part: display.part, ready: { [weak self] in
            self?.model.viewport.fieldGeneration += 1
            self?.setFieldDirty()
        }) {
            currentPart = ready
        }
        // While a new field uploads, the previous one stays on screen at the new view.
        // (or the previous part, while a newly shown part uploads).
        guard let part = currentPart, let field = part.field else { return nil }
        display.part = part.key.part
        let amplitude = field === shown.field ? inputs.incidentPeak : (field.info?.incidentPeak ?? 1)
        let key = "\(display.part)|\(display.normalization)|\(display.normalizationValue * amplitude)"
        if key != scaleKey || scaleField !== field {
            scaleKey = key
            scaleField = field
            scaleValue = field.colourScale(viewJSON: display.viewJSON(viewRect: nil, incidentAmplitude: amplitude))
        }
        let scale = fieldScale
        let width = max(1, Int((contentLayer.bounds.width * scale).rounded()))
        let height = max(1, Int((contentLayer.bounds.height * scale).rounded()))
        // While resizing, the drawable covers the layer size (see `layerSize(for:)`), and
        // the view extends to the right and down at the same pixel size.
        var viewRect = inputs.viewRect
        let drawSize = layerSize(for: contentLayer.bounds.size)
        let drawWidth = max(width, Int((drawSize.width * scale).rounded()))
        let drawHeight = max(height, Int((drawSize.height * scale).rounded()))
        if drawWidth != width || drawHeight != height {
            let px = viewRect.width / Double(width), py = viewRect.height / Double(height)
            viewRect = RectUm(xMin: viewRect.xMin, xMax: viewRect.xMin + px * Double(drawWidth),
                              yMin: viewRect.yMax - py * Double(drawHeight), yMax: viewRect.yMax)
        }
        let phase = inputs.isPlaying ? model.viewport.phase : display.phaseDeg
        guard let frame = gpu.frame(field: field, part: part, display: display, phaseDeg: phase, viewRect: viewRect,
                                    width: drawWidth, height: drawHeight, incidentAmplitude: amplitude, stencils: stencils, scale: scaleValue,
                                    desaturate: inputs.invalid, opacity: inputs.stale || inputs.invalid ? 0.85 : 1) else { return nil }
        stencils = frame.stencils
        return frame
    }

    /// False when nothing could be drawn yet (the shader or the upload is still pending).
    private func drawGPU(_ inputs: FieldInputs) -> Bool {
        guard let gpu else { return false }
        guard inputs.field != nil else {
            metalLayer.isHidden = true
            currentPart = nil
            model.viewport.drawnField = nil
            return true
        }
        guard let frame = currentFrame(inputs) else { return false }
        let size = CGSize(width: frame.stencils.width, height: frame.stencils.height)
        let scale = fieldScale
        let height = contentLayer.bounds.height
        // At the top-left corner, the drawable's size in points.
        let local = CGRect(x: 0, y: layersAreYDown ? 0 : height - size.height / scale, width: size.width / scale, height: size.height / scale)
        if metalLayer.frame != local { metalLayer.frame = local }
        if metalLayer.drawableSize != size { metalLayer.drawableSize = size }
        guard present(frame, gpu, playback: false) else { return false }
        if metalLayer.isHidden { metalLayer.isHidden = false }
        lastFrame = frame
        model.viewport.drawnField = frame.part.field
        return true
    }

    /// The last frame drawn: a playback tick only changes its phase.
    private var lastFrame: FieldFrame?

    /// Encodes and presents one frame; no layer property changes, no Core Animation
    /// transaction of its own. A playback frame colours the resampled field (made on the
    /// first frame of a view, kept while it plays). The command buffer retains what it
    /// reads, so replacing the frame, stencils or colour table while the GPU still draws
    /// the previous one is safe.
    private func present(_ frame: FieldFrame, _ gpu: FieldGPU, playback: Bool) -> Bool {
        guard let drawable = metalLayer.nextDrawable(), let cb = gpu.queue.makeCommandBuffer() else {
            PerfProbe.count("viewport.noDrawable")
            return false
        }
        var source: FieldResampled?
        if playback {
            if let r = resampled, r.matches(frame) {
                source = r
            } else {
                resampled = nil
                resampled = gpu.resample(frame, into: cb)
                source = resampled
            }
        }
        guard gpu.encode(frame, into: cb, target: drawable.texture, resampled: source) else { return false }
        // GPU time on one frame in 16, so measuring it costs little.
        if PerfProbe.enabled, model.viewport.framesDrawn % 16 == 0 {
            cb.addCompletedHandler { cb in
                let ns = Int(max(0, cb.gpuEndTime - cb.gpuStartTime) * 1e9)
                PerfProbe.count("viewport.gpu_ns", by: ns)
                PerfProbe.count("viewport.gpu_frames")
            }
        }
        cb.present(drawable)
        cb.commit()
        model.viewport.framesDrawn += 1
        PerfProbe.count("viewport.frame")
        return true
    }

    /// A playback frame: when nothing but the phase changed since the last frame, only the
    /// phase uniform is updated, and only the colouring runs. The CPU fallback renders a
    /// new image instead.
    private func drawPhaseFrame() {
        guard usesGPU else {
            model.scheduleRender()
            return
        }
        guard !fieldDirty, let gpu, var frame = lastFrame, !metalLayer.isHidden else {
            drawField(force: true)
            return
        }
        let rot = FieldUniforms.phaseFactor(model.viewport.phase)
        frame.uniforms.cosp = Float(rot.re)
        frame.uniforms.sinp = Float(rot.im)
        if present(frame, gpu, playback: true) { lastFrame = frame }
    }

    // MARK: Overlays

    struct OverlayKey: Equatable {
        var model: OverlayModel
        var size: CGSize
        var scale: CGFloat
    }

    private func readOverlay() {
        let m = model
        overlay = m.overlayModel(viewRect: m.viewRect)
        liveEdit = m.viewport.liveEdit
        overlaySize = m.geometry.imageRect.size
    }

    // What each overlay layer last drew, and what it draws next.
    private var sceneModel: OverlayModel?
    private var chromeModel: OverlayModel?
    private var liveModel: OverlayModel?
    private var liveEdit: LiveEdit?
    /// The drag the live layer was drawn for, and the model it drew.
    private var liveBase: (edit: LiveEdit, viewRect: RectUm)?
    private var sceneRedraw: DispatchWorkItem?
    private var lastSceneDraw: CFTimeInterval = 0

    /// Redraws the overlay layers whose inputs differ from what they show; `overlay` is the
    /// model the observation just read. During a drag the dragged item is drawn alone in
    /// the live layer, which a move only shifts; during a pan or pinch the scene layer is
    /// shifted and scaled, and redrawn at most 10 times a second.
    private func updateOverlays() {
        PerfProbe.time("viewport.overlayMain") { updateOverlaysNow() }
    }

    private func updateOverlaysNow() {
        guard let overlay else { return }
        let scale = overlayScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        layoutFrame(model.geometry.imageRect)
        let size = overlaySize
        var base = overlay
        if let live = liveEdit {
            var item = overlay
            base.remove(live)
            item.keepOnly(live)
            item.applyLive(live, scene: model.scene)
            updateLiveLayer(live, item: item, size: size, scale: scale)
        } else if liveModel != nil {
            liveModel = nil
            liveBase = nil
            liveLayer.isHidden = true
            liveLayer.contents = nil
            liveLayer.setAffineTransform(.identity)
        }
        let chromeKey = OverlayKey(model: overlay.chromeOnly.normalized, size: size, scale: scale)
        if chromeKey != chromeDrawn {
            let viewOnly = chromeDrawn.map { $0.size == size && $0.scale == scale && $0.model.with(viewRect: chromeKey.model.viewRect, interior: chromeKey.model.interior) == chromeKey.model } ?? false
            if (viewOnly && model.viewOverride != nil) || (isResizing && chromeDrawn != nil) {
                // A pinch changes the scale bar: at most 10 redraws a second.
                scheduleChromeRedraw(overlay, key: chromeKey)
            } else {
                drawChrome(overlay, key: chromeKey)
            }
        }
        let key = OverlayKey(model: base, size: size, scale: scale)
        guard key != sceneDrawn else { return }
        if isResizing, sceneDrawn != nil {
            // Redraw at most 10 times a second, and when the size settles.
            scheduleSceneRedraw(base, key: key)
            return
        }
        if let drawn = sceneDrawn, drawn.size == size, drawn.scale == scale, drawn.model.viewRect != base.viewRect,
           drawn.model.with(viewRect: base.viewRect, interior: base.interior) == base {
            // Only the view moved: shift and scale what is drawn, redraw soon.
            sceneLayer.setAffineTransform(Self.transform(from: drawn.model.viewRect, to: base.viewRect, size: size, yDown: layersAreYDown))
            scheduleSceneRedraw(base, key: key)
            return
        }
        drawScene(base, key: key)
    }

    private var chromeRedraw: DispatchWorkItem?
    private var lastChromeDraw: CFTimeInterval = 0

    private func drawChrome(_ m: OverlayModel, key: OverlayKey) {
        chromeRedraw?.cancel()
        chromeRedraw = nil
        chromeDrawn = key
        chromeModel = m
        lastChromeDraw = CACurrentMediaTime()
        chromeLayer.setNeedsDisplay()
    }

    private func scheduleChromeRedraw(_ m: OverlayModel, key: OverlayKey) {
        chromeRedraw?.cancel()
        let wait = max(0, lastChromeDraw + 0.1 - CACurrentMediaTime())
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self?.drawChrome(m, key: key)
                CATransaction.commit()
            }
        }
        chromeRedraw = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    private func drawScene(_ base: OverlayModel, key: OverlayKey) {
        sceneRedraw?.cancel()
        sceneRedraw = nil
        sceneDrawn = key
        sceneModel = base
        lastSceneDraw = CACurrentMediaTime()
        sceneLayer.setAffineTransform(.identity)
        sceneLayer.setNeedsDisplay()
    }

    private func scheduleSceneRedraw(_ base: OverlayModel, key: OverlayKey) {
        sceneRedraw?.cancel()
        let wait = max(0, lastSceneDraw + 0.1 - CACurrentMediaTime())
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.drawScene(base, key: key)
                CATransaction.commit()
            }
        }
        sceneRedraw = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    /// The dragged item: drawn once per drag (and when its shape changes), then shifted.
    private func updateLiveLayer(_ live: LiveEdit, item: OverlayModel, size: CGSize, scale: CGFloat) {
        if let base = liveBase, base.viewRect == item.viewRect, let delta = live.translation(from: base.edit) {
            let r = item.viewRect
            let tx = delta.dx / r.width * size.width
            // Up the plane is down the layer in a y-down layer tree.
            let ty = (layersAreYDown ? -1 : 1) * delta.dy / r.height * size.height
            liveLayer.setAffineTransform(CGAffineTransform(translationX: tx, y: ty))
            PerfProbe.count("viewport.liveShift")
            return
        }
        liveBase = (live, item.viewRect)
        liveModel = item
        liveLayer.setAffineTransform(.identity)
        liveLayer.isHidden = false
        liveLayer.setNeedsDisplay()
    }

    /// Whether the overlay layers' superlayer measures y downward. The view is flipped, so
    /// AppKit flips its backing layer's geometry, and the layers inside inherit it; a layer
    /// translation of +y then moves content down the screen.
    private var layersAreYDown: Bool { contentLayer.contentsAreFlipped() }

    /// The layer transform (about its centre) that maps content drawn for view `a` onto
    /// where it lies in view `b`, for a layer tree that measures y downward (`yDown`) or up.
    static func transform(from a: RectUm, to b: RectUm, size: CGSize, yDown: Bool) -> CGAffineTransform {
        guard b.width > 0, b.height > 0 else { return .identity }
        let w = size.width, h = size.height
        let sx = CGFloat(a.width / b.width), sy = CGFloat(a.height / b.height)
        let tx = CGFloat((a.xMin - b.xMin) / b.width) * w
        let tyDown = CGFloat((b.yMax - a.yMax) / b.height) * h
        let tyUp = h - sy * h - tyDown
        let cx = w / 2, cy = h / 2
        return CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: sx * cx + tx - cx, ty: sy * cy + (yDown ? tyDown : tyUp) - cy)
    }

    nonisolated func draw(_ layer: CALayer, in ctx: CGContext) {
        MainActor.assumeIsolated { PerfProbe.time("viewport.layerDrawMain") { drawLayer(layer, in: ctx) } }
    }

    private func drawLayer(_ layer: CALayer, in ctx: CGContext) {
        let parts: VectorRenderer.OverlayParts
        let drawn: OverlayModel?
        let size: CGSize
        if layer === sceneLayer {
            parts = .scene; drawn = sceneModel; size = imageSize
            PerfProbe.count("viewport.sceneDraw")
        } else if layer === chromeLayer {
            parts = .chrome; drawn = chromeModel; size = imageSize
            PerfProbe.count("viewport.chromeDraw")
        } else if layer === liveLayer {
            parts = .scene; drawn = liveModel; size = imageSize
            PerfProbe.count("viewport.liveDraw")
        } else {
            return
        }
        guard let drawn else { return }
        // As the SwiftUI Canvas the overlays used to draw in: smoothed text.
        ctx.setAllowsFontSmoothing(true)
        ctx.setShouldSmoothFonts(true)
        // A layer's context is y-up unless the layer says its contents are flipped; the
        // image sits at the top of a layer that is taller while resizing.
        let flipped = !layer.contentsAreFlipped()
        if flipped, layer.bounds.height != size.height { ctx.translateBy(x: 0, y: layer.bounds.height - size.height) }
        // Dynamic colours (the accent for the selection, handles and puzzle region) resolve
        // for this view's appearance.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            VectorRenderer.drawOverlays(in: ctx, size: size, flipped: flipped, model: drawn, minimumTextScale: 1, parts: parts)
        }
    }

    /// The overlays draw with dynamic system colours, which an appearance or accent colour
    /// change alters without changing anything the overlay layers are keyed on.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        redrawOverlaysForNewColours()
    }

    private func redrawOverlaysForNewColours() {
        PerfProbe.count("viewport.colourRedraw")
        sceneDrawn = nil
        chromeDrawn = nil
        liveBase = nil
        updateOverlays()
    }

    // MARK: Playback

    /// Whether frames should tick: playing a quantity that moves with the phase, with a
    /// field to show, in a window someone can see.
    var wantsFrames: Bool {
        model.display.isPlaying && model.display.quantity.dependsOnPhase && isVisibleOnScreen
    }

    var isVisibleOnScreen: Bool {
        guard bounds.width >= 1, bounds.height >= 1 else { return false }
        guard let window, !window.isMiniaturized, !Self.isAppHidden(), !screensAsleep else { return false }
        return window.occlusionState.contains(.visible)
    }

    private func updatePlayback() {
        if wantsFrames {
            if displayLink == nil {
                let link = displayLink(target: self, selector: #selector(tick(_:)))
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
            updateRate()
            displayLink?.isPaused = false
            playStart = nil
        } else {
            displayLink?.isPaused = true
            displayLink?.invalidate()
            displayLink = nil
            playStart = nil
            // The resampled field is only for playback frames.
            resampled = nil
        }
        if !model.display.isPlaying { setFieldDirty() }
    }

    /// The playback rate: the lowest of 30, 40 and 60 frames a second at which the pattern
    /// moves at most `maxStepPixels` device pixels a frame (a wave moves at most one
    /// vacuum wavelength per cycle), so a slow animation does not pay for frames that look
    /// the same; half that while the app is in the background, in Low Power Mode or when the
    /// Mac is hot. `forcedRate` overrides it (harness comparisons).
    private var preferredRate: CAFrameRateRange {
        let info = ProcessInfo.processInfo
        let active = NSApp.isActive || Self.assumeActiveForTesting
        let slow = !active || info.isLowPowerModeEnabled || info.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        var rate = Self.forcedRate ?? motionRate
        if slow { rate /= 2 }
        return CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
    }

    /// At most this many device pixels of pattern motion per playback frame.
    static let maxStepPixels = 2.0
    nonisolated(unsafe) static var forcedRate: Float?

    private var motionRate: Float {
        let needed = motionPixelsPerSecond / Self.maxStepPixels
        return [30, 40, 60].first { Double($0) >= needed } ?? 60
    }

    /// How fast the pattern moves on screen during playback, at most: one vacuum
    /// wavelength per cycle, in device pixels per second.
    var motionPixelsPerSecond: Double {
        let width = Double(max(1, contentLayer.bounds.width * backingScale))
        let view = model.viewRect.width
        guard view > 0 else { return .infinity }
        return model.display.playbackSpeed * model.scene.wavelengthUm * width / view
    }

    /// The rate the display link was last given.
    private(set) var rate: Float = 60
    var frameInterval: CFTimeInterval { 1 / Double(rate) }

    /// Re-reads the playback rate (the view, size or speed may have changed it).
    private func updateRate() {
        let range = preferredRate
        rate = range.preferred ?? 60
        if let link = displayLink, link.preferredFrameRateRange != range { link.preferredFrameRateRange = range }
    }

    @objc private func tick(_ link: CADisplayLink) {
        advance(to: link.targetTimestamp)
    }

    /// One playback frame at time `t`: the phase follows from time, not by accumulation.
    private func advance(to t: CFTimeInterval) {
        PerfProbe.count("viewport.tick")
        guard model.display.isPlaying else { return }
        // Skip ticks closer than the frame interval (a 120 Hz display at a 60 Hz cap). The
        // margin is half a 120 Hz tick: with 0.75 of the interval, three 120 Hz ticks
        // (25.0 ms) passed for a 30 fps frame (25.0 ms) whenever rounding allowed, which
        // drew up to 40 frames a second instead of 30.
        if t - lastTick < frameInterval - 1.0 / 240 { return }
        lastTick = t
        guard let start = playStart else {
            playStart = (t, model.viewport.phase)
            drawPhaseFrame()
            return
        }
        let degrees = 360 * model.display.playbackSpeed * (t - start.time)
        var phase = (start.phase + degrees).truncatingRemainder(dividingBy: 360)
        if phase < 0 { phase += 360 }
        model.viewport.phase = phase
        drawPhaseFrame()
    }

    /// For the offscreen harnesses, whose window never shows and whose display link
    /// therefore never ticks: one frame at `t` if a visible window would draw one.
    func tickForTesting(at t: CFTimeInterval) {
        updatePlaybackIfNeeded()
        guard wantsFrames else { return }
        advance(to: t)
    }

    /// Whether the playback display link exists, for the harnesses' visibility checks.
    var hasDisplayLink: Bool { displayLink != nil }

    private func updatePlaybackIfNeeded() {
        if wantsFrames != (displayLink != nil) { updatePlayback() }
    }

    private func observeVisibility() {
        for o in observers { NotificationCenter.default.removeObserver(o); NSWorkspace.shared.notificationCenter.removeObserver(o) }
        observers = []
        guard let window else { return }
        let center = NotificationCenter.default
        let update: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePlayback() }
        }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main, using: update))
        }
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification,
                     NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: NSApp, queue: .main, using: update))
        }
        observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main, using: update))
        // The accent colour (System Settings) changes the selection's colour.
        observers.append(center.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.redrawOverlaysForNewColours() }
        })
        observers.append(center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main, using: update))
        let workspace = NSWorkspace.shared.notificationCenter
        for (name, asleep) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false),
                               (NSWorkspace.sessionDidResignActiveNotification, true), (NSWorkspace.sessionDidBecomeActiveNotification, false)] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.screensAsleep = asleep
                    self?.updatePlayback()
                }
            })
        }
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) { pointerMoved(to: convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { pointerMoved(to: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { pointerMoved(to: nil) }
    override func cursorUpdate(with event: NSEvent) { updateCursor(at: convert(event.locationInWindow, from: nil)) }

    /// A pointer move. The readout follows at most `hoverRate` times a second (a status-bar
    /// number needs no more), always with the newest point.
    func pointerMoved(to point: CGPoint?) {
        let pending = pendingHover != nil
        pendingHover = .some(point)
        guard !pending else { return }
        let wait = lastHoverFlush + 1 / Self.hoverRate - CACurrentMediaTime()
        if wait <= 0 {
            RunLoop.main.perform(inModes: [.common]) { [weak self] in
                MainActor.assumeIsolated { self?.flushHover() }
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                MainActor.assumeIsolated { self?.flushHover() }
            }
        }
    }

    static let hoverRate: CFTimeInterval = 30
    private var lastHoverFlush: CFTimeInterval = 0

    private func flushHover() {
        guard let pending = pendingHover else { return }
        pendingHover = nil
        lastHoverFlush = CACurrentMediaTime()
        model.updateHover(at: pending)
        if let pending { updateCursor(at: pending) }
    }

    private func updateCursor(at point: CGPoint) {
        let cursor: NSCursor
        if model.isTracking {
            cursor = .closedHand
        } else if !model.geometry.imageRect.contains(point) {
            cursor = .arrow
        } else {
            let target = model.canvasTarget(at: point)
            if model.isInPuzzle {
                cursor = target.map { model.isPlayerItem($0.item) } == true ? .pointingHand : .arrow
            } else {
                cursor = target == nil ? .openHand : .pointingHand
            }
        }
        if cursor !== lastCursor || NSCursor.current !== cursor {
            lastCursor = cursor
            cursor.set()
        }
    }

    // MARK: Offscreen capture

    /// `renderInContext` cannot read a Metal layer: the harnesses call this before a
    /// capture to show the same frame (same shader, stencils and uniforms) as an image.
    func bakeForCapture() {
        // A capture shows the settled canvas, not the interim buffers of a resize.
        endResizing()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        sceneLayer.displayIfNeeded()
        chromeLayer.displayIfNeeded()
        liveLayer.displayIfNeeded()
        guard usesGPU, !metalLayer.isHidden, let gpu, let frame = currentFrame(fieldInputs()), let image = gpu.renderImage(frame) else { return }
        captureLayer.frame = metalLayer.frame
        captureLayer.contents = image
        captureLayer.isHidden = false
        metalLayer.isHidden = true
    }

    func unbakeAfterCapture() {
        guard !captureLayer.isHidden else { return }
        captureLayer.isHidden = true
        captureLayer.contents = nil
        metalLayer.isHidden = false
    }

    /// The field as drawn, for the harnesses.
    func snapshotField() -> CGImage? {
        guard usesGPU, let gpu, let frame = currentFrame(fieldInputs()) else { return nil }
        return gpu.renderImage(frame)
    }

    /// Animation keys on any layer of this view's tree, for the idle check.
    var animatedLayerCount: Int {
        func count(_ l: CALayer) -> Int { ((l.animationKeys()?.isEmpty ?? true) ? 0 : 1) + (l.sublayers ?? []).reduce(0) { $0 + count($1) } }
        return layer.map(count) ?? 0
    }
}

extension LiveEdit {
    /// How far this edit moved the item since `base`, in µm, if it only moved it.
    func translation(from base: LiveEdit) -> (dx: Double, dy: Double)? {
        switch (self, base) {
        case let (.element(a, x1, y1), .element(b, x0, y0)) where a == b: return (x1 - x0, y1 - y0)
        case let (.source(a, x1, y1), .source(b, x0, y0)) where a == b: return (x1 - x0, y1 - y0)
        case let (.detector(d1), .detector(d0)) where d1.id == d0.id:
            let p1 = d1.points, p0 = d0.points
            guard p1.count == p0.count, let f1 = p1.first, let f0 = p0.first else { return nil }
            let dx = f1.x - f0.x, dy = f1.y - f0.y
            for (a, b) in zip(p1, p0) where abs(a.x - b.x - dx) > 1e-9 || abs(a.y - b.y - dy) > 1e-9 { return nil }
            var moved = d0.moved(by: dx, dy)
            moved.shape = d1.shape
            return moved == d1 ? (dx, dy) : nil
        default: return nil
        }
    }

    var isElementMove: Bool {
        if case .element = self { return true }
        return false
    }

    var itemID: String {
        switch self {
        case .element(let id, _, _), .source(let id, _, _), .sourceAngle(let id, _): return id
        case .detector(let d): return d.id
        }
    }
}

extension OverlayModel {
    func with(viewRect: RectUm, interior: RectUm) -> OverlayModel {
        var m = self
        m.viewRect = viewRect
        m.interior = interior
        return m
    }

    /// The chrome model with the view moved to the origin (and the detectors with it), so a
    /// pan does not redraw the colour bar, scale bar and caption.
    var normalized: OverlayModel {
        var m = self
        let dx = -viewRect.xMin, dy = -viewRect.yMin
        m.viewRect = RectUm(xMin: 0, xMax: viewRect.width, yMin: 0, yMax: viewRect.height)
        m.interior = RectUm(xMin: interior.xMin + dx, xMax: interior.xMax + dx, yMin: interior.yMin + dy, yMax: interior.yMax + dy)
        m.detectors = detectors.map { $0.moved(by: dx, dy) }
        return m
    }

    /// Without the dragged item (the live layer draws it).
    mutating func remove(_ live: LiveEdit) {
        let id = live.itemID
        switch live {
        case .element:
            if conductors == outlines, conductors != nil { conductors?.bodies.removeAll { $0.elementId == id } }
            outlines?.bodies.removeAll { $0.elementId == id }
            anchors[id] = nil
            // Its focus moves with it, in the live layer.
            if focusIDs.count == focusPoints.count {
                let keep = focusIDs.indices.filter { focusIDs[$0] != id }
                focusPoints = keep.map { focusPoints[$0] }
                focusIDs = keep.map { focusIDs[$0] }
            }
        case .source, .sourceAngle:
            sources.removeAll { $0.id == id }
        case .detector:
            detectors.removeAll { $0.id == id }
            detectorLabels[id] = nil
        }
    }

    /// Only the dragged item: no other scene marks and no PML, puzzle region or focus.
    mutating func keepOnly(_ live: LiveEdit) {
        let id = live.itemID
        var d = display
        d.showPML = false
        display = d
        puzzle = puzzle.map { p in PuzzleOverlay(region: nil, lockedIDs: p.lockedIDs, sourceLabels: p.sourceLabels, outOfRegionIDs: p.outOfRegionIDs) }
        // A dragged element keeps its focus mark (a move carries it along; the live layer is
        // shifted, not redrawn).
        let focus = focusIDs.count == focusPoints.count && live.isElementMove
            ? focusIDs.indices.filter { focusIDs[$0] == id } : []
        focusPoints = focus.map { focusPoints[$0] }
        focusIDs = focus.map { focusIDs[$0] }
        legend = nil
        caption = nil
        switch live {
        case .element:
            let keep = outlines?.bodies.filter { $0.elementId == id }
            if conductors == outlines, conductors != nil { conductors?.bodies = keep ?? [] } else { conductors = SceneOutlines.empty(like: outlines) }
            outlines?.bodies = keep ?? []
            anchors = anchors.filter { $0.key == id }
            sources = []
            detectors = []
            detectorLabels = [:]
        case .source, .sourceAngle:
            outlines?.bodies = []
            conductors = SceneOutlines.empty(like: outlines)
            anchors = [:]
            sources = sources.filter { $0.id == id }
            detectors = []
            detectorLabels = [:]
        case .detector:
            outlines?.bodies = []
            conductors = SceneOutlines.empty(like: outlines)
            anchors = [:]
            sources = []
            detectors = detectors.filter { $0.id == id }
            detectorLabels = detectorLabels.filter { $0.key == id }
        }
    }
}

extension SceneOutlines {
    /// The same outlines with no bodies (nil stays nil).
    static func empty(like o: SceneOutlines?) -> SceneOutlines? {
        guard var o else { return nil }
        o.bodies = []
        return o
    }
}

extension OverlayModel {
    /// What the chrome layer draws from: no scene items but the detectors (the scale bar
    /// steps aside for them).
    var chromeOnly: OverlayModel {
        var m = self
        m.outlines = nil
        m.sources = []
        m.detectorLabels = [:]
        m.readingsStale = false
        m.focusPoints = []
        m.focusIDs = []
        m.selection = nil
        m.anchors = [:]
        m.conductors = nil
        m.puzzle = nil
        return m
    }

    /// The dragged item where the pointer has it, ahead of the document.
    mutating func applyLive(_ live: LiveEdit, scene: SimScene) {
        switch live {
        case .element(let id, let x, let y):
            guard let element = scene[element: id] else { return }
            let dx = x - element.xUm, dy = y - element.yUm
            guard dx != 0 || dy != 0 else { return }
            if var o = outlines {
                for i in o.bodies.indices where o.bodies[i].elementId == id {
                    o.bodies[i].outline = o.bodies[i].outline.map { [$0[0] + dx, $0[1] + dy] }
                }
                if conductors == outlines { conductors = o }
                outlines = o
            }
            anchors[id] = [x, y]
            if focusIDs.count == focusPoints.count {
                for i in focusPoints.indices where focusIDs[i] == id && focusPoints[i].count == 2 {
                    focusPoints[i] = [focusPoints[i][0] + dx, focusPoints[i][1] + dy]
                }
            }
        case .source(let id, let x, let y):
            if let i = sources.firstIndex(where: { $0.id == id }) {
                sources[i].xUm = x
                sources[i].yUm = y
            }
        case .sourceAngle(let id, let angle):
            if let i = sources.firstIndex(where: { $0.id == id }) { sources[i].angleDeg = angle }
        case .detector(let detector):
            if let i = detectors.firstIndex(where: { $0.id == detector.id }) { detectors[i] = detector }
        }
    }
}
