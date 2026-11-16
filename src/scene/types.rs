//! Scene JSON, schema version 2 (spec §3.1).
//!
//! Lengths are micrometres and angles degrees. Every type rejects unknown keys,
//! and optional settings have defaults so a minimal scene parses.

use serde::{Deserialize, Serialize};

use crate::solver::Method;

pub const SCHEMA_VERSION: u32 = 2;

fn one() -> f64 {
    1.0
}

fn yes() -> bool {
    true
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Scene {
    pub version: u32,
    /// Vacuum wavelength λ0.
    pub wavelength_um: f64,
    pub background: Background,
    #[serde(default)]
    pub polarization: Polarization,
    pub source: Source,
    #[serde(default)]
    pub elements: Vec<Element>,
    pub domain: Domain,
    #[serde(default)]
    pub solver: SolverSettings,
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Background {
    /// Real refractive index of the surrounding medium.
    pub n: f64,
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq, Default)]
#[serde(rename_all = "snake_case")]
pub enum Polarization {
    /// E along z, out of the simulation plane.
    #[default]
    Ez,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum Source {
    PlaneWave {
        angle_deg: f64,
        #[serde(default = "one")]
        amplitude: f64,
        #[serde(default)]
        phase_deg: f64,
    },
    GaussianBeam {
        /// w0: 1/e field radius (1/e² intensity radius) in the background medium.
        waist_um: f64,
        /// Waist centre, as if no elements were present.
        waist_x_um: f64,
        waist_y_um: f64,
        #[serde(default)]
        angle_deg: f64,
        #[serde(default = "one")]
        amplitude: f64,
        #[serde(default)]
        phase_deg: f64,
    },
}

impl Source {
    pub fn angle_deg(&self) -> f64 {
        match *self {
            Source::PlaneWave { angle_deg, .. } | Source::GaussianBeam { angle_deg, .. } => angle_deg,
        }
    }

    pub fn amplitude(&self) -> f64 {
        match *self {
            Source::PlaneWave { amplitude, .. } | Source::GaussianBeam { amplitude, .. } => amplitude,
        }
    }

    pub fn phase_deg(&self) -> f64 {
        match *self {
            Source::PlaneWave { phase_deg, .. } | Source::GaussianBeam { phase_deg, .. } => phase_deg,
        }
    }
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum Material {
    Pec,
    /// Complex index n + ik in the optics convention: k ≥ 0 absorbs.
    Dielectric {
        n: f64,
        #[serde(default)]
        k: f64,
    },
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Element {
    pub id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default = "yes")]
    pub enabled: bool,
    pub material: Material,
    /// Anchor; where it sits on the shape is defined per shape (spec §3.2).
    pub x_um: f64,
    pub y_um: f64,
    /// Counter-clockwise about the anchor. Local +x is the element's optical axis.
    #[serde(default)]
    pub rotation_deg: f64,
    pub shape: Shape,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum Shape {
    /// Radii in the optics sign convention: R > 0 has its centre of curvature on +x;
    /// `None` is a flat surface.
    Lens {
        r1_um: Option<f64>,
        r2_um: Option<f64>,
        center_thickness_um: f64,
        aperture_um: f64,
    },
    Slab {
        thickness_um: f64,
        height_um: f64,
    },
    Wedge {
        thick_um: f64,
        thin_um: f64,
        height_um: f64,
    },
    Prism {
        base_um: f64,
        apex_deg: f64,
    },
    /// R > 0 is concave toward −x; `None` is flat.
    Mirror {
        aperture_um: f64,
        thickness_um: f64,
        radius_um: Option<f64>,
    },
    Slits {
        count: u32,
        slit_width_um: f64,
        pitch_um: f64,
        screen_height_um: f64,
        thickness_um: f64,
    },
    Grating {
        period_um: f64,
        fill_factor: f64,
        depth_um: f64,
        count: u32,
        #[serde(default)]
        substrate_um: f64,
    },
    Cylinder {
        radius_um: f64,
    },
    Waveguide {
        width_um: f64,
        length_um: f64,
    },
    Polygon {
        vertices_um: Vec<[f64; 2]>,
    },
}

impl Shape {
    pub fn kind_name(&self) -> &'static str {
        match self {
            Shape::Lens { .. } => "lens",
            Shape::Slab { .. } => "slab",
            Shape::Wedge { .. } => "wedge",
            Shape::Prism { .. } => "prism",
            Shape::Mirror { .. } => "mirror",
            Shape::Slits { .. } => "slits",
            Shape::Grating { .. } => "grating",
            Shape::Cylinder { .. } => "cylinder",
            Shape::Waveguide { .. } => "waveguide",
            Shape::Polygon { .. } => "polygon",
        }
    }
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Domain {
    /// Interior (visible) rectangle; the PML is added outside it.
    pub x_min_um: f64,
    pub x_max_um: f64,
    pub y_min_um: f64,
    pub y_max_um: f64,
    /// PML thickness in background wavelengths.
    #[serde(default = "one")]
    pub pml_wl: f64,
}

impl Domain {
    pub fn rect(&self) -> crate::types::Rect {
        crate::types::Rect::new(self.x_min_um, self.x_max_um, self.y_min_um, self.y_max_um)
    }
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Default)]
#[serde(default, deny_unknown_fields)]
pub struct SolverSettings {
    pub method: Method,
    pub fdtd: FdtdSettings,
    pub fem: FemSettings,
    pub mom: MomSettings,
    pub output: OutputSampling,
    pub memory_limit_mb: Option<f64>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(default, deny_unknown_fields)]
pub struct FdtdSettings {
    pub preview_ppw: Option<f64>,
    pub final_ppw: Option<f64>,
    pub courant: f64,
    pub max_periods: Option<u32>,
    pub steady_tol: Option<f64>,
    pub subpixel: bool,
    pub dispersion_correction: bool,
}

impl Default for FdtdSettings {
    fn default() -> Self {
        Self {
            preview_ppw: None,
            final_ppw: None,
            courant: 0.6,
            max_periods: None,
            steady_tol: None,
            subpixel: true,
            dispersion_correction: true,
        }
    }
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(default, deny_unknown_fields)]
pub struct FemSettings {
    pub preview_ppw: Option<f64>,
    pub final_ppw: Option<f64>,
    pub order: u8,
    pub pml_reflection: f64,
}

impl Default for FemSettings {
    fn default() -> Self {
        Self {
            preview_ppw: None,
            final_ppw: None,
            order: 3,
            pml_reflection: 1e-6,
        }
    }
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(default, deny_unknown_fields)]
pub struct MomSettings {
    pub preview_ppw: Option<f64>,
    pub final_ppw: Option<f64>,
    pub pec_formulation: PecFormulation,
    pub cfie_beta_scale: f64,
    pub corner_grading: bool,
}

impl Default for MomSettings {
    fn default() -> Self {
        Self {
            preview_ppw: None,
            final_ppw: None,
            pec_formulation: PecFormulation::Auto,
            cfie_beta_scale: 1.0,
            corner_grading: true,
        }
    }
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq, Default)]
#[serde(rename_all = "snake_case")]
pub enum PecFormulation {
    #[default]
    Auto,
    Cfie,
    Efie,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Default)]
#[serde(default, deny_unknown_fields)]
pub struct OutputSampling {
    pub preview_ppw: Option<f64>,
    pub final_ppw: Option<f64>,
}
