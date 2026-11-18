use std::sync::Arc;

use fringe_core::puzzle::{self, compose, evaluate, parse_design, Puzzle, CHAPTERS};
use fringe_core::scene::{Element, Material, Shape};
use fringe_core::solver::{solve, FieldGrid, Method, Quality, SolveContext};
use fringe_core::types::C64;

fn xor() -> &'static Puzzle {
    puzzle::get("logic-xor").expect("the logic-xor sample")
}

fn slab(id: &str, x: f64, y: f64, rotation: f64, thickness: f64, height: f64, n: f64) -> Element {
    Element {
        id: id.into(),
        name: String::new(),
        enabled: true,
        material: Material::Dielectric { n, k: 0.0 },
        x_um: x,
        y_um: y,
        rotation_deg: rotation,
        shape: Shape::Slab { thickness_um: thickness, height_um: height },
    }
}

fn codes(p: &Puzzle, design: &[Element]) -> Vec<String> {
    compose(p, design).issues.into_iter().filter(|i| i.is_error()).map(|i| format!("{} {}", i.code, i.path)).collect()
}

#[test]
fn catalog_parses_and_is_sorted() {
    assert!(puzzle::catalog_errors().is_empty(), "{:?}", puzzle::catalog_errors());
    let list = puzzle::catalog();
    for (id, _) in CHAPTERS {
        assert!(list.iter().any(|p| p.chapter == id), "no puzzle in chapter {id}");
    }
    let keys: Vec<(usize, u32)> =
        list.iter().map(|p| (CHAPTERS.iter().position(|c| c.0 == p.chapter).unwrap(), p.order)).collect();
    assert!(keys.windows(2).all(|w| w[0] <= w[1]), "{keys:?}");
    for p in list {
        assert_eq!(puzzle::file_name(&p.id), Some(format!("{}.json", p.id)).as_deref());
        assert!(p.problems(puzzle::file_name(&p.id)).is_empty(), "{}: {:?}", p.id, p.problems(None));
        // The JSON the app gets reads back to the same puzzle.
        let back: Puzzle = serde_json::from_str(&p.to_json()).unwrap();
        assert_eq!(&back, p);
    }
    let v = puzzle::list_json();
    assert_eq!(v[0]["chapter_title"], "Steering light");
    assert!(v.as_array().unwrap().iter().all(|e| e["goal_type"].is_string() && e["stars"].as_array().unwrap().len() == 3));
}

#[test]
fn every_reference_passes_and_every_empty_design_fails() {
    for p in puzzle::catalog() {
        let r = puzzle::verify(p, &SolveContext::new()).unwrap();
        assert!(r.ok(), "{}: problems {:?}, reference {:?}, empty {:?}", p.id, r.problems, r.reference, r.empty);
        // Scoring stays quick: a few seconds at most, far less for the samples.
        assert!(r.wall_s < 10.0, "{}: {:.1} s", p.id, r.wall_s);
    }
}

#[test]
fn composed_scene_uses_the_scoring_resolution() {
    let p = xor();
    let c = compose(p, &p.reference);
    assert!(c.is_valid(), "{:?}", c.issues);
    assert_eq!(c.scene.solver.method, Method::Fem);
    assert_eq!(c.scene.solver.fem.preview_ppw, Some(p.scoring.ppw));
    assert_eq!(c.design, vec![true]);
    let p2 = fringe_core::problem::compile(&c.scene, Quality::Preview).unwrap();
    assert_eq!(p2.settings.ppw, p.scoring.ppw);
}

#[test]
fn rule_checks() {
    let p = xor();
    let good = slab("s", 0.0, 0.0, -45.0, 0.36, 6.0, 2.0);
    assert!(codes(p, std::slice::from_ref(&good)).is_empty());
    // Outside the region.
    assert_eq!(codes(p, &[slab("s", 0.0, 0.0, -45.0, 0.36, 8.0, 2.0)]), ["rule_region elements[0]"]);
    // A material the palette does not have.
    assert_eq!(codes(p, &[slab("s", 0.0, 0.0, -45.0, 0.36, 6.0, 1.5)]), ["rule_palette_material elements[0].material"]);
    // A kind the palette does not have.
    let mut cyl = good.clone();
    cyl.shape = Shape::Cylinder { radius_um: 0.5 };
    assert_eq!(codes(p, &[cyl]), ["rule_palette_kind elements[0]"]);
    // Too many: the palette's max and max_elements.
    let two = [slab("a", -1.5, 0.0, 0.0, 0.3, 1.0, 2.0), slab("b", 1.5, 0.0, 0.0, 0.3, 1.0, 2.0)];
    assert_eq!(codes(p, &two), ["rule_palette_max elements[1]", "rule_max_elements elements"]);
    // A disabled part does not count.
    let mut off = two.clone();
    off[1].enabled = false;
    assert!(codes(p, &off).is_empty());
    // Ids of the puzzle's sources and detectors are taken.
    let mut clash = good.clone();
    clash.id = "in-a".into();
    assert_eq!(codes(p, &[clash]), ["rule_id_clash elements[0].id"]);
    // Duplicate ids and overlaps are ordinary scene errors.
    let dup = [slab("a", -1.5, 0.0, 0.0, 0.3, 1.0, 2.0), slab("a", 1.5, 0.0, 0.0, 0.3, 1.0, 2.0)];
    assert!(codes(p, &dup).iter().any(|c| c.starts_with("duplicate_id")));
}

#[test]
fn locked_elements_cannot_change() {
    let mut p = xor().clone();
    p.scene.elements.push(slab("wall", 0.0, -3.5, 0.0, 0.3, 1.0, 2.0));
    p.rules.locked = vec!["wall".into()];
    let mine = slab("s", 0.0, 0.0, -45.0, 0.36, 6.0, 2.0);
    // Left out, or given unchanged: the puzzle's wall comes first either way.
    for design in [vec![mine.clone()], vec![p.scene.elements[0].clone(), mine.clone()]] {
        let c = compose(&p, &design);
        assert!(c.is_valid(), "{:?}", c.issues);
        assert_eq!(c.scene.elements[0].id, "wall");
        assert_eq!(c.design, vec![false, true]);
    }
    let mut moved = p.scene.elements[0].clone();
    moved.x_um = 1.0;
    assert_eq!(codes(&p, &[moved, mine.clone()]), ["rule_locked elements[0]"]);
    // A round trip that renames it, rounds a float or drops a preset label is
    // not a change.
    p.scene.elements[0].material = puzzle::get("metals-emitter-mirror").unwrap().reference[0].material.clone();
    let mut copy = p.scene.elements[0].clone();
    copy.name = "Wall".into();
    copy.x_um += 1e-12;
    if let Material::Dispersive { preset, .. } = &mut copy.material {
        *preset = None;
    } else {
        panic!("the emitter sample's reference is not dispersive");
    }
    assert!(codes(&p, &[copy, mine]).is_empty());
}

#[test]
fn palette_entries_are_shared_out_to_fit_every_part() {
    let mut p = xor().clone();
    p.rules.max_elements = None;
    p.rules.region = [-4.0, 4.0, -4.0, 4.0];
    let glass_only = p.rules.palette[0].clone();
    let mut any = glass_only.clone();
    any.materials.clear();
    any.max = Some(2);
    p.rules.palette = vec![glass_only, any];
    // Two glass slabs: one goes to each entry.
    let two = [slab("a", -1.5, 0.0, 0.0, 0.3, 1.0, 2.0), slab("b", 1.5, 0.0, 0.0, 0.3, 1.0, 2.0)];
    assert!(codes(&p, &two).is_empty(), "{:?}", codes(&p, &two));
    // An n = 1.5 slab first takes the "any" entry; the glass slabs still fit.
    let three = [slab("c", 0.0, 2.0, 0.0, 0.3, 1.0, 1.5), two[0].clone(), two[1].clone()];
    assert!(codes(&p, &three).is_empty(), "{:?}", codes(&p, &three));
    // A fourth part has no room left.
    let mut four = three.to_vec();
    four.push(slab("d", 0.0, -2.0, 0.0, 0.3, 1.0, 2.0));
    assert_eq!(codes(&p, &four), ["rule_palette_max elements[3]"]);
}

#[test]
fn emitter_share_is_of_the_power_it_actually_gives_off() {
    let p = puzzle::get("metals-emitter-mirror").unwrap();
    let silver = p.reference[0].material.clone();
    // Without a body the emitter gives off its free-space power.
    let empty = evaluate(p, &[], &SolveContext::new()).unwrap();
    let flux = empty.json["cases"][0]["readings"][0]["flux"]["total"].as_f64().unwrap();
    let free = puzzle::eval::source_power(&p.scene, &p.scene.sources[0]).unwrap();
    let score = empty.score().unwrap();
    assert!((score - 100.0 * flux / free).abs() < 1e-3 * score, "{score} vs {}", 100.0 * flux / free);
    // A silver shell close behind the emitter makes it give off about 45 %
    // more than in free space (a closed contour around the domain measures
    // 2.74 against 1.89, plus a little absorbed in the silver). Measured
    // against the free-space power this design would score 105 %.
    let shell = Element {
        id: "m".into(),
        name: String::new(),
        enabled: true,
        material: silver,
        x_um: 0.2,
        y_um: 0.0,
        rotation_deg: 0.0,
        shape: Shape::Lens { r1_um: Some(-0.5), r2_um: Some(-0.6), center_thickness_um: 0.1, aperture_um: 0.8 },
    };
    let e = evaluate(p, &[shell], &SolveContext::new()).unwrap();
    let score = e.score().unwrap();
    assert!(score > 65.0 && score < 80.0, "{score}");
    assert!(e.json["metric"]["text"].as_str().unwrap().contains("the power the emitter gives off"));
}

#[test]
fn an_emitter_share_stays_below_one_with_silver_close_to_it() {
    // A silver wall 0.07 µm behind the emitter and two blocks that leave a
    // resonant channel. Scored by MoM at 8 points per wavelength, the power
    // from the field at the emitter came out 15 % low and the share at
    // 110 %; FEM and MoM at 16 agree on about 86 %.
    let mut p = puzzle::get("metals-emitter-guide").unwrap().clone();
    p.scoring.method = Method::Mom;
    p.scoring.ppw = 8.0;
    let mut design = p.reference.clone();
    design[0].x_um = -1.12;
    for e in &mut design[1..] {
        if let Shape::Slab { thickness_um, .. } = &mut e.shape {
            *thickness_um = 0.712;
        }
    }
    let e = evaluate(&p, &design, &SolveContext::new()).unwrap();
    let score = e.score().unwrap();
    assert!(score > 80.0 && score < 95.0, "{score}");
}

#[test]
fn designs_parse_from_an_element_list_or_a_scene() {
    let p = xor();
    let list = serde_json::to_string(&p.reference).unwrap();
    assert_eq!(parse_design(&list).unwrap(), p.reference);
    let mut scene = p.scene.clone();
    scene.elements = p.reference.clone();
    assert_eq!(parse_design(&fringe_core::scene::to_json(&scene)).unwrap(), p.reference);
    assert!(parse_design("3").is_err());
    assert!(parse_design("[{\"id\": 1}]").is_err());
}

#[test]
fn invalid_designs_are_reported_not_solved() {
    let p = xor();
    let e = evaluate(p, &[slab("s", 0.0, 0.0, -45.0, 0.36, 8.0, 2.0)], &SolveContext::new()).unwrap();
    assert_eq!(e.json["valid"], false);
    assert_eq!(e.json["passed"], false);
    assert_eq!(e.json["stars"], 0);
    assert!(e.json["score"].is_null() && e.json["metric"].is_null());
    assert_eq!(e.json["cases"].as_array().unwrap().len(), 0);
    assert_eq!(e.json["issues"][0]["code"], "rule_region");
    assert!(e.fields.is_empty());
}

#[test]
fn cases_are_superpositions_of_the_per_source_fields() {
    let p = xor();
    let e = evaluate(p, &p.reference, &SolveContext::new()).unwrap();
    let j = &e.json;
    assert_eq!(j["valid"], true);
    assert_eq!(j["sources"], serde_json::json!(["in-a", "in-b"]));
    assert_eq!(e.fields.len(), 2);
    // Each field has only its own source on.
    for (f, id) in e.fields.iter().zip(["in-a", "in-b"]) {
        let on: Vec<&str> = f.scene.enabled_sources().map(|s| s.id.as_str()).collect();
        assert_eq!(on, [id]);
    }
    let cases = j["cases"].as_array().unwrap();
    assert_eq!(cases.len(), 4);
    assert_eq!(cases[2]["bits"], serde_json::json!([true, false]));
    assert_eq!(cases[2]["weights"], serde_json::json!([[1.0, 0.0], [0.0, 0.0]]));
    // Case A = B = 1 against one solve with both sources on: the same within
    // the solver's own round-off (FEM is linear and the mesh does not depend
    // on the sources).
    let both = compose(p, &p.reference).scene;
    let direct = solve(&both, Quality::Preview, &SolveContext::new()).unwrap();
    let direct_flux = direct.detector_readings()[0].measurement.flux().unwrap().total;
    let case_flux = cases[3]["readings"][0]["flux"]["total"].as_f64().unwrap();
    assert!((direct_flux - case_flux).abs() < 1e-9 * direct_flux.abs().max(1e-3), "{direct_flux} vs {case_flux}");
    // Combining the fields as the app does gives the case's readings.
    let fields: Vec<&FieldGrid> = e.fields.iter().map(Arc::as_ref).collect();
    let combined = FieldGrid::combine(&fields, &[C64::new(1.0, 0.0), C64::new(1.0, 0.0)]).unwrap();
    let flux = combined.detector_readings()[0].measurement.flux().unwrap().total;
    assert!((flux - case_flux).abs() < 1e-12 * case_flux.abs().max(1e-3));
    assert_eq!(combined.scene.enabled_sources().count(), 2);
    // XOR: bright for one input, dark for both and for none.
    let v: Vec<f64> = cases.iter().map(|c| c["outputs"][0]["value"].as_f64().unwrap()).collect();
    assert!(v[0].abs() < 1e-6 && v[3] < 0.05 && v[1] > 0.4 && v[2] > 0.4, "{v:?}");
    assert_eq!(j["metric"]["unit"], "dB");
    assert!(j["score"].as_f64().unwrap() >= j["pass"].as_f64().unwrap());
}

#[test]
fn evaluation_progress_is_monotone_and_cancellable() {
    let p = xor();
    let job = fringe_core::job::Job::run(move |ctx| evaluate(p, &p.reference, ctx));
    let mut last = 0.0;
    loop {
        let s = job.poll();
        assert!(s.fraction >= last);
        last = s.fraction;
        if s.state != 0 {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(1));
    }
    assert!(job.take_result().unwrap().is_ok());
    assert_eq!(last, 1.0);
    let job = fringe_core::job::Job::run(move |ctx| evaluate(p, &p.reference, ctx));
    job.cancel();
    assert!(matches!(job.wait(std::time::Duration::from_millis(5)), Err(fringe_core::solver::SolveError::Cancelled)));
}

#[test]
fn puzzle_problems_are_found() {
    let mut p = xor().clone();
    p.inputs.push("nope".into());
    p.stars = [20.0, 15.0, 10.0];
    p.rules.region = [3.0, 1.0, 0.0, 1.0];
    p.rules.palette[0].materials.push("unobtainium".into());
    p.scoring.ppw = 100.0;
    let problems = p.problems(Some("logic-xor.json")).join("\n");
    for want in ["input \"nope\"", "ascending", "rules.region", "unobtainium", "scoring.ppw", "bits for 8 cases"] {
        assert!(problems.contains(want), "{want} not in:\n{problems}");
    }
    assert!(!xor().problems(Some("other.json")).is_empty());
}
