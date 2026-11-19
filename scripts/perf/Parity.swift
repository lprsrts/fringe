// GPU vs CPU colouring parity (viewport design §12): the canvas's Metal shader against the
// core's render_rgba, on three solved examples, over quantity × colormap × part × transfer
// variant × phase × normalisation × view. Writes target/perf/parity.tsv (one line per case)
// and a diff heatmap for each failing case, prints a summary, and fails on any case outside:
//   - alpha and the outside mask identical;
//   - every pixel within 2 levels, except documented exceptions, and >= 99.9 % of pixels
//     exactly equal or 1 level off;
//   - exceptions (at most 0.05 % of pixels): (a) the phase of a near-zero field
//     (|E|/S < 1e-5), (b) a colour one LUT entry away where adjacent entries differ by more
//     than 2 levels, (c) the phase exactly on the ±180° cut (|Im E e^{jφ}| <= 1e-6 |E|
//     with Re < 0), where f32 and f64 round to opposite ends of the colormap.
import AppKit
import CFringeCore
import Foundation
import SwiftUI

@MainActor enum Parity {
    struct Variant {
        var name: String
        var gamma: Double = 1
        var logDb: Double? = nil
        var weighted = false
    }

    struct Outcome {
        var maxDiff = 0
        var exact = 0
        var within1 = 0
        var within2 = 0
        var exceptionsA = 0
        var exceptionsB = 0
        var exceptionsC = 0
        var failures = 0
        var alphaMismatch = 0
        var pixels = 0
        var heat: [UInt8]? = nil

        var pass: Bool {
            alphaMismatch == 0 && failures == 0
                && Double(within1) >= 0.999 * Double(pixels)
                && Double(exceptionsA + exceptionsB + exceptionsC) <= 0.0005 * Double(pixels)
        }
    }

    static func solve(_ name: String) async -> FieldHandle? {
        guard let scene = FringeBridge.example(name), let job = try? JobHandle(scene: scene, quality: .preview) else { return nil }
        while job.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        return try? job.takeResult()
    }

    static func viewJSON(quantity: Quantity, part: FieldPartName, phase: Double, colormap: ColormapName, variant: Variant,
                         norm: NormalizationMode, normValue: Double, rect: RectUm) -> String {
        let logDb = variant.logDb.map { "\($0)" } ?? "null"
        return """
        {"quantity":"\(quantity.rawValue)","part":"\(part.rawValue)","phase_deg":\(phase),"colormap":"\(colormap.rawValue)",\
        "gamma":\(variant.gamma),"normalization":{"mode":"\(norm.rawValue)","value":\(normValue)},"log_db":\(logDb),\
        "phase_weighted":\(variant.weighted),"view_um":{"x_min_um":\(rect.xMin),"x_max_um":\(rect.xMax),"y_min_um":\(rect.yMin),"y_max_um":\(rect.yMax)},\
        "outside_rgba":[0,0,0,0],"pec_rgba":null}
        """
    }

    static func bytes(of image: CGImage) -> [UInt8]? {
        guard let data = image.dataProvider?.data, image.bytesPerRow == 4 * image.width else { return nil }
        return [UInt8](data as Data)
    }

    static func run(out: String) async -> Bool {
        PerfProbe.enabled = false
        ViewportMode.override = .gpu
        guard let gpu = FieldGPU.shared else { print("parity: no Metal device"); return false }
        _ = await wait(10) { gpu.isReady || gpu.compileFailed }
        guard gpu.isReady else { print("parity: the shader did not compile"); return false }
        let examples = ["lens", "talbot", "mie_pec"]
        let quantities: [Quantity] = [.intensity, .magnitude, .real, .phase]
        let parts: [FieldPartName] = [.total, .scattered, .incident]
        let phases: [Double] = [0, 37, 90, 271]
        let norms: [(NormalizationMode, Double)] = [(.auto, 1), (.incident, 1), (.fixed, 0.5)]
        var lines = ["field\tquantity\tcolormap\tpart\tvariant\tphase\tnorm\tview\tmax_diff\tpct_exact\tpct_within1\texc_a\texc_b\texc_c\tfail_px\tpass"]
        var cases = 0, failed = 0, worst = 0
        // The playback path (resample once, colour per frame) against the one pass.
        var twoStageCases = 0, twoStageDiffering = 0, twoStageWorst = 0
        // The invalid-scene look (desaturated, 85 % opacity) against the CPU's.
        var lookCases = 0, lookFailed = 0, lookWorst = 0
        var exceptionsTotal = 0, pixelsTotal = 0
        var heatmaps = 0
        let start = Date()
        try? FileManager.default.createDirectory(atPath: "\(out)/parity", withIntermediateDirectories: true)
        for example in examples {
            guard let field = await solve(example), let grid = field.grid, let info = field.info else { print("parity: \(example) did not solve"); return false }
            print("parity: \(example) \(grid.nx)x\(grid.ny) nodes")
            let full = RectUm(xMin: grid.x0, xMax: grid.x0 + Double(grid.nx - 1) * grid.dx, yMin: grid.y0, yMax: grid.y0 + Double(grid.ny - 1) * grid.dx)
            let zoom = RectUm(xMin: full.xMin - 0.15 * full.width, xMax: full.xMin + 0.55 * full.width,
                              yMin: full.yMin + 0.3 * full.height, yMax: full.yMax + 0.1 * full.height)
            let views: [(String, RectUm, Int, Int)] = [("full", full, 1644, 925), ("zoom", zoom, 777, 555)]
            var buffers: [FieldPartName: FieldPartBuffer] = [:]
            for part in parts {
                buffers[part] = FieldPartBuffer.make(device: gpu.device, field: field, part: part, key: .init(field: ObjectIdentifier(field), part: part))
            }
            var stencils: [String: FieldStencils] = [:]
            var luts: [ColormapName: [UInt8]] = [:]
            for c in ColormapName.allCases {
                var lut = [UInt8](repeating: 0, count: 4096)
                _ = lut.withUnsafeMutableBufferPointer { fringe_colormap_lut_n(c.rawValue, info.wavelengthUm, 1024, $0.baseAddress, $0.count) }
                luts[c] = lut
            }
            var summary: [Quantity: (cases: Int, failed: Int, worst: Int, exc: Int)] = [:]
            for quantity in quantities {
                var variants = [Variant(name: "gamma1"), Variant(name: "gamma0.6", gamma: 0.6)]
                if quantity == .intensity || quantity == .magnitude { variants.append(Variant(name: "log30", logDb: 30)) }
                if quantity == .phase { variants.append(Variant(name: "weighted", weighted: true)) }
                for colormap in ColormapName.allCases {
                    for part in parts {
                        guard let buffer = buffers[part] else { continue }
                        for variant in variants {
                            for phase in phases {
                                for (norm, normValue) in norms {
                                    for (viewName, rect, w, h) in views {
                                        let value = norm == .fixed ? normValue * info.incidentPeak : normValue
                                        let json = viewJSON(quantity: quantity, part: part, phase: phase, colormap: colormap, variant: variant,
                                                            norm: norm, normValue: value, rect: rect)
                                        guard let cpuImage = try? field.render(viewJSON: json, width: w, height: h), let cpu = bytes(of: cpuImage) else {
                                            print("parity: CPU render failed for \(json)"); return false
                                        }
                                        var display = DisplaySettings()
                                        display.quantity = quantity
                                        display.part = part
                                        display.gamma = variant.gamma
                                        display.logDb = variant.logDb
                                        display.phaseWeighted = variant.weighted
                                        let scale = field.colourScale(viewJSON: json)
                                        let key = "\(viewName)"
                                        guard let frame = gpu.frame(field: field, part: buffer, display: display, phaseDeg: phase, viewRect: rect, width: w, height: h,
                                                                    incidentAmplitude: info.incidentPeak, stencils: stencils[key], scale: scale,
                                                                    desaturate: false, opacity: 1, colormap: colormap),
                                              let gpuBytes = gpu.renderBytes(frame) else { print("parity: GPU render failed"); return false }
                                        stencils[key] = frame.stencils
                                        guard let twoStage = gpu.renderBytes(frame, twoStage: true) else { print("parity: GPU two-stage render failed"); return false }
                                        twoStageCases += 1
                                        if twoStage != gpuBytes {
                                            twoStageDiffering += 1
                                            twoStageWorst = max(twoStageWorst, zip(twoStage, gpuBytes).map { abs(Int($0) - Int($1)) }.max() ?? 0)
                                        }
                                        if colormap == .viridis || colormap == .rdbu, part == .total, phase == 37, norm == .auto, variant.name == "gamma1", viewName == "full" {
                                            guard let looked = gpu.frame(field: field, part: buffer, display: display, phaseDeg: phase, viewRect: rect, width: w, height: h,
                                                                         incidentAmplitude: info.incidentPeak, stencils: frame.stencils, scale: scale,
                                                                         desaturate: true, opacity: 0.85, colormap: colormap),
                                                  let gpuLook = gpu.renderBytes(looked) else { print("parity: GPU invalid-look render failed"); return false }
                                            var reference = cpu
                                            reference.withUnsafeMutableBufferPointer { FieldLook.desaturate($0.baseAddress!, count: w * h) }
                                            for i in reference.indices { reference[i] = UInt8((Float(reference[i]) * 0.85).rounded()) }
                                            let diffs = zip(reference, gpuLook).map { abs(Int($0) - Int($1)) }
                                            let alphaSame = stride(from: 3, to: diffs.count, by: 4).allSatisfy { diffs[$0] <= 1 }
                                            let within1 = Double(diffs.filter { $0 <= 1 }.count) / Double(diffs.count)
                                            let over2 = Double(diffs.filter { $0 > 2 }.count) / Double(diffs.count)
                                            lookCases += 1
                                            lookWorst = max(lookWorst, diffs.max() ?? 0)
                                            if !(alphaSame && within1 >= 0.999 && over2 <= 0.0005) { lookFailed += 1 }
                                        }
                                        let o = compare(cpu: cpu, gpu: gpuBytes, w: w, h: h, quantity: quantity, weighted: variant.weighted, phase: phase,
                                                        lut: luts[colormap]!, field: field, part: part, rect: rect, scale: scale,
                                                        wantHeat: heatmaps < 20)
                                        cases += 1
                                        worst = max(worst, o.maxDiff)
                                        exceptionsTotal += o.exceptionsA + o.exceptionsB + o.exceptionsC
                                        pixelsTotal += o.pixels
                                        var s = summary[quantity] ?? (0, 0, 0, 0)
                                        s.cases += 1
                                        s.worst = max(s.worst, o.maxDiff)
                                        s.exc += o.exceptionsA + o.exceptionsB + o.exceptionsC
                                        if !o.pass {
                                            failed += 1
                                            s.failed += 1
                                            if let heat = o.heat, heatmaps < 20 {
                                                heatmaps += 1
                                                writeHeat(heat, w: w, h: h, to: "\(out)/parity/\(example)-\(quantity.rawValue)-\(colormap.rawValue)-\(part.rawValue)-\(variant.name)-\(Int(phase))-\(norm.rawValue)-\(viewName).png")
                                            }
                                        }
                                        summary[quantity] = s
                                        let px = Double(o.pixels)
                                        lines.append([example, quantity.rawValue, colormap.rawValue, part.rawValue, variant.name, "\(Int(phase))", norm.rawValue, viewName,
                                                      "\(o.maxDiff)", String(format: "%.4f", 100 * Double(o.exact) / px), String(format: "%.4f", 100 * Double(o.within1) / px),
                                                      "\(o.exceptionsA)", "\(o.exceptionsB)", "\(o.exceptionsC)", "\(o.failures)", o.pass ? "pass" : "FAIL"].joined(separator: "\t"))
                                    }
                                }
                            }
                        }
                    }
                }
            }
            for q in quantities {
                let s = summary[q] ?? (0, 0, 0, 0)
                print(String(format: "  %-8@ %-10@ cases %5d  failed %4d  worst diff %3d  exception pixels %d", example as NSString, q.rawValue as NSString, s.cases, s.failed, s.worst, s.exc))
            }
        }
        try? lines.joined(separator: "\n").write(toFile: "\(out)/parity.tsv", atomically: true, encoding: .utf8)
        print("parity: playback path (resample + colour) against one pass: \(twoStageCases) cases, \(twoStageDiffering) differ (worst \(twoStageWorst) levels)")
        print("parity: invalid-scene look (desaturated, 85 %) against the CPU's: \(lookCases) cases, \(lookFailed) failed (worst \(lookWorst) levels)")
        print(String(format: "parity: %d cases in %.0f s, %d failed; worst channel difference %d; exception pixels %d of %d (%.5f %%); table %@/parity.tsv",
                     cases, Date().timeIntervalSince(start), failed, worst, exceptionsTotal, pixelsTotal, 100 * Double(exceptionsTotal) / Double(max(1, pixelsTotal)), out))
        return failed == 0 && twoStageDiffering == 0 && lookFailed == 0
    }

    static func compare(cpu: [UInt8], gpu: [UInt8], w: Int, h: Int, quantity: Quantity, weighted: Bool, phase: Double, lut: [UInt8],
                        field: FieldHandle, part: FieldPartName, rect: RectUm, scale: Double, wantHeat: Bool) -> Outcome {
        var o = Outcome()
        o.pixels = w * h
        var heat: [UInt8]? = nil
        cpu.withUnsafeBufferPointer { c in
            gpu.withUnsafeBufferPointer { g in
                for i in 0..<(w * h) {
                    let k = 4 * i
                    if c[k + 3] != g[k + 3] { o.alphaMismatch += 1 }
                    let d0 = abs(Int(c[k]) - Int(g[k])), d1 = abs(Int(c[k + 1]) - Int(g[k + 1]))
                    let d2 = abs(Int(c[k + 2]) - Int(g[k + 2])), d3 = abs(Int(c[k + 3]) - Int(g[k + 3]))
                    let d: Int = max(max(d0, d1), max(d2, d3))
                    if d == 0 { o.exact += 1; o.within1 += 1; o.within2 += 1; continue }
                    if d == 1 { o.within1 += 1; o.within2 += 1; continue }
                    o.maxDiff = max(o.maxDiff, d)
                    if d == 2 { o.within2 += 1; continue }
                    // More than 2 levels: an exception or a failure.
                    let x = rect.xMin + (Double(i % w) + 0.5) * rect.width / Double(w)
                    let y = rect.yMax - (Double(i / w) + 0.5) * rect.height / Double(h)
                    var exception = false
                    let v = quantity == .phase ? field.sample(x: x, y: y, part: FieldPart(rawValue: part.rawValue) ?? .total) : nil
                    let mag = v.map { ($0.re * $0.re + $0.im * $0.im).squareRoot() } ?? 0
                    // E e^{jφ} for the branch-cut test.
                    let rot = FieldUniforms.phaseFactor(phase)
                    let zr = (v?.re ?? 0) * rot.re - (v?.im ?? 0) * rot.im
                    let zi = (v?.re ?? 0) * rot.im + (v?.im ?? 0) * rot.re
                    if quantity == .phase, mag / scale < 1e-5 {
                        o.exceptionsA += 1
                        exception = true
                    } else if quantity == .phase, mag > 0, zr < 0, abs(zi) <= 1e-6 * mag {
                        // (c) arg on the ±180° cut: f32 and f64 land on opposite ends of
                        // the colormap (index 0 against 1023, one step apart cyclically).
                        o.exceptionsC += 1
                        exception = true
                    } else if !weighted, let (a, b) = nearestEntries(c, g, k, lut), abs(a - b) <= 1 {
                        let lo = min(a, b)
                        var step = 0
                        for ch in 0..<3 {
                            let p0 = Int(lut[4 * lo + ch]), p1 = Int(lut[4 * lo + 4 + ch])
                            step = max(step, abs(p0 - p1))
                        }
                        if step > 2 { o.exceptionsB += 1; exception = true }
                    }
                    if !exception {
                        o.failures += 1
                        if wantHeat {
                            if heat == nil { heat = [UInt8](repeating: 0, count: 4 * w * h) }
                            heat![k] = 255; heat![k + 3] = 255
                        }
                    }
                }
            }
        }
        o.heat = heat
        return o
    }

    /// The closest pair of LUT entries holding the CPU's and the GPU's colours.
    static func nearestEntries(_ c: UnsafeBufferPointer<UInt8>, _ g: UnsafeBufferPointer<UInt8>, _ k: Int, _ lut: [UInt8]) -> (Int, Int)? {
        func entries(_ p: UnsafeBufferPointer<UInt8>) -> [Int] {
            (0..<1024).filter { lut[4 * $0] == p[k] && lut[4 * $0 + 1] == p[k + 1] && lut[4 * $0 + 2] == p[k + 2] }
        }
        let a = entries(c), b = entries(g)
        var best: (Int, Int)?
        for i in a { for j in b where best == nil || abs(i - j) < abs(best!.0 - best!.1) { best = (i, j) } }
        return best
    }

    static func writeHeat(_ heat: [UInt8], w: Int, h: Int, to path: String) {
        var data = heat
        let image = data.withUnsafeMutableBytes {
            CGContext(data: $0.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 4 * w,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        guard let image, let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}

/// Export check: the PNG export (core render_rgba + VectorRenderer.drawOverlays) is the
/// path the viewport redesign left alone apart from the overlay text cache. Renders the
/// lens example's export for each quantity with the text cache cold and warm and compares
/// the decoded pixels; writes the PNGs and their hashes to OUT/export/.
@MainActor enum ExportCheck {
    /// Full-resolution PNG exports of several examples, quantities and sizes, rendered with
    /// the overlay text cache (as now) and without it (every label typeset afresh, as before
    /// the cache; the overlay drawing order is otherwise the same statements in the same
    /// order). Writes hashes and fails on any differing pixel.
    static func run(out: String) async -> Bool {
        PerfProbe.enabled = false
        let m = AppState()
        try? FileManager.default.createDirectory(atPath: "\(out)/export", withIntermediateDirectories: true)
        var ok = true
        var lines: [String] = []
        for example in ["lens", "talbot", "mie_pec", "double_slit"] {
            guard let info = m.examples.first(where: { $0.name == example }) else { print("export: no \(example)"); return false }
            m.loadExample(info)
            _ = await wait(180) { !m.solver.isRunning && m.solver.shown != nil && !m.solver.isShownStale }
            for q in Quantity.allCases {
                m.setQuantity(q)
                for (w, h) in [(1920, 1080), (3840, 2160)] {
                    var export = m.pngExport
                    export.width = w
                    export.height = h
                    OverlayTextCache.enabled = false
                    let fresh = try? ImageExportService.renderPNG(export)
                    OverlayTextCache.enabled = true
                    OverlayTextCache.cache.removeAllObjects()
                    let cold = try? ImageExportService.renderPNG(export)
                    let warm = try? ImageExportService.renderPNG(export)
                    guard let fresh, let cold, let warm, let a = decode(fresh), let b = decode(cold), let c = decode(warm) else {
                        print("export: \(example) \(q) failed"); return false
                    }
                    let same = a == b && b == c
                    ok = ok && same
                    let hash = a.reduce(UInt64(0xcbf29ce484222325)) { ($0 ^ UInt64($1)) &* 0x100000001b3 }
                    lines.append("\(example)\t\(q.rawValue)\t\(w)x\(h)\t\(String(hash, radix: 16))\tuncached==cached \(a == b)\tcold==warm \(b == c)")
                    if w == 1920 { try? fresh.write(to: URL(fileURLWithPath: "\(out)/export/\(example)-\(q.rawValue).png")) }
                }
            }
        }
        try? lines.joined(separator: "\n").write(toFile: "\(out)/export/hashes.tsv", atomically: true, encoding: .utf8)
        print(lines.joined(separator: "\n"))
        print("export: \(lines.count) exports; uncached, cold and warm text cache give \(ok ? "identical" : "DIFFERENT") pixels")
        return ok
    }

    static func decode(_ data: Data) -> [UInt8]? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        var out = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ok = out.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 4 * image.width,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return ok ? out : nil
    }
}

/// The invalid-scene look against what the canvas showed before the viewport change: SwiftUI's
/// `.saturation(0)` on the field image. `ImageRenderer` draws that view offscreen (no window),
/// so the old grey levels can be read and compared with `FieldLook.desaturate`, which the GPU
/// shader and the CPU fallback both follow. The test image holds every colour of every
/// colormap's table (the field image only ever shows those), with and without the 85 %
/// opacity of a stale or invalid image (the opacity is applied the same way before and after,
/// so it is not part of this comparison).
@MainActor enum LookCheck {
    static func run(out: String) -> Bool {
        var pixels: [UInt8] = []
        for colormap in ColormapName.allCases {
            var lut = [UInt8](repeating: 0, count: 4 * FieldShader.lutSize)
            _ = lut.withUnsafeMutableBufferPointer { fringe_colormap_lut_n(colormap.rawValue, 0.5, UInt32(FieldShader.lutSize), $0.baseAddress, $0.count) }
            pixels += lut
        }
        let n = pixels.count / 4
        let w = 256, h = (n + w - 1) / w
        pixels += [UInt8](repeating: 255, count: 4 * (w * h - n))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4 * w, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return false }
        let view = Image(decorative: image, scale: 1).interpolation(.none).saturation(0).frame(width: CGFloat(w), height: CGFloat(h))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let rendered = renderer.cgImage else { print("look: ImageRenderer gave no image"); return false }
        // Read both back as RGBA8 sRGB.
        func rgba(_ img: CGImage) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: 4 * w * h)
            out.withUnsafeMutableBytes { buf in
                let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 4 * w, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            return out
        }
        let old = rgba(rendered)
        var new = rgba(image)
        new.withUnsafeMutableBufferPointer { FieldLook.desaturate($0.baseAddress!, count: w * h) }
        var diffs: [Int] = []
        var signed: [Int] = []
        for i in 0..<n {
            for c in 0..<3 {
                let d = Int(new[4 * i + c]) - Int(old[4 * i + c])
                diffs.append(abs(d))
                signed.append(d)
            }
        }
        let worst = diffs.max() ?? 0
        let mean = Double(signed.reduce(0, +)) / Double(max(1, signed.count))
        let within2 = Double(diffs.filter { $0 <= 2 }.count) / Double(max(1, diffs.count))
        let line = String(format: "look: FieldLook.desaturate against SwiftUI .saturation(0) (ImageRenderer) on %d colormap colours: worst %d levels, mean signed %+.2f, %.2f %% within 2 levels",
                          n, worst, mean, 100 * within2)
        print(line)
        try? line.write(toFile: "\(out)/look.txt", atomically: true, encoding: .utf8)
        if let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(out)/look-swiftui.png") as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, rendered, nil)
            CGImageDestinationFinalize(dest)
        }
        return worst <= 2
    }
}

/// The pan/pinch shift of the overlay layer (`ViewportView.transform`) against the mapping it
/// stands for: content drawn for view `a`, shifted and scaled about the layer's centre, must
/// put every plane point where a fresh draw for view `b` would. Checked for a layer tree that
/// measures y down (the app's: the view is flipped) and up.
@MainActor enum TransformCheck {
    static func run() -> Bool {
        var worst = 0.0
        var rng = SystemRandomNumberGenerator()
        for yDown in [true, false] {
            for _ in 0..<2000 {
                func r(_ lo: Double, _ hi: Double) -> Double { Double.random(in: lo...hi, using: &rng) }
                let ax = r(-20, 20), ay = r(-20, 20), aw = r(5, 40), ah = r(5, 40)
                let a = RectUm(xMin: ax, xMax: ax + aw, yMin: ay, yMax: ay + ah)
                let k = r(0.5, 2)
                let bx = ax + r(-5, 5), by = ay + r(-5, 5)
                let bb = RectUm(xMin: bx, xMax: bx + aw * k, yMin: by, yMax: by + ah * k)
                let size = CGSize(width: r(200, 1600), height: r(200, 1600))
                let t = ViewportView.transform(from: a, to: bb, size: size, yDown: yDown)
                let x = r(a.xMin, a.xMax), y = r(a.yMin, a.yMax)
                // Layer coordinates of the plane point drawn for a view.
                func layer(_ v: RectUm) -> CGPoint {
                    let px = (x - v.xMin) / v.width * size.width
                    let py = yDown ? (v.yMax - y) / v.height * size.height : (y - v.yMin) / v.height * size.height
                    return CGPoint(x: px, y: py)
                }
                let p = layer(a), want = layer(bb)
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let moved = CGPoint(x: c.x + t.a * (p.x - c.x) + t.tx, y: c.y + t.d * (p.y - c.y) + t.ty)
                worst = max(worst, hypot(moved.x - want.x, moved.y - want.y))
            }
        }
        print(String(format: "transform: pan/pinch layer shift against a fresh draw, 4000 cases: worst %.2e pt", worst))
        return worst < 1e-6
    }
}
