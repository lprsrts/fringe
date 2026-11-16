//! A validated scene compiled for one solve: bodies, incident field, the PML
//! rectangle and the solver settings resolved for the requested quality.

use crate::geometry::{bodies_from_scene, Body, BodyMaterial};
use crate::scene::{validate, Issue, PecFormulation, Scene};
use crate::solver::field::GridSpec;
use crate::solver::{Method, Quality};
use crate::source::Incident;
use crate::types::{Rect, Vec2};

pub struct Problem {
    pub scene: Scene,
    pub quality: Quality,
    pub lambda0: f64,
    pub k0: f64,
    pub n_b: f64,
    pub k_b: f64,
    pub eps_b: f64,
    /// Largest real index among the background and enabled dielectric bodies.
    pub n_max: f64,
    pub bodies: Vec<Body>,
    /// Analytic incident field, accurate on the PML outer rectangle.
    pub incident: Incident,
    /// The scene's domain: the visible interior, PML outside it.
    pub interior: Rect,
    pub pml_um: f64,
    pub settings: Resolved,
}

impl Problem {
    /// Interior expanded by the PML thickness.
    pub fn outer(&self) -> Rect {
        self.interior.expand(self.pml_um)
    }

    pub fn lambda_b(&self) -> f64 {
        self.lambda0 / self.n_b
    }

    pub fn lambda_min(&self) -> f64 {
        self.lambda0 / self.n_max
    }

    /// The grid FEM and MoM sample their result on: spacing λ_min / output_ppw,
    /// anchored at the interior's lower-left corner.
    pub fn output_grid(&self) -> GridSpec {
        GridSpec::covering(self.interior, self.lambda_min() / self.settings.output_ppw)
    }

    /// Index of the body containing `p`, if any. Bodies are disjoint.
    pub fn body_at(&self, p: Vec2) -> Option<usize> {
        self.bodies.iter().position(|b| b.inside(p))
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct FdtdResolved {
    pub courant: f64,
    pub max_periods: Option<u32>,
    pub steady_tol: f64,
    pub subpixel: bool,
    pub dispersion_correction: bool,
    /// Sub-samples per cell side for material averaging (4 or 8).
    pub supersample: usize,
    pub min_pml_cells: usize,
}

#[derive(Clone, Debug, PartialEq)]
pub struct FemResolved {
    pub order: u8,
    pub pml_reflection: f64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct MomResolved {
    pub pec_formulation: PecFormulation,
    pub cfie_beta_scale: f64,
    pub corner_grading: bool,
    /// Gauss–Legendre points per far panel.
    pub far_quad: usize,
    pub max_unknowns: usize,
}

/// Solver settings after applying the per-quality defaults (spec §2.3) and the
/// scene's overrides.
#[derive(Clone, Debug, PartialEq)]
pub struct Resolved {
    pub method: Method,
    pub quality: Quality,
    /// FDTD: cells per λ_min; FEM: nodes per local λ; MoM: panels per local λ.
    pub ppw: f64,
    /// FEM/MoM output samples per λ_min.
    pub output_ppw: f64,
    pub pml_um: f64,
    pub memory_limit_mb: f64,
    pub fdtd: FdtdResolved,
    pub fem: FemResolved,
    pub mom: MomResolved,
}

/// The defaults table. Wave 3 may retune the numbers.
pub mod defaults {
    use crate::solver::{Method, Quality};

    pub fn ppw(method: Method, q: Quality) -> f64 {
        match (method, q) {
            (Method::Fdtd, Quality::Preview) => 10.0,
            (Method::Fdtd, Quality::Final) => 24.0,
            (Method::Fem, Quality::Preview) => 9.0,
            (Method::Fem, Quality::Final) => 15.0,
            (Method::Mom, Quality::Preview) => 8.0,
            (Method::Mom, Quality::Final) => 16.0,
        }
    }

    pub fn output_ppw(q: Quality) -> f64 {
        match q {
            Quality::Preview => 6.0,
            Quality::Final => 12.0,
        }
    }

    pub fn memory_limit_mb(q: Quality) -> f64 {
        match q {
            Quality::Preview => 1024.0,
            Quality::Final => 6144.0,
        }
    }

    pub fn steady_tol(q: Quality) -> f64 {
        match q {
            Quality::Preview => 5e-3,
            Quality::Final => 5e-4,
        }
    }

    pub fn supersample(q: Quality) -> usize {
        match q {
            Quality::Preview => 4,
            Quality::Final => 8,
        }
    }

    pub fn min_pml_cells(q: Quality) -> usize {
        match q {
            Quality::Preview => 10,
            Quality::Final => 16,
        }
    }

    pub fn far_quad(q: Quality) -> usize {
        match q {
            Quality::Preview => 1,
            Quality::Final => 2,
        }
    }

    pub fn max_unknowns(q: Quality) -> usize {
        match q {
            Quality::Preview => 4000,
            Quality::Final => 12000,
        }
    }
}

impl Resolved {
    pub fn new(scene: &Scene, quality: Quality) -> Resolved {
        let s = &scene.solver;
        let method = s.method;
        let pick = |preview: Option<f64>, fin: Option<f64>| match quality {
            Quality::Preview => preview,
            Quality::Final => fin,
        };
        let ppw_override = match method {
            Method::Fdtd => pick(s.fdtd.preview_ppw, s.fdtd.final_ppw),
            Method::Fem => pick(s.fem.preview_ppw, s.fem.final_ppw),
            Method::Mom => pick(s.mom.preview_ppw, s.mom.final_ppw),
        };
        let lambda_b = scene.wavelength_um / scene.background.n;
        Resolved {
            method,
            quality,
            ppw: ppw_override.unwrap_or_else(|| defaults::ppw(method, quality)),
            output_ppw: pick(s.output.preview_ppw, s.output.final_ppw).unwrap_or_else(|| defaults::output_ppw(quality)),
            pml_um: scene.domain.pml_wl * lambda_b,
            memory_limit_mb: s.memory_limit_mb.unwrap_or_else(|| defaults::memory_limit_mb(quality)),
            fdtd: FdtdResolved {
                courant: s.fdtd.courant,
                max_periods: s.fdtd.max_periods,
                steady_tol: s.fdtd.steady_tol.unwrap_or_else(|| defaults::steady_tol(quality)),
                subpixel: s.fdtd.subpixel,
                dispersion_correction: s.fdtd.dispersion_correction,
                supersample: defaults::supersample(quality),
                min_pml_cells: defaults::min_pml_cells(quality),
            },
            fem: FemResolved { order: s.fem.order, pml_reflection: s.fem.pml_reflection },
            mom: MomResolved {
                pec_formulation: s.mom.pec_formulation,
                cfie_beta_scale: s.mom.cfie_beta_scale,
                corner_grading: s.mom.corner_grading,
                far_quad: defaults::far_quad(quality),
                max_unknowns: defaults::max_unknowns(quality),
            },
        }
    }
}

/// Validates `scene` and compiles it for a solve at `quality`. Errors are the
/// validation errors that apply to that quality.
pub fn compile(scene: &Scene, quality: Quality) -> Result<Problem, Vec<Issue>> {
    let errors: Vec<Issue> = validate(scene)
        .into_iter()
        .filter(|i| i.is_error() && i.applies_to(quality))
        .collect();
    if !errors.is_empty() {
        return Err(errors);
    }
    Ok(compile_unchecked(scene, quality))
}

/// [`compile`] without validation, for scenes already known to be valid.
pub fn compile_unchecked(scene: &Scene, quality: Quality) -> Problem {
    let lambda0 = scene.wavelength_um;
    let k0 = 2.0 * std::f64::consts::PI / lambda0;
    let n_b = scene.background.n;
    let bodies = bodies_from_scene(scene);
    let n_max = bodies
        .iter()
        .filter_map(|b| match b.material {
            BodyMaterial::Dielectric { n, .. } => Some(n.re),
            BodyMaterial::Pec => None,
        })
        .fold(n_b, f64::max);
    let settings = Resolved::new(scene, quality);
    let interior = scene.domain.rect();
    let pml_um = settings.pml_um;
    let incident = Incident::from_scene(scene, interior.expand(pml_um));
    Problem {
        scene: scene.clone(),
        quality,
        lambda0,
        k0,
        n_b,
        k_b: k0 * n_b,
        eps_b: n_b * n_b,
        n_max,
        bodies,
        incident,
        interior,
        pml_um,
        settings,
    }
}
