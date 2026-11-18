//! Scene validation. Every issue carries the JSON path of the value
//! it is about, so the app can show it under the right field.

use serde::Serialize;

use crate::geometry::{
    element_bodies, lens_surface_x, min_gap, polygon_min_width, polygon_self_intersects, signed_area, Body,
    MAX_POLYGON_VERTICES,
};
use crate::solver::Quality;
use crate::source::gaussian;
use crate::types::Vec2;

use super::materials::MAX_POLES;
use super::tex;
use super::types::*;

#[derive(Serialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Severity {
    Error,
    Warning,
}

#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct Issue {
    pub path: String,
    pub code: String,
    pub severity: Severity,
    /// Plain text, for the CLI and logs.
    pub message: String,
    /// The message with its math marked up (see `scene::tex`), when it has any; the app
    /// typesets it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message_math: Option<String>,
    /// Set when the issue only applies to one quality (e.g. a final solve that is
    /// too large); `None` applies to both.
    pub quality: Option<Quality>,
}

impl Issue {
    pub fn error(path: impl Into<String>, code: &str, message: impl Into<String>) -> Self {
        Self {
            path: path.into(),
            code: code.into(),
            severity: Severity::Error,
            message: message.into(),
            message_math: None,
            quality: None,
        }
    }

    pub fn warning(path: impl Into<String>, code: &str, message: impl Into<String>) -> Self {
        Self {
            path: path.into(),
            code: code.into(),
            severity: Severity::Warning,
            message: message.into(),
            message_math: None,
            quality: None,
        }
    }

    /// Treats the message as having `$…$` math: keeps it as `message_math` and makes
    /// `message` its plain form.
    pub fn with_math(mut self) -> Self {
        self.message_math = Some(std::mem::take(&mut self.message));
        self.message = super::tex::plain(self.message_math.as_deref().unwrap_or_default());
        self
    }

    pub fn for_quality(mut self, q: Quality) -> Self {
        self.quality = Some(q);
        self
    }

    pub fn is_error(&self) -> bool {
        self.severity == Severity::Error
    }

    /// Whether this issue matters for a solve at quality `q`.
    pub fn applies_to(&self, q: Quality) -> bool {
        self.quality.is_none_or(|iq| iq == q)
    }
}

/// Most slits in a slit screen and bars in a grating.
pub const MAX_SLITS: u32 = 64;
pub const MAX_GRATING_BARS: u32 = 200;

/// Minimum feature size and gap, in background wavelengths.
pub const MIN_FEATURE_WL: f64 = 0.05;

struct Checker {
    issues: Vec<Issue>,
}

impl Checker {
    fn err(&mut self, path: impl Into<String>, code: &str, msg: impl Into<String>) {
        self.issues.push(Issue::error(path, code, msg));
    }

    fn warn(&mut self, path: impl Into<String>, code: &str, msg: impl Into<String>) {
        self.issues.push(Issue::warning(path, code, msg));
    }

    /// `err` for a message with `$…$` math; names put into it must be `tex::escape`d.
    fn err_math(&mut self, path: impl Into<String>, code: &str, msg: impl Into<String>) {
        self.issues.push(Issue::error(path, code, msg).with_math());
    }

    fn warn_math(&mut self, path: impl Into<String>, code: &str, msg: impl Into<String>) {
        self.issues.push(Issue::warning(path, code, msg).with_math());
    }

    /// `err` for a message built from a field label, which has math only if it has a `$`.
    fn err_maybe_math(&mut self, path: &str, code: &str, msg: String) {
        if msg.contains('$') {
            self.err_math(path, code, msg);
        } else {
            self.err(path, code, msg);
        }
    }

    /// Checks `lo ≤ v ≤ hi`; returns whether the value is acceptable. `what` may have
    /// `$…$` math.
    fn range(&mut self, path: &str, v: f64, lo: f64, hi: f64, what: &str) -> bool {
        if !v.is_finite() {
            self.err_maybe_math(path, "non_finite", format!("{what} must be a finite number"));
            false
        } else if v < lo || v > hi {
            self.err_maybe_math(path, "out_of_range", format!("{what} must be between {} and {} (got {})", fmt(lo), fmt(hi), fmt(v)));
            false
        } else {
            true
        }
    }

    /// `what` may have `$…$` math.
    fn finite(&mut self, path: &str, v: f64, what: &str) -> bool {
        if v.is_finite() {
            true
        } else {
            self.err_maybe_math(path, "non_finite", format!("{what} must be a finite number"));
            false
        }
    }

    /// A positive length of at least `min`.
    fn dim(&mut self, path: &str, v: f64, min: f64, what: &str) -> bool {
        if !self.finite(path, v, what) {
            return false;
        }
        if v < min {
            self.err(path, "too_small", format!("{what} must be at least {} µm (got {} µm)", fmt(min), fmt(v)));
            return false;
        }
        true
    }
}

/// Short number formatting for messages.
pub fn fmt(v: f64) -> String {
    if v == 0.0 {
        return "0".into();
    }
    let a = v.abs();
    if (1e-3..1e5).contains(&a) {
        let s = format!("{:.4}", v);
        let s = s.trim_end_matches('0').trim_end_matches('.');
        s.to_string()
    } else {
        format!("{:.3e}", v)
    }
}

pub fn validate(scene: &Scene) -> Vec<Issue> {
    let mut c = Checker { issues: Vec::new() };

    if scene.version != SCHEMA_VERSION {
        c.err("version", "schema_version", format!("unsupported scene version {}", scene.version));
    }
    let lambda_ok = c.range("wavelength_um", scene.wavelength_um, 0.1, 100.0, "Wavelength");
    let nb_ok = c.range("background.n", scene.background.n, 1.0, 4.0, "Background index");
    if !(lambda_ok && nb_ok) {
        // Every other length check is relative to λ_b.
        return c.issues;
    }
    let lambda0 = scene.wavelength_um;
    let n_b = scene.background.n;
    let lambda_b = lambda0 / n_b;
    let min_feature = MIN_FEATURE_WL * lambda_b;

    let domain_ok = check_domain(&mut c, &scene.domain, lambda_b);
    let source_ok = check_sources(&mut c, scene, lambda_b, domain_ok);
    check_solver(&mut c, &scene.solver);

    let mut element_ok = vec![true; scene.elements.len()];
    for (i, e) in scene.elements.iter().enumerate() {
        let before = c.issues.iter().filter(|x| x.is_error()).count();
        check_element(&mut c, i, e, lambda0, lambda_b);
        element_ok[i] = c.issues.iter().filter(|x| x.is_error()).count() == before;
        if let Some(j) = scene.elements[..i].iter().position(|o| o.id == e.id) {
            c.err(
                format!("elements[{i}].id"),
                "duplicate_id",
                format!("element id \"{}\" is also used by elements[{j}]", e.id),
            );
        }
    }

    if !scene.elements.iter().any(|e| e.enabled) {
        c.warn("elements", "free_beam", "no enabled elements: the result is the incident field");
    }

    // Geometric checks only for enabled elements whose own parameters are valid.
    let bodies: Vec<Body> = scene
        .elements
        .iter()
        .enumerate()
        .filter(|(i, e)| e.enabled && element_ok[*i])
        .flat_map(|(i, e)| element_bodies(i, e, lambda0))
        .collect();

    if domain_ok {
        let interior = scene.domain.rect();
        let mut flagged = vec![false; scene.elements.len()];
        for b in &bodies {
            let i = b.element_index;
            if flagged[i] {
                continue;
            }
            if !interior.contains_rect(&b.bbox) {
                flagged[i] = true;
                c.err(
                    format!("elements[{i}]"),
                    "outside_domain",
                    format!("{} extends outside the simulation domain", element_label(&scene.elements[i], i)),
                );
            } else {
                let margin = (b.bbox.x_min - interior.x_min)
                    .min(interior.x_max - b.bbox.x_max)
                    .min(b.bbox.y_min - interior.y_min)
                    .min(interior.y_max - b.bbox.y_max);
                if margin < 0.25 * lambda_b {
                    flagged[i] = true;
                    c.warn_math(
                        format!("elements[{i}]"),
                        "near_pml",
                        format!(
                            r"{} is within 0.25 $\lambda$ of the domain edge; the absorbing layer may affect it",
                            tex::escape(&element_label(&scene.elements[i], i))
                        ),
                    );
                }
            }
        }
    }

    let mut reported = std::collections::HashSet::new();
    for (a_idx, a) in bodies.iter().enumerate() {
        for b in &bodies[a_idx + 1..] {
            if a.element_index == b.element_index || a.bbox.distance(&b.bbox) >= min_feature {
                continue;
            }
            let pair = (a.element_index, b.element_index);
            if reported.contains(&pair) {
                continue;
            }
            let gap = min_gap(a, b);
            if gap < min_feature {
                reported.insert(pair);
                let (i, j) = pair;
                let what = if gap == 0.0 { "overlap".to_string() } else { format!("are {} µm apart", fmt(gap)) };
                c.err_math(
                    format!("elements[{j}]"),
                    "overlap",
                    format!(
                        r"{} and {} {}; bodies must be at least {} µm (0.05 $\lambda$) apart",
                        tex::escape(&element_label(&scene.elements[i], i)),
                        tex::escape(&element_label(&scene.elements[j], j)),
                        what,
                        fmt(min_feature)
                    ),
                );
            }
        }
    }

    // An emitter inside a body, or very close to it, would make the scattered
    // field's sources (and the MoM traces) nearly singular.
    let min_emitter_gap = MIN_EMITTER_GAP_WL * lambda_b;
    for (i, s) in scene.sources.iter().enumerate() {
        let SourceKind::LineSource { x_um, y_um, .. } = s.kind else { continue };
        if !(s.enabled && source_ok[i]) {
            continue;
        }
        let p = Vec2::new(x_um, y_um);
        let near = bodies
            .iter()
            .filter(|b| b.bbox.distance_to(p) < min_emitter_gap)
            .map(|b| (b, b.signed_distance(p)))
            .min_by(|a, b| a.1.total_cmp(&b.1));
        if let Some((b, d)) = near {
            let label = element_label(&scene.elements[b.element_index], b.element_index);
            if d <= 0.0 {
                c.err(
                    format!("sources[{i}]"),
                    "emitter_inside",
                    format!("{} is inside {label}; an emitter must sit in the background", source_label(s, i)),
                );
            } else if d < min_emitter_gap {
                c.err_math(
                    format!("sources[{i}]"),
                    "emitter_too_close",
                    format!(
                        r"{} is {} µm from {}; an emitter must be at least {} µm (0.1 $\lambda$) from every element",
                        tex::escape(&source_label(s, i)),
                        fmt(d),
                        tex::escape(&label),
                        fmt(min_emitter_gap)
                    ),
                );
            }
        }
    }

    check_detectors(&mut c, scene, lambda_b, domain_ok, &source_ok);

    c.issues
}

/// Most detectors in a scene.
pub const MAX_DETECTORS: usize = 64;

fn detector_label(d: &Detector, i: usize) -> String {
    if d.name.is_empty() {
        format!("detector {} ({})", i + 1, d.shape.kind_name())
    } else {
        format!("\"{}\"", d.name)
    }
}

/// Distance from `p` to the segment a–b.
fn segment_distance(a: Vec2, b: Vec2, p: Vec2) -> f64 {
    let d = b - a;
    let len2 = d.dot(d);
    let t = if len2 > 0.0 { ((p - a).dot(d) / len2).clamp(0.0, 1.0) } else { 0.0 };
    p.dist(a + d * t)
}

/// Detector ids and sizes; an enabled detector must lie inside the interior,
/// where the solved field is. A detector close to an emitter is allowed but
/// warned about: the field there is dominated by the singular point, which
/// the grid resolves only roughly.
fn check_detectors(c: &mut Checker, scene: &Scene, lambda_b: f64, domain_ok: bool, source_ok: &[bool]) {
    if scene.detectors.len() > MAX_DETECTORS {
        c.err("detectors", "too_many", format!("at most {MAX_DETECTORS} detectors are allowed (got {})", scene.detectors.len()));
    }
    let emitters: Vec<Vec2> = scene
        .sources
        .iter()
        .zip(source_ok)
        .filter(|(s, ok)| s.enabled && **ok)
        .filter_map(|(s, _)| match s.kind {
            SourceKind::LineSource { x_um, y_um, .. } => Some(Vec2::new(x_um, y_um)),
            _ => None,
        })
        .collect();
    for (i, d) in scene.detectors.iter().enumerate() {
        let p = |field: &str| format!("detectors[{i}].shape.{field}");
        if d.id.is_empty() {
            c.err(format!("detectors[{i}].id"), "empty_id", "a detector needs an id");
        } else if let Some(j) = scene.detectors[..i].iter().position(|o| o.id == d.id) {
            c.err(
                format!("detectors[{i}].id"),
                "duplicate_id",
                format!("detector id \"{}\" is also used by detectors[{j}]", d.id),
            );
        }
        let before = c.issues.iter().filter(|x| x.is_error()).count();
        let mut finite = true;
        match d.shape {
            DetectorShape::Line { x1_um, y1_um, x2_um, y2_um } => {
                finite &= c.finite(&p("x1_um"), x1_um, "Start $x$");
                finite &= c.finite(&p("y1_um"), y1_um, "Start $y$");
                finite &= c.finite(&p("x2_um"), x2_um, "End $x$");
                finite &= c.finite(&p("y2_um"), y2_um, "End $y$");
                if finite && Vec2::new(x1_um, y1_um).dist(Vec2::new(x2_um, y2_um)) <= 0.0 {
                    c.err(p("x2_um"), "too_small", "a line detector needs two different end points");
                }
            }
            DetectorShape::Box { x_um, y_um, width_um, height_um } => {
                finite &= c.finite(&p("x_um"), x_um, "Centre $x$");
                finite &= c.finite(&p("y_um"), y_um, "Centre $y$");
                for (field, v, what) in [("width_um", width_um, "Width"), ("height_um", height_um, "Height")] {
                    if c.finite(&p(field), v, what) && v <= 0.0 {
                        c.err(p(field), "too_small", format!("{what} must be positive (got {} µm)", fmt(v)));
                    }
                }
            }
        }
        let valid = finite && c.issues.iter().filter(|x| x.is_error()).count() == before;
        if !(valid && d.enabled && domain_ok) {
            continue;
        }
        let interior = scene.domain.rect();
        let (inside, near_emitter) = match d.shape {
            DetectorShape::Line { x1_um, y1_um, x2_um, y2_um } => {
                let (a, b) = (Vec2::new(x1_um, y1_um), Vec2::new(x2_um, y2_um));
                (
                    interior.contains(a) && interior.contains(b),
                    emitters.iter().map(|&e| segment_distance(a, b, e)).fold(f64::INFINITY, f64::min),
                )
            }
            DetectorShape::Box { x_um, y_um, width_um, height_um } => {
                let r = crate::types::Rect::new(
                    x_um - 0.5 * width_um,
                    x_um + 0.5 * width_um,
                    y_um - 0.5 * height_um,
                    y_um + 0.5 * height_um,
                );
                (interior.contains_rect(&r), emitters.iter().map(|&e| r.distance_to(e)).fold(f64::INFINITY, f64::min))
            }
        };
        if !inside {
            c.err(
                format!("detectors[{i}]"),
                "outside_domain",
                format!("{} extends outside the simulation domain", detector_label(d, i)),
            );
        } else if near_emitter < 0.25 * lambda_b {
            c.warn_math(
                format!("detectors[{i}]"),
                "near_emitter",
                format!(
                    r"{} is within 0.25 $\lambda$ of an emitter, where the field is too sharply peaked for the grid to resolve; its readings are rough",
                    tex::escape(&detector_label(d, i))
                ),
            );
        }
    }
}

/// Smallest distance from a line source to any body, in background wavelengths.
pub const MIN_EMITTER_GAP_WL: f64 = 0.1;

fn source_label(s: &Source, i: usize) -> String {
    if s.name.is_empty() {
        let kind = match s.kind {
            SourceKind::PlaneWave { .. } => "plane wave",
            SourceKind::GaussianBeam { .. } => "Gaussian beam",
            SourceKind::LineSource { .. } => "emitter",
        };
        format!("source {} ({kind})", i + 1)
    } else {
        format!("\"{}\"", s.name)
    }
}

fn element_label(e: &Element, i: usize) -> String {
    if e.name.is_empty() {
        format!("element {} ({})", i + 1, e.shape.kind_name())
    } else {
        format!("\"{}\"", e.name)
    }
}

/// Checks the source list; returns, per source, whether its own parameters
/// are valid.
fn check_sources(c: &mut Checker, scene: &Scene, lambda_b: f64, domain_ok: bool) -> Vec<bool> {
    if scene.sources.is_empty() {
        c.err("sources", "no_source", "the scene needs at least one source");
    } else if !scene.sources.iter().any(|s| s.enabled) {
        c.err("sources", "no_enabled_source", "at least one source must be enabled");
    }
    let mut ok = Vec::with_capacity(scene.sources.len());
    for (i, s) in scene.sources.iter().enumerate() {
        let before = c.issues.iter().filter(|x| x.is_error()).count();
        check_source(c, i, s, lambda_b);
        if s.id.is_empty() {
            c.err(format!("sources[{i}].id"), "empty_id", "a source needs an id");
        } else if let Some(j) = scene.sources[..i].iter().position(|o| o.id == s.id) {
            c.err(
                format!("sources[{i}].id"),
                "duplicate_id",
                format!("source id \"{}\" is also used by sources[{j}]", s.id),
            );
        }
        let valid = c.issues.iter().filter(|x| x.is_error()).count() == before;
        if valid && domain_ok && s.enabled {
            check_source_placement(c, i, s, scene, lambda_b);
        }
        ok.push(valid);
    }
    ok
}

fn check_source(c: &mut Checker, i: usize, s: &Source, lambda_b: f64) {
    let p = |field: &str| format!("sources[{i}].{field}");
    match s.kind {
        SourceKind::PlaneWave { angle_deg, amplitude, phase_deg } => {
            c.finite(&p("angle_deg"), angle_deg, "Angle");
            c.finite(&p("phase_deg"), phase_deg, "Phase");
            check_amplitude(c, &p("amplitude"), amplitude);
        }
        SourceKind::GaussianBeam { waist_um, waist_x_um, waist_y_um, angle_deg, amplitude, phase_deg } => {
            c.finite(&p("waist_x_um"), waist_x_um, "Waist $x$");
            c.finite(&p("waist_y_um"), waist_y_um, "Waist $y$");
            c.finite(&p("angle_deg"), angle_deg, "Angle");
            c.finite(&p("phase_deg"), phase_deg, "Phase");
            check_amplitude(c, &p("amplitude"), amplitude);
            if c.finite(&p("waist_um"), waist_um, "Waist") {
                if waist_um < 0.1 * lambda_b {
                    c.err_math(
                        p("waist_um"),
                        "waist_too_small",
                        format!(r"waist must be at least 0.1 $\lambda$ = {} µm", fmt(0.1 * lambda_b)),
                    );
                } else if waist_um < 0.5 * lambda_b {
                    c.warn_math(
                        p("waist_um"),
                        "subwavelength_waist",
                        r"realised focus is wider than $w_0$ (waist below $\lambda/2$ in the background)",
                    );
                }
            }
        }
        SourceKind::LineSource { x_um, y_um, amplitude, phase_deg } => {
            c.finite(&p("x_um"), x_um, "Position $x$");
            c.finite(&p("y_um"), y_um, "Position $y$");
            c.finite(&p("phase_deg"), phase_deg, "Phase");
            check_amplitude(c, &p("amplitude"), amplitude);
        }
    }
}

/// Largest accepted source amplitude. FDTD keeps its fields in f32, which
/// overflows near 3.4e38; this leaves room for field enhancement.
pub const MAX_AMPLITUDE: f64 = 1e30;

fn check_amplitude(c: &mut Checker, path: &str, a: f64) {
    if c.finite(path, a, "Amplitude") {
        if a <= 0.0 {
            c.err(path, "out_of_range", "amplitude must be positive");
        } else if a > MAX_AMPLITUDE {
            c.err(path, "out_of_range", "amplitude must be at most 1e30");
        }
    }
}

/// Where an enabled source sits relative to the domain. A Gaussian beam is a
/// sum of plane waves, and the number it needs grows with the distance from
/// the waist to the far corner of the domain (PML included); a waist too far
/// away is refused rather than built for minutes. An emitter must be inside
/// the interior.
fn check_source_placement(c: &mut Checker, i: usize, s: &Source, scene: &Scene, lambda_b: f64) {
    match s.kind {
        SourceKind::GaussianBeam { waist_um, waist_x_um, waist_y_um, .. } => {
            let outer = scene.domain.rect().expand(scene.domain.pml_wl * lambda_b);
            let waist = Vec2::new(waist_x_um, waist_y_um);
            let r_max = outer.corners().iter().map(|p| p.dist(waist)).fold(0.0, f64::max);
            let k = 2.0 * std::f64::consts::PI / lambda_b;
            if gaussian::nodes_needed(k, waist_um, r_max) > gaussian::MAX_COMPONENTS as f64 {
                c.err(
                    format!("sources[{i}].waist_x_um"),
                    "waist_too_far",
                    format!(
                        "the waist is {:.0} µm from the far corner of the domain; a beam with a {} µm waist can only be built out to {:.0} µm",
                        r_max,
                        fmt(waist_um),
                        gaussian::max_reach(k, waist_um).floor()
                    ),
                );
            }
        }
        SourceKind::LineSource { x_um, y_um, .. } => {
            if !scene.domain.rect().contains(Vec2::new(x_um, y_um)) {
                c.err(
                    format!("sources[{i}]"),
                    "outside_domain",
                    format!("{} is outside the simulation domain", source_label(s, i)),
                );
            }
        }
        SourceKind::PlaneWave { .. } => {}
    }
}

fn check_domain(c: &mut Checker, d: &Domain, lambda_b: f64) -> bool {
    let mut ok = true;
    for (path, v) in [
        ("domain.x_min_um", d.x_min_um),
        ("domain.x_max_um", d.x_max_um),
        ("domain.y_min_um", d.y_min_um),
        ("domain.y_max_um", d.y_max_um),
    ] {
        ok &= c.finite(path, v, "Domain bound");
    }
    ok &= c.range("domain.pml_wl", d.pml_wl, 0.5, 4.0, r"PML thickness (in $\lambda$)");
    if !ok {
        return false;
    }
    let (w, h) = (d.x_max_um - d.x_min_um, d.y_max_um - d.y_min_um);
    for (path, size, what) in [("domain.x_max_um", w, "width"), ("domain.y_max_um", h, "height")] {
        if size < 2.0 * lambda_b {
            c.err_math(path, "domain_size", format!(r"domain {what} must be at least 2 $\lambda$ = {} µm", fmt(2.0 * lambda_b)));
            ok = false;
        } else if size > 400.0 * lambda_b {
            c.err_math(path, "domain_size", format!(r"domain {what} must be at most 400 $\lambda$ = {} µm", fmt(400.0 * lambda_b)));
            ok = false;
        }
    }
    ok
}

fn check_ppw(c: &mut Checker, path: &str, v: Option<f64>) {
    if let Some(v) = v {
        c.range(path, v, 4.0, 80.0, "Points per wavelength");
    }
}

fn check_solver(c: &mut Checker, s: &SolverSettings) {
    let f = &s.fdtd;
    check_ppw(c, "solver.fdtd.preview_ppw", f.preview_ppw);
    check_ppw(c, "solver.fdtd.final_ppw", f.final_ppw);
    c.range("solver.fdtd.courant", f.courant, 0.1, 0.65, "Courant number");
    if let Some(p) = f.max_periods {
        if p == 0 {
            c.err("solver.fdtd.max_periods", "out_of_range", "max periods must be at least 1");
        }
    }
    if let Some(t) = f.steady_tol {
        if !(t.is_finite() && t > 0.0 && t < 1.0) {
            c.err("solver.fdtd.steady_tol", "out_of_range", "steady-state tolerance must be in (0, 1)");
        }
    }
    let m = &s.fem;
    check_ppw(c, "solver.fem.preview_ppw", m.preview_ppw);
    check_ppw(c, "solver.fem.final_ppw", m.final_ppw);
    if !(m.order == 2 || m.order == 3) {
        c.err("solver.fem.order", "out_of_range", "FEM order must be 2 or 3");
    }
    c.range("solver.fem.pml_reflection", m.pml_reflection, 1e-12, 1e-2, "PML reflection");
    let b = &s.mom;
    check_ppw(c, "solver.mom.preview_ppw", b.preview_ppw);
    check_ppw(c, "solver.mom.final_ppw", b.final_ppw);
    if c.finite("solver.mom.cfie_beta_scale", b.cfie_beta_scale, r"CFIE $\beta$ scale")
        && !(b.cfie_beta_scale > 0.0 && b.cfie_beta_scale <= 10.0)
    {
        c.err_math("solver.mom.cfie_beta_scale", "out_of_range", r"CFIE $\beta$ scale must be in (0, 10]");
    }
    check_ppw(c, "solver.output.preview_ppw", s.output.preview_ppw);
    check_ppw(c, "solver.output.final_ppw", s.output.final_ppw);
    if let Some(mb) = s.memory_limit_mb {
        if !(mb.is_finite() && mb > 0.0) {
            c.err("solver.memory_limit_mb", "out_of_range", "memory limit must be positive");
        }
    }
}

/// Largest pole energy (eV) and Lorentz strength accepted; far beyond any
/// optical material, they only keep the arithmetic finite.
const MAX_POLE_EV: f64 = 1000.0;
const MAX_POLE_STRENGTH: f64 = 1e4;
/// Largest |n| a dispersive material may reach at the scene wavelength. The
/// solvers resolve λ0/|n|, so beyond this a body is better modelled as PEC.
pub const MAX_DISPERSIVE_INDEX: f64 = 30.0;

fn check_dispersive(c: &mut Checker, i: usize, eps_inf: f64, poles: &[Pole], lambda0: f64) {
    let p = |field: &str| format!("elements[{i}].material.{field}");
    let mut ok = c.range(&p("eps_inf"), eps_inf, 1.0, 100.0, r"$\varepsilon_\infty$");
    if poles.len() > MAX_POLES {
        c.err(p("poles"), "too_many_poles", format!("a material may have at most {MAX_POLES} poles (got {})", poles.len()));
        return;
    }
    for (k, pole) in poles.iter().enumerate() {
        let q = |field: &str| format!("elements[{i}].material.poles[{k}].{field}");
        match *pole {
            Pole::Drude { plasma_ev, gamma_ev } => {
                ok &= c.range(&q("plasma_ev"), plasma_ev, 0.0, MAX_POLE_EV, r"Plasma energy $\omega_p$ (eV)");
                ok &= c.range(&q("gamma_ev"), gamma_ev, 0.0, MAX_POLE_EV, "Damping (eV)");
            }
            Pole::Lorentz { strength, resonance_ev, gamma_ev } => {
                ok &= c.range(&q("strength"), strength, 0.0, MAX_POLE_STRENGTH, "Strength");
                ok &= c.range(&q("gamma_ev"), gamma_ev, 0.0, MAX_POLE_EV, "Damping (eV)");
                if c.range(&q("resonance_ev"), resonance_ev, 0.0, MAX_POLE_EV, r"Resonance $\omega_0$ (eV)") {
                    if resonance_ev <= 0.0 {
                        c.err_math(q("resonance_ev"), "out_of_range", r"resonance $\omega_0$ must be positive");
                        ok = false;
                    }
                } else {
                    ok = false;
                }
            }
        }
    }
    if !ok {
        return;
    }
    let eps = super::materials::dispersive_eps(eps_inf, poles, lambda0);
    let n = super::materials::index_from_eps(eps);
    if !(eps.re.is_finite() && eps.im.is_finite()) || eps.norm() > 1e12 {
        c.err_math(
            p("poles"),
            "material_resonance",
            format!(r"$\varepsilon$ is infinite at {} µm: a lossless resonance sits on the wavelength", fmt(lambda0)),
        );
    } else if eps.im > 1e-12 * eps.norm() {
        // Every pole with γ ≥ 0 and Δε ≥ 0 is passive; kept as a guard.
        c.err_math(p("poles"), "material_gain", r"the material has gain ($\varepsilon'' < 0$) at the scene wavelength");
    } else if n.norm() > MAX_DISPERSIVE_INDEX {
        c.err(
            p("poles"),
            "material_index",
            format!(
                "|n| = {} at {} µm is above {}; model this body as PEC",
                fmt(n.norm()),
                fmt(lambda0),
                fmt(MAX_DISPERSIVE_INDEX)
            ),
        );
    }
}

fn check_element(c: &mut Checker, i: usize, e: &Element, lambda0: f64, lambda_b: f64) {
    let p = |field: &str| format!("elements[{i}].{field}");
    let s = |field: &str| format!("elements[{i}].shape.{field}");
    c.finite(&p("x_um"), e.x_um, "Position $x$");
    c.finite(&p("y_um"), e.y_um, "Position $y$");
    c.finite(&p("rotation_deg"), e.rotation_deg, "Rotation");

    let pec = matches!(e.material, Material::Pec);
    if let Material::Dielectric { n, k } = e.material {
        let n_ok = c.range(&p("material.n"), n, 1.0, 6.0, "Refractive index $n$");
        let k_ok = c.range(&p("material.k"), k, 0.0, 1.0, "Extinction $k$");
        if n_ok && k_ok && n * n - k * k < 1.0 {
            c.err_math(
                p("material.k"),
                "material_index",
                r"$n^2 - k^2$ must be at least 1 (metals with $\varepsilon' < 1$ are not supported; use PEC)",
            );
        }
    }
    if let Material::Dispersive { eps_inf, ref poles, .. } = e.material {
        check_dispersive(c, i, eps_inf, poles, lambda0);
    }
    if matches!(e.shape, Shape::Mirror { .. } | Shape::Slits { .. }) && !pec {
        c.err(p("material"), "pec_required", format!("a {} must be PEC", e.shape.kind_name()));
    }

    let feat = MIN_FEATURE_WL * lambda_b;
    // PEC sheets must also be thick against the vacuum wavelength.
    let thick = if pec { (MIN_FEATURE_WL * lambda0).max(feat) } else { feat };

    match e.shape {
        Shape::Lens { r1_um, r2_um, center_thickness_um: t, aperture_um: d } => {
            let mut ok = c.dim(&s("center_thickness_um"), t, feat, "Centre thickness");
            ok &= c.dim(&s("aperture_um"), d, feat, "Aperture");
            for (field, r) in [("r1_um", r1_um), ("r2_um", r2_um)] {
                if let Some(r) = r {
                    if !c.finite(&s(field), r, "Radius") {
                        ok = false;
                    } else if ok && r.abs() <= 0.5 * d {
                        c.err(s(field), "lens_radius", format!("|R| must exceed half the aperture ({} µm)", fmt(0.5 * d)));
                        ok = false;
                    }
                }
            }
            if ok {
                let h = 0.5 * d;
                let sag = |y: f64| lens_surface_x(0.0, r2_um, y) - lens_surface_x(0.0, r1_um, y);
                let min_sag = (0..129)
                    .map(|k| -h + 2.0 * h * k as f64 / 128.0)
                    .map(sag)
                    .fold(f64::INFINITY, f64::min);
                if t + min_sag < feat {
                    c.err(
                        s("center_thickness_um"),
                        "lens_thickness",
                        format!(
                            "lens is thinner than {} µm somewhere; a centre thickness of at least {} µm fixes it",
                            fmt(feat),
                            fmt(feat - min_sag)
                        ),
                    );
                }
            }
        }
        Shape::Slab { thickness_um, height_um } => {
            c.dim(&s("thickness_um"), thickness_um, thick, "Thickness");
            c.dim(&s("height_um"), height_um, feat, "Height");
        }
        Shape::Waveguide { width_um, length_um } => {
            c.dim(&s("width_um"), width_um, thick, "Width");
            c.dim(&s("length_um"), length_um, feat, "Length");
        }
        Shape::Wedge { thick_um, thin_um, height_um } => {
            let a = c.dim(&s("thick_um"), thick_um, feat, "Thick side");
            let b = c.dim(&s("thin_um"), thin_um, thick, "Thin side");
            c.dim(&s("height_um"), height_um, feat, "Height");
            if a && b && thin_um >= thick_um {
                c.err(s("thin_um"), "wedge_thin", "the thin side must be thinner than the thick side");
            }
        }
        Shape::Prism { base_um, apex_deg } => {
            c.dim(&s("base_um"), base_um, feat, "Base");
            c.range(&s("apex_deg"), apex_deg, 5.0, 170.0, "Apex angle");
        }
        Shape::Mirror { aperture_um, thickness_um, radius_um } => {
            let ok = c.dim(&s("aperture_um"), aperture_um, feat, "Aperture");
            c.dim(&s("thickness_um"), thickness_um, thick, "Thickness");
            if let Some(r) = radius_um {
                if c.finite(&s("radius_um"), r, "Radius") && ok && r.abs() <= 0.5 * aperture_um {
                    c.err(
                        s("radius_um"),
                        "mirror_radius",
                        format!("|R| must exceed half the aperture ({} µm)", fmt(0.5 * aperture_um)),
                    );
                }
            }
        }
        Shape::Slits { count, slit_width_um: w, pitch_um, screen_height_um, thickness_um } => {
            let n_ok = if !(1..=MAX_SLITS).contains(&count) {
                c.err(s("count"), "out_of_range", format!("slit count must be between 1 and {MAX_SLITS}"));
                false
            } else {
                true
            };
            let w_ok = c.dim(&s("slit_width_um"), w, feat, "Slit width");
            let h_ok = c.dim(&s("screen_height_um"), screen_height_um, feat, "Screen height");
            c.dim(&s("thickness_um"), thickness_um, thick, "Thickness");
            let p_ok = c.finite(&s("pitch_um"), pitch_um, "Pitch");
            if n_ok && w_ok && p_ok {
                if count > 1 && pitch_um <= w + feat {
                    c.err(
                        s("pitch_um"),
                        "slit_pitch",
                        format!("pitch must exceed the slit width by at least {} µm", fmt(feat)),
                    );
                } else if h_ok {
                    let open = 0.5 * ((count as f64 - 1.0) * pitch_um + w);
                    if 0.5 * screen_height_um - open < feat {
                        c.err(
                            s("screen_height_um"),
                            "slit_screen",
                            format!(
                                "the screen must extend at least {} µm beyond the outer slits (height ≥ {} µm)",
                                fmt(feat),
                                fmt(2.0 * (open + feat))
                            ),
                        );
                    }
                }
            }
        }
        Shape::Grating { period_um, fill_factor, depth_um, count, substrate_um } => {
            let p_ok = c.dim(&s("period_um"), period_um, feat, "Period");
            c.dim(&s("depth_um"), depth_um, thick, "Depth");
            if !(1..=MAX_GRATING_BARS).contains(&count) {
                c.err(s("count"), "out_of_range", format!("bar count must be between 1 and {MAX_GRATING_BARS}"));
            }
            let f_ok = c.finite(&s("fill_factor"), fill_factor, "Fill factor");
            if f_ok && !(fill_factor > 0.0 && fill_factor < 1.0) {
                c.err(s("fill_factor"), "out_of_range", "fill factor must be between 0 and 1 (exclusive)");
            } else if f_ok && p_ok {
                let bar = fill_factor * period_um;
                let gap = period_um - bar;
                if bar < thick || gap < feat {
                    c.err(
                        s("fill_factor"),
                        "grating_bar",
                        format!(
                            "bars ({} µm) and gaps ({} µm) must be at least {} µm",
                            fmt(bar),
                            fmt(gap),
                            fmt(feat)
                        ),
                    );
                }
            }
            if c.finite(&s("substrate_um"), substrate_um, "Substrate") && substrate_um != 0.0 {
                c.dim(&s("substrate_um"), substrate_um, thick, "Substrate thickness");
            }
        }
        Shape::Cylinder { radius_um } => {
            c.dim(&s("radius_um"), radius_um, feat.max(0.5 * thick), "Radius");
        }
        Shape::Polygon { ref vertices_um } => {
            if vertices_um.len() < 3 {
                c.err(s("vertices_um"), "polygon_vertices", "a polygon needs at least 3 vertices");
            } else if vertices_um.len() > MAX_POLYGON_VERTICES {
                c.err(
                    s("vertices_um"),
                    "polygon_vertices",
                    format!("a polygon may have at most {MAX_POLYGON_VERTICES} vertices (got {})", vertices_um.len()),
                );
            } else if vertices_um.iter().any(|v| !(v[0].is_finite() && v[1].is_finite())) {
                c.err(s("vertices_um"), "non_finite", "polygon vertices must be finite");
            } else {
                let v: Vec<Vec2> = vertices_um.iter().map(|p| Vec2::new(p[0], p[1])).collect();
                let bbox = crate::types::Rect::from_points(v.iter().copied());
                if signed_area(&v).abs() <= 1e-9 * bbox.diag().powi(2).max(f64::MIN_POSITIVE) {
                    c.err(s("vertices_um"), "polygon_area", "the polygon has zero area");
                } else if polygon_self_intersects(&v) {
                    c.err(s("vertices_um"), "polygon_self_intersecting", "the polygon crosses itself");
                } else {
                    let width = polygon_min_width(&v);
                    if width < thick {
                        c.err(
                            s("vertices_um"),
                            "polygon_thin",
                            format!(
                                "the polygon is {} µm across at its thinnest; it must be at least {} µm",
                                fmt(width),
                                fmt(thick)
                            ),
                        );
                    }
                }
            }
        }
    }
}
