import CBeamCore
import CoreGraphics
import Foundation

/// An error reported by the core: `{"code", "message", "issues"}`.
public struct BeamError: Error, LocalizedError, Decodable, Sendable {
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
    static func take(_ pointer: UnsafeMutablePointer<CChar>?) -> BeamError {
        guard let json = BeamBridge.takeString(pointer) else {
            return BeamError(code: "internal", message: "The core reported an error without details.")
        }
        return (try? BeamBridge.decode(BeamError.self, from: json))
            ?? BeamError(code: "internal", message: json)
    }
}

/// One entry of `beam_scene_example("")`.
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
                                  "as", "at", "by", "in", "of", "on", "to", "up", "via"]
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

/// Swift wrappers for the `beam_core` C interface. Scenes travel as JSON (schema
/// version 2) and come back as the typed models in `SimScene.swift` and `CheckReport.swift`.
public enum BeamBridge {
    /// The colormap tables are sRGB, so the raster and the exported PNG are tagged as such
    /// and look the same on a wide-gamut display as in the preview.
    public static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    public static var abiVersion: UInt32 { beam_abi_version() }

    public static var coreVersion: String { String(cString: beam_version()) }

    /// Copies a string returned by the core and frees it.
    static func takeString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { beam_string_free(pointer) }
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
        takeString(beam_scene_default()) ?? "{}"
    }

    /// The core's default scene: a biconvex lens focusing a Gaussian beam.
    public static func defaultScene() -> SimScene {
        (try? SimScene.decode(json: defaultSceneJSON())) ?? SimScene()
    }

    public static func exampleSceneJSON(_ name: String) -> String? {
        guard !name.isEmpty else { return nil }
        return takeString(beam_scene_example(name))
    }

    public static func example(_ name: String) -> SimScene? {
        exampleSceneJSON(name).flatMap { try? SimScene.decode(json: $0) }
    }

    public static func examples() -> [ExampleInfo] {
        guard let json = takeString(beam_scene_example("")) else { return [] }
        return (try? decode([ExampleInfo].self, from: json)) ?? []
    }

    // MARK: Checking

    /// The check report JSON (issues, estimates, derived values) for scene JSON.
    public static func checkJSON(_ sceneJSON: String) -> String {
        takeString(beam_scene_check(sceneJSON)) ?? #"{"ok":false,"issues":[]}"#
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
        check(json: scene.jsonString())
    }

    /// Body outlines and source placement for overlays, without solving.
    public static func outlinesJSON(_ sceneJSON: String) -> String {
        takeString(beam_scene_outlines(sceneJSON)) ?? "{}"
    }

    /// nil when the core cannot read the scene.
    public static func outlines(_ scene: SimScene) -> SceneOutlines? {
        try? decode(SceneOutlines.self, from: outlinesJSON(scene.jsonString()))
    }

    /// 256 RGBA8 entries for a colour legend; empty for an unknown name.
    public static func colormapLUT(_ name: String, wavelengthUm: Double) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 1024)
        let ok = out.withUnsafeMutableBufferPointer { buf in
            beam_colormap_lut(name, wavelengthUm, buf.baseAddress, buf.count)
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

    public init(sceneJSON: String, quality: SolveQuality) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard let job = beam_job_start(sceneJSON, quality.code, &error) else {
            throw BeamError.take(error)
        }
        self.job = job
    }

    deinit {
        beam_job_free(job)
    }

    public func poll() -> BeamProgress {
        var progress = BeamProgress()
        beam_job_poll(job, &progress)
        return progress
    }

    public var isRunning: Bool { poll().state == BEAM_JOB_RUNNING }

    public var isDone: Bool { poll().state == BEAM_JOB_DONE }

    public func cancel() {
        beam_job_cancel(job)
    }

    /// The field once the job is done; nil while it runs. Throws if the job failed or
    /// was cancelled.
    public func takeResult() throws -> FieldHandle? {
        let state = poll().state
        guard state != BEAM_JOB_RUNNING else { return nil }
        var error: UnsafeMutablePointer<CChar>?
        guard let field = beam_job_take_result(job, &error) else {
            throw BeamError.take(error)
        }
        return FieldHandle(field)
    }
}

/// A solved field. Immutable, so it can be sampled and rendered from any thread.
public final class FieldHandle: @unchecked Sendable {
    private let field: OpaquePointer

    /// Grid, scene context and diagnostics as JSON.
    public let infoJSON: String
    /// The same, decoded once.
    public let info: FieldInfo?

    init(_ field: OpaquePointer) {
        self.field = field
        infoJSON = BeamBridge.takeString(beam_field_info(field)) ?? "{}"
        info = try? BeamBridge.decode(FieldInfo.self, from: infoJSON)
    }

    deinit {
        beam_field_free(field)
    }

    /// Bicubic sample of a part at a point in µm; nil outside the grid.
    public func sample(x: Double, y: Double, part: FieldPart = .total) -> (re: Double, im: Double)? {
        var re = 0.0
        var im = 0.0
        guard beam_field_sample(field, x, y, part.code, &re, &im) else { return nil }
        return (re, im)
    }

    /// Renders a view into an sRGB image, row 0 at the top.
    public func render(viewJSON: String, width: Int, height: Int) throws -> CGImage {
        guard width > 0, height > 0,
              let uWidth = UInt32(exactly: width), let uHeight = UInt32(exactly: height) else {
            throw BeamError(code: "buffer", message: "Width and height must be positive.")
        }
        let (pixels, overflow0) = width.multipliedReportingOverflow(by: height)
        let (byteCount, overflow1) = pixels.multipliedReportingOverflow(by: 4)
        guard !overflow0, !overflow1 else {
            throw BeamError(code: "buffer", message: "The image is too large.")
        }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: byteCount)
        var error: UnsafeMutablePointer<CChar>?
        guard beam_field_render_rgba(field, viewJSON, uWidth, uHeight, buffer, byteCount, &error) else {
            buffer.deallocate()
            throw BeamError.take(error)
        }
        // The provider takes ownership of the buffer and frees it when released.
        guard let provider = CGDataProvider(
            dataInfo: nil,
            data: buffer,
            size: byteCount,
            releaseData: { _, data, _ in
                UnsafeMutableRawPointer(mutating: data).deallocate()
            }
        ) else {
            buffer.deallocate()
            throw BeamError(code: "internal", message: "Could not wrap the rendered pixels in an image.")
        }
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: BeamBridge.colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            throw BeamError(code: "internal", message: "Could not wrap the rendered pixels in an image.")
        }
        return image
    }

    public func exportPNG(viewJSON: String, width: Int, height: Int, to url: URL) throws {
        guard let uWidth = UInt32(exactly: width), let uHeight = UInt32(exactly: height) else {
            throw BeamError(code: "buffer", message: "Width and height must be positive.")
        }
        var error: UnsafeMutablePointer<CChar>?
        guard beam_field_export_png(field, viewJSON, uWidth, uHeight, url.path, &error) else {
            throw BeamError.take(error)
        }
    }

    /// complex128 .npy of one part, plus a `<path>.json` grid sidecar.
    public func exportNPY(part: FieldPart, to url: URL) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard beam_field_export_npy(field, part.code, url.path, &error) else {
            throw BeamError.take(error)
        }
    }
}
