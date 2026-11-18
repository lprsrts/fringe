mod common;

use std::ffi::{c_char, CStr, CString};
use std::ptr;
use std::time::{Duration, Instant};

use fringe_core::ffi::*;

fn take(s: *mut c_char) -> String {
    assert!(!s.is_null());
    let out = unsafe { CStr::from_ptr(s) }.to_str().unwrap().to_string();
    unsafe { fringe_string_free(s) };
    out
}

fn json(s: *mut c_char) -> serde_json::Value {
    serde_json::from_str(&take(s)).unwrap()
}

fn cstr(s: &str) -> CString {
    CString::new(s).unwrap()
}

fn default_scene() -> CString {
    CString::new(take(fringe_scene_default())).unwrap()
}

/// Polls until the job leaves RUNNING, checking that progress never goes back.
fn wait(job: *mut FringeJob) -> FringeProgress {
    let mut last = 0.0;
    let start = Instant::now();
    loop {
        let mut p = FringeProgress { state: 99, stage: 0, fraction: -1.0, elapsed_s: 0.0, unknowns: 0 };
        unsafe { fringe_job_poll(job, &mut p) };
        assert!(p.fraction >= last, "progress went back from {last} to {}", p.fraction);
        last = p.fraction;
        if p.state != 0 {
            return p;
        }
        assert!(start.elapsed() < Duration::from_secs(60));
        std::thread::sleep(Duration::from_millis(2));
    }
}

#[test]
fn headers_are_identical_and_versions_agree() {
    let root = env!("CARGO_MANIFEST_DIR");
    let a = std::fs::read(format!("{root}/include/fringe_core.h")).unwrap();
    let b = std::fs::read(format!("{root}/swift/Sources/CFringeCore/include/fringe_core.h")).unwrap();
    assert_eq!(a, b, "the two copies of fringe_core.h differ");
    let text = String::from_utf8(a).unwrap();
    let line = text.lines().find(|l| l.starts_with("#define FRINGE_ABI_VERSION")).unwrap();
    let v: u32 = line.split_whitespace().nth(2).unwrap().trim_end_matches('u').parse().unwrap();
    assert_eq!(v, fringe_abi_version());
    assert_eq!(fringe_abi_version(), 3);
    let version = unsafe { CStr::from_ptr(fringe_version()) }.to_str().unwrap();
    assert_eq!(version, env!("CARGO_PKG_VERSION"));
}

#[test]
fn scenes_and_examples() {
    let list = json(unsafe { fringe_scene_example(cstr("").as_ptr()) });
    let names: Vec<&str> = list.as_array().unwrap().iter().map(|e| e["name"].as_str().unwrap()).collect();
    assert!(names.contains(&"lens") && names.contains(&"double_slit"));
    for n in &names {
        let s = take(unsafe { fringe_scene_example(cstr(n).as_ptr()) });
        let report = json(unsafe { fringe_scene_check(cstr(&s).as_ptr()) });
        assert_eq!(report["ok"], true, "{n}: {report}");
    }
    assert!(unsafe { fringe_scene_example(cstr("nope").as_ptr()) }.is_null());
    assert!(unsafe { fringe_scene_example(ptr::null()) }.is_null());
    assert!(unsafe { fringe_scene_check(ptr::null()) }.is_null());
    let bad = json(unsafe { fringe_scene_check(cstr("{oops").as_ptr()) });
    assert_eq!(bad["ok"], false);
    assert_eq!(bad["issues"][0]["code"], "parse");
}

#[test]
fn outlines() {
    let scene = default_scene();
    let o = json(unsafe { fringe_scene_outlines(scene.as_ptr()) });
    assert_eq!(o["bodies"][0]["element_id"], "lens-1");
    assert_eq!(o["bodies"][0]["pec"], false);
    assert!(o["bodies"][0]["outline"].as_array().unwrap().len() > 20);
    assert_eq!(o["source"]["kind"], "gaussian_beam");
    assert_eq!(o["source"]["w0_um"], 3.0);
    assert!((o["pml_um"].as_f64().unwrap() - 1.0).abs() < 1e-12);
    assert_eq!(o["bodies"][0]["enabled"], true);
    let e = json(unsafe { fringe_scene_outlines(cstr("[]").as_ptr()) });
    assert_eq!(e["error"]["code"], "parse");

    // Disabled elements are listed with "enabled": false, also when their own
    // parameters would not validate (here r1 is smaller than half the aperture).
    let mut v: serde_json::Value = serde_json::from_str(scene.to_str().unwrap()).unwrap();
    let mut off = v["elements"][0].clone();
    off["id"] = "lens-2".into();
    off["enabled"] = false.into();
    off["x_um"] = 8.0.into();
    let mut bad = off.clone();
    bad["id"] = "lens-3".into();
    bad["shape"]["r1_um"] = 2.0.into();
    v["elements"].as_array_mut().unwrap().extend([off, bad]);
    let o = json(unsafe { fringe_scene_outlines(cstr(&v.to_string()).as_ptr()) });
    let bodies = o["bodies"].as_array().unwrap();
    let find = |id: &str| bodies.iter().find(|b| b["element_id"] == id);
    assert_eq!(find("lens-1").unwrap()["enabled"], true);
    assert_eq!(find("lens-2").unwrap()["enabled"], false);
    assert_eq!(find("lens-3").unwrap()["enabled"], false);

    // Every source is listed; an emitter by its point.
    let mut v: serde_json::Value = serde_json::from_str(scene.to_str().unwrap()).unwrap();
    v["sources"].as_array_mut().unwrap().push(serde_json::json!({
        "type": "line_source", "id": "e", "name": "Emitter", "enabled": false, "x_um": 1.5, "y_um": -2.0
    }));
    let o = json(unsafe { fringe_scene_outlines(cstr(&v.to_string()).as_ptr()) });
    let s = o["sources"].as_array().unwrap();
    assert_eq!(s.len(), 2);
    assert_eq!(s[0]["kind"], "gaussian_beam");
    assert_eq!(s[1]["kind"], "line_source");
    assert_eq!(s[1]["enabled"], false);
    assert_eq!(s[1]["position_um"], serde_json::json!([1.5, -2.0]));
    assert!(s[1]["angle_deg"].is_null());
    assert_eq!(o["source"]["kind"], "gaussian_beam");
}

/// Outlines are not validated, so a huge element, a tiny wavelength or an
/// element count far over the limits must still come back quickly and small.
#[test]
fn outlines_are_bounded() {
    let base: serde_json::Value = serde_json::from_str(default_scene().to_str().unwrap()).unwrap();
    let mut cases = Vec::new();
    let mut big = base.clone();
    big["elements"][0]["shape"] = serde_json::json!({ "kind": "cylinder", "radius_um": 1e5 });
    cases.push(big);
    let mut tiny = base.clone();
    tiny["wavelength_um"] = 1e-7.into();
    cases.push(tiny);
    let mut slits = base.clone();
    slits["elements"][0]["material"] = serde_json::json!({ "type": "pec" });
    slits["elements"][0]["shape"] = serde_json::json!({
        "kind": "slits", "count": 4_000_000_000u32, "slit_width_um": 1.0, "pitch_um": 2.0,
        "screen_height_um": 10.0, "thickness_um": 0.5
    });
    cases.push(slits);
    for v in cases {
        let t = Instant::now();
        let o = json(unsafe { fringe_scene_outlines(cstr(&v.to_string()).as_ptr()) });
        assert!(t.elapsed() < Duration::from_secs(2), "took {:?}", t.elapsed());
        let points: usize = o["bodies"].as_array().unwrap().iter().map(|b| b["outline"].as_array().unwrap().len()).sum();
        assert!(points <= 10_000, "{points} outline points");
    }
}

#[test]
fn job_lifecycle_on_the_default_scene() {
    let scene = default_scene();
    let mut err: *mut c_char = ptr::null_mut();
    let job = unsafe { fringe_job_start(scene.as_ptr(), 0, &mut err) };
    assert!(!job.is_null() && err.is_null());
    let p = wait(job);
    assert_eq!(p.state, 1);
    assert_eq!(p.fraction, 1.0);
    let field = unsafe { fringe_job_take_result(job, &mut err) };
    assert!(!field.is_null());
    let again = unsafe { fringe_job_take_result(job, &mut err) };
    assert!(again.is_null());
    assert_eq!(json(err)["code"], "internal");
    err = ptr::null_mut();
    unsafe { fringe_job_free(job) };

    let info = json(unsafe { fringe_field_info(field) });
    assert_eq!(info["method"], "fdtd");
    assert_eq!(info["quality"], "preview");
    assert_eq!(info["incident_peak"], 1.0);
    // The incident part is A at the waist centre (to the FDTD's Yee matching).
    // The waist is 0.5 µm in front of the lens, so the scattered part there is
    // the reflection off its two faces: |r| = 0.2 each, at most about 0.4.
    let (mut re, mut im) = (0.0, 0.0);
    assert!(unsafe { fringe_field_sample(field, -6.0, 0.0, 2, &mut re, &mut im) });
    assert!(((re * re + im * im).sqrt() - 1.0).abs() < 1e-3, "incident {re} {im}");
    let (mut sre, mut sim) = (0.0, 0.0);
    assert!(unsafe { fringe_field_sample(field, -6.0, 0.0, 1, &mut sre, &mut sim) });
    let s = (sre * sre + sim * sim).sqrt();
    assert!(s > 0.05 && s < 0.45, "scattered {s}");
    let (mut tre, mut tim) = (0.0, 0.0);
    assert!(unsafe { fringe_field_sample(field, -6.0, 0.0, 0, &mut tre, &mut tim) });
    assert!((tre - re - sre).abs() < 1e-12 && (tim - im - sim).abs() < 1e-12);
    assert!(!unsafe { fringe_field_sample(field, 100.0, 0.0, 0, &mut re, &mut im) });
    assert!(!unsafe { fringe_field_sample(field, 0.0, 0.0, 7, &mut re, &mut im) });

    let (w, h) = (160u32, 90u32);
    let mut buf = vec![0u8; (w * h * 4) as usize];
    let view = cstr(r#"{"quantity": "real", "colormap": "rdbu"}"#);
    assert!(unsafe { fringe_field_render_rgba(field, view.as_ptr(), w, h, buf.as_mut_ptr(), buf.len(), &mut err) });
    assert!(err.is_null());
    assert!(!unsafe { fringe_field_render_rgba(field, cstr("{\"nope\": 1}").as_ptr(), w, h, buf.as_mut_ptr(), buf.len(), &mut err) });
    assert_eq!(json(err)["code"], "view");
    err = ptr::null_mut();
    assert!(!unsafe { fringe_field_render_rgba(field, ptr::null(), w, h, buf.as_mut_ptr(), 10, &mut err) });
    assert_eq!(json(err)["code"], "buffer");
    err = ptr::null_mut();

    let dir = std::env::temp_dir().join("fringe_ffi_test");
    let png = cstr(dir.join("a.png").to_str().unwrap());
    assert!(unsafe { fringe_field_export_png(field, ptr::null(), w, h, png.as_ptr(), &mut err) });
    let npy = cstr(dir.join("a.npy").to_str().unwrap());
    assert!(unsafe { fringe_field_export_npy(field, 2, npy.as_ptr(), &mut err) });
    assert!(dir.join("a.npy.json").exists());
    let mut len = 0usize;
    let npz = unsafe { fringe_field_npz(field, 1, &mut len, &mut err) };
    assert!(!npz.is_null() && err.is_null());
    let bytes = unsafe { std::slice::from_raw_parts(npz, len) };
    assert_eq!(&bytes[..4], b"PK\x03\x04");
    assert_eq!(&bytes[len - 22..len - 18], b"PK\x05\x06");
    unsafe { fringe_bytes_free(npz, len) };
    unsafe { fringe_bytes_free(ptr::null_mut(), 0) };
    assert!(unsafe { fringe_field_npz(field, 9, &mut len, &mut err) }.is_null());
    assert_eq!(json(err)["code"], "view");
    err = ptr::null_mut();
    assert!(unsafe { fringe_field_npz(ptr::null(), 0, &mut len, &mut err) }.is_null());
    assert_eq!(json(err)["code"], "buffer");
    assert!(unsafe { fringe_field_npz(field, 0, ptr::null_mut(), ptr::null_mut()) }.is_null());
    let _ = std::fs::remove_dir_all(dir);
    unsafe { fringe_field_free(field) };
}

#[test]
fn start_errors() {
    let mut err: *mut c_char = ptr::null_mut();
    assert!(unsafe { fringe_job_start(cstr("{not json").as_ptr(), 0, &mut err) }.is_null());
    assert_eq!(json(err)["code"], "parse");
    err = ptr::null_mut();
    assert!(unsafe { fringe_job_start(cstr(r#"{"version": 1}"#).as_ptr(), 0, &mut err) }.is_null());
    assert_eq!(json(err)["code"], "schema_version");
    err = ptr::null_mut();
    let mut v: serde_json::Value = serde_json::from_str(&take(fringe_scene_default())).unwrap();
    v["elements"][0]["shape"]["center_thickness_um"] = serde_json::json!(0.5);
    assert!(unsafe { fringe_job_start(cstr(&v.to_string()).as_ptr(), 1, &mut err) }.is_null());
    let e = json(err);
    assert_eq!(e["code"], "invalid");
    assert_eq!(e["issues"][0]["code"], "lens_thickness");
    assert!(unsafe { fringe_job_start(ptr::null(), 0, ptr::null_mut()) }.is_null());
}

#[test]
fn freeing_a_running_job_is_safe() {
    let scene = default_scene();
    for _ in 0..20 {
        let job = unsafe { fringe_job_start(scene.as_ptr(), 1, ptr::null_mut()) };
        assert!(!job.is_null());
        unsafe { fringe_job_cancel(job) };
        unsafe { fringe_job_cancel(job) };
        unsafe { fringe_job_free(job) };
    }
    unsafe { fringe_job_free(ptr::null_mut()) };
    unsafe { fringe_field_free(ptr::null_mut()) };
    unsafe { fringe_string_free(ptr::null_mut()) };
}

#[test]
fn concurrent_rendering() {
    let scene = default_scene();
    let job = unsafe { fringe_job_start(scene.as_ptr(), 0, ptr::null_mut()) };
    wait(job);
    let field = unsafe { fringe_job_take_result(job, ptr::null_mut()) };
    unsafe { fringe_job_free(job) };
    let addr = field as usize;
    let renders: Vec<Vec<u8>> = std::thread::scope(|s| {
        let handles: Vec<_> = (0..4)
            .map(|_| {
                s.spawn(move || {
                    let mut buf = vec![0u8; 320 * 180 * 4];
                    for _ in 0..10 {
                        let ok = unsafe {
                            fringe_field_render_rgba(addr as *const FringeField, ptr::null(), 320, 180, buf.as_mut_ptr(), buf.len(), ptr::null_mut())
                        };
                        assert!(ok);
                    }
                    buf
                })
            })
            .collect();
        handles.into_iter().map(|h| h.join().unwrap()).collect()
    });
    assert!(renders.windows(2).all(|w| w[0] == w[1]));
    unsafe { fringe_field_free(field) };
}

#[test]
fn colormap_lut() {
    let mut out = [0u8; 1024];
    assert!(unsafe { fringe_colormap_lut(cstr("inferno").as_ptr(), 0.633, out.as_mut_ptr(), out.len()) });
    assert_eq!(&out[..4], &[0, 0, 4, 255]);
    assert_eq!(&out[1020..], &[252, 255, 164, 255]);
    assert!(unsafe { fringe_colormap_lut(cstr("laser_glow").as_ptr(), 0.532, out.as_mut_ptr(), out.len()) });
    assert!(out[4 * 128 + 1] > out[4 * 128]);
    assert!(!unsafe { fringe_colormap_lut(cstr("nope").as_ptr(), 0.6, out.as_mut_ptr(), out.len()) });
    assert!(!unsafe { fringe_colormap_lut(cstr("inferno").as_ptr(), 0.6, out.as_mut_ptr(), 100) });
}

#[test]
fn material_presets_and_evaluation() {
    let list = json(fringe_material_presets());
    let ids: Vec<&str> = list.as_array().unwrap().iter().map(|p| p["id"].as_str().unwrap()).collect();
    for id in ["gold", "silver", "aluminium", "copper", "bk7", "fused_silica"] {
        assert!(ids.contains(&id), "{id} missing from {ids:?}");
    }
    let gold = &list.as_array().unwrap()[0]["material"];
    assert_eq!(gold["type"], "dispersive");
    let req = serde_json::json!({ "material": gold, "wavelengths_um": [0.5, 1.0] }).to_string();
    let r = json(unsafe { fringe_material_evaluate(cstr(&req).as_ptr()) });
    let k = r["k"].as_array().unwrap();
    assert_eq!(k.len(), 2);
    assert!(k[1].as_f64().unwrap() > 5.0 && r["eps1"][1].as_f64().unwrap() < -30.0, "{r}");
    let pec = json(unsafe { fringe_material_evaluate(cstr(r#"{"material": {"type": "pec"}, "wavelengths_um": [1]}"#).as_ptr()) });
    assert!(pec["n"][0].is_null());
    let bad = json(unsafe { fringe_material_evaluate(cstr(r#"{"material": {"type": "wood"}, "wavelengths_um": [1]}"#).as_ptr()) });
    assert_eq!(bad["error"]["code"], "parse");
    assert!(unsafe { fringe_material_evaluate(ptr::null()) }.is_null());
}

#[test]
fn material_curve() {
    let silver = take(fringe_material_presets());
    let presets: serde_json::Value = serde_json::from_str(&silver).unwrap();
    let m = presets.as_array().unwrap().iter().find(|p| p["id"] == "silver").unwrap()["material"].to_string();
    let r = json(unsafe { fringe_material_curve(cstr(&m).as_ptr(), 0.4, 1.2, 5, 0.5) });
    let wl: Vec<f64> = r["wavelength_um"].as_array().unwrap().iter().map(|v| v.as_f64().unwrap()).collect();
    assert_eq!(wl.len(), 5);
    assert!((wl[0] - 0.4).abs() < 1e-12 && (wl[4] - 1.2).abs() < 1e-12 && (wl[2] - 0.8).abs() < 1e-12);
    for key in ["n", "k", "eps_re", "eps_im"] {
        assert_eq!(r[key].as_array().unwrap().len(), 5, "{key}");
    }
    // Silver absorbs: k > 0 and ε_im > 0 in the n + ik convention, ε_re < 0.
    for i in 0..5 {
        assert!(r["k"][i].as_f64().unwrap() > 0.0 && r["eps_im"][i].as_f64().unwrap() > 0.0, "{r}");
        assert!(r["eps_re"][i].as_f64().unwrap() < 0.0);
    }
    assert_eq!(r["at"]["wavelength_um"], 0.5);
    assert!(r["at"]["k"].as_f64().unwrap() > 1.0);
    // A plain dielectric gives its own n and k everywhere.
    let r = json(unsafe { fringe_material_curve(cstr(r#"{"type":"dielectric","n":1.5,"k":0.01}"#).as_ptr(), 0.5, 0.6, 1, 0.55) });
    assert_eq!(r["n"][0], 1.5);
    assert_eq!(r["k"][0], 0.01);
    let pec = json(unsafe { fringe_material_curve(cstr(r#"{"type":"pec"}"#).as_ptr(), 0.5, 0.6, 2, 0.55) });
    assert!(pec["n"][0].is_null() && pec["at"]["k"].is_null());
    for (lo, hi, n, l0) in [(0.6, 0.5, 2, 0.5), (0.5, 0.6, 0, 0.5), (0.5, 0.6, 2, -1.0), (f64::NAN, 0.6, 2, 0.5)] {
        let e = json(unsafe { fringe_material_curve(cstr(r#"{"type":"pec"}"#).as_ptr(), lo, hi, n, l0) });
        assert_eq!(e["error"]["code"], "out_of_range", "{lo} {hi} {n} {l0}");
    }
    let e = json(unsafe { fringe_material_curve(cstr(r#"{"type":"gold"}"#).as_ptr(), 0.5, 0.6, 2, 0.5) });
    assert_eq!(e["error"]["code"], "parse");
    assert!(unsafe { fringe_material_curve(ptr::null(), 0.5, 0.6, 2, 0.5) }.is_null());
}

#[test]
fn scene_upgrade_gives_the_v2_source_its_id() {
    let v2 = common::fixture("scenes/lens.json");
    let v: serde_json::Value = serde_json::from_str(&v2).unwrap();
    assert_eq!(v["version"], 2, "the lens fixture is a version 2 scene");
    let up = json(unsafe { fringe_scene_upgrade(cstr(&v2).as_ptr()) });
    assert_eq!(up["version"], 3);
    assert!(up.get("source").is_none());
    let s = &up["sources"][0];
    assert_eq!((s["id"].as_str(), s["name"].as_str(), s["enabled"].as_bool()), (Some("source-1"), Some(""), Some(true)));
    assert_eq!(s["type"], v["source"]["type"]);
    let bad = json(unsafe { fringe_scene_upgrade(cstr(r#"{"version": 1}"#).as_ptr()) });
    assert_eq!(bad["error"]["code"], "schema_version");
    assert!(unsafe { fringe_scene_upgrade(ptr::null()) }.is_null());
}

#[test]
fn check_report_has_source_ids_and_effective_materials() {
    let s = take(unsafe { fringe_scene_example(cstr("silver_dimer").as_ptr()) });
    let r = json(unsafe { fringe_scene_check(cstr(&s).as_ptr()) });
    assert_eq!(r["derived"]["sources"][0]["id"], "source-1");
    assert!(r["derived"]["sources"][0]["rayleigh_range_um"].as_f64().unwrap() > 0.0);
    let m = &r["derived"]["elements"][0]["material"];
    assert!(m["k"].as_f64().unwrap() > 0.0 && m["eps_im"].as_f64().unwrap() > 0.0 && m["eps_re"].as_f64().unwrap() < 0.0, "{m}");
    assert_eq!(m["eps_re"], m["eps1"]);
}

/// Solves an example at preview quality through the C ABI.
fn solve_example(name: &str) -> *mut FringeField {
    let s = cstr(&take(unsafe { fringe_scene_example(cstr(name).as_ptr()) }));
    let job = unsafe { fringe_job_start(s.as_ptr(), 0, ptr::null_mut()) };
    assert_eq!(wait(job).state, 1);
    let f = unsafe { fringe_job_take_result(job, ptr::null_mut()) };
    unsafe { fringe_job_free(job) };
    assert!(!f.is_null());
    f
}

#[test]
fn field_info_detectors_measure_and_memory() {
    let f = solve_example("silver_dimer");
    let info = json(unsafe { fringe_field_info(f) });
    assert!(info["meta"]["memory_mb"].as_f64().unwrap() > 0.0);
    let gap = &info["detectors"][0];
    assert_eq!((gap["id"].as_str(), gap["kind"].as_str()), (Some("gap"), Some("box")));
    assert_eq!(gap["mean_intensity"]["total"], gap["total"]["mean"]);
    assert_eq!(gap["integral"]["incident"], gap["incident"]["integral"]);
    // The same detector moved, without a solve.
    let moved = r#"[{"id": "a", "shape": {"kind": "box", "x_um": 1.0, "y_um": 0.0, "width_um": 0.2, "height_um": 0.2}},
                    {"id": "b", "enabled": false, "shape": {"kind": "line", "x1_um": 0, "y1_um": 0, "x2_um": 1, "y2_um": 0}},
                    {"id": "c", "shape": {"kind": "line", "x1_um": 2.0, "y1_um": -1.0, "x2_um": 2.0, "y2_um": 1.0}}]"#;
    let r = json(unsafe { fringe_field_measure(f, cstr(moved).as_ptr()) });
    let r = r.as_array().unwrap();
    assert_eq!(r.len(), 2);
    assert_eq!(r[0]["id"], "a");
    assert!(r[0]["mean_intensity"]["incident"].as_f64().unwrap() > 0.5);
    // A line's normal has no negative zero.
    assert_eq!(r[1]["normal"].to_string(), "[1.0,0.0]");
    // The scene's own detectors read the same as the field info.
    let scene: serde_json::Value = serde_json::from_str(&take(unsafe { fringe_scene_example(cstr("silver_dimer").as_ptr()) })).unwrap();
    let same = json(unsafe { fringe_field_measure(f, cstr(&scene["detectors"].to_string()).as_ptr()) });
    assert_eq!(same[0], info["detectors"][0]);
    let outside = r#"[{"id": "x", "shape": {"kind": "box", "x_um": 40, "y_um": 0, "width_um": 1, "height_um": 1}}]"#;
    let e = json(unsafe { fringe_field_measure(f, cstr(outside).as_ptr()) });
    assert_eq!(e["error"]["issues"][0]["code"], "outside_domain");
    let e = json(unsafe { fringe_field_measure(f, cstr("{").as_ptr()) });
    assert_eq!(e["error"]["code"], "parse");
    assert!(unsafe { fringe_field_measure(f, ptr::null()) }.is_null());
    unsafe { fringe_field_free(f) };
}

#[test]
fn puzzle_list_and_get() {
    let list = json(fringe_puzzle_list());
    let list = list.as_array().unwrap();
    assert!(!list.is_empty());
    for key in ["id", "chapter", "chapter_title", "order", "title", "summary", "goal_type", "stars"] {
        assert!(list.iter().all(|p| p.get(key).is_some()), "{key}");
    }
    let id = list[0]["id"].as_str().unwrap();
    let p = json(unsafe { fringe_puzzle_get(cstr(id).as_ptr()) });
    assert_eq!(p["id"], id);
    for key in ["scene", "inputs", "goal", "rules", "scoring", "stars", "reference", "hints"] {
        assert!(p.get(key).is_some(), "{key}");
    }
    assert!(unsafe { fringe_puzzle_get(cstr("nope").as_ptr()) }.is_null());
    assert!(unsafe { fringe_puzzle_get(ptr::null()) }.is_null());
}

#[test]
fn puzzle_job_result_and_combination() {
    let p = json(unsafe { fringe_puzzle_get(cstr("logic-xor").as_ptr()) });
    let design = cstr(&p["reference"].to_string());
    let mut err = ptr::null_mut();
    let job = unsafe { fringe_puzzle_job_start(cstr("logic-xor").as_ptr(), design.as_ptr(), &mut err) };
    assert!(!job.is_null() && err.is_null());
    assert_eq!(wait(job).state, 1);
    // A puzzle job's result is not a field.
    let mut err = ptr::null_mut();
    assert!(unsafe { fringe_job_take_result(job, &mut err) }.is_null());
    assert_eq!(json(err)["code"], "wrong_job");
    let res = unsafe { fringe_puzzle_job_take_result(job, ptr::null_mut()) };
    assert!(!res.is_null());
    let mut err = ptr::null_mut();
    assert!(unsafe { fringe_puzzle_job_take_result(job, &mut err) }.is_null());
    assert_eq!(json(err)["code"], "internal");
    unsafe { fringe_job_free(job) };

    let r = json(unsafe { fringe_puzzle_result_json(res) });
    for key in ["puzzle", "valid", "issues", "sources", "inputs", "cases", "metric", "score", "pass", "passed", "stars", "star_thresholds", "wall_s"] {
        assert!(r.get(key).is_some(), "{key}");
    }
    assert_eq!(r["passed"], true);
    let count = unsafe { fringe_puzzle_result_field_count(res) };
    assert_eq!(count as usize, r["sources"].as_array().unwrap().len());
    let fields: Vec<*mut FringeField> = (0..count).map(|i| unsafe { fringe_puzzle_result_field(res, i) }).collect();
    assert!(fields.iter().all(|f| !f.is_null()));
    assert!(unsafe { fringe_puzzle_result_field(res, count) }.is_null());
    unsafe { fringe_puzzle_result_free(res) };

    // The fields outlive the result. Case A = 1, B = 1 by combination:
    let case = &r["cases"][3];
    let (re, im): (Vec<f64>, Vec<f64>) =
        case["weights"].as_array().unwrap().iter().map(|w| (w[0].as_f64().unwrap(), w[1].as_f64().unwrap())).unzip();
    let ptrs: Vec<*const FringeField> = fields.iter().map(|&f| f as *const _).collect();
    let mut err = ptr::null_mut();
    let both = unsafe { fringe_field_combine(ptrs.as_ptr(), re.as_ptr(), im.as_ptr(), ptrs.len(), &mut err) };
    assert!(!both.is_null() && err.is_null());
    let info = json(unsafe { fringe_field_info(both) });
    let want = case["readings"][0]["flux"]["total"].as_f64().unwrap();
    let got = info["detectors"][0]["flux"]["total"].as_f64().unwrap();
    assert!((got - want).abs() < 1e-12 * want.abs().max(1e-3), "{got} vs {want}");
    unsafe { fringe_field_free(both) };
    // Only input B on: the scene of the combination says so.
    let (re, im) = ([0.0, 1.0], [0.0, 0.0]);
    let b = unsafe { fringe_field_combine(ptrs.as_ptr(), re.as_ptr(), im.as_ptr(), 2, ptr::null_mut()) };
    let mut x = 0.0;
    assert!(unsafe { fringe_field_sample(b, 0.0, 3.0, 2, &mut x, ptr::null_mut()) });
    unsafe { fringe_field_free(b) };
    let mut err = ptr::null_mut();
    assert!(unsafe { fringe_field_combine(ptrs.as_ptr(), re.as_ptr(), im.as_ptr(), 0, &mut err) }.is_null());
    assert_eq!(json(err)["code"], "buffer");
    // Fields from another scene do not combine.
    let other = solve_example("lens");
    let mixed = [ptrs[0], other as *const FringeField];
    let mut err = ptr::null_mut();
    assert!(unsafe { fringe_field_combine(mixed.as_ptr(), re.as_ptr(), im.as_ptr(), 2, &mut err) }.is_null());
    assert_eq!(json(err)["code"], "combine");
    unsafe { fringe_field_free(other) };
    for f in fields {
        unsafe { fringe_field_free(f) };
    }
}

#[test]
fn puzzle_job_errors_and_invalid_designs() {
    let mut err = ptr::null_mut();
    assert!(unsafe { fringe_puzzle_job_start(cstr("nope").as_ptr(), cstr("[]").as_ptr(), &mut err) }.is_null());
    assert_eq!(json(err)["code"], "unknown_puzzle");
    let mut err = ptr::null_mut();
    assert!(unsafe { fringe_puzzle_job_start(cstr("logic-xor").as_ptr(), cstr("[{").as_ptr(), &mut err) }.is_null());
    assert_eq!(json(err)["code"], "parse");
    assert!(unsafe { fringe_puzzle_job_start(ptr::null(), ptr::null(), ptr::null_mut()) }.is_null());
    // A design outside the region runs and comes back invalid, with no fields.
    let bad = r#"[{"id": "s", "material": {"type": "dielectric", "n": 2}, "x_um": 4, "y_um": 4,
                   "shape": {"kind": "slab", "thickness_um": 0.3, "height_um": 0.5}}]"#;
    let job = unsafe { fringe_puzzle_job_start(cstr("logic-xor").as_ptr(), cstr(bad).as_ptr(), ptr::null_mut()) };
    assert_eq!(wait(job).state, 1);
    let res = unsafe { fringe_puzzle_job_take_result(job, ptr::null_mut()) };
    let r = json(unsafe { fringe_puzzle_result_json(res) });
    assert_eq!(r["valid"], false);
    assert_eq!(r["issues"][0]["code"], "rule_region");
    assert_eq!(unsafe { fringe_puzzle_result_field_count(res) }, 0);
    unsafe { fringe_puzzle_result_free(res) };
    // A solve job cannot be taken as a puzzle result.
    let f_job = unsafe { fringe_job_start(default_scene().as_ptr(), 0, ptr::null_mut()) };
    wait(f_job);
    let mut err = ptr::null_mut();
    assert!(unsafe { fringe_puzzle_job_take_result(f_job, &mut err) }.is_null());
    assert_eq!(json(err)["code"], "wrong_job");
    unsafe { fringe_job_free(f_job) };
    unsafe { fringe_job_free(job) };
    assert!(unsafe { fringe_puzzle_result_json(ptr::null()) }.is_null());
    assert_eq!(unsafe { fringe_puzzle_result_field_count(ptr::null()) }, 0);
    unsafe { fringe_puzzle_result_free(ptr::null_mut()) };
}
