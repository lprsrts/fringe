//! The solver validation cases: scenes, references, evaluation
//! regions and the single tolerance table, plus a runner shared by the solver
//! tests and `fringe-cli validate`.
//!
//! The error metric is `‖E_num − E_ref‖₂ / ‖E_ref‖₂` of the total field over the
//! case region, intersected with the solver's grid and with PEC interiors left
//! out; for FDTD, points within 2Δ of an interface are left out too.

use std::sync::Arc;
use crate::time::Instant;

use serde::Serialize;

use crate::detectors::{FieldView, Flux, Measurement};
use crate::geometry::{bodies_from_scene, BodyMaterial};
use crate::scene::*;
use crate::solver::{solve, FieldGrid, Method, Part, Quality, SolveContext};
use crate::source::Incident;
use crate::types::{Vec2, C64};

use super::metrics::{fitted_order, flux_balance, interface_band, observed_order, rel_l2, resample};
use super::{pec_plane_image, AirySlab, LineCylinder, MieCylinder};

/// One row of the tolerance table. A bound of `None` means the case does not
/// apply to that method.
///
/// Each error bound is min(target, 2 × measured), rounded up to two
/// significant digits, with the error measured at final quality on the release
/// build. The targets are the accuracies the cases were written to check:
/// 3e−3 to 1e−2 for MoM, 5e−3 to 3e−2 for FEM and 1e−2 to 8e−2 for FDTD. Twice
/// the measured error is the smaller on almost every row, so the bounds are
/// regression guards: a change that makes a solver less accurate fails here
/// even while it still meets the target. A row that measures exactly zero
/// keeps its target (MoM `transparent`, 1e−6; FEM and MoM `bk7_plain`, 1e−9,
/// where the dispersive and the plain material give the same ε). The metal
/// and line-source cases also require the FDTD to settle. Around a line
/// source the error leaves out a disc of λ_b/4, where the singular incident
/// field would dominate both norms. The detector rows measure readings, not
/// fields: `detector_plane` the relative error of a line's flux and a box's
/// mean |E|², `slab_power` |R + T − incident| / incident for a lossless slab,
/// and `slab_lossy_power` the absorbed fraction against the Airy field's,
/// which must also be far above zero. Both slab rows also bound how far R and
/// T are from the Airy values, at final quality (see `slab_rt_bound`). The order rows
/// (`fdtd_subpixel_order`, `fem_order`) are lower bounds.
#[derive(Clone, Copy, Debug, Serialize)]
pub struct CaseSpec {
    pub id: &'static str,
    pub slow: bool,
    pub mom: Option<f64>,
    pub fem: Option<f64>,
    pub fdtd: Option<f64>,
    /// FDTD cells per wavelength overriding the default for this case.
    pub fdtd_ppw: Option<f64>,
    pub description: &'static str,
}

const fn case(
    id: &'static str,
    slow: bool,
    mom: Option<f64>,
    fem: Option<f64>,
    fdtd: Option<f64>,
    fdtd_ppw: Option<f64>,
    description: &'static str,
) -> CaseSpec {
    CaseSpec { id, slow, mom, fem, fdtd, fdtd_ppw, description }
}

pub const CASES: [CaseSpec; 30] = [
    case("mie_pec", false, Some(6.4e-5), Some(8.6e-4), Some(1.4e-2), Some(30.0), "PEC cylinder r = 1, plane wave 0°"),
    case("mie_pec_37", false, Some(6.3e-5), Some(8.7e-4), Some(8.2e-3), Some(30.0), "PEC cylinder r = 1, plane wave 37°"),
    case(
        "mie_pec_resonance",
        false,
        Some(7.7e-5),
        None,
        None,
        None,
        "PEC cylinder at the first interior resonance: CFIE error at 9 radii, EFIE/CFIE conditioning",
    ),
    case("mie_diel", false, Some(2.2e-4), Some(8e-4), Some(1.8e-2), None, "dielectric cylinder n = 1.5, r = 1"),
    case("mie_lossy", false, Some(9.3e-5), Some(6e-4), Some(8.1e-3), None, "lossy cylinder n = 1.5 + 0.05i, r = 1"),
    case(
        "mie_high_index",
        true,
        Some(1.5e-4),
        Some(1.1e-3),
        Some(3.7e-2),
        Some(30.0),
        "cylinder n = 3.5, r = 0.5; an FDTD run that stops at the period cap must warn",
    ),
    case("slab_airy_0", false, Some(2.7e-6), Some(2.3e-3), Some(1.2e-3), None, "Gaussian beam through a slab, normal incidence"),
    case("slab_airy_30", true, Some(2e-5), Some(1.7e-3), Some(2.2e-2), None, "Gaussian beam through a slab at 30°"),
    case("slab_lossy", true, Some(1.8e-6), Some(1.9e-3), Some(5.1e-3), None, "Gaussian beam through a lossy slab"),
    case("mirror_0", false, Some(3.7e-6), Some(1.1e-3), Some(5.5e-3), None, "Gaussian beam on a flat PEC mirror"),
    case("mirror_25", true, Some(2.3e-5), Some(9.4e-4), Some(2.3e-2), None, "Gaussian beam on a flat PEC mirror at 25°"),
    case(
        "mirror_off_grid",
        false,
        Some(3.7e-6),
        Some(1.1e-3),
        Some(8.2e-3),
        None,
        "mirror_0 with the face a quarter FDTD cell off the grid lines",
    ),
    case(
        "fdtd_subpixel_order",
        true,
        None,
        None,
        Some(1.6),
        None,
        "mie_diel with subpixel smoothing: least-squares order over 12–30 ppw ≥ 1.6, and at 24 ppw at least 2× more accurate than without",
    ),
    case("fem_order", true, None, Some(3.0), None, None, "observed order of mie_diel with P3 at 9 and 15 ppw (≥ bound)"),
    case("mom_self", false, Some(5e-4), None, None, None, "mie_diel at 12 against 16 panels per wavelength"),
    case(
        "pml_hygiene",
        true,
        None,
        Some(1.1e-4),
        Some(1.9e-6),
        None,
        "mie_pec against the same with the domain 4 µm larger (FEM at 25 per λ)",
    ),
    case("balance", false, Some(2.2e-4), Some(1.7e-4), Some(2e-3), None, "energy balance of mie_lossy"),
    case(
        "mie_silver",
        false,
        Some(6.3e-5),
        Some(4.4e-4),
        Some(1.6e-3),
        None,
        "silver cylinder (Rakić Lorentz–Drude) r = 0.1 µm at λ0 = 0.5 µm, ε ≈ −7.6 − 0.73j",
    ),
    case("mie_gold", false, Some(1.8e-5), Some(4.7e-4), Some(1.5e-3), None, "gold cylinder (Rakić) r = 0.15 µm at λ0 = 0.633 µm, ε ≈ −9.8 − 2.0j"),
    case(
        "mie_silver_plasmon",
        false,
        Some(1.3e-4),
        Some(3.1e-4),
        Some(4.3e-3),
        None,
        "silver cylinder r = 0.06 µm at λ0 = 0.345 µm, where ε′ ≈ −1 (the in-plane plasmon condition; Ez sees no resonance)",
    ),
    case(
        "bk7_plain",
        false,
        Some(1e-9),
        Some(1e-9),
        Some(7.6e-5),
        None,
        "BK7 preset cylinder r = 1 against a plain index with the same n at λ0 = 1 µm",
    ),
    case("line_pec", false, Some(8.2e-5), Some(1.1e-3), Some(1.4e-2), Some(30.0), "line source 0.9 µm from a PEC cylinder r = 1 (Graf series)"),
    case("line_diel", false, Some(2.9e-4), Some(9.4e-4), Some(8.9e-3), None, "line source 0.9 µm from a cylinder n = 1.5, r = 1 (Graf series)"),
    case(
        "line_plane_diel",
        false,
        Some(2.8e-4),
        Some(8.8e-4),
        Some(9e-3),
        None,
        "plane wave at 30° and a line source (phase 90°) together on a cylinder n = 1.5, r = 1",
    ),
    case(
        "detector_plane",
        false,
        Some(5.2e-6),
        Some(5.2e-6),
        Some(2e-8),
        None,
        "line and box detectors in a plane wave at 30° in n_b = 1.33 against n_b A² L cos θ / 2 and A²",
    ),
    case(
        "slab_power",
        false,
        Some(2.5e-6),
        Some(9.5e-4),
        Some(1.5e-7),
        None,
        "Gaussian beam through a slab (R ≈ 0.15), line detectors in front and behind: |R + T − incident| / incident",
    ),
    case(
        "slab_lossy_power",
        false,
        Some(1.3e-6),
        Some(3.6e-4),
        Some(4.6e-3),
        None,
        "the same slab with k = 0.05: absorbed fraction 1 − (R + T) / incident against the Airy field's",
    ),
    case("free_beam", false, Some(0.0), Some(0.0), Some(0.0), None, "no elements: the scattered field is exactly zero"),
    case("line_free", false, Some(0.0), Some(0.0), Some(0.0), None, "a line source alone: the scattered field is exactly zero"),
    case("transparent", false, Some(1e-6), Some(0.0), Some(0.0), None, "cylinder with n = n_b: no scattering"),
];

pub fn spec(id: &str) -> Option<&'static CaseSpec> {
    CASES.iter().find(|c| c.id == id)
}

impl CaseSpec {
    pub fn bound(&self, m: Method) -> Option<f64> {
        match m {
            Method::Mom => self.mom,
            Method::Fem => self.fem,
            Method::Fdtd => self.fdtd,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Status {
    Pass,
    Fail,
    /// The case does not apply to this solver.
    NotApplicable,
}

impl Status {
    pub fn label(self) -> &'static str {
        match self {
            Status::Pass => "PASS",
            Status::Fail => "FAIL",
            Status::NotApplicable => "n/a",
        }
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct CaseResult {
    pub id: String,
    pub method: Method,
    pub quality: Quality,
    pub status: Status,
    pub unknowns: u64,
    pub seconds: f64,
    pub error: Option<f64>,
    pub tolerance: Option<f64>,
    pub detail: String,
}

// Scenes. All cases use λ0 = 1 µm, and all but `detector_plane` n_b = 1.

fn base(source: SourceKind, elements: Vec<Element>, domain: [f64; 4]) -> Scene {
    Scene {
        version: SCHEMA_VERSION,
        wavelength_um: 1.0,
        background: Background { n: 1.0 },
        polarization: Polarization::Ez,
        sources: vec![Source::new("source-1", source)],
        elements,
        detectors: Vec::new(),
        domain: Domain { x_min_um: domain[0], x_max_um: domain[1], y_min_um: domain[2], y_max_um: domain[3], pml_wl: 1.0 },
        solver: SolverSettings::default(),
    }
}

fn plane(angle_deg: f64) -> SourceKind {
    SourceKind::PlaneWave { angle_deg, amplitude: 1.0, phase_deg: 0.0 }
}

fn gaussian(x: f64, angle_deg: f64) -> SourceKind {
    SourceKind::GaussianBeam { waist_um: 2.5, waist_x_um: x, waist_y_um: 0.0, angle_deg, amplitude: 1.0, phase_deg: 0.0 }
}

/// The emitter of the line-source cases: 0.9 µm from the surface of the
/// unit cylinders, off the axis so that the field has no symmetry.
pub const LINE_SOURCE_POS: [f64; 2] = [-1.8, 0.6];

fn line(amplitude: f64, phase_deg: f64) -> SourceKind {
    SourceKind::LineSource { x_um: LINE_SOURCE_POS[0], y_um: LINE_SOURCE_POS[1], amplitude, phase_deg }
}

/// A unit cylinder lit by a line source.
fn line_cylinder_scene(material: Material) -> Scene {
    base(line(1.0, 0.0), vec![el("cylinder", material, 0.0, Shape::Cylinder { radius_um: 1.0 })], [-4.0, 4.0, -4.0, 4.0])
}

fn detector(id: &str, shape: DetectorShape) -> Detector {
    Detector { id: id.into(), name: String::new(), enabled: true, shape }
}

/// Slab thickness of the slab power cases: 3 µm plus a quarter wavelength in
/// the slab (n = 1.5), at the reflection maximum.
pub const SLAB_POWER_THICKNESS: f64 = 3.0 + 1.0 / 6.0;

/// Background index of `detector_plane`, the one case not in vacuum, so that
/// the n_b in the flux is checked.
pub const DETECTOR_PLANE_NB: f64 = 1.33;

fn el(id: &str, material: Material, x: f64, shape: Shape) -> Element {
    Element { id: id.into(), name: id.into(), enabled: true, material, x_um: x, y_um: 0.0, rotation_deg: 0.0, shape }
}

fn cylinder_scene(material: Material, r: f64, angle_deg: f64, half: f64) -> Scene {
    base(plane(angle_deg), vec![el("cylinder", material, 0.0, Shape::Cylinder { radius_um: r })], [-half, half, -half, half])
}

fn diel(n: f64, k: f64) -> Material {
    Material::Dielectric { n, k }
}

fn slab_scene(angle_deg: f64, k: f64) -> Scene {
    base(
        gaussian(-1.5, angle_deg),
        vec![el("slab", diel(1.5, k), 0.0, Shape::Slab { thickness_um: 3.0, height_um: 24.0 })],
        [-6.0, 6.0, -14.0, 14.0],
    )
}

fn mirror_scene(angle_deg: f64) -> Scene {
    base(
        gaussian(-3.0, angle_deg),
        vec![el("mirror", Material::Pec, 4.0, Shape::Mirror { aperture_um: 24.0, thickness_um: 0.5, radius_um: None })],
        [-10.0, 6.0, -14.0, 14.0],
    )
}

/// A cylinder of preset material `preset` at vacuum wavelength `lambda`.
fn preset_cylinder(preset: &str, r: f64, lambda: f64, half: f64) -> Scene {
    let m = crate::scene::materials::preset(preset).expect("a library preset");
    let mut s = cylinder_scene(m, r, 0.0, half);
    s.wavelength_um = lambda;
    s
}

/// The plain-index scene `bk7_plain` compares against: n of the BK7 preset at
/// λ0, entered as n + ik.
pub fn bk7_plain_reference_scene() -> Scene {
    let s = preset_cylinder("bk7", 1.0, 1.0, 4.0);
    let n = s.elements[0].material.index_at(s.wavelength_um).expect("a dielectric");
    cylinder_scene(diel(n.re, -n.im), 1.0, 0.0, 4.0)
}

/// The base scene of a case (before method and resolution are applied).
pub fn case_scene(id: &str) -> Option<Scene> {
    Some(match id {
        "mie_silver" => preset_cylinder("silver", 0.1, 0.5, 1.0),
        "mie_gold" => preset_cylinder("gold", 0.15, 0.633, 1.2),
        "mie_silver_plasmon" => preset_cylinder("silver", 0.06, 0.345, 0.7),
        "bk7_plain" => preset_cylinder("bk7", 1.0, 1.0, 4.0),
        "mie_pec" | "pml_hygiene" => cylinder_scene(Material::Pec, 1.0, 0.0, 4.0),
        "mie_pec_37" => cylinder_scene(Material::Pec, 1.0, 37.0, 4.0),
        "mie_pec_resonance" => cylinder_scene(Material::Pec, RESONANT_RADIUS, 0.0, 2.0),
        "mie_diel" | "fdtd_subpixel_order" | "fem_order" | "mom_self" => cylinder_scene(diel(1.5, 0.0), 1.0, 0.0, 4.0),
        "mie_lossy" | "balance" => cylinder_scene(diel(1.5, 0.05), 1.0, 0.0, 4.0),
        "mie_high_index" => cylinder_scene(diel(3.5, 0.0), 0.5, 0.0, 4.0),
        "slab_airy_0" => slab_scene(0.0, 0.0),
        "slab_airy_30" => slab_scene(30.0, 0.0),
        "slab_lossy" => slab_scene(0.0, 0.05),
        "mirror_0" => mirror_scene(0.0),
        "mirror_25" => mirror_scene(25.0),
        "mirror_off_grid" => {
            // At the final 24 cells/λ the mirror_0 face lies on a node line;
            // this moves it by Δ/4.
            let mut s = mirror_scene(0.0);
            s.elements[0].x_um += 1.0 / 96.0;
            s
        }
        "free_beam" => base(gaussian(-2.0, 0.0), Vec::new(), [-4.0, 4.0, -4.0, 4.0]),
        "line_free" => base(line(1.0, 0.0), Vec::new(), [-4.0, 4.0, -4.0, 4.0]),
        "line_pec" => line_cylinder_scene(Material::Pec),
        "line_diel" => line_cylinder_scene(diel(1.5, 0.0)),
        "line_plane_diel" => {
            let mut s = line_cylinder_scene(diel(1.5, 0.0));
            s.sources[0].kind = line(0.7, 90.0);
            s.sources.push(Source::new("source-2", plane(30.0)));
            s
        }
        "transparent" => cylinder_scene(diel(1.0, 0.0), 1.0, 0.0, 4.0),
        "detector_plane" => {
            let mut s = base(plane(30.0), Vec::new(), [-4.0, 4.0, -4.0, 4.0]);
            s.background.n = DETECTOR_PLANE_NB;
            s.sources[0].kind = SourceKind::PlaneWave { angle_deg: 30.0, amplitude: 2.0, phase_deg: 0.0 };
            // Off the grid nodes, and on the bottom domain edge for one end.
            s.detectors = vec![
                detector("line", DetectorShape::Line { x1_um: 1.03, y1_um: -4.0, x2_um: 1.03, y2_um: 2.29 }),
                detector("box", DetectorShape::Box { x_um: 0.1, y_um: 0.2, width_um: 0.5, height_um: 0.3 }),
            ];
            s
        }
        "slab_power" | "slab_lossy_power" => {
            // A sixth of a micrometre thicker than slab_airy_0, which is near a
            // transmission maximum (R ≈ 3e−4): here R ≈ 0.15.
            let mut s = slab_scene(0.0, if id == "slab_power" { 0.0 } else { 0.05 });
            s.elements[0].shape = Shape::Slab { thickness_um: SLAB_POWER_THICKNESS, height_um: 24.0 };
            s.detectors = vec![
                detector("front", DetectorShape::Line { x1_um: -4.0, y1_um: -8.0, x2_um: -4.0, y2_um: 8.0 }),
                detector("back", DetectorShape::Line { x1_um: 4.0, y1_um: -8.0, x2_um: 4.0, y2_um: 8.0 }),
            ];
            s
        }
        _ => return None,
    })
}

/// FEM resolution of `pml_hygiene`, high enough that the mesh difference
/// between the two domains is well below the PML reflection being measured.
pub const PML_HYGIENE_FEM_PPW: f64 = 25.0;

/// FDTD resolutions of the `fdtd_subpixel_order` fit.
pub const SUBPIXEL_PPW: [f64; 5] = [12.0, 16.0, 20.0, 24.0, 30.0];

/// k r = first zero of J0, where the EFIE for a PEC cylinder has an interior
/// resonance.
pub const RESONANT_RADIUS: f64 = 2.404_825_557_695_773 / (2.0 * std::f64::consts::PI);

fn with_method(mut s: Scene, m: Method, ppw: Option<f64>) -> Scene {
    s.solver.method = m;
    if let Some(ppw) = ppw {
        let set = |a: &mut Option<f64>, b: &mut Option<f64>| {
            *a = Some(ppw);
            *b = Some(ppw);
        };
        match m {
            Method::Fdtd => set(&mut s.solver.fdtd.preview_ppw, &mut s.solver.fdtd.final_ppw),
            Method::Fem => set(&mut s.solver.fem.preview_ppw, &mut s.solver.fem.final_ppw),
            Method::Mom => set(&mut s.solver.mom.preview_ppw, &mut s.solver.mom.final_ppw),
        }
    }
    s
}

type FieldFn = Box<dyn Fn(Vec2) -> C64 + Send + Sync>;

/// The analytic total field of a case at `p`.
pub fn reference(id: &str, scene: &Scene) -> Option<FieldFn> {
    let k0 = 2.0 * std::f64::consts::PI / scene.wavelength_um;
    let n_b = scene.background.n;
    let outer = scene.domain.rect().expand(scene.domain.pml_wl * scene.wavelength_um / n_b);
    let inc = Incident::from_scene(scene, outer);
    let bodies = bodies_from_scene(scene);
    match id {
        "free_beam" | "line_free" => Some(Box::new(move |p| inc.eval(p))),
        id if id.starts_with("mie") || id.starts_with("line") || id == "transparent" || id == "balance" || id == "pml_hygiene" => {
            let e = scene.elements.first()?;
            let Shape::Cylinder { radius_um } = e.shape else { return None };
            let center = Vec2::new(e.x_um, e.y_um);
            let material = bodies.first()?.material;
            // The incident field of every source plus each one's scattered
            // field: plane waves by the Mie series, line sources by Graf's.
            let mut scattered: Vec<FieldFn> = Vec::new();
            let mut interior: Vec<FieldFn> = Vec::new();
            for s in scene.enabled_sources() {
                let (a, ph) = (s.kind.amplitude(), s.kind.phase_deg().to_radians());
                match s.kind {
                    SourceKind::PlaneWave { angle_deg, .. } => {
                        let angle = angle_deg.to_radians();
                        let mie = Arc::new(MieCylinder::new(center, radius_um, material, n_b, k0, angle, a, ph));
                        let m2 = mie.clone();
                        scattered.push(Box::new(move |p| mie.scattered(p)));
                        interior.push(Box::new(move |p| m2.total(p)));
                    }
                    SourceKind::LineSource { x_um, y_um, .. } => {
                        let at = Vec2::new(x_um, y_um);
                        let lc = Arc::new(LineCylinder::new(center, radius_um, material, n_b, k0, at, a, ph));
                        let l2 = lc.clone();
                        scattered.push(Box::new(move |p| lc.scattered(p)));
                        interior.push(Box::new(move |p| l2.total(p)));
                    }
                    SourceKind::GaussianBeam { .. } => return None,
                }
            }
            Some(Box::new(move |p| {
                if p.dist(center) >= radius_um {
                    inc.eval(p) + scattered.iter().map(|f| f(p)).sum::<C64>()
                } else {
                    interior.iter().map(|f| f(p)).sum::<C64>()
                }
            }))
        }
        id if id.starts_with("slab") => {
            let e = scene.elements.first()?;
            let Shape::Slab { thickness_um, .. } = e.shape else { return None };
            let n_slab = match bodies.first()?.material {
                BodyMaterial::Dielectric { n, .. } => n,
                BodyMaterial::Pec => return None,
            };
            let slab = AirySlab { x_front: e.x_um - 0.5 * thickness_um, thickness: thickness_um, n_slab, n_b, k0 };
            Some(Box::new(move |p| slab.field(&inc, p)))
        }
        id if id.starts_with("mirror") => {
            let x_plane = scene.elements.first()?.x_um;
            Some(Box::new(move |p| pec_plane_image(&inc, x_plane, p)))
        }
        _ => None,
    }
}

/// Evaluation mask of a case on the solution grid.
fn region_mask(id: &str, field: &FieldGrid, method: Method) -> Vec<bool> {
    let g = &field.grid;
    // The discs about emitters, where the singular incident field would
    // dominate both norms, are left out.
    let core = field.emitter_core_mask();
    let mut mask: Vec<bool> = (0..g.len())
        .map(|idx| {
            if field.is_pec(idx) || core.as_ref().is_some_and(|c| c[idx]) {
                return false;
            }
            let p = g.point(idx % g.nx, idx / g.nx);
            match id {
                id if id.starts_with("slab") => p.y.abs() <= 8.0 && (p.x <= -2.0 || p.x >= 2.0),
                id if id.starts_with("mirror") => p.x <= 3.5 && p.y.abs() <= 10.0,
                _ => true,
            }
        })
        .collect();
    if method == Method::Fdtd {
        let bodies = bodies_from_scene(&field.scene);
        let band = interface_band(g, &bodies, 2.0 * g.dx);
        mask.iter_mut().zip(band).for_each(|(m, b)| *m &= !b);
    }
    mask
}

struct Run {
    field: FieldGrid,
    seconds: f64,
}

fn run(scene: &Scene, quality: Quality) -> Result<Run, String> {
    let t = Instant::now();
    let field = solve(scene, quality, &SolveContext::new()).map_err(|e| format!("{}: {e}", e.code()))?;
    Ok(Run { field, seconds: t.elapsed().as_secs_f64() })
}

/// Relative L2 error of a solution against the case reference over the case region.
pub fn field_error(id: &str, field: &FieldGrid) -> f64 {
    let Some(reference) = reference(id, &field.scene) else { return f64::NAN };
    let g = &field.grid;
    let refs: Vec<C64> = (0..g.len()).map(|idx| reference(g.point(idx % g.nx, idx / g.nx))).collect();
    let mask = region_mask(id, field, field.meta.method);
    rel_l2(&field.total, &refs, Some(&mask))
}

fn is_metal_case(id: &str) -> bool {
    matches!(id, "mie_silver" | "mie_gold" | "mie_silver_plasmon")
}

/// Relative errors of the `detector_plane` readings: the line's flux against
/// `n_b A² L cos θ / 2` and the box's mean |E|² against A².
pub fn detector_plane_errors(field: &FieldGrid) -> (f64, f64) {
    let s = &field.scene;
    let SourceKind::PlaneWave { angle_deg, amplitude, .. } = s.sources[0].kind else { return (f64::NAN, f64::NAN) };
    let (mut flux_err, mut box_err) = (f64::NAN, f64::NAN);
    for r in field.detector_readings() {
        match &r.measurement {
            Measurement::Line { flux, length_um, normal } => {
                let dir = Vec2::from_angle(angle_deg.to_radians());
                let want = 0.5 * s.background.n * amplitude * amplitude * length_um * dir.dot(Vec2::new(normal[0], normal[1]));
                flux_err = (flux.total - want).abs() / want.abs();
            }
            Measurement::Box { total, .. } => {
                let want = amplitude * amplitude;
                box_err = (total.mean - want).abs() / want;
            }
        }
    }
    (flux_err, box_err)
}

/// Incident, reflected and transmitted power of the slab power cases, from
/// the detectors "front" and "back" (both with the normal along +x). In front
/// of the slab the scattered field is the reflected wave alone, so the
/// reflected power is minus its flux there; behind it the total flux is the
/// transmitted power.
#[derive(Clone, Copy, Debug)]
pub struct SlabPowers {
    pub incident: f64,
    pub reflected: f64,
    pub transmitted: f64,
}

pub fn slab_powers(view: &FieldView, detectors: &[Detector]) -> SlabPowers {
    let readings = crate::detectors::measure_all(view, detectors);
    let flux = |id: &str| {
        readings.iter().find(|r| r.id == id).and_then(|r| r.measurement.flux()).unwrap_or(Flux {
            total: f64::NAN,
            incident: f64::NAN,
            scattered: f64::NAN,
        })
    };
    let (front, back) = (flux("front"), flux("back"));
    SlabPowers { incident: front.incident, reflected: -front.scattered, transmitted: back.total }
}

/// [`slab_powers`] of the Airy field sampled on the solver's grid, so that the
/// reference is measured the same way as the solution.
pub fn slab_reference_powers(id: &str, field: &FieldGrid) -> SlabPowers {
    let s = &field.scene;
    let Some(reference) = reference(id, s) else {
        return SlabPowers { incident: f64::NAN, reflected: f64::NAN, transmitted: f64::NAN };
    };
    let outer = s.domain.rect().expand(s.domain.pml_wl * s.wavelength_um / s.background.n);
    let inc = Incident::from_scene(s, outer);
    let g = &field.grid;
    let total: Vec<C64> = (0..g.len()).map(|idx| reference(g.point(idx % g.nx, idx / g.nx))).collect();
    let incident = inc.eval_grid(g);
    let view = FieldView { grid: g, total: &total, incident: &incident, wavelength_um: s.wavelength_um };
    slab_powers(&view, &s.detectors)
}

/// Bound on max(|R − R_Airy|, |T − T_Airy|) in the slab power cases at final
/// quality: twice the measured value, as for the error bounds. FDTD's is the
/// largest: its R is 0.1442 against 0.1484, from the grid's phase error over
/// the 3 µm slab, while it still conserves energy to 1e−7.
fn slab_rt_bound(method: Method) -> f64 {
    match method {
        Method::Mom => 2.2e-6,
        Method::Fem => 1.1e-3,
        Method::Fdtd => 8.5e-3,
    }
}

/// Relative L2 error of the scattered field over the case region.
pub fn scattered_error(id: &str, field: &FieldGrid) -> f64 {
    let Some(reference) = reference(id, &field.scene) else { return f64::NAN };
    let s = &field.scene;
    let outer = s.domain.rect().expand(s.domain.pml_wl * s.wavelength_um / s.background.n);
    let inc = Incident::from_scene(s, outer);
    let g = &field.grid;
    let refs: Vec<C64> = (0..g.len())
        .map(|idx| {
            let p = g.point(idx % g.nx, idx / g.nx);
            reference(p) - inc.eval(p)
        })
        .collect();
    let num: Vec<C64> = (0..g.len()).map(|i| field.value(Part::Scattered, i)).collect();
    let mask = region_mask(id, field, field.meta.method);
    rel_l2(&num, &refs, Some(&mask))
}

fn max_scattered(field: &FieldGrid) -> f64 {
    (0..field.grid.len())
        .filter(|&i| !field.is_pec(i))
        .map(|i| field.value(Part::Scattered, i).norm())
        .fold(0.0, f64::max)
        / field.incident_peak()
}

/// Runs case `id` with `method` at `quality` and compares against its bound.
pub fn run_case(id: &str, method: Method, quality: Quality) -> Result<CaseResult, String> {
    let spec = spec(id).ok_or_else(|| format!("unknown case {id}"))?;
    let mut result = CaseResult {
        id: id.into(),
        method,
        quality,
        status: Status::NotApplicable,
        unknowns: 0,
        seconds: 0.0,
        error: None,
        tolerance: spec.bound(method),
        detail: String::new(),
    };
    let Some(tol) = spec.bound(method) else {
        return Ok(result);
    };
    let scene0 = case_scene(id).ok_or_else(|| format!("no scene for case {id}"))?;
    let ppw = if method == Method::Fdtd { spec.fdtd_ppw } else { None };
    let mut pass;

    match id {
        "free_beam" | "transparent" | "line_free" => {
            let r = run(&with_method(scene0, method, ppw), quality)?;
            let e = max_scattered(&r.field);
            result.error = Some(e);
            result.detail = "max |E_s| / A".into();
            if id == "line_free" {
                // The incident field itself: analytic for FEM and MoM, the
                // Yee-matched Hankel function for FDTD.
                result.detail += &format!("; incident against H0: {:.2e}", field_error(id, &r.field));
            }
            result.unknowns = r.field.meta.solver.unknowns;
            result.seconds = r.seconds;
            pass = e <= tol;
        }
        "balance" => {
            let r = run(&with_method(scene0, method, ppw), quality)?;
            let fb = flux_balance(&r.field, r.field.scene.domain.rect().expand(-0.5));
            let e = fb.residual();
            result.error = Some(e);
            result.detail = format!("inflow {:.4e}, absorbed {:.4e}", fb.inflow, fb.absorbed);
            result.unknowns = r.field.meta.solver.unknowns;
            result.seconds = r.seconds;
            pass = e <= tol;
        }
        "detector_plane" => {
            let r = run(&with_method(scene0, method, ppw), quality)?;
            let (flux_err, box_err) = detector_plane_errors(&r.field);
            let e = flux_err.max(box_err);
            result.error = Some(e);
            result.detail = format!("flux {flux_err:.2e}, box mean |E|² {box_err:.2e}");
            result.unknowns = r.field.meta.solver.unknowns;
            result.seconds = r.seconds;
            pass = e <= tol;
        }
        "slab_power" | "slab_lossy_power" => {
            let r = run(&with_method(scene0, method, ppw), quality)?;
            let num = slab_powers(&r.field.view(), &r.field.scene.detectors);
            let reference = slab_reference_powers(id, &r.field);
            let absorbed = 1.0 - (num.reflected + num.transmitted) / num.incident;
            let absorbed_ref = 1.0 - (reference.reflected + reference.transmitted) / reference.incident;
            let e = if id == "slab_power" { absorbed.abs() } else { (absorbed - absorbed_ref).abs() };
            // The split between R and T against the Airy field's, with its own
            // bound: a solver can conserve energy exactly and still put it on
            // the wrong side (FDTD's phase error shifts the Fabry–Perot fringe).
            let rt = (num.reflected / num.incident - reference.reflected / reference.incident)
                .abs()
                .max((num.transmitted / num.incident - reference.transmitted / reference.incident).abs());
            let rt_tol = slab_rt_bound(method);
            result.error = Some(e);
            result.detail = format!(
                "R {:.5}, T {:.5} (Airy field {:.5}, {:.5}), R/T off by {rt:.2e} (bound {rt_tol:.1e}), absorbed {absorbed:.2e}",
                num.reflected / num.incident,
                num.transmitted / num.incident,
                reference.reflected / reference.incident,
                reference.transmitted / reference.incident,
            );
            result.unknowns = r.field.meta.solver.unknowns;
            result.seconds = r.seconds;
            pass = e <= tol && (quality == Quality::Preview || rt <= rt_tol);
            if id == "slab_lossy_power" {
                // The absorbing slab must show the loss, by a margin far above
                // the error bound.
                pass &= absorbed > 10.0 * tol;
            }
        }
        "bk7_plain" => {
            let a = run(&with_method(scene0, method, ppw), quality)?;
            let b = run(&with_method(bk7_plain_reference_scene(), method, ppw), quality)?;
            let mask = region_mask(id, &a.field, method);
            let e = rel_l2(&a.field.total, &b.field.total, Some(&mask));
            let mie = field_error("mie_diel", &b.field);
            result.error = Some(e);
            result.detail = format!("plain index against Mie: {mie:.2e}");
            result.unknowns = a.field.meta.solver.unknowns;
            result.seconds = a.seconds + b.seconds;
            pass = e <= tol && a.field.grid == b.field.grid;
        }
        "mom_self" => {
            let a = run(&with_method(scene0.clone(), method, Some(12.0)), quality)?;
            let b = run(&with_method(scene0, method, Some(16.0)), quality)?;
            let mask = region_mask(id, &b.field, method);
            let a_on_b: Vec<C64> = resample(&a.field, Part::Total, &b.field.grid)
                .into_iter()
                .map(|v| v.unwrap_or(C64::new(f64::NAN, 0.0)))
                .collect();
            let e = rel_l2(&a_on_b, &b.field.total, Some(&mask));
            result.error = Some(e);
            result.detail = "12 vs 16 panels per wavelength".into();
            result.unknowns = b.field.meta.solver.unknowns;
            result.seconds = a.seconds + b.seconds;
            pass = e <= tol;
        }
        "pml_hygiene" => {
            // The two FEM domains get different meshes, so at the default 15
            // per λ their difference is the mesh noise (≈ 5e-4), as large as a
            // PML a thousand times worse would cause. At 25 per λ the noise is
            // ≈ 5e-5 and R0 = 1e-3 shows as 6e-4. FDTD shares its grid nodes
            // between the two domains and needs no such care.
            let ppw = if method == Method::Fem { Some(PML_HYGIENE_FEM_PPW) } else { ppw };
            let small = run(&with_method(scene0.clone(), method, ppw), quality)?;
            let mut big_scene = scene0;
            big_scene.domain = Domain { x_min_um: -8.0, x_max_um: 8.0, y_min_um: -8.0, y_max_um: 8.0, pml_wl: 1.0 };
            let big = run(&with_method(big_scene, method, ppw), quality)?;
            let mask = region_mask("mie_pec", &small.field, method);
            let big_on_small: Vec<C64> = resample(&big.field, Part::Total, &small.field.grid)
                .into_iter()
                .map(|v| v.unwrap_or(C64::new(f64::NAN, 0.0)))
                .collect();
            let e = rel_l2(&small.field.total, &big_on_small, Some(&mask));
            result.error = Some(e);
            result.detail = match method {
                Method::Fem => format!("domain [−4, 4]² against [−8, 8]², {PML_HYGIENE_FEM_PPW} per λ"),
                _ => "domain [−4, 4]² against [−8, 8]²".into(),
            };
            result.unknowns = big.field.meta.solver.unknowns;
            result.seconds = small.seconds + big.seconds;
            pass = e <= tol;
        }
        "fdtd_subpixel_order" => {
            let mut runs = Vec::new();
            for (ppw, subpixel) in SUBPIXEL_PPW.iter().map(|&p| (p, true)).chain([(24.0, false)]) {
                let mut s = with_method(scene0.clone(), method, Some(ppw));
                s.solver.fdtd.subpixel = subpixel;
                let r = run(&s, quality)?;
                result.seconds += r.seconds;
                result.unknowns = result.unknowns.max(r.field.meta.solver.unknowns);
                runs.push((ppw, subpixel, field_error("mie_diel", &r.field)));
            }
            let on: Vec<f64> = runs.iter().filter(|r| r.1).map(|r| r.2).collect();
            let hs: Vec<f64> = SUBPIXEL_PPW.iter().map(|p| 1.0 / p).collect();
            let order = fitted_order(&hs, &on);
            let at_24 = |subpixel: bool| runs.iter().find(|r| r.0 == 24.0 && r.1 == subpixel).map_or(f64::NAN, |r| r.2);
            let (e_on, e_off) = (at_24(true), at_24(false));
            result.error = Some(order);
            result.detail = format!(
                "least-squares order over {} resolutions; at 24 ppw error {e_on:.2e} with subpixel, {e_off:.2e} without (ratio {:.1}, ≥ 2 required)",
                SUBPIXEL_PPW.len(),
                e_off / e_on
            );
            pass = order >= tol && e_off >= 2.0 * e_on;
        }
        "fem_order" => {
            let mut errs = [0.0; 2];
            for (l, ppw) in [9.0, 15.0].into_iter().enumerate() {
                let mut s = with_method(scene0.clone(), method, Some(ppw));
                s.solver.fem.order = 3;
                let r = run(&s, quality)?;
                errs[l] = field_error("mie_diel", &r.field);
                result.seconds += r.seconds;
                result.unknowns = r.field.meta.solver.unknowns;
            }
            let order = observed_order(errs[0], errs[1], 1.0 / 9.0, 1.0 / 15.0);
            result.error = Some(order);
            result.detail = format!("errors {:.2e} at 9 ppw, {:.2e} at 15 ppw", errs[0], errs[1]);
            pass = order >= tol;
        }
        "mie_pec_resonance" => {
            let mut worst = 0.0f64;
            let (mut cond_efie, mut cond_cfie) = (0.0f64, 0.0f64);
            for i in 0..9 {
                let r = RESONANT_RADIUS * (1.0 + 0.004 * (i as f64 - 4.0) / 4.0);
                let mut s = with_method(scene0.clone(), method, None);
                if let Shape::Cylinder { radius_um } = &mut s.elements[0].shape {
                    *radius_um = r;
                }
                for form in [PecFormulation::Cfie, PecFormulation::Efie] {
                    let mut s = s.clone();
                    s.solver.mom.pec_formulation = form;
                    let run = run(&s, quality)?;
                    result.seconds += run.seconds;
                    result.unknowns = run.field.meta.solver.unknowns;
                    let cond = run.field.meta.solver.cond_estimate.unwrap_or(f64::NAN);
                    if form == PecFormulation::Cfie {
                        worst = worst.max(field_error("mie_pec_resonance", &run.field));
                        cond_cfie = cond_cfie.max(cond);
                    } else {
                        cond_efie = cond_efie.max(cond);
                    }
                }
            }
            result.error = Some(worst);
            result.detail = format!("max cond EFIE {cond_efie:.2e}, CFIE {cond_cfie:.2e} (ratio ≥ 100 required)");
            pass = worst <= tol && cond_efie >= 100.0 * cond_cfie;
        }
        _ => {
            let r = run(&with_method(scene0, method, ppw), quality)?;
            let e = field_error(id, &r.field);
            result.error = Some(e);
            result.unknowns = r.field.meta.solver.unknowns;
            result.seconds = r.seconds;
            pass = e <= tol;
            if is_metal_case(id) || id.starts_with("line") {
                // The total field is mostly the incident wave around the small
                // metal cylinders (and dominated by it near an emitter), so the
                // scattered field's own error is reported too.
                let meta = &r.field.meta.solver;
                result.detail = format!(
                    "scattered-field error {:.2e}{}",
                    scattered_error(id, &r.field),
                    if meta.converged { "" } else { "; not settled" }
                );
                pass &= meta.converged;
            }
            if id == "mie_high_index" && method == Method::Fdtd {
                // The TM5 resonance of this cylinder (Q ≈ 240, 1.8 linewidths
                // below the drive) rings for longer than the period cap, so the
                // FDTD may stop unsettled. It must then say so, and the error
                // bound still applies to the field it returns.
                let meta = &r.field.meta.solver;
                let warned = meta.warnings.iter().any(|w| w.starts_with("not fully settled"));
                if meta.converged {
                    result.detail = format!("settled after {:.0} periods", meta.periods.unwrap_or(0.0));
                } else {
                    pass &= warned;
                    result.detail = format!(
                        "stopped unsettled at the {:.0}-period cap{}",
                        meta.periods.unwrap_or(0.0),
                        if warned { " and said so" } else { " without the warning" }
                    );
                }
            }
        }
    }
    result.status = if pass {
        Status::Pass
    } else {
        Status::Fail
    };
    Ok(result)
}
