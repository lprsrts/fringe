mod common;

use beam_core::check::{check, check_json};
use beam_core::scene::{examples, parse_scene, to_json, validate, Issue, Severity, Shape};

fn errors(issues: &[Issue]) -> Vec<&Issue> {
    issues.iter().filter(|i| i.severity == Severity::Error).collect()
}

fn default_value() -> serde_json::Value {
    serde_json::from_str(&to_json(&examples::default())).unwrap()
}

fn issues_of(v: &serde_json::Value) -> Vec<Issue> {
    validate(&parse_scene(&v.to_string()).unwrap())
}

#[test]
fn fixtures_round_trip_and_match_examples() {
    let mut names: Vec<&str> = examples::EXAMPLES.iter().map(|e| e.name).collect();
    names.push("default");
    for name in names {
        let text = common::fixture(&format!("scenes/{name}.json"));
        let scene = parse_scene(&text).unwrap_or_else(|e| panic!("{name}: {e}"));
        let back = parse_scene(&to_json(&scene)).unwrap();
        assert_eq!(back, scene, "{name}");
        let want = if name == "default" { examples::default() } else { examples::example(name).unwrap() };
        assert_eq!(scene, want, "fixture {name} is stale; regenerate with beam-cli example");
        let issues = validate(&scene);
        assert!(errors(&issues).is_empty(), "{name}: {issues:?}");
        assert!(issues.is_empty(), "{name} has warnings: {issues:?}");
    }
}

#[test]
fn minimal_scene_parses_with_defaults() {
    let s = parse_scene(
        r#"{"version": 2, "wavelength_um": 0.633, "background": {"n": 1},
            "source": {"type": "plane_wave", "angle_deg": 0},
            "domain": {"x_min_um": -5, "x_max_um": 5, "y_min_um": -3, "y_max_um": 3}}"#,
    )
    .unwrap();
    assert_eq!(s.domain.pml_wl, 1.0);
    assert_eq!(s.source.amplitude(), 1.0);
    assert_eq!(s.solver.fem.order, 3);
    assert_eq!(s.solver.fdtd.courant, 0.6);
    assert!(s.solver.fdtd.subpixel);
    assert!(s.elements.is_empty());
    let issues = validate(&s);
    assert!(issues.iter().any(|i| i.code == "free_beam"));
}

#[test]
fn unknown_keys_are_rejected() {
    for (path, key) in [("", "colour"), ("source", "waist"), ("domain", "pml"), ("solver.fdtd", "steps")] {
        let mut v = default_value();
        let target = if path.is_empty() { &mut v } else { path.split('.').fold(&mut v, |v, k| &mut v[k]) };
        target[key] = serde_json::json!(1);
        let e = parse_scene(&v.to_string()).unwrap_err();
        assert_eq!(e.code, "parse", "{path}.{key}");
        assert!(e.message.contains(key), "{}", e.message);
    }
    let mut v = default_value();
    v["elements"][0]["shape"]["radius_um"] = serde_json::json!(3);
    assert_eq!(parse_scene(&v.to_string()).unwrap_err().code, "parse");
}

#[test]
fn schema_version_is_checked_first() {
    let v1 = r#"{"wavelength": 6.328e-7, "waist": 0.0005, "elements": []}"#;
    let e = parse_scene(v1).unwrap_err();
    assert_eq!(e.code, "schema_version");
    assert!(e.message.contains("v1"));
    let mut v = default_value();
    v["version"] = serde_json::json!(3);
    let e = parse_scene(&v.to_string()).unwrap_err();
    assert_eq!(e.code, "schema_version");
    assert!(e.message.contains("newer"));
    assert_eq!(parse_scene("{not json").unwrap_err().code, "parse");
}

#[test]
fn lens_thickness_reports_its_path_and_fix() {
    let mut v = default_value();
    v["elements"][0]["shape"]["center_thickness_um"] = serde_json::json!(1.0);
    let issues = issues_of(&v);
    let e = issues.iter().find(|i| i.code == "lens_thickness").expect("lens_thickness");
    assert_eq!(e.path, "elements[0].shape.center_thickness_um");
    assert!(e.message.contains("2.23"), "{}", e.message);
}

#[test]
fn overlap_names_both_elements() {
    let mut v = default_value();
    let mut second = v["elements"][0].clone();
    second["id"] = serde_json::json!("lens-2");
    second["name"] = serde_json::json!("Second lens");
    second["x_um"] = serde_json::json!(-1.5);
    v["elements"].as_array_mut().unwrap().push(second);
    let issues = issues_of(&v);
    let e = issues.iter().find(|i| i.code == "overlap").expect("overlap");
    assert_eq!(e.path, "elements[1]");
    assert!(e.message.contains("\"Lens\"") && e.message.contains("\"Second lens\""), "{}", e.message);
    // Far enough apart (gap > 0.05 λ) is fine; the lens is 3 µm thick at the vertex.
    v["elements"][1]["x_um"] = serde_json::json!(-0.5);
    assert!(issues_of(&v).iter().all(|i| i.code != "overlap"));
}

#[test]
fn outside_domain_and_near_pml() {
    let mut v = default_value();
    v["elements"][0]["y_um"] = serde_json::json!(5.0);
    let issues = issues_of(&v);
    let e = issues.iter().find(|i| i.code == "outside_domain").expect("outside_domain");
    assert_eq!(e.path, "elements[0]");
    v["elements"][0]["y_um"] = serde_json::json!(3.9);
    let issues = issues_of(&v);
    assert!(issues.iter().any(|i| i.code == "near_pml" && i.severity == Severity::Warning));
}

#[test]
fn parameter_errors_have_paths() {
    let cases: Vec<(&str, serde_json::Value, &str)> = vec![
        ("wavelength_um", serde_json::json!(0.01), "wavelength_um"),
        ("background.n", serde_json::json!(5.0), "background.n"),
        ("elements.0.material.n", serde_json::json!(7.0), "elements[0].material.n"),
        ("elements.0.material.k", serde_json::json!(1.2), "elements[0].material.k"),
        ("source.waist_um", serde_json::json!(0.05), "source.waist_um"),
        ("domain.pml_wl", serde_json::json!(0.2), "domain.pml_wl"),
        ("solver.fdtd.courant", serde_json::json!(0.9), "solver.fdtd.courant"),
        ("solver.fem.order", serde_json::json!(4), "solver.fem.order"),
        ("elements.0.shape.r1_um", serde_json::json!(4.0), "elements[0].shape.r1_um"),
    ];
    for (key, value, path) in cases {
        let mut v = default_value();
        let mut target = &mut v;
        for k in key.split('.') {
            target = match k.parse::<usize>() {
                Ok(i) => &mut target[i],
                Err(_) => &mut target[k],
            };
        }
        *target = value;
        let issues = issues_of(&v);
        assert!(errors(&issues).iter().any(|i| i.path == path), "{key}: {issues:?}");
    }
}

#[test]
fn shape_rules() {
    let s = examples::example("double_slit").unwrap();
    let mut bad = s.clone();
    if let Shape::Slits { pitch_um, .. } = &mut bad.elements[0].shape {
        *pitch_um = 1.02;
    }
    assert!(validate(&bad).iter().any(|i| i.code == "slit_pitch"));
    let mut bad = s.clone();
    bad.elements[0].material = beam_core::scene::Material::Dielectric { n: 1.5, k: 0.0 };
    assert!(validate(&bad).iter().any(|i| i.code == "pec_required"));
    let mut bad = examples::example("talbot").unwrap();
    if let Shape::Grating { fill_factor, .. } = &mut bad.elements[0].shape {
        *fill_factor = 0.99;
    }
    assert!(validate(&bad).iter().any(|i| i.code == "grating_bar"));
    let mut bad = examples::default();
    bad.elements[0].shape = Shape::Polygon { vertices_um: vec![[0.0, 0.0], [3.0, 2.0], [3.0, 0.0], [0.0, 1.0]] };
    assert!(validate(&bad).iter().any(|i| i.code == "polygon_self_intersecting"));
    let mut dup = examples::default();
    let mut e = dup.elements[0].clone();
    e.x_um = 10.0;
    dup.elements.push(e);
    assert!(validate(&dup).iter().any(|i| i.code == "duplicate_id" && i.path == "elements[1].id"));
}

#[test]
fn check_report_shape() {
    let r = check(&examples::default());
    assert!(r.ok);
    let est = r.estimates.as_ref().unwrap();
    let p = est.preview.as_ref().unwrap();
    assert!(p.grid.unwrap()[0] > 100);
    assert!(est.final_.as_ref().unwrap().unknowns > p.unknowns);
    let d = &r.derived;
    assert!((d["source"]["rayleigh_range_um"].as_f64().unwrap() - 28.274).abs() < 1e-3);
    let lens = &d["elements"][0]["lens"];
    assert!((lens["paraxial_focal_um"].as_f64().unwrap() - 12.5217).abs() < 1e-3);
    assert!((lens["edge_thickness_um"].as_f64().unwrap() - 0.8174).abs() < 1e-3);
    let json = serde_json::to_value(&r).unwrap();
    assert!(json["estimates"]["final"].is_object());
    let bad = check_json("{");
    assert!(!bad.ok);
    assert_eq!(bad.issues[0].code, "parse");
}

fn codes_at(s: &beam_core::Scene, path: &str) -> Vec<String> {
    errors(&validate(s)).iter().filter(|i| i.path == path).map(|i| i.code.clone()).collect()
}

/// A waist far from the domain would need a huge plane-wave sum; it is refused
/// with a message that says how far is possible, and the check returns at once.
#[test]
fn far_waist_is_refused_quickly() {
    use beam_core::scene::Source;
    let set = |s: &mut beam_core::Scene, x: f64, w: f64| {
        if let Source::GaussianBeam { waist_x_um, waist_um, .. } = &mut s.source {
            *waist_x_um = x;
            *waist_um = w;
        }
    };
    let mut s = examples::default();
    set(&mut s, -100.0, 0.1);
    assert!(codes_at(&s, "source.waist_x_um").is_empty());
    set(&mut s, -10000.0, 0.1);
    let t = std::time::Instant::now();
    let r = check(&s);
    assert!(t.elapsed().as_secs_f64() < 2.0, "check took {:.1} s", t.elapsed().as_secs_f64());
    let e = r.issues.iter().find(|i| i.code == "waist_too_far").expect("waist_too_far");
    assert_eq!(e.path, "source.waist_x_um");
    assert!(e.message.contains("can only be built out to"), "{}", e.message);
    // A wide beam diverges less and may sit farther away.
    set(&mut s, -2000.0, 20.0);
    assert!(codes_at(&s, "source.waist_x_um").is_empty());
}
