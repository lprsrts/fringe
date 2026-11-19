//! fringe_core for the browser: scene JSON in, a rendered field out. The module
//! keeps the last solved field so the page can re-render it (another quantity,
//! colormap or phase) without solving again. Everything runs on the calling
//! thread, which should be a Web Worker.

use std::cell::RefCell;
use std::sync::Arc;

use fringe_core::render::{render_rgba, View};
use fringe_core::scene::examples::{example, EXAMPLES};
use fringe_core::solver::{solve as core_solve, FieldGrid, Method, Quality, SolveContext};
use serde_json::json;
use wasm_bindgen::prelude::*;

thread_local! {
    static FIELD: RefCell<Option<Arc<FieldGrid>>> = const { RefCell::new(None) };
}

fn err(e: impl std::fmt::Display) -> JsError {
    JsError::new(&e.to_string())
}

fn field() -> Result<Arc<FieldGrid>, JsError> {
    FIELD.with(|f| f.borrow().clone()).ok_or_else(|| JsError::new("nothing solved yet"))
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
    serde_json::Value::Array(list).to_string()
}

/// A built-in example scene as JSON (e.g. "lens"), the same as
/// `fringe-cli example <name>`.
#[wasm_bindgen]
pub fn example_scene(name: &str) -> Result<String, JsError> {
    let scene = example(name).ok_or_else(|| JsError::new(&format!("no example {name:?}")))?;
    serde_json::to_string_pretty(&scene).map_err(err)
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
/// `render`. Returns the solve's metadata as JSON, plus `nx` and `ny`.
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
    let mut meta = serde_json::to_value(&field.meta).map_err(err)?;
    meta["nx"] = field.grid.nx.into();
    meta["ny"] = field.grid.ny.into();
    FIELD.with(|f| *f.borrow_mut() = Some(Arc::new(field)));
    Ok(meta.to_string())
}

/// Renders the last solved field with `view_json` (the app's and CLI's view
/// JSON; "" for the default) as RGBA8, row 0 at the top.
#[wasm_bindgen]
pub fn render(view_json: &str, width: u32, height: u32) -> Result<Vec<u8>, JsError> {
    let field = field()?;
    let view = View::parse(view_json).map_err(err)?;
    let mut out = vec![0u8; width as usize * height as usize * 4];
    render_rgba(&field, &view, width, height, &mut out).map_err(err)?;
    Ok(out)
}

/// |Ez|² of the last solved field, row-major from the grid's `x0, y0` corner
/// (for benchmarks and checks).
#[wasm_bindgen]
pub fn intensity() -> Result<Vec<f32>, JsError> {
    Ok(field()?.total.iter().map(|z| z.norm_sqr() as f32).collect())
}

/// The module's linear memory in bytes. Wasm memory only grows, so this is the
/// peak the heap has reached so far (plus allocator slack).
#[wasm_bindgen]
pub fn memory_bytes() -> f64 {
    (core::arch::wasm32::memory_size(0) * 65536) as f64
}
