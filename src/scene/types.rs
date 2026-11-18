//! Scene JSON, schema version 3.
//!
//! Lengths are micrometres and angles degrees. Every type rejects unknown keys,
//! and optional settings have defaults so a minimal scene parses.

use serde::{Deserialize, Serialize};

use crate::solver::Method;

pub const SCHEMA_VERSION: u32 = 3;

/// The oldest version [`crate::scene::parse_scene`] still reads (and upgrades).
pub const OLDEST_SCHEMA_VERSION: u32 = 2;

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
    /// At least one must be enabled. Version 2 had a single `source`.
    pub sources: Vec<Source>,
    #[serde(default)]
    pub elements: Vec<Element>,
    /// Where the solved field is measured (see [`crate::detectors`]).
    #[serde(default)]
    pub detectors: Vec<Detector>,
    pub domain: Domain,
    #[serde(default)]
    pub solver: SolverSettings,
}

impl Scene {
    pub fn enabled_sources(&self) -> impl Iterator<Item = &Source> {
        self.sources.iter().filter(|s| s.enabled)
    }

    /// The field scale used for "incident" normalisation: the sum of the
    /// enabled sources' amplitudes, which bounds the incident field away from
    /// emitters (1 when nothing is enabled).
    pub fn incident_scale(&self) -> f64 {
        let s: f64 = self.enabled_sources().map(|s| s.kind.amplitude()).sum();
        if s.is_finite() && s > 0.0 {
            s
        } else {
            1.0
        }
    }

    /// The first enabled plane wave or Gaussian beam, the "main beam" for
    /// quantities that need a direction.
    pub fn first_beam(&self) -> Option<&Source> {
        self.enabled_sources().find(|s| s.kind.angle_deg().is_some())
    }
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

/// One coherent source. All enabled sources radiate at the scene wavelength and
/// their incident fields add.
///
/// The common keys sit beside the kind's own (`{"type": "plane_wave", "id": …,
/// "angle_deg": …}`). Unknown keys are still rejected: the flattened kind sees
/// every key but these three, and denies the ones it does not know.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Source {
    pub id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default = "yes")]
    pub enabled: bool,
    #[serde(flatten)]
    pub kind: SourceKind,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum SourceKind {
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
    /// A line current along z through (x, y): in the plane, a point emitter of
    /// cylindrical waves, `E = A e^{jφ} H0⁽²⁾(k_b r) / |H0⁽²⁾(2π)|`, so that
    /// |E| ≈ A one background wavelength away.
    LineSource {
        x_um: f64,
        y_um: f64,
        #[serde(default = "one")]
        amplitude: f64,
        #[serde(default)]
        phase_deg: f64,
    },
}

impl SourceKind {
    pub fn kind_name(&self) -> &'static str {
        match self {
            SourceKind::PlaneWave { .. } => "plane_wave",
            SourceKind::GaussianBeam { .. } => "gaussian_beam",
            SourceKind::LineSource { .. } => "line_source",
        }
    }

    /// The propagation direction; `None` for a line source, which has none.
    pub fn angle_deg(&self) -> Option<f64> {
        match *self {
            SourceKind::PlaneWave { angle_deg, .. } | SourceKind::GaussianBeam { angle_deg, .. } => Some(angle_deg),
            SourceKind::LineSource { .. } => None,
        }
    }

    pub fn amplitude(&self) -> f64 {
        match *self {
            SourceKind::PlaneWave { amplitude, .. }
            | SourceKind::GaussianBeam { amplitude, .. }
            | SourceKind::LineSource { amplitude, .. } => amplitude,
        }
    }

    pub fn phase_deg(&self) -> f64 {
        match *self {
            SourceKind::PlaneWave { phase_deg, .. }
            | SourceKind::GaussianBeam { phase_deg, .. }
            | SourceKind::LineSource { phase_deg, .. } => phase_deg,
        }
    }
}

impl Source {
    /// An enabled source with an empty name.
    pub fn new(id: impl Into<String>, kind: SourceKind) -> Source {
        Source { id: id.into(), name: String::new(), enabled: true, kind }
    }
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum Material {
    Pec,
    /// Complex index n + ik in the optics convention: k ≥ 0 absorbs.
    Dielectric {
        n: f64,
        #[serde(default)]
        k: f64,
    },
    /// Lorentz–Drude model `ε(ω) = ε∞ + Σ poles`, evaluated at the scene
    /// wavelength (see [`crate::scene::materials`]).
    Dispersive {
        /// Which library entry the numbers came from, if any. Only a label: the
        /// numbers below are what is solved.
        #[serde(default)]
        preset: Option<String>,
        eps_inf: f64,
        #[serde(default)]
        poles: Vec<Pole>,
    },
}

/// One term of a dispersive material, with frequencies as photon energies in eV.
#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum Pole {
    /// `−ωp² / (ω² − jγω)`
    Drude { plasma_ev: f64, gamma_ev: f64 },
    /// `Δε·ω0² / (ω0² − ω² + jγω)`
    Lorentz { strength: f64, resonance_ev: f64, gamma_ev: f64 },
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
    /// Anchor; where it sits on the shape is defined per shape.
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

/// A place where the solved field is measured. Detectors do not change the
/// solve; they are read from the field afterwards.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Detector {
    pub id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default = "yes")]
    pub enabled: bool,
    pub shape: DetectorShape,
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum DetectorShape {
    /// Power flux through the segment from p1 to p2, counted positive along the
    /// normal to the right of p1 → p2.
    Line { x1_um: f64, y1_um: f64, x2_um: f64, y2_um: f64 },
    /// Mean and integral of |E|² over an axis-aligned rectangle centred on (x, y).
    Box { x_um: f64, y_um: f64, width_um: f64, height_um: f64 },
}

impl DetectorShape {
    pub fn kind_name(&self) -> &'static str {
        match self {
            DetectorShape::Line { .. } => "line",
            DetectorShape::Box { .. } => "box",
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
