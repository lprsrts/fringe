mod common;

use std::ffi::{c_char, CStr, CString};
use std::ptr;
use std::time::{Duration, Instant};

use beam_core::ffi::*;

fn take(s: *mut c_char) -> String {
    assert!(!s.is_null());
    let out = unsafe { CStr::from_ptr(s) }.to_str().unwrap().to_string();
    unsafe { beam_string_free(s) };
    out
}

fn json(s: *mut c_char) -> serde_json::Value {
    serde_json::from_str(&take(s)).unwrap()
}

fn cstr(s: &str) -> CString {
    CString::new(s).unwrap()
}

fn default_scene() -> CString {
    CString::new(take(beam_scene_default())).unwrap()
}

/// Polls until the job leaves RUNNING, checking that progress never goes back.
fn wait(job: *mut BeamJob) -> BeamProgress {
    let mut last = 0.0;
    let start = Instant::now();
    loop {
        let mut p = BeamProgress { state: 99, stage: 0, fraction: -1.0, elapsed_s: 0.0, unknowns: 0 };
        unsafe { beam_job_poll(job, &mut p) };
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
    let a = std::fs::read(format!("{root}/include/beam_core.h")).unwrap();
    let b = std::fs::read(format!("{root}/swift/Sources/CBeamCore/include/beam_core.h")).unwrap();
    assert_eq!(a, b, "the two copies of beam_core.h differ");
    let text = String::from_utf8(a).unwrap();
    let line = text.lines().find(|l| l.starts_with("#define BEAM_ABI_VERSION")).unwrap();
    let v: u32 = line.split_whitespace().nth(2).unwrap().trim_end_matches('u').parse().unwrap();
    assert_eq!(v, beam_abi_version());
    assert_eq!(beam_abi_version(), 2);
    let version = unsafe { CStr::from_ptr(beam_version()) }.to_str().unwrap();
    assert_eq!(version, env!("CARGO_PKG_VERSION"));
}

#[test]
fn scenes_and_examples() {
    let list = json(unsafe { beam_scene_example(cstr("").as_ptr()) });
    let names: Vec<&str> = list.as_array().unwrap().iter().map(|e| e["name"].as_str().unwrap()).collect();
    assert!(names.contains(&"lens") && names.contains(&"double_slit"));
    for n in &names {
        let s = take(unsafe { beam_scene_example(cstr(n).as_ptr()) });
        let report = json(unsafe { beam_scene_check(cstr(&s).as_ptr()) });
        assert_eq!(report["ok"], true, "{n}: {report}");
    }
    assert!(unsafe { beam_scene_example(cstr("nope").as_ptr()) }.is_null());
    assert!(unsafe { beam_scene_example(ptr::null()) }.is_null());
    assert!(unsafe { beam_scene_check(ptr::null()) }.is_null());
    let bad = json(unsafe { beam_scene_check(cstr("{oops").as_ptr()) });
    assert_eq!(bad["ok"], false);
    assert_eq!(bad["issues"][0]["code"], "parse");
}

#[test]
fn outlines() {
    let scene = default_scene();
    let o = json(unsafe { beam_scene_outlines(scene.as_ptr()) });
    assert_eq!(o["bodies"][0]["element_id"], "lens-1");
    assert_eq!(o["bodies"][0]["pec"], false);
    assert!(o["bodies"][0]["outline"].as_array().unwrap().len() > 20);
    assert_eq!(o["source"]["kind"], "gaussian_beam");
    assert_eq!(o["source"]["w0_um"], 3.0);
    assert!((o["pml_um"].as_f64().unwrap() - 1.0).abs() < 1e-12);
    assert_eq!(o["bodies"][0]["enabled"], true);
    let e = json(unsafe { beam_scene_outlines(cstr("[]").as_ptr()) });
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
    let o = json(unsafe { beam_scene_outlines(cstr(&v.to_string()).as_ptr()) });
    let bodies = o["bodies"].as_array().unwrap();
    let find = |id: &str| bodies.iter().find(|b| b["element_id"] == id);
    assert_eq!(find("lens-1").unwrap()["enabled"], true);
    assert_eq!(find("lens-2").unwrap()["enabled"], false);
    assert_eq!(find("lens-3").unwrap()["enabled"], false);
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
        let o = json(unsafe { beam_scene_outlines(cstr(&v.to_string()).as_ptr()) });
        assert!(t.elapsed() < Duration::from_secs(2), "took {:?}", t.elapsed());
        let points: usize = o["bodies"].as_array().unwrap().iter().map(|b| b["outline"].as_array().unwrap().len()).sum();
        assert!(points <= 10_000, "{points} outline points");
    }
}

#[test]
fn job_lifecycle_on_the_default_scene() {
    let scene = default_scene();
    let mut err: *mut c_char = ptr::null_mut();
    let job = unsafe { beam_job_start(scene.as_ptr(), 0, &mut err) };
    assert!(!job.is_null() && err.is_null());
    let p = wait(job);
    assert_eq!(p.state, 1);
    assert_eq!(p.fraction, 1.0);
    let field = unsafe { beam_job_take_result(job, &mut err) };
    assert!(!field.is_null());
    let again = unsafe { beam_job_take_result(job, &mut err) };
    assert!(again.is_null());
    assert_eq!(json(err)["code"], "internal");
    err = ptr::null_mut();
    unsafe { beam_job_free(job) };

    let info = json(unsafe { beam_field_info(field) });
    assert_eq!(info["method"], "fdtd");
    assert_eq!(info["quality"], "preview");
    assert_eq!(info["incident_peak"], 1.0);
    // The incident part is A at the waist centre (to the FDTD's Yee matching).
    // The waist is 0.5 µm in front of the lens, so the scattered part there is
    // the reflection off its two faces: |r| = 0.2 each, at most about 0.4.
    let (mut re, mut im) = (0.0, 0.0);
    assert!(unsafe { beam_field_sample(field, -6.0, 0.0, 2, &mut re, &mut im) });
    assert!(((re * re + im * im).sqrt() - 1.0).abs() < 1e-3, "incident {re} {im}");
    let (mut sre, mut sim) = (0.0, 0.0);
    assert!(unsafe { beam_field_sample(field, -6.0, 0.0, 1, &mut sre, &mut sim) });
    let s = (sre * sre + sim * sim).sqrt();
    assert!(s > 0.05 && s < 0.45, "scattered {s}");
    let (mut tre, mut tim) = (0.0, 0.0);
    assert!(unsafe { beam_field_sample(field, -6.0, 0.0, 0, &mut tre, &mut tim) });
    assert!((tre - re - sre).abs() < 1e-12 && (tim - im - sim).abs() < 1e-12);
    assert!(!unsafe { beam_field_sample(field, 100.0, 0.0, 0, &mut re, &mut im) });
    assert!(!unsafe { beam_field_sample(field, 0.0, 0.0, 7, &mut re, &mut im) });

    let (w, h) = (160u32, 90u32);
    let mut buf = vec![0u8; (w * h * 4) as usize];
    let view = cstr(r#"{"quantity": "real", "colormap": "rdbu"}"#);
    assert!(unsafe { beam_field_render_rgba(field, view.as_ptr(), w, h, buf.as_mut_ptr(), buf.len(), &mut err) });
    assert!(err.is_null());
    assert!(!unsafe { beam_field_render_rgba(field, cstr("{\"nope\": 1}").as_ptr(), w, h, buf.as_mut_ptr(), buf.len(), &mut err) });
    assert_eq!(json(err)["code"], "view");
    err = ptr::null_mut();
    assert!(!unsafe { beam_field_render_rgba(field, ptr::null(), w, h, buf.as_mut_ptr(), 10, &mut err) });
    assert_eq!(json(err)["code"], "buffer");
    err = ptr::null_mut();

    let dir = std::env::temp_dir().join("beam_ffi_test");
    let png = cstr(dir.join("a.png").to_str().unwrap());
    assert!(unsafe { beam_field_export_png(field, ptr::null(), w, h, png.as_ptr(), &mut err) });
    let npy = cstr(dir.join("a.npy").to_str().unwrap());
    assert!(unsafe { beam_field_export_npy(field, 2, npy.as_ptr(), &mut err) });
    assert!(dir.join("a.npy.json").exists());
    let _ = std::fs::remove_dir_all(dir);
    unsafe { beam_field_free(field) };
}

#[test]
fn start_errors() {
    let mut err: *mut c_char = ptr::null_mut();
    assert!(unsafe { beam_job_start(cstr("{not json").as_ptr(), 0, &mut err) }.is_null());
    assert_eq!(json(err)["code"], "parse");
    err = ptr::null_mut();
    assert!(unsafe { beam_job_start(cstr(r#"{"version": 1}"#).as_ptr(), 0, &mut err) }.is_null());
    assert_eq!(json(err)["code"], "schema_version");
    err = ptr::null_mut();
    let mut v: serde_json::Value = serde_json::from_str(&take(beam_scene_default())).unwrap();
    v["elements"][0]["shape"]["center_thickness_um"] = serde_json::json!(0.5);
    assert!(unsafe { beam_job_start(cstr(&v.to_string()).as_ptr(), 1, &mut err) }.is_null());
    let e = json(err);
    assert_eq!(e["code"], "invalid");
    assert_eq!(e["issues"][0]["code"], "lens_thickness");
    assert!(unsafe { beam_job_start(ptr::null(), 0, ptr::null_mut()) }.is_null());
}

#[test]
fn freeing_a_running_job_is_safe() {
    let scene = default_scene();
    for _ in 0..20 {
        let job = unsafe { beam_job_start(scene.as_ptr(), 1, ptr::null_mut()) };
        assert!(!job.is_null());
        unsafe { beam_job_cancel(job) };
        unsafe { beam_job_cancel(job) };
        unsafe { beam_job_free(job) };
    }
    unsafe { beam_job_free(ptr::null_mut()) };
    unsafe { beam_field_free(ptr::null_mut()) };
    unsafe { beam_string_free(ptr::null_mut()) };
}

#[test]
fn concurrent_rendering() {
    let scene = default_scene();
    let job = unsafe { beam_job_start(scene.as_ptr(), 0, ptr::null_mut()) };
    wait(job);
    let field = unsafe { beam_job_take_result(job, ptr::null_mut()) };
    unsafe { beam_job_free(job) };
    let addr = field as usize;
    let renders: Vec<Vec<u8>> = std::thread::scope(|s| {
        let handles: Vec<_> = (0..4)
            .map(|_| {
                s.spawn(move || {
                    let mut buf = vec![0u8; 320 * 180 * 4];
                    for _ in 0..10 {
                        let ok = unsafe {
                            beam_field_render_rgba(addr as *const BeamField, ptr::null(), 320, 180, buf.as_mut_ptr(), buf.len(), ptr::null_mut())
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
    unsafe { beam_field_free(field) };
}

#[test]
fn colormap_lut() {
    let mut out = [0u8; 1024];
    assert!(unsafe { beam_colormap_lut(cstr("inferno").as_ptr(), 0.633, out.as_mut_ptr(), out.len()) });
    assert_eq!(&out[..4], &[0, 0, 4, 255]);
    assert_eq!(&out[1020..], &[252, 255, 164, 255]);
    assert!(unsafe { beam_colormap_lut(cstr("laser_glow").as_ptr(), 0.532, out.as_mut_ptr(), out.len()) });
    assert!(out[4 * 128 + 1] > out[4 * 128]);
    assert!(!unsafe { beam_colormap_lut(cstr("nope").as_ptr(), 0.6, out.as_mut_ptr(), out.len()) });
    assert!(!unsafe { beam_colormap_lut(cstr("inferno").as_ptr(), 0.6, out.as_mut_ptr(), 100) });
}
