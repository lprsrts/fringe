// Mac App Store screenshots of the real app, with no text added: drives AppState
// headlessly, solves each scene at final quality, renders FringeWindow in an offscreen
// NSWindow (never ordered front, made key or sent input), captures the whole window, title
// bar and toolbar included, with cacheDisplay at 2x and writes it as a 2880 x 1800 PNG.
//
// Compiled together with the app sources (minus FringeMain.swift) by build.sh.
// usage: fringe-screenshots OUT_DIR [ONLY_PREFIX]
import AppKit
import QuartzCore
import SwiftUI

// MARK: - Shots

struct Shot {
    var file: String
    var example: String
    var method: SolverMethod
    var quantity: Quantity
    var colormap: ColormapName
    var phaseDeg: Double? = nil
    var selection: (AppState) -> SidebarItem
    /// How the image meets the canvas: the domain grown or cropped to the canvas shape with
    /// the image following the window, or a fixed output aspect ratio.
    var fit: Fit = .grow
    /// Scrolls the inspector as far as it goes with both its top edge (the toolbar) and its
    /// bottom edge falling between rows rather than through one.
    var scrollInspectorToEnd = false
    var prepare: (inout FringeDocument) -> Void = { _ in }

    enum Fit { case grow, crop, aspect(OutputAspect) }
}

@MainActor let shots: [Shot] = [
    // A biconvex lens focusing a Gaussian beam (FDTD), with the source inspector.
    Shot(file: "01-lens-focus", example: "lens", method: .fdtd, quantity: .intensity, colormap: .inferno,
         selection: { _ in .source }, prepare: { $0.display.showParaxialFocus = false }),
    // A photonic nanojet behind a glass cylinder (FEM), with the solver inspector.
    Shot(file: "02-nanojet", example: "mie_dielectric", method: .fem, quantity: .intensity, colormap: .plasma,
         selection: { _ in .simulation }, fit: .crop, scrollInspectorToEnd: true),
    // Young's double slit in the phase of the field, weighted by its strength (MoM), with
    // the display inspector.
    Shot(file: "03-double-slit-phase", example: "double_slit", method: .mom, quantity: .phase, colormap: .twilight, phaseDeg: 0,
         selection: { _ in .display }, fit: .crop, scrollInspectorToEnd: true, prepare: { $0.display.phaseWeighted = true }),
    // A prism refracting a Gaussian beam (FEM), with the prism selected: material and shape.
    Shot(file: "04-prism-material", example: "prism", method: .fem, quantity: .intensity, colormap: .viridis,
         selection: { m in m.scene.elements.first.map { .element($0.id) } ?? .source }),
    // A Talbot carpet (FDTD) at a square output, about the canvas's own shape: the
    // grating's self-images repeat down the whole frame, so the export fills it.
    Shot(file: "05-export", example: "talbot", method: .fdtd, quantity: .intensity, colormap: .asympton,
         selection: { _ in .output }, fit: .aspect(.r1x1)),
]

/// Window size in points, captured at 2x: exactly the 2880 x 1800 App Store size.
let windowSize = CGSize(width: 1440, height: 900)
/// The unified toolbar's height, which the panes scroll under.
let toolbarHeight: CGFloat = 52

/// The inspector's scroll view: the rightmost SwiftUI scroll view.
@MainActor func inspectorScrollView(_ root: NSView) -> NSScrollView? {
    findViews(root) { typeName($0) == "HostingScrollView" }
        .max { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX } as? NSScrollView
}

// MARK: - Entry

@main
enum Screenshots {
    static func main() {
        // Positional arguments come before the first option (the -Apple... defaults).
        let args = Array(CommandLine.arguments.prefix { !$0.hasPrefix("-") })
        guard args.count >= 2 else {
            FileHandle.standardError.write("usage: fringe-screenshots OUT_DIR [ONLY_PREFIX]\n".data(using: .utf8)!)
            exit(2)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // AppState restores and saves a document in the standard defaults; start clean.
        UserDefaults.standard.removeObject(forKey: AppState.documentKey)
        MainActor.assumeIsolated {
            Task {
                var failed = false
                for shot in shots where args.count < 3 || shot.file.hasPrefix(args[2]) {
                    do { try await render(shot, out: args[1]) } catch {
                        print("FAIL \(shot.file): \(error)"); failed = true
                    }
                }
                UserDefaults.standard.removeObject(forKey: AppState.documentKey)
                UserDefaults.standard.synchronize()
                exit(failed ? 1 : 0)
            }
        }
        RunLoop.main.run()
    }
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

@MainActor func render(_ shot: Shot, out: String) async throws {
    let model = AppState()
    guard let info = model.examples.first(where: { $0.name == shot.example }) else { throw ShotError(description: "no example \(shot.example)") }
    model.loadExample(info)
    // The example's domain; with the Window aspect its height follows the canvas.
    let original = model.scene.domain.rect
    model.edit("Prepare") { doc in
        doc.scene.solver.method = shot.method
        doc.display.quantity = shot.quantity
        doc.display.colormap = shot.colormap
        if let phase = shot.phaseDeg { doc.display.phaseDeg = phase }
        doc.display.showParaxialFocus = true
        if case .aspect(let aspect) = shot.fit { doc.output.aspect = aspect } else { doc.output.aspect = .window }
        shot.prepare(&doc)
    }
    model.selection = shot.selection(model)

    let host = NSHostingView(rootView: FringeWindow().environment(model))
    host.sceneBridgingOptions = [.toolbars, .title]
    let window = OffscreenKeyWindow(
        contentRect: NSRect(origin: .zero, size: windowSize),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .darkAqua)
    window.toolbarStyle = .unified
    window.title = "Fringe"
    window.contentView = host
    window.setContentSize(windowSize)
    // Never ordered front: the window lives offscreen and is only drawn into a bitmap.

    _ = await wait(10) { model.containerSize.width > 0 }
    try? await Task.sleep(for: .milliseconds(400))
    let canvas = model.containerSize
    let canvasAspect = Double(canvas.width / canvas.height)
    switch shot.fit {
    case .grow:
        model.edit("Fill Canvas") { doc in doc.scene.domain.set(doc.scene.domain.rect.grown(toAspect: canvasAspect)) }
    case .crop:
        model.edit("Fill Canvas") { doc in
            let r = original
            // Rounded to values a user would type: the width down to 0.1 µm, the centre to 0.05 µm.
            let width = (min(r.width, r.height * canvasAspect) * 10).rounded(.down) / 10, height = width / canvasAspect
            // Light runs along +x: keep the input side, where the source and the optics are.
            let centerX = ((r.xMin + width / 2) * 20).rounded() / 20, centerY = (((r.yMin + r.yMax) / 2) * 20).rounded() / 20
            doc.scene.domain.set(centerX: centerX, centerY: centerY, width: width, height: height)
        }
    case .aspect: break
    }
    try? await Task.sleep(for: .milliseconds(300))
    // Wait for the automatic preview to settle, then run the final solve.
    _ = await wait(120) { !model.solver.isRunning }
    model.runFinal()
    var lastLog = Date()
    let solved = await wait(900) {
        if Date().timeIntervalSince(lastLog) > 10 {
            lastLog = Date()
            print("  \(shot.file): \(model.solver.status.title) running=\(model.solver.isRunning) canFinal=\(model.solver.canRunFinal) domain=\(model.scene.domain.rect)")
        }
        if model.solver.status.title.contains("failed") { return true }
        guard let shown = model.solver.shown else { return false }
        return shown.quality == .final && !model.solver.isRunning && !model.solver.isShownStale
    }
    guard solved, model.solver.shown?.quality == .final, !model.solver.isShownStale else { throw ShotError(description: "final solve did not finish: \(model.solver.status.title)") }
    let rendered = await wait(60) { model.renderer.rendered?.field === model.solver.shown?.field }
    guard rendered else { throw ShotError(description: "render did not finish") }
    if shot.scrollInspectorToEnd, let sv = inspectorScrollView(host), let doc = sv.documentView, let docLayer = doc.layer,
       let root = host.window?.contentView?.superview?.layer {
        func leaves(_ l: CALayer) -> [CALayer] { (l.sublayers ?? []).flatMap { [$0] + leaves($0) } }
        // Text, controls and separators, in window coordinates at the current (top) scroll.
        let parts = leaves(docLayer).filter { !$0.isHidden && ($0.contents != nil || $0.backgroundColor != nil) }
            .map { root.convert($0.bounds, from: $0) }.filter { $0.height < 40 && $0.width < 300 }
        let clip = sv.contentView, origin = clip.bounds.origin
        doc.scrollToVisible(NSRect(x: 0, y: doc.isFlipped ? doc.bounds.maxY - 1 : 0, width: 1, height: 1))
        let maxScroll = Int(abs(clip.bounds.origin.y - origin.y).rounded(.down))
        let top = windowSize.height - toolbarHeight
        let scroll = stride(from: maxScroll, through: 0, by: -1).first { s in
            parts.allSatisfy { r in
                let r = r.offsetBy(dx: 0, dy: CGFloat(s)).insetBy(dx: 0, dy: -2)
                return !(r.minY < top && r.maxY > top) && !(r.minY < 0 && r.maxY > 0)
            }
        } ?? 0
        clip.scroll(to: NSPoint(x: origin.x, y: origin.y + CGFloat(doc.isFlipped ? scroll : -scroll)))
        sv.reflectScrolledClipView(clip)
        print("  \(shot.file): inspector scrolled \(scroll) of \(maxScroll) pt")
    }
    try? await Task.sleep(for: .seconds(1.5))
    print("\(shot.file): \(model.caption.map(MathTypesetter.plain) ?? "-") container=\(model.containerSize)")

    let windowImage = try captureWindow(window)
    try writePNG(try flatten(windowImage), to: "\(out)/\(shot.file).png")
    window.contentView = nil
    window.close()
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

    static func isVibrant(_ f: AnyObject) -> Bool { (f.value(forKey: "type") as? String)?.hasPrefix("vibrantColorMatrix") ?? false }

    static func matrix(_ f: AnyObject) -> [Float]? {
        guard let t = f.value(forKey: "type") as? String, t == "colorMatrix" || t.hasPrefix("vibrantColorMatrix"),
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
    static let backdrop: [CGFloat] = [0.16, 0.16, 0.17, 1]

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
    static let accent: [CGFloat] = [10 / 255, 132 / 255, 1, 1]
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
let windowBase = CGColor(srgbRed: 0.110, green: 0.110, blue: 0.118, alpha: 1)
let inspectorFill = CGColor(srgbRed: 0.137, green: 0.137, blue: 0.145, alpha: 1)
let platterSelected = CGColor(srgbRed: 0.36, green: 0.36, blue: 0.38, alpha: 1)
let rowSelected = CGColor(srgbRed: 0.27, green: 0.27, blue: 0.29, alpha: 1)

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
            drawLabel(k, in: box, color: NSColor(white: 0.62, alpha: 1))
        }
        ctx.setFillColor(platterSelected)
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil)); ctx.fillPath()
        drawLabel(i, in: pill, color: .white)
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
