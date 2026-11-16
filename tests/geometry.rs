use spade::{AngleLimit, ConstrainedDelaunayTriangulation, Point2, RefinementParameters, Triangulation};

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
