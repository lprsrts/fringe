use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};

const PNG_SIGNATURE: [u8; 8] = [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];

fn cli() -> Command {
    Command::new(env!("CARGO_BIN_EXE_beam-cli"))
}

fn run(args: &[&str]) -> Output {
    cli().args(args).output().expect("failed to spawn beam-cli")
}

fn stdout(out: &Output) -> String {
    String::from_utf8_lossy(&out.stdout).into_owned()
}

fn stderr(out: &Output) -> String {
    String::from_utf8_lossy(&out.stderr).into_owned()
}

/// Asserts the command failed with exit code 1 and an error mentioning `needle`.
fn assert_fails_with(args: &[&str], needle: &str) {
    let out = run(args);
    assert_eq!(out.status.code(), Some(1), "{args:?} should fail");
    let err = stderr(&out);
    assert!(
        err.starts_with("beam-cli: "),
        "{args:?}: stderr was {err:?}"
    );
    assert!(
        err.contains(needle),
        "{args:?}: expected {needle:?} in {err:?}"
    );
    assert!(
        out.stdout.is_empty(),
        "{args:?}: nothing should go to stdout"
    );
}

/// A scratch directory under the system temp dir, removed on drop.
struct TempDir(PathBuf);

impl TempDir {
    fn new() -> Self {
        static COUNTER: AtomicUsize = AtomicUsize::new(0);
        let n = COUNTER.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!("beam-cli-test-{}-{n}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        TempDir(dir)
    }

    fn path(&self, name: &str) -> PathBuf {
        self.0.join(name)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn export(out: &Path, extra: &[&str]) -> Output {
    let mut args = vec!["export", "--output", out.to_str().unwrap()];
    args.extend_from_slice(extra);
    run(&args)
}

fn export_ok(out: &Path, extra: &[&str]) -> image::RgbaImage {
    let res = export(out, extra);
    assert!(
        res.status.success(),
        "export {extra:?} failed: {}",
        stderr(&res)
    );
    let bytes = std::fs::read(out).unwrap();
    assert_eq!(bytes[..8], PNG_SIGNATURE);
    image::load_from_memory(&bytes).unwrap().to_rgba8()
}

fn luminance(p: &image::Rgba<u8>) -> f64 {
    0.299 * p[0] as f64 + 0.587 * p[1] as f64 + 0.114 * p[2] as f64
}

/// Reads the first number after `label` in `info` output.
fn info_field(text: &str, label: &str) -> f64 {
    let line = text
        .lines()
        .find(|l| l.starts_with(label))
        .unwrap_or_else(|| panic!("no {label:?} line in:\n{text}"));
    line[label.len()..]
        .split_whitespace()
        .next()
        .unwrap()
        .parse()
        .unwrap_or_else(|_| panic!("bad number on line {line:?}"))
}

fn assert_rel(actual: f64, expected: f64, rel: f64) {
    assert!(
        ((actual - expected) / expected).abs() < rel,
        "expected {expected}, got {actual}"
    );
}

#[test]
fn help_lists_commands_and_options() {
    for args in [
        &["--help"][..],
        &["-h"],
        &["help"],
        &[],
        &["export", "--help"],
        &["info", "-h"],
    ] {
        let out = run(args);
        assert!(out.status.success(), "{args:?}");
        let text = stdout(&out);
        assert!(text.contains("Usage:"), "{args:?}");
        for opt in [
            "--output",
            "--waist",
            "--wavelength",
            "--colormap",
            "--fringe",
            "--power",
        ] {
            assert!(text.contains(opt), "help for {args:?} is missing {opt}");
        }
        assert!(out.stderr.is_empty());
    }
}

#[test]
fn version_matches_crate() {
    for flag in ["--version", "-V"] {
        let out = run(&[flag]);
        assert!(out.status.success());
        assert_eq!(
            stdout(&out).trim(),
            format!("beam-cli {}", env!("CARGO_PKG_VERSION"))
        );
    }
}

#[test]
fn info_defaults_to_hene_beam() {
    let out = run(&["info"]);
    assert!(out.status.success());
    let text = stdout(&out);

    // 632.8 nm, w0 = 0.5 mm, n = 1, P = 1 W.
    let w0: f64 = 0.5e-3;
    let lambda = 632.8e-9;
    let z_r = std::f64::consts::PI * w0 * w0 / lambda;
    assert_rel(info_field(&text, "wavelength"), 632.8, 1e-6);
    assert_rel(info_field(&text, "waist w0"), 500.0, 1e-6);
    assert_rel(info_field(&text, "rayleigh z_R"), z_r, 1e-5);
    assert_rel(info_field(&text, "confocal b"), 2.0 * z_r, 1e-5);
    assert_rel(
        info_field(&text, "divergence"),
        lambda / (std::f64::consts::PI * w0) * 1e3,
        1e-3,
    );
    assert_rel(
        info_field(&text, "peak intensity"),
        2.0 / (std::f64::consts::PI * w0 * w0),
        1e-3,
    );
    assert!(text.contains("paraxial        yes"));
}

#[test]
fn info_scales_with_index_and_power() {
    let out = run(&[
        "info",
        "--waist",
        "1mm",
        "--wavelength",
        "1064nm",
        "--n",
        "1.5",
        "--power",
        "2",
    ]);
    assert!(out.status.success(), "{}", stderr(&out));
    let text = stdout(&out);

    // In a medium of index n the Rayleigh range grows by n and the divergence
    // shrinks by n, because the wavelength inside the medium is lambda / n.
    let (w0, lambda, n) = (1e-3_f64, 1064e-9, 1.5);
    let z_r = std::f64::consts::PI * w0 * w0 * n / lambda;
    assert_rel(info_field(&text, "rayleigh z_R"), z_r, 1e-5);
    assert_rel(
        info_field(&text, "divergence"),
        lambda / (std::f64::consts::PI * w0 * n) * 1e3,
        1e-3,
    );
    assert_rel(info_field(&text, "power"), 2.0, 1e-6);
    assert_rel(
        info_field(&text, "peak intensity"),
        2.0 * 2.0 / (std::f64::consts::PI * w0 * w0),
        1e-3,
    );
}

#[test]
fn unit_suffixes_convert_to_metres() {
    // Each pair describes the same beam; the printed waist and wavelength must agree.
    let cases: &[(&[&str], f64, f64)] = &[
        (&["--waist", "0.8mm", "--wavelength", "532nm"], 800.0, 532.0),
        (
            &["--waist", "800um", "--wavelength", "0.532um"],
            800.0,
            532.0,
        ),
        (
            &["--waist", "800µm", "--wavelength", "5.32e-7"],
            800.0,
            532.0,
        ),
        (
            &["--waist", "0.08cm", "--wavelength", "5.32e-7m"],
            800.0,
            532.0,
        ),
        (&["--w0", "150um", "--lambda", "1064nm"], 150.0, 1064.0),
        (
            &["--waist", " 2mm ", "--wavelength", "633 nm"],
            2000.0,
            633.0,
        ),
    ];
    for (flags, waist_um, lambda_nm) in cases {
        let mut args = vec!["info"];
        args.extend_from_slice(flags);
        let out = run(&args);
        assert!(out.status.success(), "{flags:?}: {}", stderr(&out));
        let text = stdout(&out);
        assert_rel(info_field(&text, "waist w0"), *waist_um, 1e-6);
        assert_rel(info_field(&text, "wavelength"), *lambda_nm, 1e-6);
    }
}

#[test]
fn tight_focus_has_sub_millimetre_rayleigh_range() {
    // A 5 um waist at 532 nm diverges at ~34 mrad; still paraxial, but z_R is sub-millimetre.
    let out = run(&["info", "--lambda", "532nm", "--w0", "5um"]);
    assert!(out.status.success());
    let text = stdout(&out);
    assert_rel(
        info_field(&text, "divergence"),
        532e-9 / (std::f64::consts::PI * 5e-6) * 1e3,
        1e-3,
    );
    assert!(info_field(&text, "rayleigh z_R") < 1e-3);
}

#[test]
fn info_rejects_unphysical_beams() {
    assert_fails_with(&["info", "--waist", "-1mm"], "w0 must be positive");
    assert_fails_with(&["info", "--waist", "0"], "w0 must be positive");
    assert_fails_with(
        &["info", "--wavelength", "-500nm"],
        "wavelength must be positive",
    );
    assert_fails_with(&["info", "--n", "0.5"], "refractive index");
    assert_fails_with(&["info", "--n", "NaN"], "refractive index");
    assert_fails_with(&["info", "--n", "inf"], "refractive index");
    assert_fails_with(&["info", "--n", "glass"], "invalid --n");
    assert_fails_with(&["info", "--power", "-1"], "power must be");
    assert_fails_with(
        &["info", "--colormap", "viridis"],
        "unknown option '--colormap' for info",
    );
}

#[test]
fn rejects_bad_arguments() {
    let cases: &[(&[&str], &str)] = &[
        (&["frobnicate"], "unknown command 'frobnicate'"),
        (&["export", "--width", "800"], "export needs --output"),
        (&["export", "--output"], "--output needs a value"),
        (
            &["export", "-o", "x.png", "--waist"],
            "--waist needs a value",
        ),
        (
            &["export", "-o", "x.png", "--bogus"],
            "unknown option '--bogus'",
        ),
        (
            &["export", "-o", "x.png", "--waist", "-0.001"],
            "--waist must be positive",
        ),
        (
            &["export", "-o", "x.png", "--waist", "0"],
            "--waist must be positive",
        ),
        (
            &["export", "-o", "x.png", "--wavelength", "-5e-7"],
            "--wavelength must be positive",
        ),
        (
            &["export", "-o", "x.png", "--waist", "inf"],
            "must be finite",
        ),
        (
            &["export", "-o", "x.png", "--waist", "1e400"],
            "must be finite",
        ),
        (
            &["export", "-o", "x.png", "--waist", "NaN"],
            "must be finite",
        ),
        (
            &["export", "-o", "x.png", "--waist", "mm"],
            "invalid number",
        ),
        (&["export", "-o", "x.png", "--waist", ""], "empty value"),
        (
            &["export", "-o", "x.png", "--waist", "3furlongs"],
            "invalid number",
        ),
        (
            &["export", "-o", "x.png", "--width", "0"],
            "--width must be positive",
        ),
        (
            &["export", "-o", "x.png", "--height", "0"],
            "--height must be positive",
        ),
        (
            &["export", "-o", "x.png", "--width", "-5"],
            "invalid --width",
        ),
        (
            &["export", "-o", "x.png", "--width", "999999999999999999999"],
            "invalid --width",
        ),
        (
            &["export", "-o", "x.png", "--width", "16385"],
            "--width must be at most 16384",
        ),
        (
            &["export", "-o", "x.png", "--height", "16385"],
            "--height must be at most 16384",
        ),
        (
            &["export", "-o", "x.png", "--colormap", "rainbow"],
            "unknown colormap 'rainbow'",
        ),
        (
            &["export", "-o", "x.png", "--gamma", "0"],
            "--gamma must be a positive number",
        ),
        (
            &["export", "-o", "x.png", "--gamma", "-2"],
            "--gamma must be a positive number",
        ),
        (
            &["export", "-o", "x.png", "--gamma", "NaN"],
            "--gamma must be a positive number",
        ),
        (
            &["export", "-o", "x.png", "--fringe", "NaN"],
            "invalid --fringe",
        ),
        (&["--frobnicate"], "unknown option '--frobnicate'"),
    ];
    for (args, needle) in cases {
        assert_fails_with(args, needle);
        let err = stderr(&run(args));
        assert!(err.contains("try 'beam-cli --help'"), "{args:?}: {err:?}");
    }
}

#[test]
fn failed_export_writes_nothing() {
    let dir = TempDir::new();
    let out = dir.path("never.png");
    let res = export(&out, &["--width", "0"]);
    assert!(!res.status.success());
    assert!(!out.exists());
}

#[test]
fn export_writes_a_beam_png() {
    // Replaces the old verify_export.sh: a real cover-sized PNG with visible contrast.
    let dir = TempDir::new();
    let out = dir.path("cover.png");
    let res = export(
        &out,
        &[
            "--width",
            "1280",
            "--height",
            "960",
            "--colormap",
            "viridis",
        ],
    );
    assert!(res.status.success(), "{}", stderr(&res));
    let msg = stdout(&res);
    assert!(msg.starts_with("wrote "), "{msg:?}");
    assert!(msg.contains("1280x960") && msg.contains("viridis"));

    let bytes = std::fs::read(&out).unwrap();
    assert_eq!(bytes[..8], PNG_SIGNATURE);
    assert!(
        bytes.len() > 10_000,
        "suspiciously small PNG: {} bytes",
        bytes.len()
    );

    let img = image::load_from_memory(&bytes).unwrap().to_rgba8();
    assert_eq!(img.dimensions(), (1280, 960));

    let lum: Vec<f64> = img.pixels().step_by(97).map(luminance).collect();
    let mean = lum.iter().sum::<f64>() / lum.len() as f64;
    let std = (lum.iter().map(|l| (l - mean).powi(2)).sum::<f64>() / lum.len() as f64).sqrt();
    let (min, max) = lum
        .iter()
        .fold((f64::MAX, f64::MIN), |(a, b), &l| (a.min(l), b.max(l)));
    assert!(max - min >= 50.0, "dynamic range {}", max - min);
    assert!(std >= 8.0, "std dev {std}");
    assert!(max > 150.0, "peak luminance {max}");

    // The beam axis runs horizontally through the middle, so the centre row
    // must be brighter than the top edge, and the image symmetric about it.
    let (w, h) = img.dimensions();
    let centre = luminance(img.get_pixel(w / 2, h / 2));
    let edge = luminance(img.get_pixel(w / 2, 0));
    assert!(centre > edge + 50.0, "centre {centre} vs edge {edge}");
    let above = luminance(img.get_pixel(w / 2, h / 4));
    let below = luminance(img.get_pixel(w / 2, h - 1 - h / 4));
    assert!(
        (above - below).abs() <= 3.0,
        "asymmetric: {above} vs {below}"
    );
}

#[test]
fn every_colormap_exports() {
    let dir = TempDir::new();
    let names = [
        "viridis",
        "inferno",
        "plasma",
        "turbo",
        "laser_glow",
        "asympton",
    ];
    let mut centres = Vec::new();
    for name in names {
        let out = dir.path(&format!("{name}.png"));
        let img = export_ok(
            &out,
            &["--colormap", name, "--width", "64", "--height", "48"],
        );
        assert_eq!(img.dimensions(), (64, 48));
        centres.push(*img.get_pixel(32, 24));
    }
    for i in 0..centres.len() {
        for j in i + 1..centres.len() {
            assert_ne!(
                centres[i], centres[j],
                "{} and {} look identical",
                names[i], names[j]
            );
        }
    }
}

#[test]
fn colormap_name_is_case_insensitive() {
    let dir = TempDir::new();
    let upper = export_ok(
        &dir.path("a.png"),
        &["--colormap", "ASYMPTON", "--width", "16", "--height", "16"],
    );
    let lower = export_ok(
        &dir.path("b.png"),
        &["--colormap", "asympton", "--width", "16", "--height", "16"],
    );
    assert_eq!(upper, lower);
}

#[test]
fn export_accepts_unit_suffixed_flags() {
    let dir = TempDir::new();
    let small = ["--width", "48", "--height", "32"];
    let mut with_units = small.to_vec();
    with_units.extend([
        "--waist",
        "0.4mm",
        "--wavelength",
        "532nm",
        "--z",
        "5cm",
        "--z-min",
        "-0.3m",
        "--z-max",
        "300mm",
        "--x-max",
        "1200um",
    ]);
    let mut bare = small.to_vec();
    bare.extend([
        "--waist",
        "4e-4",
        "--wavelength",
        "5.32e-7",
        "--z",
        "0.05",
        "--z-min",
        "-0.3",
        "--z-max",
        "0.3",
        "--x-max",
        "0.0012",
    ]);
    let a = export_ok(&dir.path("units.png"), &with_units);
    let b = export_ok(&dir.path("bare.png"), &bare);
    assert_eq!(a, b);
}

#[test]
fn gamma_and_fringe_change_the_image() {
    let dir = TempDir::new();
    let base = ["--width", "64", "--height", "48"];
    let plain = export_ok(&dir.path("plain.png"), &base);

    let mut g = base.to_vec();
    g.extend(["--gamma", "2.2"]);
    assert_ne!(plain, export_ok(&dir.path("gamma.png"), &g));

    let mut f = base.to_vec();
    f.extend(["--fringe", "0.5"]);
    assert_ne!(plain, export_ok(&dir.path("fringe.png"), &f));
}

#[test]
fn fringe_is_clamped_to_unit_range() {
    let dir = TempDir::new();
    let base = ["--width", "32", "--height", "24"];
    let at = |v: &str, name: &str| {
        let mut a = base.to_vec();
        a.extend(["--fringe", v]);
        export_ok(&dir.path(name), &a)
    };
    assert_eq!(at("5", "over.png"), at("1", "one.png"));
    assert_eq!(at("-1", "under.png"), at("0", "zero.png"));
}

#[test]
fn bare_flags_export_to_cover_png_in_cwd() {
    let dir = TempDir::new();
    let res = cli()
        .args(["--width", "16", "--height", "8"])
        .current_dir(&dir.0)
        .output()
        .unwrap();
    assert!(res.status.success(), "{}", stderr(&res));
    let img = image::open(dir.path("cover.png")).unwrap();
    assert_eq!((img.width(), img.height()), (16, 8));
}

#[test]
fn export_creates_missing_parent_directories() {
    let dir = TempDir::new();
    let out = dir.path("a/b/c/cover.png");
    let img = export_ok(&out, &["--width", "8", "--height", "8"]);
    assert_eq!(img.dimensions(), (8, 8));
}

#[test]
fn extreme_sizes_and_beams_still_produce_pngs() {
    let dir = TempDir::new();
    let cases: &[&[&str]] = &[
        &["--width", "1", "--height", "1"],
        &["--width", "4000", "--height", "1"],
        &["--width", "1", "--height", "4000"],
        // Waist far below the wavelength: z_R is sub-nanometre.
        &[
            "--width",
            "16",
            "--height",
            "16",
            "--waist",
            "1nm",
            "--wavelength",
            "10um",
        ],
        // Waist placed absurdly far from the window.
        &["--width", "16", "--height", "16", "--z", "1e300"],
    ];
    for (i, extra) in cases.iter().enumerate() {
        let out = dir.path(&format!("{i}.png"));
        let res = export(&out, extra);
        assert!(res.status.success(), "{extra:?}: {}", stderr(&res));
        let bytes = std::fs::read(&out).unwrap();
        assert_eq!(bytes[..8], PNG_SIGNATURE, "{extra:?}");
        image::load_from_memory(&bytes).unwrap();
    }
}

#[test]
fn rejects_empty_or_inverted_render_window() {
    let dir = TempDir::new();
    let out = dir.path("x.png");
    let out = out.to_str().unwrap();
    assert_fails_with(&["export", "-o", out, "--x-max", "0"], "--x-max");
    assert_fails_with(&["export", "-o", out, "--x-max", "-1mm"], "--x-max");
    assert_fails_with(
        &["export", "-o", out, "--z-min", "1", "--z-max", "-1"],
        "--z-min",
    );
}

#[test]
fn concurrent_exports_do_not_interfere() {
    let dir = TempDir::new();
    let children: Vec<_> = (0..4)
        .map(|i| {
            let out = dir.path(&format!("{i}.png"));
            let child = cli()
                .args([
                    "export",
                    "--output",
                    out.to_str().unwrap(),
                    "--width",
                    "96",
                    "--height",
                    "64",
                ])
                .stdout(Stdio::null())
                .spawn()
                .unwrap();
            (out, child)
        })
        .collect();
    let mut images = Vec::new();
    for (out, mut child) in children {
        assert!(child.wait().unwrap().success());
        images.push(image::open(out).unwrap().to_rgba8());
    }
    assert!(images.windows(2).all(|w| w[0] == w[1]));
}
