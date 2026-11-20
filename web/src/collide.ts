// Keeps a dragged element clear of the others. The core rejects bodies closer
// than 0.05 λ (and overlaps), and solving stops until that is undone, so a
// move, rotation or resize advances only as far as the shape stays clear.
//
// The dragged body's outline is predicted, not recomputed: the core places a
// shape by rotating its local contour about the element's anchor and then
// translating it, and a resize scales every length of the shape, so a move,
// rotation or uniform scale of the outline captured at the drag's start is
// exactly the outline the core would produce.

export type Pt = [number, number];
export type Poly = Pt[];

function segIntersect(a: Pt, b: Pt, c: Pt, d: Pt): boolean {
  const o = (p: Pt, q: Pt, r: Pt) => (q[0] - p[0]) * (r[1] - p[1]) - (q[1] - p[1]) * (r[0] - p[0]);
  const d1 = o(c, d, a), d2 = o(c, d, b), d3 = o(a, b, c), d4 = o(a, b, d);
  return d1 * d2 < 0 && d3 * d4 < 0;
}

function pointSeg(p: Pt, a: Pt, b: Pt): number {
  const dx = b[0] - a[0], dy = b[1] - a[1];
  const len2 = dx * dx + dy * dy;
  const t = len2 > 0 ? Math.max(0, Math.min(1, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / len2)) : 0;
  return Math.hypot(p[0] - (a[0] + t * dx), p[1] - (a[1] + t * dy));
}

function inside(p: Pt, poly: Poly): boolean {
  let hit = false;
  for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    const [xi, yi] = poly[i], [xj, yj] = poly[j];
    if (yi > p[1] !== yj > p[1] && p[0] < ((xj - xi) * (p[1] - yi)) / (yj - yi + 1e-18) + xi) hit = !hit;
  }
  return hit;
}

interface Box {
  x0: number;
  x1: number;
  y0: number;
  y1: number;
}

const boxOf = (p: Poly): Box => {
  let x0 = Infinity, x1 = -Infinity, y0 = Infinity, y1 = -Infinity;
  for (const [x, y] of p) {
    if (x < x0) x0 = x;
    if (x > x1) x1 = x;
    if (y < y0) y0 = y;
    if (y > y1) y1 = y;
  }
  return {x0, x1, y0, y1};
};

/** True when two closed polygons overlap or come closer than `gap`. */
function tooClose(a: Poly, ab: Box, b: Poly, bb: Box, gap: number): boolean {
  if (ab.x0 > bb.x1 + gap || bb.x0 > ab.x1 + gap || ab.y0 > bb.y1 + gap || bb.y0 > ab.y1 + gap) return false;
  if (inside(a[0], b) || inside(b[0], a)) return true;
  for (let i = 0; i < a.length; i++) {
    const a0 = a[i], a1 = a[(i + 1) % a.length];
    for (let j = 0; j < b.length; j++) {
      const b0 = b[j], b1 = b[(j + 1) % b.length];
      if (segIntersect(a0, a1, b0, b1)) return true;
      if (
        pointSeg(a0, b0, b1) < gap ||
        pointSeg(a1, b0, b1) < gap ||
        pointSeg(b0, a0, a1) < gap ||
        pointSeg(b1, a0, a1) < gap
      )
        return true;
    }
  }
  return false;
}

export interface Pose {
  dx: number;
  dy: number;
  /** Rotation added, in degrees (counter-clockwise, about the anchor). */
  dRot: number;
  /** Uniform scale about the anchor. */
  k: number;
}

export class Clearance {
  private others: {poly: Poly; box: Box}[];
  /** False while the drag started in a collision: then nothing is blocked until the shape is clear once. */
  private active: boolean;

  constructor(
    private self: Poly[],
    others: Poly[],
    private anchor: Pt,
    private gap: number,
  ) {
    this.others = others.filter((p) => p.length > 2).map((poly) => ({poly, box: boxOf(poly)}));
    this.active = this.clear({dx: 0, dy: 0, dRot: 0, k: 1});
  }

  private place(pose: Pose): Poly[] {
    const [ax, ay] = this.anchor;
    const r = (pose.dRot * Math.PI) / 180;
    const c = Math.cos(r), s = Math.sin(r);
    return this.self.map((poly) =>
      poly.map(([x, y]) => {
        const ux = (x - ax) * pose.k, uy = (y - ay) * pose.k;
        return [ax + ux * c - uy * s + pose.dx, ay + ux * s + uy * c + pose.dy] as Pt;
      }),
    );
  }

  clear(pose: Pose): boolean {
    for (const poly of this.place(pose)) {
      if (poly.length < 3) continue;
      const box = boxOf(poly);
      for (const o of this.others) if (tooClose(poly, box, o.poly, o.box, this.gap)) return false;
    }
    return true;
  }

  private lerp(from: Pose, to: Pose, t: number): Pose {
    return {
      dx: from.dx + (to.dx - from.dx) * t,
      dy: from.dy + (to.dy - from.dy) * t,
      dRot: from.dRot + (to.dRot - from.dRot) * t,
      k: from.k + (to.k - from.k) * t,
    };
  }

  /**
   * How far (0–1) the shape gets from `from` toward `to` before it first
   * touches a neighbour. The path is sampled finely enough not to skip over
   * the gap, so a fast drag can't tunnel through a neighbour to its far side.
   */
  private reach(from: Pose, to: Pose): number {
    const size = Math.max(...this.self.flat().map(([x, y]) => Math.hypot(x - this.anchor[0], y - this.anchor[1])), 1e-6);
    const travel = Math.max(
      Math.abs(to.dx - from.dx),
      Math.abs(to.dy - from.dy),
      (Math.abs(to.dRot - from.dRot) * Math.PI * size) / 180,
      Math.abs(to.k - from.k) * size,
    );
    const n = Math.min(64, Math.max(1, Math.ceil(travel / this.gap)));
    for (let i = 1; i <= n; i++) {
      if (this.clear(this.lerp(from, to, i / n))) continue;
      let lo = (i - 1) / n, hi = i / n;
      for (let j = 0; j < 10; j++) {
        const mid = (lo + hi) / 2;
        if (this.clear(this.lerp(from, to, mid))) lo = mid;
        else hi = mid;
      }
      return lo;
    }
    return 1;
  }

  /**
   * The pose to apply for a drag step from the last allowed pose `from` toward
   * `to`: `to` when the way there is clear; else, for `slide`, the nearer of
   * `to` with one axis held, so a move glides along a neighbour; else as far
   * as the shape gets before it touches.
   */
  limit(from: Pose, to: Pose, slide = false): Pose {
    if (!this.active) {
      if (this.clear(to)) this.active = true;
      return to;
    }
    const t = this.reach(from, to);
    if (t >= 1) return to;
    if (slide) {
      const options = [
        {...to, dy: from.dy},
        {...to, dx: from.dx},
      ]
        .filter((p) => p.dx !== from.dx || p.dy !== from.dy)
        .filter((p) => this.reach(from, p) >= 1);
      if (options.length) {
        const dist = (p: Pose) => Math.hypot(p.dx - to.dx, p.dy - to.dy);
        return options.sort((a, b) => dist(a) - dist(b))[0];
      }
    }
    return this.lerp(from, to, t);
  }
}
