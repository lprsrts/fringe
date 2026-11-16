//! The solver validation cases (spec §9.2): scenes, references, evaluation
//! regions and the single tolerance table, plus a runner shared by the solver
//! tests and `beam-cli validate`.
//!
//! The error metric is `‖E_num − E_ref‖₂ / ‖E_ref‖₂` of the total field over the
//! case region, intersected with the solver's grid and with PEC interiors left
//! out; for FDTD, points within 2Δ of an interface are left out too.

use std::time::Instant;

use serde::Serialize;

use crate::geometry::{bodies_from_scene, BodyMaterial};
use crate::scene::*;
use crate::solver::{solve, FieldGrid, Method, Part, Quality, SolveContext};
use crate::source::Incident;
use crate::types::{Vec2, C64};

use super::metrics::{flux_balance, interface_band, observed_order, rel_l2, resample};
use super::{pec_plane_image, AirySlab, MieCylinder};

/// One row of the tolerance table. A bound of `None` means the case does not
/// apply to that method. Wave 3 tightens these to min(bound, 2 × measured).
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

pub const CASES: [CaseSpec; 18] = [
    case("mie_pec", false, Some(5e-3), Some(2e-2), Some(8e-2), Some(30.0), "PEC cylinder r = 1, plane wave 0°"),
    case("mie_pec_37", false, Some(5e-3), Some(2e-2), Some(8e-2), Some(30.0), "PEC cylinder r = 1, plane wave 37°"),
    case(
        "mie_pec_resonance",
        false,
        Some(1e-2),
        None,
        None,
        None,
        "PEC cylinder at the first interior resonance: CFIE error at 9 radii, EFIE/CFIE conditioning",
    ),
    case("mie_diel", false, Some(5e-3), Some(1.5e-2), Some(3e-2), None, "dielectric cylinder n = 1.5, r = 1"),
    case("mie_lossy", false, Some(5e-3), Some(1.5e-2), Some(3e-2), None, "lossy cylinder n = 1.5 + 0.05i, r = 1"),
    case("mie_high_index", true, Some(1e-2), Some(3e-2), Some(8e-2), Some(30.0), "cylinder n = 3.5, r = 0.5"),
    case("slab_airy_0", false, Some(5e-3), Some(2e-2), Some(4e-2), None, "Gaussian beam through a slab, normal incidence"),
    case("slab_airy_30", true, Some(5e-3), Some(2e-2), Some(4e-2), None, "Gaussian beam through a slab at 30°"),
    case("slab_lossy", true, Some(5e-3), Some(2e-2), Some(4e-2), None, "Gaussian beam through a lossy slab"),
    case("mirror_0", false, Some(5e-3), Some(2e-2), Some(4e-2), None, "Gaussian beam on a flat PEC mirror"),
    case("mirror_25", true, Some(5e-3), Some(2e-2), Some(4e-2), None, "Gaussian beam on a flat PEC mirror at 25°"),
    case(
        "fdtd_subpixel_order",
        true,
        None,
        None,
        Some(1.6),
        None,
        "observed order of mie_diel at 12 and 24 ppw: ≥ 1.6 with subpixel smoothing, ≤ 1.3 without",
    ),
    case("fem_order", true, None, Some(3.0), None, None, "observed order of mie_diel with P3 at 9 and 15 ppw (≥ bound)"),
    case("mom_self", false, Some(3e-3), None, None, None, "mie_diel at 12 against 16 panels per wavelength"),
    case("pml_hygiene", true, None, Some(5e-3), Some(1e-2), None, "mie_pec against the same with the domain 4 µm larger"),
    case("balance", false, Some(1e-2), Some(1e-2), Some(3e-2), None, "energy balance of mie_lossy"),
    case("free_beam", false, Some(0.0), Some(0.0), Some(0.0), None, "no elements: the scattered field is exactly zero"),
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
    /// The solver is a stub (incident field only).
    Stub,
    /// The case does not apply to this solver.
    NotApplicable,
}

impl Status {
    pub fn label(self) -> &'static str {
        match self {
            Status::Pass => "PASS",
            Status::Fail => "FAIL",
            Status::Stub => "STUB",
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

// Scenes. All cases use λ0 = 1 µm and n_b = 1.

fn base(source: Source, elements: Vec<Element>, domain: [f64; 4]) -> Scene {
    Scene {
        version: SCHEMA_VERSION,
        wavelength_um: 1.0,
        background: Background { n: 1.0 },
        polarization: Polarization::Ez,
        source,
        elements,
        domain: Domain { x_min_um: domain[0], x_max_um: domain[1], y_min_um: domain[2], y_max_um: domain[3], pml_wl: 1.0 },
        solver: SolverSettings::default(),
    }
}

fn plane(angle_deg: f64) -> Source {
    Source::PlaneWave { angle_deg, amplitude: 1.0, phase_deg: 0.0 }
}

fn gaussian(x: f64, angle_deg: f64) -> Source {
    Source::GaussianBeam { waist_um: 2.5, waist_x_um: x, waist_y_um: 0.0, angle_deg, amplitude: 1.0, phase_deg: 0.0 }
}

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

/// The base scene of a case (before method and resolution are applied).
pub fn case_scene(id: &str) -> Option<Scene> {
    Some(match id {
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
        "free_beam" => base(gaussian(-2.0, 0.0), Vec::new(), [-4.0, 4.0, -4.0, 4.0]),
        "transparent" => cylinder_scene(diel(1.0, 0.0), 1.0, 0.0, 4.0),
        _ => return None,
    })
}

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

fn is_stub(f: &FieldGrid) -> bool {
    f.meta.solver.warnings.iter().any(|w| w.contains("not implemented yet"))
}

/// The analytic total field of a case at `p`.
pub fn reference(id: &str, scene: &Scene) -> Option<Box<dyn Fn(Vec2) -> C64 + Send + Sync>> {
    let k0 = 2.0 * std::f64::consts::PI / scene.wavelength_um;
    let n_b = scene.background.n;
    let outer = scene.domain.rect().expand(scene.domain.pml_wl * scene.wavelength_um / n_b);
    let inc = Incident::from_scene(scene, outer);
    let bodies = bodies_from_scene(scene);
    match id {
        "free_beam" => Some(Box::new(move |p| inc.eval(p))),
        id if id.starts_with("mie") || id == "transparent" || id == "balance" || id == "pml_hygiene" => {
            let e = scene.elements.first()?;
            let Shape::Cylinder { radius_um } = e.shape else { return None };
            let mie = MieCylinder::new(
                Vec2::new(e.x_um, e.y_um),
                radius_um,
                bodies.first()?.material,
                n_b,
                k0,
                scene.source.angle_deg().to_radians(),
                scene.source.amplitude(),
                scene.source.phase_deg().to_radians(),
            );
            Some(Box::new(move |p| mie.total(p)))
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
    let mut mask: Vec<bool> = (0..g.len())
        .map(|idx| {
            if field.is_pec(idx) {
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
    let mut stub = false;
    let mut pass;

    match id {
        "free_beam" | "transparent" => {
            let r = run(&with_method(scene0, method, ppw), quality)?;
            stub = is_stub(&r.field);
            let e = max_scattered(&r.field);
            result.error = Some(e);
            result.detail = "max |E_s| / A".into();
            result.unknowns = r.field.meta.solver.unknowns;
            result.seconds = r.seconds;
            pass = e <= tol;
        }
        "balance" => {
            let r = run(&with_method(scene0, method, ppw), quality)?;
            stub = is_stub(&r.field);
            let fb = flux_balance(&r.field, r.field.scene.domain.rect().expand(-0.5));
            let e = fb.residual();
            result.error = Some(e);
            result.detail = format!("inflow {:.4e}, absorbed {:.4e}", fb.inflow, fb.absorbed);
            result.unknowns = r.field.meta.solver.unknowns;
            result.seconds = r.seconds;
            pass = e <= tol;
        }
        "mom_self" => {
            let a = run(&with_method(scene0.clone(), method, Some(12.0)), quality)?;
            let b = run(&with_method(scene0, method, Some(16.0)), quality)?;
            stub = is_stub(&a.field) || is_stub(&b.field);
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
            let small = run(&with_method(scene0.clone(), method, ppw), quality)?;
            let mut big_scene = scene0;
            big_scene.domain = Domain { x_min_um: -8.0, x_max_um: 8.0, y_min_um: -8.0, y_max_um: 8.0, pml_wl: 1.0 };
            let big = run(&with_method(big_scene, method, ppw), quality)?;
            stub = is_stub(&small.field) || is_stub(&big.field);
            let mask = region_mask("mie_pec", &small.field, method);
            let big_on_small: Vec<C64> = resample(&big.field, Part::Total, &small.field.grid)
                .into_iter()
                .map(|v| v.unwrap_or(C64::new(f64::NAN, 0.0)))
                .collect();
            let e = rel_l2(&small.field.total, &big_on_small, Some(&mask));
            result.error = Some(e);
            result.detail = "domain [−4, 4]² against [−8, 8]²".into();
            result.unknowns = big.field.meta.solver.unknowns;
            result.seconds = small.seconds + big.seconds;
            pass = e <= tol;
        }
        "fdtd_subpixel_order" => {
            let mut orders = [0.0; 2];
            let mut secs = 0.0;
            for (k, subpixel) in [true, false].into_iter().enumerate() {
                let mut errs = [0.0; 2];
                for (l, ppw) in [12.0, 24.0].into_iter().enumerate() {
                    let mut s = with_method(scene0.clone(), method, Some(ppw));
                    s.solver.fdtd.subpixel = subpixel;
                    let r = run(&s, quality)?;
                    stub |= is_stub(&r.field);
                    errs[l] = field_error("mie_diel", &r.field);
                    secs += r.seconds;
                    result.unknowns = r.field.meta.solver.unknowns;
                }
                orders[k] = observed_order(errs[0], errs[1], 1.0 / 12.0, 1.0 / 24.0);
            }
            result.error = Some(orders[0]);
            result.seconds = secs;
            result.detail = format!("order {:.2} with subpixel, {:.2} without (≤ 1.3 required)", orders[0], orders[1]);
            pass = orders[0] >= tol && orders[1] <= 1.3;
        }
        "fem_order" => {
            let mut errs = [0.0; 2];
            for (l, ppw) in [9.0, 15.0].into_iter().enumerate() {
                let mut s = with_method(scene0.clone(), method, Some(ppw));
                s.solver.fem.order = 3;
                let r = run(&s, quality)?;
                stub |= is_stub(&r.field);
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
                    stub |= is_stub(&run.field);
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
            stub = is_stub(&r.field);
            let e = field_error(id, &r.field);
            result.error = Some(e);
            result.unknowns = r.field.meta.solver.unknowns;
            result.seconds = r.seconds;
            pass = e <= tol;
            if id == "mie_high_index" && method == Method::Fdtd && !r.field.meta.solver.converged {
                pass = false;
                result.detail = "not converged".into();
            }
        }
    }
    result.status = if stub {
        Status::Stub
    } else if pass {
        Status::Pass
    } else {
        Status::Fail
    };
    Ok(result)
}
