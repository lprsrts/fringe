//! fringe_core for the browser: scene JSON in, a rendered field out, plus
//! detector measurements and the bundled puzzle engine. The module keeps the
//! last solved field (and, after a puzzle check, the per-source fields so
//! switching cases needs no re-solve). Everything runs on the calling thread,
//! which should be a Web Worker.

use std::cell::RefCell;
use std::sync::Arc;

use fringe_core::detectors::{measure_all, Reading};
use fringe_core::ffi::scene_outlines_json;
use fringe_core::puzzle::{self, eval::source_power, parse_design, Puzzle};
use fringe_core::render::{render_rgba, View, MAX_DIMENSION};
use fringe_core::scene::examples::{example, EXAMPLES};
use fringe_core::scene::materials::presets_json;
use fringe_core::scene::Detector;
use fringe_core::solver::{solve as core_solve, FieldGrid, Method, Quality, SolveContext};
use fringe_core::types::C64;
use serde_json::{json, Value};
use wasm_bindgen::prelude::*;

/// The largest RGBA image `render` returns: 32 Mpx, which covers a 5K screen at
/// 2× pixel density. Bigger requests are refused before any allocation.
const MAX_RENDER_BYTES: usize = 32 * 1024 * 1024 * 4;

thread_local! {
    static FIELD: RefCell<Option<Arc<FieldGrid>>> = const { RefCell::new(None) };
    static PUZZLE_FIELDS: RefCell<Vec<Arc<FieldGrid>>> = const { RefCell::new(Vec::new()) };
}

fn err(e: impl std::fmt::Display) -> JsError {
    JsError::new(&e.to_string())
}

fn field() -> Result<Arc<FieldGrid>, JsError> {
    FIELD.with(|f| f.borrow().clone()).ok_or_else(|| JsError::new("nothing solved yet"))
}

fn field_meta_json(field: &FieldGrid) -> Result<Value, JsError> {
    let mut meta = serde_json::to_value(&field.meta).map_err(err)?;
    meta["nx"] = field.grid.nx.into();
    meta["ny"] = field.grid.ny.into();
    meta["incident_peak"] = field.incident_peak().into();
    meta["readings"] = serde_json::to_value(field.detector_readings()).map_err(err)?;
    Ok(meta)
}

fn find_puzzle(id: &str) -> Result<&'static Puzzle, JsError> {
    puzzle::get(id).ok_or_else(|| JsError::new(&format!("no puzzle {id:?}")))
}

/// The built-in examples as JSON: `[{name, title, method, quantity, colormap}]`.
#[wasm_bindgen]
pub fn examples() -> String {
    let list: Vec<_> = EXAMPLES
        .iter()
        .map(|e| {
            json!({"name": e.name, "title": e.title, "method": e.method.label(),
                   "quantity": e.quantity, "colormap": e.colormap})
        })
        .collect();
    Value::Array(list).to_string()
}

/// A built-in example scene as JSON (e.g. "lens"), the same as
/// `fringe-cli example <name>`.
#[wasm_bindgen]
pub fn example_scene(name: &str) -> Result<String, JsError> {
    let scene = example(name).ok_or_else(|| JsError::new(&format!("no example {name:?}")))?;
    serde_json::to_string_pretty(&scene).map_err(err)
}

/// The dispersive material preset library (gold, silver, aluminium, copper,
/// BK7, fused silica) as JSON.
#[wasm_bindgen]
pub fn material_presets() -> String {
    presets_json().to_string()
}

/// Exact body outlines, PML thickness, sources and detector outlines for
/// overlays and hit-testing.
#[wasm_bindgen]
pub fn outlines(scene_json: &str) -> Result<String, JsError> {
    let value = scene_outlines_json(scene_json);
    if let Some(msg) = value.get("error").and_then(|e| e.get("message")).and_then(Value::as_str) {
        return Err(JsError::new(msg));
    }
    Ok(value.to_string())
}

/// Validation issues and cost estimates for `scene_json`, as the CLI's
/// `check --json` reports them.
#[wasm_bindgen]
pub fn check(scene_json: &str) -> Result<String, JsError> {
    let scene = fringe_core::parse_scene(scene_json).map_err(|e| JsError::new(&e.message))?;
    serde_json::to_string(&fringe_core::check(&scene)).map_err(err)
}

/// Solves `scene_json` with `method` ("fdtd", "fem", "mom"; "" keeps the
/// scene's) at `quality` ("preview" or "final") and keeps the field for
/// `render` and `measure_detectors`. Returns the solve's metadata as JSON, plus
/// `nx`, `ny`, `incident_peak` and `readings`.
#[wasm_bindgen]
pub fn solve(scene_json: &str, method: &str, quality: &str) -> Result<String, JsError> {
    let mut scene = fringe_core::parse_scene(scene_json).map_err(|e| JsError::new(&e.message))?;
    if !method.is_empty() {
        scene.solver.method =
            Method::parse(method).ok_or_else(|| JsError::new(&format!("unknown solver {method:?}")))?;
    }
    let quality = Quality::parse(quality).ok_or_else(|| JsError::new(&format!("unknown quality {quality:?}")))?;
    // Drop the previous field first: FEM's peak is high enough that holding
    // two fields matters in a 4 GB address space.
    FIELD.with(|f| f.borrow_mut().take());
    let field = core_solve(&scene, quality, &SolveContext::new()).map_err(err)?;
    let meta = field_meta_json(&field)?;
    FIELD.with(|f| *f.borrow_mut() = Some(Arc::new(field)));
    Ok(meta.to_string())
}

/// Measures `detectors_json` (a JSON array of scene Detector objects) on the
/// last solved field, without solving again.
#[wasm_bindgen]
pub fn measure_detectors(detectors_json: &str) -> Result<String, JsError> {
    let detectors: Vec<Detector> = serde_json::from_str(detectors_json).map_err(err)?;
    let field = field()?;
    let view = field.view();
    let readings: Vec<Reading> = measure_all(&view, &detectors);
    serde_json::to_string(&readings).map_err(err)
}

/// Renders the last solved field with `view_json` (the app's and CLI's view
/// JSON; "" for the default) as RGBA8, row 0 at the top.
#[wasm_bindgen]
pub fn render(view_json: &str, width: u32, height: u32) -> Result<Vec<u8>, JsError> {
    let field = field()?;
    let view = View::parse(view_json).map_err(err)?;
    // Check the size before allocating: wasm memory never shrinks, and an
    // allocation that fails traps the module instead of returning an error.
    let bytes = (width as usize)
        .checked_mul(height as usize)
        .and_then(|px| px.checked_mul(4))
        .filter(|&b| width > 0 && height > 0 && width <= MAX_DIMENSION && height <= MAX_DIMENSION && b <= MAX_RENDER_BYTES)
        .ok_or_else(|| JsError::new(&format!("can't render a {width}×{height} image: each side must be 1–{MAX_DIMENSION} px and the whole at most 32 Mpx")))?;
    let mut out = vec![0u8; bytes];
    render_rgba(&field, &view, width, height, &mut out).map_err(err)?;
    Ok(out)
}

/// |Ez|² of the last solved field, row-major from the grid's `x0, y0` corner
/// (for benchmarks and checks).
#[wasm_bindgen]
pub fn intensity() -> Result<Vec<f32>, JsError> {
    Ok(field()?.total.iter().map(|z| z.norm_sqr() as f32).collect())
}

/// Every bundled puzzle's summary, ordered by chapter then `order`.
#[wasm_bindgen]
pub fn puzzles() -> String {
    puzzle::list_json().to_string()
}

/// One bundled puzzle as JSON, plus `reference_power` and `reference_intensity`
/// for live detector preview before a full Check.
#[wasm_bindgen]
pub fn puzzle(id: &str) -> Result<String, JsError> {
    let p = find_puzzle(id)?;
    let mut value = serde_json::to_value(p).map_err(err)?;
    let ref_id = p.goal.reference_source.as_ref().or(p.inputs.first());
    let ref_src = match ref_id {
        Some(sid) => p.scene.sources.iter().find(|s| &s.id == sid),
        None => p.scene.enabled_sources().next(),
    };
    value["reference_power"] = match ref_src.and_then(|s| source_power(&p.scene, s)) {
        Some(pow) if pow.is_finite() => json!(pow),
        _ => Value::Null,
    };
    value["reference_intensity"] = match ref_src {
        Some(s) => json!(s.kind.amplitude().powi(2)),
        None => Value::Null,
    };
    Ok(value.to_string())
}

/// Checks a puzzle design against the puzzle's rules and scene validation
/// without solving. Returns `{valid, issues, out_of_region_ids}`.
#[wasm_bindgen]
pub fn puzzle_check(id: &str, design_json: &str) -> Result<String, JsError> {
    let p = find_puzzle(id)?;
    let design = parse_design(design_json).map_err(err)?;
    let composed = puzzle::compose(p, &design);
    let mut out_of_region_ids: Vec<String> = Vec::new();
    for issue in &composed.issues {
        if issue.code == "rule_region" {
            if let Some(idx) = issue
                .path
                .strip_prefix("elements[")
                .and_then(|rest| rest.strip_suffix(']'))
                .and_then(|s| s.parse::<usize>().ok())
            {
                if let Some(el) = composed.scene.elements.get(idx) {
                    if !out_of_region_ids.contains(&el.id) {
                        out_of_region_ids.push(el.id.clone());
                    }
                }
            }
        }
    }
    let out = json!({
        "valid": composed.is_valid(),
        "issues": composed.issues,
        "out_of_region_ids": out_of_region_ids,
    });
    Ok(out.to_string())
}

/// Evaluates `design_json` for puzzle `id`, caching the per-source fields so
/// `select_puzzle_case` can combine any input case without solving again.
#[wasm_bindgen]
pub fn puzzle_evaluate(id: &str, design_json: &str) -> Result<String, JsError> {
    let p = find_puzzle(id)?;
    let design = parse_design(design_json).map_err(err)?;
    // Free previous fields before running the per-source solves.
    FIELD.with(|f| f.borrow_mut().take());
    PUZZLE_FIELDS.with(|pf| pf.borrow_mut().clear());
    let eval = puzzle::evaluate(p, &design, &SolveContext::new()).map_err(err)?;
    PUZZLE_FIELDS.with(|pf| *pf.borrow_mut() = eval.fields);
    Ok(eval.json.to_string())
}

/// Combines the cached per-source fields from the last `puzzle_evaluate` with
/// real weights (one per entry in the evaluation's `sources` array), stores
/// the result as the active field for `render`, and returns its metadata.
#[wasm_bindgen]
pub fn select_puzzle_case(weights: &[f64]) -> Result<String, JsError> {
    let combined = PUZZLE_FIELDS.with(|pf| -> Result<FieldGrid, JsError> {
        let fields = pf.borrow();
        if fields.is_empty() {
            return Err(JsError::new("no checked puzzle fields available"));
        }
        let refs: Vec<&FieldGrid> = fields.iter().map(|f| f.as_ref()).collect();
        let cw: Vec<C64> = weights.iter().map(|&w| C64::new(w, 0.0)).collect();
        FieldGrid::combine(&refs, &cw).map_err(err)
    })?;
    let meta = field_meta_json(&combined)?;
    FIELD.with(|f| *f.borrow_mut() = Some(Arc::new(combined)));
    Ok(meta.to_string())
}

/// Releases the cached per-source puzzle fields.
#[wasm_bindgen]
pub fn clear_puzzle_fields() {
    PUZZLE_FIELDS.with(|pf| pf.borrow_mut().clear());
}

/// The module's linear memory in bytes. Wasm memory only grows, so this is the
/// peak the heap has reached so far (plus allocator slack).
#[wasm_bindgen]
pub fn memory_bytes() -> f64 {
    (core::arch::wasm32::memory_size(0) * 65536) as f64
}
