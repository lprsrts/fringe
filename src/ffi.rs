//! C ABI (`include/fringe_core.h`). Every entry point catches panics; strings
//! returned to the caller are released with `fringe_string_free`, byte buffers
//! with `fringe_bytes_free`.

use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use std::sync::Arc;

use serde_json::{json, Value};

use crate::check::check_json;
use crate::geometry::{element_bodies, BodyMaterial, MAX_POLYGON_VERTICES};
use crate::job::Job;
use crate::render::{export_png_file, npz_c128, render_rgba, write_npy_c128, Colormap, View};
use crate::scene::validate::{MAX_GRATING_BARS, MAX_SLITS};
use crate::scene::{examples, parse_scene, to_json, validate, Detector, DetectorShape, Issue, Material, Shape, SourceKind};
use crate::solver::context::{STATE_CANCELLED, STATE_DONE, STATE_FAILED};
use crate::solver::{FieldGrid, Part, Quality, SolveError};
use crate::types::{Vec2, C64};

pub const FRINGE_ABI_VERSION: u32 = 3;

/// Matches `FringeProgress` in the header.
#[repr(C)]
pub struct FringeProgress {
    pub state: u32,
    pub stage: u32,
    pub fraction: f64,
    pub elapsed_s: f64,
    pub unknowns: u64,
}

pub struct FringeJob(Job);
pub struct FringeField(Arc<FieldGrid>);

fn guard<T>(fallback: T, f: impl FnOnce() -> T) -> T {
    catch_unwind(AssertUnwindSafe(f)).unwrap_or(fallback)
}

fn into_c(s: String) -> *mut c_char {
    CString::new(s.replace('\0', "")).map_or(ptr::null_mut(), CString::into_raw)
}

unsafe fn str_arg<'a>(p: *const c_char) -> Option<&'a str> {
    if p.is_null() {
        None
    } else {
        CStr::from_ptr(p).to_str().ok()
    }
}

fn error_json(code: &str, message: impl Into<String>, issues: &[Issue]) -> String {
    json!({ "code": code, "message": message.into(), "issues": issues }).to_string()
}

unsafe fn set_error(out: *mut *mut c_char, code: &str, message: impl Into<String>, issues: &[Issue]) {
    if !out.is_null() {
        *out = into_c(error_json(code, message, issues));
    }
}

unsafe fn set_solve_error(out: *mut *mut c_char, e: &SolveError) {
    set_error(out, e.code(), e.to_string(), e.issues());
}

#[no_mangle]
pub extern "C" fn fringe_abi_version() -> u32 {
    FRINGE_ABI_VERSION
}

#[no_mangle]
pub extern "C" fn fringe_version() -> *const c_char {
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr() as *const c_char
}

/// # Safety
/// `s` must be NULL or a string returned by this library, freed once.
#[no_mangle]
pub unsafe extern "C" fn fringe_string_free(s: *mut c_char) {
    if !s.is_null() {
        guard((), || drop(CString::from_raw(s)));
    }
}

#[no_mangle]
pub extern "C" fn fringe_scene_default() -> *mut c_char {
    guard(ptr::null_mut(), || into_c(to_json(&examples::default())))
}

/// # Safety
/// `name` must be NULL or a valid C string.
#[no_mangle]
pub unsafe extern "C" fn fringe_scene_example(name: *const c_char) -> *mut c_char {
    guard(ptr::null_mut(), || {
        let Some(name) = str_arg(name) else { return ptr::null_mut() };
        if name.is_empty() {
            let list: Vec<Value> = examples::EXAMPLES
                .iter()
                .map(|e| {
                    json!({
                        "name": e.name, "title": e.title, "method": e.method,
                        "quantity": e.quantity, "colormap": e.colormap,
                    })
                })
                .collect();
            return into_c(Value::Array(list).to_string());
        }
        examples::example(name).map_or(ptr::null_mut(), |s| into_c(to_json(&s)))
    })
}

/// # Safety
/// `scene_json` must be NULL or a valid C string.
#[no_mangle]
pub unsafe extern "C" fn fringe_scene_check(scene_json: *const c_char) -> *mut c_char {
    if scene_json.is_null() {
        return ptr::null_mut();
    }
    guard(ptr::null_mut(), || {
        let report = match str_arg(scene_json) {
            Some(s) => check_json(s),
            None => crate::check::CheckReport {
                ok: false,
                issues: vec![Issue::error("", "parse", "scene is not valid UTF-8")],
                estimates: None,
                derived: Value::Null,
            },
        };
        into_c(serde_json::to_string(&report).unwrap_or_default())
    })
}

/// Body outlines (of every element, disabled ones flagged), PML thickness,
/// source placement and detector outlines for the app's overlays.
pub fn scene_outlines_json(scene_json: &str) -> Value {
    let scene = match parse_scene(scene_json) {
        Ok(s) => s,
        Err(e) => return json!({ "error": { "code": e.code, "message": e.message } }),
    };
    let lambda_b = scene.wavelength_um / scene.background.n;
    let chord = lambda_b / 20.0;
    // Disabled elements are listed too (flagged), so the app can draw and select
    // them; an element whose parameters do not give a finite outline is skipped,
    // and so is one with more slits, bars or vertices than validation allows
    // (the scene is not validated here, and those would cost time and memory in
    // proportion). `polyline` bounds the points per contour.
    let bodies: Vec<Value> = scene
        .elements
        .iter()
        .enumerate()
        .filter(|(_, e)| match &e.shape {
            Shape::Slits { count, .. } => *count <= MAX_SLITS,
            Shape::Grating { count, .. } => *count <= MAX_GRATING_BARS,
            Shape::Polygon { vertices_um } => vertices_um.len() <= MAX_POLYGON_VERTICES,
            _ => true,
        })
        .flat_map(|(i, e)| element_bodies(i, e, scene.wavelength_um).into_iter().map(move |b| (e.enabled, b)))
        .filter_map(|(enabled, b)| {
            let outline: Vec<[f64; 2]> = b.contour.polyline(chord, 2f64.to_radians()).iter().map(|p| p.to_array()).collect();
            if outline.is_empty() || outline.iter().flatten().any(|v| !v.is_finite()) {
                return None;
            }
            Some(json!({
                "element_id": b.element_id,
                "enabled": enabled,
                "pec": matches!(b.material, BodyMaterial::Pec),
                "outline": outline,
            }))
        })
        .collect();
    let d = &scene.domain;
    // Where to draw each source: a beam's waist (the domain centre for a plane
    // wave) with its direction, or an emitter's point.
    let placement = |k: &SourceKind| match *k {
        SourceKind::GaussianBeam { waist_um, waist_x_um, waist_y_um, angle_deg, .. } => {
            ([waist_x_um, waist_y_um], Some(angle_deg), Some(waist_um))
        }
        SourceKind::PlaneWave { angle_deg, .. } => {
            ([0.5 * (d.x_min_um + d.x_max_um), 0.5 * (d.y_min_um + d.y_max_um)], Some(angle_deg), None)
        }
        SourceKind::LineSource { x_um, y_um, .. } => ([x_um, y_um], None, None),
    };
    let sources: Vec<Value> = scene
        .sources
        .iter()
        .map(|s| {
            let (pos, angle, w0) = placement(&s.kind);
            json!({
                "id": s.id, "name": s.name, "enabled": s.enabled, "kind": s.kind.kind_name(),
                "position_um": pos, "angle_deg": angle, "w0_um": w0,
            })
        })
        .collect();
    // The version 2 shape, for the first enabled source.
    let source = scene.enabled_sources().next().or(scene.sources.first()).map_or(Value::Null, |s| {
        let (pos, angle, w0) = placement(&s.kind);
        json!({ "kind": s.kind.kind_name(), "waist_um": pos, "angle_deg": angle, "w0_um": w0 })
    });
    // Detectors as drawn: a line's two end points and the side its flux counts
    // positive, a box's four corners. Non-finite ones are skipped.
    let detectors: Vec<Value> = scene
        .detectors
        .iter()
        .filter_map(|det| {
            let points = crate::detectors::outline(&det.shape);
            if points.iter().flatten().any(|v| !v.is_finite()) {
                return None;
            }
            let normal = match det.shape {
                DetectorShape::Line { x1_um, y1_um, x2_um, y2_um } => {
                    json!(crate::detectors::line_normal(Vec2::new(x1_um, y1_um), Vec2::new(x2_um, y2_um)).to_array())
                }
                DetectorShape::Box { .. } => Value::Null,
            };
            Some(json!({
                "id": det.id, "name": det.name, "enabled": det.enabled, "kind": det.shape.kind_name(),
                "points_um": points, "normal": normal,
            }))
        })
        .collect();
    json!({
        "domain": { "x_min_um": d.x_min_um, "x_max_um": d.x_max_um, "y_min_um": d.y_min_um, "y_max_um": d.y_max_um, "pml_wl": d.pml_wl },
        "pml_um": d.pml_wl * lambda_b,
        "bodies": bodies,
        "source": source,
        "sources": sources,
        "detectors": detectors,
    })
}

/// # Safety
/// `scene_json` must be NULL or a valid C string.
#[no_mangle]
pub unsafe extern "C" fn fringe_scene_outlines(scene_json: *const c_char) -> *mut c_char {
    if scene_json.is_null() {
        return ptr::null_mut();
    }
    guard(ptr::null_mut(), || {
        let v = match str_arg(scene_json) {
            Some(s) => scene_outlines_json(s),
            None => json!({ "error": { "code": "parse", "message": "scene is not valid UTF-8" } }),
        };
        into_c(v.to_string())
    })
}

fn quality_from(q: u32) -> Option<Quality> {
    match q {
        0 => Some(Quality::Preview),
        1 => Some(Quality::Final),
        _ => None,
    }
}

/// # Safety
/// `scene_json` must be NULL or a valid C string; `error_json_out` NULL or writable.
#[no_mangle]
pub unsafe extern "C" fn fringe_job_start(scene_json: *const c_char, quality: u32, error_json_out: *mut *mut c_char) -> *mut FringeJob {
    guard(ptr::null_mut(), || {
        let Some(text) = str_arg(scene_json) else {
            set_error(error_json_out, "parse", "scene JSON is NULL or not UTF-8", &[]);
            return ptr::null_mut();
        };
        let Some(q) = quality_from(quality) else {
            set_error(error_json_out, "invalid", format!("unknown quality {quality}"), &[]);
            return ptr::null_mut();
        };
        let scene = match parse_scene(text) {
            Ok(s) => s,
            Err(e) => {
                set_error(error_json_out, e.code, e.message, &[]);
                return ptr::null_mut();
            }
        };
        let issues: Vec<Issue> = validate(&scene).into_iter().filter(|i| i.is_error() && i.applies_to(q)).collect();
        if let Some(first) = issues.first() {
            let msg = first.message.clone();
            set_error(error_json_out, "invalid", msg, &issues);
            return ptr::null_mut();
        }
        Box::into_raw(Box::new(FringeJob(Job::spawn(scene, q))))
    })
}

/// # Safety
/// `job` must be NULL or a live job; `out` NULL or writable.
#[no_mangle]
pub unsafe extern "C" fn fringe_job_poll(job: *const FringeJob, out: *mut FringeProgress) {
    if job.is_null() || out.is_null() {
        return;
    }
    guard((), || {
        let s = (*job).0.poll();
        *out = FringeProgress { state: s.state, stage: s.stage, fraction: s.fraction, elapsed_s: s.elapsed_s, unknowns: s.unknowns };
    })
}

/// # Safety
/// `job` must be NULL or a live job.
#[no_mangle]
pub unsafe extern "C" fn fringe_job_cancel(job: *mut FringeJob) {
    if !job.is_null() {
        guard((), || (*job).0.cancel());
    }
}

/// # Safety
/// `job` must be NULL or a live job; `error_json_out` NULL or writable.
#[no_mangle]
pub unsafe extern "C" fn fringe_job_take_result(job: *mut FringeJob, error_json_out: *mut *mut c_char) -> *mut FringeField {
    if job.is_null() {
        return ptr::null_mut();
    }
    guard(ptr::null_mut(), || {
        let job = &(*job).0;
        let state = job.poll().state;
        match job.take_result() {
            Some(Ok(field)) => Box::into_raw(Box::new(FringeField(field))),
            Some(Err(e)) => {
                set_solve_error(error_json_out, &e);
                ptr::null_mut()
            }
            None => {
                match state {
                    STATE_DONE => set_error(error_json_out, "internal", "the result was already taken", &[]),
                    STATE_CANCELLED => set_error(error_json_out, "cancelled", "cancelled", &[]),
                    STATE_FAILED => set_error(error_json_out, "internal", "the error was already taken", &[]),
                    _ => {}
                }
                ptr::null_mut()
            }
        }
    })
}

/// # Safety
/// `job` must be NULL or a job not yet freed.
#[no_mangle]
pub unsafe extern "C" fn fringe_job_free(job: *mut FringeJob) {
    if !job.is_null() {
        guard((), || drop(Box::from_raw(job)));
    }
}

/// # Safety
/// `field` must be NULL or a live field.
#[no_mangle]
pub unsafe extern "C" fn fringe_field_info(field: *const FringeField) -> *mut c_char {
    if field.is_null() {
        return ptr::null_mut();
    }
    guard(ptr::null_mut(), || into_c((*field).0.info_json().to_string()))
}

/// # Safety
/// `field` must be NULL or a live field; the outputs NULL or writable.
#[no_mangle]
pub unsafe extern "C" fn fringe_field_sample(
    field: *const FringeField,
    x_um: f64,
    y_um: f64,
    part: u32,
    out_re: *mut f64,
    out_im: *mut f64,
) -> bool {
    if field.is_null() {
        return false;
    }
    guard(false, || {
        let Some(part) = Part::from_u32(part) else { return false };
        match (*field).0.sample(part, Vec2::new(x_um, y_um)) {
            Some(v) => {
                if !out_re.is_null() {
                    *out_re = v.re;
                }
                if !out_im.is_null() {
                    *out_im = v.im;
                }
                true
            }
            None => false,
        }
    })
}

unsafe fn view_arg(view_json: *const c_char, error_json_out: *mut *mut c_char) -> Option<View> {
    let text = if view_json.is_null() {
        ""
    } else {
        match str_arg(view_json) {
            Some(s) => s,
            None => {
                set_error(error_json_out, "view", "view JSON is not UTF-8", &[]);
                return None;
            }
        }
    };
    match View::parse(text) {
        Ok(v) => Some(v),
        Err(e) => {
            set_error(error_json_out, e.code(), e.to_string(), &[]);
            None
        }
    }
}

/// # Safety
/// `field` must be NULL or live, `out_rgba` must hold `out_len` bytes, and the
/// strings must be NULL or valid.
#[no_mangle]
pub unsafe extern "C" fn fringe_field_render_rgba(
    field: *const FringeField,
    view_json: *const c_char,
    width: u32,
    height: u32,
    out_rgba: *mut u8,
    out_len: usize,
    error_json_out: *mut *mut c_char,
) -> bool {
    if field.is_null() || out_rgba.is_null() {
        set_error(error_json_out, "buffer", "field or output buffer is NULL", &[]);
        return false;
    }
    guard(false, || {
        let Some(view) = view_arg(view_json, error_json_out) else { return false };
        let out = std::slice::from_raw_parts_mut(out_rgba, out_len);
        match render_rgba(&(*field).0, &view, width, height, out) {
            Ok(()) => true,
            Err(e) => {
                set_error(error_json_out, e.code(), e.to_string(), &[]);
                false
            }
        }
    })
}

/// # Safety
/// `field` must be NULL or live; the strings NULL or valid.
#[no_mangle]
pub unsafe extern "C" fn fringe_field_export_png(
    field: *const FringeField,
    view_json: *const c_char,
    width: u32,
    height: u32,
    path: *const c_char,
    error_json_out: *mut *mut c_char,
) -> bool {
    if field.is_null() {
        set_error(error_json_out, "buffer", "field is NULL", &[]);
        return false;
    }
    guard(false, || {
        let Some(path) = str_arg(path) else {
            set_error(error_json_out, "io", "path is NULL or not UTF-8", &[]);
            return false;
        };
        let Some(view) = view_arg(view_json, error_json_out) else { return false };
        let result = (|| {
            let mut rgba = vec![0u8; width as usize * height as usize * 4];
            render_rgba(&(*field).0, &view, width, height, &mut rgba)?;
            export_png_file(path, &rgba, width, height)
        })();
        match result {
            Ok(()) => true,
            Err(e) => {
                set_error(error_json_out, e.code(), e.to_string(), &[]);
                false
            }
        }
    })
}

/// # Safety
/// `field` must be NULL or live; `path` NULL or valid.
#[no_mangle]
pub unsafe extern "C" fn fringe_field_export_npy(
    field: *const FringeField,
    part: u32,
    path: *const c_char,
    error_json_out: *mut *mut c_char,
) -> bool {
    if field.is_null() {
        set_error(error_json_out, "buffer", "field is NULL", &[]);
        return false;
    }
    guard(false, || {
        let Some(path) = str_arg(path) else {
            set_error(error_json_out, "io", "path is NULL or not UTF-8", &[]);
            return false;
        };
        let Some(part) = Part::from_u32(part) else {
            set_error(error_json_out, "view", format!("unknown part {part}"), &[]);
            return false;
        };
        match write_npy_c128(path, &(*field).0, part) {
            Ok(()) => true,
            Err(e) => {
                set_error(error_json_out, e.code(), e.to_string(), &[]);
                false
            }
        }
    })
}

/// # Safety
/// `field` must be NULL or live; `out_len` NULL or writable.
#[no_mangle]
pub unsafe extern "C" fn fringe_field_npz(
    field: *const FringeField,
    part: u32,
    out_len: *mut usize,
    error_json_out: *mut *mut c_char,
) -> *mut u8 {
    if field.is_null() || out_len.is_null() {
        set_error(error_json_out, "buffer", "field or out_len is NULL", &[]);
        return ptr::null_mut();
    }
    guard(ptr::null_mut(), || {
        let Some(part) = Part::from_u32(part) else {
            set_error(error_json_out, "view", format!("unknown part {part}"), &[]);
            return ptr::null_mut();
        };
        match npz_c128(&(*field).0, part) {
            Ok(bytes) => {
                // A boxed slice has exactly `len` capacity, so `fringe_bytes_free`
                // can rebuild it from the pointer and length alone.
                let bytes = bytes.into_boxed_slice();
                *out_len = bytes.len();
                Box::into_raw(bytes).cast::<u8>()
            }
            Err(e) => {
                set_error(error_json_out, e.code(), e.to_string(), &[]);
                ptr::null_mut()
            }
        }
    })
}

/// # Safety
/// `bytes` must be NULL or a buffer from this library not yet freed, with the
/// length it was returned with.
#[no_mangle]
pub unsafe extern "C" fn fringe_bytes_free(bytes: *mut u8, len: usize) {
    if !bytes.is_null() {
        guard((), || drop(Box::from_raw(ptr::slice_from_raw_parts_mut(bytes, len))));
    }
}

/// # Safety
/// `field` must be NULL or a field not yet freed.
#[no_mangle]
pub unsafe extern "C" fn fringe_field_free(field: *mut FringeField) {
    if !field.is_null() {
        guard((), || drop(Box::from_raw(field)));
    }
}

#[no_mangle]
pub extern "C" fn fringe_material_presets() -> *mut c_char {
    guard(ptr::null_mut(), || into_c(crate::scene::materials::presets_json().to_string()))
}

/// `{"material", "wavelengths_um"}` to n, k, ε1, ε2 per wavelength (see the header).
pub fn material_evaluate_json(request: &str) -> Value {
    let err = |code: &str, message: String| json!({ "error": { "code": code, "message": message } });
    #[derive(serde::Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Request {
        material: crate::scene::Material,
        wavelengths_um: Vec<f64>,
    }
    let r: Request = match serde_json::from_str(request) {
        Ok(r) => r,
        Err(e) => return err("parse", format!("invalid request: {e}")),
    };
    if let Some(l) = r.wavelengths_um.iter().find(|l| !(l.is_finite() && **l > 0.0)) {
        return err("out_of_range", format!("wavelengths must be positive (got {l})"));
    }
    let (mut n, mut k, mut e1, mut e2) = (Vec::new(), Vec::new(), Vec::new(), Vec::new());
    for &l in &r.wavelengths_um {
        let finite = |v: f64| if v.is_finite() { json!(v) } else { Value::Null };
        match (r.material.index_at(l), r.material.eps_at(l)) {
            (Some(nc), Some(eps)) => {
                n.push(finite(nc.re));
                k.push(finite(-nc.im));
                e1.push(finite(eps.re));
                e2.push(finite(-eps.im));
            }
            _ => {
                for v in [&mut n, &mut k, &mut e1, &mut e2] {
                    v.push(Value::Null);
                }
            }
        }
    }
    json!({ "n": n, "k": k, "eps1": e1, "eps2": e2 })
}

/// # Safety
/// `request_json` must be NULL or a valid C string.
#[no_mangle]
pub unsafe extern "C" fn fringe_material_evaluate(request_json: *const c_char) -> *mut c_char {
    if request_json.is_null() {
        return ptr::null_mut();
    }
    guard(ptr::null_mut(), || {
        let v = match str_arg(request_json) {
            Some(s) => material_evaluate_json(s),
            None => json!({ "error": { "code": "parse", "message": "request is not valid UTF-8" } }),
        };
        into_c(v.to_string())
    })
}

/// # Safety
/// `name` must be NULL or valid; `out_rgba` must hold `out_len` bytes.
#[no_mangle]
pub unsafe extern "C" fn fringe_colormap_lut(name: *const c_char, wavelength_um: f64, out_rgba: *mut u8, out_len: usize) -> bool {
    if out_rgba.is_null() || out_len < 1024 {
        return false;
    }
    guard(false, || {
        let Some(cm) = str_arg(name).and_then(|n| n.parse::<Colormap>().ok()) else { return false };
        let out = std::slice::from_raw_parts_mut(out_rgba, 1024);
        for (dst, c) in out.as_chunks_mut::<4>().0.iter_mut().zip(cm.lut(wavelength_um * 1000.0, 256)) {
            dst.copy_from_slice(&c);
        }
        true
    })
}

/// Evaluates a material over a wavelength range for plotting: `count`
/// wavelengths spaced evenly from `lambda_min_um` to `lambda_max_um`, and the
/// value at `lambda0_um`. n + ik and ε_re + i ε_im in the optics convention
/// (k, ε_im ≥ 0 absorb); PEC and non-finite values give nulls.
pub fn material_curve_json(material_json: &str, lambda_min_um: f64, lambda_max_um: f64, count: u32, lambda0_um: f64) -> Value {
    let err = |code: &str, message: String| json!({ "error": { "code": code, "message": message } });
    let material: Material = match serde_json::from_str(material_json) {
        Ok(m) => m,
        Err(e) => return err("parse", format!("invalid material: {e}")),
    };
    let positive = |v: f64| v.is_finite() && v > 0.0;
    if !(positive(lambda_min_um) && positive(lambda_max_um) && lambda_min_um <= lambda_max_um) {
        return err("out_of_range", format!("the range must be positive with min <= max (got {lambda_min_um} to {lambda_max_um})"));
    }
    if !positive(lambda0_um) {
        return err("out_of_range", format!("the scene wavelength must be positive (got {lambda0_um})"));
    }
    if !(1..=MAX_CURVE_POINTS).contains(&count) {
        return err("out_of_range", format!("count must be 1 to {MAX_CURVE_POINTS} (got {count})"));
    }
    let finite = |v: f64| if v.is_finite() { json!(v) } else { Value::Null };
    let at = |l: f64| match (material.index_at(l), material.eps_at(l)) {
        (Some(n), Some(e)) => [finite(n.re), finite(-n.im), finite(e.re), finite(-e.im)],
        _ => [Value::Null, Value::Null, Value::Null, Value::Null],
    };
    let mut cols: [Vec<Value>; 4] = Default::default();
    let mut wavelengths = Vec::with_capacity(count as usize);
    for i in 0..count {
        let l = if count == 1 {
            lambda_min_um
        } else {
            lambda_min_um + (lambda_max_um - lambda_min_um) * i as f64 / (count - 1) as f64
        };
        wavelengths.push(l);
        for (c, v) in cols.iter_mut().zip(at(l)) {
            c.push(v);
        }
    }
    let [n, k, eps_re, eps_im] = cols;
    let [n0, k0, e0, e1] = at(lambda0_um);
    json!({
        "wavelength_um": wavelengths, "n": n, "k": k, "eps_re": eps_re, "eps_im": eps_im,
        "at": { "wavelength_um": lambda0_um, "n": n0, "k": k0, "eps_re": e0, "eps_im": e1 },
    })
}

/// Most wavelengths [`material_curve_json`] evaluates.
pub const MAX_CURVE_POINTS: u32 = 10_000;

/// # Safety
/// `material_json` must be NULL or a valid C string.
#[no_mangle]
pub unsafe extern "C" fn fringe_material_curve(
    material_json: *const c_char,
    lambda_min_um: f64,
    lambda_max_um: f64,
    count: u32,
    lambda0_um: f64,
) -> *mut c_char {
    if material_json.is_null() {
        return ptr::null_mut();
    }
    guard(ptr::null_mut(), || {
        let v = match str_arg(material_json) {
            Some(s) => material_curve_json(s, lambda_min_um, lambda_max_um, count, lambda0_um),
            None => json!({ "error": { "code": "parse", "message": "material is not valid UTF-8" } }),
        };
        into_c(v.to_string())
    })
}

/// The core's version 3 JSON for a scene of any readable version, or
/// `{"error": {"code", "message"}}`.
pub fn scene_upgrade_json(scene_json: &str) -> String {
    match parse_scene(scene_json) {
        Ok(s) => to_json(&s),
        Err(e) => json!({ "error": { "code": e.code, "message": e.message } }).to_string(),
    }
}

/// # Safety
/// `scene_json` must be NULL or a valid C string.
#[no_mangle]
pub unsafe extern "C" fn fringe_scene_upgrade(scene_json: *const c_char) -> *mut c_char {
    if scene_json.is_null() {
        return ptr::null_mut();
    }
    guard(ptr::null_mut(), || match str_arg(scene_json) {
        Some(s) => into_c(scene_upgrade_json(s)),
        None => into_c(json!({ "error": { "code": "parse", "message": "scene is not valid UTF-8" } }).to_string()),
    })
}

/// Readings of `detectors_json` (a JSON array of scene detectors) on a solved
/// field, enabled ones in order, or `{"error": {"code", "message", "issues"}}`.
/// The detectors are validated as in a scene (inside the domain, sizes, ids).
pub fn field_measure_json(field: &FieldGrid, detectors_json: &str) -> Value {
    let detectors: Vec<Detector> = match serde_json::from_str(detectors_json) {
        Ok(d) => d,
        Err(e) => return json!({ "error": { "code": "parse", "message": format!("invalid detector list: {e}"), "issues": [] } }),
    };
    let mut scene = field.scene.clone();
    scene.detectors = detectors;
    let issues: Vec<Issue> = validate(&scene).into_iter().filter(|i| i.is_error() && i.path.starts_with("detectors")).collect();
    if let Some(first) = issues.first() {
        return json!({ "error": { "code": "invalid", "message": first.message, "issues": issues } });
    }
    serde_json::to_value(crate::detectors::measure_all(&field.view(), &scene.detectors)).unwrap_or(Value::Null)
}

/// # Safety
/// `field` must be NULL or live; `detectors_json` NULL or a valid C string.
#[no_mangle]
pub unsafe extern "C" fn fringe_field_measure(field: *const FringeField, detectors_json: *const c_char) -> *mut c_char {
    if field.is_null() || detectors_json.is_null() {
        return ptr::null_mut();
    }
    guard(ptr::null_mut(), || {
        let v = match str_arg(detectors_json) {
            Some(s) => field_measure_json(&(*field).0, s),
            None => json!({ "error": { "code": "parse", "message": "detectors are not valid UTF-8", "issues": [] } }),
        };
        into_c(v.to_string())
    })
}

/// # Safety
/// `fields` must point to `count` live fields, `weights_re` and `weights_im`
/// to `count` doubles each; `error_json_out` NULL or writable.
#[no_mangle]
pub unsafe extern "C" fn fringe_field_combine(
    fields: *const *const FringeField,
    weights_re: *const f64,
    weights_im: *const f64,
    count: usize,
    error_json_out: *mut *mut c_char,
) -> *mut FringeField {
    if fields.is_null() || weights_re.is_null() || weights_im.is_null() || count == 0 {
        set_error(error_json_out, "buffer", "fields or weights are NULL, or count is 0", &[]);
        return ptr::null_mut();
    }
    guard(ptr::null_mut(), || {
        let ptrs = std::slice::from_raw_parts(fields, count);
        if ptrs.iter().any(|f| f.is_null()) {
            set_error(error_json_out, "buffer", "a field is NULL", &[]);
            return ptr::null_mut();
        }
        let grids: Vec<&FieldGrid> = ptrs.iter().map(|&f| &*(*f).0).collect();
        let re = std::slice::from_raw_parts(weights_re, count);
        let im = std::slice::from_raw_parts(weights_im, count);
        let weights: Vec<C64> = re.iter().zip(im).map(|(&r, &i)| C64::new(r, i)).collect();
        match FieldGrid::combine(&grids, &weights) {
            Ok(f) => Box::into_raw(Box::new(FringeField(Arc::new(f)))),
            Err(m) => {
                set_error(error_json_out, "combine", m, &[]);
                ptr::null_mut()
            }
        }
    })
}
