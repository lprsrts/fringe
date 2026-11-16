mod common;

use std::collections::HashMap;

use fringe_core::analytic::cases;
use fringe_core::render::view::{scale, NormMode, Normalization, PartName, ViewRect};
use fringe_core::render::{render_rgba, write_npy_c128, Colormap, ColormapKind, Quantity, View};
use fringe_core::scene::examples;
use fringe_core::solver::{solve, FieldGrid, Part, Quality, SolveContext};
use fringe_core::types::C64;

fn field(name: &str) -> FieldGrid {
    solve(&examples::example(name).unwrap(), Quality::Preview, &SolveContext::new()).unwrap()
}

fn render(f: &FieldGrid, view: &View, w: u32, h: u32) -> Vec<u8> {
    let mut buf = vec![0u8; (w * h * 4) as usize];
    render_rgba(f, view, w, h, &mut buf).unwrap();
    buf
}

fn px(buf: &[u8], w: u32, x: u32, y: u32) -> [u8; 4] {
    let i = ((y * w + x) * 4) as usize;
    [buf[i], buf[i + 1], buf[i + 2], buf[i + 3]]
}

#[test]
fn colormap_endpoints() {
    assert_eq!(Colormap::Inferno.map(0.0, 633.0), [0, 0, 4, 255]);
    assert_eq!(Colormap::Inferno.map(1.0, 633.0), [252, 255, 164, 255]);
    assert_eq!(Colormap::RdBu.map(0.0, 633.0), [0x05, 0x30, 0x61, 255]);
    assert_eq!(Colormap::RdBu.map(1.0, 633.0), [0x67, 0x00, 0x1f, 255]);
    assert_eq!(Colormap::LaserGlow.map(0.0, 633.0), [0, 0, 0, 255]);
    assert_eq!(Colormap::Twilight.map(0.0, 633.0), [226, 217, 226, 255]);
    for c in Colormap::ALL {
        assert_eq!(c.lut(633.0, 1024).len(), 1024);
        assert_eq!(c.map(f64::NAN, 633.0), c.map(0.0, 633.0));
    }
}

#[test]
fn cyclic_maps_wrap() {
    for c in Colormap::ALL.iter().filter(|c| c.kind() == ColormapKind::Cyclic) {
        let (a, b) = (c.map(0.0, 633.0), c.map(1.0, 633.0));
        for ch in 0..3 {
            assert!((a[ch] as i32 - b[ch] as i32).abs() <= 1, "{c:?}: {a:?} vs {b:?}");
        }
    }
}

#[test]
fn diverging_maps_have_a_neutral_midpoint() {
    let [r, g, b, _] = Colormap::RdBu.map(0.5, 633.0);
    assert!((r as i32 - g as i32).abs() <= 8 && (g as i32 - b as i32).abs() <= 8);
    assert_eq!(Colormap::SpectralGlow.map(0.5, 633.0), [0, 0, 0, 255]);
    assert_eq!(Colormap::RdBu.kind(), ColormapKind::Diverging);
}

#[test]
fn real_part_flips_colour_at_half_a_period() {
    let f = field("lens");
    let view = |phase_deg: f64| View { quantity: Quantity::Real, colormap: "rdbu".into(), phase_deg, ..View::default() };
    let (w, h) = (320, 180);
    let a = render(&f, &view(30.0), w, h);
    let b = render(&f, &view(210.0), w, h);
    let lut = Colormap::RdBu.lut(1000.0, 1024);
    let mut index: HashMap<[u8; 4], Vec<usize>> = HashMap::new();
    for (i, c) in lut.iter().enumerate() {
        index.entry(*c).or_default().push(i);
    }
    for (&ca, &cb) in a.as_chunks::<4>().0.iter().zip(b.as_chunks::<4>().0) {
        let ok = index[&ca].iter().any(|&i| {
            let j = 1023 - i;
            [j.saturating_sub(1), j, (j + 1).min(1023)].iter().any(|&k| lut[k] == cb)
        });
        assert!(ok, "{ca:?} does not mirror to {cb:?}");
    }
}

#[test]
fn phase_is_periodic_and_scale_does_not_depend_on_it() {
    let f = field("slab");
    for q in [Quantity::Real, Quantity::Phase, Quantity::Intensity] {
        let v = |phase_deg: f64| View { quantity: q, phase_deg, ..View::default() };
        assert_eq!(render(&f, &v(47.0), 200, 120), render(&f, &v(407.0), 200, 120), "{q:?}");
        assert_eq!(scale(&f, &v(0.0)), scale(&f, &v(123.0)));
    }
    let v = |phase_deg: f64| View { quantity: Quantity::Intensity, phase_deg, ..View::default() };
    assert_eq!(render(&f, &v(0.0), 200, 120), render(&f, &v(91.0), 200, 120));
}

#[test]
fn row_zero_is_the_top() {
    let mut f = field("lens");
    let g = f.grid;
    for j in 0..g.ny {
        for i in 0..g.nx {
            f.total[g.index(i, j)] = C64::new(j as f64 / (g.ny - 1) as f64, 0.0);
        }
    }
    let view = View {
        quantity: Quantity::Magnitude,
        normalization: Normalization { mode: NormMode::Fixed, value: 1.0 },
        colormap: "viridis".into(),
        ..View::default()
    };
    let (w, h) = (64, 36);
    let buf = render(&f, &view, w, h);
    let top = px(&buf, w, 10, 0);
    let bottom = px(&buf, w, 10, h - 1);
    let lum = |c: [u8; 4]| c[0] as u32 + c[1] as u32 + c[2] as u32;
    assert!(lum(top) > lum(bottom) + 300, "{top:?} vs {bottom:?}");
}

#[test]
fn outside_and_pec_colours() {
    let f = field("mie_pec");
    let r = f.grid.rect();
    let view = View {
        view_um: Some(ViewRect { x_min_um: r.x_min - 4.0, x_max_um: r.x_max, y_min_um: r.y_min, y_max_um: r.y_max }),
        outside_rgba: [1, 2, 3, 4],
        pec_rgba: Some([9, 9, 9, 255]),
        ..View::default()
    };
    let (w, h) = (200, 90);
    let buf = render(&f, &view, w, h);
    assert_eq!(px(&buf, w, 2, 45), [1, 2, 3, 4]);
    // The cylinder sits at the origin: x = 0 maps to column (0 − (−10)) / 20 · 200 = 100.
    assert_eq!(px(&buf, w, 100, 45), [9, 9, 9, 255]);
    let plain = View { pec_rgba: None, ..view };
    assert_ne!(px(&render(&f, &plain, w, h), w, 100, 45), [9, 9, 9, 255]);
}

#[test]
fn parts_and_errors() {
    let scattered = View { part: PartName::Scattered, ..View::default() };
    // With no elements the scattered field is exactly zero: one flat colour.
    let free = solve(&cases::case_scene("free_beam").unwrap(), Quality::Preview, &SolveContext::new()).unwrap();
    let buf = render(&free, &scattered, 40, 20);
    assert!(buf.as_chunks::<4>().0.iter().all(|c| *c == [0, 0, 4, 255]));
    // The lens scatters, so its scattered part is not flat.
    let f = field("lens");
    let buf = render(&f, &scattered, 40, 20);
    assert!(buf.as_chunks::<4>().0.iter().any(|c| *c != [0, 0, 4, 255]));
    assert!((0..f.grid.len()).any(|i| f.value(Part::Scattered, i).norm() > 0.05));
    let mut small = vec![0u8; 10];
    assert!(render_rgba(&f, &View::default(), 4, 4, &mut small).is_err());
    assert!(render_rgba(&f, &View { colormap: "nope".into(), ..View::default() }, 4, 4, &mut [0u8; 64]).is_err());
    assert!(View::parse(r#"{"quantity": "real", "bogus": 1}"#).is_err());
    let v = View::parse(r#"{"quantity": "phase", "pec_rgba": null}"#).unwrap();
    assert_eq!(v.quantity, Quantity::Phase);
    assert_eq!(v.pec_rgba, None);
    assert_eq!(View::parse("{}").unwrap().pec_rgba, Some([128, 128, 128, 255]));
}

#[test]
fn render_speed() {
    let f = field("lens");
    let (w, h) = (2100, 1200);
    let mut buf = vec![0u8; w * h * 4];
    let t = std::time::Instant::now();
    render_rgba(&f, &View::default(), w as u32, h as u32, &mut buf).unwrap();
    eprintln!("2.5 MP render: {:.1} ms", t.elapsed().as_secs_f64() * 1e3);
}

#[test]
fn npy_layout() {
    let f = field("lens");
    let dir = std::env::temp_dir().join("fringe_render_npy_test");
    let path = dir.join("field.npy");
    write_npy_c128(&path, &f, Part::Total).unwrap();
    let bytes = std::fs::read(&path).unwrap();
    assert_eq!(&bytes[..8], b"\x93NUMPY\x01\x00");
    let hlen = u16::from_le_bytes([bytes[8], bytes[9]]) as usize;
    assert_eq!((10 + hlen) % 64, 0);
    let header = std::str::from_utf8(&bytes[10..10 + hlen]).unwrap();
    assert!(header.contains("'descr': '<c16'"));
    assert!(header.contains(&format!("'shape': ({}, {})", f.grid.ny, f.grid.nx)));
    assert_eq!(bytes.len(), 10 + hlen + 16 * f.grid.len());
    // Row 0 of the array is the top row of the grid.
    let g = f.grid;
    let first = C64::new(
        f64::from_le_bytes(bytes[10 + hlen..18 + hlen].try_into().unwrap()),
        f64::from_le_bytes(bytes[18 + hlen..26 + hlen].try_into().unwrap()),
    );
    assert_eq!(first, f.total[g.index(0, g.ny - 1)]);
    let sidecar: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(dir.join("field.npy.json")).unwrap()).unwrap();
    assert_eq!(sidecar["grid"]["nx"], g.nx);
    let _ = std::fs::remove_dir_all(dir);
}
