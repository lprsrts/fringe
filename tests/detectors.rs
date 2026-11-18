//! Detectors: the measurement on synthetic fields, scene validation, and the
//! readings in the field info and the outline JSON. The per-solver checks
//! (plane-wave flux, slab R + T) are the `detector_plane`, `slab_power` and
//! `slab_lossy_power` validation cases in tests/{fdtd,fem,mom}.rs.

mod common;

use std::f64::consts::PI;

use fringe_core::detectors::{box_intensity, line_flux, line_normal, measure_all, FieldView, Measurement};
use fringe_core::ffi::scene_outlines_json;
use fringe_core::scene::{examples, parse_scene, to_json, validate, Detector, DetectorShape, Severity, Source, SourceKind};
use fringe_core::solver::{solve, GridSpec, Quality, SolveContext};
use fringe_core::types::{Rect, Vec2, C64, J};

/// A plane wave `a e^{-j k n_b (cos θ x + sin θ y)}` on a grid of `ppw` nodes
/// per background wavelength, λ0 = 1.
fn plane_wave(ppw: f64, n_b: f64, angle_deg: f64, a: f64) -> (GridSpec, Vec<C64>) {
    let dx = 1.0 / n_b / ppw;
    let g = GridSpec::covering(Rect::new(-3.0, 3.0, -3.0, 3.0), dx);
    let k = 2.0 * PI * n_b;
    let (c, s) = (angle_deg.to_radians().cos(), angle_deg.to_radians().sin());
    let v = (0..g.len())
        .map(|idx| {
            let p = g.point(idx % g.nx, idx / g.nx);
            a * (-J * k * (c * p.x + s * p.y)).exp()
        })
        .collect();
    (g, v)
}

fn view<'a>(g: &'a GridSpec, total: &'a [C64], incident: &'a [C64]) -> FieldView<'a> {
    FieldView { grid: g, total, incident, wavelength_um: 1.0 }
}

#[test]
fn plane_wave_flux_is_nb_a2_over_2_per_um() {
    // At 6 nodes per wavelength (the preview output grid) and at 12 (final),
    // off the nodes and at an angle to the line.
    for (ppw, tol) in [(6.0, 2e-3), (12.0, 1e-5), (24.0, 1e-7)] {
        for (n_b, angle, a) in [(1.0, 0.0, 1.0), (1.33, 30.0, 2.0), (2.0, -55.0, 0.7)] {
            let (g, e) = plane_wave(ppw, n_b, angle, a);
            let zero = vec![C64::new(0.0, 0.0); e.len()];
            let (p1, p2) = (Vec2::new(0.37, -1.91), Vec2::new(0.52, 2.13));
            let n = line_normal(p1, p2);
            let dir = Vec2::from_angle(f64::to_radians(angle));
            let want = 0.5 * n_b * a * a * p1.dist(p2) * dir.dot(n);
            let f = line_flux(&view(&g, &e, &zero), p1, p2);
            assert!((f.total - want).abs() <= tol * want.abs(), "ppw {ppw} n_b {n_b} θ {angle}: {} vs {want}", f.total);
            // All of it is scattered when the incident slice is zero.
            assert_eq!(f.scattered, f.total);
            assert_eq!(f.incident, 0.0);
            // Reversing the line reverses the normal and the sign.
            let back = line_flux(&view(&g, &e, &zero), p2, p1);
            assert!((back.total + f.total).abs() <= 1e-9 * want.abs());
        }
    }
}

#[test]
fn normal_is_to_the_right_of_the_line() {
    let n = line_normal(Vec2::new(4.0, -2.0), Vec2::new(4.0, 2.0));
    assert_eq!((n.x, n.y), (1.0, 0.0));
    let n = line_normal(Vec2::new(0.0, 0.0), Vec2::new(1.0, 0.0));
    assert_eq!((n.x, n.y), (0.0, -1.0));
}

#[test]
fn counter_propagating_waves_carry_the_difference() {
    // E = A e^{-jkx} + B e^{jkx}: the cross terms carry no net power, so the
    // flux is (A² − B²)/2 per µm, and the scattered part (B) gives −B²/2.
    let (g, fwd) = plane_wave(8.0, 1.0, 0.0, 1.0);
    let (_, bwd) = plane_wave(8.0, 1.0, 180.0, 0.6);
    let total: Vec<C64> = fwd.iter().zip(&bwd).map(|(a, b)| a + b).collect();
    let v = view(&g, &total, &fwd);
    for x in [-1.0, -0.13, 0.4, 2.2] {
        let f = line_flux(&v, Vec2::new(x, -1.0), Vec2::new(x, 1.0));
        assert!((f.total - (1.0 - 0.36)).abs() < 2e-4, "{x}: {}", f.total);
        assert!((f.incident - 1.0).abs() < 2e-4);
        assert!((f.scattered + 0.36).abs() < 2e-4);
    }
}

#[test]
fn box_mean_and_integral() {
    let (g, e) = plane_wave(6.0, 1.5, 20.0, 3.0);
    let half: Vec<C64> = e.iter().map(|v| v * 0.5).collect();
    let r = Rect::new(-0.7, 0.55, 0.1, 0.43);
    let (t, i) = box_intensity(&view(&g, &e, &half), r);
    assert!((t.mean - 9.0).abs() < 9.0 * 3e-3, "{}", t.mean);
    assert!((t.integral - t.mean * r.width() * r.height()).abs() < 1e-12);
    assert!((i.mean - 2.25).abs() < 2.25 * 3e-3);
    assert!(t.max >= t.mean);
    // A standing wave cos(kx) averaged over a whole number of periods is ½.
    let lambda = 1.0 / 1.5;
    let cos: Vec<C64> = (0..g.len()).map(|idx| C64::new((2.0 * PI / lambda * g.point(idx % g.nx, 0).x).cos(), 0.0)).collect();
    let (t, _) = box_intensity(&view(&g, &cos, &cos), Rect::new(-lambda, lambda, -0.2, 0.2));
    assert!((t.mean - 0.5).abs() < 5e-3, "{}", t.mean);
    // The largest sample, within a quarter cell of the crest.
    assert!(t.max > 0.9 && t.max < 1.01, "{}", t.max);
}

#[test]
fn small_grids_and_edges_are_measured() {
    // A grid narrower than the 8-node stencil, and a line on the grid edge.
    let g = GridSpec { x0: 0.0, y0: 0.0, dx: 0.1, nx: 4, ny: 3 };
    let e: Vec<C64> = (0..g.len()).map(|i| C64::new(1.0 + 0.1 * (i % 4) as f64, 0.0)).collect();
    let f = line_flux(&view(&g, &e, &e), Vec2::new(0.0, 0.0), Vec2::new(0.3, 0.2));
    assert!(f.total.is_finite());
    let (t, _) = box_intensity(&view(&g, &e, &e), Rect::new(0.0, 0.3, 0.0, 0.2));
    assert!(t.mean > 1.0 && t.mean < 1.7, "{}", t.mean);
}

fn line(id: &str, x1: f64, y1: f64, x2: f64, y2: f64) -> Detector {
    Detector { id: id.into(), name: String::new(), enabled: true, shape: DetectorShape::Line { x1_um: x1, y1_um: y1, x2_um: x2, y2_um: y2 } }
}

fn boxed(id: &str, x: f64, y: f64, w: f64, h: f64) -> Detector {
    Detector { id: id.into(), name: String::new(), enabled: true, shape: DetectorShape::Box { x_um: x, y_um: y, width_um: w, height_um: h } }
}

#[test]
fn detectors_round_trip_with_defaults() {
    let mut v: serde_json::Value = serde_json::from_str(&to_json(&examples::default())).unwrap();
    v["detectors"] = serde_json::json!([
        {"id": "out-1", "name": "Output", "enabled": true, "shape": {"kind": "line", "x1_um": 4, "y1_um": -2, "x2_um": 4, "y2_um": 2}},
        {"id": "spot", "shape": {"kind": "box", "x_um": 3, "y_um": 0, "width_um": 0.5, "height_um": 0.5}}
    ]);
    let s = parse_scene(&v.to_string()).unwrap();
    assert_eq!(s.detectors[0], Detector { name: "Output".into(), ..line("out-1", 4.0, -2.0, 4.0, 2.0) });
    assert_eq!(s.detectors[1], boxed("spot", 3.0, 0.0, 0.5, 0.5));
    assert_eq!(parse_scene(&to_json(&s)).unwrap(), s);
    assert!(validate(&s).iter().all(|i| !i.path.starts_with("detectors")), "{:?}", validate(&s));
    // A scene without detectors has none.
    v.as_object_mut().unwrap().remove("detectors");
    assert!(parse_scene(&v.to_string()).unwrap().detectors.is_empty());
    // Unknown keys and kinds are refused.
    v["detectors"] = serde_json::json!([{"id": "a", "shape": {"kind": "line", "x1_um": 0, "y1_um": 0, "x2_um": 1, "y2_um": 0, "z": 1}}]);
    assert_eq!(parse_scene(&v.to_string()).unwrap_err().code, "parse");
    v["detectors"] = serde_json::json!([{"id": "a", "shape": {"kind": "circle", "x_um": 0}}]);
    assert_eq!(parse_scene(&v.to_string()).unwrap_err().code, "parse");
}

#[test]
fn version_2_scenes_cannot_hold_detectors() {
    let text = |detectors: &str| {
        format!(
            r#"{{"version": 2, "wavelength_um": 1, "background": {{"n": 1}},
            "source": {{"type": "plane_wave", "angle_deg": 0}}, "detectors": {detectors},
            "domain": {{"x_min_um": -5, "x_max_um": 5, "y_min_um": -3, "y_max_um": 3}}}}"#
        )
    };
    let one = r#"[{"id": "a", "shape": {"kind": "box", "x_um": 0, "y_um": 0, "width_um": 1, "height_um": 1}}]"#;
    assert_eq!(parse_scene(&text(one)).unwrap_err().code, "schema_version");
    // An empty list is harmless and accepted.
    assert!(parse_scene(&text("[]")).unwrap().detectors.is_empty());
}

#[test]
fn detector_validation() {
    // The default scene's domain is wider than ±5 × ±3 µm.
    let base = examples::default();
    let d = base.domain;
    let codes = |dets: Vec<Detector>| {
        let mut s = base.clone();
        s.detectors = dets;
        validate(&s)
            .into_iter()
            .filter(|i| i.path.starts_with("detectors"))
            .map(|i| (i.path, i.code, i.severity))
            .collect::<Vec<_>>()
    };
    let e = Severity::Error;
    assert_eq!(codes(vec![line("a", 0.0, 0.0, 0.0, 0.0)]), [("detectors[0].shape.x2_um".into(), "too_small".into(), e)]);
    assert_eq!(codes(vec![boxed("a", 0.0, 0.0, 0.0, 1.0)]), [("detectors[0].shape.width_um".into(), "too_small".into(), e)]);
    assert_eq!(codes(vec![boxed("a", 0.0, 0.0, 1.0, -1.0)]), [("detectors[0].shape.height_um".into(), "too_small".into(), e)]);
    assert_eq!(codes(vec![line("a", 0.0, f64::NAN, 1.0, 0.0)]), [("detectors[0].shape.y1_um".into(), "non_finite".into(), e)]);
    assert_eq!(codes(vec![line("a", 0.0, 0.0, d.x_max_um + 0.1, 0.0)]), [("detectors[0]".into(), "outside_domain".into(), e)]);
    assert_eq!(codes(vec![boxed("a", d.x_min_um + 0.2, 0.0, 0.5, 0.5)]), [("detectors[0]".into(), "outside_domain".into(), e)]);
    // On the domain edge is inside.
    assert!(codes(vec![line("a", d.x_min_um, d.y_min_um, d.x_max_um, d.y_max_um)]).is_empty());
    // A disabled detector is not placed.
    assert!(codes(vec![Detector { enabled: false, ..line("a", 0.0, 0.0, 100.0, 0.0) }]).is_empty());
    assert_eq!(
        codes(vec![line("a", 0.0, 0.0, 1.0, 0.0), line("a", 0.0, 1.0, 1.0, 1.0), line("", 0.0, 2.0, 1.0, 2.0)]),
        [("detectors[1].id".into(), "duplicate_id".into(), e), ("detectors[2].id".into(), "empty_id".into(), e)]
    );
    let many: Vec<Detector> = (0..65).map(|k| line(&format!("d{k}"), 0.0, 0.0, 1.0, 0.0)).collect();
    assert_eq!(codes(many), [("detectors".into(), "too_many".into(), e)]);

    // Near an emitter: a warning.
    let mut s = base.clone();
    s.sources.push(Source::new("emitter", SourceKind::LineSource { x_um: 2.0, y_um: 2.0, amplitude: 1.0, phase_deg: 0.0 }));
    s.detectors = vec![line("a", 2.1, 1.0, 2.1, 3.0), boxed("b", -2.0, -2.0, 0.5, 0.5)];
    let issues: Vec<_> = validate(&s).into_iter().filter(|i| i.path.starts_with("detectors")).collect();
    assert_eq!(issues.len(), 1, "{issues:?}");
    assert_eq!((issues[0].path.as_str(), issues[0].code.as_str(), issues[0].severity), ("detectors[0]", "near_emitter", Severity::Warning));
}

#[test]
fn readings_are_in_the_field_info() {
    let mut s = examples::example("emitter_mirror").unwrap();
    s.detectors.push(boxed("spot", 0.0, 2.0, 1.0, 0.5));
    s.detectors.push(Detector { enabled: false, ..boxed("off", 0.0, -2.0, 1.0, 0.5) });
    let field = solve(&s, Quality::Preview, &SolveContext::new()).unwrap();
    let info = field.info_json();
    let dets = info["detectors"].as_array().unwrap();
    // Enabled detectors only, in scene order.
    assert_eq!(dets.len(), 2);
    assert_eq!(dets[0]["id"], "output");
    assert_eq!(dets[0]["kind"], "line");
    assert_eq!(dets[0]["normal"], serde_json::json!([-1.0, 0.0]));
    assert_eq!(dets[0]["length_um"], 10.0);
    let flux = &dets[0]["flux"];
    // The collimated return beam and the emitter's own wave both cross it towards −x.
    assert!(flux["total"].as_f64().unwrap() > 0.0);
    assert!(flux["incident"].as_f64().unwrap() > 0.0);
    assert!(flux["scattered"].as_f64().unwrap() > 0.0);
    assert_eq!(dets[1]["kind"], "box");
    assert_eq!(dets[1]["area_um2"], 0.5);
    for part in ["total", "incident"] {
        let b = &dets[1][part];
        let (mean, integral, max) = (b["mean"].as_f64().unwrap(), b["integral"].as_f64().unwrap(), b["max"].as_f64().unwrap());
        assert!(mean > 0.0 && max >= mean && (integral - 0.5 * mean).abs() < 1e-12);
    }
    // The same readings from the field's view, as the puzzle engine would take them.
    let again = measure_all(&field.view(), &field.scene.detectors);
    assert_eq!(serde_json::to_value(&again).unwrap(), info["detectors"]);
    assert!(matches!(again[0].measurement, Measurement::Line { .. }));
}

#[test]
fn outlines_list_detectors() {
    let mut s = examples::example("emitter_mirror").unwrap();
    s.detectors.push(Detector { enabled: false, ..boxed("spot", 1.0, 2.0, 1.0, 0.5) });
    let v = scene_outlines_json(&to_json(&s));
    let dets = v["detectors"].as_array().unwrap();
    assert_eq!(dets.len(), 2);
    assert_eq!(dets[0]["kind"], "line");
    assert_eq!(dets[0]["points_um"], serde_json::json!([[-10.0, 5.0], [-10.0, -5.0]]));
    assert_eq!(dets[0]["normal"], serde_json::json!([-1.0, 0.0]));
    assert_eq!(dets[1]["enabled"], false);
    assert_eq!(dets[1]["points_um"], serde_json::json!([[0.5, 1.75], [1.5, 1.75], [1.5, 2.25], [0.5, 2.25]]));
    assert!(dets[1]["normal"].is_null());
}

#[test]
fn readings_are_measured_once_per_field_and_print_without_negative_zero() {
    let scene = examples::example("silver_dimer").unwrap();
    let field = solve(&scene, Quality::Preview, &SolveContext::new()).unwrap();
    let a = field.detector_readings();
    let b = field.detector_readings();
    assert!(std::ptr::eq(a, b));
    let info = field.info_json();
    assert_eq!(info["detectors"][0]["mean_intensity"]["total"], info["detectors"][0]["total"]["mean"]);
    // A vertical line pointing down has normal (-1, 0); a horizontal one (0, 1).
    let n = line_normal(Vec2::new(0.0, 1.0), Vec2::new(0.0, -1.0));
    assert_eq!(serde_json::to_string(&n.to_array()).unwrap(), "[-1.0,0.0]");
    let n = line_normal(Vec2::new(1.0, 0.0), Vec2::new(-1.0, 0.0));
    assert_eq!(serde_json::to_string(&n.to_array()).unwrap(), "[0.0,1.0]");
}
