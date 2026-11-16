// Compose the Fringe cover banner (4:1, 3168 x 792) from a solved complex Ez field (.npy):
// the nanojet chain in the brand ramp, glass rims on the beads, then the icon, the
// wordmark and the Helmholtz equation the solvers answer, set like the app sets math.
// usage: swift compose.swift FIELD.npy SCENE.json ICON.png OUT.png
import AppKit
import CoreGraphics
import CoreText
import Foundation

let args = CommandLine.arguments
guard args.count == 5 else { fatalError("usage: compose FIELD.npy SCENE.json ICON.png OUT.png") }
let npyPath = args[1], scenePath = args[2], iconPath = args[3], outPath = args[4]

let W = 3168, H = 792
let Wf = CGFloat(W), Hf = CGFloat(H)

// MARK: - read the complex128 .npy (C order, rows x cols)
let data = try! Data(contentsOf: URL(fileURLWithPath: npyPath))
let headerLen = Int(data[8]) | (Int(data[9]) << 8)
let header = String(data: data[10..<(10 + headerLen)], encoding: .ascii)!
precondition(header.contains("<c16") && header.contains("False"), "expected little-endian complex128, C order")
let shapeStr = header.components(separatedBy: "(")[1].components(separatedBy: ")")[0]
let dims = shapeStr.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
let rows = dims[0], cols = dims[1]
var inten = [Double](repeating: 0, count: rows * cols)
data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
    let base = raw.baseAddress!.advanced(by: 10 + headerLen)
    for i in 0..<(rows * cols) {
        let re = base.loadUnaligned(fromByteOffset: i * 16, as: Double.self)
        let im = base.loadUnaligned(fromByteOffset: i * 16 + 8, as: Double.self)
        inten[i] = re * re + im * im
    }
}

// MARK: - scene geometry (domain + cylinders)
let scene = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: scenePath))) as! [String: Any]
let dom = scene["domain"] as! [String: Double]
let x0 = dom["x_min_um"]!, x1 = dom["x_max_um"]!, y0 = dom["y_min_um"]!, y1 = dom["y_max_um"]!
struct Cyl { let x: Double; let y: Double; let r: Double }
let cyls: [Cyl] = (scene["elements"] as! [[String: Any]]).compactMap { e in
    guard let s = e["shape"] as? [String: Any], s["kind"] as? String == "cylinder" else { return nil }
    return Cyl(x: e["x_um"] as! Double, y: e["y_um"] as! Double, r: s["radius_um"] as! Double)
}
// pixel (top-left origin) from µm
func px(_ x: Double) -> CGFloat { CGFloat((x - x0) / (x1 - x0)) * Wf }
func py(_ y: Double) -> CGFloat { CGFloat((y1 - y) / (y1 - y0)) * Hf }
let pxPerUm = Wf / CGFloat(x1 - x0)

// .npy row 0 is y_max (top row of the image)
func sample(_ u: Double, _ v: Double) -> Double {
    // u in [0, cols-1], v in [0, rows-1]; Catmull-Rom bicubic
    let iu = Int(floor(u)), iv = Int(floor(v))
    let fu = u - Double(iu), fv = v - Double(iv)
    func w(_ t: Double) -> [Double] {
        let t2 = t * t, t3 = t2 * t
        return [(-t3 + 2 * t2 - t) / 2, (3 * t3 - 5 * t2 + 2) / 2, (-3 * t3 + 4 * t2 + t) / 2, (t3 - t2) / 2]
    }
    let wu = w(fu), wv = w(fv)
    var acc = 0.0
    for j in 0..<4 {
        let r = min(max(iv - 1 + j, 0), rows - 1)
        var row = 0.0
        for i in 0..<4 {
            let c = min(max(iu - 1 + i, 0), cols - 1)
            row += wu[i] * inten[r * cols + c]
        }
        acc += wv[j] * row
    }
    return max(acc, 0)
}

// MARK: - brand ramp: deep graphite -> graphite -> slate -> grey -> Asympton yellow -> warm white
typealias RGB = (Double, Double, Double)
func hex(_ h: UInt32) -> RGB { (Double((h >> 16) & 255) / 255, Double((h >> 8) & 255) / 255, Double(h & 255) / 255) }
let stops: [(Double, RGB)] = [
    (0.00, hex(0x0B0D0F)),
    (0.18, hex(0x1A1D20)),
    (0.40, hex(0x3A4249)),
    (0.60, hex(0x8E9CA8)),
    (0.80, hex(0xF3C623)),
    (1.00, hex(0xFFF6D8)),
]
func ramp(_ t: Double) -> RGB {
    let t = min(max(t, 0), 1)
    for k in 1..<stops.count where t <= stops[k].0 {
        let (ta, a) = stops[k - 1], (tb, b) = stops[k]
        var f = (t - ta) / (tb - ta)
        f = f * f * (3 - 2 * f)
        return (a.0 + (b.0 - a.0) * f, a.1 + (b.1 - a.1) * f, a.2 + (b.2 - a.2) * f)
    }
    return stops.last!.1
}

// tone map: soft-saturating, so the jets bloom to warm white without clipping hard
let I0 = 1.1
func tone(_ I: Double) -> Double { pow(1 - exp(-I / I0), 0.75) }

// MARK: - field layer with legibility shaping
var pixels = [UInt8](repeating: 255, count: W * H * 4)
let avCx = 0.135 * Double(W), avCy = 0.70 * Double(H), avR = 0.23 * Double(H)
for y in 0..<H {
    let v = (Double(y) + 0.5) / Double(H) * Double(rows - 1)
    let yn = (Double(y) + 0.5) / Double(H)
    for x in 0..<W {
        let u = (Double(x) + 0.5) / Double(W) * Double(cols - 1)
        let xn = (Double(x) + 0.5) / Double(W)
        var t = tone(sample(u, v))
        // quiet the right third behind the wordmark (keep the fan of lobes faintly)
        let rightQuiet = 1 - 0.45 * smoothstep(0.58, 0.80, xn)
        // quiet the lower-left avatar zone
        let dx = Double(x) - avCx, dy = Double(y) - avCy
        let d = sqrt(dx * dx + dy * dy) / avR
        let avatarQuiet = 1 - 0.55 * (1 - smoothstep(0.7, 1.9, d))
        // left fade so the incoming beam emerges from darkness
        let leftFade = 0.55 + 0.45 * smoothstep(0.0, 0.22, xn)
        // gentle top/bottom vignette
        let vert = 1 - 0.25 * pow(abs(yn - 0.42) / 0.58, 2)
        t *= rightQuiet * avatarQuiet * leftFade * vert
        let c = ramp(t)
        let o = (y * W + x) * 4
        pixels[o] = UInt8(min(255, c.0 * 255)); pixels[o + 1] = UInt8(min(255, c.1 * 255)); pixels[o + 2] = UInt8(min(255, c.2 * 255))
    }
}
func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let t = min(max((x - a) / (b - a), 0), 1); return t * t * (3 - 2 * t)
}

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let provider = CGDataProvider(data: Data(pixels) as CFData)!
let fieldImg = CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: W * 4, space: cs,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)!
ctx.draw(fieldImg, in: CGRect(x: 0, y: 0, width: W, height: H))

// work in top-left coordinates from here
ctx.translateBy(x: 0, y: Hf); ctx.scaleBy(x: 1, y: -1)

func color(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    let c = hex(h); return CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: a)
}

// MARK: - glass beads: thin rim + a soft specular arc, like the icon's glass
for c in cyls {
    let cx = px(c.x), cy = py(c.y), r = CGFloat(c.r) * pxPerUm
    let rect = CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)
    ctx.saveGState()
    ctx.setStrokeColor(color(0xE8EDF2, 0.30)); ctx.setLineWidth(2.0)
    ctx.strokeEllipse(in: rect.insetBy(dx: 1, dy: 1))
    // specular arc at upper-left
    ctx.setStrokeColor(color(0xFFFFFF, 0.55)); ctx.setLineWidth(3.0); ctx.setLineCap(.round)
    ctx.addArc(center: CGPoint(x: cx, y: cy), radius: r - 6, startAngle: .pi * 1.08, endAngle: .pi * 1.38, clockwise: false)
    ctx.strokePath()
    ctx.restoreGState()
}

// MARK: - legibility scrim behind the text block (very soft radial darkening)
let textCx = 0.775 * Wf, textCy = 0.47 * Hf
ctx.saveGState()
let scrim = CGGradient(colorsSpace: cs, colors: [color(0x0B0D0F, 0.55), color(0x0B0D0F, 0.0)] as CFArray, locations: [0, 1])!
ctx.translateBy(x: textCx, y: textCy); ctx.scaleBy(x: 2.6, y: 1)
ctx.drawRadialGradient(scrim, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 0.34 * Hf, options: [])
ctx.restoreGState()

// MARK: - typography
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)

func sys(_ weight: NSFont.Weight, _ size: CGFloat) -> NSFont { NSFont.systemFont(ofSize: size, weight: weight) }
// STIX Two ships with macOS, in /System/Library/Fonts/Supplemental.
func named(_ name: String, _ size: CGFloat) -> NSFont {
    guard let f = NSFont(name: name, size: size) else { fatalError("missing font \(name)") }
    return f
}
struct Piece { var text: String; var font: NSFont; var color: CGColor; var kern: CGFloat = 0; var shift: CGFloat = 0 }
func rich(_ ps: [Piece]) -> NSAttributedString {
    let out = NSMutableAttributedString()
    for p in ps {
        out.append(NSAttributedString(string: p.text, attributes: [.font: p.font, .foregroundColor: NSColor(cgColor: p.color)!,
                                                                  .kern: p.kern, .baselineOffset: p.shift]))
    }
    return out
}
/// Draws `s` with its first line's baseline at `p` (top-left coordinates).
func put(_ s: NSAttributedString, baseline p: CGPoint, shadow: CGFloat = 0) {
    let f = s.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
    ctx.saveGState()
    if shadow > 0 { ctx.setShadow(offset: .zero, blur: shadow, color: color(0x000000, 0.55)) }
    s.draw(with: CGRect(x: p.x, y: p.y - f.ascender, width: 4000, height: 1000), options: [.usesLineFragmentOrigin])
    ctx.restoreGState()
}
func wide(_ s: NSAttributedString) -> CGFloat { s.size().width }
func drawIcon(_ r: CGRect) {
    guard let icon = NSImage(contentsOfFile: iconPath), let cg = icon.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        fatalError("cannot read the icon at \(iconPath)")
    }
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 34, color: color(0x000000, 0.6))
    ctx.translateBy(x: r.minX, y: r.maxY); ctx.scaleBy(x: 1, y: -1)
    ctx.interpolationQuality = .high
    ctx.draw(cg, in: CGRect(origin: .zero, size: r.size))
    ctx.restoreGState()
}

let ink = color(0xF4F2EC), mist = color(0xC9D1D8, 0.92), gold = color(0xF3C623)
let rightEdge = 0.955 * Wf
let axisY = py(cyls.first!.y)

// The icon on the jet axis and the wordmark beside it; under them the scalar Helmholtz
// equation for Ez, with the index the user draws in gold, and the tagline.
let iconSize: CGFloat = 196, gap: CGFloat = 44
let wordFont = sys(.semibold, 228)
let word = rich([Piece(text: "Fringe", font: wordFont, color: ink, kern: -4)])
let m: CGFloat = 70, sc: CGFloat = 0.68
let it = named("STIXTwoText-Italic", m), up = named("STIXTwoText", m), sym = named("STIXTwoMath-Regular", m)
let itS = named("STIXTwoText-Italic", m * sc), upS = named("STIXTwoText", m * sc)
let eq = rich([
    Piece(text: "∇", font: sym, color: ink), Piece(text: "2", font: upS, color: ink, shift: 0.36 * m),
    Piece(text: "E", font: it, color: ink, kern: 2), Piece(text: "z", font: itS, color: ink, shift: -0.18 * m),
    Piece(text: " + ", font: up, color: ink, kern: 4),
    Piece(text: "k", font: it, color: ink, kern: 2),
    // the subscript 0 and superscript 2 share one column, as TeX stacks them
    Piece(text: "0", font: upS, color: ink, kern: -("0" as NSString).size(withAttributes: [.font: upS]).width, shift: -0.18 * m),
    Piece(text: "2", font: upS, color: ink, shift: 0.36 * m),
    Piece(text: " n", font: it, color: gold), Piece(text: "2", font: upS, color: gold, shift: 0.36 * m),
    Piece(text: "(", font: up, color: gold), Piece(text: "x", font: it, color: gold), Piece(text: ", ", font: up, color: gold),
    Piece(text: "y", font: it, color: gold), Piece(text: ")", font: up, color: gold),
    Piece(text: " E", font: it, color: ink, kern: 2), Piece(text: "z", font: itS, color: ink, shift: -0.18 * m),
    Piece(text: " = 0", font: up, color: ink, kern: 4),
])
let tag = rich([Piece(text: "Draw the optics. Fringe solves the rest.", font: sys(.regular, 46), color: mist, kern: 0.2)])
let rowW = iconSize + gap + wide(word)
let left = rightEdge - max(rowW, wide(eq))
let iconRect = CGRect(x: left, y: axisY - iconSize / 2, width: iconSize, height: iconSize)
drawIcon(iconRect)
put(word, baseline: CGPoint(x: left + iconSize + gap - 6, y: iconRect.midY + wordFont.capHeight / 2), shadow: 28)
put(eq, baseline: CGPoint(x: left + 2, y: iconRect.maxY + 118), shadow: 18)
put(tag, baseline: CGPoint(x: left + 4, y: iconRect.maxY + 214))

// MARK: - write
func writePNG(_ img: CGImage, _ path: String) {
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
let out = ctx.makeImage()!
writePNG(out, outPath)

print("wrote \(outPath) (\(W)x\(H)), field grid \(cols)x\(rows)")
