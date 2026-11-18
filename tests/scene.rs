mod common;

use fringe_core::check::{check, check_json};
use fringe_core::scene::{examples, parse_scene, to_json, validate, Issue, Severity, Shape};

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
        assert_eq!(scene, want, "fixture {name} is stale; regenerate with fringe-cli example");
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
    assert_eq!(s.sources[0].kind.amplitude(), 1.0);
    assert_eq!(s.solver.fem.order, 3);
    assert_eq!(s.solver.fdtd.courant, 0.6);
    assert!(s.solver.fdtd.subpixel);
    assert!(s.elements.is_empty());
    let issues = validate(&s);
    assert!(issues.iter().any(|i| i.code == "free_beam"));
}

#[test]
fn unknown_keys_are_rejected() {
    for (path, key) in [("", "colour"), ("sources.0", "waist"), ("domain", "pml"), ("solver.fdtd", "steps")] {
        let mut v = default_value();
        let target = if path.is_empty() {
            &mut v
        } else {
            path.split('.').fold(&mut v, |v, k| match k.parse::<usize>() {
                Ok(i) => &mut v[i],
                Err(_) => &mut v[k],
            })
        };
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
    v["version"] = serde_json::json!(4);
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
        ("sources.0.waist_um", serde_json::json!(0.05), "sources[0].waist_um"),
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
    bad.elements[0].material = fringe_core::scene::Material::Dielectric { n: 1.5, k: 0.0 };
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
    assert_eq!(d["sources"][0]["id"], "source-1");
    assert_eq!(d["sources"][0]["rayleigh_range_um"], d["source"]["rayleigh_range_um"]);
    let lens = &d["elements"][0]["lens"];
    assert!((lens["paraxial_focal_um"].as_f64().unwrap() - 12.5217).abs() < 1e-3);
    assert!((lens["edge_thickness_um"].as_f64().unwrap() - 0.8174).abs() < 1e-3);
    let json = serde_json::to_value(&r).unwrap();
    assert!(json["estimates"]["final"].is_object());
    let bad = check_json("{");
    assert!(!bad.ok);
    assert_eq!(bad.issues[0].code, "parse");
}

fn codes_at(s: &fringe_core::Scene, path: &str) -> Vec<String> {
    errors(&validate(s)).iter().filter(|i| i.path == path).map(|i| i.code.clone()).collect()
}

#[test]
fn amplitude_is_bounded() {
    let mut s = examples::default();
    if let fringe_core::scene::SourceKind::GaussianBeam { amplitude, .. } = &mut s.sources[0].kind {
        *amplitude = 1e40;
    }
    assert_eq!(codes_at(&s, "sources[0].amplitude"), ["out_of_range"]);
    if let fringe_core::scene::SourceKind::GaussianBeam { amplitude, .. } = &mut s.sources[0].kind {
        *amplitude = 1e30;
    }
    assert!(codes_at(&s, "sources[0].amplitude").is_empty());
}

/// A waist far from the domain would need a huge plane-wave sum; it is refused
/// with a message that says how far is possible, and the check returns at once.
#[test]
fn far_waist_is_refused_quickly() {
    use fringe_core::scene::SourceKind;
    let set = |s: &mut fringe_core::Scene, x: f64, w: f64| {
        if let SourceKind::GaussianBeam { waist_x_um, waist_um, .. } = &mut s.sources[0].kind {
            *waist_x_um = x;
            *waist_um = w;
        }
    };
    let mut s = examples::default();
    set(&mut s, -100.0, 0.1);
    assert!(codes_at(&s, "sources[0].waist_x_um").is_empty());
    set(&mut s, -10000.0, 0.1);
    let t = std::time::Instant::now();
    let r = check(&s);
    assert!(t.elapsed().as_secs_f64() < 2.0, "check took {:.1} s", t.elapsed().as_secs_f64());
    let e = r.issues.iter().find(|i| i.code == "waist_too_far").expect("waist_too_far");
    assert_eq!(e.path, "sources[0].waist_x_um");
    assert!(e.message.contains("can only be built out to"), "{}", e.message);
    // A wide beam diverges less and may sit farther away.
    set(&mut s, -2000.0, 20.0);
    assert!(codes_at(&s, "sources[0].waist_x_um").is_empty());
}

#[test]
fn thin_and_huge_polygons_are_refused() {
    let mut s = examples::default();
    let poly = |v: Vec<[f64; 2]>| Shape::Polygon { vertices_um: v };
    s.elements[0].shape = poly(vec![[-0.005, -1.0], [0.005, -1.0], [0.005, 1.0], [-0.005, 1.0]]);
    let issues = validate(&s);
    let e = issues.iter().find(|i| i.code == "polygon_thin").expect("polygon_thin");
    assert!(e.message.contains("0.01 µm across"), "{}", e.message);
    // A sliver triangle.
    s.elements[0].shape = poly(vec![[-1.0, 0.0], [1.0, 0.0], [0.0, 0.0005]]);
    assert!(validate(&s).iter().any(|i| i.code == "polygon_thin"));
    // A finely sampled circle is fine however short its edges are.
    let circle: Vec<[f64; 2]> =
        (0..2000).map(|k| 2.0 * std::f64::consts::PI * k as f64 / 2000.0).map(|a| [2.0 * a.cos(), 2.0 * a.sin()]).collect();
    s.elements[0].shape = poly(circle);
    assert!(errors(&validate(&s)).is_empty(), "{:?}", errors(&validate(&s)));
    s.elements[0].shape = poly((0..3000).map(|k| {
        let a = 2.0 * std::f64::consts::PI * k as f64 / 3000.0;
        [2.0 * a.cos(), 2.0 * a.sin()]
    }).collect());
    assert_eq!(codes_at(&s, "elements[0].shape.vertices_um"), ["polygon_vertices"]);
}

/// The divergence readout is an angle below 90° even for a sub-wavelength waist.
#[test]
fn divergence_stays_below_ninety_degrees() {
    use fringe_core::scene::SourceKind;
    let mut s = examples::default();
    if let SourceKind::GaussianBeam { waist_um, .. } = &mut s.sources[0].kind {
        *waist_um = 0.1;
    }
    let d = check(&s).derived;
    let theta = d["source"]["divergence_deg"].as_f64().unwrap();
    assert!(theta > 70.0 && theta < 90.0, "{theta}");
}

/// Messages with math keep their markup in `message_math` and are plain Unicode in
/// `message`; a `$` in an element name stays literal.
#[test]
fn issue_math_has_a_plain_form() {
    let mut s = examples::example("lens").unwrap();
    if let fringe_core::scene::SourceKind::GaussianBeam { waist_um, .. } = &mut s.sources[0].kind {
        *waist_um = 0.3;
    }
    s.domain.pml_wl = 9.0;
    s.elements[0].name = "Lens $1".into();
    s.elements[0].material = fringe_core::scene::Material::Dielectric { n: 1.2, k: 0.9 };
    s.elements[0].x_um = s.domain.x_max_um - 1.0;
    let issues = validate(&s);
    let math: Vec<_> = issues.iter().filter(|i| i.message_math.is_some()).collect();
    assert!(math.len() >= 3, "{issues:?}");
    for i in &issues {
        assert!(!i.message.contains('\\'), "markup in plain message: {}", i.message);
        if let Some(tex) = &i.message_math {
            assert_eq!(fringe_core::scene::tex::plain(tex), i.message);
        } else {
            assert!(!i.message.contains("$\\"), "{}", i.message);
        }
    }
    assert!(issues.iter().any(|i| i.message.contains("w₀") && i.message.contains("λ/2")));
    assert!(issues.iter().any(|i| i.message.contains("n² − k²")));
}

#[test]
fn version_2_scenes_are_upgraded() {
    let mut v = default_value();
    v["version"] = serde_json::json!(2);
    let mut source = v["sources"][0].clone();
    for k in ["id", "name", "enabled"] {
        source.as_object_mut().unwrap().remove(k);
    }
    v.as_object_mut().unwrap().remove("sources");
    v["source"] = source;
    let s = parse_scene(&v.to_string()).unwrap();
    assert_eq!(s.version, fringe_core::scene::SCHEMA_VERSION);
    assert_eq!(s, examples::default());
    assert!(to_json(&s).contains("\"version\": 3"));
}

#[test]
fn version_2_scenes_cannot_hold_dispersive_materials() {
    let gold = fringe_core::scene::materials::preset("gold").unwrap();
    let mut v = dispersive_value(serde_json::to_value(&gold).unwrap());
    v["version"] = serde_json::json!(2);
    let e = parse_scene(&v.to_string()).unwrap_err();
    assert_eq!(e.code, "schema_version");
    assert!(e.message.contains("elements[0]"), "{}", e.message);
}

#[test]
fn version_3_scenes_with_a_single_source_parse() {
    // v3 files written before the source list existed keep the single v2
    // `source`; the source-list upgrade must keep reading them.
    let s = parse_scene(
        r#"{"version": 3, "wavelength_um": 0.5, "background": {"n": 1},
            "source": {"type": "plane_wave", "angle_deg": 0},
            "domain": {"x_min_um": -2, "x_max_um": 2, "y_min_um": -2, "y_max_um": 2},
            "elements": [{"id": "c", "x_um": 0, "y_um": 0, "material": {"type": "dispersive", "eps_inf": 1.0,
                "poles": [{"type": "drude", "plasma_ev": 9.0, "gamma_ev": 0.05}]},
                "shape": {"kind": "cylinder", "radius_um": 0.1}}]}"#,
    )
    .unwrap();
    assert_eq!(s.version, fringe_core::scene::SCHEMA_VERSION);
    assert!(errors(&validate(&s)).is_empty(), "{:?}", validate(&s));
}

fn dispersive_value(material: serde_json::Value) -> serde_json::Value {
    let mut v = default_value();
    v["elements"][0]["material"] = material;
    v
}

#[test]
fn dispersive_material_round_trips_and_validates() {
    let gold = fringe_core::scene::materials::preset("gold").unwrap();
    let v = dispersive_value(serde_json::to_value(&gold).unwrap());
    let s = parse_scene(&v.to_string()).unwrap();
    assert_eq!(parse_scene(&to_json(&s)).unwrap(), s);
    assert!(errors(&validate(&s)).is_empty(), "{:?}", validate(&s));
    // The preset label is optional, and metals (ε′ < 0) are allowed.
    let v = dispersive_value(serde_json::json!({
        "type": "dispersive", "eps_inf": 1.0,
        "poles": [{"type": "drude", "plasma_ev": 9.0, "gamma_ev": 0.05}]
    }));
    let issues = issues_of(&v);
    assert!(errors(&issues).is_empty(), "{issues:?}");
    let d = check(&parse_scene(&v.to_string()).unwrap()).derived;
    let m = &d["elements"][0]["material"];
    assert!(m["eps1"].as_f64().unwrap() < -40.0 && m["dispersive"] == true, "{m}");
}

#[test]
fn dispersive_material_errors_carry_their_paths() {
    let cases = [
        (serde_json::json!({"type": "dispersive", "eps_inf": 0.5, "poles": []}), "elements[0].material.eps_inf"),
        (
            serde_json::json!({"type": "dispersive", "eps_inf": 1.0,
                "poles": [{"type": "drude", "plasma_ev": 9.0, "gamma_ev": -0.1}]}),
            "elements[0].material.poles[0].gamma_ev",
        ),
        (
            serde_json::json!({"type": "dispersive", "eps_inf": 1.0,
                "poles": [{"type": "lorentz", "strength": -1.0, "resonance_ev": 3.0, "gamma_ev": 0.1}]}),
            "elements[0].material.poles[0].strength",
        ),
        (
            serde_json::json!({"type": "dispersive", "eps_inf": 1.0,
                "poles": [{"type": "lorentz", "strength": 1.0, "resonance_ev": 0.0, "gamma_ev": 0.1}]}),
            "elements[0].material.poles[0].resonance_ev",
        ),
        (
            // A lossless resonance exactly at λ0 = 1 µm.
            serde_json::json!({"type": "dispersive", "eps_inf": 1.0,
                "poles": [{"type": "lorentz", "strength": 1.0, "resonance_ev": 1.239841984, "gamma_ev": 0.0}]}),
            "elements[0].material.poles",
        ),
        (
            serde_json::json!({"type": "dispersive", "eps_inf": 1.0,
                "poles": vec![serde_json::json!({"type": "drude", "plasma_ev": 1.0, "gamma_ev": 0.1}); 9]}),
            "elements[0].material.poles",
        ),
        (
            // |n| ≈ 72 at 1 µm.
            serde_json::json!({"type": "dispersive", "eps_inf": 1.0,
                "poles": [{"type": "drude", "plasma_ev": 90.0, "gamma_ev": 0.01}]}),
            "elements[0].material.poles",
        ),
    ];
    for (m, path) in cases {
        let issues = issues_of(&dispersive_value(m.clone()));
        assert!(errors(&issues).iter().any(|i| i.path == path), "{m}: {issues:?}");
    }
    let unknown = dispersive_value(serde_json::json!({"type": "dispersive", "eps_inf": 1.0, "poles": [], "colour": 1}));
    assert_eq!(parse_scene(&unknown.to_string()).unwrap_err().code, "parse");
}

// Source lists and line sources.

#[test]
fn version_2_source_becomes_the_source_list() {
    let s = parse_scene(
        r#"{"version": 2, "wavelength_um": 1, "background": {"n": 1},
            "source": {"type": "plane_wave", "angle_deg": 10},
            "domain": {"x_min_um": -5, "x_max_um": 5, "y_min_um": -3, "y_max_um": 3}}"#,
    )
    .unwrap();
    assert_eq!(s.sources.len(), 1);
    let src = &s.sources[0];
    assert_eq!((src.id.as_str(), src.name.as_str(), src.enabled), (fringe_core::scene::UPGRADED_SOURCE_ID, "", true));
    assert_eq!(src.kind.angle_deg(), Some(10.0));
    // A v2 `source` may not carry the v3 keys, and v2 knows no source list or emitter.
    for bad in [
        r#""source": {"type": "plane_wave", "angle_deg": 0, "id": "x"}"#,
        r#""sources": [{"id": "a", "type": "plane_wave", "angle_deg": 0}]"#,
        r#""source": {"type": "line_source", "x_um": 0, "y_um": 0}"#,
    ] {
        let text = format!(
            r#"{{"version": 2, "wavelength_um": 1, "background": {{"n": 1}}, {bad},
                "domain": {{"x_min_um": -5, "x_max_um": 5, "y_min_um": -3, "y_max_um": 3}}}}"#
        );
        assert!(parse_scene(&text).is_err(), "{bad}");
    }
}

#[test]
fn source_and_sources_together_are_refused() {
    let mut v = default_value();
    v["source"] = serde_json::json!({"type": "plane_wave", "angle_deg": 0});
    assert_eq!(parse_scene(&v.to_string()).unwrap_err().code, "parse");
}

#[test]
fn line_sources_round_trip_with_defaults() {
    let mut v = default_value();
    v["sources"].as_array_mut().unwrap().push(serde_json::json!({"type": "line_source", "id": "e", "x_um": 1, "y_um": 2}));
    let s = parse_scene(&v.to_string()).unwrap();
    let e = &s.sources[1];
    assert!(e.enabled && e.name.is_empty());
    assert_eq!(e.kind, fringe_core::scene::SourceKind::LineSource { x_um: 1.0, y_um: 2.0, amplitude: 1.0, phase_deg: 0.0 });
    assert_eq!(parse_scene(&to_json(&s)).unwrap(), s);
    v["sources"][1]["angle_deg"] = serde_json::json!(3);
    assert_eq!(parse_scene(&v.to_string()).unwrap_err().code, "parse");
}

#[test]
fn source_list_rules() {
    let mut s = examples::default();
    s.sources.clear();
    assert_eq!(codes_at(&s, "sources"), ["no_source"]);
    let mut s = examples::default();
    s.sources[0].enabled = false;
    assert_eq!(codes_at(&s, "sources"), ["no_enabled_source"]);
    let mut s = examples::default();
    s.sources.push(s.sources[0].clone());
    assert_eq!(codes_at(&s, "sources[1].id"), ["duplicate_id"]);
    s.sources[1].id = String::new();
    assert_eq!(codes_at(&s, "sources[1].id"), ["empty_id"]);
}

#[test]
fn emitter_placement_rules() {
    use fringe_core::scene::{Source, SourceKind};
    // The default lens: centre (−4, 0), 3 µm thick at the vertex, λ_b = 1.
    let with_emitter = |x: f64, y: f64| {
        let mut s = examples::default();
        s.sources.push(Source::new("e", SourceKind::LineSource { x_um: x, y_um: y, amplitude: 1.0, phase_deg: 0.0 }));
        s
    };
    assert_eq!(codes_at(&with_emitter(-4.0, 0.0), "sources[1]"), ["emitter_inside"]);
    // The back vertex is at x = −2.5: 0.05 µm out is too close, 0.15 µm is fine.
    assert_eq!(codes_at(&with_emitter(-2.45, 0.0), "sources[1]"), ["emitter_too_close"]);
    assert!(codes_at(&with_emitter(-2.35, 0.0), "sources[1]").is_empty());
    assert_eq!(codes_at(&with_emitter(30.0, 0.0), "sources[1]"), ["outside_domain"]);
    assert_eq!(codes_at(&with_emitter(f64::NAN, 0.0), "sources[1].x_um"), ["non_finite"]);
    // A disabled emitter, or one beside a disabled element, is not checked against bodies.
    let mut s = with_emitter(-4.0, 0.0);
    s.sources[1].enabled = false;
    assert!(errors(&validate(&s)).is_empty());
    let mut s = with_emitter(-4.0, 0.0);
    s.elements[0].enabled = false;
    assert!(codes_at(&s, "sources[1]").is_empty());
}

/// The point emitter example solves with each solver; the colour scale and the
/// peak leave out the singular point.
#[test]
fn emitter_scale_ignores_the_singular_point() {
    use fringe_core::solver::{solve, Quality, SolveContext};
    let mut s = examples::example("emitter_mirror").unwrap();
    // A source on an output node (the preview grid starts at (−12, −6.75)
    // with spacing 1/6 µm).
    if let fringe_core::scene::SourceKind::LineSource { x_um, y_um, .. } = &mut s.sources[0].kind {
        *x_um = -12.0 + 36.0 * (1.0 / 6.0);
        *y_um = -6.75 + 40.0 * (1.0 / 6.0);
    }
    let f = solve(&s, Quality::Preview, &SolveContext::new()).unwrap();
    assert_eq!((f.grid.x0, f.grid.y0, f.grid.dx), (-12.0, -6.75, 1.0 / 6.0));
    let info = f.info_json();
    let peak = info["total_peak"].as_f64().unwrap();
    assert!(peak.is_finite() && peak < 4.0, "{peak}");
    assert_eq!(info["incident_peak"].as_f64(), Some(1.0));
    assert!(f.total.iter().all(|v| v.re.is_finite() && v.im.is_finite()));
}
