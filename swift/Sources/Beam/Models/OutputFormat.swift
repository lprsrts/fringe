import Foundation

public enum OutputAspect: Hashable, Sendable {
    case r16x9, r3x2, r4x3, r1x1, r4x5, r3x4, r9x16, window
    /// Any width:height ratio, e.g. 21:9 for a banner.
    case custom(width: Int, height: Int)

    public static let presets: [OutputAspect] = [.r16x9, .r3x2, .r4x3, .r1x1, .r4x5, .r3x4, .r9x16, .window]
    public static let customTermRange: ClosedRange<Int> = 1...999

    /// Width and height terms of the ratio, or nil when the image follows the window.
    public var terms: (width: Int, height: Int)? {
        switch self {
        case .r16x9: return (16, 9)
        case .r3x2: return (3, 2)
        case .r4x3: return (4, 3)
        case .r1x1: return (1, 1)
        case .r4x5: return (4, 5)
        case .r3x4: return (3, 4)
        case .r9x16: return (9, 16)
        case .window: return nil
        case .custom(let width, let height):
            let range = Self.customTermRange
            return (min(range.upperBound, max(range.lowerBound, width)),
                    min(range.upperBound, max(range.lowerBound, height)))
        }
    }

    public var title: String {
        guard let terms else { return "Window" }
        return "\(terms.width):\(terms.height)"
    }

    /// Width over height, or nil when the image follows the window.
    public var ratio: Double? {
        terms.map { Double($0.width) / Double($0.height) }
    }

    public var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }

    /// What picking "Custom" switches to: the current ratio, so the image doesn't jump.
    public var asCustom: OutputAspect {
        guard let terms else { return .custom(width: 21, height: 9) }
        return .custom(width: terms.width, height: terms.height)
    }

    public var fileTag: String {
        guard let terms else { return "window" }
        return "\(terms.width)x\(terms.height)"
    }

    /// The digit for ⌃⌘ in the View > Aspect Ratio menu. Custom ratios have none.
    public var shortcutDigit: Character? {
        switch self {
        case .r16x9: return "1"
        case .r3x2: return "2"
        case .r4x3: return "3"
        case .r1x1: return "4"
        case .r4x5: return "5"
        case .r3x4: return "6"
        case .r9x16: return "7"
        case .window: return "0"
        case .custom: return nil
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
