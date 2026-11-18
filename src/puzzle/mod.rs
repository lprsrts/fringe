//! Puzzles: a scene with fixed parts, sources and detectors, a goal measured
//! by the detectors, and rules for what the player may add.
//!
//! Each puzzle is one JSON file in the top-level `puzzles/` directory, named
//! `<chapter>-<slug>.json` after its id; the build script lists the directory,
//! so adding a puzzle is adding a file. The format:
//!
//! ```json
//! {"id": "logic-xor", "chapter": "logic", "order": 1, "title": "XOR",
//!  "summary": "…", "hints": ["…"],
//!  "scene": { …scene v3: fixed elements, sources, detectors… },
//!  "inputs": ["in-a", "in-b"],
//!  "goal": {"type": "truth_table", "pass": 10,
//!           "outputs": [{"detector": "through", "bits": [0, 1, 1, 0]}]},
//!  "rules": {"locked": ["wall"], "region": [x_min, x_max, y_min, y_max],
//!            "palette": [{"kind": "slab", "materials": ["glass"], "max": 1}],
//!            "max_elements": 1,
//!            "materials": {"glass": {"name": "Glass", "type": "dielectric", "n": 1.5}}},
//!  "scoring": {"method": "fem", "ppw": 9},
//!  "stars": [10, 15, 20],
//!  "reference": [ …the elements of one known solution… ]}
//! ```
//!
//! [`rules`] composes the scene a design is scored in and checks the rules;
//! [`eval`] solves it and computes the goal's metric.

pub mod eval;
pub mod rules;

use std::collections::BTreeMap;
use std::sync::OnceLock;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::scene::{validate, DetectorShape, Element, Material, Scene, SCHEMA_VERSION};
use crate::solver::Method;

pub use eval::{evaluate, verify, Evaluation, VerifyReport};
pub use rules::{compose, parse_design, Composed};

/// Chapter ids and titles, in the order the chapters are played.
pub const CHAPTERS: [(&str, &str); 4] = [
    ("steering", "Steering light"),
    ("interference", "Interference"),
    ("logic", "Logic with light"),
    ("metals", "Metals and emitters"),
];

pub fn chapter_title(id: &str) -> Option<&'static str> {
    CHAPTERS.iter().find(|c| c.0 == id).map(|c| c.1)
}

fn chapter_index(id: &str) -> usize {
    CHAPTERS.iter().position(|c| c.0 == id).unwrap_or(CHAPTERS.len())
}

/// Most input sources a truth table may have (16 cases).
pub const MAX_INPUTS: usize = 4;

/// The scoring resolution must lie in this range (points per wavelength).
pub const PPW_RANGE: (f64, f64) = (4.0, 30.0);

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Puzzle {
    pub id: String,
    pub chapter: String,
    pub order: u32,
    pub title: String,
    pub summary: String,
    #[serde(default)]
    pub hints: Vec<String>,
    /// Schema version 3, with the fixed elements, the sources and the detectors.
    pub scene: Scene,
    /// Source ids switched on and off as the bits of each case; input 0 is
    /// the most significant bit. Other enabled sources are always on.
    #[serde(default)]
    pub inputs: Vec<String>,
    pub goal: Goal,
    pub rules: Rules,
    pub scoring: Scoring,
    /// Score thresholds for one, two and three stars, in the metric's unit.
    pub stars: [f64; 3],
    /// The elements of one known solution (fixed elements may be left out).
    pub reference: Vec<Element>,
}

/// What is measured and what counts as solved. `pass` is a score threshold
/// in the metric's unit; every score is "higher is better".
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Goal {
    pub pass: f64,
    /// A plain one-line statement of the goal, for the app.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    /// What detector values are divided by (see [`Reference`]).
    #[serde(default)]
    pub reference: Reference,
    /// The source a `"source"` reference refers to; by default the first
    /// input, or the first enabled source without inputs.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reference_source: Option<String>,
    #[serde(flatten)]
    pub kind: GoalKind,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum GoalKind {
    /// Each output detector must be bright where its bit is 1 and dark where
    /// it is 0. Score: the contrast in dB between the weakest 1 and the
    /// strongest 0, the smallest over the outputs.
    TruthTable { outputs: Vec<TruthOutput> },
    /// Score: the detector's value over the reference, in per cent for a line
    /// detector (flux) and as a factor for a box (mean |E|²).
    Maximize { detector: String },
    /// Score: −10 log10 of the summed quantity over the reference, in dB.
    Minimize {
        detectors: Vec<String>,
        #[serde(default)]
        quantity: MinimizeQuantity,
    },
    /// Split power between two line detectors: the share of the first,
    /// `a / (a + b)`, must be within `tolerance` of `ratio`. Score: each
    /// side's power over what it should get, `min(a / ratio, b / (1 − ratio))`
    /// with a and b relative to the reference, in per cent; 100 for a lossless
    /// exact split.
    Target { detectors: [String; 2], ratio: f64, tolerance: f64 },
}

impl GoalKind {
    pub fn type_name(&self) -> &'static str {
        match self {
            GoalKind::TruthTable { .. } => "truth_table",
            GoalKind::Maximize { .. } => "maximize",
            GoalKind::Minimize { .. } => "minimize",
            GoalKind::Target { .. } => "target",
        }
    }

    /// Every detector id the goal reads.
    pub fn detectors(&self) -> Vec<&str> {
        match self {
            GoalKind::TruthTable { outputs } => outputs.iter().map(|o| o.detector.as_str()).collect(),
            GoalKind::Maximize { detector } => vec![detector],
            GoalKind::Minimize { detectors, .. } => detectors.iter().map(String::as_str).collect(),
            GoalKind::Target { detectors, .. } => detectors.iter().map(String::as_str).collect(),
        }
    }
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct TruthOutput {
    pub detector: String,
    /// The wanted bit (0 or 1) per case, in case order.
    pub bits: Vec<u8>,
}

/// What a minimize goal sums over its detectors.
#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq, Default)]
#[serde(rename_all = "snake_case")]
pub enum MinimizeQuantity {
    /// Scattered flux through line detectors (along their normals): around a
    /// closed contour with outward normals, the total scattered power.
    #[default]
    Scattered,
    /// Total flux through line detectors.
    Flux,
    /// Mean |E|² in box detectors.
    Intensity,
}

/// The divisor of detector values. A number is used as is (flux per µm in z,
/// or |E|² for a box). `"source"`: for a flux, the power the reference source
/// radiates (a Gaussian beam's power through its waist; for an emitter, the
/// power it gives off in that case with the design in place, which bodies
/// near it change, absorption in them included; a plane wave has no finite
/// power and cannot be used); for a box,
/// the source amplitude squared. `"incident"`: the same quantity measured on
/// the incident field of the case, i.e. what the detector would see with no
/// elements at all.
#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq)]
#[serde(untagged)]
pub enum Reference {
    Fixed(f64),
    Named(ReferenceKind),
}

impl Default for Reference {
    fn default() -> Self {
        Reference::Named(ReferenceKind::Source)
    }
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ReferenceKind {
    Source,
    Incident,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Rules {
    /// Ids of scene elements the player cannot move, change or remove.
    #[serde(default)]
    pub locked: Vec<String>,
    /// Where the player's elements must lie: [x_min, x_max, y_min, y_max] in µm.
    pub region: [f64; 4],
    /// The parts the player may add.
    #[serde(default)]
    pub palette: Vec<PaletteEntry>,
    /// Most enabled elements the player may have in the design.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_elements: Option<u32>,
    /// Materials the palette names, beside "pec" and the preset ids.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub materials: BTreeMap<String, NamedMaterial>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct PaletteEntry {
    /// A shape kind: "slab", "mirror", "cylinder", …
    pub kind: String,
    /// Allowed material names: "pec", a preset id, or a key of
    /// `rules.materials`. Empty allows any material.
    #[serde(default)]
    pub materials: Vec<String>,
    /// Most elements of this entry; none is unlimited.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max: Option<u32>,
}

/// A puzzle material with a display name.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct NamedMaterial {
    #[serde(default)]
    pub name: String,
    #[serde(flatten)]
    pub material: Material,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Scoring {
    pub method: Method,
    /// The scoring method's preview resolution, points per wavelength.
    pub ppw: f64,
}

impl Puzzle {
    pub fn chapter_title(&self) -> &'static str {
        chapter_title(&self.chapter).unwrap_or("")
    }

    /// The entry of `fringe_puzzle_list`.
    pub fn summary_json(&self) -> Value {
        json!({
            "id": self.id,
            "chapter": self.chapter,
            "chapter_title": self.chapter_title(),
            "order": self.order,
            "title": self.title,
            "summary": self.summary,
            "goal_type": self.goal.kind.type_name(),
            "stars": self.stars,
        })
    }

    pub fn to_json(&self) -> String {
        serde_json::to_string_pretty(self).expect("puzzles always serialise")
    }

    /// The material a palette name stands for.
    pub fn material(&self, name: &str) -> Option<Material> {
        if name == "pec" {
            return Some(Material::Pec);
        }
        if let Some(m) = self.rules.materials.get(name) {
            return Some(m.material.clone());
        }
        crate::scene::materials::preset(name)
    }

    /// Problems with the puzzle itself, as text; empty for a good puzzle.
    /// `file_name`, when given, must be `<id>.json`.
    pub fn problems(&self, file_name: Option<&str>) -> Vec<String> {
        let mut out = Vec::new();
        let mut bad = |m: String| out.push(m);
        if let Some(f) = file_name {
            if f != format!("{}.json", self.id) {
                bad(format!("the file is named {f}, not {}.json", self.id));
            }
        }
        if chapter_title(&self.chapter).is_none() {
            bad(format!("unknown chapter \"{}\"", self.chapter));
        } else if !self.id.starts_with(&format!("{}-", self.chapter)) || self.id.len() <= self.chapter.len() + 1 {
            bad(format!("the id must be \"{}-<slug>\"", self.chapter));
        }
        if !self.id.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-') {
            bad("the id may hold only lower-case letters, digits and hyphens".into());
        }
        for (what, text) in [("title", &self.title), ("summary", &self.summary)] {
            if text.trim().is_empty() {
                bad(format!("the {what} is empty"));
            }
        }
        let s = &self.scene;
        if s.version != SCHEMA_VERSION {
            bad(format!("the scene must be version {SCHEMA_VERSION}"));
        }
        for i in validate(s).into_iter().filter(|i| i.is_error()) {
            bad(format!("scene: {}: {} [{}]", i.path, i.message, i.code));
        }
        let enabled_source = |id: &str| s.sources.iter().any(|x| x.id == id && x.enabled);
        if self.inputs.len() > MAX_INPUTS {
            bad(format!("at most {MAX_INPUTS} inputs"));
        }
        for (k, id) in self.inputs.iter().enumerate() {
            if !enabled_source(id) {
                bad(format!("input \"{id}\" is not an enabled source"));
            }
            if self.inputs[..k].contains(id) {
                bad(format!("input \"{id}\" is listed twice"));
            }
        }
        let detector = |id: &str| s.detectors.iter().find(|d| d.id == id && d.enabled);
        let is_line = |id: &str| detector(id).is_some_and(|d| matches!(d.shape, DetectorShape::Line { .. }));
        let is_box = |id: &str| detector(id).is_some_and(|d| matches!(d.shape, DetectorShape::Box { .. }));
        for id in self.goal.kind.detectors() {
            if detector(id).is_none() {
                bad(format!("goal detector \"{id}\" is not an enabled detector of the scene"));
            }
        }
        let cases = 1usize << self.inputs.len();
        match &self.goal.kind {
            GoalKind::TruthTable { outputs } => {
                if self.inputs.is_empty() {
                    bad("a truth table needs inputs".into());
                }
                if outputs.is_empty() {
                    bad("a truth table needs at least one output".into());
                }
                for o in outputs {
                    if o.bits.len() != cases {
                        bad(format!("output \"{}\" has {} bits for {cases} cases", o.detector, o.bits.len()));
                    }
                    if o.bits.iter().any(|&b| b > 1) {
                        bad(format!("output \"{}\" has bits other than 0 and 1", o.detector));
                    }
                    if !(o.bits.contains(&0) && o.bits.contains(&1)) {
                        bad(format!("output \"{}\" needs at least one 0 and one 1", o.detector));
                    }
                }
            }
            GoalKind::Maximize { .. } => {}
            GoalKind::Minimize { detectors, quantity } => {
                if detectors.is_empty() {
                    bad("a minimize goal needs at least one detector".into());
                }
                for id in detectors {
                    let ok = match quantity {
                        MinimizeQuantity::Intensity => is_box(id),
                        _ => is_line(id),
                    };
                    if detector(id).is_some() && !ok {
                        bad(format!("detector \"{id}\" is the wrong kind for {quantity:?} (box for intensity, line otherwise)"));
                    }
                }
            }
            GoalKind::Target { detectors, ratio, tolerance } => {
                for id in detectors {
                    if detector(id).is_some() && !is_line(id) {
                        bad(format!("target detector \"{id}\" must be a line"));
                    }
                }
                if detectors[0] == detectors[1] {
                    bad("the two target detectors must differ".into());
                }
                if !(*ratio > 0.0 && *ratio < 1.0) || !(*tolerance > 0.0 && *tolerance < 0.5) {
                    bad("target ratio must be in (0, 1) and tolerance in (0, 0.5)".into());
                }
            }
        }
        if let Reference::Fixed(v) = self.goal.reference {
            if !(v.is_finite() && v > 0.0) {
                bad(format!("a fixed reference must be positive (got {v})"));
            }
        }
        if let Some(id) = &self.goal.reference_source {
            if !enabled_source(id) {
                bad(format!("reference source \"{id}\" is not an enabled source"));
            }
        }
        if !self.goal.pass.is_finite() {
            bad("goal.pass must be finite".into());
        }
        if !self.stars.iter().all(|t| t.is_finite()) || self.stars[0] > self.stars[1] || self.stars[1] > self.stars[2] {
            bad("the star thresholds must be finite and ascending".into());
        }
        if self.stars[0] < self.goal.pass {
            bad("the first star threshold must not be below goal.pass".into());
        }
        let r = &self.rules;
        for id in &r.locked {
            if !s.elements.iter().any(|e| &e.id == id) {
                bad(format!("locked element \"{id}\" is not in the scene"));
            }
        }
        let [x0, x1, y0, y1] = r.region;
        if !(r.region.iter().all(|v| v.is_finite()) && x0 < x1 && y0 < y1) {
            bad("rules.region must be [x_min, x_max, y_min, y_max] with min < max".into());
        } else if !s.domain.rect().contains_rect(&crate::types::Rect::new(x0, x1, y0, y1)) {
            bad("rules.region must lie inside the domain".into());
        }
        if r.palette.is_empty() {
            bad("the palette is empty".into());
        }
        for p in &r.palette {
            if !SHAPE_KINDS.contains(&p.kind.as_str()) {
                bad(format!("unknown palette kind \"{}\"", p.kind));
            }
            for m in &p.materials {
                if self.material(m).is_none() {
                    bad(format!("palette material \"{m}\" is not pec, a preset or a key of rules.materials"));
                }
            }
        }
        if !(self.scoring.ppw >= PPW_RANGE.0 && self.scoring.ppw <= PPW_RANGE.1) {
            bad(format!("scoring.ppw must be {}–{}", PPW_RANGE.0, PPW_RANGE.1));
        }
        if self.reference.is_empty() {
            bad("the reference solution is empty".into());
        }
        out
    }
}

/// Shape kinds, as in the scene JSON.
pub const SHAPE_KINDS: [&str; 10] =
    ["lens", "slab", "wedge", "prism", "mirror", "slits", "grating", "cylinder", "waveguide", "polygon"];

mod files {
    include!(concat!(env!("OUT_DIR"), "/puzzle_files.rs"));
}

/// The bundled puzzle files: (file name, JSON text), sorted by name.
pub fn files() -> &'static [(&'static str, &'static str)] {
    files::PUZZLE_FILES
}

struct Catalog {
    /// (file name, puzzle), sorted for play.
    puzzles: Vec<(&'static str, Puzzle)>,
    list: Vec<Puzzle>,
    errors: Vec<String>,
}

fn catalog_data() -> &'static Catalog {
    static CATALOG: OnceLock<Catalog> = OnceLock::new();
    CATALOG.get_or_init(|| {
        let mut puzzles: Vec<(&'static str, Puzzle)> = Vec::new();
        let mut errors = Vec::new();
        for &(name, text) in files() {
            match serde_json::from_str::<Puzzle>(text) {
                Ok(p) if puzzles.iter().any(|q| q.1.id == p.id) => errors.push(format!("{name}: duplicate id {}", p.id)),
                Ok(p) => puzzles.push((name, p)),
                Err(e) => errors.push(format!("{name}: {e}")),
            }
        }
        puzzles.sort_by(|(_, a), (_, b)| {
            (chapter_index(&a.chapter), a.order, &a.id).cmp(&(chapter_index(&b.chapter), b.order, &b.id))
        });
        let list = puzzles.iter().map(|p| p.1.clone()).collect();
        Catalog { puzzles, list, errors }
    })
}

/// Every bundled puzzle that parses, by chapter order, then `order`, then id.
pub fn catalog() -> &'static [Puzzle] {
    &catalog_data().list
}

/// The file a bundled puzzle came from.
pub fn file_name(id: &str) -> Option<&'static str> {
    catalog_data().puzzles.iter().find(|p| p.1.id == id).map(|p| p.0)
}

/// Files that did not parse (or repeat an id), as "file: message". Always
/// empty in a good build; the tests and `fringe-cli puzzle verify` check it.
pub fn catalog_errors() -> &'static [String] {
    &catalog_data().errors
}

pub fn get(id: &str) -> Option<&'static Puzzle> {
    catalog().iter().find(|p| p.id == id)
}

/// The `fringe_puzzle_list` JSON.
pub fn list_json() -> Value {
    Value::Array(catalog().iter().map(Puzzle::summary_json).collect())
}
