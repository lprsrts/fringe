//! Colormaps and intensity transfer functions.
//!
//! Every colormap takes a value in [0, 1] and returns opaque RGBA8. Out-of-range
//! input is clamped and NaN maps to 0.

use std::str::FromStr;

/// Palette choice. Discriminants are part of the C ABI (`CColormap`).
#[repr(C)]
#[derive(Copy, Clone, Debug, PartialEq, Eq, Hash, Default)]
pub enum Colormap {
    #[default]
    Viridis = 0,
    Inferno = 1,
    Plasma = 2,
    Turbo = 3,
    LaserGlow = 4,
    Asympton = 5,
}

impl Colormap {
    /// Name accepted by `from_str`, e.g. `"laser_glow"`.
    pub const fn name(&self) -> &'static str {
        match self {
            Colormap::Viridis => "viridis",
            Colormap::Inferno => "inferno",
            Colormap::Plasma => "plasma",
            Colormap::Turbo => "turbo",
            Colormap::LaserGlow => "laser_glow",
            Colormap::Asympton => "asympton",
        }
    }

    pub const fn all() -> [Colormap; 6] {
        [
            Colormap::Viridis,
            Colormap::Inferno,
            Colormap::Plasma,
            Colormap::Turbo,
            Colormap::LaserGlow,
            Colormap::Asympton,
        ]
    }
}

impl FromStr for Colormap {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.trim().to_lowercase().replace('-', "_").as_str() {
            "viridis" => Ok(Colormap::Viridis),
            "inferno" => Ok(Colormap::Inferno),
            "plasma" => Ok(Colormap::Plasma),
            "turbo" => Ok(Colormap::Turbo),
            "laser_glow" | "laserglow" | "laser" => Ok(Colormap::LaserGlow),
            "asympton" => Ok(Colormap::Asympton),
            other => Err(format!(
                "unknown colormap '{}' (expected viridis, inferno, plasma, turbo, laser_glow or asympton)",
                other
            )),
        }
    }
}

/// How intensity is turned into colour. Same layout as the C `CRenderStyle`
/// (32 bytes, 8-byte aligned).
#[repr(C)]
#[derive(Copy, Clone, Debug, PartialEq)]
pub struct RenderStyle {
    pub colormap: Colormap,
    /// Exponent applied to normalised intensity before colour mapping.
    pub gamma: f64,
    /// Overlay wavefront fringes on the intensity.
    pub show_wavefront_composite: bool,
    /// Fringe depth in [0, 1]; 0 disables them even if the overlay is on.
    pub fringe_modulation: f64,
}

impl Default for RenderStyle {
    fn default() -> Self {
        Self {
            colormap: Colormap::Viridis,
            gamma: 1.0,
            show_wavefront_composite: false,
            fringe_modulation: 0.0,
        }
    }
}

impl RenderStyle {
    /// A non-positive or NaN `gamma` is replaced by 1.
    pub fn new(colormap: Colormap, gamma: f64) -> Self {
        Self {
            colormap,
            gamma: if gamma <= 0.0 || gamma.is_nan() {
                1.0
            } else {
                gamma
            },
            show_wavefront_composite: false,
            fringe_modulation: 0.0,
        }
    }

    pub fn with_wavefront(mut self, show_wavefront: bool, fringe_modulation: f64) -> Self {
        self.show_wavefront_composite = show_wavefront;
        self.fringe_modulation = fringe_modulation.clamp(0.0, 1.0);
        self
    }

    #[inline]
    pub fn map_intensity(&self, normalized_intensity: f64, wavelength_m: f64) -> [u8; 4] {
        map_intensity_to_rgba(
            normalized_intensity,
            self.gamma,
            self.colormap,
            wavelength_m,
        )
    }
}

/// Curve applied to normalised intensity before it is coloured.
#[derive(Copy, Clone, Debug, PartialEq, Default)]
pub enum TransferFunction {
    /// `T(I) = I`
    #[default]
    Linear,
    /// `T(I) = I^gamma`
    Gamma(f64),
    /// `T(I) = ln(1 + a*I) / ln(1 + a)`, with `a = compression`.
    Logarithmic { compression: f64 },
    /// `T(I) = clamp(1 + 10*log10(I) / D, 0, 1)`: the top `D` dB fill the range.
    Decibel { dynamic_range_db: f64 },
}

impl TransferFunction {
    /// `Linear` for gamma ~1, otherwise `Gamma` (invalid values fall back to 1).
    pub fn from_gamma(gamma: f64) -> Self {
        if (gamma - 1.0).abs() < 1e-6 {
            TransferFunction::Linear
        } else {
            TransferFunction::Gamma(if gamma <= 0.0 || gamma.is_nan() {
                1.0
            } else {
                gamma
            })
        }
    }

    /// Map an intensity in [0, 1] to [0, 1]. Inputs outside the range are clamped first;
    /// bad parameters fall back to gamma 1, compression 1000 or 60 dB.
    #[inline]
    pub fn apply(&self, normalized_intensity: f64) -> f64 {
        if normalized_intensity.is_nan() || normalized_intensity <= 0.0 {
            return 0.0;
        }
        if normalized_intensity >= 1.0 {
            return 1.0;
        }

        match *self {
            TransferFunction::Linear => normalized_intensity,
            TransferFunction::Gamma(gamma) => {
                let g = if gamma <= 0.0 || gamma.is_nan() {
                    1.0
                } else {
                    gamma
                };
                normalized_intensity.powf(g)
            }
            TransferFunction::Logarithmic { compression } => {
                let a = if compression <= 0.0 || compression.is_nan() {
                    1000.0
                } else {
                    compression
                };
                (1.0 + a * normalized_intensity).ln() / (1.0 + a).ln()
            }
            TransferFunction::Decibel { dynamic_range_db } => {
                let d = if dynamic_range_db <= 0.0 || dynamic_range_db.is_nan() {
                    60.0
                } else {
                    dynamic_range_db
                };
                let floor_val = 10.0f64.powf(-d / 10.0);
                if normalized_intensity <= floor_val {
                    0.0
                } else {
                    let db = 10.0 * normalized_intensity.log10();
                    ((d + db) / d).clamp(0.0, 1.0)
                }
            }
        }
    }
}

/// An RGBA8 pixel.
#[repr(C)]
#[derive(Copy, Clone, Debug, PartialEq, Eq, Hash, Default)]
pub struct Rgba {
    pub r: u8,
    pub g: u8,
    pub b: u8,
    pub a: u8,
}

impl Rgba {
    pub const WHITE: Self = Self {
        r: 255,
        g: 255,
        b: 255,
        a: 255,
    };
    pub const BLACK: Self = Self {
        r: 0,
        g: 0,
        b: 0,
        a: 255,
    };

    #[inline(always)]
    pub const fn new(r: u8, g: u8, b: u8, a: u8) -> Self {
        Self { r, g, b, a }
    }

    #[inline(always)]
    pub const fn to_array(self) -> [u8; 4] {
        [self.r, self.g, self.b, self.a]
    }
}

impl From<[u8; 4]> for Rgba {
    #[inline(always)]
    fn from(arr: [u8; 4]) -> Self {
        Self {
            r: arr[0],
            g: arr[1],
            b: arr[2],
            a: arr[3],
        }
    }
}

impl From<Rgba> for [u8; 4] {
    #[inline(always)]
    fn from(rgba: Rgba) -> Self {
        [rgba.r, rgba.g, rgba.b, rgba.a]
    }
}

/// Colours of the Asympton palette (sRGB).
pub mod asympton_tokens {
    pub const CARBON_BLACK: [u8; 3] = [26, 29, 32]; // #1A1D20
    pub const CARBON_DARK: [u8; 3] = [12, 12, 12]; // #0C0C0C
    pub const MINERAL_SLATE: [u8; 3] = [142, 156, 168]; // #8E9CA8
    pub const MINERAL_LIGHT: [u8; 3] = [243, 241, 232]; // #F3F1E8
    pub const SIGNAL_YELLOW: [u8; 3] = [243, 198, 35]; // #F3C623
    pub const GOLD_ACCENT: [u8; 3] = [241, 204, 64]; // #F1CC40
    pub const HIGHLIGHT_CREAM: [u8; 3] = [255, 242, 178]; // #FFF2B2
}

/// Convert a wavelength to nanometres, guessing the unit.
///
/// Values in [10, 10000] are taken to be nanometres already; anything else is
/// metres. Non-positive or NaN input gives 632.8 nm.
#[inline]
pub fn wavelength_to_nm(wavelength: f64) -> f64 {
    if wavelength <= 0.0 || wavelength.is_nan() {
        632.8
    } else if wavelength < 1.0e-3 {
        wavelength * 1.0e9
    } else if (10.0..=10_000.0).contains(&wavelength) {
        wavelength
    } else {
        wavelength * 1.0e9
    }
}

/// Approximate perceived colour of monochromatic light, after Dan Bruton's
/// piecewise-linear spectrum. Outside 380-750 nm the edge colour is kept at 30%
/// brightness so UV and IR beams stay visible.
pub fn wavelength_to_rgb(wavelength_nm: f64) -> [u8; 3] {
    let w = wavelength_nm;
    let (raw_r, raw_g, raw_b) = if w < 380.0 {
        (0.5, 0.0, 1.0)
    } else if w < 440.0 {
        (-(w - 440.0) / (440.0 - 380.0), 0.0, 1.0)
    } else if w < 490.0 {
        (0.0, (w - 440.0) / (490.0 - 440.0), 1.0)
    } else if w < 510.0 {
        (0.0, 1.0, -(w - 510.0) / (510.0 - 490.0))
    } else if w < 580.0 {
        ((w - 510.0) / (580.0 - 510.0), 1.0, 0.0)
    } else if w < 645.0 {
        (1.0, -(w - 645.0) / (645.0 - 580.0), 0.0)
    } else {
        (1.0, 0.0, 0.0)
    };

    // Intensity falls off towards the limits of vision.
    let factor = if (380.0..420.0).contains(&w) {
        0.3 + 0.7 * (w - 380.0) / (420.0 - 380.0)
    } else if (420.0..=645.0).contains(&w) {
        1.0
    } else if (645.0..=750.0).contains(&w) {
        0.3 + 0.7 * (750.0 - w) / (750.0 - 645.0)
    } else {
        0.3
    };

    let gamma = 0.8;
    let r = (255.0 * (raw_r * factor).max(0.0).powf(gamma))
        .round()
        .clamp(0.0, 255.0) as u8;
    let g = (255.0 * (raw_g * factor).max(0.0).powf(gamma))
        .round()
        .clamp(0.0, 255.0) as u8;
    let b = (255.0 * (raw_b * factor).max(0.0).powf(gamma))
        .round()
        .clamp(0.0, 255.0) as u8;

    [r, g, b]
}

// Viridis, inferno and plasma use Matt Zucker's 6th-order polynomial fits to the
// matplotlib maps (CC0, https://www.shadertoy.com/view/WlfXRN), with a linear
// correction that pins both endpoints to the exact matplotlib colours.

type Poly6 = [[f64; 3]; 7];

const VIRIDIS_POLY: Poly6 = [
    [0.2777273272234177, 0.005407344544966578, 0.3340998053353061],
    [0.1050930431085774, 1.404613529898575, 1.384590162594685],
    [-0.3308618287255563, 0.214847559468213, 0.09509516302823659],
    [-4.634230498983486, -5.799100973351585, -19.33244095627987],
    [6.228269936347081, 14.17993336680509, 56.69055260068105],
    [4.776384997670288, -13.74514537774601, -65.35303263337234],
    [-5.435455855934631, 4.645852612178535, 26.3124352495832],
];

const INFERNO_POLY: Poly6 = [
    [
        0.0002189403691192265,
        0.001651004631001012,
        -0.01948089843709184,
    ],
    [0.1065134194856116, 0.5639564367884091, 3.932712388889277],
    [11.60249308247187, -3.972853965665698, -15.9423941062914],
    [-41.70399613139459, 17.43639888205313, 44.35414519872813],
    [77.162935699427, -33.40235894210092, -81.80730925738993],
    [-71.31942824499214, 32.62606426397723, 73.20951985803202],
    [25.13112622477341, -12.24266895238567, -23.07032500287172],
];

const PLASMA_POLY: Poly6 = [
    [0.05873234392399702, 0.02333670892565664, 0.5433401826748754],
    [2.176514634195958, 0.2383834171260182, 0.7539604599784036],
    [-2.689460476458034, -7.455851135738909, 3.110799939717086],
    [6.130348345893603, 42.3461881477227, -28.51885465332158],
    [-11.10743619062271, -82.66631109428045, 60.13984767418263],
    [10.02306557647065, 71.4136177009535, -54.07218655560067],
    [-3.658713842777788, -22.93153465461149, 18.19190778539828],
];

#[inline]
fn eval_poly6(c: &Poly6, t: f64) -> [f64; 3] {
    let mut out = [0.0; 3];
    for (ch, o) in out.iter_mut().enumerate() {
        *o = c.iter().rev().fold(0.0, |acc, row| acc * t + row[ch]);
    }
    out
}

/// Evaluate a fit, shifted linearly so t = 0 and t = 1 give `lo` and `hi` exactly.
#[inline]
fn poly_colormap(c: &Poly6, lo: [u8; 3], hi: [u8; 3], t: f64) -> [u8; 4] {
    let t_c = if t.is_nan() { 0.0 } else { t.clamp(0.0, 1.0) };
    let f0 = eval_poly6(c, 0.0);
    let f1 = eval_poly6(c, 1.0);
    let f = eval_poly6(c, t_c);
    let mut rgba = [0, 0, 0, 255];
    for ch in 0..3 {
        let e0 = lo[ch] as f64 / 255.0 - f0[ch];
        let e1 = hi[ch] as f64 / 255.0 - f1[ch];
        let v = f[ch] + e0 * (1.0 - t_c) + e1 * t_c;
        rgba[ch] = (v * 255.0).round().clamp(0.0, 255.0) as u8;
    }
    rgba
}

/// matplotlib's viridis: #440154 at 0, #fde725 at 1.
#[inline]
pub fn colormap_viridis(t: f64) -> [u8; 4] {
    poly_colormap(&VIRIDIS_POLY, [68, 1, 84], [253, 231, 37], t)
}

/// matplotlib's inferno: #000004 at 0, #fcffa4 at 1.
#[inline]
pub fn colormap_inferno(t: f64) -> [u8; 4] {
    poly_colormap(&INFERNO_POLY, [0, 0, 4], [252, 255, 164], t)
}

/// matplotlib's plasma: #0d0887 at 0, #f0f921 at 1.
#[inline]
pub fn colormap_plasma(t: f64) -> [u8; 4] {
    poly_colormap(&PLASMA_POLY, [13, 8, 135], [240, 249, 33], t)
}

/// Google's turbo, linearly interpolated between five stops.
#[inline]
pub fn colormap_turbo(t: f64) -> [u8; 4] {
    let t_c = if t.is_nan() { 0.0 } else { t.clamp(0.0, 1.0) };
    let stops: [(f64, [u8; 3]); 5] = [
        (0.00, [48, 18, 59]),
        (0.25, [30, 203, 237]),
        (0.50, [164, 252, 60]),
        (0.75, [251, 184, 38]),
        (1.00, [122, 4, 3]),
    ];
    for i in 0..stops.len() - 1 {
        let (t0, c0) = stops[i];
        let (t1, c1) = stops[i + 1];
        if t_c >= t0 && t_c <= t1 {
            let local_t = (t_c - t0) / (t1 - t0);
            return [
                (c0[0] as f64 + (c1[0] as f64 - c0[0] as f64) * local_t).round() as u8,
                (c0[1] as f64 + (c1[1] as f64 - c0[1] as f64) * local_t).round() as u8,
                (c0[2] as f64 + (c1[2] as f64 - c0[2] as f64) * local_t).round() as u8,
                255,
            ];
        }
    }
    [122, 4, 3, 255]
}

/// Ramps from black to the beam's spectral colour at 0.75, then on to white, so the
/// core looks overexposed the way a photographed laser spot does.
pub fn colormap_laser_glow(t: f64, wavelength_nm: f64) -> [u8; 4] {
    let t_c = if t.is_nan() { 0.0 } else { t.clamp(0.0, 1.0) };
    let base = wavelength_to_rgb(wavelength_nm);
    let r0 = base[0] as f64;
    let g0 = base[1] as f64;
    let b0 = base[2] as f64;

    let threshold = 0.75;
    let (r, g, b) = if t_c < threshold {
        let s = t_c / threshold;
        (r0 * s, g0 * s, b0 * s)
    } else {
        let u = (t_c - threshold) / (1.0 - threshold);
        (
            r0 + (255.0 - r0) * u,
            g0 + (255.0 - g0) * u,
            b0 + (255.0 - b0) * u,
        )
    };

    [
        r.round().clamp(0.0, 255.0) as u8,
        g.round().clamp(0.0, 255.0) as u8,
        b.round().clamp(0.0, 255.0) as u8,
        255,
    ]
}

/// Asympton palette: carbon black, mineral slate at 0.5, signal yellow at 0.85,
/// cream at 1.
#[inline]
pub fn colormap_asympton(t: f64) -> [u8; 4] {
    let t_c = if t.is_nan() { 0.0 } else { t.clamp(0.0, 1.0) };
    let (r, g, b) = if t_c < 0.5 {
        let s = t_c / 0.5;
        (
            26.0 + (142.0 - 26.0) * s,
            29.0 + (156.0 - 29.0) * s,
            32.0 + (168.0 - 32.0) * s,
        )
    } else if t_c < 0.85 {
        let s = (t_c - 0.5) / 0.35;
        (
            142.0 + (243.0 - 142.0) * s,
            156.0 + (198.0 - 156.0) * s,
            168.0 + (35.0 - 168.0) * s,
        )
    } else {
        let s = (t_c - 0.85) / 0.15;
        (
            243.0 + (255.0 - 243.0) * s,
            198.0 + (242.0 - 198.0) * s,
            35.0 + (178.0 - 35.0) * s,
        )
    };

    [
        r.round().clamp(0.0, 255.0) as u8,
        g.round().clamp(0.0, 255.0) as u8,
        b.round().clamp(0.0, 255.0) as u8,
        255,
    ]
}

/// Colour for `v` in [0, 1]. `wavelength_m` only matters for `LaserGlow`.
pub fn map_colormap(colormap: Colormap, v: f64, wavelength_m: f64) -> [u8; 4] {
    match colormap {
        Colormap::Viridis => colormap_viridis(v),
        Colormap::Inferno => colormap_inferno(v),
        Colormap::Plasma => colormap_plasma(v),
        Colormap::Turbo => colormap_turbo(v),
        Colormap::LaserGlow => {
            let nm = wavelength_to_nm(wavelength_m);
            colormap_laser_glow(v, nm)
        }
        Colormap::Asympton => colormap_asympton(v),
    }
}

/// [`map_colormap`] after applying `gamma`.
pub fn map_intensity_to_rgba(
    normalized_intensity: f64,
    gamma: f64,
    colormap: Colormap,
    wavelength_m: f64,
) -> [u8; 4] {
    let transfer = TransferFunction::from_gamma(gamma);
    let corrected = transfer.apply(normalized_intensity);
    map_colormap(colormap, corrected, wavelength_m)
}

/// [`map_colormap`] after applying `transfer`.
pub fn map_intensity_with_transfer(
    normalized_intensity: f64,
    transfer: TransferFunction,
    colormap: Colormap,
    wavelength_m: f64,
) -> [u8; 4] {
    let corrected = transfer.apply(normalized_intensity);
    map_colormap(colormap, corrected, wavelength_m)
}

/// A colormap and transfer function sampled at 256 levels.
#[derive(Clone, Debug, PartialEq)]
pub struct ColormapLut {
    table: [[u8; 4]; 256],
}

impl ColormapLut {
    /// Table with a linear transfer function.
    pub fn new(colormap: Colormap, wavelength_m: f64) -> Self {
        Self::with_gamma(colormap, wavelength_m, 1.0)
    }

    pub fn with_gamma(colormap: Colormap, wavelength_m: f64, gamma: f64) -> Self {
        Self::with_transfer(colormap, wavelength_m, TransferFunction::from_gamma(gamma))
    }

    pub fn with_transfer(
        colormap: Colormap,
        wavelength_m: f64,
        transfer: TransferFunction,
    ) -> Self {
        let mut table = [[0u8; 4]; 256];
        for (i, entry) in table.iter_mut().enumerate() {
            let t = i as f64 / 255.0;
            let corrected = transfer.apply(t);
            *entry = map_colormap(colormap, corrected, wavelength_m);
        }
        Self { table }
    }

    /// Nearest entry for a value in [0, 1] (clamped).
    #[inline(always)]
    pub fn lookup(&self, normalized_intensity: f64) -> [u8; 4] {
        let idx = (normalized_intensity.clamp(0.0, 1.0) * 255.0).round() as usize;
        self.table[idx.min(255)]
    }

    #[inline(always)]
    pub fn lookup_byte(&self, byte_val: u8) -> [u8; 4] {
        self.table[byte_val as usize]
    }

    pub fn as_slice(&self) -> &[[u8; 4]; 256] {
        &self.table
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn colormap_abi_discriminants() {
        assert_eq!(std::mem::size_of::<Colormap>(), 4);
        assert_eq!(Colormap::Viridis as u32, 0);
        assert_eq!(Colormap::Inferno as u32, 1);
        assert_eq!(Colormap::Plasma as u32, 2);
        assert_eq!(Colormap::Turbo as u32, 3);
        assert_eq!(Colormap::LaserGlow as u32, 4);
        assert_eq!(Colormap::Asympton as u32, 5);
    }

    #[test]
    fn render_style_matches_c_layout() {
        assert_eq!(std::mem::size_of::<RenderStyle>(), 32);
        assert_eq!(std::mem::align_of::<RenderStyle>(), 8);
    }

    #[test]
    fn viridis_luminance_increases() {
        let mut prev_lum = -1.0;
        for i in 0..=100 {
            let t = i as f64 / 100.0;
            let [r, g, b, _] = map_colormap(Colormap::Viridis, t, 632.8e-9);
            let lum = 0.2126 * r as f64 + 0.7152 * g as f64 + 0.0722 * b as f64;
            assert!(lum >= prev_lum - 0.5, "luminance dropped at t={}", t);
            prev_lum = lum;
        }
        let [r0, _, _, _] = map_colormap(Colormap::Viridis, 0.0, 632.8e-9);
        let [r1, g1, _, _] = map_colormap(Colormap::Viridis, 1.0, 632.8e-9);
        assert!(r0 < 100);
        assert!(r1 > 200 && g1 > 200);
    }

    #[test]
    fn perceptual_maps_match_matplotlib_reference() {
        // (map, t, matplotlib colour); midpoints from the published 256-entry tables.
        type Map = fn(f64) -> [u8; 4];
        let cases: [(Map, f64, [u8; 3]); 15] = [
            (colormap_viridis, 0.0, [68, 1, 84]),
            (colormap_viridis, 0.25, [59, 82, 139]),
            (colormap_viridis, 0.5, [33, 145, 140]),
            (colormap_viridis, 0.75, [94, 201, 98]),
            (colormap_viridis, 1.0, [253, 231, 37]),
            (colormap_inferno, 0.0, [0, 0, 4]),
            (colormap_inferno, 0.25, [87, 16, 110]),
            (colormap_inferno, 0.5, [188, 55, 84]),
            (colormap_inferno, 0.75, [249, 142, 9]),
            (colormap_inferno, 1.0, [252, 255, 164]),
            (colormap_plasma, 0.0, [13, 8, 135]),
            (colormap_plasma, 0.25, [126, 3, 168]),
            (colormap_plasma, 0.5, [204, 71, 120]),
            (colormap_plasma, 0.75, [248, 149, 64]),
            (colormap_plasma, 1.0, [240, 249, 33]),
        ];
        for (f, t, want) in cases {
            let got = f(t);
            for ch in 0..3 {
                let d = (got[ch] as i32 - want[ch] as i32).abs();
                assert!(d <= 6, "t={t}: got {got:?}, want {want:?}");
            }
        }
    }

    #[test]
    fn inferno_spans_dark_to_bright() {
        let [r0, g0, b0, _] = map_colormap(Colormap::Inferno, 0.0, 632.8e-9);
        let [r1, g1, b1, _] = map_colormap(Colormap::Inferno, 1.0, 632.8e-9);
        let lum0 = 0.2126 * r0 as f64 + 0.7152 * g0 as f64 + 0.0722 * b0 as f64;
        let lum1 = 0.2126 * r1 as f64 + 0.7152 * g1 as f64 + 0.0722 * b1 as f64;
        assert!(lum1 - lum0 > 220.0);
        assert!(lum0 < 15.0);
    }

    #[test]
    fn plasma_midtones_are_saturated() {
        for i in 20..=80 {
            let t = i as f64 / 100.0;
            let [r, g, b, _] = map_colormap(Colormap::Plasma, t, 632.8e-9);
            let delta = r.max(g).max(b) - r.min(g).min(b);
            assert!(delta >= 50);
        }
    }

    #[test]
    fn laser_glow_black_to_white_through_beam_colour() {
        let peak = map_colormap(Colormap::LaserGlow, 1.0, 532.0e-9);
        assert_eq!(peak, [255, 255, 255, 255]);
        let zero = map_colormap(Colormap::LaserGlow, 0.0, 532.0e-9);
        assert_eq!(zero, [0, 0, 0, 255]);
        let mid = map_colormap(Colormap::LaserGlow, 0.5, 532.0e-9);
        assert!(mid[1] > mid[0] && mid[1] > mid[2]);
    }

    #[test]
    fn asympton_stops() {
        let p0 = map_colormap(Colormap::Asympton, 0.0, 632.8e-9);
        assert_eq!(p0, [26, 29, 32, 255]);
        let p_mid = map_colormap(Colormap::Asympton, 0.5, 632.8e-9);
        assert_eq!(p_mid, [142, 156, 168, 255]);
        let p_acc = map_colormap(Colormap::Asympton, 0.85, 632.8e-9);
        assert_eq!(p_acc, [243, 198, 35, 255]);
    }

    #[test]
    fn transfer_functions_are_monotonic_and_bounded() {
        let transfers = [
            TransferFunction::Linear,
            TransferFunction::Gamma(0.5),
            TransferFunction::Gamma(2.2),
            TransferFunction::Decibel {
                dynamic_range_db: 60.0,
            },
            TransferFunction::Logarithmic {
                compression: 1000.0,
            },
        ];
        for tf in transfers {
            assert_eq!(tf.apply(0.0), 0.0);
            assert_eq!(tf.apply(1.0), 1.0);
            assert_eq!(tf.apply(-5.0), 0.0);
            assert_eq!(tf.apply(5.0), 1.0);
            let mut prev = -1.0;
            for step in 0..=100 {
                let v = step as f64 / 100.0;
                let val = tf.apply(v);
                assert!(val >= prev - 1e-9);
                prev = val;
            }
        }
    }

    #[test]
    fn lut_matches_direct_mapping() {
        let lut = ColormapLut::new(Colormap::Turbo, 632.8e-9);
        for i in 0..256 {
            let t = i as f64 / 255.0;
            let direct = map_colormap(Colormap::Turbo, t, 632.8e-9);
            let lut_val = lut.lookup_byte(i as u8);
            assert_eq!(direct, lut_val);
        }
    }

    #[test]
    fn wavelength_unit_guessing_and_colour() {
        assert_eq!(wavelength_to_nm(-1.0), 632.8);
        assert_eq!(wavelength_to_nm(f64::NAN), 632.8);

        assert!((wavelength_to_nm(632.8e-9) - 632.8).abs() < 1e-9);

        assert_eq!(wavelength_to_nm(532.0), 532.0);

        // 1 m is metres, not nanometres, so it should come out as dim IR red rather than UV violet.
        let nm_1m = wavelength_to_nm(1.0);
        assert!(nm_1m >= 1e9);
        let rgb_1m = wavelength_to_rgb(nm_1m);
        assert_eq!(rgb_1m, [97, 0, 0]);

        let nm_1nm = wavelength_to_nm(1e-9);
        assert!((nm_1nm - 1.0).abs() < 1e-9);
        let rgb_1nm = wavelength_to_rgb(nm_1nm);
        assert_eq!(rgb_1nm, [56, 0, 97]);
    }
}
