//! The check report: validation issues, solver capability issues,
//! cost estimates for both qualities and derived quantities.

use serde::Serialize;
use serde_json::Value;

use crate::problem::compile_unchecked;
use crate::scene::{derived::derived, parse_scene, validate, Issue, Scene};
use crate::solver::{solver_for, Estimate, Method, Quality};

#[derive(Serialize, Clone, Debug)]
pub struct CheckReport {
    /// True when nothing blocks a preview solve.
    pub ok: bool,
    pub issues: Vec<Issue>,
    pub estimates: Option<Estimates>,
    pub derived: Value,
}

#[derive(Serialize, Clone, Debug)]
pub struct Estimates {
    pub preview: Option<EstimateReport>,
    #[serde(rename = "final")]
    pub final_: Option<EstimateReport>,
}

#[derive(Serialize, Clone, Debug)]
pub struct EstimateReport {
    pub method: Method,
    pub ppw: f64,
    pub unknowns: u64,
    pub memory_mb: f64,
    pub seconds: f64,
    pub grid: Option<[usize; 2]>,
    pub detail: String,
}

pub fn check(scene: &Scene) -> CheckReport {
    let mut issues = validate(scene);
    let blocked = |issues: &[Issue], q: Quality| issues.iter().any(|i| i.is_error() && i.applies_to(q));

    let mut per_quality: Vec<(Quality, Option<EstimateReport>, Vec<Issue>)> = Vec::new();
    for q in [Quality::Preview, Quality::Final] {
        if blocked(&issues, q) {
            per_quality.push((q, None, Vec::new()));
            continue;
        }
        let p = compile_unchecked(scene, q);
        let solver = solver_for(p.settings.method);
        let mut extra = solver.check(&p);
        let est: Estimate = crate::solver::estimate(&p);
        if est.memory_mb > p.settings.memory_limit_mb {
            extra.push(Issue::error(
                "solver.memory_limit_mb",
                "too_large",
                format!(
                    "{} {} needs about {:.0} MB, more than the {:.0} MB limit",
                    solver.method().label(),
                    q.name(),
                    est.memory_mb,
                    p.settings.memory_limit_mb
                ),
            ));
        }
        if let Some(default) = p.settings.ppw_lowered_from {
            extra.push(Issue::warning(
                "solver",
                "preview_coarsened",
                format!(
                    "the preview runs at {:.1} points per wavelength instead of {:.0} to fit the size limits",
                    p.settings.ppw, default
                ),
            ));
        }
        for w in &p.incident.warnings {
            extra.push(Issue::warning("sources", "incident_accuracy", w.clone()));
        }
        let report = EstimateReport {
            method: p.settings.method,
            ppw: p.settings.ppw,
            unknowns: est.unknowns,
            memory_mb: est.memory_mb,
            seconds: est.seconds,
            grid: est.grid,
            detail: est.detail,
        };
        per_quality.push((q, Some(report), extra));
    }

    // An issue the solver raises for both qualities is reported once, without a quality.
    let (preview_extra, final_extra) = (&per_quality[0].2, &per_quality[1].2);
    for i in preview_extra {
        let same = |o: &Issue| o.path == i.path && o.code == i.code && o.message == i.message;
        if final_extra.iter().any(same) {
            issues.push(i.clone());
        } else {
            issues.push(i.clone().for_quality(Quality::Preview));
        }
    }
    for i in final_extra {
        let same = |o: &Issue| o.path == i.path && o.code == i.code && o.message == i.message;
        if !preview_extra.iter().any(same) {
            issues.push(i.clone().for_quality(Quality::Final));
        }
    }

    let ok = !blocked(&issues, Quality::Preview);
    let mut it = per_quality.into_iter();
    let preview = it.next().and_then(|x| x.1);
    let final_ = it.next().and_then(|x| x.1);
    let estimates = (preview.is_some() || final_.is_some()).then_some(Estimates { preview, final_ });
    let derived = if scene.wavelength_um.is_finite() && scene.background.n.is_finite() {
        derived(scene)
    } else {
        Value::Null
    };
    CheckReport { ok, issues, estimates, derived }
}

/// Check report for scene JSON; a scene that does not parse gives a report with
/// one `parse` or `schema_version` issue.
pub fn check_json(scene_json: &str) -> CheckReport {
    match parse_scene(scene_json) {
        Ok(scene) => check(&scene),
        Err(e) => CheckReport {
            ok: false,
            issues: vec![Issue::error("", e.code, e.message)],
            estimates: None,
            derived: Value::Null,
        },
    }
}
