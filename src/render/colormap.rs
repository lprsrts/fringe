//! Colormaps. Every map takes t in [0, 1] (clamped; NaN maps to 0) and returns
//! opaque sRGB RGBA8.

use std::str::FromStr;

#[derive(Copy, Clone, Debug, PartialEq, Eq, Hash, Default)]
pub enum Colormap {
    Viridis,
    #[default]
    Inferno,
    Plasma,
    Turbo,
    LaserGlow,
    Asympton,
    RdBu,
    SpectralGlow,
    Twilight,
    PhaseWheel,
}

/// How a map is meant to be read: ordered values, values around a neutral
/// midpoint, or angles.
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub enum ColormapKind {
    Sequential,
    Diverging,
    Cyclic,
}

impl Colormap {
    pub const ALL: [Colormap; 10] = [
        Colormap::Viridis,
        Colormap::Inferno,
        Colormap::Plasma,
        Colormap::Turbo,
        Colormap::LaserGlow,
        Colormap::Asympton,
        Colormap::RdBu,
        Colormap::SpectralGlow,
        Colormap::Twilight,
        Colormap::PhaseWheel,
    ];

    /// Name accepted by `from_str`, e.g. `"laser_glow"`.
    pub const fn name(&self) -> &'static str {
        match self {
            Colormap::Viridis => "viridis",
            Colormap::Inferno => "inferno",
            Colormap::Plasma => "plasma",
            Colormap::Turbo => "turbo",
            Colormap::LaserGlow => "laser_glow",
            Colormap::Asympton => "asympton",
            Colormap::RdBu => "rdbu",
            Colormap::SpectralGlow => "spectral_glow",
            Colormap::Twilight => "twilight",
            Colormap::PhaseWheel => "phase_wheel",
        }
    }

    pub const fn kind(&self) -> ColormapKind {
        match self {
            Colormap::RdBu | Colormap::SpectralGlow => ColormapKind::Diverging,
            Colormap::Twilight | Colormap::PhaseWheel => ColormapKind::Cyclic,
            _ => ColormapKind::Sequential,
        }
    }

    /// Colour for `t`; `wavelength_nm` only matters for the laser maps.
    pub fn map(&self, t: f64, wavelength_nm: f64) -> [u8; 4] {
        match self {
            Colormap::Viridis => colormap_viridis(t),
            Colormap::Inferno => colormap_inferno(t),
            Colormap::Plasma => colormap_plasma(t),
            Colormap::Turbo => colormap_turbo(t),
            Colormap::LaserGlow => colormap_laser_glow(t, wavelength_nm),
            Colormap::Asympton => colormap_asympton(t),
            Colormap::RdBu => colormap_rdbu(t),
            Colormap::SpectralGlow => colormap_spectral_glow(t, wavelength_nm),
            Colormap::Twilight => colormap_twilight(t),
            Colormap::PhaseWheel => colormap_phase_wheel(t),
        }
    }

    /// `n` colours sampled at t = i/(n − 1).
    pub fn lut(&self, wavelength_nm: f64, n: usize) -> Vec<[u8; 4]> {
        let n = n.max(2);
        (0..n).map(|i| self.map(i as f64 / (n - 1) as f64, wavelength_nm)).collect()
    }
}

impl FromStr for Colormap {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let key = s.trim().to_lowercase().replace('-', "_");
        let key = match key.as_str() {
            "laserglow" | "laser" => "laser_glow",
            "rd_bu" => "rdbu",
            "spectralglow" => "spectral_glow",
            "phasewheel" | "phase" => "phase_wheel",
            k => k,
        }
        .to_string();
        Colormap::ALL.iter().copied().find(|c| c.name() == key).ok_or_else(|| {
            let names: Vec<&str> = Colormap::ALL.iter().map(|c| c.name()).collect();
            format!("unknown colormap '{}' (expected one of {})", s.trim(), names.join(", "))
        })
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

// ColorBrewer RdBu-11, reversed so that t = 0 is blue.
const RDBU: [[u8; 3]; 11] = [
    [0x05, 0x30, 0x61],
    [0x21, 0x66, 0xac],
    [0x43, 0x93, 0xc3],
    [0x92, 0xc5, 0xde],
    [0xd1, 0xe5, 0xf0],
    [0xf7, 0xf7, 0xf7],
    [0xfd, 0xdb, 0xc7],
    [0xf4, 0xa5, 0x82],
    [0xd6, 0x60, 0x4d],
    [0xb2, 0x18, 0x2b],
    [0x67, 0x00, 0x1f],
];

fn srgb_to_linear(c: u8) -> f64 {
    let v = c as f64 / 255.0;
    if v <= 0.04045 {
        v / 12.92
    } else {
        ((v + 0.055) / 1.055).powf(2.4)
    }
}

fn linear_to_srgb(v: f64) -> u8 {
    let v = v.clamp(0.0, 1.0);
    let s = if v <= 0.003_130_8 { 12.92 * v } else { 1.055 * v.powf(1.0 / 2.4) - 0.055 };
    (s * 255.0).round().clamp(0.0, 255.0) as u8
}

fn clamp_t(t: f64) -> f64 {
    if t.is_nan() {
        0.0
    } else {
        t.clamp(0.0, 1.0)
    }
}

/// Equally spaced stops interpolated in sRGB (`linear = false`) or in linear light.
fn stops(table: &[[u8; 3]], t: f64, linear: bool) -> [u8; 4] {
    let t = clamp_t(t) * (table.len() - 1) as f64;
    let i = (t.floor() as usize).min(table.len() - 2);
    let f = t - i as f64;
    let mut out = [0, 0, 0, 255];
    for ch in 0..3 {
        let (a, b) = (table[i][ch], table[i + 1][ch]);
        out[ch] = if linear {
            linear_to_srgb(srgb_to_linear(a) * (1.0 - f) + srgb_to_linear(b) * f)
        } else {
            (a as f64 * (1.0 - f) + b as f64 * f).round() as u8
        };
    }
    out
}

/// Diverging blue–white–red (ColorBrewer RdBu, reversed), interpolated in linear light.
pub fn colormap_rdbu(t: f64) -> [u8; 4] {
    stops(&RDBU, t, true)
}

/// Diverging with a black centre: the beam's colour above 0.5 and its spectral
/// complement below, both ramping through [`colormap_laser_glow`].
pub fn colormap_spectral_glow(t: f64, wavelength_nm: f64) -> [u8; 4] {
    let t = clamp_t(t);
    let a = (2.0 * t - 1.0).abs();
    if t >= 0.5 {
        colormap_laser_glow(a, wavelength_nm)
    } else {
        colormap_laser_glow(a, (1160.0 - wavelength_nm).clamp(400.0, 700.0))
    }
}

// An approximation of matplotlib's twilight with nine sRGB stops.
const TWILIGHT: [[u8; 3]; 9] = [
    [226, 217, 226],
    [160, 180, 205],
    [100, 125, 192],
    [98, 72, 170],
    [48, 20, 58],
    [125, 42, 85],
    [178, 92, 82],
    [210, 165, 155],
    [226, 217, 226],
];

/// Cyclic, light at both ends and dark in the middle.
pub fn colormap_twilight(t: f64) -> [u8; 4] {
    stops(&TWILIGHT, t, false)
}

/// Cyclic hue wheel: `0.5 + 0.5 cos(2π(t − {0, 1/3, 2/3}))` scaled to 0.12–0.95.
pub fn colormap_phase_wheel(t: f64) -> [u8; 4] {
    let t = clamp_t(t);
    let mut out = [0, 0, 0, 255];
    for (ch, o) in out.iter_mut().take(3).enumerate() {
        let v = 0.5 + 0.5 * (2.0 * std::f64::consts::PI * (t - ch as f64 / 3.0)).cos();
        *o = ((0.12 + 0.83 * v) * 255.0).round() as u8;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_round_trip() {
        for c in Colormap::ALL {
            assert_eq!(c.name().parse::<Colormap>().unwrap(), c);
        }
        assert!("nope".parse::<Colormap>().is_err());
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
    fn laser_glow_black_to_white_through_beam_colour() {
        assert_eq!(colormap_laser_glow(1.0, 532.0), [255, 255, 255, 255]);
        assert_eq!(colormap_laser_glow(0.0, 532.0), [0, 0, 0, 255]);
        let mid = colormap_laser_glow(0.5, 532.0);
        assert!(mid[1] > mid[0] && mid[1] > mid[2]);
    }

    #[test]
    fn asympton_stops() {
        assert_eq!(colormap_asympton(0.0), [26, 29, 32, 255]);
        assert_eq!(colormap_asympton(0.5), [142, 156, 168, 255]);
        assert_eq!(colormap_asympton(0.85), [243, 198, 35, 255]);
    }

    #[test]
    fn rdbu_endpoints_and_midpoint() {
        assert_eq!(colormap_rdbu(0.0), [0x05, 0x30, 0x61, 255]);
        assert_eq!(colormap_rdbu(1.0), [0x67, 0x00, 0x1f, 255]);
        assert_eq!(colormap_rdbu(0.5), [0xf7, 0xf7, 0xf7, 255]);
    }

    #[test]
    fn spectral_glow_is_black_in_the_middle() {
        assert_eq!(colormap_spectral_glow(0.5, 633.0), [0, 0, 0, 255]);
        assert_eq!(colormap_spectral_glow(1.0, 633.0), [255, 255, 255, 255]);
    }

    #[test]
    fn wavelength_colour() {
        assert_eq!(wavelength_to_rgb(1e9), [97, 0, 0]);
        assert_eq!(wavelength_to_rgb(1.0), [56, 0, 97]);
    }
}
