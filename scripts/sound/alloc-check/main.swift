// Counts heap allocations on the render path. alloc-check/count.c interposes malloc, calloc,
// realloc and their typed and zone variants and counts calls while `fringe_count_on` is set.
// The render calls start from a cold renderer and include note starts, phase inheritance,
// legato toggles and a fadeOutAll, so first-use runtime work would show up here.

import Foundation

let h = dlopen(nil, RTLD_NOW)
let on = dlsym(h, "fringe_count_on")!.assumingMemoryBound(to: Int32.self)
let count = dlsym(h, "fringe_count")!.assumingMemoryBound(to: Int.self)
let r = SynthRenderer.allocate(sampleRate: 48000)
var L = [Float](repeating: 0, count: 512), R = L
var batch: UInt32 = 1
let scores = [SoundPalette.sample(), SoundPalette.toggleTone(value: 0.4, wrong: true),
              SoundPalette.toggleTone(value: 0.1, wrong: false, at: 0.3)]
for s in scores {
    for n in s.notes {
        var n = n.sanitized()
        n.batch = batch
        r.ring.push(SynthCommand(op: .play, note: n))
    }
    batch += 1
}
var failed = false
L.withUnsafeMutableBufferPointer { lb in
    R.withUnsafeMutableBufferPointer { rb in
        on.pointee = 1
        // A probe allocation proves the counter works.
        let probe = [Int](repeating: 7, count: Int(on.pointee) + 99)
        let afterProbe = count.pointee
        for k in 0..<200 {
            if k == 120 { r.ring.push(SynthCommand(op: .fadeOutAll, seconds: 0.06)) }
            r.render(frames: 512, left: lb.baseAddress!, right: rb.baseAddress!)
        }
        let total = count.pointee - afterProbe
        on.pointee = 0
        print("- allocation counter: probe counted \(afterProbe) (must be > 0); allocations in 200 render callbacks (2.1 s from a cold start, with note starts, legato toggles and a fadeOutAll): \(total)")
        failed = afterProbe == 0 || total != 0 || probe.count == 0
    }
}
r.deallocate()
exit(failed ? 1 : 0)
