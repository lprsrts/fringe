//! Scene description: JSON schema, validation, derived quantities and examples.

pub mod derived;
pub mod examples;
pub mod materials;
pub mod tex;
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

/// The id a version 2 scene's single source gets on upgrade.
pub const UPGRADED_SOURCE_ID: &str = "source-1";

/// Parses scene JSON. The version is checked first, so a v1 file gets a clear
/// message rather than a list of unknown fields. Version 2 is read and upgraded:
/// its single `source` becomes `sources: [source]` (id [`UPGRADED_SOURCE_ID`]),
/// and it has no dispersive materials or detectors.
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
    let version = obj.get("version").and_then(|v| v.as_u64());
    match version {
        Some(v) if (OLDEST_SCHEMA_VERSION as u64..=SCHEMA_VERSION as u64).contains(&v) => {}
        Some(v) if v > SCHEMA_VERSION as u64 => {
            return Err(SceneError {
                code: "schema_version",
                message: format!("scene version {v} is newer than this build (which reads version {SCHEMA_VERSION})"),
            })
        }
        _ => {
            return Err(SceneError {
                code: "schema_version",
                message: format!(
                    "v1 scenes, from the old paraxial model, are not supported (expected \"version\": {SCHEMA_VERSION})"
                ),
            })
        }
    }
    // Version 2 predates dispersive materials; a v2 file holding one was not
    // written by a v2 build and is more likely a mislabelled v3 file.
    if version == Some(2) {
        let elements = obj.get("elements").and_then(|e| e.as_array());
        if let Some(i) = elements.into_iter().flatten().position(|e| e["material"]["type"] == "dispersive") {
            return Err(SceneError {
                code: "schema_version",
                message: format!(
                    "elements[{i}] has a dispersive material, which needs \"version\": {SCHEMA_VERSION} (version 2 has only pec and dielectric)"
                ),
            });
        }
        if obj.contains_key("sources") || obj.get("source").is_some_and(|s| s["type"] == "line_source") {
            return Err(SceneError {
                code: "schema_version",
                message: format!(
                    "a source list or a line source needs \"version\": {SCHEMA_VERSION} (version 2 has one plane wave or Gaussian beam in \"source\")"
                ),
            });
        }
        if obj.get("detectors").is_some_and(|d| d.as_array().is_none_or(|a| !a.is_empty())) {
            return Err(SceneError {
                code: "schema_version",
                message: format!("detectors need \"version\": {SCHEMA_VERSION} (version 2 has none)"),
            });
        }
    }
    // Version 2 had one `source`; it becomes the only entry of `sources`. The
    // upgrade keys on the field, not on the version: scenes written while v3
    // had the dispersive material but not yet the source list say version 3
    // and still have `source`.
    let mut value = value;
    if let Some(obj) = value.as_object_mut() {
        if let Some(source) = obj.remove("source") {
            if obj.contains_key("sources") {
                return Err(SceneError {
                    code: "parse",
                    message: "a scene has either \"source\" (version 2) or \"sources\", not both".into(),
                });
            }
            let source = match source {
                serde_json::Value::Object(mut m) => {
                    for (k, v) in [("id", UPGRADED_SOURCE_ID.into()), ("name", "".into()), ("enabled", true.into())] {
                        if m.contains_key(k) {
                            return Err(SceneError {
                                code: "parse",
                                message: format!("invalid scene: unknown field `{k}` in the version 2 \"source\""),
                            });
                        }
                        m.insert(k.into(), v);
                    }
                    serde_json::Value::Object(m)
                }
                other => other,
            };
            obj.insert("sources".into(), serde_json::Value::Array(vec![source]));
        }
    }
    let mut scene: Scene = serde_json::from_value(value).map_err(|e| SceneError {
        code: "parse",
        message: format!("invalid scene: {e}"),
    })?;
    scene.version = SCHEMA_VERSION;
    Ok(scene)
}

/// Pretty-printed scene JSON.
pub fn to_json(scene: &Scene) -> String {
    serde_json::to_string_pretty(scene).expect("scenes always serialise")
}
