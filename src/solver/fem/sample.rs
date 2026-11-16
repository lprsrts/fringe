//! Evaluation of the FEM solution on the output grid.
//!
//! A bucket grid over triangle bounding boxes finds candidates; straight triangles
//! are tested with affine barycentrics (tolerance 1e-9), curved ones by Newton on
//! the isoparametric map (≤ 4 iterations, from the affine guess). If nothing
//! contains the point (sliver gaps along curved boundaries, PEC holes), the nearest
//! candidate is used with its reference coordinates clamped to the triangle.

#![allow(clippy::needless_range_loop)]

use rayon::prelude::*;

use crate::solver::field::GridSpec;
use crate::solver::SolveContext;
use crate::types::{Rect, Vec2, C64};

use super::assemble::Dofs;
use super::element::{RefElement, MAX_NODES};
use super::mesh::Mesh;

struct Buckets {
    x0: f64,
    y0: f64,
    cell: f64,
    nx: usize,
    ny: usize,
    start: Vec<u32>,
    items: Vec<u32>,
}

impl Buckets {
    fn build(bboxes: &[Rect], domain: Rect, cell: f64) -> Buckets {
        let nx = ((domain.width() / cell).ceil() as usize).max(1);
        let ny = ((domain.height() / cell).ceil() as usize).max(1);
        let (x0, y0) = (domain.x_min, domain.y_min);
        let range = |b: &Rect| {
            let i0 = (((b.x_min - x0) / cell).floor().max(0.0) as usize).min(nx - 1);
            let i1 = (((b.x_max - x0) / cell).floor().max(0.0) as usize).min(nx - 1);
            let j0 = (((b.y_min - y0) / cell).floor().max(0.0) as usize).min(ny - 1);
            let j1 = (((b.y_max - y0) / cell).floor().max(0.0) as usize).min(ny - 1);
            (i0, i1, j0, j1)
        };
        let mut count = vec![0u32; nx * ny + 1];
        for b in bboxes {
            let (i0, i1, j0, j1) = range(b);
            for j in j0..=j1 {
                for i in i0..=i1 {
                    count[j * nx + i + 1] += 1;
                }
            }
        }
        for k in 0..nx * ny {
            count[k + 1] += count[k];
        }
        let mut next = count.clone();
        let mut items = vec![0u32; count[nx * ny] as usize];
        for (t, b) in bboxes.iter().enumerate() {
            let (i0, i1, j0, j1) = range(b);
            for j in j0..=j1 {
                for i in i0..=i1 {
                    let c = j * nx + i;
                    items[next[c] as usize] = t as u32;
                    next[c] += 1;
                }
            }
        }
        Buckets { x0, y0, cell, nx, ny, start: count, items }
    }

    fn get(&self, q: Vec2) -> &[u32] {
        let i = ((q.x - self.x0) / self.cell).floor();
        let j = ((q.y - self.y0) / self.cell).floor();
        if i < 0.0 || j < 0.0 || i as usize >= self.nx || j as usize >= self.ny {
            return &[];
        }
        let c = j as usize * self.nx + i as usize;
        &self.items[self.start[c] as usize..self.start[c + 1] as usize]
    }
}

/// Distance of reference coordinates outside the reference triangle (0 inside).
#[inline]
fn outside(xi: [f64; 2]) -> f64 {
    let l = [1.0 - xi[0] - xi[1], xi[0], xi[1]];
    l.iter().map(|&v| (-v).max(0.0)).sum()
}

/// Projects reference coordinates onto the reference triangle.
fn clamp_ref(xi: [f64; 2]) -> [f64; 2] {
    let mut a = xi[0].max(0.0);
    let mut b = xi[1].max(0.0);
    let s = a + b;
    if s > 1.0 {
        a /= s;
        b /= s;
    }
    [a, b]
}

pub fn sample(mesh: &Mesh, el: &RefElement, dofs: &Dofs, u: &[C64], grid: &GridSpec, ctx: &SolveContext) -> Vec<C64> {
    let n = el.n;
    let nt = mesh.tris.len();
    let geom = |t: usize| -> [Vec2; MAX_NODES] {
        let mut x = [Vec2::ZERO; MAX_NODES];
        for k in 0..n {
            x[k] = dofs.pos[dofs.elem[t][k] as usize];
        }
        x
    };
    let bboxes: Vec<Rect> = (0..nt)
        .into_par_iter()
        .map(|t| {
            let x = geom(t);
            let b = x[..n].iter().fold(Rect::EMPTY, |r, &q| r.include(q));
            b.expand(1e-9 * (b.width() + b.height()))
        })
        .collect();
    let domain = bboxes.iter().fold(Rect::EMPTY, |r, b| r.union(b));
    let buckets = Buckets::build(&bboxes, domain, 2.0 * mesh.h_b);

    // Affine reference coordinates of q in triangle t.
    let affine = |t: usize, q: Vec2| -> [f64; 2] {
        let tr = mesh.tris[t];
        let a = mesh.verts[tr[0] as usize];
        let e1 = mesh.verts[tr[1] as usize] - a;
        let e2 = mesh.verts[tr[2] as usize] - a;
        let d = q - a;
        let det = e1.cross(e2);
        [d.cross(e2) / det, e1.cross(d) / det]
    };
    let newton = |t: usize, q: Vec2, x: &[Vec2; MAX_NODES]| -> [f64; 2] {
        let mut xi = affine(t, q);
        for _ in 0..4 {
            let b = el.eval(xi);
            let mut m = Vec2::ZERO;
            let mut j = [[0.0; 2]; 2];
            for k in 0..n {
                m += x[k] * b.phi[k];
                j[0][0] += x[k].x * b.dphi[k][0];
                j[0][1] += x[k].x * b.dphi[k][1];
                j[1][0] += x[k].y * b.dphi[k][0];
                j[1][1] += x[k].y * b.dphi[k][1];
            }
            let r = q - m;
            let det = j[0][0] * j[1][1] - j[0][1] * j[1][0];
            let dx = (j[1][1] * r.x - j[0][1] * r.y) / det;
            let dy = (-j[1][0] * r.x + j[0][0] * r.y) / det;
            xi = [xi[0] + dx, xi[1] + dy];
            if dx.abs() + dy.abs() < 1e-13 {
                break;
            }
        }
        xi
    };
    let eval = |t: usize, xi: [f64; 2]| -> C64 {
        let b = el.eval(xi);
        let g = &dofs.elem[t];
        (0..n).map(|k| u[g[k] as usize] * b.phi[k]).sum()
    };

    let mut out = vec![C64::new(0.0, 0.0); grid.len()];
    out.par_chunks_mut(grid.nx).enumerate().for_each(|(j, row)| {
        if ctx.is_cancelled() {
            return;
        }
        for (i, v) in row.iter_mut().enumerate() {
            let q = grid.point(i, j);
            let mut best: Option<(f64, usize, [f64; 2])> = None;
            let mut found = None;
            for &t in buckets.get(q) {
                let t = t as usize;
                if !bboxes[t].contains(q) && best.is_some() {
                    continue;
                }
                let xi = if dofs.curved[t] {
                    let x = geom(t);
                    newton(t, q, &x)
                } else {
                    affine(t, q)
                };
                let o = outside(xi);
                if o <= 1e-9 {
                    found = Some((t, xi));
                    break;
                }
                if best.is_none_or(|b| o < b.0) {
                    best = Some((o, t, xi));
                }
            }
            *v = match (found, best) {
                (Some((t, xi)), _) => eval(t, xi),
                (None, Some((_, t, xi))) => eval(t, clamp_ref(xi)),
                (None, None) => C64::new(0.0, 0.0),
            };
        }
    });
    out
}
