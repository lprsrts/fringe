//! The scene a design is scored in, and the puzzle's rules.
//!
//! A design is a list of elements. The composed scene is the puzzle scene with
//! the design applied: locked elements always as the puzzle has them, the
//! puzzle's other elements as the design has them (left out when the design
//! does not have them), then the design's own elements in its order. So a
//! design that lists every element of the app's document, in document order,
//! gives a composed scene in the same order, and `elements[i]` in an issue is
//! the document's element i.
//!
//! The solver settings are the scoring method at its preview quality, with the
//! puzzle's resolution as that method's preview override, so a live preview of
//! the composed scene uses exactly the scoring resolution.

use std::collections::HashSet;

use serde_json::Value;

use crate::geometry::element_bodies;
use crate::scene::{parse_scene, validate, Element, Issue, Material, Scene};
use crate::solver::Method;
use crate::types::Rect;

use super::Puzzle;

/// A design read from JSON: an array of elements, or a whole scene (of which
/// only the elements are used).
pub fn parse_design(json: &str) -> Result<Vec<Element>, String> {
    let v: Value = serde_json::from_str(json).map_err(|e| format!("invalid JSON: {e}"))?;
    match v {
        Value::Array(_) => serde_json::from_value(v).map_err(|e| format!("invalid element list: {e}")),
        Value::Object(_) => parse_scene(json).map(|s| s.elements).map_err(|e| e.message),
        _ => Err("a design is a JSON array of elements or a scene object".into()),
    }
}

pub struct Composed {
    pub scene: Scene,
    /// Per element of the composed scene: whether it belongs to the design
    /// (everything but the locked elements).
    pub design: Vec<bool>,
    /// Scene validation and rule issues; paths are into the composed scene.
    pub issues: Vec<Issue>,
}

impl Composed {
    /// No error blocks scoring.
    pub fn is_valid(&self) -> bool {
        !self.issues.iter().any(|i| i.is_error())
    }
}

/// The puzzle scene with `design` applied, scoring settings set, and every
/// rule and validation issue.
pub fn compose(p: &Puzzle, design: &[Element]) -> Composed {
    let locked: HashSet<&str> = p.rules.locked.iter().map(String::as_str).collect();
    let mut scene = p.scene.clone();
    let mut elements = Vec::new();
    let mut is_design = Vec::new();
    let mut rule_issues = Vec::new();
    let mut used = vec![false; design.len()];
    for e in &p.scene.elements {
        let found = (0..design.len()).find(|&k| !used[k] && design[k].id == e.id);
        if let Some(k) = found {
            used[k] = true;
        }
        if locked.contains(e.id.as_str()) {
            if let Some(k) = found {
                if !same_locked(&design[k], e) {
                    rule_issues.push(Issue::error(
                        format!("elements[{}]", elements.len()),
                        "rule_locked",
                        format!("{} is fixed in this puzzle and cannot be changed", label(e)),
                    ));
                }
            }
            elements.push(e.clone());
            is_design.push(false);
        } else if let Some(k) = found {
            elements.push(design[k].clone());
            is_design.push(true);
        }
    }
    for (k, d) in design.iter().enumerate() {
        if !used[k] {
            elements.push(d.clone());
            is_design.push(true);
        }
    }
    scene.elements = elements;
    scene.solver.method = p.scoring.method;
    let ppw = Some(p.scoring.ppw);
    match p.scoring.method {
        Method::Fdtd => scene.solver.fdtd.preview_ppw = ppw,
        Method::Fem => scene.solver.fem.preview_ppw = ppw,
        Method::Mom => scene.solver.mom.preview_ppw = ppw,
    }

    let mut issues = validate(&scene);
    let has_error = |i: usize| {
        let at = format!("elements[{i}]");
        issues.iter().any(|x| x.is_error() && (x.path == at || x.path.starts_with(&format!("{at}."))))
    };
    let checkable: Vec<bool> = (0..scene.elements.len()).map(|i| !has_error(i)).collect();
    check_rules(p, &scene, &is_design, &checkable, &mut rule_issues);
    issues.extend(rule_issues);
    Composed { scene, design: is_design, issues }
}

fn label(e: &Element) -> String {
    if e.name.is_empty() {
        format!("the {} \"{}\"", e.shape.kind_name(), e.id)
    } else {
        format!("\"{}\"", e.name)
    }
}

/// Equal as far as the solve is concerned: a dispersive material's preset
/// label does not count.
fn same_material(a: &Material, b: &Material) -> bool {
    match (a, b) {
        (Material::Dispersive { eps_inf: ea, poles: pa, .. }, Material::Dispersive { eps_inf: eb, poles: pb, .. }) => {
            ea == eb && pa == pb
        }
        _ => a == b,
    }
}

/// A locked element as the design gives it back is unchanged if it differs
/// only in its name, a dispersive material's preset label (null or another
/// label for the same poles), or in floats by rounding (relative 1e-9), so an
/// app that round-trips the document does not trip the rule.
fn same_locked(given: &Element, locked: &Element) -> bool {
    fn close(a: &Value, b: &Value) -> bool {
        match (a, b) {
            (Value::Number(x), Value::Number(y)) => match (x.as_f64(), y.as_f64()) {
                (Some(x), Some(y)) => (x - y).abs() <= 1e-9 * x.abs().max(y.abs()).max(1.0),
                _ => x == y,
            },
            (Value::Array(x), Value::Array(y)) => x.len() == y.len() && x.iter().zip(y).all(|(a, b)| close(a, b)),
            (Value::Object(x), Value::Object(y)) => {
                let keys: HashSet<&String> = x.keys().chain(y.keys()).filter(|k| *k != "preset" && *k != "name").collect();
                keys.into_iter().all(|k| close(x.get(k).unwrap_or(&Value::Null), y.get(k).unwrap_or(&Value::Null)))
            }
            _ => a == b,
        }
    }
    match (serde_json::to_value(given), serde_json::to_value(locked)) {
        (Ok(a), Ok(b)) => close(&a, &b),
        _ => given == locked,
    }
}

/// Assigns each part to a palette entry it fits, at most `max` parts per
/// entry, so that as many parts as possible are placed (Kuhn's augmenting
/// paths over the entries' slots, parts in order). `fits[i]` lists the
/// entries part i may use. Returns the entry per part, `None` where the
/// palette has no room left for it.
fn assign_palette(fits: &[Vec<usize>], capacity: &[usize]) -> Vec<Option<usize>> {
    // slots[e] holds the parts assigned to entry e.
    let mut slots: Vec<Vec<usize>> = vec![Vec::new(); capacity.len()];
    let mut entry_of: Vec<Option<usize>> = vec![None; fits.len()];
    fn place(
        i: usize,
        fits: &[Vec<usize>],
        capacity: &[usize],
        slots: &mut [Vec<usize>],
        entry_of: &mut [Option<usize>],
        seen: &mut [bool],
    ) -> bool {
        for &e in &fits[i] {
            if seen[e] {
                continue;
            }
            seen[e] = true;
            if slots[e].len() < capacity[e] {
                slots[e].push(i);
                entry_of[i] = Some(e);
                return true;
            }
            for k in 0..slots[e].len() {
                let other = slots[e][k];
                if place(other, fits, capacity, slots, entry_of, seen) {
                    slots[e][k] = i;
                    entry_of[i] = Some(e);
                    return true;
                }
            }
        }
        false
    }
    for i in 0..fits.len() {
        let mut seen = vec![false; capacity.len()];
        place(i, fits, capacity, &mut slots, &mut entry_of, &mut seen);
    }
    entry_of
}

fn check_rules(p: &Puzzle, scene: &Scene, is_design: &[bool], checkable: &[bool], out: &mut Vec<Issue>) {
    let r = &p.rules;
    let region = Rect::new(r.region[0], r.region[1], r.region[2], r.region[3]);
    let mut enabled = 0u32;
    // Enabled parts that some palette entry fits, matched to entries below.
    let mut fitting: Vec<(usize, Vec<usize>)> = Vec::new();
    for (i, e) in scene.elements.iter().enumerate() {
        if !is_design[i] {
            continue;
        }
        let path = format!("elements[{i}]");
        if scene.sources.iter().any(|s| s.id == e.id) || scene.detectors.iter().any(|d| d.id == e.id) {
            out.push(Issue::error(
                format!("{path}.id"),
                "rule_id_clash",
                format!("element id \"{}\" is already used by a source or detector of the puzzle", e.id),
            ));
        }
        if !e.enabled {
            continue;
        }
        enabled += 1;
        let kind = e.shape.kind_name();
        let kind_found = r.palette.iter().any(|entry| entry.kind == kind);
        let fits: Vec<usize> = (0..r.palette.len())
            .filter(|&k| {
                let entry = &r.palette[k];
                entry.kind == kind
                    && (entry.materials.is_empty()
                        || entry.materials.iter().any(|m| p.material(m).is_some_and(|m| same_material(&m, &e.material))))
            })
            .collect();
        if !kind_found {
            out.push(Issue::error(
                path.clone(),
                "rule_palette_kind",
                format!("{} is not one of the parts this puzzle allows", label(e)),
            ));
        } else if fits.is_empty() {
            out.push(Issue::error(
                format!("{path}.material"),
                "rule_palette_material",
                format!("{} has a material this puzzle does not allow for a {kind}", label(e)),
            ));
        } else {
            fitting.push((i, fits));
        }
        if checkable[i] {
            let bodies = element_bodies(i, e, scene.wavelength_um);
            if bodies.iter().any(|b| !region.contains_rect(&b.bbox)) {
                out.push(Issue::error(
                    path.clone(),
                    "rule_region",
                    format!("{} lies outside the region where parts may go", label(e)),
                ));
            }
        }
    }
    let n = fitting.len();
    let capacity: Vec<usize> = r.palette.iter().map(|e| e.max.map_or(n, |m| m as usize)).collect();
    let fits: Vec<Vec<usize>> = fitting.iter().map(|(_, f)| f.clone()).collect();
    for ((i, f), entry) in fitting.iter().zip(assign_palette(&fits, &capacity)) {
        if entry.is_none() {
            let max: usize = f.iter().map(|&k| capacity[k]).sum();
            let kind = scene.elements[*i].shape.kind_name();
            out.push(Issue::error(
                format!("elements[{i}]"),
                "rule_palette_max",
                format!("this puzzle allows at most {max} {kind} part{} like this one", if max == 1 { "" } else { "s" }),
            ));
        }
    }
    if let Some(max) = r.max_elements {
        if enabled > max {
            out.push(Issue::error(
                "elements",
                "rule_max_elements",
                format!("this puzzle allows at most {max} part{}; the design has {enabled}", if max == 1 { "" } else { "s" }),
            ));
        }
    }
}
