mod common;

use beam_core::geometry::{element_bodies, min_gap, signed_area, Body, Contour, Segment};
use beam_core::scene::{Element, Material, Shape};
use beam_core::types::Vec2;
use spade::{AngleLimit, ConstrainedDelaunayTriangulation, Point2, RefinementParameters, Triangulation};

use common::Rng;

fn element(shape: Shape, material: Material, rotation_deg: f64) -> Element {
    Element {
        id: "e".into(),
        name: "e".into(),
        enabled: true,
        material,
        x_um: 0.7,
        y_um: -0.4,
        rotation_deg,
        shape,
    }
}

fn glass() -> Material {
    Material::Dielectric { n: 1.5, k: 0.0 }
}

fn shapes() -> Vec<(&'static str, Shape, Material)> {
    vec![
        ("biconvex", Shape::Lens { r1_um: Some(12.0), r2_um: Some(-12.0), center_thickness_um: 3.0, aperture_um: 10.0 }, glass()),
        ("plano_convex", Shape::Lens { r1_um: Some(8.0), r2_um: None, center_thickness_um: 2.5, aperture_um: 8.0 }, glass()),
        ("biconcave", Shape::Lens { r1_um: Some(-10.0), r2_um: Some(10.0), center_thickness_um: 0.6, aperture_um: 8.0 }, glass()),
        ("meniscus", Shape::Lens { r1_um: Some(6.0), r2_um: Some(9.0), center_thickness_um: 1.5, aperture_um: 8.0 }, glass()),
        ("slab", Shape::Slab { thickness_um: 2.0, height_um: 7.0 }, glass()),
        ("wedge", Shape::Wedge { thick_um: 3.0, thin_um: 1.0, height_um: 6.0 }, glass()),
        ("prism", Shape::Prism { base_um: 6.0, apex_deg: 60.0 }, glass()),
        ("flat_mirror", Shape::Mirror { aperture_um: 8.0, thickness_um: 0.5, radius_um: None }, Material::Pec),
        ("concave_mirror", Shape::Mirror { aperture_um: 8.0, thickness_um: 0.5, radius_um: Some(10.0) }, Material::Pec),
        ("convex_mirror", Shape::Mirror { aperture_um: 8.0, thickness_um: 0.5, radius_um: Some(-7.0) }, Material::Pec),
        ("slits", Shape::Slits { count: 3, slit_width_um: 0.8, pitch_um: 2.0, screen_height_um: 9.0, thickness_um: 0.4 }, Material::Pec),
        ("grating", Shape::Grating { period_um: 1.5, fill_factor: 0.4, depth_um: 0.8, count: 5, substrate_um: 0.0 }, glass()),
        ("comb", Shape::Grating { period_um: 1.5, fill_factor: 0.4, depth_um: 0.8, count: 5, substrate_um: 1.2 }, glass()),
        ("cylinder", Shape::Cylinder { radius_um: 1.7 }, glass()),
        ("waveguide", Shape::Waveguide { width_um: 0.8, length_um: 9.0 }, glass()),
        (
            "polygon",
            Shape::Polygon { vertices_um: vec![[0.0, 0.0], [0.0, 3.0], [3.0, 3.0], [3.0, 2.0], [1.0, 2.0], [1.0, 0.0]] },
            glass(),
        ),
    ]
}

/// Even–odd test against a fine polyline of the contour.
fn polyline_inside(poly: &[Vec2], p: Vec2) -> bool {
    let n = poly.len();
    let mut inside = false;
    for i in 0..n {
        let (a, b) = (poly[i], poly[(i + 1) % n]);
        if (a.y > p.y) != (b.y > p.y) && p.x < a.x + (p.y - a.y) * (b.x - a.x) / (b.y - a.y) {
            inside = !inside;
        }
    }
    inside
}

fn bodies(shape: &Shape, material: Material, rotation: f64) -> Vec<Body> {
    element_bodies(0, &element(shape.clone(), material, rotation))
}

#[test]
fn inside_agrees_with_polyline_winding() {
    let mut rng = Rng(0x1234_5678_9abc_def1);
    for (name, shape, material) in shapes() {
        for rotation in [0.0, 37.0] {
            for body in bodies(&shape, material, rotation) {
                let poly = body.contour.polyline(1e-3, 0.2f64.to_radians());
                let r = body.bbox.expand(0.5);
                let mut disagreements = 0;
                for _ in 0..10_000 {
                    let p = rng.point_in(r);
                    let sd = body.signed_distance(p);
                    if sd.abs() < 1e-4 {
                        continue;
                    }
                    if body.inside(p) != polyline_inside(&poly, p) {
                        disagreements += 1;
                    }
                    assert_eq!(sd < 0.0, body.inside(p), "{name}: sign of signed distance at {p:?}");
                }
                assert_eq!(disagreements, 0, "{name} rotated {rotation}°");
            }
        }
    }
}

#[test]
fn signed_distance_matches_polyline_distance() {
    let mut rng = Rng(42);
    for (name, shape, material) in shapes() {
        for body in bodies(&shape, material, 20.0) {
            let poly = body.contour.polyline(2e-3, 0.1f64.to_radians());
            for _ in 0..300 {
                let p = rng.point_in(body.bbox.expand(1.0));
                let d_poly = (0..poly.len())
                    .map(|i| Segment::Line { a: poly[i], b: poly[(i + 1) % poly.len()] }.closest(p).2)
                    .fold(f64::INFINITY, f64::min);
                let d = body.signed_distance(p).abs();
                assert!((d - d_poly).abs() < 1e-5, "{name}: {d} vs {d_poly}");
            }
        }
    }
}

#[test]
fn contours_are_closed_and_counter_clockwise() {
    for (name, shape, material) in shapes() {
        for body in bodies(&shape, material, 115.0) {
            let segs = &body.contour.segments;
            for i in 0..segs.len() {
                let gap = segs[i].end().dist(segs[(i + 1) % segs.len()].start());
                assert!(gap < 1e-12, "{name}: gap {gap} after segment {i}");
            }
            let area = body.contour.area();
            let poly_area = signed_area(&body.contour.polyline(1e-3, 0.1f64.to_radians()));
            assert!(area > 0.0, "{name}: area {area}");
            assert!((area - poly_area).abs() < 1e-4 * area.max(1.0), "{name}: {area} vs {poly_area}");
            assert!(body.contour.bbox().contains_rect(&body.contour.bbox()));
        }
    }
}

#[test]
fn body_counts() {
    let n = |name: &str| {
        let (_, shape, m) = shapes().into_iter().find(|s| s.0 == name).unwrap();
        bodies(&shape, m, 0.0).len()
    };
    assert_eq!(n("slits"), 4);
    assert_eq!(n("grating"), 5);
    assert_eq!(n("comb"), 1);
    assert_eq!(n("cylinder"), 1);
}

#[test]
fn shapes_sit_where_the_spec_puts_them() {
    // Lens: vertices at ±t/2 on the axis about the anchor.
    let (_, lens, m) = shapes().remove(0);
    let b = &bodies(&lens, m, 0.0)[0];
    let anchor = Vec2::new(0.7, -0.4);
    assert!(b.contour.closest(anchor + Vec2::new(-1.5, 0.0)).3 < 1e-12);
    assert!(b.contour.closest(anchor + Vec2::new(1.5, 0.0)).3 < 1e-12);
    // Mirror: reflecting vertex at the anchor, facing −x.
    let (_, mirror, m) = shapes().into_iter().find(|s| s.0 == "concave_mirror").unwrap();
    let b = &bodies(&mirror, m, 0.0)[0];
    assert!(b.contour.closest(anchor).3 < 1e-12);
    assert!(b.inside(anchor + Vec2::new(0.25, 0.0)) && !b.inside(anchor + Vec2::new(-0.05, 0.0)));
    // Prism: apex up, anchor at the centroid.
    let (_, prism, m) = shapes().into_iter().find(|s| s.0 == "prism").unwrap();
    let b = &bodies(&prism, m, 0.0)[0];
    let c = b.contour.segments.iter().map(|s| s.start()).fold(Vec2::ZERO, |a, p| a + p) / 3.0;
    assert!(c.dist(anchor) < 1e-12);
    assert!(b.bbox.y_max - anchor.y > anchor.y - b.bbox.y_min);
}

#[test]
fn gaps_between_bodies() {
    let circle = |x: f64, r: f64| Contour::new(vec![
        Segment::Arc { center: Vec2::new(x, 0.0), radius: r, start: 0.0, sweep: std::f64::consts::PI },
        Segment::Arc { center: Vec2::new(x, 0.0), radius: r, start: std::f64::consts::PI, sweep: std::f64::consts::PI },
    ]);
    let square = |x0: f64| Contour::polygon(&[Vec2::new(x0, -1.0), Vec2::new(x0 + 2.0, -1.0), Vec2::new(x0 + 2.0, 1.0), Vec2::new(x0, 1.0)]);
    let gap = beam_core::geometry::contour_gap;
    assert!((gap(&circle(0.0, 1.0), &circle(3.0, 1.0)) - 1.0).abs() < 1e-12);
    assert!((gap(&circle(0.0, 1.0), &square(1.5)) - 0.5).abs() < 1e-12);
    assert_eq!(gap(&circle(0.0, 1.0), &square(0.5)), 0.0);
    assert_eq!(gap(&circle(0.0, 3.0), &circle(0.5, 1.0)), 0.0);
    assert!((gap(&square(0.0), &square(2.3)) - 0.3).abs() < 1e-12);
    // Diagonal: corner to arc.
    let d = gap(&circle(0.0, 1.0), &Contour::polygon(&[Vec2::new(2.0, 2.0), Vec2::new(3.0, 2.0), Vec2::new(3.0, 3.0), Vec2::new(2.0, 3.0)]));
    assert!((d - (8f64.sqrt() - 1.0)).abs() < 1e-12);
    let a = bodies(&Shape::Cylinder { radius_um: 1.0 }, glass(), 0.0);
    assert_eq!(min_gap(&a[0], &a[0]), 0.0);
}


fn min_angle_deg(p: [Point2<f64>; 3]) -> f64 {
    let mut m = 180.0f64;
    for k in 0..3 {
        let a = p[k];
        let b = p[(k + 1) % 3];
        let c = p[(k + 2) % 3];
        let (ux, uy) = (b.x - a.x, b.y - a.y);
        let (vx, vy) = (c.x - a.x, c.y - a.y);
        let cos = (ux * vx + uy * vy) / ((ux * ux + uy * uy).sqrt() * (vx * vx + vy * vy).sqrt());
        m = m.min(cos.clamp(-1.0, 1.0).acos().to_degrees());
    }
    m
}

/// spade 2.15 API used by the FEM mesher: CDT with closed constraint loops split
/// at the target size h, an equilateral seed lattice kept 0.6 h away from the
/// constraints, then `refine` with a 25° limit while keeping constraint edges
/// unsplit.
///
/// With `keep_constraint_edges`, refine cannot remove a skinny triangle whose
/// circumcentre encroaches a constraint edge, so the seeds are what make the mesh
/// good near boundaries; refine alone leaves 2° slivers there.
/// `exclude_outer_faces(true)` uses winding parity, which would also exclude
/// regions enclosed by two loops (the PML ring, a body inside the domain), so the
/// FEM mesher should leave it off: the outer rectangle is the convex hull anyway.
#[test]
fn spade_cdt_refine_spike() {
    let h: f64 = 0.13;
    let half: f64 = 2.0;
    let mut cdt = ConstrainedDelaunayTriangulation::<Point2<f64>>::new();
    let add_loop = |cdt: &mut ConstrainedDelaunayTriangulation<Point2<f64>>, pts: Vec<(f64, f64)>| {
        let hs: Vec<_> = pts
            .iter()
            .map(|&(x, y)| cdt.insert(Point2::new(x, y)).unwrap())
            .collect();
        for k in 0..hs.len() {
            cdt.add_constraint(hs[k], hs[(k + 1) % hs.len()]);
        }
        hs.len()
    };
    let per_side = (2.0 * half / h).ceil() as usize;
    let mut square = Vec::new();
    for side in 0..4 {
        for k in 0..per_side {
            let s = -half + 2.0 * half * k as f64 / per_side as f64;
            square.push(match side {
                0 => (s, -half),
                1 => (half, s),
                2 => (-s, half),
                _ => (-half, -s),
            });
        }
    }
    let n_square = add_loop(&mut cdt, square);
    let m = (2.0 * std::f64::consts::PI / h).ceil() as usize;
    let circle: Vec<_> = (0..m)
        .map(|k| {
            let t = 2.0 * std::f64::consts::PI * k as f64 / m as f64;
            (t.cos(), t.sin())
        })
        .collect();
    let n_circle = add_loop(&mut cdt, circle);
    let dy = h * 3f64.sqrt() / 2.0;
    let mut row = 0;
    let mut y = -half;
    while y <= half {
        let mut x = -half + if row % 2 == 1 { h / 2.0 } else { 0.0 };
        while x <= half {
            let r = (x * x + y * y).sqrt();
            let d_square = (half - x.abs()).min(half - y.abs());
            if (r - 1.0).abs() >= 0.6 * h && d_square >= 0.6 * h {
                cdt.insert(Point2::new(x, y)).unwrap();
            }
            x += h;
        }
        y += dy;
        row += 1;
    }
    let before = cdt.num_vertices();
    let result = cdt.refine(
        RefinementParameters::<f64>::new()
            .with_angle_limit(AngleLimit::from_deg(25.0))
            .keep_constraint_edges()
            .with_max_additional_vertices(before / 2)
            .exclude_outer_faces(false),
    );
    assert!(result.refinement_complete);
    let mut worst = 180.0f64;
    let mut inside = 0;
    for f in cdt.inner_faces() {
        let v = f.vertices().map(|v| v.position());
        worst = worst.min(min_angle_deg(v));
        let c = Point2::new((v[0].x + v[1].x + v[2].x) / 3.0, (v[0].y + v[1].y + v[2].y) / 3.0);
        if c.x * c.x + c.y * c.y < 1.0 {
            inside += 1;
        }
    }
    assert!(worst >= 18.0, "min angle {worst}");
    assert!(inside > 300, "only {inside} triangles inside the circle");
    assert_eq!(cdt.num_constraints(), n_square + n_circle);
    eprintln!(
        "spade: {before} vertices before refine, {} after, min angle {worst:.1}°",
        cdt.num_vertices()
    );
}

#[test]
fn ray_hits_lines_and_arcs() {
    let c = Contour::polygon(&[Vec2::new(0.0, 0.0), Vec2::new(2.0, 0.0), Vec2::new(2.0, 1.0), Vec2::new(0.0, 1.0)]);
    let t = c.ray_hit(Vec2::new(-1.0, 0.5), Vec2::new(1.0, 0.0), 10.0).unwrap();
    assert!((t - 1.0).abs() < 1e-12);
    assert!(c.ray_hit(Vec2::new(-1.0, 0.5), Vec2::new(1.0, 0.0), 0.5).is_none());
    assert!(c.ray_hit(Vec2::new(-1.0, 2.0), Vec2::new(1.0, 0.0), 10.0).is_none());
    let circle = Contour::new(vec![
        Segment::Arc { center: Vec2::ZERO, radius: 1.0, start: 0.0, sweep: std::f64::consts::PI },
        Segment::Arc { center: Vec2::ZERO, radius: 1.0, start: std::f64::consts::PI, sweep: std::f64::consts::PI },
    ]);
    let t = circle.ray_hit(Vec2::new(0.6, -3.0), Vec2::new(0.0, 1.0), 10.0).unwrap();
    assert!((t - (3.0 - 0.8)).abs() < 1e-12, "{t}");
    // From inside, the first crossing is the exit.
    let t = circle.ray_hit(Vec2::ZERO, Vec2::new(1.0, 0.0), 10.0).unwrap();
    assert!((t - 1.0).abs() < 1e-12);
}

#[test]
fn polygon_width() {
    use beam_core::geometry::polygon_min_width;
    let rect = [Vec2::new(0.0, 0.0), Vec2::new(3.0, 0.0), Vec2::new(3.0, 0.2), Vec2::new(0.0, 0.2)];
    assert!((polygon_min_width(&rect) - 0.2).abs() < 1e-12);
    let mut cw = rect;
    cw.reverse();
    assert!((polygon_min_width(&cw) - 0.2).abs() < 1e-12);
    // An L with a thin arm.
    let l = [Vec2::new(0.0, 0.0), Vec2::new(4.0, 0.0), Vec2::new(4.0, 0.1), Vec2::new(1.0, 0.1), Vec2::new(1.0, 3.0), Vec2::new(0.0, 3.0)];
    assert!((polygon_min_width(&l) - 0.1).abs() < 1e-12);
    // A 512-gon of radius 1 is about 2 across, however short its edges.
    let n = 512;
    let circle: Vec<Vec2> = (0..n).map(|k| Vec2::from_angle(2.0 * std::f64::consts::PI * k as f64 / n as f64)).collect();
    let w = polygon_min_width(&circle);
    assert!(w > 1.99 && w <= 2.0 + 1e-12, "{w}");
}
