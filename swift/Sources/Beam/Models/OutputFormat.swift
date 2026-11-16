import Foundation

public enum OutputAspect: String, CaseIterable, Identifiable, Sendable {
    case r16x9, r3x2, r4x3, r1x1, r4x5, r3x4, r9x16, window

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .r16x9: return "16:9"
        case .r3x2: return "3:2"
        case .r4x3: return "4:3"
        case .r1x1: return "1:1"
        case .r4x5: return "4:5"
        case .r3x4: return "3:4"
        case .r9x16: return "9:16"
        case .window: return "Window"
        }
    }

    /// Width over height, or nil when the image follows the window.
    public var ratio: Double? {
        switch self {
        case .r16x9: return 16.0 / 9.0
        case .r3x2: return 3.0 / 2.0
        case .r4x3: return 4.0 / 3.0
        case .r1x1: return 1.0
        case .r4x5: return 4.0 / 5.0
        case .r3x4: return 3.0 / 4.0
        case .r9x16: return 9.0 / 16.0
        case .window: return nil
        }
    }

    public var fileTag: String {
        self == .window ? "window" : title.replacingOccurrences(of: ":", with: "x")
    }

    /// The digit for ⌃⌘ in the View > Aspect ratio menu.
    public var shortcutDigit: Character {
        switch self {
        case .r16x9: return "1"
        case .r3x2: return "2"
        case .r4x3: return "3"
        case .r1x1: return "4"
        case .r4x5: return "5"
        case .r3x4: return "6"
        case .r9x16: return "7"
        case .window: return "0"
        }
    }
}

/// Pixel length of the image's long edge.
public enum LongEdge: Hashable, Sendable {
    case px1920, px3840, px5120, px7680
    case custom(Int)

    public static let presets: [LongEdge] = [.px1920, .px3840, .px5120, .px7680]
    public static let customRange: ClosedRange<Int> = 64...16384

    public var pixels: Int {
        switch self {
        case .px1920: return 1920
        case .px3840: return 3840
        case .px5120: return 5120
        case .px7680: return 7680
        case .custom(let pixels): return min(Self.customRange.upperBound, max(Self.customRange.lowerBound, pixels))
        }
    }

    public var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }
}

/// Aspect ratio and pixel size of the image. The preview frame and every export use it,
/// so what is exported always has the crop that is on screen.
public struct OutputFormat: Equatable, Sendable {
    public var aspect: OutputAspect = .r16x9
    public var longEdge: LongEdge = .px3840

    public init() {}

    /// Width and height in pixels. `windowAspect` is used for the Window aspect.
    public func pixelSize(windowAspect: Double) -> (width: Int, height: Int) {
        let ratio = aspect.ratio ?? (windowAspect.isFinite && windowAspect > 0 ? windowAspect : 16.0 / 9.0)
        let long = Double(longEdge.pixels)
        let width = ratio >= 1 ? long : (long * ratio).rounded()
        let height = ratio >= 1 ? (long / ratio).rounded() : long
        let limit = Double(LongEdge.customRange.upperBound)
        return (Int(min(limit, max(1, width))), Int(min(limit, max(1, height))))
    }

    public func summary(windowAspect: Double) -> String {
        let size = pixelSize(windowAspect: windowAspect)
        return "\(aspect.title) · \(size.width) × \(size.height)"
    }
}
