use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::thread;

use beam_core::render::asympton_tokens;
use beam_core::{
    check_buffer_capacity, colormap_asympton, colormap_inferno, colormap_laser_glow,
    colormap_plasma, colormap_turbo, colormap_viridis, encode_png, export_beam_to_png_file,
    export_png_file, map_colormap, map_intensity_to_rgba, map_intensity_with_transfer,
    render_longitudinal_rgba, render_longitudinal_slice, render_transverse_rgba,
    render_transverse_slice, wavelength_to_nm, wavelength_to_rgb, Colormap, ColormapLut,
    GaussianBeam, IntensityGrid, OpticalElement, OpticalTrain, RenderError, RenderStyle,
    TransferFunction, MAX_DIMENSION,
};

const PNG_SIGNATURE: &[u8; 8] = b"\x89PNG\r\n\x1a\n";

/// A fresh directory under the system temp dir, removed on drop.
struct TempDir(PathBuf);

impl TempDir {
    fn new(name: &str) -> Self {
        static COUNTER: AtomicUsize = AtomicUsize::new(0);
        let n = COUNTER.fetch_add(1, Ordering::Relaxed);
        let path =
            std::env::temp_dir().join(format!("beam_render_{}_{}_{}", name, std::process::id(), n));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).unwrap();
        TempDir(path)
    }

    fn join(&self, p: &str) -> PathBuf {
        self.0.join(p)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn free_space() -> OpticalTrain {
    OpticalTrain::new()
}

fn style(colormap: Colormap, gamma: f64, fringes: f64) -> RenderStyle {
    RenderStyle::new(colormap, gamma).with_wavefront(fringes > 0.0, fringes)
}

#[allow(clippy::too_many_arguments)]
fn render(
    beam: &GaussianBeam,
    train: &OpticalTrain,
    style: &RenderStyle,
    z_min: f64,
    z_max: f64,
    x_max: f64,
    width: usize,
    height: usize,
) -> Vec<u8> {
    let mut buf = vec![0u8; width * height * 4];
    render_longitudinal_rgba(
        beam, train, style, z_min, z_max, x_max, width, height, &mut buf,
    )
    .unwrap();
    buf
}

#[allow(clippy::too_many_arguments)]
fn longitudinal(
    beam: &GaussianBeam,
    train: &OpticalTrain,
    style: &RenderStyle,
    z_min: f64,
    z_max: f64,
    x_max: f64,
    width: usize,
    height: usize,
) -> IntensityGrid {
    IntensityGrid::evaluate_longitudinal(beam, train, z_min, z_max, x_max, width, height, style)
        .unwrap()
}

fn pixel(buf: &[u8], width: usize, col: usize, row: usize) -> [u8; 4] {
    let i = (row * width + col) * 4;
    [buf[i], buf[i + 1], buf[i + 2], buf[i + 3]]
}

fn pixels(buf: &[u8]) -> impl Iterator<Item = &[u8; 4]> {
    buf.as_chunks::<4>().0.iter()
}

fn luminance(c: [u8; 4]) -> f64 {
    0.2126 * c[0] as f64 + 0.7152 * c[1] as f64 + 0.0722 * c[2] as f64
}

fn assert_opaque(buf: &[u8]) {
    assert!(pixels(buf).all(|p| p[3] == 255), "non-opaque pixel");
}

fn assert_unit_range(grid: &IntensityGrid) {
    for &v in &grid.data {
        assert!(v.is_finite() && (0.0..=1.0).contains(&v), "value {v}");
    }
}

fn decode_png(bytes: &[u8]) -> image::RgbaImage {
    image::load_from_memory(bytes).unwrap().to_rgba8()
}

fn lens(f: f64) -> OpticalElement {
    OpticalElement::ThinLens { focal_length: f }
}

fn interface(n1: f64, n2: f64, radius: Option<f64>) -> OpticalElement {
    OpticalElement::DielectricInterface { n1, n2, radius }
}

#[test]
fn on_axis_intensity_falls_as_lorentzian() {
    let beam = GaussianBeam::default();
    let zr = beam.rayleigh_range();
    // Odd sizes put a pixel centre exactly on the waist and on the axis.
    let (w, h) = (401, 51);
    let grid = longitudinal(
        &beam,
        &free_space(),
        &RenderStyle::default(),
        -2.0 * zr,
        2.0 * zr,
        2e-3,
        w,
        h,
    );
    assert!((grid.peak_intensity - beam.peak_intensity()).abs() / beam.peak_intensity() < 1e-9);

    let row = h / 2;
    let dz = 4.0 * zr / w as f64;
    for col in 0..w {
        let z = -2.0 * zr + (col as f64 + 0.5) * dz;
        let expected = 1.0 / (1.0 + (z / zr).powi(2));
        let got = grid.data[row * w + col];
        assert!(
            (got - expected).abs() < 1e-9,
            "col {col}: {got} vs {expected}"
        );
    }
    // Half intensity at z = +-z_R, a fifth at the edges.
    assert!((grid.data[row * w] - 0.2).abs() < 2e-3);
    assert!((grid.data[row * w + w - 1] - 0.2).abs() < 2e-3);
}

#[test]
fn transverse_profile_across_waist_column_is_gaussian() {
    let beam = GaussianBeam::default();
    let (w, h, x_max) = (11, 201, 3.0 * beam.w0);
    let grid = longitudinal(
        &beam,
        &free_space(),
        &RenderStyle::default(),
        -0.1,
        0.1,
        x_max,
        w,
        h,
    );
    let col = w / 2;
    let dx = 2.0 * x_max / h as f64;
    for row in 0..h {
        let x = -x_max + (row as f64 + 0.5) * dx;
        let expected = (-2.0 * x * x / (beam.w0 * beam.w0)).exp();
        assert!((grid.data[row * w + col] - expected).abs() < 1e-9);
    }
}

#[test]
fn longitudinal_image_is_mirror_symmetric_about_axis() {
    let beam = GaussianBeam::default();
    let mut train = OpticalTrain::new();
    train.add_element(0.3, lens(0.2));
    let (w, h) = (64, 48);
    let buf = render(
        &beam,
        &train,
        &style(Colormap::Inferno, 1.3, 0.6),
        0.0,
        0.8,
        3.0 * beam.w0,
        w,
        h,
    );
    for row in 0..h / 2 {
        for col in 0..w {
            assert_eq!(
                pixel(&buf, w, col, row),
                pixel(&buf, w, col, h - 1 - row),
                "row {row} col {col}"
            );
        }
    }
}

#[test]
fn transverse_grid_is_gaussian_and_normalised_per_plane() {
    let beam = GaussianBeam::default();
    let z = beam.rayleigh_range();
    let wz = beam.waist_at(z);
    let (n, half) = (101, 3.0 * wz);
    let grid = IntensityGrid::evaluate_transverse(
        &beam,
        &free_space(),
        z,
        half,
        half,
        n,
        n,
        &RenderStyle::default(),
    )
    .unwrap();

    let local_peak = beam.intensity_at(0.0, z);
    assert!((grid.peak_intensity - local_peak).abs() / local_peak < 1e-12);
    assert!((grid.data[(n / 2) * n + n / 2] - 1.0).abs() < 1e-12);

    let step = 2.0 * half / n as f64;
    let mut power = 0.0;
    for j in 0..n {
        let y = -half + (j as f64 + 0.5) * step;
        for i in 0..n {
            let x = -half + (i as f64 + 0.5) * step;
            let v = grid.data[j * n + i];
            let expected = (-2.0 * (x * x + y * y) / (wz * wz)).exp();
            assert!((v - expected).abs() < 1e-9);
            power += v * grid.peak_intensity * step * step;
        }
    }
    // Integrating the image recovers the beam power.
    assert!(
        (power - beam.power).abs() / beam.power < 1e-3,
        "power {power}"
    );
}

#[test]
fn transverse_image_has_four_fold_symmetry() {
    let beam = GaussianBeam::default();
    let n = 40;
    let half = 2e-3;
    let mut buf = vec![0u8; n * n * 4];
    render_transverse_rgba(
        &beam,
        &free_space(),
        &style(Colormap::Plasma, 1.0, 0.7),
        0.6,
        half,
        half,
        n,
        n,
        &mut buf,
    )
    .unwrap();
    for j in 0..n {
        for i in 0..n {
            let p = pixel(&buf, n, i, j);
            assert_eq!(p, pixel(&buf, n, n - 1 - i, j));
            assert_eq!(p, pixel(&buf, n, i, n - 1 - j));
            assert_eq!(p, pixel(&buf, n, j, i));
        }
    }
}

#[test]
fn gamma_is_applied_as_a_power_of_the_linear_value() {
    let beam = GaussianBeam::default();
    let plain = longitudinal(
        &beam,
        &free_space(),
        &RenderStyle::default(),
        -1.0,
        1.0,
        2e-3,
        33,
        17,
    );
    for gamma in [0.3, 2.2] {
        let g = longitudinal(
            &beam,
            &free_space(),
            &RenderStyle::new(Colormap::Viridis, gamma),
            -1.0,
            1.0,
            2e-3,
            33,
            17,
        );
        for (a, b) in plain.data.iter().zip(&g.data) {
            assert!((a.powf(gamma) - b).abs() < 1e-12);
        }
    }
}

#[test]
fn values_stay_in_unit_range_for_any_gamma_and_fringe_depth() {
    let beam = GaussianBeam::default();
    let mut train = OpticalTrain::new();
    train.add_element(0.2, lens(0.15));
    for gamma in [0.1, 0.5, 1.0, 2.2, 10.0] {
        for depth in [0.0, 0.5, 1.0] {
            let s = style(Colormap::Turbo, gamma, depth);
            let grid = longitudinal(&beam, &train, &s, -0.5, 0.5, 2e-3, 40, 20);
            assert_unit_range(&grid);
            let t = IntensityGrid::evaluate_transverse(&beam, &train, 0.3, 1e-3, 1e-3, 20, 20, &s)
                .unwrap();
            assert_unit_range(&t);
        }
    }
}

#[test]
fn fringes_only_darken_and_reach_full_depth() {
    let beam = GaussianBeam::new(532e-9, 0.2e-3, 0.0, 1.0, 1.5).unwrap();
    let mut train = OpticalTrain::new();
    train.add_element(0.10, lens(0.05));
    train.add_element(0.30, lens(0.15));

    let m = 0.8;
    let args = (0.0, 0.5, 4.0 * beam.w0, 300, 151);
    let plain = longitudinal(
        &beam,
        &train,
        &RenderStyle::default(),
        args.0,
        args.1,
        args.2,
        args.3,
        args.4,
    );
    let fringed = longitudinal(
        &beam,
        &train,
        &style(Colormap::Viridis, 1.0, m),
        args.0,
        args.1,
        args.2,
        args.3,
        args.4,
    );

    let (mut lo, mut hi) = (f64::MAX, f64::MIN);
    for (p, f) in plain.data.iter().zip(&fringed.data) {
        assert!(*f <= *p + 1e-15);
        assert!(*f >= (1.0 - m) * *p - 1e-15);
        if *p > 1e-3 {
            let r = f / p;
            lo = lo.min(r);
            hi = hi.max(r);
        }
    }
    assert!(lo < 1.0 - m + 0.02, "darkest fringe ratio {lo}");
    assert!(hi > 0.98, "brightest fringe ratio {hi}");

    // The fringes are visible as pixel-to-pixel variation along the axis.
    let row = args.4 / 2;
    let changes = (1..args.3)
        .filter(|&c| {
            let a = fringed.data[row * args.3 + c - 1];
            let b = fringed.data[row * args.3 + c];
            (a - b).abs() > 1e-3
        })
        .count();
    assert!(changes > 150, "only {changes} changes along the axis");
}

#[test]
fn fringes_are_off_unless_enabled_with_nonzero_depth() {
    let beam = GaussianBeam::default();
    let base = render(
        &beam,
        &free_space(),
        &RenderStyle::default(),
        -0.5,
        0.5,
        2e-3,
        48,
        24,
    );

    let disabled = RenderStyle {
        fringe_modulation: 0.8,
        ..RenderStyle::default()
    };
    let zero_depth = RenderStyle::default().with_wavefront(true, 0.0);
    for s in [disabled, zero_depth] {
        assert_eq!(
            render(&beam, &free_space(), &s, -0.5, 0.5, 2e-3, 48, 24),
            base
        );
    }

    let on = RenderStyle::default().with_wavefront(true, 0.8);
    assert_ne!(
        render(&beam, &free_space(), &on, -0.5, 0.5, 2e-3, 48, 24),
        base
    );
}

#[test]
fn fringes_are_flat_across_the_waist_plane() {
    let beam = GaussianBeam::default();
    let (w, h) = (21, 101);
    let s = style(Colormap::Viridis, 1.0, 0.9);
    let plain = longitudinal(
        &beam,
        &free_space(),
        &RenderStyle::default(),
        -0.2,
        0.2,
        2e-3,
        w,
        h,
    );
    let fringed = longitudinal(&beam, &free_space(), &s, -0.2, 0.2, 2e-3, w, h);

    let col = w / 2;
    let ratios: Vec<f64> = (0..h)
        .map(|row| row * w + col)
        .filter(|&i| plain.data[i] > 1e-6)
        .map(|i| fringed.data[i] / plain.data[i])
        .collect();
    let first = ratios[0];
    assert!(ratios.iter().all(|r| (r - first).abs() < 1e-9));
}

#[test]
fn transverse_fringes_form_rings_away_from_the_waist() {
    let beam = GaussianBeam::default();
    let n = 101;
    let half = 1.5e-3;
    let s = style(Colormap::Viridis, 1.0, 0.8);
    let ratio_spread = |z: f64| {
        let plain = IntensityGrid::evaluate_transverse(
            &beam,
            &free_space(),
            z,
            half,
            half,
            n,
            n,
            &RenderStyle::default(),
        )
        .unwrap();
        let fringed =
            IntensityGrid::evaluate_transverse(&beam, &free_space(), z, half, half, n, n, &s)
                .unwrap();
        let ratios: Vec<f64> = plain
            .data
            .iter()
            .zip(&fringed.data)
            .filter(|(p, _)| **p > 1e-3)
            .map(|(p, f)| f / p)
            .collect();
        let lo = ratios.iter().cloned().fold(f64::MAX, f64::min);
        let hi = ratios.iter().cloned().fold(f64::MIN, f64::max);
        hi - lo
    };
    assert!(ratio_spread(0.0) < 1e-9);
    assert!(ratio_spread(beam.rayleigh_range()) > 0.3);
}

#[test]
fn brightest_column_sits_on_the_focus_of_a_mirror() {
    let beam = GaussianBeam::new(1064e-9, 1e-3, 0.0, 1.0, 5.0).unwrap();
    let mut train = OpticalTrain::new();
    train.add_element(0.25, OpticalElement::CurvedMirror { radius: 0.5 });
    let focus = train.beam_at(&beam, 0.6).unwrap().z0;
    assert!((focus - 0.5).abs() < 0.01, "focus at {focus}");

    let (w, h, z_min, z_max) = (801, 21, 0.1, 0.9);
    let grid = longitudinal(
        &beam,
        &train,
        &RenderStyle::default(),
        z_min,
        z_max,
        2.5e-3,
        w,
        h,
    );
    let row = &grid.data[(h / 2) * w..(h / 2 + 1) * w];
    let (col, &max) = row
        .iter()
        .enumerate()
        .max_by(|a, b| a.1.partial_cmp(b.1).unwrap())
        .unwrap();
    assert!((max - 1.0).abs() < 1e-12);
    let dz = (z_max - z_min) / w as f64;
    let z = z_min + (col as f64 + 0.5) * dz;
    assert!((z - focus).abs() <= dz, "peak at {z}, focus at {focus}");
}

#[test]
fn varied_trains_render_without_artifacts() {
    let mut trains: Vec<(&str, OpticalTrain)> = Vec::new();

    let mut t = OpticalTrain::new();
    t.add_element(0.2, lens(0.2));
    t.add_element(0.4, interface(1.0, 1.5, None));
    trains.push(("lens into glass", t));

    let mut t = OpticalTrain::new();
    t.add_element(0.1, interface(1.0, 1.5, Some(0.10)));
    t.add_element(0.12, interface(1.5, 1.0, Some(-0.10)));
    t.add_element(0.15, OpticalElement::GaussianAperture { radius: 0.3e-3 });
    trains.push(("thick lens and stop", t));

    let mut t = OpticalTrain::new();
    t.add_element(0.0, OpticalElement::FlatMirror);
    t.add_element(0.15, lens(0.15));
    t.add_element(0.25, interface(1.0, 1.5, None));
    t.add_element(0.35, interface(1.5, 1.0, None));
    t.add_element(0.45, OpticalElement::GaussianAperture { radius: 0.5e-3 });
    trains.push(("cavity-like", t));

    let mut t = OpticalTrain::new();
    t.add_element(0.01, lens(1.5e-3));
    trains.push(("very short focus", t));

    let mut t = OpticalTrain::new();
    for i in 1..=100 {
        let z = i as f64 * 0.02;
        let e = match i % 4 {
            0 => lens(0.15),
            1 => OpticalElement::CurvedMirror { radius: 0.5 },
            2 => interface(1.0, 1.5, None),
            _ => OpticalElement::GaussianAperture { radius: 1.2e-3 },
        };
        t.add_element(z, e);
    }
    trains.push(("100 elements", t));

    let beam = GaussianBeam::new(632.8e-9, 0.5e-3, 0.0, 1.0, 2.0).unwrap();
    let s = style(Colormap::Inferno, 1.2, 0.3);
    for (name, train) in &trains {
        let grid = longitudinal(&beam, train, &s, 0.0, 0.8, 2e-3, 120, 61);
        assert_unit_range(&grid);
        let buf = grid.to_rgba_vec(&s, beam.wavelength).unwrap();
        assert_opaque(&buf);
        let mut tbuf = vec![0u8; 32 * 32 * 4];
        render_transverse_rgba(&beam, train, &s, 0.5, 2e-3, 2e-3, 32, 32, &mut tbuf)
            .unwrap_or_else(|e| panic!("{name}: {e}"));
    }
}

#[test]
fn unpropagatable_train_falls_back_to_the_input_beam() {
    let beam = GaussianBeam::default();
    let mut singular = OpticalTrain::new();
    singular.add_element(0.1, lens(1e-18));
    assert!(singular.beam_at(&beam, 0.2).is_err());

    let s = RenderStyle::default();
    assert_eq!(
        render(&beam, &singular, &s, 0.0, 0.5, 2e-3, 40, 20),
        render(&beam, &free_space(), &s, 0.0, 0.5, 2e-3, 40, 20)
    );
}

#[test]
fn infinite_focal_length_lens_changes_nothing() {
    let beam = GaussianBeam::default();
    let mut train = OpticalTrain::new();
    train.add_element(0.2, lens(f64::INFINITY));
    let s = RenderStyle::default();
    let with = longitudinal(&beam, &train, &s, 0.0, 0.5, 2e-3, 40, 21);
    let without = longitudinal(&beam, &free_space(), &s, 0.0, 0.5, 2e-3, 40, 21);
    for (a, b) in with.data.iter().zip(&without.data) {
        assert!((a - b).abs() < 1e-12);
    }
}

#[test]
fn extreme_beams_render_finite_values() {
    let s = style(Colormap::Viridis, 1.0, 0.9);
    let cases = [
        // 1 pm waist: far outside the paraxial regime.
        (
            GaussianBeam::new(632.8e-9, 1e-12, 0.0, 1.0, 1.0).unwrap(),
            -1e-6,
            1e-6,
            1e-9,
        ),
        // 1 km waist: effectively a plane wave.
        (
            GaussianBeam::new(632.8e-9, 1000.0, 0.0, 1.0, 1.0).unwrap(),
            -1000.0,
            1000.0,
            3000.0,
        ),
        // Soft X-ray and microwave wavelengths.
        (
            GaussianBeam::new(1e-9, 0.5e-3, 0.0, 1.0, 1.0).unwrap(),
            -0.1,
            0.1,
            1e-3,
        ),
        (
            GaussianBeam::new(1.0, 0.5e-3, 0.0, 1.0, 1.0).unwrap(),
            -0.1,
            0.1,
            1e-3,
        ),
    ];
    for (beam, z_min, z_max, x_max) in cases {
        let grid = longitudinal(&beam, &free_space(), &s, z_min, z_max, x_max, 64, 32);
        assert_unit_range(&grid);
        let t = IntensityGrid::evaluate_transverse(
            &beam,
            &free_space(),
            z_max,
            x_max,
            x_max,
            16,
            16,
            &s,
        )
        .unwrap();
        assert_unit_range(&t);
    }
}

#[test]
fn swapped_or_negative_bounds_give_the_same_image() {
    let beam = GaussianBeam::default();
    let s = RenderStyle::default();
    let reference = render(&beam, &free_space(), &s, -0.5, 1.0, 2e-3, 30, 20);
    assert_eq!(
        render(&beam, &free_space(), &s, 1.0, -0.5, 2e-3, 30, 20),
        reference
    );
    assert_eq!(
        render(&beam, &free_space(), &s, -0.5, 1.0, -2e-3, 30, 20),
        reference
    );
}

#[test]
fn degenerate_bounds_are_accepted() {
    let beam = GaussianBeam::default();
    let s = RenderStyle::default();

    // A single z: every column is the same.
    let (w, h) = (10, 8);
    let buf = render(&beam, &free_space(), &s, 0.3, 0.3, 2e-3, w, h);
    for row in 0..h {
        for col in 1..w {
            assert_eq!(pixel(&buf, w, col, row), pixel(&buf, w, 0, row));
        }
    }

    // A zero transverse extent is widened rather than rejected.
    render(&beam, &free_space(), &s, 0.0, 1.0, 0.0, w, h);
    let mut tbuf = vec![0u8; w * h * 4];
    render_transverse_rgba(&beam, &free_space(), &s, 0.0, 0.0, 0.0, w, h, &mut tbuf).unwrap();
}

#[test]
fn non_finite_bounds_are_rejected() {
    let beam = GaussianBeam::default();
    let s = RenderStyle::default();
    let mut buf = vec![0u8; 8 * 8 * 4];
    for (z_min, z_max, x_max) in [
        (f64::NAN, 1.0, 1e-3),
        (0.0, f64::INFINITY, 1e-3),
        (0.0, 1.0, f64::NAN),
    ] {
        let err = render_longitudinal_rgba(
            &beam,
            &free_space(),
            &s,
            z_min,
            z_max,
            x_max,
            8,
            8,
            &mut buf,
        )
        .unwrap_err();
        assert!(matches!(err, RenderError::InvalidBounds(_)), "{err:?}");
        assert!(IntensityGrid::evaluate_longitudinal(
            &beam,
            &free_space(),
            z_min,
            z_max,
            x_max,
            8,
            8,
            &s
        )
        .is_err());
    }
}

#[test]
fn single_pixel_image_is_the_peak_colour() {
    let beam = GaussianBeam::default();
    for cmap in Colormap::all() {
        let s = RenderStyle::new(cmap, 1.0);
        let buf = render(&beam, &free_space(), &s, -1.0, 1.0, 2e-3, 1, 1);
        assert_eq!(buf, map_colormap(cmap, 1.0, beam.wavelength));
    }
}

#[test]
fn single_row_and_single_column_images() {
    let beam = GaussianBeam::default();
    let s = RenderStyle::default();

    // A 1-pixel-tall image is the on-axis line.
    let line = longitudinal(&beam, &free_space(), &s, -2.0, 2.0, 1e-3, 10_000, 1);
    let zr = beam.rayleigh_range();
    let peak = line.data.iter().cloned().fold(0.0, f64::max);
    assert!((peak - 1.0).abs() < 1e-12);
    assert!(line
        .data
        .iter()
        .all(|v| *v > 1.0 / (1.0 + (2.0 / zr).powi(2)) - 1e-6));

    let column = longitudinal(&beam, &free_space(), &s, 0.0, 0.0, 5e-3, 1, 10_000);
    assert_unit_range(&column);
    assert!(column.data[0] < 1e-30 && column.data[5_000] > 0.99);
}

#[test]
fn invalid_sizes_are_rejected() {
    let beam = GaussianBeam::default();
    let s = RenderStyle::default();
    let max = MAX_DIMENSION as usize;
    let mut buf = vec![0u8; 64];

    for (w, h) in [(0, 4), (4, 0), (max + 1, 1), (1, max + 1)] {
        let err =
            render_longitudinal_rgba(&beam, &free_space(), &s, 0.0, 1.0, 1e-3, w, h, &mut buf)
                .unwrap_err();
        assert!(
            matches!(err, RenderError::InvalidDimensions { .. }),
            "{err:?}"
        );
        assert!(
            render_transverse_rgba(&beam, &free_space(), &s, 0.0, 1e-3, 1e-3, w, h, &mut buf)
                .is_err()
        );
        assert!(IntensityGrid::new(w, h).is_err());
    }

    let err = render_longitudinal_rgba(
        &beam,
        &free_space(),
        &s,
        0.0,
        1.0,
        1e-3,
        10,
        10,
        &mut vec![0u8; 399],
    )
    .unwrap_err();
    assert!(matches!(
        err,
        RenderError::BufferTooSmall {
            required: 400,
            provided: 399
        }
    ));

    assert_eq!(check_buffer_capacity(10, 10, 400).unwrap(), 400);
    assert!(check_buffer_capacity(max + 1, 1, usize::MAX).is_err());
    assert!(IntensityGrid::new(3, 2)
        .unwrap()
        .to_rgba(&s, 1e-6, &mut [0u8; 23])
        .is_err());
}

#[test]
fn oversized_buffer_tail_is_left_alone() {
    let beam = GaussianBeam::default();
    let s = RenderStyle::default();
    let (w, h) = (8, 4);
    let used = w * h * 4;
    let mut buf = vec![0xABu8; used + 37];
    render_longitudinal_rgba(&beam, &free_space(), &s, 0.0, 1.0, 1e-3, w, h, &mut buf).unwrap();
    assert_opaque(&buf[..used]);
    assert!(buf[used..].iter().all(|&b| b == 0xAB));
}

#[test]
fn max_dimension_is_accepted() {
    let beam = GaussianBeam::default();
    let s = RenderStyle::default();
    let w = MAX_DIMENSION as usize;
    let buf = render(&beam, &free_space(), &s, -1.0, 1.0, 1e-3, w, 2);
    assert_eq!(buf.len(), w * 2 * 4);
    let png = encode_png(&buf, MAX_DIMENSION, 2).unwrap();
    assert_eq!(decode_png(&png).dimensions(), (MAX_DIMENSION, 2));
}

#[test]
fn full_hd_render_with_fringes() {
    let beam = GaussianBeam::default();
    let mut train = OpticalTrain::new();
    train.add_element(0.4, lens(0.3));
    let (w, h) = (1920, 1080);
    let buf = render(
        &beam,
        &train,
        &style(Colormap::Turbo, 1.1, 0.5),
        -1.0,
        2.0,
        2.5e-3,
        w,
        h,
    );
    assert_eq!(buf.len(), w * h * 4);
    assert_opaque(&buf);
}

#[test]
fn grid_colouring_matches_direct_render() {
    let beam = GaussianBeam::new(532e-9, 0.4e-3, 0.0, 1.0, 1.0).unwrap();
    let s = style(Colormap::LaserGlow, 1.4, 0.5);
    let (w, h) = (50, 30);
    let grid = longitudinal(&beam, &free_space(), &s, -0.4, 0.6, 1.5e-3, w, h);
    let via_grid = grid.to_rgba_vec(&s, beam.wavelength).unwrap();
    assert_eq!(
        via_grid,
        render(&beam, &free_space(), &s, -0.4, 0.6, 1.5e-3, w, h)
    );
}

#[test]
fn slice_helpers_match_parallel_renderers() {
    let beam = GaussianBeam::default();
    let mut train = OpticalTrain::new();
    train.add_element(0.2, lens(0.25));
    let (w, h) = (37, 23);

    for cmap in Colormap::all() {
        let s = style(cmap, 1.7, 0.4);
        let cm = |t: f64| map_colormap(cmap, t, beam.wavelength);

        let slice =
            render_longitudinal_slice(&beam, &train, -0.2, 0.7, 2e-3, w, h, 1.7, 0.4, &cm).unwrap();
        assert_eq!(slice, render(&beam, &train, &s, -0.2, 0.7, 2e-3, w, h));

        let tslice =
            render_transverse_slice(&beam, &train, 0.5, 1e-3, 2e-3, w, h, 1.7, 0.4, &cm).unwrap();
        let mut tbuf = vec![0u8; w * h * 4];
        render_transverse_rgba(&beam, &train, &s, 0.5, 1e-3, 2e-3, w, h, &mut tbuf).unwrap();
        assert_eq!(tslice, tbuf);
    }
}

#[test]
fn slice_helpers_with_zero_width_return_empty() {
    let beam = GaussianBeam::default();
    let cm = |t: f64| colormap_viridis(t);
    let out = render_longitudinal_slice(&beam, &free_space(), 0.0, 1.0, 1e-3, 0, 5, 1.0, 0.0, &cm)
        .unwrap();
    assert!(out.is_empty());
    let out = render_transverse_slice(&beam, &free_space(), 0.0, 1e-3, 1e-3, 0, 5, 1.0, 0.0, &cm)
        .unwrap();
    assert!(out.is_empty());
}

#[test]
fn rendered_image_has_tonal_range() {
    let beam = GaussianBeam::default();
    let buf = render(
        &beam,
        &free_space(),
        &RenderStyle::default(),
        -1.0,
        2.0,
        2.5e-3,
        240,
        135,
    );
    let colours: HashSet<&[u8; 4]> = pixels(&buf).collect();
    assert!(colours.len() >= 50, "{} distinct colours", colours.len());
    let lums: Vec<f64> = pixels(&buf).map(|p| luminance(*p)).collect();
    let lo = lums.iter().cloned().fold(f64::MAX, f64::min);
    let hi = lums.iter().cloned().fold(f64::MIN, f64::max);
    assert!(hi - lo > 150.0);
}

#[test]
fn laser_glow_render_has_white_core_on_black() {
    let beam = GaussianBeam::new(532e-9, 0.3e-3, 0.0, 1.0, 5.0).unwrap();
    let (w, h) = (101, 101);
    let s = RenderStyle::new(Colormap::LaserGlow, 1.0);
    let buf = render(&beam, &free_space(), &s, -0.2, 0.2, 5.0 * beam.w0, w, h);
    assert_eq!(pixel(&buf, w, w / 2, h / 2), [255, 255, 255, 255]);
    assert_eq!(pixel(&buf, w, 0, 0), [0, 0, 0, 255]);
    let mid = pixel(&buf, w, w / 2, h / 2 - 15);
    assert!(mid[1] > mid[0] && mid[1] > mid[2], "532 nm wing {mid:?}");
}

#[test]
fn asympton_render_uses_the_palette() {
    let beam = GaussianBeam::default();
    let (w, h) = (101, 61);
    let s = RenderStyle::new(Colormap::Asympton, 1.6);
    let buf = render(&beam, &free_space(), &s, -0.3, 0.3, 4.0 * beam.w0, w, h);

    let carbon = asympton_tokens::CARBON_BLACK;
    assert_eq!(pixel(&buf, w, 0, 0), [carbon[0], carbon[1], carbon[2], 255]);
    let cream = asympton_tokens::HIGHLIGHT_CREAM;
    assert_eq!(
        pixel(&buf, w, w / 2, h / 2),
        [cream[0], cream[1], cream[2], 255]
    );
    let yellowish = pixels(&buf).any(|p| p[0] >= 240 && (190..=210).contains(&p[1]) && p[2] <= 60);
    assert!(yellowish, "no signal-yellow pixels");
}

#[test]
fn concurrent_renders_are_deterministic() {
    let beam = GaussianBeam::default();
    let mut train = OpticalTrain::new();
    train.add_element(0.3, lens(0.2));
    let s = style(Colormap::Plasma, 1.3, 0.5);
    let (w, h) = (48, 24);
    let expected = render(&beam, &train, &s, -0.5, 1.0, 1.5e-3, w, h);
    let mut expected_t = vec![0u8; w * h * 4];
    render_transverse_rgba(&beam, &train, &s, 0.6, 1e-3, 1e-3, w, h, &mut expected_t).unwrap();

    thread::scope(|scope| {
        for _ in 0..8 {
            scope.spawn(|| {
                let mut tbuf = vec![0u8; w * h * 4];
                for _ in 0..20 {
                    assert_eq!(render(&beam, &train, &s, -0.5, 1.0, 1.5e-3, w, h), expected);
                    render_transverse_rgba(&beam, &train, &s, 0.6, 1e-3, 1e-3, w, h, &mut tbuf)
                        .unwrap();
                    assert_eq!(tbuf, expected_t);
                }
            });
        }
    });
}

#[test]
fn colormaps_clamp_out_of_range_and_nan_input() {
    let wl = 632.8e-9;
    for cmap in Colormap::all() {
        let lo = map_colormap(cmap, 0.0, wl);
        let hi = map_colormap(cmap, 1.0, wl);
        for v in [-0.0001, -10.0, f64::NEG_INFINITY, f64::NAN] {
            assert_eq!(map_colormap(cmap, v, wl), lo, "{cmap:?} at {v}");
        }
        for v in [1.0001, 2.5, f64::INFINITY] {
            assert_eq!(map_colormap(cmap, v, wl), hi, "{cmap:?} at {v}");
        }
        for i in 0..=100 {
            assert_eq!(map_colormap(cmap, i as f64 / 100.0, wl)[3], 255);
        }
    }
}

#[test]
fn map_colormap_dispatches_to_each_palette() {
    let wl = 532e-9;
    for i in 0..=20 {
        let t = i as f64 / 20.0;
        assert_eq!(map_colormap(Colormap::Viridis, t, wl), colormap_viridis(t));
        assert_eq!(map_colormap(Colormap::Inferno, t, wl), colormap_inferno(t));
        assert_eq!(map_colormap(Colormap::Plasma, t, wl), colormap_plasma(t));
        assert_eq!(map_colormap(Colormap::Turbo, t, wl), colormap_turbo(t));
        assert_eq!(
            map_colormap(Colormap::Asympton, t, wl),
            colormap_asympton(t)
        );
        // The wavelength may be given in metres or nanometres.
        assert_eq!(
            map_colormap(Colormap::LaserGlow, t, wl),
            colormap_laser_glow(t, 532.0)
        );
        assert_eq!(
            map_colormap(Colormap::LaserGlow, t, 532.0),
            colormap_laser_glow(t, 532.0)
        );
    }
}

#[test]
fn viridis_brightens_monotonically() {
    let mut prev = f64::MIN;
    for i in 0..=100 {
        let lum = luminance(colormap_viridis(i as f64 / 100.0));
        assert!(lum >= prev - 0.5, "step {i}: {lum} < {prev}");
        prev = lum;
    }
    assert!(colormap_viridis(0.0)[0] < 100);
    let top = colormap_viridis(1.0);
    assert!(top[0] > 200 && top[1] > 200);
}

#[test]
fn inferno_runs_from_near_black_to_bright() {
    let lo = luminance(colormap_inferno(0.0));
    let hi = luminance(colormap_inferno(1.0));
    assert!(lo < 15.0);
    assert!(hi - lo > 220.0);
}

#[test]
fn plasma_midtones_are_saturated() {
    for i in 20..=80 {
        let [r, g, b, _] = colormap_plasma(i as f64 / 100.0);
        let spread = r.max(g).max(b) - r.min(g).min(b);
        assert!(spread >= 50, "t = {}: spread {spread}", i as f64 / 100.0);
    }
}

#[test]
fn turbo_hits_its_stops() {
    assert_eq!(colormap_turbo(0.0), [48, 18, 59, 255]);
    assert_eq!(colormap_turbo(0.25), [30, 203, 237, 255]);
    assert_eq!(colormap_turbo(0.5), [164, 252, 60, 255]);
    assert_eq!(colormap_turbo(0.75), [251, 184, 38, 255]);
    assert_eq!(colormap_turbo(1.0), [122, 4, 3, 255]);
}

#[test]
fn asympton_hits_its_stops() {
    let rgba = |c: [u8; 3]| [c[0], c[1], c[2], 255];
    assert_eq!(colormap_asympton(0.0), rgba(asympton_tokens::CARBON_BLACK));
    assert_eq!(colormap_asympton(0.5), rgba(asympton_tokens::MINERAL_SLATE));
    assert_eq!(
        colormap_asympton(0.85),
        rgba(asympton_tokens::SIGNAL_YELLOW)
    );
    assert_eq!(
        colormap_asympton(1.0),
        rgba(asympton_tokens::HIGHLIGHT_CREAM)
    );
}

#[test]
fn laser_glow_goes_black_to_beam_colour_to_white() {
    for nm in [193.0, 450.0, 532.0, 650.0, 1064.0] {
        assert_eq!(colormap_laser_glow(0.0, nm), [0, 0, 0, 255]);
        assert_eq!(colormap_laser_glow(1.0, nm), [255, 255, 255, 255]);
        let spectral = wavelength_to_rgb(nm);
        assert_eq!(
            colormap_laser_glow(0.75, nm),
            [spectral[0], spectral[1], spectral[2], 255]
        );
    }
    let green = colormap_laser_glow(0.5, 532.0);
    assert!(green[1] > green[0] && green[1] > green[2]);
    let uv = colormap_laser_glow(0.5, 193.0);
    assert!(uv[2] > uv[1]);
}

#[test]
fn wavelength_units_are_guessed() {
    assert!((wavelength_to_nm(632.8e-9) - 632.8).abs() < 1e-9);
    assert_eq!(wavelength_to_nm(532.0), 532.0);
    assert!((wavelength_to_nm(10.6e-6) - 10_600.0).abs() < 1e-6);
    for bad in [0.0, -1.0, f64::NAN] {
        assert_eq!(wavelength_to_nm(bad), 632.8);
    }
    // A 1 m microwave must not be mistaken for nanometres and drawn violet.
    assert_eq!(wavelength_to_nm(1.0), 1e9);
    assert_eq!(wavelength_to_rgb(1e9), [97, 0, 0]);
}

#[test]
fn spectral_colours_have_the_right_dominant_channel() {
    let dominant = |nm: f64| {
        let c = wavelength_to_rgb(nm);
        (0..3).max_by_key(|&i| c[i]).unwrap()
    };
    assert_eq!(dominant(450.0), 2);
    assert_eq!(dominant(532.0), 1);
    assert_eq!(dominant(650.0), 0);
    // Outside the visible band the edge colour is kept, dimmed.
    assert_eq!(wavelength_to_rgb(100.0), wavelength_to_rgb(300.0));
    assert!(wavelength_to_rgb(300.0)[2] < 255);
}

#[test]
fn colormap_names_round_trip() {
    for cmap in Colormap::all() {
        assert_eq!(cmap.name().parse::<Colormap>().unwrap(), cmap);
    }
    assert_eq!(
        " Laser-Glow ".parse::<Colormap>().unwrap(),
        Colormap::LaserGlow
    );
    assert_eq!("laser".parse::<Colormap>().unwrap(), Colormap::LaserGlow);
    assert!("magma".parse::<Colormap>().is_err());
}

#[test]
fn transfer_functions_fix_endpoints_and_are_monotonic() {
    let transfers = [
        TransferFunction::Linear,
        TransferFunction::Gamma(0.1),
        TransferFunction::Gamma(2.2),
        TransferFunction::Gamma(10.0),
        TransferFunction::Logarithmic {
            compression: 1000.0,
        },
        TransferFunction::Decibel {
            dynamic_range_db: 40.0,
        },
    ];
    for tf in transfers {
        assert_eq!(tf.apply(0.0), 0.0, "{tf:?}");
        assert_eq!(tf.apply(1.0), 1.0, "{tf:?}");
        assert_eq!(tf.apply(-3.0), 0.0);
        assert_eq!(tf.apply(f64::NAN), 0.0);
        assert_eq!(tf.apply(7.0), 1.0);
        let mut prev = 0.0;
        for i in 1..=1000 {
            let v = tf.apply(i as f64 / 1000.0);
            assert!((0.0..=1.0).contains(&v) && v >= prev, "{tf:?} at {i}");
            prev = v;
        }
    }
}

#[test]
fn transfer_function_values() {
    assert!((TransferFunction::Gamma(2.2).apply(0.5) - 0.5f64.powf(2.2)).abs() < 1e-15);
    let log = TransferFunction::Logarithmic {
        compression: 1000.0,
    }
    .apply(0.001);
    assert!((log - 2f64.ln() / 1001f64.ln()).abs() < 1e-12);
    let db = TransferFunction::Decibel {
        dynamic_range_db: 60.0,
    };
    assert!((db.apply(1e-3) - 0.5).abs() < 1e-12);
    assert_eq!(db.apply(1e-7), 0.0);

    // A faint 1% signal is lifted by low gamma and crushed by high gamma.
    assert!(TransferFunction::Gamma(0.1).apply(0.01) > 0.6);
    assert!(TransferFunction::Gamma(10.0).apply(0.01) < 1e-19);
}

#[test]
fn bad_transfer_parameters_fall_back_to_defaults() {
    let samples = [0.001, 0.2, 0.7];
    let same = |a: TransferFunction, b: TransferFunction| {
        for x in samples {
            assert_eq!(a.apply(x), b.apply(x), "{a:?} vs {b:?}");
        }
    };
    same(TransferFunction::Gamma(-1.0), TransferFunction::Linear);
    same(TransferFunction::Gamma(f64::NAN), TransferFunction::Linear);
    same(
        TransferFunction::Logarithmic { compression: 0.0 },
        TransferFunction::Logarithmic {
            compression: 1000.0,
        },
    );
    same(
        TransferFunction::Decibel {
            dynamic_range_db: f64::NAN,
        },
        TransferFunction::Decibel {
            dynamic_range_db: 60.0,
        },
    );
    assert_eq!(TransferFunction::from_gamma(1.0), TransferFunction::Linear);
    assert_eq!(
        TransferFunction::from_gamma(0.0),
        TransferFunction::Gamma(1.0)
    );
    assert_eq!(
        TransferFunction::from_gamma(2.0),
        TransferFunction::Gamma(2.0)
    );
}

#[test]
fn render_style_sanitises_inputs() {
    assert_eq!(RenderStyle::new(Colormap::Turbo, -2.0).gamma, 1.0);
    assert_eq!(RenderStyle::new(Colormap::Turbo, f64::NAN).gamma, 1.0);
    assert_eq!(
        RenderStyle::default()
            .with_wavefront(true, 3.0)
            .fringe_modulation,
        1.0
    );
    assert_eq!(
        RenderStyle::default()
            .with_wavefront(true, -1.0)
            .fringe_modulation,
        0.0
    );

    let s = RenderStyle::new(Colormap::Inferno, 2.0);
    assert_eq!(
        s.map_intensity(0.3, 632.8e-9),
        colormap_inferno(0.3f64.powf(2.0))
    );
}

#[test]
fn intensity_mapping_applies_transfer_before_colour() {
    let wl = 632.8e-9;
    for cmap in Colormap::all() {
        for i in 0..=10 {
            let x = i as f64 / 10.0;
            assert_eq!(
                map_intensity_to_rgba(x, 2.2, cmap, wl),
                map_colormap(cmap, x.powf(2.2), wl)
            );
            let tf = TransferFunction::Logarithmic { compression: 100.0 };
            assert_eq!(
                map_intensity_with_transfer(x, tf, cmap, wl),
                map_colormap(cmap, tf.apply(x), wl)
            );
        }
    }
}

#[test]
fn lookup_table_matches_direct_mapping() {
    let wl = 532e-9;
    for cmap in Colormap::all() {
        let lut = ColormapLut::with_gamma(cmap, wl, 1.8);
        for i in 0..=255u8 {
            let x = i as f64 / 255.0;
            let direct = map_intensity_to_rgba(x, 1.8, cmap, wl);
            assert_eq!(lut.lookup(x), direct);
            assert_eq!(lut.lookup_byte(i), direct);
            assert_eq!(lut.as_slice()[i as usize], direct);
        }
        assert_eq!(lut.lookup(-1.0), lut.lookup_byte(0));
        assert_eq!(lut.lookup(5.0), lut.lookup_byte(255));
    }
    assert_eq!(
        ColormapLut::new(Colormap::Plasma, wl),
        ColormapLut::with_transfer(Colormap::Plasma, wl, TransferFunction::Linear)
    );
}

fn gradient(width: usize, height: usize) -> Vec<u8> {
    let mut buf = Vec::with_capacity(width * height * 4);
    for y in 0..height {
        for x in 0..width {
            buf.extend_from_slice(&[(x % 256) as u8, (y % 256) as u8, 128, 255]);
        }
    }
    buf
}

#[test]
fn encode_png_round_trips_pixels() {
    for (w, h) in [(1usize, 1usize), (400, 300), (37, 1)] {
        let buf = gradient(w, h);
        let png = encode_png(&buf, w as u32, h as u32).unwrap();
        assert_eq!(&png[..8], PNG_SIGNATURE);
        assert_eq!(&png[8..16], b"\0\0\0\x0dIHDR");
        let img = decode_png(&png);
        assert_eq!(img.dimensions(), (w as u32, h as u32));
        assert_eq!(img.into_raw(), buf);
        if w * h > 1000 {
            assert!(png.len() < buf.len(), "PNG not compressed");
        }
    }
}

#[test]
fn encode_png_rejects_bad_input() {
    let buf = vec![0u8; 16];
    for (w, h) in [(0, 4), (4, 0), (0, 0), (MAX_DIMENSION + 1, 1)] {
        assert!(matches!(
            encode_png(&buf, w, h),
            Err(RenderError::InvalidDimensions { .. })
        ));
    }
    for len in [15, 17, 0] {
        assert!(matches!(
            encode_png(&vec![0u8; len], 2, 2),
            Err(RenderError::BufferLengthMismatch { expected: 16, .. })
        ));
    }
}

#[test]
fn export_png_file_writes_a_decodable_file() {
    let dir = TempDir::new("export");
    let path = dir.join("nested/deeper/cover.png");
    let buf = gradient(64, 32);
    export_png_file(&path, &buf, 64, 32).unwrap();

    let bytes = fs::read(&path).unwrap();
    assert_eq!(&bytes[..8], PNG_SIGNATURE);
    assert_eq!(decode_png(&bytes).into_raw(), buf);
    assert!(!dir.join("nested/deeper/cover.png.tmp").exists());
}

#[test]
fn export_png_file_overwrites_existing_file() {
    let dir = TempDir::new("overwrite");
    let path = dir.join("cover.png");
    export_png_file(&path, &[255u8; 16], 2, 2).unwrap();
    let second = [0u8, 128, 255, 255];
    export_png_file(&path, &second, 1, 1).unwrap();
    let img = decode_png(&fs::read(&path).unwrap());
    assert_eq!(img.dimensions(), (1, 1));
    assert_eq!(img.into_raw(), second);
}

#[test]
fn failed_export_leaves_nothing_behind() {
    let dir = TempDir::new("failed");

    // A bad buffer is caught before anything touches the disk.
    let path = dir.join("sub/cover.png");
    assert!(matches!(
        export_png_file(&path, &[0u8; 15], 2, 2),
        Err(RenderError::BufferLengthMismatch { .. })
    ));
    assert!(!dir.join("sub").exists());

    // A parent that is a regular file makes the write itself fail.
    let blocker = dir.join("blocker");
    fs::write(&blocker, b"not a directory").unwrap();
    let path = blocker.join("cover.png");
    let err = export_png_file(&path, &[0u8; 16], 2, 2).unwrap_err();
    assert!(matches!(err, RenderError::Io(_)), "{err:?}");
    assert!(std::error::Error::source(&err).is_some());
    assert_eq!(fs::read_dir(&dir.0).unwrap().count(), 1);

    // The previous file survives a failed overwrite.
    let good = dir.join("good.png");
    export_png_file(&good, &[7u8; 16], 2, 2).unwrap();
    let before = fs::read(&good).unwrap();
    assert!(export_png_file(&good, &[7u8; 3], 2, 2).is_err());
    assert_eq!(fs::read(&good).unwrap(), before);
}

#[test]
fn export_beam_matches_in_memory_render() {
    let dir = TempDir::new("beam");
    let beam = GaussianBeam::new(532e-9, 0.4e-3, 0.0, 1.0, 3.5).unwrap();
    let mut train = OpticalTrain::new();
    train.add_element(0.15, lens(0.15));
    train.add_element(0.35, interface(1.0, 1.5, None));
    train.add_element(0.50, OpticalElement::GaussianAperture { radius: 0.35e-3 });
    let s = style(Colormap::Viridis, 1.1, 0.35);
    let (w, h) = (320u32, 240u32);

    let path = dir.join("cover.png");
    export_beam_to_png_file(&path, &beam, &train, &s, 0.0, 0.7, 1.2e-3, w, h).unwrap();
    let img = decode_png(&fs::read(&path).unwrap());
    assert_eq!(img.dimensions(), (w, h));
    let expected = render(&beam, &train, &s, 0.0, 0.7, 1.2e-3, w as usize, h as usize);
    assert_eq!(img.into_raw(), expected);
}

#[test]
fn export_beam_rejects_oversized_images_without_writing() {
    let dir = TempDir::new("oversized");
    let path = dir.join("too_big.png");
    let beam = GaussianBeam::default();
    let s = RenderStyle::default();
    for (w, h) in [(MAX_DIMENSION + 1, 100), (100, MAX_DIMENSION + 1), (0, 10)] {
        let err = export_beam_to_png_file(&path, &beam, &free_space(), &s, -0.1, 0.1, 1e-3, w, h)
            .unwrap_err();
        assert!(matches!(err, RenderError::InvalidDimensions { .. }));
    }
    assert!(!Path::new(&path).exists());
}

#[test]
fn render_errors_have_readable_messages() {
    let err = encode_png(&[], 0, 3).unwrap_err();
    assert_eq!(err.to_string(), "invalid image size 0x3");
    let err = encode_png(&[0u8; 3], 1, 1).unwrap_err();
    assert_eq!(
        err.to_string(),
        "buffer length mismatch: expected 4 bytes, got 3"
    );
}
