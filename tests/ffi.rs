//! The C ABI, called directly from Rust the way the Swift app calls it.

use std::f64::consts::{FRAC_PI_2, FRAC_PI_4, PI, SQRT_2};
use std::ffi::CString;
use std::mem::size_of;
use std::path::{Path, PathBuf};
use std::ptr;
use std::sync::atomic::{AtomicUsize, Ordering};

use beam_core::ffi::{
    beam_calc_curvature_at_z, beam_calc_gouy_phase, beam_calc_rayleigh_range, beam_calc_waist_at_z,
    beam_export_png_file, beam_render_longitudinal_rgba, CBeamParams, CColormap,
    COpticalElementType, CPlacedElement, CRenderStyle, MAX_DIMENSION,
};
use beam_core::physics::{GaussianBeam, OpticalTrain};
use beam_core::render::colormap::{Colormap, RenderStyle};
use beam_core::render::grid::render_longitudinal_rgba;

const HENE: f64 = 632.8e-9;
const W0: f64 = 0.5e-3;

fn close(a: f64, b: f64, rel: f64) -> bool {
    (a - b).abs() <= rel * a.abs().max(b.abs())
}

fn element(z: f64, element_type: COpticalElementType, param1: f64, param2: f64) -> CPlacedElement {
    CPlacedElement {
        z,
        element_type,
        param1,
        param2,
    }
}

/// Inputs to one render call; tweak a field and call `render`.
#[derive(Clone)]
struct Scene {
    beam: CBeamParams,
    elements: Vec<CPlacedElement>,
    style: CRenderStyle,
    z_min: f64,
    z_max: f64,
    x_max: f64,
    width: u32,
    height: u32,
}

impl Default for Scene {
    fn default() -> Self {
        Self {
            beam: CBeamParams::default(),
            elements: Vec::new(),
            style: CRenderStyle::default(),
            z_min: -0.5,
            z_max: 0.5,
            x_max: 1.5e-3,
            width: 32,
            height: 16,
        }
    }
}

impl Scene {
    fn byte_len(&self) -> usize {
        self.width as usize * self.height as usize * 4
    }

    /// Renders into `buf`, passing `buf.len()` as the buffer length.
    fn render_into(&self, buf: &mut [u8]) -> bool {
        unsafe { self.render_raw(buf.as_mut_ptr(), buf.len() as u32) }
    }

    unsafe fn render_raw(&self, out: *mut u8, len: u32) -> bool {
        self.render_with(
            self.elements.as_ptr(),
            self.elements.len() as u32,
            &self.style,
            out,
            len,
        )
    }

    unsafe fn render_with(
        &self,
        elements: *const CPlacedElement,
        count: u32,
        style: *const CRenderStyle,
        out: *mut u8,
        len: u32,
    ) -> bool {
        beam_render_longitudinal_rgba(
            &self.beam,
            elements,
            count,
            style,
            self.z_min,
            self.z_max,
            self.x_max,
            self.width,
            self.height,
            out,
            len,
        )
    }

    fn render(&self) -> Option<Vec<u8>> {
        let mut buf = vec![0u8; self.byte_len()];
        self.render_into(&mut buf).then_some(buf)
    }

    fn export(&self, path: &Path) -> bool {
        let c_path = CString::new(path.to_str().unwrap()).unwrap();
        unsafe { self.export_raw(c_path.as_ptr()) }
    }

    unsafe fn export_raw(&self, path: *const std::os::raw::c_char) -> bool {
        beam_export_png_file(
            path,
            &self.beam,
            self.elements.as_ptr(),
            self.elements.len() as u32,
            &self.style,
            self.z_min,
            self.z_max,
            self.x_max,
            self.width,
            self.height,
        )
    }
}

/// A unique directory under the system temp dir, removed on drop.
struct TempDir(PathBuf);

impl TempDir {
    fn new() -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let dir = std::env::temp_dir().join(format!(
            "beam-ffi-test-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&dir).unwrap();
        Self(dir)
    }

    fn join(&self, name: &str) -> PathBuf {
        self.0.join(name)
    }

    fn entries(&self) -> Vec<String> {
        let mut names: Vec<String> = std::fs::read_dir(&self.0)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        names
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn rayleigh_range_matches_formula() {
    let z_r = beam_calc_rayleigh_range(W0, HENE, 1.0);
    assert!(close(z_r, PI * W0 * W0 / HENE, 1e-14));
    assert!(close(z_r, 1.2411, 1e-4), "z_R = {z_r}");

    // In a medium the wavelength shrinks by n, so z_R grows by n.
    let in_glass = beam_calc_rayleigh_range(W0, HENE, 1.5);
    assert!(close(in_glass, 1.5 * z_r, 1e-14));
}

#[test]
fn rayleigh_range_returns_zero_on_invalid_input() {
    let bad = [0.0, -1e-3, f64::NAN, f64::INFINITY, f64::NEG_INFINITY];
    for &v in &bad {
        assert_eq!(beam_calc_rayleigh_range(v, HENE, 1.0), 0.0, "w0 = {v}");
        assert_eq!(
            beam_calc_rayleigh_range(W0, v, 1.0),
            0.0,
            "wavelength = {v}"
        );
        assert_eq!(beam_calc_rayleigh_range(W0, HENE, v), 0.0, "n = {v}");
    }
    assert_eq!(beam_calc_rayleigh_range(W0, HENE, 0.999), 0.0);
}

#[test]
fn waist_grows_by_sqrt2_at_rayleigh_range() {
    let z_r = beam_calc_rayleigh_range(W0, HENE, 1.0);
    assert_eq!(beam_calc_waist_at_z(W0, 0.0, z_r), W0);
    assert!(close(
        beam_calc_waist_at_z(W0, z_r, z_r),
        SQRT_2 * W0,
        1e-14
    ));
    assert!(close(
        beam_calc_waist_at_z(W0, -z_r, z_r),
        SQRT_2 * W0,
        1e-14
    ));
}

#[test]
fn waist_approaches_linear_far_field() {
    let z_r = 1.0;
    let z = 1e4;
    let w = beam_calc_waist_at_z(W0, z, z_r);
    // w = w0 z/z_R √(1 + (z_R/z)²), so the relative excess is ~ (z_R/z)²/2.
    assert!(close(w, W0 * z / z_r, 1e-8));
    assert!(w > W0 * z / z_r);
}

#[test]
fn waist_at_z_returns_zero_on_invalid_input() {
    assert_eq!(beam_calc_waist_at_z(W0, 0.1, 0.0), 0.0);
    assert_eq!(beam_calc_waist_at_z(W0, 0.1, -1.0), 0.0);
    assert_eq!(beam_calc_waist_at_z(W0, 0.1, f64::NAN), 0.0);
    assert_eq!(beam_calc_waist_at_z(W0, 0.1, f64::INFINITY), 0.0);
    assert_eq!(beam_calc_waist_at_z(-W0, 0.1, 1.0), 0.0);
    assert_eq!(beam_calc_waist_at_z(f64::NAN, 0.1, 1.0), 0.0);
    assert_eq!(beam_calc_waist_at_z(W0, f64::NAN, 1.0), 0.0);
    assert_eq!(beam_calc_waist_at_z(W0, f64::INFINITY, 1.0), 0.0);
    // A zero waist is degenerate but not invalid.
    assert_eq!(beam_calc_waist_at_z(0.0, 0.1, 1.0), 0.0);
}

#[test]
fn curvature_is_flat_at_waist_and_peaks_at_rayleigh_range() {
    let z_r = beam_calc_rayleigh_range(W0, HENE, 1.0);
    assert_eq!(beam_calc_curvature_at_z(0.0, z_r), 0.0);

    let peak = beam_calc_curvature_at_z(z_r, z_r);
    assert!(close(peak, 1.0 / (2.0 * z_r), 1e-14));
    for &f in &[0.5, 0.9, 1.1, 2.0, 10.0] {
        assert!(beam_calc_curvature_at_z(f * z_r, z_r) < peak, "z = {f} z_R");
    }

    assert_eq!(
        beam_calc_curvature_at_z(-z_r, z_r),
        -beam_calc_curvature_at_z(z_r, z_r)
    );
    // Far from the waist the wavefront is a sphere centred on the waist.
    assert!(close(beam_calc_curvature_at_z(1e4, 1.0), 1e-4, 1e-8));
}

#[test]
fn curvature_returns_zero_on_invalid_input() {
    assert_eq!(beam_calc_curvature_at_z(0.5, 0.0), 0.0);
    assert_eq!(beam_calc_curvature_at_z(0.5, -1.0), 0.0);
    assert_eq!(beam_calc_curvature_at_z(0.5, f64::NAN), 0.0);
    assert_eq!(beam_calc_curvature_at_z(f64::NAN, 1.0), 0.0);
    assert_eq!(beam_calc_curvature_at_z(f64::INFINITY, 1.0), 0.0);
}

#[test]
fn gouy_phase_is_quarter_pi_at_rayleigh_range() {
    let z_r = beam_calc_rayleigh_range(W0, HENE, 1.0);
    assert_eq!(beam_calc_gouy_phase(0.0, z_r), 0.0);
    assert!(close(beam_calc_gouy_phase(z_r, z_r), FRAC_PI_4, 1e-14));
    assert!(close(beam_calc_gouy_phase(-z_r, z_r), -FRAC_PI_4, 1e-14));

    let far = beam_calc_gouy_phase(1e9 * z_r, z_r);
    assert!(far < FRAC_PI_2 && close(far, FRAC_PI_2, 1e-8));
}

#[test]
fn gouy_phase_returns_zero_on_invalid_input() {
    assert_eq!(beam_calc_gouy_phase(0.5, 0.0), 0.0);
    assert_eq!(beam_calc_gouy_phase(0.5, -1.0), 0.0);
    assert_eq!(beam_calc_gouy_phase(0.5, f64::NAN), 0.0);
    assert_eq!(beam_calc_gouy_phase(f64::NAN, 1.0), 0.0);
    assert_eq!(beam_calc_gouy_phase(f64::NEG_INFINITY, 1.0), 0.0);
}

#[test]
fn analytic_queries_agree_with_gaussian_beam() {
    for &(lambda, w0, n) in &[
        (HENE, W0, 1.0),
        (1064e-9, 20e-6, 1.45),
        (10.6e-6, 3e-3, 1.0),
    ] {
        let beam = GaussianBeam::new(lambda, w0, 0.0, n, 1.0).unwrap();
        let z_r = beam_calc_rayleigh_range(w0, lambda, n);
        assert!(close(z_r, beam.rayleigh_range(), 1e-12));

        for &f in &[-3.0, -1.0, -0.25, 0.25, 1.0, 3.0] {
            let z = f * z_r;
            assert!(close(
                beam_calc_waist_at_z(w0, z, z_r),
                beam.waist_at(z),
                1e-12
            ));
            assert!(close(
                beam_calc_gouy_phase(z, z_r),
                beam.gouy_phase(z),
                1e-12
            ));
            let r = beam.radius_of_curvature(z).unwrap();
            assert!(close(beam_calc_curvature_at_z(z, z_r), 1.0 / r, 1e-12));
        }
    }
}

#[test]
fn render_fills_buffer_with_opaque_pixels() {
    let buf = Scene::default().render().expect("render should succeed");
    assert!(buf.as_chunks::<4>().0.iter().all(|px| px[3] == 255));
    assert!(
        buf.as_chunks::<4>().0.iter().any(|px| px[..3] != buf[..3]),
        "image is flat"
    );
}

#[test]
fn render_matches_native_renderer() {
    let scene = Scene {
        style: CRenderStyle {
            colormap: CColormap::Inferno,
            gamma: 0.8,
            show_wavefront_composite: true,
            fringe_modulation: 0.4,
        },
        elements: vec![element(0.1, COpticalElementType::ThinLens, 0.2, 0.0)],
        ..Scene::default()
    };
    let via_ffi = scene.render().unwrap();

    let beam = GaussianBeam::default();
    let mut train = OpticalTrain::new();
    train.add_element(
        0.1,
        beam_core::physics::OpticalElement::ThinLens { focal_length: 0.2 },
    );
    let style = RenderStyle::new(Colormap::Inferno, 0.8).with_wavefront(true, 0.4);
    let mut native = vec![0u8; scene.byte_len()];
    render_longitudinal_rgba(
        &beam,
        &train,
        &style,
        -0.5,
        0.5,
        1.5e-3,
        32,
        16,
        &mut native,
    )
    .unwrap();

    assert_eq!(via_ffi, native);
}

#[test]
fn render_is_deterministic() {
    let scene = Scene::default();
    assert_eq!(scene.render(), scene.render());
}

#[test]
fn render_accepts_reversed_z_range() {
    let scene = Scene::default();
    let mut reversed = scene.clone();
    reversed.z_min = scene.z_max;
    reversed.z_max = scene.z_min;
    assert_eq!(reversed.render(), scene.render());
}

#[test]
fn render_rejects_null_pointers() {
    let scene = Scene::default();
    let mut buf = vec![0u8; scene.byte_len()];
    let len = buf.len() as u32;
    unsafe {
        assert!(!scene.render_raw(ptr::null_mut(), len));
        assert!(!scene.render_with(ptr::null(), 0, ptr::null(), buf.as_mut_ptr(), len));
        assert!(!scene.render_with(ptr::null(), 3, &scene.style, buf.as_mut_ptr(), len));
        assert!(!beam_render_longitudinal_rgba(
            ptr::null(),
            ptr::null(),
            0,
            &scene.style,
            -0.5,
            0.5,
            1e-3,
            scene.width,
            scene.height,
            buf.as_mut_ptr(),
            len,
        ));
        // A null element list is fine when the count is zero.
        assert!(scene.render_with(ptr::null(), 0, &scene.style, buf.as_mut_ptr(), len));
    }
}

#[test]
fn render_rejects_short_buffer_without_writing() {
    let scene = Scene::default();
    let mut buf = vec![7u8; scene.byte_len()];
    for len in [0, 1, scene.byte_len() - 1] {
        assert!(!unsafe { scene.render_raw(buf.as_mut_ptr(), len as u32) });
        assert!(buf.iter().all(|&b| b == 7), "wrote with len {len}");
    }

    // 1920x1080 asked for, 1 KiB given.
    let mut big = scene.clone();
    big.width = 1920;
    big.height = 1080;
    let mut small = vec![0u8; 1024];
    assert!(!big.render_into(&mut small));
}

#[test]
fn render_writes_only_the_image_into_a_larger_buffer() {
    let scene = Scene::default();
    let n = scene.byte_len();
    let mut buf = vec![0xAAu8; n + 64];
    assert!(scene.render_into(&mut buf));
    assert_eq!(&buf[..n], &scene.render().unwrap()[..]);
    assert!(buf[n..].iter().all(|&b| b == 0xAA));
}

#[test]
fn render_handles_unaligned_buffer() {
    let scene = Scene::default();
    let n = scene.byte_len();
    let mut raw = vec![0x55u8; n + 2];
    assert!(unsafe { scene.render_raw(raw.as_mut_ptr().add(1), n as u32) });
    assert_eq!(raw[0], 0x55);
    assert_eq!(raw[n + 1], 0x55);
    assert_eq!(&raw[1..=n], &scene.render().unwrap()[..]);
}

#[test]
fn render_rejects_bad_dimensions() {
    let mut buf = vec![0u8; 64];
    for (w, h) in [
        (0, 16),
        (16, 0),
        (MAX_DIMENSION + 1, 1),
        (1, MAX_DIMENSION + 1),
        (u32::MAX, 1),
        (u32::MAX, u32::MAX),
    ] {
        let scene = Scene {
            width: w,
            height: h,
            ..Scene::default()
        };
        assert!(!scene.render_into(&mut buf), "{w}x{h}");
    }
}

#[test]
fn render_accepts_one_pixel_and_extreme_aspect_ratios() {
    for (w, h) in [(1, 1), (4096, 1), (1, 4096)] {
        let scene = Scene {
            width: w,
            height: h,
            ..Scene::default()
        };
        let buf = scene.render().unwrap_or_else(|| panic!("{w}x{h} failed"));
        assert!(buf.as_chunks::<4>().0.iter().all(|px| px[3] == 255));
    }
}

#[test]
fn render_rejects_invalid_beam() {
    let base = CBeamParams::default();
    let bad = [
        CBeamParams {
            wavelength: 0.0,
            ..base
        },
        CBeamParams {
            wavelength: -HENE,
            ..base
        },
        CBeamParams {
            wavelength: f64::NAN,
            ..base
        },
        CBeamParams { w0: 0.0, ..base },
        CBeamParams {
            w0: f64::INFINITY,
            ..base
        },
        CBeamParams {
            z0: f64::NAN,
            ..base
        },
        CBeamParams {
            refractive_index: 0.5,
            ..base
        },
        CBeamParams {
            power: -1.0,
            ..base
        },
        CBeamParams {
            power: f64::NAN,
            ..base
        },
    ];
    for beam in bad {
        let scene = Scene {
            beam,
            ..Scene::default()
        };
        assert!(scene.render().is_none(), "{beam:?}");
    }
}

#[test]
fn render_rejects_non_finite_bounds() {
    let base = Scene::default();
    let bad = [
        Scene {
            z_min: f64::NAN,
            ..base.clone()
        },
        Scene {
            z_max: f64::INFINITY,
            ..base.clone()
        },
        Scene {
            z_min: f64::NEG_INFINITY,
            ..base.clone()
        },
        Scene {
            x_max: f64::NAN,
            ..base.clone()
        },
        Scene {
            x_max: 0.0,
            ..base.clone()
        },
        Scene {
            x_max: -1e-3,
            ..base.clone()
        },
    ];
    for scene in bad {
        assert!(
            scene.render().is_none(),
            "z {}..{} x {}",
            scene.z_min,
            scene.z_max,
            scene.x_max
        );
    }
}

#[test]
fn render_rejects_invalid_style() {
    let base = CRenderStyle::default();
    for style in [
        CRenderStyle {
            gamma: f64::NAN,
            ..base
        },
        CRenderStyle {
            gamma: -1.0,
            ..base
        },
        CRenderStyle {
            gamma: f64::INFINITY,
            ..base
        },
        CRenderStyle {
            fringe_modulation: f64::NAN,
            ..base
        },
    ] {
        let scene = Scene {
            style,
            ..Scene::default()
        };
        assert!(scene.render().is_none(), "{style:?}");
    }
}

#[test]
fn render_rejects_out_of_range_colormap() {
    let scene = Scene::default();
    let mut buf = vec![0u8; scene.byte_len()];
    for discriminant in [6u32, 99, u32::MAX] {
        // C can pass any integer here; u64 storage keeps the struct aligned.
        let mut raw = [0u64; size_of::<CRenderStyle>() / 8];
        unsafe {
            ptr::copy_nonoverlapping(&scene.style, raw.as_mut_ptr().cast(), 1);
            raw.as_mut_ptr().cast::<u32>().write(discriminant);
            let style = raw.as_ptr().cast::<CRenderStyle>();
            assert!(!scene.render_with(ptr::null(), 0, style, buf.as_mut_ptr(), buf.len() as u32));
        }
    }
}

#[test]
fn render_rejects_out_of_range_element_type() {
    let scene = Scene::default();
    let mut buf = vec![0u8; scene.byte_len()];
    let mut raw = [0u64; size_of::<CPlacedElement>() / 8];
    let good = element(0.1, COpticalElementType::ThinLens, 0.2, 0.0);
    unsafe {
        ptr::copy_nonoverlapping(&good, raw.as_mut_ptr().cast(), 1);
        raw.as_mut_ptr().add(1).cast::<u32>().write(5);
        let elements = raw.as_ptr().cast::<CPlacedElement>();
        assert!(!scene.render_with(
            elements,
            1,
            &scene.style,
            buf.as_mut_ptr(),
            buf.len() as u32
        ));
    }
}

#[test]
fn render_rejects_invalid_element_parameters() {
    use COpticalElementType::*;
    let bad = [
        element(f64::NAN, FlatMirror, 0.0, 0.0),
        element(f64::INFINITY, ThinLens, 0.1, 0.0),
        element(0.1, ThinLens, 0.0, 0.0),
        element(0.1, ThinLens, f64::NAN, 0.0),
        element(0.1, CurvedMirror, 0.0, 0.0),
        element(0.1, CurvedMirror, f64::INFINITY, 0.0),
        element(0.1, DielectricInterface, 0.5, 1.5),
        element(0.1, DielectricInterface, 1.0, f64::NAN),
        element(0.1, GaussianAperture, 0.0, 0.0),
        element(0.1, GaussianAperture, -1e-3, 0.0),
    ];
    for e in bad {
        let scene = Scene {
            elements: vec![e],
            ..Scene::default()
        };
        assert!(scene.render().is_none(), "{e:?}");
    }

    // One bad element anywhere in the train is enough.
    let mut elements = vec![element(0.1, FlatMirror, 0.0, 0.0); 10];
    elements[7] = element(0.2, ThinLens, 0.0, 0.0);
    assert!(Scene {
        elements,
        ..Scene::default()
    }
    .render()
    .is_none());
}

#[test]
fn infinite_focal_length_lens_is_a_flat_plate() {
    let plain = Scene::default();
    for f in [f64::INFINITY, f64::NEG_INFINITY] {
        let with_plate = Scene {
            elements: vec![element(0.2, COpticalElementType::ThinLens, f, 0.0)],
            ..Scene::default()
        };
        assert_eq!(with_plate.render(), plain.render(), "f = {f}");
    }
}

#[test]
fn render_supports_every_colormap_and_element_type() {
    use COpticalElementType::*;
    let elements = vec![
        element(-0.3, GaussianAperture, 1.2e-3, 0.0),
        element(-0.1, ThinLens, 0.15, 0.0),
        element(0.05, DielectricInterface, 1.0, 1.5),
        element(0.15, DielectricInterface, 1.5, 1.0),
        element(0.25, CurvedMirror, -0.5, 0.0),
        element(0.35, FlatMirror, 0.0, 0.0),
    ];
    let mut images = Vec::new();
    for colormap in [
        CColormap::Viridis,
        CColormap::Inferno,
        CColormap::Plasma,
        CColormap::Turbo,
        CColormap::LaserGlow,
        CColormap::Asympton,
    ] {
        let scene = Scene {
            elements: elements.clone(),
            style: CRenderStyle {
                colormap,
                gamma: 2.2,
                show_wavefront_composite: true,
                fringe_modulation: 0.6,
            },
            ..Scene::default()
        };
        images.push(
            scene
                .render()
                .unwrap_or_else(|| panic!("{colormap:?} failed")),
        );
    }
    for (i, a) in images.iter().enumerate() {
        for b in &images[i + 1..] {
            assert_ne!(a, b, "two colormaps rendered identically");
        }
    }
}

#[test]
fn render_handles_long_element_train() {
    use COpticalElementType::*;
    let elements: Vec<_> = (1..=200)
        .map(|i| {
            let z = i as f64 * 0.01;
            match i % 5 {
                0 => element(z, ThinLens, 0.15, 0.0),
                1 => element(z, CurvedMirror, 0.5, 0.0),
                2 => element(z, DielectricInterface, 1.0, 1.5),
                3 => element(z, DielectricInterface, 1.5, 1.0),
                _ => element(z, GaussianAperture, 1.2e-3, 0.0),
            }
        })
        .collect();
    let scene = Scene {
        elements,
        z_min: 0.0,
        z_max: 2.0,
        x_max: 2e-3,
        width: 100,
        height: 50,
        ..Scene::default()
    };
    let buf = scene.render().expect("200-element train should render");
    assert!(buf.as_chunks::<4>().0.iter().all(|px| px[3] == 255));
}

#[test]
fn render_handles_extreme_beams() {
    let cases = [
        // 1 pm waist: z_R ~ 5e-18 m, far outside paraxial validity.
        (
            CBeamParams {
                w0: 1e-12,
                ..CBeamParams::default()
            },
            -1e-6,
            1e-6,
            1e-9,
        ),
        // 1 km waist: effectively a plane wave over the window.
        (
            CBeamParams {
                w0: 1000.0,
                ..CBeamParams::default()
            },
            -1000.0,
            1000.0,
            3000.0,
        ),
        // 1 nm soft X-ray with heavy fringes.
        (
            CBeamParams {
                wavelength: 1e-9,
                ..CBeamParams::default()
            },
            -0.1,
            0.1,
            1e-3,
        ),
        // 1 m microwave.
        (
            CBeamParams {
                wavelength: 1.0,
                ..CBeamParams::default()
            },
            -0.1,
            0.1,
            1e-3,
        ),
        // Zero power.
        (
            CBeamParams {
                power: 0.0,
                ..CBeamParams::default()
            },
            -0.5,
            0.5,
            1e-3,
        ),
    ];
    for (beam, z_min, z_max, x_max) in cases {
        let scene = Scene {
            beam,
            z_min,
            z_max,
            x_max,
            style: CRenderStyle {
                show_wavefront_composite: true,
                fringe_modulation: 0.9,
                ..CRenderStyle::default()
            },
            ..Scene::default()
        };
        let buf = scene.render().unwrap_or_else(|| panic!("{beam:?} failed"));
        assert!(
            buf.as_chunks::<4>().0.iter().all(|px| px[3] == 255),
            "{beam:?}"
        );
    }
}

#[test]
fn export_writes_png_matching_render() {
    let dir = TempDir::new();
    let path = dir.join("beam.png");
    let scene = Scene {
        elements: vec![element(0.2, COpticalElementType::ThinLens, 0.1, 0.0)],
        style: CRenderStyle {
            colormap: CColormap::Asympton,
            ..CRenderStyle::default()
        },
        width: 48,
        height: 24,
        ..Scene::default()
    };
    assert!(scene.export(&path));

    let bytes = std::fs::read(&path).unwrap();
    assert_eq!(&bytes[..8], b"\x89PNG\r\n\x1a\n");
    let img = image::load_from_memory(&bytes).unwrap().to_rgba8();
    assert_eq!(img.dimensions(), (48, 24));
    assert_eq!(img.into_raw(), scene.render().unwrap());
    assert_eq!(dir.entries(), ["beam.png"], "temp file left behind");
}

#[test]
fn export_creates_missing_parent_directories() {
    let dir = TempDir::new();
    let path = dir.join("a/b/c/beam.png");
    assert!(Scene::default().export(&path));
    assert!(path.is_file());
}

#[test]
fn export_overwrites_existing_file() {
    let dir = TempDir::new();
    let path = dir.join("beam.png");
    std::fs::write(&path, b"stale").unwrap();
    assert!(Scene::default().export(&path));
    let bytes = std::fs::read(&path).unwrap();
    assert!(image::load_from_memory(&bytes).is_ok());
}

#[test]
fn export_rejects_bad_paths() {
    let dir = TempDir::new();
    let scene = Scene::default();
    unsafe {
        assert!(!scene.export_raw(ptr::null()));
        for s in [&b""[..], b"   ", b"\xff\xfe.png"] {
            let c = CString::new(s).unwrap();
            assert!(!scene.export_raw(c.as_ptr()), "{s:?}");
        }
    }

    // The target is an existing directory.
    assert!(!scene.export(&dir.0));

    // A parent component is a regular file.
    std::fs::write(dir.join("file"), b"x").unwrap();
    assert!(!scene.export(&dir.join("file/beam.png")));
    assert_eq!(dir.entries(), ["file"]);
}

#[test]
fn export_rejects_invalid_input_without_creating_a_file() {
    let dir = TempDir::new();
    let path = dir.join("beam.png");
    let base = Scene::default();
    let bad = [
        Scene {
            width: 0,
            ..base.clone()
        },
        Scene {
            height: 0,
            ..base.clone()
        },
        Scene {
            width: MAX_DIMENSION + 1,
            ..base.clone()
        },
        Scene {
            height: MAX_DIMENSION + 1,
            ..base.clone()
        },
        Scene {
            width: u32::MAX,
            ..base.clone()
        },
        Scene {
            width: u32::MAX / 2,
            height: 2,
            ..base.clone()
        },
        Scene {
            beam: CBeamParams {
                w0: 0.0,
                ..base.beam
            },
            ..base.clone()
        },
        Scene {
            x_max: f64::NAN,
            ..base.clone()
        },
        Scene {
            style: CRenderStyle {
                gamma: -1.0,
                ..base.style
            },
            ..base.clone()
        },
        Scene {
            elements: vec![element(0.1, COpticalElementType::ThinLens, 0.0, 0.0)],
            ..base.clone()
        },
    ];
    for scene in bad {
        assert!(!scene.export(&path));
        assert!(dir.entries().is_empty());
    }

    unsafe {
        let c = CString::new(path.to_str().unwrap()).unwrap();
        assert!(!beam_export_png_file(
            c.as_ptr(),
            ptr::null(),
            ptr::null(),
            0,
            &base.style,
            -0.5,
            0.5,
            1e-3,
            8,
            8,
        ));
        assert!(!beam_export_png_file(
            c.as_ptr(),
            &base.beam,
            ptr::null(),
            0,
            ptr::null(),
            -0.5,
            0.5,
            1e-3,
            8,
            8,
        ));
        assert!(!beam_export_png_file(
            c.as_ptr(),
            &base.beam,
            ptr::null(),
            2,
            &base.style,
            -0.5,
            0.5,
            1e-3,
            8,
            8,
        ));
    }
    assert!(dir.entries().is_empty());
}
