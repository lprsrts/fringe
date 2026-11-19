//! Scene JSON in, intensity field out: the smallest browser-facing surface of
//! fringe_core, for timing the solvers as WebAssembly.

use fringe_core::scene::examples::example;
use fringe_core::solver::{solve as core_solve, Method, Quality, SolveContext};
use std::cell::RefCell;
use wasm_bindgen::prelude::*;

thread_local! {
    static LAST_META: RefCell<String> = const { RefCell::new(String::new()) };
}

/// A built-in example scene as JSON (e.g. "lens"), the same as
/// `fringe-cli example <name>`.
#[wasm_bindgen]
pub fn example_scene(name: &str) -> Result<String, JsError> {
    let scene = example(name).ok_or_else(|| JsError::new(&format!("no example {name:?}")))?;
    serde_json::to_string(&scene).map_err(|e| JsError::new(&e.to_string()))
}

/// Solves `scene_json` with `method` ("fdtd", "fem", "mom"; "" keeps the
/// scene's) at `quality` ("preview" or "final") on the calling thread.
/// Returns `[nx, ny, wall_s, memory_estimate_mb, |Ez|² row-major...]`.
#[wasm_bindgen]
pub fn solve(scene_json: &str, method: &str, quality: &str) -> Result<Vec<f32>, JsError> {
    let mut scene = fringe_core::parse_scene(scene_json).map_err(|e| JsError::new(&e.message))?;
    if !method.is_empty() {
        scene.solver.method =
            Method::parse(method).ok_or_else(|| JsError::new(&format!("unknown solver {method:?}")))?;
    }
    let quality = Quality::parse(quality).ok_or_else(|| JsError::new(&format!("unknown quality {quality:?}")))?;
    let field = core_solve(&scene, quality, &SolveContext::new()).map_err(|e| JsError::new(&e.to_string()))?;
    LAST_META.with(|m| *m.borrow_mut() = serde_json::to_string(&field.meta).unwrap_or_default());
    let g = &field.grid;
    let mut out = Vec::with_capacity(4 + field.total.len());
    out.extend([g.nx as f32, g.ny as f32, field.meta.wall_s as f32, field.meta.memory_mb as f32]);
    out.extend(field.total.iter().map(|z| z.norm_sqr() as f32));
    Ok(out)
}

/// The last solve's metadata as JSON, including the solver's stage timings.
#[wasm_bindgen]
pub fn last_meta() -> String {
    LAST_META.with(|m| m.borrow().clone())
}

/// The module's linear memory in bytes. Wasm memory only grows, so read after
/// a solve this is the peak the heap reached (plus allocator slack).
#[wasm_bindgen]
pub fn memory_bytes() -> f64 {
    (core::arch::wasm32::memory_size(0) * 65536) as f64
}
