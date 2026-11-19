import CFringeCore
import CoreGraphics
import Foundation
import Metal
import os

/// Colours a solved field on the GPU: the field is uploaded once per (solve, part) as
/// float2 re/im, and each frame is one fragment pass that resamples it with the same
/// Catmull–Rom stencils as the core's `render_rgba` (computed here on the CPU in double
/// precision, so the outside mask is identical), applies the quantity and scale, and looks
/// the colour up in the core's own 1024-entry table. Phase, pan, zoom, quantity, colormap
/// and the stale and invalid looks are parameters; nothing is coloured on the CPU.
///
/// During playback only the phase changes, so the canvas resamples the field once into a
/// float2 texture at the drawable's size (`resample`) and each frame only colours it
/// (`encode(..., resampled:)`): one texture read per pixel instead of sixteen buffer reads.
/// Both paths run the same resampling and colouring code, so they give the same pixels.
///
/// The shader is compiled at run time from source (the Command Line Tools have no offline
/// Metal compiler). `FieldGPU.shared` is nil when there is no Metal device or the shader
/// does not compile; the canvas then uses the CPU renderer.
@MainActor
final class FieldGPU {
    nonisolated private static let log = Logger(subsystem: "com.asympton.fringe", category: "gpu")

    let device: MTLDevice
    let queue: MTLCommandQueue
    private(set) var pipeline: MTLRenderPipelineState?
    private var offscreenPipeline: MTLRenderPipelineState?
    private var resamplePipeline: MTLRenderPipelineState?
    private var colourPipeline: MTLRenderPipelineState?
    private var offscreenColourPipeline: MTLRenderPipelineState?
    /// Reused for every pass: only the target changes.
    private let pass: MTLRenderPassDescriptor = {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        return pass
    }()
    private(set) var compileFailed = false
    private var waiters: [() -> Void] = []

    /// One shared instance; compilation starts on first use.
    static let shared: FieldGPU? = {
        guard ViewportMode.current == .gpu, let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        return FieldGPU(device: device, queue: queue)
    }()

    private init(device: MTLDevice, queue: MTLCommandQueue) {
        self.device = device
        self.queue = queue
        compile()
    }

    var isReady: Bool { pipeline != nil }

    /// Runs `body` once the shader is compiled (at once if it is), never if it failed.
    func whenReady(_ body: @escaping () -> Void) {
        if pipeline != nil { body() } else if !compileFailed { waiters.append(body) }
    }

    private var failureHandlers: [() -> Void] = []

    /// Runs `body` if the shader fails to compile (at once if it has).
    func whenFailed(_ body: @escaping () -> Void) {
        if compileFailed { body() } else if pipeline == nil { failureHandlers.append(body) }
    }

    private func compile() {
        let options = MTLCompileOptions()
        options.languageVersion = .version3_1
        options.mathMode = .safe
        let start = ContinuousClock.now
        device.makeLibrary(source: FieldShader.source, options: options) { [weak self] library, error in
            let elapsed = ContinuousClock.now - start
            DispatchQueue.main.async {
                guard let self else { return }
                MainActor.assumeIsolated {
                    guard let library, error == nil || library.makeFunction(name: "field_fs") != nil else {
                        Self.log.error("Field shader failed to compile: \(error?.localizedDescription ?? "-", privacy: .public)")
                        self.compileFailed = true
                        self.waiters = []
                        let failed = self.failureHandlers
                        self.failureHandlers = []
                        failed.forEach { $0() }
                        return
                    }
                    do {
                        self.pipeline = try self.makePipeline(library, "field_fs", format: .bgra8Unorm)
                        self.offscreenPipeline = try self.makePipeline(library, "field_fs", format: .rgba8Unorm)
                        self.resamplePipeline = try self.makePipeline(library, "field_resample_fs", format: .rg32Float)
                        self.colourPipeline = try self.makePipeline(library, "field_colour_fs", format: .bgra8Unorm)
                        self.offscreenColourPipeline = try self.makePipeline(library, "field_colour_fs", format: .rgba8Unorm)
                        Self.log.debug("Field shader ready in \(elapsed)")
                        PerfProbe.count("gpu.compile_ns", by: Int(elapsed.components.attoseconds / 1_000_000_000) + Int(elapsed.components.seconds) * 1_000_000_000)
                    } catch {
                        Self.log.error("Field pipeline failed: \(error.localizedDescription, privacy: .public)")
                        self.compileFailed = true
                        let failed = self.failureHandlers
                        self.failureHandlers = []
                        failed.forEach { $0() }
                    }
                    self.failureHandlers = []
                    let waiting = self.waiters
                    self.waiters = []
                    if self.pipeline != nil { waiting.forEach { $0() } }
                }
            }
        }
    }

    private func makePipeline(_ library: MTLLibrary, _ fragment: String, format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "field_vs")
        d.fragmentFunction = library.makeFunction(name: fragment)
        d.colorAttachments[0].pixelFormat = format
        return try device.makeRenderPipelineState(descriptor: d)
    }

    // MARK: Field buffers

    /// The uploaded parts, most recently used last; at most `maxParts` stay.
    private var parts: [FieldPartBuffer] = []
    private var loading: Set<PartKey> = []
    private static let maxParts = 2

    struct PartKey: Hashable {
        var field: ObjectIdentifier
        var part: FieldPartName
    }

    /// The uploaded part of `field`, or nil while it uploads; `ready` runs on the main
    /// thread when it has.
    func buffer(for field: FieldHandle, part: FieldPartName, ready: @escaping () -> Void) -> FieldPartBuffer? {
        let key = PartKey(field: ObjectIdentifier(field), part: part)
        if let i = parts.firstIndex(where: { $0.key == key && $0.field === field }) {
            let hit = parts.remove(at: i)
            parts.append(hit)
            return hit
        }
        guard !loading.contains(key) else { return nil }
        loading.insert(key)
        let device = self.device
        DispatchQueue.global(qos: .userInitiated).async {
            let made = FieldPartBuffer.make(device: device, field: field, part: part, key: key)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.loading.remove(key)
                    guard let made else { return }
                    self.parts.removeAll { $0.key == key }
                    self.parts.append(made)
                    // Least recently used goes first.
                    while self.parts.count > Self.maxParts { self.parts.removeFirst() }
                    ready()
                }
            }
        }
        return nil
    }

    // MARK: Colour tables

    private var luts: [String: MTLTexture] = [:]

    func lut(_ colormap: ColormapName, wavelengthUm: Double) -> MTLTexture? {
        let key = "\(colormap.rawValue)@\(wavelengthUm)"
        if let hit = luts[key] { return hit }
        var bytes = [UInt8](repeating: 0, count: 4 * FieldShader.lutSize)
        let ok = bytes.withUnsafeMutableBufferPointer {
            fringe_colormap_lut_n(colormap.rawValue, wavelengthUm, UInt32(FieldShader.lutSize), $0.baseAddress, $0.count)
        }
        guard ok else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: FieldShader.lutSize, height: 1, mipmapped: false)
        d.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, FieldShader.lutSize, 1), mipmapLevel: 0, withBytes: bytes, bytesPerRow: 4 * FieldShader.lutSize)
        if luts.count > 24 { luts.removeAll() }
        luts[key] = tex
        return tex
    }

    // MARK: Drawing

    /// Encodes one frame of `frame` into `target` (a drawable's or an offscreen texture):
    /// in one pass, or, with `resampled` (from `resample`, for the same part and
    /// stencils), only the colouring.
    func encode(_ frame: FieldFrame, into commandBuffer: MTLCommandBuffer, target: MTLTexture, offscreen: Bool = false,
                resampled: FieldResampled? = nil) -> Bool {
        let state = resampled == nil ? (offscreen ? offscreenPipeline : pipeline) : (offscreen ? offscreenColourPipeline : colourPipeline)
        guard let state else { return false }
        if let resampled, !resampled.matches(frame) { return false }
        pass.colorAttachments[0].texture = target
        defer { pass.colorAttachments[0].texture = nil }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.setRenderPipelineState(state)
        var uniforms = frame.uniforms
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FieldUniforms>.stride, index: 0)
        if let resampled {
            encoder.setFragmentTexture(resampled.texture, index: 1)
        } else {
            encoder.setFragmentBuffer(frame.part.buffer, offset: 0, index: 1)
        }
        encoder.setFragmentBuffer(frame.stencils.columns, offset: 0, index: 2)
        encoder.setFragmentBuffer(frame.stencils.rows, offset: 0, index: 3)
        encoder.setFragmentTexture(frame.lut, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }

    /// The field of `frame` resampled at its pixel size (float2 per pixel, before scaling),
    /// encoded into `commandBuffer`; nil if the texture cannot be made.
    func resample(_ frame: FieldFrame, into commandBuffer: MTLCommandBuffer) -> FieldResampled? {
        guard let resamplePipeline else { return nil }
        let w = frame.stencils.width, h = frame.stencils.height
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg32Float, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        guard let texture = device.makeTexture(descriptor: d) else { return nil }
        pass.colorAttachments[0].texture = texture
        defer { pass.colorAttachments[0].texture = nil }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.setRenderPipelineState(resamplePipeline)
        var uniforms = frame.uniforms
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FieldUniforms>.stride, index: 0)
        encoder.setFragmentBuffer(frame.part.buffer, offset: 0, index: 1)
        encoder.setFragmentBuffer(frame.stencils.columns, offset: 0, index: 2)
        encoder.setFragmentBuffer(frame.stencils.rows, offset: 0, index: 3)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        PerfProbe.count("viewport.resample")
        return FieldResampled(texture: texture, part: frame.part, stencils: frame.stencils)
    }

    /// The frame drawn into a new image, for the offscreen harnesses and the parity test.
    /// Same shader, stencils and uniforms as on screen.
    func renderImage(_ frame: FieldFrame) -> CGImage? {
        let w = frame.stencils.width, h = frame.stencils.height
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let target = device.makeTexture(descriptor: d), let cb = queue.makeCommandBuffer(),
              encode(frame, into: cb, target: target, offscreen: true) else { return nil }
        cb.commit()
        cb.waitUntilCompleted()
        let bytesPerRow = 4 * w
        let data = NSMutableData(length: bytesPerRow * h)!
        target.getBytes(data.mutableBytes, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: FringeBridge.colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// RGBA8 bytes of a frame as the shader writes them (premultiplied), row 0 at the top,
    /// for the parity test; with `twoStage`, through the playback path (resample, then
    /// colour).
    func renderBytes(_ frame: FieldFrame, twoStage: Bool = false) -> [UInt8]? {
        let w = frame.stencils.width, h = frame.stencils.height
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let target = device.makeTexture(descriptor: d), let cb = queue.makeCommandBuffer() else { return nil }
        let resampled = twoStage ? resample(frame, into: cb) : nil
        if twoStage, resampled == nil { return nil }
        guard encode(frame, into: cb, target: target, offscreen: true, resampled: resampled) else { return nil }
        cb.commit()
        cb.waitUntilCompleted()
        var out = [UInt8](repeating: 0, count: 4 * w * h)
        out.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: 4 * w, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0) }
        return out
    }

    // MARK: Frames

    /// Everything one draw needs, for a field, a view and a pixel size.
    func frame(field: FieldHandle, part: FieldPartBuffer, display: DisplaySettings, phaseDeg: Double, viewRect: RectUm,
               width: Int, height: Int, incidentAmplitude: Double, stencils cached: FieldStencils?, scale: Double,
               desaturate: Bool, opacity: Float, colormap: ColormapName? = nil) -> FieldFrame? {
        guard width > 0, height > 0, let lut = lut(colormap ?? display.colormap, wavelengthUm: part.wavelengthUm) else { return nil }
        let stencils: FieldStencils
        if let cached, cached.matches(grid: part.grid, viewRect: viewRect, width: width, height: height) {
            stencils = cached
        } else {
            guard let made = FieldStencils(device: device, grid: part.grid, viewRect: viewRect, width: width, height: height) else { return nil }
            stencils = made
        }
        let uniforms = FieldUniforms(display: display, phaseDeg: phaseDeg, scale: scale, grid: part.grid, width: width,
                                     desaturate: desaturate, opacity: opacity)
        return FieldFrame(part: part, stencils: stencils, lut: lut, uniforms: uniforms)
    }
}

/// How the canvas colours the field: on the GPU (the default) or with the core's CPU
/// renderer. `--viewport cpu` or `-FringeViewport cpu` picks the CPU path.
enum ViewportMode: String {
    case gpu
    case cpu

    nonisolated(unsafe) static var override: ViewportMode?

    static var current: ViewportMode {
        if let override { return override }
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--viewport"), i + 1 < args.count, let mode = ViewportMode(rawValue: args[i + 1]) { return mode }
        if let text = UserDefaults.standard.string(forKey: "FringeViewport"), let mode = ViewportMode(rawValue: text) { return mode }
        return .gpu
    }
}

/// One uploaded part of a field: float2 per node in shared memory.
final class FieldPartBuffer: @unchecked Sendable {
    let key: FieldGPU.PartKey
    weak var field: FieldHandle?
    let buffer: MTLBuffer
    let grid: FieldGrid2D
    let wavelengthUm: Double

    private init(key: FieldGPU.PartKey, field: FieldHandle, buffer: MTLBuffer, grid: FieldGrid2D, wavelengthUm: Double) {
        self.key = key
        self.field = field
        self.buffer = buffer
        self.grid = grid
        self.wavelengthUm = wavelengthUm
    }

    static func make(device: MTLDevice, field: FieldHandle, part: FieldPartName, key: FieldGPU.PartKey) -> FieldPartBuffer? {
        guard let grid = field.grid, grid.nx >= 2, grid.ny >= 2 else { return nil }
        let floats = grid.nx * grid.ny * 2
        let start = DispatchTime.now().uptimeNanoseconds
        guard let buffer = device.makeBuffer(length: floats * MemoryLayout<Float>.stride, options: .storageModeShared) else { return nil }
        let ok = fringe_field_part_f32(field.field, part.code, buffer.contents().assumingMemoryBound(to: Float.self), floats, nil)
        guard ok else { return nil }
        PerfProbe.count("viewport.upload")
        PerfProbe.count("viewport.upload_ns", by: Int(DispatchTime.now().uptimeNanoseconds - start))
        PerfProbe.count("viewport.upload_bytes", by: floats * 4)
        return FieldPartBuffer(key: key, field: field, buffer: buffer, grid: grid, wavelengthUm: field.wavelengthUm)
    }
}

/// A field's node grid: node (i, j) at (x0 + i dx, y0 + j dx).
struct FieldGrid2D: Equatable, Sendable {
    var nx: Int
    var ny: Int
    var x0: Double
    var y0: Double
    var dx: Double
}

extension FieldHandle {
    var grid: FieldGrid2D? {
        var nx: UInt32 = 0, ny: UInt32 = 0, x0 = 0.0, y0 = 0.0, dx = 0.0
        guard fringe_field_grid(field, &nx, &ny, &x0, &y0, &dx) else { return nil }
        return FieldGrid2D(nx: Int(nx), ny: Int(ny), x0: x0, y0: y0, dx: dx)
    }

    var wavelengthUm: Double { info?.wavelengthUm ?? 1 }

    /// The colour scale the core's renderer uses for this view JSON.
    func colourScale(viewJSON: String) -> Double {
        fringe_field_scale(field, viewJSON)
    }
}

/// Per-column and per-row Catmull–Rom stencils of a view, in the exact double-precision
/// arithmetic of `render_rgba` (src/render/view.rs), stored as {float4 w, int i0, int inside}.
final class FieldStencils {
    let columns: MTLBuffer
    let rows: MTLBuffer
    let grid: FieldGrid2D
    let viewRect: RectUm
    let width: Int
    let height: Int

    static let stride = 32
    static let edge = 1e-9

    init?(device: MTLDevice, grid: FieldGrid2D, viewRect: RectUm, width: Int, height: Int) {
        guard let columns = device.makeBuffer(length: max(1, width) * Self.stride, options: .storageModeShared),
              let rows = device.makeBuffer(length: max(1, height) * Self.stride, options: .storageModeShared) else { return nil }
        self.columns = columns
        self.rows = rows
        self.grid = grid
        self.viewRect = viewRect
        self.width = width
        self.height = height
        let px = (viewRect.xMax - viewRect.xMin) / Double(width)
        let py = (viewRect.yMax - viewRect.yMin) / Double(height)
        Self.fill(columns, count: width, n: grid.nx) { i in
            (grid: grid, f: (viewRect.xMin + (Double(i) + 0.5) * px - grid.x0) / grid.dx)
        }
        Self.fill(rows, count: height, n: grid.ny) { row in
            (grid: grid, f: (viewRect.yMax - (Double(row) + 0.5) * py - grid.y0) / grid.dx)
        }
        PerfProbe.count("viewport.stencils")
    }

    func matches(grid: FieldGrid2D, viewRect: RectUm, width: Int, height: Int) -> Bool {
        self.grid == grid && self.viewRect == viewRect && self.width == width && self.height == height
    }

    private static func fill(_ buffer: MTLBuffer, count: Int, n: Int, position: (Int) -> (grid: FieldGrid2D, f: Double)) {
        let p = buffer.contents()
        let last = Double(n - 1)
        for k in 0..<count {
            let base = p + k * stride
            let f = position(k).f
            guard f >= -edge && f <= last + edge else {
                base.storeBytes(of: SIMD4<Float>(0, 0, 0, 0), as: SIMD4<Float>.self)
                base.storeBytes(of: Int32(0), toByteOffset: 16, as: Int32.self)
                base.storeBytes(of: Int32(0), toByteOffset: 20, as: Int32.self)
                continue
            }
            let c = min(max(f, 0), last)
            let i0 = min(Int(c.rounded(.down)), max(n - 2, 0))
            let w = catmullRom(c - Double(i0))
            base.storeBytes(of: SIMD4<Float>(Float(w.0), Float(w.1), Float(w.2), Float(w.3)), as: SIMD4<Float>.self)
            base.storeBytes(of: Int32(i0), toByteOffset: 16, as: Int32.self)
            base.storeBytes(of: Int32(1), toByteOffset: 20, as: Int32.self)
        }
    }

    /// `catmull_rom` of src/solver/field.rs.
    static func catmullRom(_ t: Double) -> (Double, Double, Double, Double) {
        let t2 = t * t
        let t3 = t2 * t
        return (0.5 * (-t3 + 2.0 * t2 - t), 0.5 * (3.0 * t3 - 5.0 * t2 + 2.0), 0.5 * (-3.0 * t3 + 4.0 * t2 + t), 0.5 * (t3 - t2))
    }
}

/// The shader's uniforms; the layout matches `Uniforms` in `FieldShader.source`.
struct FieldUniforms {
    var nx: UInt32 = 0
    var ny: UInt32 = 0
    var quantity: UInt32 = 0
    var transfer: UInt32 = 0
    var invScale: Float = 1
    var cosp: Float = 1
    var sinp: Float = 0
    var gamma: Float = 1
    var factor: Float = 10
    var db: Float = 1
    var desaturate: Float = 0
    var opacity: Float = 1
    var weighted: UInt32 = 0
    var width: UInt32 = 0
    var height: UInt32 = 0
    var pad: UInt32 = 0

    init(display: DisplaySettings, phaseDeg: Double, scale: Double, grid: FieldGrid2D, width: Int, desaturate: Bool, opacity: Float) {
        nx = UInt32(grid.nx)
        ny = UInt32(grid.ny)
        switch display.quantity {
        case .intensity: quantity = 0
        case .magnitude: quantity = 1
        case .real: quantity = 2
        case .phase: quantity = 3
        }
        let g = display.gamma.isFinite && display.gamma > 0 ? display.gamma : 1
        gamma = Float(g)
        if display.usesLogScale, let db = display.logDb, db > 0 {
            transfer = 2
            factor = display.quantity == .intensity ? 10 : 20
            self.db = Float(db)
        } else {
            transfer = g == 1 ? 0 : 1
        }
        invScale = Float(1 / scale)
        let rot = Self.phaseFactor(phaseDeg)
        cosp = Float(rot.re)
        sinp = Float(rot.im)
        weighted = display.quantity == .phase && display.phaseWeighted ? 1 : 0
        self.width = UInt32(width)
        self.desaturate = desaturate ? 1 : 0
        self.opacity = opacity
    }

    /// `phase_factor` of src/render/view.rs: e^{jφ}, exact at multiples of 90°.
    static func phaseFactor(_ deg: Double) -> (re: Double, im: Double) {
        var d = deg.truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        let q = (d / 90).rounded(.down)
        let r = (d - 90 * q) * .pi / 180
        let s = sin(r), c = cos(r)
        switch Int(q) {
        case 0: return (c, s)
        case 1: return (-s, c)
        case 2: return (-c, -s)
        default: return (s, -c)
        }
    }
}

struct FieldFrame {
    var part: FieldPartBuffer
    var stencils: FieldStencils
    var lut: MTLTexture
    var uniforms: FieldUniforms
}

/// A field part resampled at one view and pixel size: what each playback frame colours.
final class FieldResampled {
    let texture: MTLTexture
    let part: FieldPartBuffer
    let stencils: FieldStencils

    init(texture: MTLTexture, part: FieldPartBuffer, stencils: FieldStencils) {
        self.texture = texture
        self.part = part
        self.stencils = stencils
    }

    func matches(_ frame: FieldFrame) -> Bool { frame.part === part && frame.stencils === stencils }
}

/// The invalid-scene look on the CPU, with the shader's formula: each pixel's colour mixed
/// to its Rec. 709 luma, computed on the sRGB-encoded values (premultiplied values give the
/// premultiplied result, since the mix is linear). The CPU fallback shows this image; the
/// parity test compares the shader against it.
enum FieldLook {
    static func desaturated(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 4 * w, space: FringeBridge.colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        desaturate(data.assumingMemoryBound(to: UInt8.self), count: w * h)
        return ctx.makeImage()
    }

    /// In place, on RGBA8 pixels.
    static func desaturate(_ p: UnsafeMutablePointer<UInt8>, count: Int) {
        for i in 0..<count {
            let k = 4 * i
            let luma = (0.2126 * Float(p[k]) + 0.7152 * Float(p[k + 1]) + 0.0722 * Float(p[k + 2])).rounded()
            let v = UInt8(min(255, max(0, luma)))
            p[k] = v
            p[k + 1] = v
            p[k + 2] = v
        }
    }
}

enum FieldShader {
    static let lutSize = 1024

    /// Line-for-line the colouring of `render_rgba` (src/render/view.rs).
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        uint nx, ny, quantity, transfer;
        float inv_scale, cosp, sinp, gamma;
        float factor, db, desaturate, opacity;
        uint weighted, width, height, pad;
    };

    struct Stencil {
        float4 w;
        int i0;
        int inside;
        int pad0;
        int pad1;
    };

    struct VSOut { float4 position [[position]]; };

    vertex VSOut field_vs(uint vid [[vertex_id]]) {
        // One triangle covering the target.
        float2 p = float2((vid << 1) & 2, vid & 2);
        VSOut o;
        o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        return o;
    }

    static inline float transfer_of(float v, constant Uniforms& u) {
        float t;
        if (u.transfer == 2) {
            t = v > 0.0f ? 1.0f + u.factor * log10(v) / u.db : 0.0f;
        } else if (u.transfer == 1) {
            t = powr(clamp(v, 0.0f, 1.0f), u.gamma);
        } else {
            t = clamp(v, 0.0f, 1.0f);
        }
        return clamp(t, 0.0f, 1.0f);
    }

    static inline float4 lut_at(float t, texture2d<float, access::read> lut) {
        uint i = isnan(t) ? 0u : min(uint(max(t, 0.0f) * 1024.0f), 1023u);
        return lut.read(uint2(i, 0));
    }

    // The field at one pixel: the 4x4 Catmull-Rom sum of the nodes around it.
    static inline float2 resample(Stencil c, Stencil r, constant Uniforms& u, const device float2* E) {
        int nx = int(u.nx), ny = int(u.ny);
        float2 e = float2(0.0);
        for (int b = 0; b < 4; b++) {
            int jr = clamp(r.i0 + b - 1, 0, ny - 1);
            float2 acc = float2(0.0);
            for (int a = 0; a < 4; a++) {
                int ic = clamp(c.i0 + a - 1, 0, nx - 1);
                acc += E[jr * nx + ic] * c.w[a];
            }
            e += acc * r.w[b];
        }
        return e;
    }

    // The colour of a pixel whose resampled field is e, premultiplied.
    static inline float4 colour(float2 e, constant Uniforms& u, texture2d<float, access::read> lut) {
        float2 en = e * u.inv_scale;
        float4 rgb;
        if (u.quantity == 0) {
            rgb = lut_at(transfer_of(dot(en, en), u), lut);
        } else if (u.quantity == 1) {
            rgb = lut_at(transfer_of(length(en), u), lut);
        } else if (u.quantity == 2) {
            float v = en.x * u.cosp - en.y * u.sinp;
            float m = min(abs(v), 1.0f);
            float g = u.gamma == 1.0f ? m : powr(m, u.gamma);
            rgb = lut_at(0.5f + 0.5f * copysign(g, v), lut);
        } else {
            float2 z = float2(e.x * u.cosp - e.y * u.sinp, e.x * u.sinp + e.y * u.cosp);
            rgb = lut_at((precise::atan2(z.y, z.x) + M_PI_F) / (2.0f * M_PI_F), lut);
            if (u.weighted != 0) {
                float2 zn = z * u.inv_scale;
                float bright = sqrt(min(length(zn), 1.0f));
                rgb.rgb = round(rgb.rgb * 255.0f * bright) / 255.0f;
            }
        }
        if (u.desaturate > 0.0f) {
            float luma = dot(rgb.rgb, float3(0.2126f, 0.7152f, 0.0722f));
            rgb.rgb = mix(rgb.rgb, float3(luma), u.desaturate);
        }
        return float4(rgb.rgb * u.opacity, u.opacity);
    }

    // One pass: resample and colour.
    fragment float4 field_fs(VSOut in [[stage_in]],
                             constant Uniforms& u [[buffer(0)]],
                             const device float2* E [[buffer(1)]],
                             const device Stencil* cols [[buffer(2)]],
                             const device Stencil* rows [[buffer(3)]],
                             texture2d<float, access::read> lut [[texture(0)]]) {
        uint2 p = uint2(in.position.xy);
        Stencil c = cols[p.x];
        Stencil r = rows[p.y];
        if (c.inside == 0 || r.inside == 0) return float4(0.0);
        return colour(resample(c, r, u, E), u, lut);
    }

    // Playback, once per view: the resampled field into an rg32Float target.
    fragment float4 field_resample_fs(VSOut in [[stage_in]],
                                      constant Uniforms& u [[buffer(0)]],
                                      const device float2* E [[buffer(1)]],
                                      const device Stencil* cols [[buffer(2)]],
                                      const device Stencil* rows [[buffer(3)]]) {
        uint2 p = uint2(in.position.xy);
        Stencil c = cols[p.x];
        Stencil r = rows[p.y];
        if (c.inside == 0 || r.inside == 0) return float4(0.0);
        return float4(resample(c, r, u, E), 0.0, 0.0);
    }

    // Playback, per frame: colour the resampled field.
    fragment float4 field_colour_fs(VSOut in [[stage_in]],
                                    constant Uniforms& u [[buffer(0)]],
                                    const device Stencil* cols [[buffer(2)]],
                                    const device Stencil* rows [[buffer(3)]],
                                    texture2d<float, access::read> lut [[texture(0)]],
                                    texture2d<float, access::read> field [[texture(1)]]) {
        uint2 p = uint2(in.position.xy);
        if (cols[p.x].inside == 0 || rows[p.y].inside == 0) return float4(0.0);
        return colour(field.read(p).xy, u, lut);
    }
    """
}
