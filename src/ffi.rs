//! C ABI for the Swift app. Mirrors `include/beam_core.h`; keep the two in sync.

use std::f64::consts::PI;
use std::ffi::CStr;
use std::os::raw::c_char;
use std::path::Path;
use std::ptr::addr_of;

use crate::physics::{GaussianBeam, OpticalElement, OpticalTrain};
use crate::render::colormap::{Colormap, RenderStyle};

/// Beam parameters, all SI units.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CBeamParams {
    /// Vacuum wavelength (m).
    pub wavelength: f64,
    /// 1/e² waist radius (m).
    pub w0: f64,
    /// Waist position on the axis (m).
    pub z0: f64,
    /// Refractive index of the medium, >= 1.
    pub refractive_index: f64,
    /// Total power (W).
    pub power: f64,
}

impl Default for CBeamParams {
    /// 0.5 mm He-Ne beam in air.
    fn default() -> Self {
        Self {
            wavelength: 632.8e-9,
            w0: 0.5e-3,
            z0: 0.0,
            refractive_index: 1.0,
            power: 1.0,
        }
    }
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum COpticalElementType {
    ThinLens = 0,
    CurvedMirror = 1,
    FlatMirror = 2,
    DielectricInterface = 3,
    GaussianAperture = 4,
}

/// An optical element at axial position `z` (m).
///
/// `param1` is the focal length, mirror radius, aperture radius or `n1`
/// depending on `element_type`; `param2` is `n2` for a dielectric interface.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CPlacedElement {
    pub z: f64,
    pub element_type: COpticalElementType,
    pub param1: f64,
    pub param2: f64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Default)]
pub enum CColormap {
    #[default]
    Viridis = 0,
    Inferno = 1,
    Plasma = 2,
    Turbo = 3,
    LaserGlow = 4,
    Asympton = 5,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CRenderStyle {
    pub colormap: CColormap,
    /// Display gamma; 1.0 is linear.
    pub gamma: f64,
    pub show_wavefront_composite: bool,
    /// Depth of the wavefront fringes, 0..=1.
    pub fringe_modulation: f64,
}

impl Default for CRenderStyle {
    fn default() -> Self {
        Self {
            colormap: CColormap::Viridis,
            gamma: 1.0,
            show_wavefront_composite: false,
            fringe_modulation: 0.0,
        }
    }
}

/// Rayleigh range z_R = π n w0² / λ. Returns 0 on invalid input.
#[no_mangle]
pub extern "C" fn beam_calc_rayleigh_range(w0: f64, wavelength: f64, n: f64) -> f64 {
    if !w0.is_finite()
        || w0 <= 0.0
        || !wavelength.is_finite()
        || wavelength <= 0.0
        || !n.is_finite()
        || n < 1.0
    {
        return 0.0;
    }
    PI * n * w0 * w0 / wavelength
}

/// Beam radius w(z) = w0 √(1 + (z/z_R)²), with z measured from the waist.
/// Returns 0 on invalid input.
#[no_mangle]
pub extern "C" fn beam_calc_waist_at_z(w0: f64, z: f64, z_r: f64) -> f64 {
    if !w0.is_finite() || w0 < 0.0 || !z.is_finite() || !z_r.is_finite() || z_r <= 0.0 {
        return 0.0;
    }
    let ratio = z / z_r;
    w0 * (1.0 + ratio * ratio).sqrt()
}

/// Wavefront curvature 1/R(z) = z / (z² + z_R²).
///
/// Returned as curvature rather than R so the waist (R = ∞) comes out as 0
/// instead of a division by zero. Returns 0 on invalid input.
#[no_mangle]
pub extern "C" fn beam_calc_curvature_at_z(z: f64, z_r: f64) -> f64 {
    if !z.is_finite() || !z_r.is_finite() || z_r <= 0.0 {
        return 0.0;
    }
    let denom = z * z + z_r * z_r;
    if denom <= 0.0 {
        return 0.0;
    }
    z / denom
}

/// Gouy phase ψ(z) = atan(z / z_R) in radians. Returns 0 on invalid input.
#[no_mangle]
pub extern "C" fn beam_calc_gouy_phase(z: f64, z_r: f64) -> f64 {
    if !z.is_finite() || !z_r.is_finite() || z_r <= 0.0 {
        return 0.0;
    }
    (z / z_r).atan()
}

/// Validates the raw inputs shared by the render and export entry points.
///
/// The enum and bool fields are read through raw pointers as plain integers
/// and checked before conversion: C can hand us any bit pattern, and
/// materialising an out-of-range Rust enum or bool (even inside a `&T`) is UB.
///
/// # Safety
/// `beam` and `style` must be null or point to readable structs of the C
/// layout; `elements` must be null or point to `element_count` readable
/// `CPlacedElement`s.
unsafe fn parse_ffi_inputs(
    beam: *const CBeamParams,
    elements: *const CPlacedElement,
    element_count: u32,
    style: *const CRenderStyle,
    z_min: f64,
    z_max: f64,
    x_max: f64,
) -> Option<(GaussianBeam, OpticalTrain, RenderStyle)> {
    if beam.is_null() || style.is_null() {
        return None;
    }

    // CBeamParams is all f64, so every bit pattern is valid and a reference is fine.
    // GaussianBeam::new checks finiteness and ranges.
    let b = &*beam;
    let gaussian_beam =
        GaussianBeam::new(b.wavelength, b.w0, b.z0, b.refractive_index, b.power).ok()?;

    let colormap = match addr_of!((*style).colormap).cast::<u32>().read() {
        0 => Colormap::Viridis,
        1 => Colormap::Inferno,
        2 => Colormap::Plasma,
        3 => Colormap::Turbo,
        4 => Colormap::LaserGlow,
        5 => Colormap::Asympton,
        _ => return None,
    };
    let gamma = addr_of!((*style).gamma).read();
    let fringe_modulation = addr_of!((*style).fringe_modulation).read();
    let show_wavefront_composite = addr_of!((*style).show_wavefront_composite)
        .cast::<u8>()
        .read()
        != 0;
    if !gamma.is_finite() || gamma < 0.0 || !fringe_modulation.is_finite() {
        return None;
    }
    let render_style = RenderStyle {
        colormap,
        gamma,
        show_wavefront_composite,
        fringe_modulation,
    };

    if !z_min.is_finite() || !z_max.is_finite() || !x_max.is_finite() || x_max <= 0.0 {
        return None;
    }

    let mut train = OpticalTrain::new();
    if element_count > 0 && elements.is_null() {
        return None;
    }
    for i in 0..element_count as usize {
        let e = elements.add(i);
        let z = addr_of!((*e).z).read();
        let p1 = addr_of!((*e).param1).read();
        let p2 = addr_of!((*e).param2).read();
        if !z.is_finite() {
            return None;
        }

        let element = match addr_of!((*e).element_type).cast::<u32>().read() {
            // An infinite focal length is a flat plate and is allowed.
            0 if !p1.is_nan() && p1 != 0.0 => OpticalElement::ThinLens { focal_length: p1 },
            1 if p1.is_finite() && p1 != 0.0 => OpticalElement::CurvedMirror { radius: p1 },
            2 => OpticalElement::FlatMirror,
            3 if p1.is_finite() && p1 >= 1.0 && p2.is_finite() && p2 >= 1.0 => {
                OpticalElement::DielectricInterface {
                    n1: p1,
                    n2: p2,
                    radius: None,
                }
            }
            4 if p1.is_finite() && p1 > 0.0 => OpticalElement::GaussianAperture { radius: p1 },
            _ => return None,
        };
        train.add_element(z, element);
    }

    Some((gaussian_beam, train, render_style))
}

pub use crate::render::MAX_DIMENSION;

/// Renders the (z, x) intensity field into a caller-owned RGBA8 buffer.
///
/// Returns `false` on invalid input or if rendering fails; panics are caught.
///
/// # Safety
/// `beam` and `style` must point to valid structs, `elements` to
/// `element_count` elements (may be null when the count is 0), and
/// `out_rgba_buffer` to at least `buffer_len` writable bytes.
/// `buffer_len` must be at least `width * height * 4`.
#[no_mangle]
pub unsafe extern "C" fn beam_render_longitudinal_rgba(
    beam: *const CBeamParams,
    elements: *const CPlacedElement,
    element_count: u32,
    style: *const CRenderStyle,
    z_min: f64,
    z_max: f64,
    x_max: f64,
    width: u32,
    height: u32,
    out_rgba_buffer: *mut u8,
    buffer_len: u32,
) -> bool {
    let result = std::panic::catch_unwind(|| {
        if out_rgba_buffer.is_null()
            || width == 0
            || height == 0
            || width > MAX_DIMENSION
            || height > MAX_DIMENSION
        {
            return false;
        }

        // Bounded by MAX_DIMENSION, so this cannot overflow.
        let total_bytes = width as usize * height as usize * 4;
        if (buffer_len as usize) < total_bytes {
            return false;
        }

        let Some((gaussian_beam, train, render_style)) =
            parse_ffi_inputs(beam, elements, element_count, style, z_min, z_max, x_max)
        else {
            return false;
        };

        let out = std::slice::from_raw_parts_mut(out_rgba_buffer, total_bytes);
        crate::render::grid::render_longitudinal_rgba(
            &gaussian_beam,
            &train,
            &render_style,
            z_min,
            z_max,
            x_max,
            width as usize,
            height as usize,
            out,
        )
        .is_ok()
    });

    result.unwrap_or(false)
}

/// Renders the beam and writes it as a PNG to `file_path`.
///
/// Returns `false` on invalid input or any I/O or encoding error; panics are caught.
///
/// # Safety
/// `file_path` must be a NUL-terminated UTF-8 string. Pointer requirements for
/// `beam`, `elements` and `style` are as for [`beam_render_longitudinal_rgba`].
#[no_mangle]
pub unsafe extern "C" fn beam_export_png_file(
    file_path: *const c_char,
    beam: *const CBeamParams,
    elements: *const CPlacedElement,
    element_count: u32,
    style: *const CRenderStyle,
    z_min: f64,
    z_max: f64,
    x_max: f64,
    width: u32,
    height: u32,
) -> bool {
    let result = std::panic::catch_unwind(|| {
        if file_path.is_null()
            || width == 0
            || height == 0
            || width > MAX_DIMENSION
            || height > MAX_DIMENSION
        {
            return false;
        }

        let Ok(path_str) = CStr::from_ptr(file_path).to_str() else {
            return false;
        };
        if path_str.trim().is_empty() {
            return false;
        }

        let Some((gaussian_beam, train, render_style)) =
            parse_ffi_inputs(beam, elements, element_count, style, z_min, z_max, x_max)
        else {
            return false;
        };

        crate::render::export_beam_to_png_file(
            Path::new(path_str),
            &gaussian_beam,
            &train,
            &render_style,
            z_min,
            z_max,
            x_max,
            width,
            height,
        )
        .is_ok()
    });

    result.unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::mem::{align_of, offset_of, size_of};

    #[test]
    fn test_ffi_struct_sizes_and_alignments() {
        assert_eq!(size_of::<CBeamParams>(), 40);
        assert_eq!(align_of::<CBeamParams>(), 8);

        assert_eq!(size_of::<COpticalElementType>(), 4);
        assert_eq!(align_of::<COpticalElementType>(), 4);

        assert_eq!(size_of::<CPlacedElement>(), 32);
        assert_eq!(align_of::<CPlacedElement>(), 8);
        assert_eq!(offset_of!(CPlacedElement, z), 0);
        assert_eq!(offset_of!(CPlacedElement, element_type), 8);
        assert_eq!(offset_of!(CPlacedElement, param1), 16);
        assert_eq!(offset_of!(CPlacedElement, param2), 24);

        assert_eq!(size_of::<CColormap>(), 4);
        assert_eq!(align_of::<CColormap>(), 4);

        assert_eq!(size_of::<CRenderStyle>(), 32);
        assert_eq!(align_of::<CRenderStyle>(), 8);
        assert_eq!(offset_of!(CRenderStyle, colormap), 0);
        assert_eq!(offset_of!(CRenderStyle, gamma), 8);
        assert_eq!(offset_of!(CRenderStyle, show_wavefront_composite), 16);
        assert_eq!(offset_of!(CRenderStyle, fringe_modulation), 24);
    }

    #[test]
    fn test_analytical_query_functions() {
        let w0 = 0.5e-3;
        let lambda = 632.8e-9;
        let n = 1.0;

        let z_r = beam_calc_rayleigh_range(w0, lambda, n);
        let expected_zr = PI * n * w0 * w0 / lambda;
        assert!((z_r - expected_zr).abs() < 1e-10);

        // Invalid rayleigh inputs
        assert_eq!(beam_calc_rayleigh_range(0.0, lambda, n), 0.0);
        assert_eq!(beam_calc_rayleigh_range(w0, 0.0, n), 0.0);
        assert_eq!(beam_calc_rayleigh_range(w0, lambda, 0.5), 0.0);
        assert_eq!(beam_calc_rayleigh_range(w0, f64::NAN, n), 0.0);

        // Waist at z
        let w_at_0 = beam_calc_waist_at_z(w0, 0.0, z_r);
        assert!((w_at_0 - w0).abs() < 1e-12);
        let w_at_zr = beam_calc_waist_at_z(w0, z_r, z_r);
        assert!((w_at_zr - w0 * 2.0f64.sqrt()).abs() < 1e-12);

        // Curvature at z
        let curv_0 = beam_calc_curvature_at_z(0.0, z_r);
        assert_eq!(curv_0, 0.0);
        let curv_zr = beam_calc_curvature_at_z(z_r, z_r);
        assert!((curv_zr - 1.0 / (2.0 * z_r)).abs() < 1e-12);

        // Gouy phase at z
        let gouy_0 = beam_calc_gouy_phase(0.0, z_r);
        assert_eq!(gouy_0, 0.0);
        let gouy_zr = beam_calc_gouy_phase(z_r, z_r);
        assert!((gouy_zr - PI / 4.0).abs() < 1e-12);
    }

    #[test]
    fn test_render_longitudinal_rgba_success_and_validation() {
        let beam = CBeamParams::default();
        let style = CRenderStyle::default();
        let width = 32u32;
        let height = 16u32;
        let mut buffer = vec![0u8; (width * height * 4) as usize];

        // Valid rendering
        unsafe {
            let ok = beam_render_longitudinal_rgba(
                &beam,
                std::ptr::null(),
                0,
                &style,
                -0.5,
                0.5,
                1.0e-3,
                width,
                height,
                buffer.as_mut_ptr(),
                buffer.len() as u32,
            );
            assert!(ok);
        }
        // Alpha channel should be 255 for rendered pixels
        assert_eq!(buffer[3], 255);

        // Null checks
        unsafe {
            assert!(!beam_render_longitudinal_rgba(
                std::ptr::null(),
                std::ptr::null(),
                0,
                &style,
                -0.5,
                0.5,
                1.0e-3,
                width,
                height,
                buffer.as_mut_ptr(),
                buffer.len() as u32,
            ));
            assert!(!beam_render_longitudinal_rgba(
                &beam,
                std::ptr::null(),
                0,
                std::ptr::null(),
                -0.5,
                0.5,
                1.0e-3,
                width,
                height,
                buffer.as_mut_ptr(),
                buffer.len() as u32,
            ));
            assert!(!beam_render_longitudinal_rgba(
                &beam,
                std::ptr::null(),
                0,
                &style,
                -0.5,
                0.5,
                1.0e-3,
                width,
                height,
                std::ptr::null_mut(),
                buffer.len() as u32,
            ));
        }

        // Buffer too small
        unsafe {
            assert!(!beam_render_longitudinal_rgba(
                &beam,
                std::ptr::null(),
                0,
                &style,
                -0.5,
                0.5,
                1.0e-3,
                width,
                height,
                buffer.as_mut_ptr(),
                (buffer.len() - 1) as u32,
            ));
        }

        // An out-of-range colormap discriminant, as C could pass. u64 storage
        // keeps the fake struct 8-byte aligned.
        let mut invalid_style = [0u64; size_of::<CRenderStyle>() / 8];
        unsafe { (invalid_style.as_mut_ptr() as *mut u32).write(99) };
        let invalid_style_ptr = invalid_style.as_ptr() as *const CRenderStyle;
        unsafe {
            assert!(!beam_render_longitudinal_rgba(
                &beam,
                std::ptr::null(),
                0,
                invalid_style_ptr,
                -0.5,
                0.5,
                1.0e-3,
                width,
                height,
                buffer.as_mut_ptr(),
                buffer.len() as u32,
            ));
        }
    }

    #[test]
    fn test_render_with_optical_elements() {
        let beam = CBeamParams::default();
        let style = CRenderStyle {
            colormap: CColormap::Inferno,
            gamma: 1.0,
            show_wavefront_composite: true,
            fringe_modulation: 0.5,
        };
        let elements = [
            CPlacedElement {
                z: 0.2,
                element_type: COpticalElementType::ThinLens,
                param1: 0.1,
                param2: 0.0,
            },
            CPlacedElement {
                z: 0.4,
                element_type: COpticalElementType::DielectricInterface,
                param1: 1.0,
                param2: 1.5,
            },
        ];

        let width = 16u32;
        let height = 16u32;
        let mut buffer = vec![0u8; (width * height * 4) as usize];

        unsafe {
            let ok = beam_render_longitudinal_rgba(
                &beam,
                elements.as_ptr(),
                elements.len() as u32,
                &style,
                0.0,
                0.6,
                1.5e-3,
                width,
                height,
                buffer.as_mut_ptr(),
                buffer.len() as u32,
            );
            assert!(ok);

            let inf_lens = [CPlacedElement {
                z: 0.2,
                element_type: COpticalElementType::ThinLens,
                param1: f64::INFINITY,
                param2: 0.0,
            }];
            let ok_inf = beam_render_longitudinal_rgba(
                &beam,
                inf_lens.as_ptr(),
                inf_lens.len() as u32,
                &style,
                0.0,
                0.6,
                1.5e-3,
                width,
                height,
                buffer.as_mut_ptr(),
                buffer.len() as u32,
            );
            assert!(
                ok_inf,
                "an infinite focal length (flat plate) should be accepted"
            );
        }
    }

    #[test]
    fn test_export_png_file_ffi() {
        let temp_dir = std::env::temp_dir().join("beam_core_ffi_test");
        let png_path = temp_dir.join("test_ffi_export.png");
        let c_path = std::ffi::CString::new(png_path.to_str().unwrap()).unwrap();

        let beam = CBeamParams::default();
        let style = CRenderStyle::default();

        unsafe {
            let ok = beam_export_png_file(
                c_path.as_ptr(),
                &beam,
                std::ptr::null(),
                0,
                &style,
                -0.1,
                0.1,
                1.0e-3,
                32,
                32,
            );
            assert!(ok);
        }

        assert!(png_path.exists());
        let contents = std::fs::read(&png_path).unwrap();
        assert_eq!(&contents[0..8], b"\x89PNG\r\n\x1a\n");

        let _ = std::fs::remove_dir_all(temp_dir);
    }

    #[test]
    fn test_dimension_boundary_and_overflow_guards() {
        let beam = CBeamParams::default();
        let style = CRenderStyle::default();
        let mut buffer = [0u8; 64];

        unsafe {
            // Render: width > MAX_DIMENSION
            assert!(!beam_render_longitudinal_rgba(
                &beam,
                std::ptr::null(),
                0,
                &style,
                -0.5,
                0.5,
                1.0e-3,
                MAX_DIMENSION + 1,
                1,
                buffer.as_mut_ptr(),
                buffer.len() as u32,
            ));

            // Render: height > MAX_DIMENSION
            assert!(!beam_render_longitudinal_rgba(
                &beam,
                std::ptr::null(),
                0,
                &style,
                -0.5,
                0.5,
                1.0e-3,
                1,
                MAX_DIMENSION + 1,
                buffer.as_mut_ptr(),
                buffer.len() as u32,
            ));

            // Render: u32::MAX width
            assert!(!beam_render_longitudinal_rgba(
                &beam,
                std::ptr::null(),
                0,
                &style,
                -0.5,
                0.5,
                1.0e-3,
                u32::MAX,
                1,
                buffer.as_mut_ptr(),
                buffer.len() as u32,
            ));

            // Render: zero width or height
            assert!(!beam_render_longitudinal_rgba(
                &beam,
                std::ptr::null(),
                0,
                &style,
                -0.5,
                0.5,
                1.0e-3,
                0,
                16,
                buffer.as_mut_ptr(),
                buffer.len() as u32,
            ));
            assert!(!beam_render_longitudinal_rgba(
                &beam,
                std::ptr::null(),
                0,
                &style,
                -0.5,
                0.5,
                1.0e-3,
                16,
                0,
                buffer.as_mut_ptr(),
                buffer.len() as u32,
            ));

            // Export: width > MAX_DIMENSION
            let dummy_path = std::ffi::CString::new("/tmp/should_never_be_written.png").unwrap();
            assert!(!beam_export_png_file(
                dummy_path.as_ptr(),
                &beam,
                std::ptr::null(),
                0,
                &style,
                -0.5,
                0.5,
                1.0e-3,
                MAX_DIMENSION + 1,
                1,
            ));

            // Export: height > MAX_DIMENSION
            assert!(!beam_export_png_file(
                dummy_path.as_ptr(),
                &beam,
                std::ptr::null(),
                0,
                &style,
                -0.5,
                0.5,
                1.0e-3,
                1,
                MAX_DIMENSION + 1,
            ));

            // Huge sizes must be rejected before anything is allocated.
            assert!(!beam_export_png_file(
                dummy_path.as_ptr(),
                &beam,
                std::ptr::null(),
                0,
                &style,
                -0.5,
                0.5,
                1.0e-3,
                u32::MAX,
                1,
            ));
            assert!(!beam_export_png_file(
                dummy_path.as_ptr(),
                &beam,
                std::ptr::null(),
                0,
                &style,
                -0.5,
                0.5,
                1.0e-3,
                u32::MAX / 2,
                2,
            ));

            // Export: zero dimensions
            assert!(!beam_export_png_file(
                dummy_path.as_ptr(),
                &beam,
                std::ptr::null(),
                0,
                &style,
                -0.5,
                0.5,
                1.0e-3,
                0,
                16,
            ));
            assert!(!beam_export_png_file(
                dummy_path.as_ptr(),
                &beam,
                std::ptr::null(),
                0,
                &style,
                -0.5,
                0.5,
                1.0e-3,
                16,
                0,
            ));
        }
    }
}
