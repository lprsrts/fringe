// Compares two sets of PNG shots (e.g. target/ui-shots-before and target/ui-shots): for each
// name in both, the share of pixels that differ by more than `tolerance` levels in any channel,
// the largest difference, and the bounding box of the differing pixels. Writes a heatmap
// <name>.diff.png into OUT_DIR for every shot that differs.
//
// usage: shot-diff BEFORE_DIR AFTER_DIR OUT_DIR [TOLERANCE]
import AppKit
import Foundation

func pixels(_ path: String) -> (w: Int, h: Int, data: [UInt8])? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let w = image.width, h = image.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    let ok = data.withUnsafeMutableBytes { buf -> Bool in
        guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 4 * w,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    return ok ? (w, h, data) : nil
}

let args = CommandLine.arguments
guard args.count >= 4 else { print("usage: shot-diff BEFORE AFTER OUT [TOL]"); exit(2) }
let tolerance = args.count > 4 ? Int(args[4]) ?? 2 : 2
let fm = FileManager.default
try? fm.createDirectory(atPath: args[3], withIntermediateDirectories: true)
let names = ((try? fm.contentsOfDirectory(atPath: args[1])) ?? []).filter { $0.hasSuffix(".png") && !$0.hasSuffix(".diff.png") }.sorted()
var differing = 0
for name in names {
    let a = "\(args[1])/\(name)", b = "\(args[2])/\(name)"
    guard fm.fileExists(atPath: b) else { print(String(format: "%-48@ missing in after", name as NSString)); continue }
    guard let p = pixels(a), let q = pixels(b) else { print("\(name): unreadable"); continue }
    guard p.w == q.w, p.h == q.h else { print(String(format: "%-48@ size %dx%d -> %dx%d", name as NSString, p.w, p.h, q.w, q.h)); differing += 1; continue }
    var count = 0, maxDiff = 0
    var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
    var heat = [UInt8](repeating: 0, count: p.w * p.h * 4)
    for i in 0..<(p.w * p.h) {
        var d = 0
        for c in 0..<4 { d = max(d, abs(Int(p.data[4 * i + c]) - Int(q.data[4 * i + c]))) }
        maxDiff = max(maxDiff, d)
        let g = UInt8(p.data[4 * i] / 4)
        heat[4 * i] = g; heat[4 * i + 1] = g; heat[4 * i + 2] = g; heat[4 * i + 3] = 255
        if d > tolerance {
            count += 1
            let x = i % p.w, y = i / p.w
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            heat[4 * i] = 255; heat[4 * i + 1] = UInt8(max(0, 255 - 4 * d)); heat[4 * i + 2] = 0
        }
    }
    let share = 100 * Double(count) / Double(p.w * p.h)
    let box = count > 0 ? "box (\(minX),\(minY))-(\(maxX),\(maxY)) px" : ""
    print(String(format: "%-48@ %8.4f %% > %d levels, max %3d  %@", name as NSString, share, tolerance, maxDiff, box as NSString))
    if count > 0 {
        differing += 1
        let ctx = heat.withUnsafeMutableBytes {
            CGContext(data: $0.baseAddress, width: p.w, height: p.h, bitsPerComponent: 8, bytesPerRow: 4 * p.w,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        if let ctx, let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(args[3])/\(name.replacingOccurrences(of: ".png", with: ".diff.png"))") as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, ctx, nil)
            CGImageDestinationFinalize(dest)
        }
    }
}
print("\(differing) of \(names.count) shots differ by more than \(tolerance) levels somewhere")
