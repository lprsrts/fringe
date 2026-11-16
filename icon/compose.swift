// Draws the app icon from a square field render: the macOS icon grid (an 824 pt
// rounded square on a 1024 pt canvas), a soft shadow and a faint rim.
//
//   swift icon/compose.swift FIELD.png OUT.png
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let field = NSImage(contentsOfFile: args[1])?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("usage: compose.swift FIELD.png OUT.png\n".data(using: .utf8)!)
    exit(2)
}

let canvas = 1024.0
let body = CGRect(x: 100, y: 100, width: 824, height: 824)

/// The icon body: the grid's rounded square, 185 pt corners on 824 pt, which sits on the
/// system's continuous-corner shape closely enough at every icon size.
func squircle(_ rect: CGRect) -> CGPath {
    let radius = rect.width * 185 / 824
    return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

let ctx = CGContext(data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let shape = squircle(body)

// Shadow under the body.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
ctx.addPath(shape)
ctx.setFillColor(CGColor(gray: 0, alpha: 1))
ctx.fillPath()
ctx.restoreGState()

// The field, filling the body.
ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
ctx.interpolationQuality = .high
ctx.draw(field, in: body)
// Light from above: a faint wash over the top half.
let wash = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                      colors: [CGColor(gray: 1, alpha: 0.10), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(wash, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.midY), options: [])
ctx.restoreGState()

// A thin rim so the edge holds against dark backgrounds.
ctx.addPath(squircle(body.insetBy(dx: 1.5, dy: 1.5)))
ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.14))
ctx.setLineWidth(3)
ctx.strokePath()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
