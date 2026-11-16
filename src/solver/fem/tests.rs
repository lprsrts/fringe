//! Mesh-quality tests. They live inside the crate so the mesh
//! internals stay private; the solver validation cases are in `tests/fem.rs`.

use std::collections::HashSet;

use crate::analytic::cases::case_scene;
use crate::geometry::BodyMaterial;
use crate::problem::{compile, Problem};
use crate::scene::{examples, Scene};
use crate::solver::{Method, Quality};

use super::{assemble, element, estimate_dofs, mesh};

#[derive(Clone, Debug)]
struct MeshReport {
    vertices: usize,
    triangles: usize,
    refined_vertices: usize,
    min_angle_deg: f64,
    dofs: usize,
    free_dofs: usize,
    estimated_dofs: f64,
    warnings: Vec<String>,
    /// Largest distance from a recorded arc-edge end to its arc point (should be ~0).
    max_arc_error: f64,
    /// Recorded arc constraint edges that are not edges of the final triangulation.
    missing_arc_edges: usize,
    arc_edges: usize,
    /// Total area of the triangles tagged dielectric.
    dielectric_area: f64,
}

fn mesh_report(p: &Problem) -> MeshReport {
    let order = p.settings.fem.order as usize;
    let m = mesh::build(p, order).unwrap();
    let el = element::RefElement::new(order);
    let dofs = assemble::number_dofs(p, &m, &el);
    let mut max_arc_error = 0.0f64;
    for (&(lo, hi), r) in &m.arcs {
        let seg = &p.bodies[r.body as usize].contour.segments[r.seg as usize];
        for (v, t) in [(lo, r.t_lo), (hi, r.t_hi)] {
            max_arc_error = max_arc_error.max(seg.point(t).dist(m.verts[v as usize]));
        }
    }
    let edges: HashSet<(u32, u32)> = m
        .tris
        .iter()
        .flat_map(|t| [(t[0], t[1]), (t[1], t[2]), (t[2], t[0])])
        .map(|(a, b)| (a.min(b), a.max(b)))
        .collect();
    let missing_arc_edges = m.arcs.keys().filter(|k| !edges.contains(k)).count();
    let mut dielectric_area = 0.0;
    for (t, tr) in m.tris.iter().enumerate() {
        let b = m.tri_body[t];
        if b != mesh::BACKGROUND && matches!(p.bodies[b as usize].material, BodyMaterial::Dielectric { .. }) {
            let [a, bb, c] = tr.map(|v| m.verts[v as usize]);
            dielectric_area += 0.5 * (bb - a).cross(c - a).abs();
        }
    }
    MeshReport {
        vertices: m.verts.len(),
        triangles: m.tris.len(),
        refined_vertices: m.refined_vertices,
        min_angle_deg: mesh::min_angle_deg(&m),
        dofs: dofs.n,
        free_dofs: dofs.n_free,
        estimated_dofs: estimate_dofs(p),
        warnings: m.warnings,
        max_arc_error,
        missing_arc_edges,
        arc_edges: m.arcs.len(),
        dielectric_area,
    }
}

fn mesh_scenes() -> Vec<(String, Scene)> {
    let mut out: Vec<(String, Scene)> =
        examples::EXAMPLES.iter().map(|e| (e.name.to_string(), examples::example(e.name).unwrap())).collect();
    for id in ["mie_pec", "mie_diel", "mie_high_index", "slab_airy_0", "mirror_0", "free_beam"] {
        out.push((id.to_string(), case_scene(id).unwrap()));
    }
    out
}

/// Every triangle of every example and case mesh has all angles ≥ 18°; every arc
/// constraint edge survives as a mesh edge with its ends on the arc; dielectric
/// triangles cover the bodies' areas to 1 %; the DOF estimate is within 25 %.
#[test]
fn fem_mesh_quality() {
    for (name, mut s) in mesh_scenes() {
        s.solver.method = Method::Fem;
        for q in [Quality::Preview, Quality::Final] {
            let p = compile(&s, q).unwrap();
            let m = mesh_report(&p);
            let diel_area: f64 = p.bodies.iter().filter(|b| !b.is_pec()).map(|b| b.contour.area().abs()).sum();
            eprintln!(
                "{name} {}: {} vertices (+{} refined), {} triangles, min angle {:.2}°, {} arc edges, {} unknowns (est {:.0})",
                q.name(),
                m.vertices,
                m.refined_vertices,
                m.triangles,
                m.min_angle_deg,
                m.arc_edges,
                m.free_dofs,
                m.estimated_dofs
            );
            assert!(m.min_angle_deg >= 18.0, "{name} {}: min angle {}", q.name(), m.min_angle_deg);
            assert!(m.warnings.is_empty(), "{name}: {:?}", m.warnings);
            assert!(m.max_arc_error < 1e-9, "{name}: arc error {}", m.max_arc_error);
            assert_eq!(m.missing_arc_edges, 0, "{name} {}: arc edges lost from the mesh", q.name());
            // Chords cut arcs, so the straight-sided area differs slightly.
            assert!(
                (m.dielectric_area - diel_area).abs() <= 1e-2 * diel_area,
                "{name}: dielectric area {} vs {}",
                m.dielectric_area,
                diel_area
            );
            let est = m.estimated_dofs;
            assert!(
                est / (m.dofs as f64) < 1.25 && (m.dofs as f64) / est < 1.25,
                "{name}: DOF estimate {est} vs {}",
                m.dofs
            );
        }
    }
}
