//! Scene description: JSON schema, validation, derived quantities and examples.

pub mod derived;
pub mod examples;
pub mod types;
pub mod validate;

pub use types::*;
pub use validate::{validate, Issue, Severity};

/// Why a scene could not be read. `code` is `parse` or `schema_version`.
#[derive(Clone, Debug, PartialEq)]
pub struct SceneError {
    pub code: &'static str,
    pub message: String,
}

impl std::fmt::Display for SceneError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for SceneError {}

/// Parses scene JSON. The version is checked first, so a v1 file gets a clear
/// message rather than a list of unknown fields.
pub fn parse_scene(json: &str) -> Result<Scene, SceneError> {
    let value: serde_json::Value = serde_json::from_str(json).map_err(|e| SceneError {
        code: "parse",
        message: format!("invalid JSON: {e}"),
    })?;
    let Some(obj) = value.as_object() else {
        return Err(SceneError {
            code: "parse",
            message: "a scene must be a JSON object".into(),
        });
    };
    match obj.get("version").and_then(|v| v.as_u64()) {
        Some(v) if v == SCHEMA_VERSION as u64 => {}
        Some(v) if v > SCHEMA_VERSION as u64 => {
            return Err(SceneError {
                code: "schema_version",
                message: format!("scene version {v} is newer than this build (which reads version {SCHEMA_VERSION})"),
            })
        }
        _ => {
            return Err(SceneError {
                code: "schema_version",
                message: "scene from Beam v1; not supported (expected \"version\": 2)".into(),
            })
        }
    }
    serde_json::from_str(json).map_err(|e| SceneError {
        code: "parse",
        message: format!("invalid scene: {e}"),
    })
}

/// Pretty-printed scene JSON.
pub fn to_json(scene: &Scene) -> String {
    serde_json::to_string_pretty(scene).expect("scenes always serialise")
}
