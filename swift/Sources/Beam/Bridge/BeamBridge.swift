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

    enum CodingKeys: String, CodingKey {
        case name
        case title
        case method
        case quantity
        case colormap
    }
}

public enum SolveQuality: UInt32, Sendable {
    case preview = 0
    case final = 1
}

public enum FieldPart: UInt32, Sendable {
    case total = 0
    case scattered = 1
    case incident = 2
}

/// Swift wrappers for the `beam_core` C interface. Scenes travel as JSON strings
/// (schema version 2); typed scene models build on top of these.
public enum BeamBridge {
    /// The colormap tables are sRGB, so the raster and the exported PNG are tagged as such
    /// and look the same on a wide-gamut display as in the preview.
    public static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    public static var abiVersion: UInt32 { beam_abi_version() }

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
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    public static func defaultSceneJSON() -> String {
        takeString(beam_scene_default()) ?? "{}"
    }

    public static func exampleSceneJSON(_ name: String) -> String? {
        guard !name.isEmpty else { return nil }
        return takeString(beam_scene_example(name))
    }

    public static func examples() -> [ExampleInfo] {
        guard let json = takeString(beam_scene_example("")) else { return [] }
        return (try? decode([ExampleInfo].self, from: json)) ?? []
    }

    /// The check report JSON (issues, estimates, derived values) for a scene.
    public static func checkJSON(_ sceneJSON: String) -> String {
        takeString(beam_scene_check(sceneJSON)) ?? #"{"ok":false,"issues":[]}"#
    }

    /// Body outlines and source placement for overlays, without solving.
    public static func outlinesJSON(_ sceneJSON: String) -> String {
        takeString(beam_scene_outlines(sceneJSON)) ?? "{}"
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

    public init(sceneJSON: String, quality: SolveQuality) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard let job = beam_job_start(sceneJSON, quality.rawValue, &error) else {
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

    init(_ field: OpaquePointer) {
        self.field = field
        infoJSON = BeamBridge.takeString(beam_field_info(field)) ?? "{}"
    }

    deinit {
        beam_field_free(field)
    }

    /// Bicubic sample of a part at a point in µm; nil outside the grid.
    public func sample(x: Double, y: Double, part: FieldPart = .total) -> (re: Double, im: Double)? {
        var re = 0.0
        var im = 0.0
        guard beam_field_sample(field, x, y, part.rawValue, &re, &im) else { return nil }
        return (re, im)
    }

    /// Renders a view (spec §3.6 JSON) into an sRGB image, row 0 at the top.
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
        // The image takes ownership of the buffer and frees it when released.
        guard let provider = CGDataProvider(
            dataInfo: nil,
            data: buffer,
            size: byteCount,
            releaseData: { _, data, _ in
                UnsafeMutableRawPointer(mutating: data).deallocate()
            }
        ), let image = CGImage(
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
        guard beam_field_export_npy(field, part.rawValue, url.path, &error) else {
            throw BeamError.take(error)
        }
    }
}
