import CFringeCore
import CoreGraphics
import Foundation

/// An error reported by the core: `{"code", "message", "issues"}`.
public struct FringeError: Error, LocalizedError, Decodable, Sendable {
    public struct Issue: Decodable, Sendable {
        public var path: String
        public var code: String
        public var severity: String
        public var message: String
    }

    public var code: String
    public var message: String
    public var issues: [Issue]

    enum CodingKeys: String, CodingKey {
        case code
        case message
        case issues
    }

    public init(code: String, message: String, issues: [Issue] = []) {
        self.code = code
        self.message = message
        self.issues = issues
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decode(String.self, forKey: .code)
        message = try c.decode(String.self, forKey: .message)
        issues = try c.decodeIfPresent([Issue].self, forKey: .issues) ?? []
    }

    public var errorDescription: String? { message }

    /// Decodes the error JSON in `pointer` and frees it.
    static func take(_ pointer: UnsafeMutablePointer<CChar>?) -> FringeError {
        guard let json = FringeBridge.takeString(pointer) else {
            return FringeError(code: "internal", message: "The core reported an error without details.")
        }
        return (try? FringeBridge.decode(FringeError.self, from: json))
            ?? FringeError(code: "internal", message: json)
    }
}

/// One entry of `fringe_scene_example("")`.
public struct ExampleInfo: Decodable, Hashable, Sendable {
    public var name: String
    public var title: String
    public var method: String
    public var quantity: String?
    public var colormap: String?

    public var solver: SolverMethod? { SolverMethod(rawValue: method) }

    /// The title in title case for a menu: "Young's Double Slit".
    public var menuTitle: String { Self.titleCased(title) }

    /// macOS title case: every word capitalised except articles, coordinating conjunctions
    /// and prepositions of three letters or fewer, unless first or last. Words that already
    /// contain capitals (PEC, Talbot) are left alone.
    static func titleCased(_ text: String) -> String {
        let minor: Set<String> = ["a", "an", "the", "and", "but", "or", "nor", "for", "so", "yet",
                                  "as", "at", "by", "in", "of", "on", "to", "up", "via", "with", "into", "from"]
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        return words.enumerated().map { index, word in
            let isEdge = index == 0 || index == words.count - 1
            if word.contains(where: \.isUppercase) || (!isEdge && minor.contains(word)) { return word }
            return word.split(separator: "-", omittingEmptySubsequences: false)
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: "-")
        }.joined(separator: " ")
    }

    enum CodingKeys: String, CodingKey {
        case name
        case title
        case method
        case quantity
        case colormap
    }
}

public typealias SolveQuality = QualityName
public typealias FieldPart = FieldPartName

/// Swift wrappers for the `fringe_core` C interface. Scenes travel as JSON (schema
/// version 3) and come back as the typed models in `SimScene.swift` and `CheckReport.swift`.
public enum FringeBridge {
    /// The colormap tables are sRGB, so the raster and the exported PNG are tagged as such
    /// and look the same on a wide-gamut display as in the preview.
    public static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    public static var abiVersion: UInt32 { fringe_abi_version() }

    public static var coreVersion: String { String(cString: fringe_version()) }

    /// Copies a string returned by the core and frees it.
    static func takeString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { fringe_string_free(pointer) }
        return String(cString: pointer)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    public static func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try SimScene.jsonEncoder.encode(value), as: UTF8.self)
    }

    // MARK: Scenes

    public static func defaultSceneJSON() -> String {
        takeString(fringe_scene_default()) ?? "{}"
    }

    /// The core's default scene: a biconvex lens focusing a Gaussian beam.
    public static func defaultScene() -> SimScene {
        (try? SimScene.decode(json: defaultSceneJSON())) ?? SimScene()
    }

    public static func exampleSceneJSON(_ name: String) -> String? {
        guard !name.isEmpty else { return nil }
        return takeString(fringe_scene_example(name))
    }

    public static func example(_ name: String) -> SimScene? {
        exampleSceneJSON(name).flatMap { try? SimScene.decode(json: $0) }
    }

    public static func examples() -> [ExampleInfo] {
        guard let json = takeString(fringe_scene_example("")) else { return [] }
        return (try? decode([ExampleInfo].self, from: json)) ?? []
    }

    // MARK: Checking

    /// The check report JSON (issues, estimates, derived values) for scene JSON.
    public static func checkJSON(_ sceneJSON: String) -> String {
        takeString(fringe_scene_check(sceneJSON)) ?? #"{"ok":false,"issues":[]}"#
    }

    /// Issues, cost estimates for both qualities and derived quantities. Never throws: a
    /// scene the core cannot read comes back as a report with one `parse` issue.
    public static func check(json sceneJSON: String) -> CheckReport {
        let json = checkJSON(sceneJSON)
        do {
            return try decode(CheckReport.self, from: json)
        } catch {
            return CheckReport(ok: false, issues: [
                Issue(path: "", code: "internal", severity: .error, message: "could not read the check report: \(error)")
            ])
        }
    }

    public static func check(_ scene: SimScene) -> CheckReport {
        PerfProbe.time("core.check") { check(json: scene.jsonString()) }
    }

    /// Body outlines and source placement for overlays, without solving.
    public static func outlinesJSON(_ sceneJSON: String) -> String {
        takeString(fringe_scene_outlines(sceneJSON)) ?? "{}"
    }

    /// nil when the core cannot read the scene.
    public static func outlines(_ scene: SimScene) -> SceneOutlines? {
        PerfProbe.time("core.outlines") { try? decode(SceneOutlines.self, from: outlinesJSON(scene.jsonString())) }
    }

    // MARK: Materials

    /// The core's Lorentz–Drude presets (metals and glasses); empty if the core sends
    /// nothing readable.
    public static func materialLibrary() -> [MaterialLibraryEntry] {
        (try? decode([MaterialLibraryEntry].self, from: materialLibraryJSON())) ?? []
    }

    /// The preset library as the core sends it.
    public static func materialLibraryJSON() -> String {
        takeString(fringe_material_presets()) ?? "[]"
    }

    private struct EvaluateRequest: Encodable {
        var material: Material
        var wavelengthsUm: [Double]

        enum CodingKeys: String, CodingKey {
            case material
            case wavelengthsUm = "wavelengths_um"
        }
    }

    private struct EvaluateResponse: Decodable {
        var n: [Double?]
        var k: [Double?]
        var eps1: [Double?]
        var eps2: [Double?]
    }

    /// n + ik and ε1 + iε2 of `material` at each wavelength (optics convention, k ≥ 0
    /// absorbs); nil for PEC or when the core cannot evaluate it.
    public static func evaluate(_ material: Material, wavelengthsUm: [Double]) -> [EffectiveIndex]? {
        guard !material.isPEC, !wavelengthsUm.isEmpty,
              let request = try? encode(EvaluateRequest(material: material, wavelengthsUm: wavelengthsUm)),
              let json = takeString(fringe_material_evaluate(request)),
              let response = try? decode(EvaluateResponse.self, from: json),
              response.n.count == wavelengthsUm.count, response.k.count == wavelengthsUm.count,
              response.eps1.count == wavelengthsUm.count, response.eps2.count == wavelengthsUm.count else {
            return nil
        }
        var values: [EffectiveIndex] = []
        values.reserveCapacity(wavelengthsUm.count)
        // A sample the core cannot evaluate (one landing exactly on a lossless pole) is NaN,
        // a gap in the curve; only a model with no value anywhere fails.
        for i in wavelengthsUm.indices {
            values.append(EffectiveIndex(n: response.n[i] ?? .nan, k: response.k[i] ?? .nan,
                                         eps1: response.eps1[i] ?? .nan, eps2: response.eps2[i] ?? .nan))
        }
        guard values.contains(where: { $0.n.isFinite && $0.k.isFinite }) else { return nil }
        return values
    }

    /// n and k at `count` wavelengths evenly spread over `range` (µm), and the value at
    /// `lambda0`, for the material chart. Built on `fringe_material_evaluate`; one call.
    public static func materialCurve(_ material: Material, range: ClosedRange<Double>, count: Int, lambda0: Double) -> MaterialCurve? {
        guard count >= 2, range.lowerBound > 0 else { return nil }
        let step = (range.upperBound - range.lowerBound) / Double(count - 1)
        let wavelengths = (0..<count).map { range.lowerBound + Double($0) * step }
        guard let values = evaluate(material, wavelengthsUm: wavelengths + [lambda0]) else { return nil }
        let curve = values.dropLast()
        return MaterialCurve(
            wavelengthUm: wavelengths,
            n: curve.map(\.n),
            k: curve.map(\.k),
            eps1: curve.map(\.eps1),
            eps2: curve.map(\.eps2),
            at: values.last.flatMap { [$0.n, $0.k, $0.eps1, $0.eps2].allSatisfy(\.isFinite) ? $0 : nil }
        )
    }

    /// 256 RGBA8 entries for a colour legend; empty for an unknown name.
    public static func colormapLUT(_ name: String, wavelengthUm: Double) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 1024)
        let ok = out.withUnsafeMutableBufferPointer { buf in
            fringe_colormap_lut(name, wavelengthUm, buf.baseAddress, buf.count)
        }
        return ok ? out : []
    }
}

/// One solve on a background thread. Poll it; take the result once it is done.
public final class JobHandle: @unchecked Sendable {
    private let job: OpaquePointer

    public convenience init(scene: SimScene, quality: SolveQuality) throws {
        try self.init(sceneJSON: scene.jsonString(), quality: quality)
    }

    public convenience init(sceneJSON: String, quality: SolveQuality) throws {
        try self.init(sceneJSON: sceneJSON, code: quality.code)
    }

    /// A preview while a drag is in progress: at most 1 M FDTD cells (core quality 2).
    public convenience init(trackingScene scene: SimScene) throws {
        try self.init(sceneJSON: scene.jsonString(), code: 2)
    }

    private init(sceneJSON: String, code: UInt32) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard let job = fringe_job_start(sceneJSON, code, &error) else {
            throw FringeError.take(error)
        }
        self.job = job
    }

    deinit {
        fringe_job_free(job)
    }

    public func poll() -> FringeProgress {
        var progress = FringeProgress()
        fringe_job_poll(job, &progress)
        return progress
    }

    public var isRunning: Bool { poll().state == FRINGE_JOB_RUNNING }

    public var isDone: Bool { poll().state == FRINGE_JOB_DONE }

    public func cancel() {
        fringe_job_cancel(job)
    }

    /// The field once the job is done; nil while it runs. Throws if the job failed or
    /// was cancelled.
    public func takeResult() throws -> FieldHandle? {
        let state = poll().state
        guard state != FRINGE_JOB_RUNNING else { return nil }
        var error: UnsafeMutablePointer<CChar>?
        guard let field = fringe_job_take_result(job, &error) else {
            throw FringeError.take(error)
        }
        return FieldHandle(field)
    }
}

/// A solved field. Immutable, so it can be sampled and rendered from any thread.
public final class FieldHandle: @unchecked Sendable {
    let field: OpaquePointer

    /// Grid, scene context and diagnostics as JSON.
    public let infoJSON: String
    /// The same, decoded once.
    public let info: FieldInfo?

    init(_ field: OpaquePointer) {
        self.field = field
        infoJSON = FringeBridge.takeString(fringe_field_info(field)) ?? "{}"
        info = try? FringeBridge.decode(FieldInfo.self, from: infoJSON)
    }

    deinit {
        fringe_field_free(field)
    }

    /// Bicubic sample of a part at a point in µm; nil outside the grid.
    public func sample(x: Double, y: Double, part: FieldPart = .total) -> (re: Double, im: Double)? {
        var re = 0.0
        var im = 0.0
        PerfProbe.count("field.sample")
        guard fringe_field_sample(field, x, y, part.code, &re, &im) else { return nil }
        return (re, im)
    }

    /// Renders a view into an sRGB image, row 0 at the top.
    public func render(viewJSON: String, width: Int, height: Int) throws -> CGImage {
        guard width > 0, height > 0,
              let uWidth = UInt32(exactly: width), let uHeight = UInt32(exactly: height) else {
            throw FringeError(code: "buffer", message: "Width and height must be positive.")
        }
        let (pixels, overflow0) = width.multipliedReportingOverflow(by: height)
        let (byteCount, overflow1) = pixels.multipliedReportingOverflow(by: 4)
        guard !overflow0, !overflow1 else {
            throw FringeError(code: "buffer", message: "The image is too large.")
        }
        // Recycled: a released image hands its buffer back for the next render of the same
        // size, so playback does not allocate a new raster for every frame.
        let buffer = RasterPool.take(byteCount)
        var error: UnsafeMutablePointer<CChar>?
        PerfProbe.count("render.bytes", by: byteCount)
        let renderedOK = PerfProbe.time("render.rgba_core") { fringe_field_render_rgba(field, viewJSON, uWidth, uHeight, buffer, byteCount, &error) }
        guard renderedOK else {
            RasterPool.give(buffer, byteCount)
            throw FringeError.take(error)
        }
        let cgStart = DispatchTime.now().uptimeNanoseconds
        defer { if PerfProbe.enabled { PerfProbe.count("render.cgimage_ns", by: Int(DispatchTime.now().uptimeNanoseconds - cgStart)); PerfProbe.count("render.cgimage") } }
        // The provider takes ownership of the buffer and frees it when released.
        guard let provider = CGDataProvider(
            dataInfo: nil,
            data: buffer,
            size: byteCount,
            releaseData: { _, data, size in
                RasterPool.give(UnsafeMutableRawPointer(mutating: data).assumingMemoryBound(to: UInt8.self), size)
            }
        ) else {
            RasterPool.give(buffer, byteCount)
            throw FringeError(code: "internal", message: "Could not wrap the rendered pixels in an image.")
        }
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: FringeBridge.colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            throw FringeError(code: "internal", message: "Could not wrap the rendered pixels in an image.")
        }
        return image
    }

    public func exportPNG(viewJSON: String, width: Int, height: Int, to url: URL) throws {
        guard let uWidth = UInt32(exactly: width), let uHeight = UInt32(exactly: height) else {
            throw FringeError(code: "buffer", message: "Width and height must be positive.")
        }
        var error: UnsafeMutablePointer<CChar>?
        guard fringe_field_export_png(field, viewJSON, uWidth, uHeight, url.path, &error) else {
            throw FringeError.take(error)
        }
    }

    /// One part as a NumPy .npz (complex field, x and y node coordinates, run info),
    /// returned rather than written so the caller can save it where the sandbox allows.
    public func npzData(part: FieldPart) throws -> Data {
        var length = 0
        var error: UnsafeMutablePointer<CChar>?
        guard let bytes = fringe_field_npz(field, part.code, &length, &error) else {
            throw FringeError.take(error)
        }
        // Data takes ownership and hands the buffer back to Rust, which allocated it.
        return Data(bytesNoCopy: bytes, count: length, deallocator: .custom { pointer, count in
            fringe_bytes_free(pointer.assumingMemoryBound(to: UInt8.self), count)
        })
    }
}

/// Raster buffers handed back by released images, reused for the next render of the same
/// size. Holds at most `limit` buffers; any other size is freed.
enum RasterPool {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var free: [(pointer: UnsafeMutablePointer<UInt8>, size: Int)] = []
    private static let limit = 3

    static func take(_ size: Int) -> UnsafeMutablePointer<UInt8> {
        lock.lock()
        if let i = free.firstIndex(where: { $0.size == size }) {
            let p = free.remove(at: i).pointer
            lock.unlock()
            PerfProbe.count("render.poolHit")
            return p
        }
        lock.unlock()
        return UnsafeMutablePointer<UInt8>.allocate(capacity: size)
    }

    static func give(_ pointer: UnsafeMutablePointer<UInt8>, _ size: Int) {
        lock.lock()
        // Buffers of another size belong to an older canvas size: drop them.
        free.removeAll { old in
            if old.size != size { old.pointer.deallocate(); return true }
            return false
        }
        if free.count < limit {
            free.append((pointer, size))
            lock.unlock()
        } else {
            lock.unlock()
            pointer.deallocate()
        }
    }
}
