use std::io::Write;
use std::process::{Command, Output, Stdio};

fn cli(args: &[&str], stdin: Option<&str>) -> Output {
    let mut child = Command::new(env!("CARGO_BIN_EXE_beam-cli"))
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    if let Some(s) = stdin {
        child.stdin.take().unwrap().write_all(s.as_bytes()).unwrap();
    }
    drop(child.stdin.take());
    child.wait_with_output().unwrap()
}

fn code(o: &Output) -> i32 {
    o.status.code().unwrap()
}

fn tmp(name: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join("beam_cli_test");
    std::fs::create_dir_all(&dir).unwrap();
    dir.join(name)
}

fn png_size(path: &std::path::Path) -> (u32, u32) {
    let b = std::fs::read(path).unwrap();
    assert_eq!(&b[..8], b"\x89PNG\r\n\x1a\n");
    (u32::from_be_bytes(b[16..20].try_into().unwrap()), u32::from_be_bytes(b[20..24].try_into().unwrap()))
}

fn example(name: &str) -> String {
    String::from_utf8(cli(&["example", name], None).stdout).unwrap()
}

#[test]
fn help_version_and_usage_errors() {
    assert_eq!(code(&cli(&[], None)), 0);
    let o = cli(&["--version"], None);
    assert!(String::from_utf8_lossy(&o.stdout).starts_with("beam-cli 0.2"));
    assert_eq!(code(&cli(&["frobnicate"], None)), 2);
    assert_eq!(code(&cli(&["solve", "-"], Some(&example("lens")))), 2);
    let o = cli(&["info", "--waist", "1mm"], None);
    assert_eq!(code(&o), 2);
    assert!(String::from_utf8_lossy(&o.stderr).contains("removed in v2"));
    assert_eq!(code(&cli(&["export", "-o", "x.png"], None)), 2);
}

#[test]
fn example_list_and_check() {
    let o = cli(&["example"], None);
    assert_eq!(code(&o), 0);
    let text = String::from_utf8(o.stdout).unwrap();
    assert_eq!(text.lines().count(), 10);
    assert!(text.lines().next().unwrap().starts_with("lens"));
    assert_eq!(code(&cli(&["example", "nope"], None)), 2);
    let o = cli(&["check", "-"], Some(&example("talbot")));
    assert_eq!(code(&o), 0, "{}", String::from_utf8_lossy(&o.stdout));
    let o = cli(&["check", "-", "--json"], Some(&example("lens")));
    let report: serde_json::Value = serde_json::from_slice(&o.stdout).unwrap();
    assert_eq!(report["ok"], true);
    let bad = example("lens").replace("\"center_thickness_um\": 3.0", "\"center_thickness_um\": 0.5");
    let o = cli(&["check", "-"], Some(&bad));
    assert_eq!(code(&o), 1);
    assert!(String::from_utf8_lossy(&o.stdout).contains("lens_thickness"));
}

#[test]
fn solve_writes_png_npy_and_stats() {
    let png = tmp("lens.png");
    let npy = tmp("lens.npy");
    let stats = tmp("lens.json");
    let o = cli(
        &["solve", "-", "-o", png.to_str().unwrap(), "--quality", "preview", "--width", "480", "--npy", npy.to_str().unwrap(), "--stats", stats.to_str().unwrap(), "--quiet"],
        Some(&example("lens")),
    );
    assert_eq!(code(&o), 0, "{}", String::from_utf8_lossy(&o.stderr));
    assert_eq!(png_size(&png), (480, 270));
    let b = std::fs::read(&npy).unwrap();
    assert_eq!(&b[..6], b"\x93NUMPY");
    let s: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&stats).unwrap()).unwrap();
    assert_eq!(s["method"], "fdtd");
    // Both sizes: the domain is centred and padded to the pixel aspect.
    let o = cli(&["solve", "-", "-o", png.to_str().unwrap(), "--quality", "preview", "--width", "300", "--height", "300", "--solver", "mom", "--quantity", "phase", "--quiet"], Some(&example("lens")));
    assert_eq!(code(&o), 0);
    assert_eq!(png_size(&png), (300, 300));
    // Neither: 1920 on the long edge.
    let o = cli(&["solve", "-", "-o", png.to_str().unwrap(), "--quality", "preview", "--quiet"], Some(&example("slab")));
    assert_eq!(code(&o), 0);
    assert_eq!(png_size(&png), (1707, 1920));
    // Invalid scenes are solve errors.
    let bad = example("lens").replace("\"center_thickness_um\": 3.0", "\"center_thickness_um\": 0.5");
    assert_eq!(code(&cli(&["solve", "-", "-o", png.to_str().unwrap(), "--quiet"], Some(&bad))), 3);
    assert_eq!(code(&cli(&["solve", "-", "-o", png.to_str().unwrap(), "--colormap", "nope"], Some(&example("lens")))), 2);
}

#[test]
fn frames() {
    let dir = tmp("frames");
    let o = cli(&["frames", "-", "-o", dir.to_str().unwrap(), "--frames", "3", "--quality", "preview", "--width", "64", "--quiet"], Some(&example("mie_pec")));
    assert_eq!(code(&o), 0, "{}", String::from_utf8_lossy(&o.stderr));
    for k in 0..3 {
        assert_eq!(png_size(&dir.join(format!("frame_{k:03}.png"))).0, 64);
    }
}

#[test]
fn validate_prints_a_row_per_case_and_solver() {
    let o = cli(&["validate", "--case", "free_beam,transparent", "--quality", "preview"], None);
    let text = String::from_utf8_lossy(&o.stdout).to_string();
    for case in ["free_beam", "transparent"] {
        let rows: Vec<&str> = text.lines().filter(|l| l.starts_with(case)).collect();
        assert_eq!(rows.len(), 3, "{text}");
        assert!(rows.iter().all(|l| l.contains("| PASS")), "{text}");
    }
    assert_eq!(code(&o), 0, "{text}");
    let o = cli(&["validate", "--case", "free_beam", "--solver", "mom", "--json"], None);
    let rows: serde_json::Value = serde_json::from_slice(&o.stdout).unwrap();
    assert_eq!(rows[0]["status"], "pass");
    assert_eq!(rows[0]["error"], 0.0);
    assert_eq!(code(&cli(&["validate", "--case", "nope"], None)), 2);
    assert_eq!(code(&cli(&["validate", "--solver", "nope"], None)), 2);
}
