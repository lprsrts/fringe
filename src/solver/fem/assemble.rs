//! Degrees of freedom, isoparametric geometry and the sparse system (spec §5.2).
//!
//! Weak form (complex symmetric, no conjugation): find u = E_s with
//! `∫ (Λ∇u·∇v − k0² ε_r s u v) = ∫_bodies k0² (ε_r − ε_b) E_inc v`, u = 0 on the outer
//! boundary and u = −E_inc on PEC boundaries (lifted to the right-hand side).

#![allow(clippy::needless_range_loop)] // index-heavy element kernels

use std::collections::HashMap;

use rayon::prelude::*;

use crate::geometry::BodyMaterial;
use crate::linalg::SparseBuilder;
use crate::problem::Problem;
use crate::solver::{SolveContext, SolveError};
use crate::special::quadrature::triangle_rule;
use crate::types::{Rect, Vec2, C64};

use super::element::{BasisAt, RefElement, EDGES, MAX_NODES};
use super::mesh::{Mesh, BACKGROUND};
use super::pml::{Pml, Stretch};

const NONE: u32 = u32::MAX;

/// Global numbering: vertices, then p − 1 nodes per edge (ordered from the lower
/// vertex index), then the face nodes of each triangle.
pub struct Dofs {
    pub n: usize,
    /// Local → global DOF per triangle, in reference-node order.
    pub elem: Vec<[u32; MAX_NODES]>,
    /// Position of every DOF (the isoparametric geometric nodes).
    pub pos: Vec<Vec2>,
    /// Whether each triangle has a curved edge.
    pub curved: Vec<bool>,
    /// Dirichlet value of each DOF (`None` for free DOFs).
    pub dirichlet: Vec<Option<C64>>,
    /// Free index of each DOF, or `u32::MAX` for Dirichlet and face DOFs.
    pub free: Vec<u32>,
    /// First face DOF; face DOFs are eliminated by static condensation.
    pub face0: usize,
    pub n_free: usize,
}

pub fn number_dofs(p: &Problem, mesh: &Mesh, el: &RefElement) -> Dofs {
    let ord = el.order;
    let ne = el.edge_nodes();
    let nf = el.face_nodes();
    let nv = mesh.verts.len();
    let nt = mesh.tris.len();

    // Edges.
    let mut edge_id: HashMap<(u32, u32), u32> = HashMap::with_capacity(nt * 2);
    let mut edge_ends: Vec<(u32, u32)> = Vec::with_capacity(nt * 2);
    let mut edge_count: Vec<u8> = Vec::with_capacity(nt * 2);
    let mut tri_edges: Vec<[u32; 3]> = Vec::with_capacity(nt);
    for t in &mesh.tris {
        let mut te = [0u32; 3];
        for (k, e) in EDGES.iter().enumerate() {
            let (a, b) = (t[e[0]], t[e[1]]);
            let key = (a.min(b), a.max(b));
            let id = *edge_id.entry(key).or_insert_with(|| {
                edge_ends.push(key);
                edge_count.push(0);
                (edge_ends.len() - 1) as u32
            });
            edge_count[id as usize] += 1;
            te[k] = id;
        }
        tri_edges.push(te);
    }
    let n_edges = edge_ends.len();
    let n = nv + n_edges * ne + nt * nf;

    // Positions.
    let mut pos = vec![Vec2::ZERO; n];
    pos[..nv].copy_from_slice(&mesh.verts);
    let mut edge_curved = vec![false; n_edges];
    for (e, &(lo, hi)) in edge_ends.iter().enumerate() {
        let (a, b) = (mesh.verts[lo as usize], mesh.verts[hi as usize]);
        let arc = mesh.arcs.get(&(lo, hi));
        edge_curved[e] = arc.is_some();
        for k in 0..ne {
            let f = (k + 1) as f64 / ord as f64;
            pos[nv + e * ne + k] = match arc {
                Some(r) => {
                    let seg = &p.bodies[r.body as usize].contour.segments[r.seg as usize];
                    seg.point(r.t_lo + f * (r.t_hi - r.t_lo))
                }
                None => a.lerp(b, f),
            };
        }
    }

    // Element maps.
    let face0 = nv + n_edges * ne;
    let mut elem = vec![[NONE; MAX_NODES]; nt];
    let mut curved = vec![false; nt];
    for (ti, t) in mesh.tris.iter().enumerate() {
        let m = &mut elem[ti];
        m[..3].copy_from_slice(t);
        for (k, e) in EDGES.iter().enumerate() {
            let id = tri_edges[ti][k] as usize;
            curved[ti] |= edge_curved[id];
            let forward = t[e[0]] < t[e[1]];
            for i in 1..ord {
                let g = if forward { i - 1 } else { ord - 1 - i };
                m[3 + k * ne + (i - 1)] = (nv + id * ne + g) as u32;
            }
        }
        for k in 0..nf {
            let g = face0 + ti * nf + k;
            m[3 + 3 * ne + k] = g as u32;
            let v: Vec2 = (0..3).map(|q| mesh.verts[t[q] as usize]).fold(Vec2::ZERO, |s, x| s + x);
            pos[g] = if ord == 3 {
                // x_face = ¼ Σ edge nodes − ⅙ Σ vertices (the centroid when straight).
                let es: Vec2 = (3..9).map(|q| pos[m[q] as usize]).fold(Vec2::ZERO, |s, x| s + x);
                es * 0.25 - v * (1.0 / 6.0)
            } else {
                let xi = el.nodes[3 + 3 * ne + k];
                let [a, b, c] = [0, 1, 2].map(|q| mesh.verts[t[q] as usize]);
                a + (b - a) * xi[0] + (c - a) * xi[1]
            };
        }
    }

    // Dirichlet DOFs: everything on a boundary edge (an edge with one triangle).
    // On the outer rectangle u = 0; on PEC holes u = −E_inc.
    let outer = p.outer();
    let tol = 1e-9 * outer.diag();
    let on_outer = |q: Vec2| {
        (q.x - outer.x_min).abs() < tol
            || (q.x - outer.x_max).abs() < tol
            || (q.y - outer.y_min).abs() < tol
            || (q.y - outer.y_max).abs() < tol
    };
    let mut is_dir = vec![false; n];
    // Vertices no kept triangle uses (inside PEC holes) are not unknowns.
    let mut used = vec![false; nv];
    for t in &mesh.tris {
        for &v in t {
            used[v as usize] = true;
        }
    }
    for (e, &(lo, hi)) in edge_ends.iter().enumerate() {
        if edge_count[e] == 1 {
            is_dir[lo as usize] = true;
            is_dir[hi as usize] = true;
            for k in 0..ne {
                is_dir[nv + e * ne + k] = true;
            }
        }
    }
    for (v, &u) in used.iter().enumerate() {
        if !u {
            is_dir[v] = true;
        }
    }
    let pec_nodes: Vec<usize> = (0..n).filter(|&i| is_dir[i] && (i >= nv || used[i]) && !on_outer(pos[i])).collect();
    let pec_pts: Vec<Vec2> = pec_nodes.iter().map(|&i| pos[i]).collect();
    let pec_vals = p.incident.eval_points(&pec_pts);
    let mut dirichlet: Vec<Option<C64>> = is_dir.iter().map(|&d| if d { Some(C64::new(0.0, 0.0)) } else { None }).collect();
    for (&i, v) in pec_nodes.iter().zip(pec_vals) {
        dirichlet[i] = Some(-v);
    }
    // Face (interior) DOFs are condensed out element by element, so the global
    // system has only vertex and edge unknowns.
    let mut free = vec![NONE; n];
    let mut n_free = 0usize;
    for i in 0..face0 {
        if !is_dir[i] {
            free[i] = n_free as u32;
            n_free += 1;
        }
    }
    Dofs { n, elem, pos, curved, dirichlet, free, face0, n_free }
}

/// Basis tables at the quadrature points of one rule.
struct Tables {
    w: Vec<f64>,
    b: Vec<BasisAt>,
}

fn tables(el: &RefElement, degree: usize) -> Tables {
    let r = triangle_rule(degree);
    Tables { w: r.weights.clone(), b: r.points.iter().map(|&x| el.eval(x)).collect() }
}

/// Jacobian [[∂x/∂ξ, ∂x/∂η], [∂y/∂ξ, ∂y/∂η]] of the geometric map.
#[inline]
fn jacobian(x: &[Vec2; MAX_NODES], n: usize, b: &BasisAt) -> [[f64; 2]; 2] {
    let mut j = [[0.0; 2]; 2];
    for k in 0..n {
        let d = b.dphi[k];
        j[0][0] += x[k].x * d[0];
        j[0][1] += x[k].x * d[1];
        j[1][0] += x[k].y * d[0];
        j[1][1] += x[k].y * d[1];
    }
    j
}

#[inline]
fn map_point(x: &[Vec2; MAX_NODES], n: usize, b: &BasisAt) -> Vec2 {
    let mut q = Vec2::ZERO;
    for k in 0..n {
        q += x[k] * b.phi[k];
    }
    q
}

/// Reference integrals for straight elements outside the PML:
/// `S[a][b][i][j] = ∫ ∂_a φ_i ∂_b φ_j` and `M[i][j] = ∫ φ_i φ_j` on the reference triangle.
struct RefMatrices {
    s: [[[[f64; MAX_NODES]; MAX_NODES]; 2]; 2],
    m: [[f64; MAX_NODES]; MAX_NODES],
}

fn ref_matrices(el: &RefElement, t: &Tables) -> RefMatrices {
    let mut r = RefMatrices { s: [[[[0.0; MAX_NODES]; MAX_NODES]; 2]; 2], m: [[0.0; MAX_NODES]; MAX_NODES] };
    let n = el.n;
    for (w, b) in t.w.iter().zip(&t.b) {
        for i in 0..n {
            for j in 0..n {
                r.m[i][j] += w * b.phi[i] * b.phi[j];
                for a in 0..2 {
                    for c in 0..2 {
                        r.s[a][c][i][j] += w * b.dphi[i][a] * b.dphi[j][c];
                    }
                }
            }
        }
    }
    r
}

pub struct System {
    pub matrix: SparseBuilder,
    pub rhs: Vec<C64>,
    /// Per triangle, for recovering its face DOFs after the solve:
    /// `u_f = (g_f − Σ_j c_fj u_j)/a_ff` with the row `[c_f0 … c_f,ns−1, a_ff, g_f]`
    /// stored for each face DOF (P3 has one).
    pub recovery: Vec<[C64; MAX_NODES + 2]>,
}

/// Fills in the face DOFs of `u` (whose other entries are final) from the
/// element rows kept by [`assemble`].
pub fn recover_faces(el: &RefElement, dofs: &Dofs, sys_recovery: &[[C64; MAX_NODES + 2]], u: &mut [C64]) {
    let nf = el.face_nodes();
    if nf == 0 {
        return;
    }
    debug_assert_eq!(nf, 1);
    let ns = el.n - nf;
    let vals: Vec<C64> = sys_recovery
        .par_iter()
        .enumerate()
        .map(|(t, r)| {
            let g = &dofs.elem[t];
            let mut acc = r[ns + 1];
            for j in 0..ns {
                acc -= r[j] * u[g[j] as usize];
            }
            acc / r[ns]
        })
        .collect();
    for (t, v) in vals.into_iter().enumerate() {
        u[dofs.elem[t][ns] as usize] = v;
    }
}

/// Assembles the free-DOF system with Dirichlet lifting.
pub fn assemble(p: &Problem, mesh: &Mesh, el: &RefElement, dofs: &Dofs, ctx: &SolveContext) -> Result<System, SolveError> {
    let order = el.order;
    let (mat_deg, load_deg) = match order {
        1 => (2, 4),
        2 => (4, 6),
        _ => (6, 8),
    };
    let tm = tables(el, mat_deg);
    let tl = tables(el, load_deg);
    let refm = ref_matrices(el, &tm);
    let n = el.n;
    let nf = el.face_nodes();
    assert!(nf <= 1, "static condensation supports one face node");
    let k0sq = p.k0 * p.k0;
    let eps_b = C64::new(p.eps_b, 0.0);
    let pml = Pml::new(p.interior, p.pml_um, p.settings.fem.pml_reflection, p.k_b);
    let eps_of = |t: usize| -> C64 {
        match mesh.tri_body[t] {
            BACKGROUND => eps_b,
            b => match p.bodies[b as usize].material {
                BodyMaterial::Dielectric { eps, .. } => eps,
                BodyMaterial::Pec => eps_b,
            },
        }
    };
    let geom = |t: usize| -> [Vec2; MAX_NODES] {
        let mut x = [Vec2::ZERO; MAX_NODES];
        for k in 0..n {
            x[k] = dofs.pos[dofs.elem[t][k] as usize];
        }
        x
    };
    let interior: Rect = p.interior;

    // Incident field at the load quadrature points of every source element.
    let load_elems: Vec<usize> = (0..mesh.tris.len()).filter(|&t| (eps_of(t) - eps_b).norm() > 0.0).collect();
    let nql = tl.w.len();
    let load_pts: Vec<Vec2> = load_elems
        .par_iter()
        .flat_map_iter(|&t| {
            let x = geom(t);
            tl.b.iter().map(move |b| map_point(&x, n, b)).collect::<Vec<_>>()
        })
        .collect();
    let load_inc = p.incident.eval_points(&load_pts);
    let mut load_slot = vec![NONE; mesh.tris.len()];
    for (s, &t) in load_elems.iter().enumerate() {
        load_slot[t] = s as u32;
    }
    ctx.checkpoint()?;

    const CHUNK: usize = 2048;
    let nt = mesh.tris.len();
    let n_chunks = nt.div_ceil(CHUNK).max(1);
    let done = std::sync::atomic::AtomicUsize::new(0);
    #[allow(clippy::type_complexity)]
    let parts: Vec<Option<(SparseBuilder, Vec<(u32, C64)>, Vec<[C64; MAX_NODES + 2]>)>> = (0..n_chunks)
        .into_par_iter()
        .map(|c| {
            if ctx.is_cancelled() {
                return None;
            }
            let mut sb = SparseBuilder::new(dofs.n_free);
            sb.reserve(CHUNK.min(nt) * n * n);
            let mut rhs: Vec<(u32, C64)> = Vec::new();
            let mut recs: Vec<[C64; MAX_NODES + 2]> = Vec::with_capacity(CHUNK);
            for t in c * CHUNK..((c + 1) * CHUNK).min(nt) {
                let x = geom(t);
                let eps = eps_of(t);
                let mut a = [[C64::new(0.0, 0.0); MAX_NODES]; MAX_NODES];
                let bb = x[..n].iter().fold(Rect::EMPTY, |r, &q| r.include(q));
                let in_pml = !(interior.contains(Vec2::new(bb.x_min, bb.y_min))
                    && interior.contains(Vec2::new(bb.x_max, bb.y_max)));
                if !dofs.curved[t] && !in_pml {
                    // Affine element: constant Jacobian.
                    let j = jacobian(&x, n, &tm.b[0]);
                    let det = j[0][0] * j[1][1] - j[0][1] * j[1][0];
                    let inv = [[j[1][1] / det, -j[0][1] / det], [-j[1][0] / det, j[0][0] / det]];
                    // ∇φ = J⁻ᵀ ∇̂φ, so ∇φ_i·∇φ_j = Σ_ab G_ab ∂_a φ̂_i ∂_b φ̂_j with G = J⁻¹ J⁻ᵀ.
                    let mut g = [[0.0; 2]; 2];
                    for (ga, ia) in g.iter_mut().zip(&inv) {
                        for (gab, ib) in ga.iter_mut().zip(&inv) {
                            *gab = ia[0] * ib[0] + ia[1] * ib[1];
                        }
                    }
                    let ad = det.abs();
                    let km = k0sq * eps;
                    for i in 0..n {
                        for jj in 0..n {
                            let mut s = 0.0;
                            for aa in 0..2 {
                                for cc in 0..2 {
                                    s += g[aa][cc] * refm.s[aa][cc][i][jj];
                                }
                            }
                            a[i][jj] = C64::new(ad * s, 0.0) - km * (ad * refm.m[i][jj]);
                        }
                    }
                } else {
                    for (w, b) in tm.w.iter().zip(&tm.b) {
                        let j = jacobian(&x, n, b);
                        let det = j[0][0] * j[1][1] - j[0][1] * j[1][0];
                        let inv = [[j[1][1] / det, -j[0][1] / det], [-j[1][0] / det, j[0][0] / det]];
                        let st = if in_pml { pml.at(map_point(&x, n, b)) } else { Stretch::IDENTITY };
                        let wd = w * det.abs();
                        let mut gx = [0.0; MAX_NODES];
                        let mut gy = [0.0; MAX_NODES];
                        for k in 0..n {
                            let d = b.dphi[k];
                            // J⁻ᵀ d: column k of inv is the row of J⁻ᵀ.
                            gx[k] = inv[0][0] * d[0] + inv[1][0] * d[1];
                            gy[k] = inv[0][1] * d[0] + inv[1][1] * d[1];
                        }
                        let lxx = st.lxx * wd;
                        let lyy = st.lyy * wd;
                        let ms = st.s * eps * (k0sq * wd);
                        for i in 0..n {
                            for jj in i..n {
                                let v = lxx * (gx[i] * gx[jj]) + lyy * (gy[i] * gy[jj]) - ms * (b.phi[i] * b.phi[jj]);
                                a[i][jj] += v;
                            }
                        }
                    }
                    for i in 0..n {
                        for jj in 0..i {
                            a[i][jj] = a[jj][i];
                        }
                    }
                }

                // Load.
                let mut f = [C64::new(0.0, 0.0); MAX_NODES];
                let slot = load_slot[t];
                if slot != NONE {
                    let base = slot as usize * nql;
                    let c = (eps - eps_b) * k0sq;
                    for (q, (w, b)) in tl.w.iter().zip(&tl.b).enumerate() {
                        let j = jacobian(&x, n, b);
                        let det = (j[0][0] * j[1][1] - j[0][1] * j[1][0]).abs();
                        let v = c * load_inc[base + q] * (w * det);
                        for i in 0..n {
                            f[i] += v * b.phi[i];
                        }
                    }
                }

                // Static condensation of the face DOF (P3): the global system keeps
                // the first ns local DOFs.
                let ns = n - nf;
                let mut rec = [C64::new(0.0, 0.0); MAX_NODES + 2];
                if nf == 1 {
                    let aff = a[ns][ns];
                    for i in 0..ns {
                        let s = a[i][ns] / aff;
                        for jj in 0..ns {
                            a[i][jj] -= s * a[ns][jj];
                        }
                        f[i] -= s * f[ns];
                    }
                    rec[..ns].copy_from_slice(&a[ns][..ns]);
                    rec[ns] = aff;
                    rec[ns + 1] = f[ns];
                }
                recs.push(rec);

                let g = &dofs.elem[t];
                for i in 0..ns {
                    let fi = dofs.free[g[i] as usize];
                    if fi == NONE {
                        continue;
                    }
                    let mut r = f[i];
                    for jj in 0..ns {
                        let gj = g[jj] as usize;
                        let fj = dofs.free[gj];
                        if fj == NONE {
                            if let Some(ud) = dofs.dirichlet[gj] {
                                if ud.re != 0.0 || ud.im != 0.0 {
                                    r -= a[i][jj] * ud;
                                }
                            }
                        } else {
                            sb.add(fi as usize, fj as usize, a[i][jj]);
                        }
                    }
                    if r.re != 0.0 || r.im != 0.0 {
                        rhs.push((fi, r));
                    }
                }
            }
            let d = done.fetch_add(1, std::sync::atomic::Ordering::Relaxed) + 1;
            ctx.report(d as f64 / n_chunks as f64);
            Some((sb, rhs, recs))
        })
        .collect();
    ctx.checkpoint()?;

    let mut matrix = SparseBuilder::new(dofs.n_free);
    let total: usize = parts.iter().map(|p| p.as_ref().map_or(0, |x| x.0.len())).sum();
    matrix.reserve(total);
    let mut rhs = vec![C64::new(0.0, 0.0); dofs.n_free];
    let mut recovery = Vec::with_capacity(nt);
    for part in parts.into_iter().flatten() {
        matrix.extend(part.0);
        for (i, v) in part.1 {
            rhs[i as usize] += v;
        }
        recovery.extend(part.2);
    }
    Ok(System { matrix, rhs, recovery })
}
