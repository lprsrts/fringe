//! Scoring a design: one solve per enabled source, cases by superposition,
//! detector readings per case, and the goal's metric.
//!
//! The solvers are linear, so the field of any set of sources is the sum of
//! their separate fields. Each enabled source is solved alone at the scoring
//! method's preview quality and the puzzle's resolution; a case (one setting
//! of the input bits) is the sum of the fields of the sources that are on,
//! with weight 1, and its detectors are measured on that sum. The per-source
//! fields are returned with the readings, so the app can show any case by
//! combining them again, without a solve.
//!
//! For FDTD the sum differs slightly from one solve with all sources on: each
//! single-source run corrects the grid dispersion for its own source's
//! direction.
//!
//! Every score is "higher is better":
//!
//! | goal | score | unit |
//! |---|---|---|
//! | `truth_table` | 10 log10(weakest 1 / strongest 0), smallest over the outputs | dB |
//! | `maximize`, line detector | flux / reference × 100 | % |
//! | `maximize`, box detector | mean \|E\|² / reference | × |
//! | `minimize` | −10 log10(Σ quantity / reference) | dB |
//! | `target` | 100 × min(a / ratio, b / (1 − ratio)), a and b the two fluxes over the reference; to pass, the share a / (a + b) must also be within the tolerance | % |
//!
//! With a `"source"` reference, an emitter's power is what it gives off in
//! the case being measured, not its free-space power: a mirror close to an
//! emitter can make it give off half as much again, and a share of the
//! free-space power could pass 100 %. See `SourceReference::case_power`.
//!
//! Values below [`FLOOR`] (in units of the reference) count as `FLOOR`, so a
//! contrast or a suppression is at most 60 dB. With several cases, a
//! maximize or target score is the worst case's, a minimize score too.

use std::sync::Arc;
use crate::time::Instant;

use serde::Serialize;
use serde_json::{json, Value};

use crate::analytic::metrics::simpson;
use crate::detectors::{line_flux, measure_all, value_at, FieldView, Measurement, Reading};
use crate::scene::{Element, Scene, Source, SourceKind};
use crate::solver::{solve, FieldGrid, Quality, SolveContext, SolveError};
use crate::source::{line_source_norm, Incident};
use crate::types::{cis, Rect, Vec2, C64};

use super::rules::{compose, Composed};
use super::{GoalKind, MinimizeQuantity, Puzzle, Reference, ReferenceKind};

/// The smallest detector value (relative to the reference) a dB score uses.
pub const FLOOR: f64 = 1e-6;

/// The result JSON (`fringe_puzzle_result_json`) and the per-source fields,
/// in the order of its `"sources"`.
pub struct Evaluation {
    pub json: Value,
    pub fields: Vec<Arc<FieldGrid>>,
}

impl Evaluation {
    pub fn passed(&self) -> bool {
        self.json["passed"] == true
    }

    pub fn stars(&self) -> u64 {
        self.json["stars"].as_u64().unwrap_or(0)
    }

    pub fn score(&self) -> Option<f64> {
        self.json["score"].as_f64()
    }
}

/// Scores `design` (see [`compose`] for how it is applied). A design that
/// breaks a rule or does not validate is not solved: the result has
/// `"valid": false`, the issues and no fields. Errors are solver failures and
/// cancellation.
pub fn evaluate(p: &Puzzle, design: &[Element], ctx: &SolveContext) -> Result<Evaluation, SolveError> {
    let t0 = Instant::now();
    let c = compose(p, design);
    if !c.is_valid() {
        return Ok(Evaluation { json: invalid_json(p, &c, t0), fields: Vec::new() });
    }
    let ids: Vec<String> = c.scene.enabled_sources().map(|s| s.id.clone()).collect();
    let mut fields = Vec::with_capacity(ids.len());
    let n = ids.len() as f64;
    for (k, id) in ids.iter().enumerate() {
        let mut s = c.scene.clone();
        for src in &mut s.sources {
            src.enabled = src.id == *id;
        }
        let f = solve(&s, Quality::Preview, &ctx.window(k as f64 / n, (k + 1) as f64 / n))?;
        fields.push(Arc::new(f));
    }

    let reference = SourceReference::new(p, &c.scene);
    let n_inputs = p.inputs.len();
    let mut cases = Vec::with_capacity(1 << n_inputs);
    for case in 0..1usize << n_inputs {
        let bits: Vec<bool> = (0..n_inputs).map(|b| (case >> (n_inputs - 1 - b)) & 1 == 1).collect();
        let weights: Vec<f64> = ids
            .iter()
            .map(|id| match p.inputs.iter().position(|x| x == id) {
                Some(b) => f64::from(u8::from(bits[b])),
                None => 1.0,
            })
            .collect();
        let readings = case_readings(&fields, &weights, &c.scene);
        let source_power = reference.case_power(&c.scene, &ids, &fields, &weights);
        cases.push(Case { bits, weights, readings, source_power });
    }

    let outcome = score(p, &c.scene, &cases, &reference);
    let passed = outcome.passed && outcome.score.is_finite();
    let stars = if passed { p.stars.iter().filter(|&&t| outcome.score >= t).count() } else { 0 };
    let cases_json: Vec<Value> = cases
        .iter()
        .zip(&outcome.outputs)
        .map(|(case, outputs)| {
            json!({
                "bits": case.bits,
                "weights": case.weights.iter().map(|w| [*w, 0.0]).collect::<Vec<_>>(),
                "readings": case.readings,
                "outputs": outputs,
            })
        })
        .collect();
    let json = json!({
        "puzzle": p.id,
        "valid": true,
        "issues": c.issues,
        "goal_type": p.goal.kind.type_name(),
        "method": p.scoring.method,
        "ppw": p.scoring.ppw,
        "sources": ids,
        "inputs": p.inputs,
        "cases": cases_json,
        "metric": outcome.metric,
        "score": finite(outcome.score),
        "pass": p.goal.pass,
        "passed": passed,
        "stars": stars,
        "star_thresholds": p.stars,
        "wall_s": t0.elapsed().as_secs_f64(),
    });
    Ok(Evaluation { json, fields })
}

fn finite(v: f64) -> Value {
    if v.is_finite() {
        json!(v)
    } else {
        Value::Null
    }
}

fn invalid_json(p: &Puzzle, c: &Composed, t0: Instant) -> Value {
    json!({
        "puzzle": p.id,
        "valid": false,
        "issues": c.issues,
        "goal_type": p.goal.kind.type_name(),
        "method": p.scoring.method,
        "ppw": p.scoring.ppw,
        "sources": [],
        "inputs": p.inputs,
        "cases": [],
        "metric": Value::Null,
        "score": Value::Null,
        "pass": p.goal.pass,
        "passed": false,
        "stars": 0,
        "star_thresholds": p.stars,
        "wall_s": t0.elapsed().as_secs_f64(),
    })
}

struct Case {
    bits: Vec<bool>,
    weights: Vec<f64>,
    readings: Vec<Reading>,
    /// The power the reference source gives off in this case, if it has one.
    source_power: Option<f64>,
}

/// Readings of the weighted sum of `fields`. A single field at weight 1 uses
/// its cached readings.
fn case_readings(fields: &[Arc<FieldGrid>], weights: &[f64], scene: &Scene) -> Vec<Reading> {
    let on: Vec<usize> = (0..fields.len()).filter(|&k| weights[k] != 0.0).collect();
    if let [k] = on[..] {
        if weights[k] == 1.0 {
            return fields[k].detector_readings().to_vec();
        }
    }
    let Some(first) = fields.first() else { return Vec::new() };
    let sum = |part: fn(&FieldGrid) -> &[C64]| -> Vec<C64> {
        let mut out = vec![C64::new(0.0, 0.0); first.grid.len()];
        for &k in &on {
            out.iter_mut().zip(part(&fields[k])).for_each(|(o, v)| *o += weights[k] * v);
        }
        out
    };
    let (total, incident) = (sum(|f| &f.total), sum(|f| &f.incident));
    let view = FieldView { grid: &first.grid, total: &total, incident: &incident, wavelength_um: scene.wavelength_um };
    measure_all(&view, &scene.detectors)
}

/// The power a source radiates, per µm in z: for a Gaussian beam the flux
/// through a line across its waist (integrated from the beam's own plane
/// waves, so it is exact for the field the solvers use), for a line source
/// `2 A² / (k0 |H0⁽²⁾(2π)|²)`. A plane wave carries no finite power: `None`.
pub fn source_power(scene: &Scene, s: &Source) -> Option<f64> {
    let lambda0 = scene.wavelength_um;
    let k0 = 2.0 * std::f64::consts::PI / lambda0;
    let k_b = k0 * scene.background.n;
    let lambda_b = lambda0 / scene.background.n;
    match s.kind {
        SourceKind::PlaneWave { .. } => None,
        SourceKind::LineSource { amplitude, .. } => {
            let h = line_source_norm();
            Some(2.0 * amplitude * amplitude / (k0 * h * h))
        }
        SourceKind::GaussianBeam { waist_um, waist_x_um, waist_y_um, angle_deg, amplitude, .. } => {
            let waist = Vec2::new(waist_x_um, waist_y_um);
            let theta = angle_deg.to_radians();
            let axis = Vec2::from_angle(theta);
            let across = Vec2::new(-axis.y, axis.x);
            // The profile is below 1e-13 of its peak 4 w0 out; a sub-wavelength
            // waist is widened by the band limit, hence the λ_b terms.
            let half = 4.0 * waist_um.max(lambda_b) + lambda_b;
            let rect = Rect::new(waist.x - half, waist.x + half, waist.y - half, waist.y + half);
            let inc = Incident::gaussian(k_b, waist_um, waist, theta, amplitude, 0.0, rect);
            let intervals = ((2.0 * half / (lambda_b / 32.0) / 2.0).ceil() as usize) * 2;
            let h = 2.0 * half / intervals as f64;
            let samples: Vec<f64> = (0..=intervals)
                .map(|i| {
                    let (e, g) = inc.eval_grad(waist + across * (-half + i as f64 * h));
                    -(e.conj() * (g[0] * axis.x + g[1] * axis.y)).im / (2.0 * k0)
                })
                .collect();
            Some(simpson(&samples, h))
        }
    }
}

/// How much larger the net flux out of the contour around the design must be
/// than the power from the field at the emitter to replace it (see
/// `SourceReference::case_power`).
const OUTFLOW_MARGIN: f64 = 1.02;

/// The `"source"` reference: the reference source, its power on its own in
/// the background ([`source_power`]) and its amplitude².
struct SourceReference {
    source: Option<Source>,
    power: Option<f64>,
    intensity: Option<f64>,
    /// A closed contour around the design region and the emitter, for the
    /// lower bound on an emitter's power in `case_power`.
    contour: Rect,
}

impl SourceReference {
    fn new(p: &Puzzle, scene: &Scene) -> SourceReference {
        let id = p.goal.reference_source.as_ref().or(p.inputs.first());
        let src = match id {
            Some(id) => scene.sources.iter().find(|s| &s.id == id),
            None => scene.enabled_sources().next(),
        };
        // A quarter of a background wavelength clear of the region (so of
        // every design part) and of the domain edge, where the fields of FEM
        // and FDTD are less accurate.
        let margin = 0.25 * scene.wavelength_um / scene.background.n;
        let [x0, x1, y0, y1] = p.rules.region;
        let mut around = Rect::new(x0, x1, y0, y1);
        if let Some(Source { kind: SourceKind::LineSource { x_um, y_um, .. }, .. }) = src {
            around = around.include(Vec2::new(*x_um, *y_um));
        }
        let around = around.expand(margin);
        let d = &scene.domain;
        let inner = Rect::new(d.x_min_um, d.x_max_um, d.y_min_um, d.y_max_um).expand(-margin);
        let contour = Rect::new(
            around.x_min.max(inner.x_min),
            around.x_max.min(inner.x_max),
            around.y_min.max(inner.y_min),
            around.y_max.min(inner.y_max),
        );
        SourceReference {
            source: src.cloned(),
            power: src.and_then(|s| source_power(scene, s)),
            intensity: src.map(|s| s.kind.amplitude().powi(2)),
            contour,
        }
    }

    fn is_emitter(&self) -> bool {
        self.source.as_ref().is_some_and(|s| matches!(s.kind, SourceKind::LineSource { .. }))
    }

    /// The power the reference source gives off in one case. A beam's power
    /// is set by the beam alone. An emitter is a current, and the power it
    /// gives off depends on what is near it: a body that reflects its field
    /// back onto it can raise or lower it by tens of percent. So for an
    /// emitter that is on, this is the power it actually gives off in this
    /// case,
    ///
    /// `P = (2 / k0) (|w c|² + Re[(w c)* E_reg(r0)])`,
    ///
    /// with `w c` its weighted coefficient (field `c H0⁽²⁾(k_b r)`) and `E_reg`
    /// the case's field at the emitter less the emitter's own singular
    /// incident field: every source's scattered field plus the other
    /// sources' fields. Without any body `E_reg = 0` and `P` is
    /// [`source_power`]. Power absorbed in a body counts as given off, so the
    /// share of it that reaches a detector is at most 1.
    ///
    /// `E_reg` comes from the grid by the detectors' 8 × 8 interpolation, and
    /// with metal a few hundredths of a micrometre from the emitter the
    /// stencil reaches into the metal, where the field bends sharply. In a
    /// resonant channel that made `P` up to 15 % too low, and a share of more
    /// than 100 %. So when the emitter is the only source on, `P` is at least
    /// the net flux out of a box around the design region and the emitter:
    /// that is what the emitter gives off less what the bodies inside absorb,
    /// a lower bound that does not depend on the field near the emitter.
    fn case_power(&self, scene: &Scene, ids: &[String], fields: &[Arc<FieldGrid>], weights: &[f64]) -> Option<f64> {
        let src = self.source.as_ref()?;
        let SourceKind::LineSource { x_um, y_um, amplitude, phase_deg } = src.kind else { return self.power };
        let k = ids.iter().position(|id| *id == src.id)?;
        let w = weights[k];
        if w == 0.0 {
            return self.power;
        }
        let r0 = Vec2::new(x_um, y_um);
        let grid = &fields[k].grid;
        let mut e_reg = -w * value_at(grid, &fields[k].incident, r0);
        for (f, &wj) in fields.iter().zip(weights) {
            if wj != 0.0 {
                e_reg += wj * value_at(grid, &f.total, r0);
            }
        }
        let c = w * amplitude * cis(phase_deg.to_radians()) / line_source_norm();
        let k0 = 2.0 * std::f64::consts::PI / scene.wavelength_um;
        let p = 2.0 / k0 * (c.norm_sqr() + (c.conj() * e_reg).re);
        let alone = weights.iter().enumerate().all(|(j, &wj)| j == k || wj == 0.0);
        // The contour flux has its own error of 1-2 % (more at FDTD), so it
        // replaces `P` only when it is clearly larger; with no bodies `P` is
        // exact and stays.
        let outflow = if alone { self.outflow(scene, &fields[k], w) } else { f64::NAN };
        let p = if outflow > OUTFLOW_MARGIN * p { outflow } else { p };
        (p.is_finite() && p > 0.0).then_some(p)
    }

    /// The net power out of `contour` of `field` at weight `w`, or NaN when
    /// the contour is degenerate.
    fn outflow(&self, scene: &Scene, field: &FieldGrid, w: f64) -> f64 {
        let r = self.contour;
        if !(r.width() > 0.0 && r.height() > 0.0) {
            return f64::NAN;
        }
        let view = FieldView { grid: &field.grid, total: &field.total, incident: &field.incident, wavelength_um: scene.wavelength_um };
        // Counter-clockwise, so each side's normal points out of the box.
        let corners = [
            Vec2::new(r.x_min, r.y_min),
            Vec2::new(r.x_max, r.y_min),
            Vec2::new(r.x_max, r.y_max),
            Vec2::new(r.x_min, r.y_max),
        ];
        let flux: f64 = (0..4).map(|i| line_flux(&view, corners[i], corners[(i + 1) % 4]).total).sum();
        w * w * flux
    }
}

/// A detector's value (total flux for a line, mean total |E|² for a box) and
/// the same on the incident field.
fn detector_value(readings: &[Reading], id: &str) -> Option<(f64, f64, bool)> {
    let r = readings.iter().find(|r| r.id == id)?;
    Some(match &r.measurement {
        Measurement::Line { flux, .. } => (flux.total, flux.incident, true),
        Measurement::Box { total, incident, .. } => (total.mean, incident.mean, false),
    })
}

fn detector_name<'a>(scene: &'a Scene, id: &'a str) -> &'a str {
    scene.detectors.iter().find(|d| d.id == id && !d.name.is_empty()).map_or(id, |d| d.name.as_str())
}

#[derive(Serialize)]
struct Output {
    detector: String,
    target: Option<bool>,
    value: Option<f64>,
}

struct Outcome {
    score: f64,
    passed: bool,
    metric: Value,
    /// Per case.
    outputs: Vec<Vec<Output>>,
}

fn score(p: &Puzzle, scene: &Scene, cases: &[Case], src: &SourceReference) -> Outcome {
    // The divisor for a detector value in one case; `line` tells flux from |E|².
    let reference = |case: &Case, incident: f64, line: bool| match p.goal.reference {
        Reference::Fixed(v) => v,
        Reference::Named(ReferenceKind::Incident) => incident,
        Reference::Named(ReferenceKind::Source) => (if line { case.source_power } else { src.intensity }).unwrap_or(f64::NAN),
    };
    let ref_text = |line: bool| match p.goal.reference {
        Reference::Fixed(_) => "the reference",
        Reference::Named(ReferenceKind::Incident) if line => "the incident power",
        Reference::Named(ReferenceKind::Incident) => "the incident intensity",
        Reference::Named(ReferenceKind::Source) if line && src.is_emitter() => "the power the emitter gives off",
        Reference::Named(ReferenceKind::Source) if line => "the source power",
        Reference::Named(ReferenceKind::Source) => "the source intensity",
    };
    let value = |case: &Case, id: &str| -> (f64, bool) {
        match detector_value(&case.readings, id) {
            Some((v, inc, line)) => (v / reference(case, inc, line), line),
            None => (f64::NAN, true),
        }
    };
    let floor_db = |v: f64| 10.0 * v.max(FLOOR).log10();
    let output = |id: &str, target: Option<bool>, v: f64| Output { detector: id.into(), target, value: v.is_finite().then_some(v) };
    let worst = |vals: &[f64], f: fn(f64, f64) -> f64, start: f64| vals.iter().copied().fold(start, f);

    match &p.goal.kind {
        GoalKind::TruthTable { outputs } => {
            let mut per_case: Vec<Vec<Output>> = cases.iter().map(|_| Vec::new()).collect();
            let mut best: Option<(f64, String)> = None;
            for o in outputs {
                let (mut weakest_one, mut strongest_zero) = (f64::INFINITY, f64::NEG_INFINITY);
                let mut missing = false;
                for (k, case) in cases.iter().enumerate() {
                    let v = value(case, &o.detector).0;
                    let on = o.bits.get(k) == Some(&1);
                    per_case[k].push(output(&o.detector, Some(on), v));
                    missing |= !v.is_finite();
                    if on {
                        weakest_one = weakest_one.min(v);
                    } else {
                        strongest_zero = strongest_zero.max(v);
                    }
                }
                let contrast = if missing { f64::NAN } else { floor_db(weakest_one) - floor_db(strongest_zero) };
                let name = detector_name(scene, &o.detector);
                let prefix = if outputs.len() > 1 { format!("{name}: ") } else { String::new() };
                let text = format!("{prefix}weakest 1 is {}, strongest 0 is {}", short(weakest_one), short(strongest_zero));
                if best.as_ref().is_none_or(|b| contrast.is_nan() || contrast < b.0) {
                    best = Some((contrast, text));
                }
            }
            let (score, text) = best.unwrap_or((f64::NAN, String::new()));
            Outcome {
                score,
                passed: score >= p.goal.pass,
                metric: json!({ "label": "contrast", "unit": "dB", "value": finite(score), "text": text }),
                outputs: per_case,
            }
        }
        GoalKind::Maximize { detector } => {
            let mut vals = Vec::new();
            let mut line = true;
            let per_case = cases
                .iter()
                .map(|case| {
                    let (v, l) = value(case, detector);
                    line = l;
                    vals.push(if v.is_finite() { v } else { f64::NAN });
                    vec![output(detector, None, v)]
                })
                .collect();
            let v = worst(&vals, f64::min, f64::INFINITY);
            let name = detector_name(scene, detector);
            let (score, unit, label, text) = if line {
                (100.0 * v, "%", "power", format!("{:.1} % of {} reaches {name}", 100.0 * v, ref_text(true)))
            } else {
                (v, "×", "intensity", format!("the mean |E|² in {name} is {} times {}", short(v), ref_text(false)))
            };
            Outcome {
                score,
                passed: score >= p.goal.pass,
                metric: json!({ "label": label, "unit": unit, "value": finite(score), "text": text }),
                outputs: per_case,
            }
        }
        GoalKind::Minimize { detectors, quantity } => {
            let line = *quantity != MinimizeQuantity::Intensity;
            let mut fractions = Vec::new();
            let per_case = cases
                .iter()
                .map(|case| {
                    let mut sum = 0.0;
                    let mut incident = 0.0;
                    let mut outs = Vec::new();
                    for id in detectors {
                        let r = case.readings.iter().find(|r| &r.id == id);
                        let (q, inc) = match r.map(|r| &r.measurement) {
                            Some(Measurement::Line { flux, .. }) => match quantity {
                                MinimizeQuantity::Scattered => (flux.scattered, flux.incident),
                                _ => (flux.total, flux.incident),
                            },
                            Some(Measurement::Box { total, incident, .. }) => (total.mean, incident.mean),
                            None => (f64::NAN, f64::NAN),
                        };
                        sum += q;
                        incident += inc;
                        outs.push((id.clone(), q));
                    }
                    let r = reference(case, incident, line);
                    fractions.push(sum / r);
                    outs.into_iter().map(|(id, q)| output(&id, None, q / r)).collect()
                })
                .collect();
            let v = worst(&fractions, |a, b| if a.is_nan() || b.is_nan() { f64::NAN } else { a.max(b) }, f64::NEG_INFINITY);
            let score = -floor_db(v);
            let score = if v.is_nan() { f64::NAN } else { score };
            let names: Vec<&str> = detectors.iter().map(|d| detector_name(scene, d)).collect();
            let what = match quantity {
                MinimizeQuantity::Scattered => format!("the scattered power through {}", names.join(", ")),
                MinimizeQuantity::Flux => format!("the power through {}", names.join(", ")),
                MinimizeQuantity::Intensity => format!("the mean |E|² in {}", names.join(", ")),
            };
            Outcome {
                score,
                passed: score >= p.goal.pass,
                metric: json!({
                    "label": "suppression", "unit": "dB", "value": finite(score),
                    "text": format!("{what} is {} % of {}", short(100.0 * v), ref_text(line)),
                    "fraction": finite(v),
                }),
                outputs: per_case,
            }
        }
        GoalKind::Target { detectors: [a, b], ratio, tolerance } => {
            let mut balanced = f64::INFINITY;
            let mut worst_case = (f64::NAN, f64::NAN);
            let mut ratio_ok = true;
            let per_case = cases
                .iter()
                .map(|case| {
                    let (va, _) = value(case, a);
                    let (vb, _) = value(case, b);
                    let share = va / (va + vb);
                    if share.is_nan() || (share - ratio).abs() > *tolerance {
                        ratio_ok = false;
                    }
                    // Each side against the power it should get: 1 for a
                    // lossless, exact split, less for loss or imbalance.
                    let weaker = (va / ratio).min(vb / (1.0 - ratio));
                    let weaker = if weaker.is_finite() { weaker } else { f64::NAN };
                    if weaker.is_nan() || weaker < balanced {
                        balanced = weaker;
                        worst_case = (va, vb);
                    }
                    vec![output(a, None, va), output(b, None, vb)]
                })
                .collect();
            let score = 100.0 * balanced;
            let (va, vb) = worst_case;
            let share = va / (va + vb);
            let (na, nb) = (detector_name(scene, a), detector_name(scene, b));
            let text = format!(
                "{na} gets {:.1} % and {nb} {:.1} % of {}, a {:.0}/{:.0} split (aim: {:.0}/{:.0} within {:.0} points)",
                100.0 * va,
                100.0 * vb,
                ref_text(true),
                100.0 * share,
                100.0 * (1.0 - share),
                100.0 * ratio,
                100.0 * (1.0 - ratio),
                100.0 * tolerance
            );
            Outcome {
                score,
                passed: ratio_ok && score >= p.goal.pass,
                metric: json!({
                    "label": "balanced power", "unit": "%", "value": finite(score), "text": text,
                    "share": finite(share), "share_ok": ratio_ok,
                }),
                outputs: per_case,
            }
        }
    }
}

/// Three significant figures (at most 8 decimals), or "none" for a missing
/// value.
fn short(v: f64) -> String {
    if !v.is_finite() {
        return "none".into();
    }
    if v.abs() < 5e-9 {
        return "0".into();
    }
    let digits = (2 - v.abs().log10().floor() as i32).clamp(0, 8) as usize;
    fixed(v, digits)
}

/// `v` with `digits` decimals, without the minus sign of a value that rounds
/// to zero (a tiny negative flux would otherwise print as "-0.0000").
pub fn fixed(v: f64, digits: usize) -> String {
    let s = format!("{v:.digits$}");
    match s.strip_prefix('-') {
        Some(rest) if rest.bytes().all(|c| c == b'0' || c == b'.') => rest.to_string(),
        _ => s,
    }
}

/// What `fringe-cli puzzle verify` checks for one puzzle.
pub struct VerifyReport {
    pub id: String,
    /// Problems with the puzzle file itself (see [`Puzzle::problems`]).
    pub problems: Vec<String>,
    /// The result for the reference solution.
    pub reference: Result<Value, String>,
    /// The result for the puzzle as it opens (its own elements, nothing added).
    pub empty: Result<Value, String>,
    pub wall_s: f64,
}

impl VerifyReport {
    /// The puzzle is sound, the reference passes with at least one star, and
    /// the empty design does not pass.
    pub fn ok(&self) -> bool {
        self.problems.is_empty()
            && self.reference.as_ref().is_ok_and(|r| r["passed"] == true && r["stars"].as_u64().unwrap_or(0) >= 1)
            && self.empty.as_ref().is_ok_and(|r| r["passed"] == false)
    }
}

pub fn verify(p: &Puzzle, ctx: &SolveContext) -> Result<VerifyReport, SolveError> {
    let t0 = Instant::now();
    let mut problems = p.problems(super::file_name(&p.id));
    if let Some(m) = reference_problem(p) {
        problems.push(m);
    }
    let run = |design: &[Element], ctx: &SolveContext| -> Result<Result<Value, String>, SolveError> {
        match evaluate(p, design, ctx) {
            Ok(e) => Ok(Ok(e.json)),
            Err(SolveError::Cancelled) => Err(SolveError::Cancelled),
            Err(e) => Ok(Err(format!("{}: {e}", e.code()))),
        }
    };
    let reference = run(&p.reference, &ctx.window(0.0, 0.5))?;
    let empty = run(&p.scene.elements, &ctx.window(0.5, 1.0))?;
    Ok(VerifyReport { id: p.id.clone(), problems, reference, empty, wall_s: t0.elapsed().as_secs_f64() })
}

/// A `"source"` reference needs a finite source power for a flux goal.
fn reference_problem(p: &Puzzle) -> Option<String> {
    if p.goal.reference != Reference::Named(ReferenceKind::Source) {
        return None;
    }
    let src = SourceReference::new(p, &p.scene);
    let needs_power = match &p.goal.kind {
        GoalKind::Minimize { quantity, .. } => *quantity != MinimizeQuantity::Intensity,
        GoalKind::Target { .. } => true,
        kind => kind.detectors().iter().any(|id| {
            p.scene.detectors.iter().any(|d| d.id == *id && matches!(d.shape, crate::scene::DetectorShape::Line { .. }))
        }),
    };
    (needs_power && !src.power.is_some_and(|v| v.is_finite() && v > 0.0)).then(|| {
        "the goal reference is \"source\" but the reference source has no finite power (a plane wave); use \"incident\" or a number".into()
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scene::Source;

    fn scene_with(kind: SourceKind, n_b: f64) -> (Scene, Source) {
        let mut s = crate::scene::examples::default();
        s.background.n = n_b;
        let src = Source::new("s", kind);
        s.sources = vec![src.clone()];
        (s, src)
    }

    #[test]
    fn gaussian_power_matches_the_paraxial_value_for_a_wide_beam() {
        let (s, src) = scene_with(
            SourceKind::GaussianBeam { waist_um: 3.0, waist_x_um: 1.0, waist_y_um: -2.0, angle_deg: 30.0, amplitude: 2.0, phase_deg: 40.0 },
            1.33,
        );
        let p = source_power(&s, &src).unwrap();
        // n_b A² w0 √(π/2) / 2, the paraxial power of exp(−η²/w0²).
        let want = 1.33 * 4.0 * 3.0 * (std::f64::consts::PI / 2.0).sqrt() / 2.0;
        assert!((p - want).abs() < 2e-3 * want, "{p} vs {want}");
    }

    #[test]
    fn line_source_power_does_not_depend_on_the_background() {
        let kind = SourceKind::LineSource { x_um: 0.0, y_um: 0.0, amplitude: 1.5, phase_deg: 0.0 };
        let (a, sa) = scene_with(kind.clone(), 1.0);
        let (b, sb) = scene_with(kind, 1.5);
        let (pa, pb) = (source_power(&a, &sa).unwrap(), source_power(&b, &sb).unwrap());
        assert!((pa - pb).abs() < 1e-12 * pa);
        assert!(source_power(&a, &Source::new("p", SourceKind::PlaneWave { angle_deg: 0.0, amplitude: 1.0, phase_deg: 0.0 })).is_none());
    }

    #[test]
    fn short_numbers() {
        assert_eq!(short(0.81234), "0.812");
        assert_eq!(short(12.345), "12.3");
        assert_eq!(short(0.0001234), "0.000123");
        assert_eq!(short(f64::NAN), "none");
        assert_eq!(short(-1e-12), "0");
        assert_eq!(short(-0.5), "-0.500");
        assert_eq!(fixed(-0.00001, 4), "0.0000");
        assert_eq!(fixed(-0.0, 2), "0.00");
    }
}
