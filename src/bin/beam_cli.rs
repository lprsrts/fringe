//! `beam-cli`: solve Beam scenes, render them to PNG and run the validation cases.
//!
//! Argument parsing is hand-rolled to keep the crate free of a CLI dependency.

use std::io::{IsTerminal, Read, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use beam_core::analytic::cases::{self, Status};
use beam_core::analytic::metrics::{focal_peak, rel_l2, resample};
use beam_core::check::check;
use beam_core::job::Job;
use beam_core::render::view::{NormMode, Normalization, PartName, ViewRect};
use beam_core::render::{export_png_file, render_rgba, write_npy_c128, Colormap, Quantity, View};
use beam_core::scene::validate::fmt;
use beam_core::scene::{examples, parse_scene, to_json, Scene, Severity};
use beam_core::solver::context::{STATE_CANCELLED, STATE_RUNNING};
use beam_core::solver::{FieldGrid, Method, Part, Quality, SolveError};
use beam_core::types::C64;

const HELP: &str = "\
beam-cli: full-wave 2D (Ez) optics scenes

Usage:
  beam-cli example [NAME] [-o FILE]       print an example scene (no NAME: list them)
  beam-cli check SCENE [--json]           validation issues, cost estimates and derived values
  beam-cli solve SCENE -o OUT.png [options]
  beam-cli frames SCENE -o DIR [--frames N] [options]
                                          one solve, N images over phase 0..360°
  beam-cli validate [--case ID[,ID…]|all] [--solver fdtd,fem,mom|all]
                    [--quality preview|final] [--slow] [--json]
  beam-cli compare SCENE [--solvers fem,mom,fdtd] [--quality final] [--json]
                                          solve with each solver; time, peak on
                                          the source axis past the last element,
                                          and the difference between each pair
  beam-cli --help | --version

SCENE is a scene JSON file, or - for standard input.

Solve options:
  --solver fdtd|fem|mom        override the scene's solver
  --quality preview|final      default final
  --ppw N                      points per wavelength for the chosen solver and quality
  --quantity intensity|magnitude|real|phase
  --part total|scattered|incident
  --colormap NAME              default per quantity: inferno, rdbu (real), twilight (phase)
  --gamma G
  --norm auto|incident|VALUE   colour scale
  --log-db DB                  logarithmic scale over DB decibels (intensity, magnitude)
  --phase-deg D                phase of the snapshot Re(E e^{jφ})
  --width W, --height H        one sets the other from the domain aspect; neither
                               gives a 1920 px long edge
  --outlines                   draw element outlines
  --npy FILE                   also write the chosen part as complex128 .npy
  --stats FILE                 write the field info as JSON
  --quiet                      no progress or summary

Exit codes: 0 ok, 1 check or validation failure, 2 usage, 3 solve or file error,
130 cancelled.
";

enum Fail {
    Usage(String),
    Check,
    /// A solve that failed, or a file that could not be read or written.
    Solve(String),
    Cancelled,
}

type Result<T> = std::result::Result<T, Fail>;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match run(args) {
        Ok(()) => ExitCode::SUCCESS,
        Err(Fail::Usage(m)) => {
            eprintln!("beam-cli: {m}");
            eprintln!("Run beam-cli --help for usage.");
            ExitCode::from(2)
        }
        Err(Fail::Check) => ExitCode::from(1),
        Err(Fail::Solve(m)) => {
            eprintln!("beam-cli: {m}");
            ExitCode::from(3)
        }
        Err(Fail::Cancelled) => {
            eprintln!("beam-cli: cancelled");
            ExitCode::from(130)
        }
    }
}

fn run(args: Vec<String>) -> Result<()> {
    let Some((cmd, rest)) = args.split_first() else {
        print!("{HELP}");
        return Ok(());
    };
    let mut a = Args::new(rest);
    match cmd.as_str() {
        "--help" | "-h" | "help" => {
            print!("{HELP}");
            Ok(())
        }
        "--version" | "-V" => {
            println!("beam-cli {}", env!("CARGO_PKG_VERSION"));
            Ok(())
        }
        "example" => cmd_example(&mut a),
        "check" => cmd_check(&mut a),
        "solve" => cmd_solve(&mut a),
        "frames" => cmd_frames(&mut a),
        "validate" => cmd_validate(&mut a),
        "compare" => cmd_compare(&mut a),
        "info" | "export" => Err(Fail::Usage(
            "removed in v2; use `beam-cli example lens | beam-cli solve - -o out.png`".into(),
        )),
        other => Err(Fail::Usage(format!("unknown command '{other}'"))),
    }
}

/// Flags and positional arguments, consumed as they are read so leftovers can
/// be reported.
struct Args {
    items: Vec<Option<String>>,
}

impl Args {
    fn new(args: &[String]) -> Self {
        Self { items: args.iter().cloned().map(Some).collect() }
    }

    fn flag(&mut self, names: &[&str]) -> bool {
        let mut found = false;
        for it in self.items.iter_mut() {
            if it.as_deref().is_some_and(|s| names.contains(&s)) {
                *it = None;
                found = true;
            }
        }
        found
    }

    fn value(&mut self, names: &[&str]) -> Result<Option<String>> {
        let mut out = None;
        let mut i = 0;
        while i < self.items.len() {
            if self.items[i].as_deref().is_some_and(|s| names.contains(&s)) {
                let name = self.items[i].take().unwrap();
                let v = self.items.get_mut(i + 1).and_then(Option::take);
                match v {
                    Some(v) => out = Some(v),
                    None => return Err(Fail::Usage(format!("{name} needs a value"))),
                }
                i += 1;
            }
            i += 1;
        }
        Ok(out)
    }

    fn parsed<T: std::str::FromStr>(&mut self, names: &[&str]) -> Result<Option<T>> {
        match self.value(names)? {
            None => Ok(None),
            Some(v) => v.parse().map(Some).map_err(|_| Fail::Usage(format!("invalid value for {}: {v}", names[0]))),
        }
    }

    /// The first remaining argument that is not a flag. Read the value flags
    /// first: until then their values are still in the list.
    fn positional(&mut self) -> Option<String> {
        let i = self.items.iter().position(|s| s.as_deref().is_some_and(|s| s == "-" || !s.starts_with('-')))?;
        self.items[i].take()
    }

    fn finish(&self) -> Result<()> {
        match self.items.iter().flatten().next() {
            Some(extra) => Err(Fail::Usage(format!("unexpected argument '{extra}'"))),
            None => Ok(()),
        }
    }
}

fn read_scene(src: &str) -> Result<Scene> {
    let text = if src == "-" {
        let mut s = String::new();
        std::io::stdin().read_to_string(&mut s).map_err(|e| Fail::Solve(format!("reading stdin: {e}")))?;
        s
    } else {
        std::fs::read_to_string(src).map_err(|e| Fail::Solve(format!("reading {src}: {e}")))?
    };
    parse_scene(&text).map_err(|e| {
        eprintln!("beam-cli: {}: {}", if src == "-" { "stdin" } else { src }, e.message);
        Fail::Check
    })
}

fn cmd_example(a: &mut Args) -> Result<()> {
    let out = a.value(&["-o", "--output"])?;
    let name = a.positional();
    a.finish()?;
    let Some(name) = name else {
        for e in examples::EXAMPLES.iter() {
            println!("{:<16} {:<5} {}", e.name, e.method.label(), e.title);
        }
        return Ok(());
    };
    let scene = examples::example(&name).ok_or_else(|| Fail::Usage(format!("no example named '{name}'")))?;
    let json = to_json(&scene) + "\n";
    match out {
        Some(path) => std::fs::write(&path, json).map_err(|e| Fail::Solve(format!("writing {path}: {e}"))),
        None => {
            print!("{json}");
            Ok(())
        }
    }
}

fn cmd_check(a: &mut Args) -> Result<()> {
    let as_json = a.flag(&["--json"]);
    let src = a.positional().ok_or_else(|| Fail::Usage("check needs a SCENE".into()))?;
    a.finish()?;
    let scene = read_scene(&src)?;
    let report = check(&scene);
    if as_json {
        println!("{}", serde_json::to_string_pretty(&report).unwrap_or_default());
    } else {
        if report.issues.is_empty() {
            println!("No issues.");
        }
        for i in &report.issues {
            let sev = match i.severity {
                Severity::Error => "error",
                Severity::Warning => "warning",
            };
            let q = i.quality.map(|q| format!(" ({})", q.name())).unwrap_or_default();
            let path = if i.path.is_empty() { String::new() } else { format!("{}: ", i.path) };
            println!("{sev}{q}: {path}{} [{}]", i.message, i.code);
        }
        if let Some(est) = &report.estimates {
            for (label, e) in [("Preview", &est.preview), ("Final", &est.final_)] {
                if let Some(e) = e {
                    let time = if e.seconds < 0.05 { "under 0.1 s".to_string() } else { format!("about {:.1} s", e.seconds) };
                    println!(
                        "{label}: {} at {}/λ, {}, {time} and {:.0} MB",
                        e.method.label(),
                        e.ppw,
                        e.detail,
                        e.memory_mb
                    );
                }
            }
        }
        for line in derived_lines(&report.derived) {
            println!("{line}");
        }
    }
    if report.issues.iter().any(|i| i.severity == Severity::Error) {
        return Err(Fail::Check);
    }
    Ok(())
}

/// The derived values of a check report as labelled lines.
fn derived_lines(d: &serde_json::Value) -> Vec<String> {
    let um = |v: &serde_json::Value| v.as_f64().map(|x| format!("{} µm", fmt(x)));
    let deg = |v: &serde_json::Value| v.as_f64().map(|x| format!("{x:.2}°"));
    let mut out = Vec::new();
    if let (Some(b), Some(m)) = (d["lambda_b_um"].as_f64(), d["lambda_min_um"].as_f64()) {
        let mut line = format!("Wavelength: {} µm in the background", fmt(b));
        if m < b {
            line += &format!(", {} µm in the densest element", fmt(m));
        }
        out.push(line);
    }
    let src = &d["source"];
    if let (Some(z), Some(t)) = (um(&src["rayleigh_range_um"]), deg(&src["divergence_deg"])) {
        out.push(format!("Source: Rayleigh range {z}, divergence half-angle {t} (paraxial)"));
    }
    for e in d["elements"].as_array().into_iter().flatten() {
        let id = e["id"].as_str().unwrap_or("?");
        let mut parts = Vec::new();
        if let Some(l) = e.get("lens") {
            match (um(&l["paraxial_focal_um"]), um(&l["back_focal_um"])) {
                (Some(f), Some(b)) => parts.push(format!("paraxial focal length {f}, paraxial back focal length {b}")),
                _ => parts.push("no paraxial focus (afocal)".into()),
            }
            if let Some([x, y]) = l["paraxial_focus_um"].as_array().map(|a| [a[0].as_f64(), a[1].as_f64()]) {
                if let (Some(x), Some(y)) = (x, y) {
                    parts.push(format!("paraxial focus at ({}, {}) µm", fmt(x), fmt(y)));
                }
            }
            if let Some(t) = um(&l["edge_thickness_um"]) {
                parts.push(format!("edge thickness {t}"));
            }
        }
        if let Some(m) = e.get("mirror") {
            parts.push(match um(&m["focal_um"]) {
                Some(f) => format!("paraxial focal length {f}"),
                None => "flat".into(),
            });
        }
        if let Some(g) = e.get("grating") {
            let orders: Vec<String> = g["orders"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|o| Some(format!("{} at {}", o["m"].as_i64()?, deg(&o["angle_deg"])?)))
                .collect();
            parts.push(format!("propagating orders {}", orders.join(", ")));
        }
        if let Some(sl) = e.get("slits") {
            if let Some(a) = deg(&sl["single_slit_null_deg"]) {
                parts.push(format!("first single-slit null at {a}"));
            }
            if let Some(a) = deg(&sl["fringe_spacing_deg"]) {
                parts.push(format!("fringe spacing {a}"));
            }
        }
        if let Some(c) = e.get("cylinder") {
            if let Some(x) = c["size_parameter"].as_f64() {
                parts.push(format!("size parameter k r = {x:.2}"));
            }
        }
        if let Some(w) = e.get("waveguide") {
            if let (Some(v), Some(n)) = (w["v_number"].as_f64(), w["guided_modes"].as_i64()) {
                parts.push(format!("V number {v:.2}, {n} guided modes"));
            }
        }
        if let Some(p) = e.get("prism") {
            parts.push(match deg(&p["min_deviation_deg"]) {
                Some(a) => format!("minimum deviation {a}"),
                None => "no minimum deviation (total internal reflection)".into(),
            });
        }
        if !parts.is_empty() {
            out.push(format!("{id}: {}", parts.join("; ")));
        }
    }
    out
}

/// Solve and display options shared by `solve` and `frames`.
struct SolveOpts {
    method: Option<Method>,
    quality: Quality,
    ppw: Option<f64>,
    width: Option<u32>,
    height: Option<u32>,
    view: View,
    quiet: bool,
}

impl SolveOpts {
    /// Applies the solver and resolution overrides to the scene.
    fn apply(&self, scene: &mut Scene) {
        if let Some(m) = self.method {
            scene.solver.method = m;
        }
        if let Some(ppw) = self.ppw {
            let s = &mut scene.solver;
            let slot = match (s.method, self.quality) {
                (Method::Fdtd, Quality::Preview) => &mut s.fdtd.preview_ppw,
                (Method::Fdtd, Quality::Final) => &mut s.fdtd.final_ppw,
                (Method::Fem, Quality::Preview) => &mut s.fem.preview_ppw,
                (Method::Fem, Quality::Final) => &mut s.fem.final_ppw,
                (Method::Mom, Quality::Preview) => &mut s.mom.preview_ppw,
                (Method::Mom, Quality::Final) => &mut s.mom.final_ppw,
            };
            *slot = Some(ppw);
        }
    }
}

fn solve_opts(a: &mut Args, default_quantity: Quantity) -> Result<SolveOpts> {
    let method = match a.value(&["--solver"])? {
        Some(m) => Some(Method::parse(&m).ok_or_else(|| Fail::Usage(format!("unknown solver '{m}'")))?),
        None => None,
    };
    let quality = match a.value(&["--quality"])? {
        Some(q) => Quality::parse(&q).ok_or_else(|| Fail::Usage(format!("unknown quality '{q}'")))?,
        None => Quality::Final,
    };
    let ppw = a.parsed::<f64>(&["--ppw"])?;
    let quantity = match a.value(&["--quantity"])? {
        Some(q) => Quantity::parse(&q).ok_or_else(|| Fail::Usage(format!("unknown quantity '{q}'")))?,
        None => default_quantity,
    };
    let part = match a.value(&["--part"])?.as_deref() {
        None | Some("total") => PartName::Total,
        Some("scattered") => PartName::Scattered,
        Some("incident") => PartName::Incident,
        Some(p) => return Err(Fail::Usage(format!("unknown part '{p}'"))),
    };
    let colormap = match a.value(&["--colormap"])? {
        Some(c) => c.parse::<Colormap>().map_err(Fail::Usage)?,
        None => quantity.default_colormap(),
    };
    let normalization = match a.value(&["--norm"])?.as_deref() {
        None | Some("auto") => Normalization::default(),
        Some("incident") => Normalization { mode: NormMode::Incident, value: 1.0 },
        Some(v) => Normalization {
            mode: NormMode::Fixed,
            value: v.parse().map_err(|_| Fail::Usage(format!("invalid --norm value '{v}'")))?,
        },
    };
    let view = View {
        quantity,
        part,
        phase_deg: a.parsed(&["--phase-deg"])?.unwrap_or(0.0),
        colormap: colormap.name().into(),
        gamma: a.parsed(&["--gamma"])?.unwrap_or(1.0),
        normalization,
        log_db: a.parsed(&["--log-db"])?,
        outlines: a.flag(&["--outlines"]),
        ..View::default()
    };
    let width = a.parsed::<u32>(&["--width"])?;
    let height = a.parsed::<u32>(&["--height"])?;
    for v in [width, height].into_iter().flatten() {
        if v == 0 || v > beam_core::render::MAX_DIMENSION {
            return Err(Fail::Usage(format!("image sizes must be 1–{}", beam_core::render::MAX_DIMENSION)));
        }
    }
    Ok(SolveOpts { method, quality, ppw, width, height, view, quiet: a.flag(&["--quiet", "-q"]) })
}

/// Pixel size and view rectangle: one dimension follows the other from
/// the domain aspect; with both, the domain is centred and grown to fit.
fn image_size(scene: &Scene, width: Option<u32>, height: Option<u32>) -> (u32, u32, Option<ViewRect>) {
    let d = &scene.domain;
    let (dw, dh) = (d.x_max_um - d.x_min_um, d.y_max_um - d.y_min_um);
    let aspect = dw / dh;
    let clamp = |v: f64| (v.round() as u32).clamp(1, beam_core::render::MAX_DIMENSION);
    match (width, height) {
        (Some(w), Some(h)) => {
            let pix = w as f64 / h as f64;
            let (vw, vh) = if pix > aspect { (dh * pix, dh) } else { (dw, dw / pix) };
            let (cx, cy) = (0.5 * (d.x_min_um + d.x_max_um), 0.5 * (d.y_min_um + d.y_max_um));
            let rect = ViewRect {
                x_min_um: cx - 0.5 * vw,
                x_max_um: cx + 0.5 * vw,
                y_min_um: cy - 0.5 * vh,
                y_max_um: cy + 0.5 * vh,
            };
            (w, h, Some(rect))
        }
        (Some(w), None) => (w, clamp(w as f64 / aspect), None),
        (None, Some(h)) => (clamp(h as f64 * aspect), h, None),
        (None, None) if aspect >= 1.0 => (1920, clamp(1920.0 / aspect), None),
        (None, None) => (clamp(1920.0 * aspect), 1920, None),
    }
}

fn cancel_flag() -> &'static Arc<AtomicBool> {
    static FLAG: OnceLock<Arc<AtomicBool>> = OnceLock::new();
    FLAG.get_or_init(|| {
        let flag = Arc::new(AtomicBool::new(false));
        let f = flag.clone();
        let _ = ctrlc::set_handler(move || f.store(true, Ordering::SeqCst));
        flag
    })
}

const STAGES: [&str; 6] = ["setup", "geometry", "assembly", "solve", "sampling", "done"];

/// Runs a solve on a job thread, showing progress on a terminal and cancelling
/// on Ctrl-C.
fn solve_scene(scene: &Scene, quality: Quality, quiet: bool) -> Result<Arc<FieldGrid>> {
    let cancel = cancel_flag();
    let job = Job::spawn(scene.clone(), quality);
    let tty = !quiet && std::io::stderr().is_terminal();
    let mut cancelled = false;
    loop {
        let p = job.poll();
        if p.state != STATE_RUNNING {
            break;
        }
        if cancel.load(Ordering::SeqCst) && !cancelled {
            job.cancel();
            cancelled = true;
        }
        if tty {
            let stage = STAGES.get(p.stage as usize).copied().unwrap_or("");
            eprint!("\r{:<9} {:>3.0}%  {:.1} s   ", stage, 100.0 * p.fraction, p.elapsed_s);
            let _ = std::io::stderr().flush();
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    if tty {
        eprint!("\r{:40}\r", "");
    }
    if job.poll().state == STATE_CANCELLED {
        return Err(Fail::Cancelled);
    }
    match job.take_result() {
        Some(Ok(f)) => Ok(f),
        Some(Err(SolveError::Cancelled)) => Err(Fail::Cancelled),
        Some(Err(SolveError::Invalid(issues))) => {
            for i in &issues {
                eprintln!("error: {}: {} [{}]", i.path, i.message, i.code);
            }
            Err(Fail::Solve("the scene is invalid".into()))
        }
        Some(Err(e)) => Err(Fail::Solve(format!("{}: {e}", e.code()))),
        None => Err(Fail::Solve("the solve ended without a result".into())),
    }
}

fn write_png(field: &FieldGrid, view: &View, w: u32, h: u32, path: &Path) -> Result<()> {
    let mut rgba = vec![0u8; w as usize * h as usize * 4];
    render_rgba(field, view, w, h, &mut rgba).map_err(|e| Fail::Solve(e.to_string()))?;
    export_png_file(path, &rgba, w, h).map_err(|e| Fail::Solve(format!("writing {}: {e}", path.display())))
}

fn summary(field: &FieldGrid) -> String {
    let m = &field.meta;
    let mut s = format!(
        "{} {} at {}/λ: {}×{} grid, {} unknowns, {:.2} s",
        m.method.label(),
        m.quality.name(),
        m.ppw,
        field.grid.nx,
        field.grid.ny,
        m.solver.unknowns,
        m.wall_s
    );
    if let Some(p) = m.solver.periods {
        s += &format!(", {p:.0} periods");
    }
    if !m.solver.converged {
        s += ", not converged";
    }
    s
}

fn cmd_solve(a: &mut Args) -> Result<()> {
    let out = a.value(&["-o", "--output"])?.ok_or_else(|| Fail::Usage("solve needs -o OUT.png".into()))?;
    let npy = a.value(&["--npy"])?;
    let stats = a.value(&["--stats"])?;
    let scene_flag = a.value(&["--scene"])?;
    let mut opts = solve_opts(a, Quantity::Intensity)?;
    let src = scene_flag.or_else(|| a.positional()).ok_or_else(|| Fail::Usage("solve needs a SCENE".into()))?;
    a.finish()?;
    let mut scene = read_scene(&src)?;
    opts.apply(&mut scene);
    let (w, h, rect) = image_size(&scene, opts.width, opts.height);
    opts.view.view_um = rect;
    let field = solve_scene(&scene, opts.quality, opts.quiet)?;
    for warning in &field.meta.solver.warnings {
        if !opts.quiet {
            eprintln!("warning: {warning}");
        }
    }
    write_png(&field, &opts.view, w, h, Path::new(&out))?;
    if let Some(path) = npy {
        let part: Part = opts.view.part.into();
        write_npy_c128(&path, &field, part).map_err(|e| Fail::Solve(format!("writing {path}: {e}")))?;
    }
    if let Some(path) = stats {
        let text = serde_json::to_string_pretty(&field.info_json()).unwrap_or_default();
        std::fs::write(&path, text).map_err(|e| Fail::Solve(format!("writing {path}: {e}")))?;
    }
    if !opts.quiet {
        eprintln!("{}", summary(&field));
        eprintln!("Wrote {out} ({w}×{h})");
    }
    Ok(())
}

fn cmd_frames(a: &mut Args) -> Result<()> {
    let dir = a.value(&["-o", "--output"])?.ok_or_else(|| Fail::Usage("frames needs -o DIR".into()))?;
    let n: usize = a.parsed(&["--frames"])?.unwrap_or(24);
    if n == 0 {
        return Err(Fail::Usage("--frames must be at least 1".into()));
    }
    let mut opts = solve_opts(a, Quantity::Real)?;
    let src = a.positional().ok_or_else(|| Fail::Usage("frames needs a SCENE".into()))?;
    a.finish()?;
    let mut scene = read_scene(&src)?;
    opts.apply(&mut scene);
    let (w, h, rect) = image_size(&scene, opts.width, opts.height);
    opts.view.view_um = rect;
    let field = solve_scene(&scene, opts.quality, opts.quiet)?;
    let dir = PathBuf::from(dir);
    std::fs::create_dir_all(&dir).map_err(|e| Fail::Solve(format!("creating {}: {e}", dir.display())))?;
    let start = opts.view.phase_deg;
    for k in 0..n {
        let mut view = opts.view.clone();
        view.phase_deg = start + 360.0 * k as f64 / n as f64;
        write_png(&field, &view, w, h, &dir.join(format!("frame_{k:03}.png")))?;
    }
    if !opts.quiet {
        eprintln!("{}", summary(&field));
        eprintln!("Wrote {n} frames to {}", dir.display());
    }
    Ok(())
}

fn list_arg(v: Option<String>, all: &[&str]) -> Vec<String> {
    match v.as_deref() {
        None | Some("all") => all.iter().map(|s| s.to_string()).collect(),
        Some(s) => s.split(',').map(|x| x.trim().to_string()).filter(|x| !x.is_empty()).collect(),
    }
}

fn cmd_validate(a: &mut Args) -> Result<()> {
    let case_arg = a.value(&["--case"])?;
    let explicit_cases = case_arg.as_deref().is_some_and(|c| c != "all");
    let all_ids: Vec<&str> = cases::CASES.iter().map(|c| c.id).collect();
    let ids = list_arg(case_arg, &all_ids);
    let methods: Vec<Method> = list_arg(a.value(&["--solver"])?, &["fdtd", "fem", "mom"])
        .iter()
        .map(|m| Method::parse(m).ok_or_else(|| Fail::Usage(format!("unknown solver '{m}'"))))
        .collect::<Result<_>>()?;
    let quality = match a.value(&["--quality"])? {
        Some(q) => Quality::parse(&q).ok_or_else(|| Fail::Usage(format!("unknown quality '{q}'")))?,
        None => Quality::Final,
    };
    let slow = a.flag(&["--slow"]);
    let as_json = a.flag(&["--json"]);
    a.finish()?;
    for id in &ids {
        if cases::spec(id).is_none() {
            return Err(Fail::Usage(format!("unknown case '{id}'")));
        }
    }
    let mut results = Vec::new();
    if !as_json {
        println!("{:<20} | {:<6} | {:<7} | {:>9} | {:>8} | {:>9} | {:>9} | result", "case", "solver", "quality", "unknowns", "seconds", "error", "tolerance");
    }
    let mut failed = false;
    for id in &ids {
        let spec = cases::spec(id).unwrap();
        if spec.slow && !slow && !explicit_cases {
            continue;
        }
        for &m in &methods {
            if spec.bound(m).is_none() {
                continue;
            }
            let r = match cases::run_case(id, m, quality) {
                Ok(r) => r,
                Err(e) => {
                    eprintln!("{id} with {}: {e}", m.label());
                    failed = true;
                    continue;
                }
            };
            failed |= r.status == Status::Fail;
            if !as_json {
                let num = |v: Option<f64>| v.map_or("-".to_string(), |x| format!("{x:.2e}"));
                println!(
                    "{:<20} | {:<6} | {:<7} | {:>9} | {:>8.2} | {:>9} | {:>9} | {}{}",
                    r.id,
                    m.label(),
                    r.quality.name(),
                    r.unknowns,
                    r.seconds,
                    num(r.error),
                    num(r.tolerance),
                    r.status.label(),
                    if r.detail.is_empty() { String::new() } else { format!("  {}", r.detail) }
                );
            }
            results.push(r);
        }
    }
    if as_json {
        println!("{}", serde_json::to_string_pretty(&results).unwrap_or_default());
    }
    if failed {
        Err(Fail::Check)
    } else {
        Ok(())
    }
}

fn cmd_compare(a: &mut Args) -> Result<()> {
    let methods: Vec<Method> = list_arg(a.value(&["--solvers"])?, &["fem", "mom", "fdtd"])
        .iter()
        .map(|m| Method::parse(m).ok_or_else(|| Fail::Usage(format!("unknown solver '{m}'"))))
        .collect::<Result<_>>()?;
    let quality = match a.value(&["--quality"])? {
        Some(q) => Quality::parse(&q).ok_or_else(|| Fail::Usage(format!("unknown quality '{q}'")))?,
        None => Quality::Final,
    };
    let as_json = a.flag(&["--json"]);
    let src = a.positional().ok_or_else(|| Fail::Usage("compare needs a SCENE".into()))?;
    a.finish()?;
    let scene = read_scene(&src)?;
    let axis_y = match scene.source {
        beam_core::scene::Source::GaussianBeam { waist_y_um, .. } => waist_y_um,
        beam_core::scene::Source::PlaneWave { .. } => 0.5 * (scene.domain.y_min_um + scene.domain.y_max_um),
    };
    let mut fields = Vec::new();
    for &m in &methods {
        let mut s = scene.clone();
        s.solver.method = m;
        let f = solve_scene(&s, quality, as_json)?;
        fields.push((m, f));
    }
    // The intensity peak on the source axis past the last enabled element (the
    // whole axis when there is none): the focus of a lens, the first maximum
    // behind a slit.
    let bodies = beam_core::geometry::bodies_from_scene(&scene);
    let x_from = bodies.iter().map(|b| b.bbox.x_max).fold(scene.domain.x_min_um, f64::max);
    let mut per_solver = Vec::new();
    for (m, f) in &fields {
        let peak = focal_peak(f, axis_y, x_from, scene.domain.x_max_um);
        per_solver.push(serde_json::json!({
            "solver": m, "seconds": f.meta.wall_s, "unknowns": f.meta.solver.unknowns,
            "axial_peak_x_um": peak.map(|p| p.0), "axial_peak_intensity": peak.map(|p| p.1),
            "peak_intensity": f.norms().max[0].powi(2),
        }));
    }
    let mut pairs = Vec::new();
    for i in 0..fields.len() {
        for j in i + 1..fields.len() {
            let (a_m, a_f) = &fields[i];
            let (b_m, b_f) = &fields[j];
            let g = &a_f.grid;
            let b_on_a = resample(b_f, Part::Total, g);
            let mask: Vec<bool> = (0..g.len()).map(|k| !a_f.is_pec(k) && b_on_a[k].is_some()).collect();
            let b_vals: Vec<C64> = b_on_a.into_iter().map(|v| v.unwrap_or_default()).collect();
            let e = rel_l2(&a_f.total, &b_vals, Some(&mask));
            pairs.push(serde_json::json!({ "a": a_m, "b": b_m, "rel_l2": e }));
        }
    }
    if as_json {
        println!("{}", serde_json::to_string_pretty(&serde_json::json!({ "solvers": per_solver, "pairs": pairs })).unwrap_or_default());
    } else {
        let label = |v: &serde_json::Value| v.as_str().and_then(Method::parse).map_or("?", |m| m.label());
        println!("past x = {} µm on the axis y = {} µm:", fmt(x_from), fmt(axis_y));
        for s in &per_solver {
            println!(
                "{:<5} {:>8.2} s  axial peak x = {}  peak |E|² = {:.3}",
                label(&s["solver"]),
                s["seconds"].as_f64().unwrap_or(0.0),
                s["axial_peak_x_um"].as_f64().map_or("-".into(), |v| format!("{v:.3} µm")),
                s["peak_intensity"].as_f64().unwrap_or(0.0)
            );
        }
        for p in &pairs {
            println!(
                "{} vs {}: relative L2 difference {:.3e}",
                label(&p["a"]),
                label(&p["b"]),
                p["rel_l2"].as_f64().unwrap_or(f64::NAN)
            );
        }
    }
    Ok(())
}
