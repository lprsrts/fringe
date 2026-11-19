import CoreGraphics

/// A curve's name drawn on the plot.
struct PlacedLabel: Equatable {
    var text: String
    /// Top-left origin, in figure points.
    var rect: CGRect
    var secondary: Bool
}

/// Where curve names go: at the right end of each curve when they clear each other;
/// otherwise where the curves are furthest apart in the last 60 % of the plot, the upper
/// name above (or just under) its curve, the lower one below (or just over) its curve.
/// Never stacked with leaders, never clipped: a name that fits nowhere is dropped (the
/// readout and VoiceOver still carry it).
enum DirectLabel {
    struct Curve {
        var text: String
        /// The curve in figure points, in x order.
        var points: [CGPoint]
        var size: CGSize
        var secondary: Bool
    }

    static let endGap: CGFloat = 4
    static let clearance: CGFloat = 3

    /// The labels at the curve ends, or nil when two of them would touch.
    static func atEnds(_ curves: [Curve], endX: CGFloat) -> [PlacedLabel]? {
        let labels = curves.compactMap { c -> PlacedLabel? in
            guard let last = c.points.last else { return nil }
            return PlacedLabel(text: c.text, rect: CGRect(x: endX + endGap, y: last.y - c.size.height / 2,
                                                          width: c.size.width, height: c.size.height), secondary: c.secondary)
        }
        for i in labels.indices {
            for j in labels.indices where j > i {
                if labels[i].rect.insetBy(dx: 0, dy: -1).intersects(labels[j].rect.insetBy(dx: 0, dy: -1)) { return nil }
            }
        }
        return labels
    }

    /// True when two curves are within `tolerance` points everywhere.
    static func coincide(_ a: Curve, _ b: Curve, tolerance: CGFloat = 2) -> Bool {
        guard !a.points.isEmpty else { return false }
        for p in a.points {
            guard let y = y(of: b.points, at: p.x) else { continue }
            if abs(y - p.y) > tolerance { return false }
        }
        return true
    }

    /// Labels inside the plot.
    /// `avoid` is an x range no name may overlap (the crosshair).
    static func inside(_ curves: [Curve], plot: CGRect, avoid: ClosedRange<CGFloat>? = nil) -> [PlacedLabel] {
        func clear(_ r: CGRect) -> Bool {
            guard let avoid else { return true }
            return r.maxX < avoid.lowerBound || r.minX > avoid.upperBound
        }
        if curves.count == 1, let c = curves.first {
            // One curve: above it where it is lowest in the last 60 %.
            let candidates = c.points.filter { $0.x >= plot.minX + plot.width * 0.4 }.sorted { $0.y > $1.y }
            for p in candidates.prefix(40) {
                if let r = above(c, at: p.x, plot: plot, avoid: []), clear(r) { return [PlacedLabel(text: c.text, rect: r, secondary: c.secondary)] }
            }
            return []
        }
        guard curves.count == 2 else { return [] }
        let a = curves[0], b = curves[1]
        // Candidate x positions in the last 60 %, furthest apart first.
        let xs = a.points.map(\.x).filter { $0 >= plot.minX + plot.width * 0.4 }
        let scored = xs.compactMap { x -> (x: CGFloat, gap: CGFloat)? in
            guard let ya = y(of: a.points, at: x), let yb = y(of: b.points, at: x) else { return nil }
            return (x, abs(ya - yb))
        }.sorted { $0.gap > $1.gap }
        var best: [PlacedLabel] = []
        for cand in scored.prefix(60) {
            guard let ya = y(of: a.points, at: cand.x), let yb = y(of: b.points, at: cand.x) else { continue }
            let (upper, lower) = ya <= yb ? (a, b) : (b, a)
            let uOptions = [above(upper, at: cand.x, plot: plot, avoid: [lower]), under(upper, at: cand.x, plot: plot, avoid: [lower])].map { $0.flatMap { clear($0) ? $0 : nil } }
            let lOptions = [below(lower, at: cand.x, plot: plot, avoid: [upper]), over(lower, at: cand.x, plot: plot, avoid: [upper])].map { $0.flatMap { clear($0) ? $0 : nil } }
            for u in uOptions.compactMap({ $0 }) {
                for l in lOptions.compactMap({ $0 }) where !u.insetBy(dx: -2, dy: -2).intersects(l) {
                    let placed = [PlacedLabel(text: upper.text, rect: u, secondary: upper.secondary),
                                  PlacedLabel(text: lower.text, rect: l, secondary: lower.secondary)]
                    return curves.compactMap { c in placed.first { $0.text == c.text } }
                }
            }
            if best.isEmpty, let u = uOptions.compactMap({ $0 }).first {
                best = [PlacedLabel(text: upper.text, rect: u, secondary: upper.secondary)]
            }
        }
        return best
    }

    // MARK: Candidate boxes

    private static func box(_ c: Curve, centredAt x: CGFloat, plot: CGRect) -> CGRect {
        let minX = min(max(plot.minX + 2, x - c.size.width / 2), plot.maxX - 2 - c.size.width)
        return CGRect(x: minX, y: 0, width: c.size.width, height: c.size.height)
    }

    private static func above(_ c: Curve, at x: CGFloat, plot: CGRect, avoid: [Curve]) -> CGRect? {
        var r = box(c, centredAt: x, plot: plot)
        guard let ext = extent(c.points, r.minX, r.maxX) else { return nil }
        r.origin.y = ext.min - clearance - r.height
        return valid(r, plot: plot, avoid: avoid)
    }

    private static func under(_ c: Curve, at x: CGFloat, plot: CGRect, avoid: [Curve]) -> CGRect? {
        var r = box(c, centredAt: x, plot: plot)
        guard let ext = extent(c.points, r.minX, r.maxX) else { return nil }
        r.origin.y = ext.max + clearance
        return valid(r, plot: plot, avoid: avoid)
    }

    private static func below(_ c: Curve, at x: CGFloat, plot: CGRect, avoid: [Curve]) -> CGRect? {
        under(c, at: x, plot: plot, avoid: avoid)
    }

    private static func over(_ c: Curve, at x: CGFloat, plot: CGRect, avoid: [Curve]) -> CGRect? {
        above(c, at: x, plot: plot, avoid: avoid)
    }

    /// The box if it lies in the plot and clears the other curves.
    private static func valid(_ r: CGRect, plot: CGRect, avoid: [Curve]) -> CGRect? {
        guard r.minY >= plot.minY, r.maxY <= plot.maxY - 1 else { return nil }
        for c in avoid {
            guard let ext = extent(c.points, r.minX, r.maxX) else { continue }
            if ext.max >= r.minY - 2 && ext.min <= r.maxY + 2 { return nil }
        }
        return r
    }

    /// The highest (min) and lowest (max) y of a curve over [x0, x1].
    static func extent(_ points: [CGPoint], _ x0: CGFloat, _ x1: CGFloat) -> (min: CGFloat, max: CGFloat)? {
        var ys = points.filter { $0.x >= x0 && $0.x <= x1 }.map(\.y)
        if let a = y(of: points, at: x0) { ys.append(a) }
        if let b = y(of: points, at: x1) { ys.append(b) }
        guard let lo = ys.min(), let hi = ys.max() else { return nil }
        return (lo, hi)
    }

    /// The curve's y at x by linear interpolation, nil outside it.
    static func y(of points: [CGPoint], at x: CGFloat) -> CGFloat? {
        guard let first = points.first, let last = points.last, x >= first.x - 0.01, x <= last.x + 0.01 else { return nil }
        guard let i = points.firstIndex(where: { $0.x >= x }) else { return last.y }
        if i == 0 { return points[0].y }
        let a = points[i - 1], b = points[i]
        let t = (x - a.x) / max(1e-9, b.x - a.x)
        return a.y + t * (b.y - a.y)
    }
}
