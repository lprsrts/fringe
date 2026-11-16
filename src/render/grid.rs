//! Rasterising beam intensity over a 2D slice.
//!
//! Longitudinal slices lie in the (z, x) plane: columns are axial positions,
//! rows run from `-x_max` at the top to `x_max` at the bottom. Transverse slices
//! lie in the (x, y) plane at a fixed `z`. Samples are taken at pixel centres.

#![allow(clippy::chunks_exact_to_as_chunks)]

use rayon::prelude::*;

use super::colormap::{map_colormap, RenderStyle};
use crate::physics::{GaussianBeam, OpticalTrain};

/// Errors from rendering and export.
#[derive(Debug)]
pub enum RenderError {
    /// Width or height is zero or above [`MAX_DIMENSION`].
    InvalidDimensions {
        width: usize,
        height: usize,
    },
    InvalidBounds(String),
    BufferTooSmall {
        required: usize,
        provided: usize,
    },
    BufferLengthMismatch {
        expected: usize,
        actual: usize,
    },
    /// `width * height * 4` does not fit in `usize`.
    BufferOverflow,
    PropagationError(String),
    InvalidBeamParams(String),
    Io(std::io::Error),
    Encoding(image::ImageError),
    Simulation(String),
}

impl std::fmt::Display for RenderError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidDimensions { width, height } => {
                write!(f, "invalid image size {}x{}", width, height)
            }
            Self::InvalidBounds(msg) => write!(f, "invalid bounds: {}", msg),
            Self::BufferTooSmall { required, provided } => write!(
                f,
                "buffer too small: need {} bytes, got {}",
                required, provided
            ),
            Self::BufferLengthMismatch { expected, actual } => write!(
                f,
                "buffer length mismatch: expected {} bytes, got {}",
                expected, actual
            ),
            Self::BufferOverflow => write!(f, "image size overflows usize"),
            Self::PropagationError(err) => write!(f, "propagation failed: {}", err),
            Self::InvalidBeamParams(err) => write!(f, "invalid beam parameters: {}", err),
            Self::Io(err) => write!(f, "I/O error: {}", err),
            Self::Encoding(err) => write!(f, "PNG encoding failed: {}", err),
            Self::Simulation(msg) => write!(f, "{}", msg),
        }
    }
}

impl std::error::Error for RenderError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io(err) => Some(err),
            Self::Encoding(err) => Some(err),
            _ => None,
        }
    }
}

impl From<std::io::Error> for RenderError {
    fn from(err: std::io::Error) -> Self {
        RenderError::Io(err)
    }
}

impl From<image::ImageError> for RenderError {
    fn from(err: image::ImageError) -> Self {
        RenderError::Encoding(err)
    }
}

/// `exp(x)`, flushed to 0 below -708 (where `exp` goes subnormal) and to infinity
/// above 700. Non-finite input gives 0.
#[inline]
pub fn safe_exp(x: f64) -> f64 {
    if !x.is_finite() || x < -708.0 {
        0.0
    } else if x > 700.0 {
        f64::INFINITY
    } else {
        x.exp()
    }
}

/// Wavelength the fringe spacing is calibrated against (He-Ne).
pub const VISUAL_REF_WAVELENGTH: f64 = 632.8e-9;
/// Fringes per Rayleigh range for a beam at [`VISUAL_REF_WAVELENGTH`].
pub const VISUAL_FRINGES_PER_ZR: f64 = 10.0;
/// Exaggerates wavefront curvature so it reads on plots whose z and x scales differ
/// by orders of magnitude.
pub const VISUAL_CURVATURE_GAIN: f64 = 2.0;

/// Axial wavenumber used to draw fringes, in rad/m.
///
/// The real `k` (~10^7 rad/m) is far beyond what a metre-wide image can sample, so
/// the fringes would alias into moire that shifts with zoom and resolution. Instead
/// the carrier is tied to the initial beam's Rayleigh range, which keeps the
/// pattern stable while still scaling with `1/lambda` (clamped to 4x either way)
/// and with the local refractive index.
#[inline]
pub fn visual_wavefront_wavenumber(initial_beam: &GaussianBeam, local_beam: &GaussianBeam) -> f64 {
    let zr_ref = std::f64::consts::PI
        * initial_beam.refractive_index.max(1.0)
        * initial_beam.w0
        * initial_beam.w0
        / VISUAL_REF_WAVELENGTH;
    let wl_scale = (VISUAL_REF_WAVELENGTH / initial_beam.wavelength.max(1e-18)).clamp(0.25, 4.0);
    let n_scale = local_beam.refractive_index / initial_beam.refractive_index.max(1.0);
    (VISUAL_FRINGES_PER_ZR * std::f64::consts::PI / zr_ref.max(1e-18)) * wl_scale * n_scale
}

/// Fringe phase at `(z, x)`, using the carrier from [`visual_wavefront_wavenumber`].
///
/// Lines of constant phase are the parabolas
/// `z(x) = z_c - (VISUAL_CURVATURE_GAIN * k * kappa(z_c) / (2 k_vis)) * x^2`,
/// which is what the app's vector wavefront overlay draws, so the two line up.
#[inline]
pub fn visual_wavefront_phase(
    initial_beam: &GaussianBeam,
    local_beam: &GaussianBeam,
    x: f64,
    z: f64,
) -> f64 {
    let k_vis = visual_wavefront_wavenumber(initial_beam, local_beam);
    let k_local = local_beam.wavenumber();
    let kappa = local_beam.curvature_at(z);
    let psi = local_beam.gouy_phase(z);
    let dz = z - local_beam.z0;
    k_vis * dz - psi + VISUAL_CURVATURE_GAIN * 0.5 * k_local * x * x * kappa
}

/// Order `z_min`/`z_max` and make `x_max` positive (a zero `x_max` becomes 1 um).
/// Fails on non-finite input.
pub fn normalize_grid_bounds(
    z_min: f64,
    z_max: f64,
    x_max: f64,
) -> Result<(f64, f64, f64), RenderError> {
    if !z_min.is_finite() || !z_max.is_finite() || !x_max.is_finite() {
        return Err(RenderError::InvalidBounds(
            "bounds must be finite".to_string(),
        ));
    }
    let (z_min, z_max) = if z_min <= z_max {
        (z_min, z_max)
    } else {
        (z_max, z_min)
    };
    Ok((z_min, z_max, half_extent(x_max)))
}

/// Largest width or height accepted. 16384^2 RGBA8 is about 1 GiB.
pub const MAX_DIMENSION: u32 = 16384;

/// Check the image size and that `buffer_len` holds it. Returns the bytes needed.
#[inline]
pub fn check_buffer_capacity(
    width: usize,
    height: usize,
    buffer_len: usize,
) -> Result<usize, RenderError> {
    check_dimensions(width, height)?;
    let required_len = width
        .checked_mul(height)
        .and_then(|p| p.checked_mul(4))
        .ok_or(RenderError::BufferOverflow)?;
    if buffer_len < required_len {
        return Err(RenderError::BufferTooSmall {
            required: required_len,
            provided: buffer_len,
        });
    }
    Ok(required_len)
}

fn check_dimensions(width: usize, height: usize) -> Result<(), RenderError> {
    let max = MAX_DIMENSION as usize;
    if width == 0 || height == 0 || width > max || height > max {
        return Err(RenderError::InvalidDimensions { width, height });
    }
    Ok(())
}

fn half_extent(v: f64) -> f64 {
    if v.abs() < 1e-15 {
        1e-6
    } else {
        v.abs()
    }
}

/// Centre of cell `i` when `[-half, half]` is split into `n` cells; 0 if `n == 1`.
#[inline]
fn cell_centre(i: usize, n: usize, half: f64) -> f64 {
    if n > 1 {
        let step = 2.0 * half / n as f64;
        -half + (i as f64 + 0.5) * step
    } else {
        0.0
    }
}

/// Axial position and local beam for every column. Propagating through the train
/// once per column, rather than per pixel, is what makes rendering cheap.
fn column_beams(
    beam: &GaussianBeam,
    train: &OpticalTrain,
    z_min: f64,
    z_max: f64,
    width: usize,
) -> Vec<(f64, GaussianBeam)> {
    let dz = if width > 1 {
        (z_max - z_min) / width as f64
    } else {
        0.0
    };
    (0..width)
        .into_par_iter()
        .map(|col| {
            let z = if width > 1 {
                z_min + (col as f64 + 0.5) * dz
            } else {
                (z_min + z_max) * 0.5
            };
            // If propagation fails (e.g. a singular element), show the input beam
            // rather than failing the whole image.
            (z, train.beam_at(beam, z).unwrap_or(*beam))
        })
        .collect()
}

/// Brightest on-axis intensity across the columns, used to normalise the image.
fn on_axis_peak(columns: &[(f64, GaussianBeam)]) -> f64 {
    let peak = columns
        .par_iter()
        .map(|(z, b)| b.intensity_at(0.0, *z))
        .reduce(|| 0.0f64, f64::max);
    if peak.is_finite() && peak > 0.0 {
        peak
    } else {
        1.0
    }
}

/// Fringe depth to use, or 0 when the overlay is off.
fn fringe_depth(style: &RenderStyle) -> f64 {
    if style.show_wavefront_composite {
        style.fringe_modulation
    } else {
        0.0
    }
}

/// Darken `value` by `cos^2(phase)` with depth `depth`, then apply `gamma`.
#[inline]
fn shade(mut value: f64, phase: impl FnOnce() -> f64, depth: f64, gamma: f64) -> f64 {
    if depth > 0.0 {
        let m = depth.clamp(0.0, 1.0);
        value *= (1.0 - m) + m * phase().cos().powi(2);
    }
    if gamma > 0.0 && (gamma - 1.0).abs() > 1e-6 {
        value.powf(gamma).clamp(0.0, 1.0)
    } else {
        value
    }
}

#[inline]
fn longitudinal_value(
    beam: &GaussianBeam,
    local_beam: &GaussianBeam,
    x: f64,
    z: f64,
    peak: f64,
    depth: f64,
    gamma: f64,
) -> f64 {
    let intensity = (local_beam.intensity_at(x, z) / peak).clamp(0.0, 1.0);
    shade(
        intensity,
        || visual_wavefront_phase(beam, local_beam, x, z),
        depth,
        gamma,
    )
}

/// The local beam at one transverse plane. Each plane is normalised to its own
/// on-axis intensity, and the fringes use the physical wavenumber since only `r`
/// varies across the image.
struct TransversePlane {
    inv_w_sq: f64,
    k: f64,
    kappa: f64,
    base_phase: f64,
}

impl TransversePlane {
    fn new(local: &GaussianBeam, z: f64) -> Self {
        let w = local.waist_at(z);
        let k = local.wavenumber();
        Self {
            inv_w_sq: 1.0 / (w * w),
            k,
            kappa: local.curvature_at(z),
            base_phase: k * z - local.gouy_phase(z),
        }
    }

    #[inline]
    fn value(&self, r_sq: f64, depth: f64, gamma: f64) -> f64 {
        let intensity = safe_exp(-2.0 * r_sq * self.inv_w_sq).clamp(0.0, 1.0);
        shade(
            intensity,
            || self.base_phase + 0.5 * self.k * r_sq * self.kappa,
            depth,
            gamma,
        )
    }
}

/// Normalised intensity samples in [0, 1], before colour mapping. Row-major.
#[derive(Clone, Debug, PartialEq)]
pub struct IntensityGrid {
    pub width: usize,
    pub height: usize,
    pub data: Vec<f64>,
    /// Intensity (W/m^2) that maps to 1.0.
    pub peak_intensity: f64,
    /// Always 0; kept for API compatibility.
    pub min_intensity: f64,
}

impl IntensityGrid {
    /// A zeroed grid.
    pub fn new(width: usize, height: usize) -> Result<Self, RenderError> {
        check_dimensions(width, height)?;
        let total_pixels = width
            .checked_mul(height)
            .ok_or(RenderError::BufferOverflow)?;
        Ok(Self {
            width,
            height,
            data: vec![0.0; total_pixels],
            peak_intensity: 0.0,
            min_intensity: 0.0,
        })
    }

    /// Sample a longitudinal slice, with fringes and gamma from `style` applied.
    #[allow(clippy::too_many_arguments)]
    pub fn evaluate_longitudinal(
        beam: &GaussianBeam,
        train: &OpticalTrain,
        z_min: f64,
        z_max: f64,
        x_max: f64,
        width: usize,
        height: usize,
        style: &RenderStyle,
    ) -> Result<Self, RenderError> {
        let (z_min, z_max, x_max) = normalize_grid_bounds(z_min, z_max, x_max)?;
        let mut grid = Self::new(width, height)?;
        let columns = column_beams(beam, train, z_min, z_max, width);
        let peak = on_axis_peak(&columns);
        grid.peak_intensity = peak;
        let depth = fringe_depth(style);

        grid.data
            .par_chunks_exact_mut(width)
            .enumerate()
            .for_each(|(j, row)| {
                let x = cell_centre(j, height, x_max);
                for (val, (z, local)) in row.iter_mut().zip(&columns) {
                    *val = longitudinal_value(beam, local, x, *z, peak, depth, style.gamma);
                }
            });

        Ok(grid)
    }

    /// Sample a transverse slice at `z`, with fringes and gamma from `style` applied.
    #[allow(clippy::too_many_arguments)]
    pub fn evaluate_transverse(
        beam: &GaussianBeam,
        train: &OpticalTrain,
        z: f64,
        x_max: f64,
        y_max: f64,
        width: usize,
        height: usize,
        style: &RenderStyle,
    ) -> Result<Self, RenderError> {
        let mut grid = Self::new(width, height)?;
        let (x_max, y_max) = (half_extent(x_max), half_extent(y_max));

        let local_beam = train.beam_at(beam, z).unwrap_or(*beam);
        let peak = local_beam.intensity_at(0.0, z);
        grid.peak_intensity = if peak.is_finite() && peak > 0.0 {
            peak
        } else {
            1.0
        };

        let plane = TransversePlane::new(&local_beam, z);
        let depth = fringe_depth(style);
        grid.data
            .par_chunks_exact_mut(width)
            .enumerate()
            .for_each(|(j, row)| {
                let y = cell_centre(j, height, y_max);
                for (i, val) in row.iter_mut().enumerate() {
                    let x = cell_centre(i, width, x_max);
                    *val = plane.value(x * x + y * y, depth, style.gamma);
                }
            });

        Ok(grid)
    }

    /// Colour the grid into `out_buffer`, which must hold at least `width * height * 4` bytes.
    /// Gamma is not applied again here.
    pub fn to_rgba(
        &self,
        style: &RenderStyle,
        wavelength: f64,
        out_buffer: &mut [u8],
    ) -> Result<(), RenderError> {
        let required_len = check_buffer_capacity(self.width, self.height, out_buffer.len())?;
        out_buffer[..required_len]
            .par_chunks_exact_mut(self.width * 4)
            .zip(self.data.par_chunks_exact(self.width))
            .for_each(|(pixel_row, scalar_row)| {
                for (pixel, &t) in pixel_row.chunks_exact_mut(4).zip(scalar_row) {
                    pixel.copy_from_slice(&map_colormap(style.colormap, t, wavelength));
                }
            });
        Ok(())
    }

    /// Like [`to_rgba`](Self::to_rgba), into a new buffer.
    pub fn to_rgba_vec(
        &self,
        style: &RenderStyle,
        wavelength: f64,
    ) -> Result<Vec<u8>, RenderError> {
        let total_bytes = self
            .width
            .checked_mul(self.height)
            .and_then(|p| p.checked_mul(4))
            .ok_or(RenderError::BufferOverflow)?;
        let mut buf = vec![0u8; total_bytes];
        self.to_rgba(style, wavelength, &mut buf)?;
        Ok(buf)
    }
}

/// Render a longitudinal slice of `beam` through `train` into `out_buffer` (RGBA8).
///
/// The slice covers `z` in `[z_min, z_max]` and `x` in `[-x_max, x_max]`;
/// swapped or negative bounds are normalised (see [`normalize_grid_bounds`]).
/// Intensity is normalised to the brightest on-axis point in view.
#[allow(clippy::too_many_arguments)]
pub fn render_longitudinal_rgba(
    beam: &GaussianBeam,
    train: &OpticalTrain,
    style: &RenderStyle,
    z_min: f64,
    z_max: f64,
    x_max: f64,
    width: usize,
    height: usize,
    out_buffer: &mut [u8],
) -> Result<(), RenderError> {
    let required_len = check_buffer_capacity(width, height, out_buffer.len())?;
    let (z_min, z_max, x_max) = normalize_grid_bounds(z_min, z_max, x_max)?;
    let columns = column_beams(beam, train, z_min, z_max, width);
    let peak = on_axis_peak(&columns);
    let depth = fringe_depth(style);

    out_buffer[..required_len]
        .par_chunks_exact_mut(width * 4)
        .enumerate()
        .for_each(|(j, row)| {
            let x = cell_centre(j, height, x_max);
            for (pixel, (z, local)) in row.chunks_exact_mut(4).zip(&columns) {
                let t = longitudinal_value(beam, local, x, *z, peak, depth, style.gamma);
                pixel.copy_from_slice(&map_colormap(style.colormap, t, local.wavelength));
            }
        });

    Ok(())
}

/// Single-threaded [`render_longitudinal_rgba`] with a caller-supplied colormap,
/// returning a new buffer. Fringes are drawn whenever `fringe_modulation > 0`.
#[allow(clippy::too_many_arguments)]
pub fn render_longitudinal_slice(
    beam: &GaussianBeam,
    train: &OpticalTrain,
    z_min: f64,
    z_max: f64,
    x_max: f64,
    width: usize,
    height: usize,
    gamma: f64,
    fringe_modulation: f64,
    colormap_fn: &dyn Fn(f64) -> [u8; 4],
) -> Result<Vec<u8>, RenderError> {
    let total_bytes = width
        .checked_mul(height)
        .and_then(|p| p.checked_mul(4))
        .ok_or(RenderError::BufferOverflow)?;
    let mut buffer = vec![0u8; total_bytes];

    let (z_min, z_max, x_max) = normalize_grid_bounds(z_min, z_max, x_max)?;
    let columns = column_beams(beam, train, z_min, z_max, width);
    let peak = on_axis_peak(&columns);

    // width == 0 leaves `buffer` empty, and chunks_exact_mut(0) would panic.
    if width > 0 {
        for (j, row) in buffer.chunks_exact_mut(width * 4).enumerate() {
            let x = cell_centre(j, height, x_max);
            for (pixel, (z, local)) in row.chunks_exact_mut(4).zip(&columns) {
                let t = longitudinal_value(beam, local, x, *z, peak, fringe_modulation, gamma);
                pixel.copy_from_slice(&colormap_fn(t));
            }
        }
    }

    Ok(buffer)
}

/// Render the transverse (x, y) plane at `z` into `out_buffer` (RGBA8), covering
/// `[-x_max, x_max]` by `[-y_max, y_max]`. Each plane is normalised to its own peak.
#[allow(clippy::too_many_arguments)]
pub fn render_transverse_rgba(
    beam: &GaussianBeam,
    train: &OpticalTrain,
    style: &RenderStyle,
    z: f64,
    x_max: f64,
    y_max: f64,
    width: usize,
    height: usize,
    out_buffer: &mut [u8],
) -> Result<(), RenderError> {
    let required_len = check_buffer_capacity(width, height, out_buffer.len())?;
    let (x_max, y_max) = (half_extent(x_max), half_extent(y_max));
    let local_beam = train.beam_at(beam, z).unwrap_or(*beam);
    let plane = TransversePlane::new(&local_beam, z);
    let depth = fringe_depth(style);

    out_buffer[..required_len]
        .par_chunks_exact_mut(width * 4)
        .enumerate()
        .for_each(|(j, row)| {
            let y = cell_centre(j, height, y_max);
            for (i, pixel) in row.chunks_exact_mut(4).enumerate() {
                let x = cell_centre(i, width, x_max);
                let t = plane.value(x * x + y * y, depth, style.gamma);
                pixel.copy_from_slice(&map_colormap(style.colormap, t, local_beam.wavelength));
            }
        });

    Ok(())
}

/// Single-threaded [`render_transverse_rgba`] with a caller-supplied colormap,
/// returning a new buffer. Fringes are drawn whenever `fringe_modulation > 0`.
#[allow(clippy::too_many_arguments)]
pub fn render_transverse_slice(
    beam: &GaussianBeam,
    train: &OpticalTrain,
    z: f64,
    x_max: f64,
    y_max: f64,
    width: usize,
    height: usize,
    gamma: f64,
    fringe_modulation: f64,
    colormap_fn: &dyn Fn(f64) -> [u8; 4],
) -> Result<Vec<u8>, RenderError> {
    let total_bytes = width
        .checked_mul(height)
        .and_then(|p| p.checked_mul(4))
        .ok_or(RenderError::BufferOverflow)?;
    let mut buffer = vec![0u8; total_bytes];
    let (x_max, y_max) = (half_extent(x_max), half_extent(y_max));
    let local_beam = train.beam_at(beam, z).unwrap_or(*beam);
    let plane = TransversePlane::new(&local_beam, z);

    if width > 0 {
        for (j, row) in buffer.chunks_exact_mut(width * 4).enumerate() {
            let y = cell_centre(j, height, y_max);
            for (i, pixel) in row.chunks_exact_mut(4).enumerate() {
                let x = cell_centre(i, width, x_max);
                let t = plane.value(x * x + y * y, fringe_modulation, gamma);
                pixel.copy_from_slice(&colormap_fn(t));
            }
        }
    }

    Ok(buffer)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn intensity_grid_rejects_zero_size() {
        assert!(IntensityGrid::new(0, 100).is_err());
        assert!(IntensityGrid::new(100, 0).is_err());
        let grid = IntensityGrid::new(50, 40).unwrap();
        assert_eq!(grid.data.len(), 2000);
    }

    #[test]
    fn safe_exp_limits() {
        assert_eq!(safe_exp(-709.0), 0.0);
        assert_eq!(safe_exp(-1000.0), 0.0);
        assert_eq!(safe_exp(0.0), 1.0);
        assert!(safe_exp(701.0).is_infinite());
    }

    #[test]
    fn normalize_grid_bounds_orders_and_rejects_nan() {
        let (z_min, z_max, x_max) = normalize_grid_bounds(2.0, -1.0, -0.05).unwrap();
        assert_eq!(z_min, -1.0);
        assert_eq!(z_max, 2.0);
        assert_eq!(x_max, 0.05);

        assert!(normalize_grid_bounds(f64::NAN, 1.0, 1.0).is_err());
    }

    #[test]
    fn check_buffer_capacity_limits() {
        assert!(check_buffer_capacity(0, 10, 100).is_err());
        assert!(check_buffer_capacity(10, 10, 399).is_err());
        assert_eq!(check_buffer_capacity(10, 10, 400).unwrap(), 400);
    }

    #[test]
    fn longitudinal_grid_to_rgba() {
        let beam = GaussianBeam::default();
        let train = OpticalTrain::new();
        let style = RenderStyle::default();

        let grid =
            IntensityGrid::evaluate_longitudinal(&beam, &train, -0.5, 0.5, 0.002, 64, 32, &style)
                .unwrap();

        assert_eq!(grid.data.len(), 64 * 32);
        assert!(grid.peak_intensity > 0.0);

        let rgba = grid.to_rgba_vec(&style, beam.wavelength).unwrap();
        assert_eq!(rgba.len(), 64 * 32 * 4);
    }

    #[test]
    fn fringes_stay_in_unit_range() {
        let beam = GaussianBeam::default();
        let train = OpticalTrain::new();
        let style = RenderStyle::default().with_wavefront(true, 0.8);

        let grid =
            IntensityGrid::evaluate_longitudinal(&beam, &train, -0.5, 0.5, 0.002, 32, 32, &style)
                .unwrap();

        for &val in &grid.data {
            assert!((0.0..=1.0).contains(&val), "out of range: {}", val);
        }
    }

    #[test]
    fn visual_fringes_follow_wavefront_parabola() {
        let beam = GaussianBeam::default();
        let k_vis = visual_wavefront_wavenumber(&beam, &beam);
        let z_r = beam.rayleigh_range();

        // cos^2 has period pi, so this is VISUAL_FRINGES_PER_ZR fringes per z_R.
        assert!(((k_vis * z_r) / std::f64::consts::PI - VISUAL_FRINGES_PER_ZR).abs() < 1e-9);

        // Going out to x = w along the parabola z(x) = z_c - sagitta * (x/w)^2 should
        // land on the same phase as the axis at z_c.
        let z_c = 0.8 * z_r;
        let w_c = beam.waist_at(z_c);
        let kappa_c = beam.curvature_at(z_c);
        let k_local = beam.wavenumber();
        let sagitta = (VISUAL_CURVATURE_GAIN * 0.5 * k_local * w_c * w_c * kappa_c) / k_vis;
        assert!(sagitta > 0.0);

        let z_edge = z_c - sagitta;
        let phase_center = k_vis * z_c - beam.gouy_phase(z_c);
        let phase_edge = k_vis * z_edge - beam.gouy_phase(z_c)
            + VISUAL_CURVATURE_GAIN * 0.5 * k_local * w_c * w_c * kappa_c;
        assert!(
            (phase_center - phase_edge).abs() < 1e-12,
            "edge phase {} != centre phase {}",
            phase_edge,
            phase_center
        );
    }
}
