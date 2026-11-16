//! Triangle mesh of the outer rectangle (interior + PML) by spade's constrained
//! Delaunay triangulation.
//!
//! 1. Constraints: the outer rectangle and the PML inner rectangle sampled at h_b,
//!    and every body contour with each segment split into ⌈len/h_bnd⌉ equal-parameter
//!    pieces (h_bnd = min(h inside, h outside); arcs also at most 30° per piece).
//!    Each constraint edge on an arc records (body, segment, t at both ends) so the
//!    elements along it can be made isoparametric.
//! 2. Seeds: an equilateral lattice at h_b over the outer rectangle (outside every
//!    body and ≥ 0.6 h_b from every constraint), and a lattice at h_i inside every
//!    dielectric body (≥ 0.6 h_i from its contour).
//! 3. Bulk CDT, then Ruppert refinement with a 25° angle limit that keeps
//!    constraint edges whole, capped at 50 % more vertices. If refinement does not
//!    complete, the unrefined mesh is kept and a warning is added.
//! 4. Triangles are tagged by the body containing their centroid; triangles inside
//!    PEC bodies are dropped (PEC bodies are holes).

use std::collections::HashMap;

use rayon::prelude::*;
use spade::{AngleLimit, ConstrainedDelaunayTriangulation, Point2, RefinementParameters, Triangulation};

use crate::geometry::{BodyMaterial, Segment};
use crate::problem::Problem;
use crate::solver::SolveError;
use crate::types::{Rect, Vec2};

/// Tag of background triangles in [`Mesh::tri_body`].
pub const BACKGROUND: u32 = u32::MAX;

/// Position of a constraint edge on a body's arc segment.
#[derive(Clone, Copy, Debug)]
pub struct ArcRef {
    pub body: u32,
    pub seg: u32,
    /// Arc parameter at the lower-indexed vertex of the edge.
    pub t_lo: f64,
    /// Arc parameter at the higher-indexed vertex.
    pub t_hi: f64,
}

#[derive(Clone, Debug)]
pub struct Mesh {
    pub verts: Vec<Vec2>,
    /// Counter-clockwise vertex triples; PEC interiors removed.
    pub tris: Vec<[u32; 3]>,
    /// Body index of each triangle, or [`BACKGROUND`].
    pub tri_body: Vec<u32>,
    /// Constraint edges on arcs, keyed by (lower, higher) vertex index.
    pub arcs: HashMap<(u32, u32), ArcRef>,
    /// Background element size.
    pub h_b: f64,
    pub warnings: Vec<String>,
    /// Vertices refinement added (diagnostics for the mesh tests).
    #[cfg_attr(not(test), allow(dead_code))]
    pub refined_vertices: usize,
}

/// Mesh size inside body `b`, or `None` for PEC: `p · λ_region / ppw`.
pub fn body_h(p: &Problem, b: usize, order: f64) -> Option<f64> {
    match p.bodies[b].material {
        BodyMaterial::Pec => None,
        BodyMaterial::Dielectric { n, .. } => Some(order * p.lambda0 / n.re.max(1e-3) / p.settings.ppw),
    }
}

pub fn background_h(p: &Problem, order: f64) -> f64 {
    order * p.lambda_b() / p.settings.ppw
}

/// Distance from `p` to the boundary of rectangle `r` (inside or outside).
fn rect_boundary_distance(r: &Rect, p: Vec2) -> f64 {
    if r.contains(p) {
        (p.x - r.x_min).min(r.x_max - p.x).min(p.y - r.y_min).min(r.y_max - p.y)
    } else {
        r.distance_to(p)
    }
}

/// Equilateral lattice points with spacing h covering `r`, shifted by `off`.
fn lattice(r: &Rect, h: f64, off: Vec2) -> Vec<Vec2> {
    let dy = h * 3f64.sqrt() / 2.0;
    let ny = ((r.height() - off.y) / dy).floor().max(-1.0) as i64 + 1;
    let mut pts = Vec::new();
    for j in 0..ny.max(0) {
        let y = r.y_min + off.y + j as f64 * dy;
        let x0 = r.x_min + off.x + if j % 2 == 1 { 0.5 * h } else { 0.0 };
        let nx = ((r.x_max - x0) / h).floor().max(-1.0) as i64 + 1;
        for i in 0..nx.max(0) {
            pts.push(Vec2::new(x0 + i as f64 * h, y));
        }
    }
    pts
}

/// (body, segment, t_from, t_to) of a constraint edge on an arc.
type ArcPiece = (u32, u32, f64, f64);

struct Constraints {
    pts: Vec<Vec2>,
    edges: Vec<[usize; 2]>,
    /// For each edge: (body, segment, t_from, t_to) when it lies on an arc.
    arc: Vec<Option<ArcPiece>>,
}

impl Constraints {
    fn add_rect(&mut self, r: &Rect, h: f64) {
        let c = [
            Vec2::new(r.x_min, r.y_min),
            Vec2::new(r.x_max, r.y_min),
            Vec2::new(r.x_max, r.y_max),
            Vec2::new(r.x_min, r.y_max),
        ];
        let first = self.pts.len();
        for k in 0..4 {
            let (a, b) = (c[k], c[(k + 1) % 4]);
            let n = ((a.dist(b) / h).ceil() as usize).max(1);
            for i in 0..n {
                self.pts.push(a.lerp(b, i as f64 / n as f64));
            }
        }
        self.close_loop(first, None);
    }

    /// Connects points first..end in a loop with plain (non-arc) edges unless
    /// `arcs` gives per-edge arc info.
    fn close_loop(&mut self, first: usize, arcs: Option<Vec<Option<ArcPiece>>>) {
        let end = self.pts.len();
        for i in first..end {
            let j = if i + 1 == end { first } else { i + 1 };
            self.edges.push([i, j]);
            self.arc.push(arcs.as_ref().and_then(|a| a[i - first]));
        }
    }
}

const MAX_ARC_PIECE: f64 = std::f64::consts::PI / 6.0;

/// Builds the mesh. `order` is the element order p (the sizes are p·λ/ppw).
pub fn build(p: &Problem, order: usize) -> Result<Mesh, SolveError> {
    let pf = order as f64;
    let h_b = background_h(p, pf);
    let outer = p.outer();
    let interior = p.interior;
    let nb = p.bodies.len();
    let h_in: Vec<Option<f64>> = (0..nb).map(|b| body_h(p, b, pf)).collect();

    // 1. Constraints.
    let mut c = Constraints { pts: Vec::new(), edges: Vec::new(), arc: Vec::new() };
    c.add_rect(&outer, h_b);
    if p.pml_um > 0.0 {
        c.add_rect(&interior, h_b);
    }
    for (b, body) in p.bodies.iter().enumerate() {
        let h_bnd = h_in[b].map_or(h_b, |h| h.min(h_b));
        let first = c.pts.len();
        let mut info = Vec::new();
        for (s, seg) in body.contour.segments.iter().enumerate() {
            let mut n = ((seg.length() / h_bnd).ceil() as usize).max(1);
            let is_arc = matches!(seg, Segment::Arc { .. });
            if let Segment::Arc { sweep, .. } = *seg {
                n = n.max((sweep.abs() / MAX_ARC_PIECE).ceil() as usize);
            }
            for k in 0..n {
                let t0 = k as f64 / n as f64;
                let t1 = (k + 1) as f64 / n as f64;
                c.pts.push(seg.point(t0));
                info.push(if is_arc { Some((b as u32, s as u32, t0, t1)) } else { None });
            }
        }
        c.close_loop(first, Some(info));
    }
    let n_constraint_pts = c.pts.len();

    // 2. Seeds.
    let keep_bg = |q: Vec2| -> bool {
        if rect_boundary_distance(&outer, q) < 0.6 * h_b {
            return false;
        }
        if p.pml_um > 0.0 && rect_boundary_distance(&interior, q) < 0.6 * h_b {
            return false;
        }
        for body in &p.bodies {
            if body.bbox.expand(0.6 * h_b).contains(q) && body.contour.signed_distance(q) < 0.6 * h_b {
                return false;
            }
        }
        true
    };
    let bg: Vec<Vec2> = lattice(&outer, h_b, Vec2::new(0.5 * h_b, 0.5 * h_b))
        .into_par_iter()
        .filter(|&q| keep_bg(q))
        .collect();
    let mut seeds = bg;
    for (b, body) in p.bodies.iter().enumerate() {
        let Some(h) = h_in[b] else { continue };
        // Per-body offset: a fraction of h that differs between bodies.
        let f = 0.5 + 0.37 * ((b as f64 * 0.618_034) % 1.0 - 0.5);
        let inner: Vec<Vec2> = lattice(&body.bbox, h, Vec2::new(f * h, 0.5 * f * h))
            .into_par_iter()
            .filter(|&q| body.contour.signed_distance(q) <= -0.6 * h)
            .collect();
        seeds.extend(inner);
    }

    // 3. Triangulate and refine.
    let mut all: Vec<Point2<f64>> = Vec::with_capacity(c.pts.len() + seeds.len());
    all.extend(c.pts.iter().map(|q| Point2::new(q.x, q.y)));
    all.extend(seeds.iter().map(|q| Point2::new(q.x, q.y)));
    let n_input = all.len();
    let mut conflicts = 0usize;
    let cdt: ConstrainedDelaunayTriangulation<Point2<f64>> =
        ConstrainedDelaunayTriangulation::try_bulk_load_cdt(all, c.edges.clone(), |_| conflicts += 1)
            .map_err(|e| SolveError::Internal(format!("mesh triangulation failed: {e:?}")))?;
    if cdt.num_vertices() != n_input {
        return Err(SolveError::Internal(format!(
            "mesh triangulation merged {} duplicate points",
            n_input - cdt.num_vertices()
        )));
    }
    if conflicts > 0 {
        return Err(SolveError::Internal(format!("{conflicts} crossing constraint edges in the mesh")));
    }

    let mut warnings = Vec::new();
    let unrefined = cdt.clone();
    let mut cdt = cdt;
    let params = RefinementParameters::<f64>::new()
        .with_angle_limit(AngleLimit::from_deg(25.0))
        .keep_constraint_edges()
        .exclude_outer_faces(false)
        .with_max_additional_vertices(n_input / 2);
    let refined = std::panic::catch_unwind(std::panic::AssertUnwindSafe(move || {
        let r = cdt.refine(params);
        (cdt, r.refinement_complete)
    }));
    let cdt = match refined {
        Ok((cdt, true)) => cdt,
        Ok((_, false)) => {
            warnings.push("mesh refinement reached its vertex cap; using the unrefined mesh".to_string());
            unrefined
        }
        Err(_) => {
            warnings.push("mesh refinement failed; using the unrefined mesh".to_string());
            unrefined
        }
    };

    let mut verts = vec![Vec2::ZERO; cdt.num_vertices()];
    for v in cdt.vertices() {
        let q = v.position();
        verts[v.fix().index()] = Vec2::new(q.x, q.y);
    }
    let raw: Vec<[u32; 3]> = cdt
        .inner_faces()
        .map(|f| {
            let v = f.vertices();
            [v[0].fix().index() as u32, v[1].fix().index() as u32, v[2].fix().index() as u32]
        })
        .collect();
    drop(cdt);

    // 4. Tag by centroid; drop PEC interiors.
    let tags: Vec<u32> = raw
        .par_iter()
        .map(|t| {
            let ctr = (verts[t[0] as usize] + verts[t[1] as usize] + verts[t[2] as usize]) / 3.0;
            match p.body_at(ctr) {
                Some(b) => b as u32,
                None => BACKGROUND,
            }
        })
        .collect();
    let mut tris = Vec::with_capacity(raw.len());
    let mut tri_body = Vec::with_capacity(raw.len());
    for (t, tag) in raw.into_iter().zip(tags) {
        if tag != BACKGROUND && p.bodies[tag as usize].is_pec() {
            continue;
        }
        tris.push(t);
        tri_body.push(tag);
    }

    let mut arcs = HashMap::new();
    for (e, info) in c.edges.iter().zip(&c.arc) {
        if let Some((body, seg, t0, t1)) = *info {
            let (a, b) = (e[0] as u32, e[1] as u32);
            let r = if a < b {
                ArcRef { body, seg, t_lo: t0, t_hi: t1 }
            } else {
                ArcRef { body, seg, t_lo: t1, t_hi: t0 }
            };
            arcs.insert((a.min(b), a.max(b)), r);
        }
    }
    debug_assert!(c.edges.iter().all(|e| e[0] < n_constraint_pts && e[1] < n_constraint_pts));

    Ok(Mesh {
        refined_vertices: verts.len() - n_input,
        verts,
        tris,
        tri_body,
        arcs,
        h_b,
        warnings,
    })
}

/// Interior angles of a straight triangle, in degrees.
#[cfg(test)]
pub fn angles_deg(a: Vec2, b: Vec2, c: Vec2) -> [f64; 3] {
    let ang = |p: Vec2, q: Vec2, r: Vec2| {
        let u = q - p;
        let v = r - p;
        u.cross(v).abs().atan2(u.dot(v)).to_degrees()
    };
    [ang(a, b, c), ang(b, c, a), ang(c, a, b)]
}

/// Smallest interior angle over the mesh, in degrees.
#[cfg(test)]
pub fn min_angle_deg(m: &Mesh) -> f64 {
    m.tris
        .par_iter()
        .map(|t| {
            let [a, b, c] = angles_deg(m.verts[t[0] as usize], m.verts[t[1] as usize], m.verts[t[2] as usize]);
            a.min(b).min(c)
        })
        .reduce(|| 180.0, f64::min)
}
