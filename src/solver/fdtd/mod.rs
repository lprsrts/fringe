//! Finite-difference time-domain solver (spec §5.1).
//!
//! A 2D Yee scheme for Ez (TM_z) in normalised units (c = ε0 = μ0 = 1, H̃ = η0 H,
//! time in µm of light travel), solved for the scattered field. Sources are the
//! polarisation currents `J = (ε′ − ε_b,u) ∂_t E_inc + σ E_inc` inside dielectric
//! bodies, written in the exactly consistent discrete form, plus `E_s = −E_inc` on
//! PEC nodes. The incident field is the Yee-dispersion-matched copy of the
//! analytic one (every plane-wave component gets its numerical wavenumber), so
//! `E_s + E_inc` is an exact discrete total-field solution and the shadow shows
//! no ghost beam. All media get the axis dispersion correction ε·F when enabled.
//!
//! The run ramps the source over 4 periods, runs at least the ramp plus one
//! transit time, watches a one-period DFT at probe nodes until it settles, and
//! then takes a 2-period DFT on every interior node.
//!
//! Files: `grid.rs` (layout), `materials.rs` (rasterisation), `cpml.rs` (PML
//! coefficients), `update.rs` (the time step), `dft.rs` (run control).

pub mod cpml;
pub mod dft;
pub mod grid;
pub mod materials;
pub mod update;

use std::time::Instant;

use crate::problem::Problem;
use crate::scene::validate::fmt;
use crate::scene::{Material, Shape};
use crate::source::yee::{dispersion_corrected_eps, yee_wavenumber};
use crate::source::Incident;
use crate::types::C64;

use super::{Estimate, Issue, Method, Quality, SolveContext, SolveError, Solver, SolverMeta, SolverOutput, Stage};
use grid::{min_periods, Layout};
use materials::{body_eps, rasterize, NodeMat};
use update::{Engine, EngineInit, PecNode, SrcNode};

pub struct FdtdSolver;

/// Seconds per cell-step (calibrated on an 8-core M-series Mac, release build).
const C_FDTD: f64 = 1.5e-10;
/// Periods beyond the minimum run that convergence typically takes, plus the
/// 2-period DFT.
const EXTRA_PERIODS: f64 = 6.0;
/// Cell limits per quality.
const MAX_CELLS_PREVIEW: usize = 4_000_000;
const MAX_CELLS_FINAL: usize = 40_000_000;

/// Number of whole periods of the final DFT.
const DFT_PERIODS: usize = 2;

impl FdtdSolver {
    /// Estimated number of periods a solve runs.
    pub fn estimated_periods(p: &Problem) -> f64 {
        let est = min_periods(p) as f64 + EXTRA_PERIODS;
        est.min((grid::max_periods(p) + DFT_PERIODS) as f64)
    }
}

/// ε of the background and of each body as the grid sees it (dispersion
/// corrected along the source axis when enabled).
pub struct Media {
    pub eps_bg: f64,
    pub bodies: Vec<Option<C64>>,
}

pub fn media(p: &Problem, l: &Layout) -> Media {
    let axis = p.incident.axis_angle;
    let corr = p.settings.fdtd.dispersion_correction;
    let correct = |e: C64| if corr { dispersion_corrected_eps(e, axis, p.k0, l.dx, l.dt) } else { e };
    Media { eps_bg: correct(C64::new(p.eps_b, 0.0)).re, bodies: body_eps(p, correct) }
}

/// The Yee-matched copy of the problem's incident field.
pub fn matched_incident(p: &Problem, l: &Layout, eps_bg: f64) -> Incident {
    let omega = l.omega();
    p.incident.map_wavenumbers(|phi| yee_wavenumber(phi, eps_bg, omega, l.dx, l.dt))
}

fn memory_mb(l: &Layout) -> f64 {
    // ez, hx, hy, Ca, Cb/Δ (f32) per cell; ψ strips; the f64 DFT accumulators,
    // the scattered and incident outputs and the pipeline's total field (16 B
    // each) per interior node.
    let psi = 8.0 * 2.0 * l.np as f64 * (l.nx + l.ny) as f64;
    (20.0 * l.cells() as f64 + psi + 64.0 * l.interior_cells() as f64) / 1e6
}

impl Solver for FdtdSolver {
    fn method(&self) -> Method {
        Method::Fdtd
    }

    fn check(&self, p: &Problem) -> Vec<Issue> {
        let mut out = Vec::new();
        let l = Layout::new(p);
        let q = p.quality;
        let limit = match q {
            Quality::Preview => MAX_CELLS_PREVIEW,
            Quality::Final => MAX_CELLS_FINAL,
        };
        if l.cells() > limit {
            out.push(
                Issue::error(
                    "solver.fdtd",
                    "too_large",
                    format!(
                        "the FDTD grid has {} cells ({} × {}), more than the {} limit for {}",
                        l.cells(),
                        l.nx,
                        l.ny,
                        limit,
                        q.name()
                    ),
                )
                .for_quality(q),
            );
        }
        for b in p.bodies.iter().filter(|b| b.is_pec()) {
            if let Some(t) = b.nominal_thickness_um.filter(|&t| t < l.dx) {
                out.push(
                    Issue::error(
                        format!("elements[{}].shape", b.element_index),
                        "fdtd_thin_pec",
                        format!(
                            "\"{}\" is {} µm thick, thinner than the FDTD cell Δ = {} µm; use MoM or FEM, or raise the FDTD resolution",
                            b.name,
                            fmt(t),
                            fmt(l.dx)
                        ),
                    )
                    .for_quality(q),
                );
            }
        }
        let mut slow = None;
        let mut pec_elements = 0;
        for (i, e) in p.scene.elements.iter().enumerate().filter(|(_, e)| e.enabled) {
            match e.shape {
                Shape::Grating { .. } => slow = slow.or(Some((i, "grating"))),
                Shape::Waveguide { .. } => slow = slow.or(Some((i, "waveguide"))),
                _ => {}
            }
            if matches!(e.material, Material::Pec) || matches!(e.shape, Shape::Mirror { .. } | Shape::Slits { .. }) {
                pec_elements += 1;
            }
        }
        if let Some((i, what)) = slow {
            out.push(Issue::warning(
                format!("elements[{i}]"),
                "fdtd_slow_convergence",
                format!("the FDTD may converge slowly with a {what} (resonant fields); FEM or MoM may be faster"),
            ));
        } else if pec_elements >= 2 {
            out.push(Issue::warning(
                "solver.fdtd",
                "fdtd_slow_convergence",
                "the FDTD may converge slowly in a PEC cavity; FEM or MoM may be faster",
            ));
        }
        out
    }

    fn estimate(&self, p: &Problem) -> Estimate {
        let l = Layout::new(p);
        let cells = l.cells() as u64;
        let periods = Self::estimated_periods(p);
        let steps = l.steps_per_period as f64;
        Estimate {
            unknowns: cells,
            memory_mb: memory_mb(&l),
            seconds: cells as f64 * steps * periods * C_FDTD,
            grid: Some([l.nx, l.ny]),
            detail: format!("{}k cells · {} steps/period · ~{:.0} periods", cells / 1000, l.steps_per_period, periods),
        }
    }

    fn solve(&self, p: &Problem, ctx: &SolveContext) -> Result<SolverOutput, SolveError> {
        let t0 = Instant::now();
        let mut timings = Vec::new();
        let l = Layout::new(p);
        ctx.stage(Stage::Geometry, (0.02, 0.08));
        let media = media(p, &l);
        let eps_bg = media.eps_bg;
        let matched = matched_incident(p, &l, eps_bg);
        if matched.comps.iter().any(|c| !c.k[0].is_finite() || !c.k[1].is_finite()) {
            return Err(SolveError::Numerical("no Yee wavenumber for the incident field (Courant limit)".into()));
        }
        let cancel = ctx.cancel_flag();
        let raster =
            rasterize(p, &l, C64::new(eps_bg, 0.0), &media.bodies, &cancel).ok_or(SolveError::Cancelled)?;
        ctx.report(0.5);
        ctx.checkpoint()?;

        // Coefficients, sources and PEC nodes.
        let (nx, ny) = (l.nx, l.ny);
        let dt = l.dt;
        let omega = l.omega();
        let cb_bg = dt / eps_bg;
        let mut ca = vec![1.0f32; nx * ny];
        let mut cbd = vec![(cb_bg / l.dx) as f32; nx * ny];
        for jj in 0..ny {
            for ii in [0, nx - 1] {
                ca[jj * nx + ii] = 0.0;
                cbd[jj * nx + ii] = 0.0;
            }
        }
        for jj in [0, ny - 1] {
            ca[jj * nx..(jj + 1) * nx].fill(0.0);
            cbd[jj * nx..(jj + 1) * nx].fill(0.0);
        }
        let pts: Vec<_> = raster.nodes.iter().map(|&(idx, _)| l.point(idx % nx, idx / nx)).collect();
        let e_inc = matched.eval_points(&pts);
        ctx.checkpoint()?;
        let mut src = Vec::new();
        let mut pec = Vec::new();
        for (&(idx, m), e) in raster.nodes.iter().zip(&e_inc) {
            match m {
                NodeMat::Pec => {
                    ca[idx] = 0.0;
                    cbd[idx] = 0.0;
                    pec.push(PecNode { idx: idx as u32, re: e.re as f32, im: e.im as f32 });
                }
                NodeMat::Medium(eps) => {
                    // ε = ε′ − jε″, σ = ω ε″.
                    let e1 = eps.re;
                    let sigma = -omega * eps.im;
                    let loss = sigma * dt / (2.0 * e1);
                    let a = (1.0 - loss) / (1.0 + loss);
                    let cb = (dt / e1) / (1.0 + loss);
                    ca[idx] = a as f32;
                    cbd[idx] = (cb / l.dx) as f32;
                    let c1 = cb * (e1 - eps_bg) / dt;
                    let c2 = cb * 0.5 * sigma;
                    src.push(SrcNode {
                        idx: idx as u32,
                        u1: (c1 * e.re) as f32,
                        u2: (c2 * e.re) as f32,
                        v1: (c1 * e.im) as f32,
                        v2: (c2 * e.im) as f32,
                    });
                }
            }
        }
        let px = cpml::profiles(&l, nx, eps_bg, p.k_b);
        let py = cpml::profiles(&l, ny, eps_bg, p.k_b);
        let mut engine = Engine::new(l, EngineInit { ca, cbd, cb_bg: cb_bg as f32, src, pec, px, py });
        // Matched incident at the probes, the scale for the convergence measure.
        let stride = update::PROBE_STRIDE;
        let probe_pts: Vec<_> = (0..engine.probe_rows)
            .flat_map(|r| (0..engine.probe_cols).map(move |c| l.point(l.np + c * stride, l.np + r * stride)))
            .collect();
        let inc_probe_norm = matched.eval_points(&probe_pts).iter().map(|v| v.norm_sqr()).sum::<f64>().sqrt();
        timings.push(("setup".to_string(), t0.elapsed().as_secs_f64()));
        ctx.report(1.0);
        ctx.checkpoint()?;

        // Time stepping.
        let t1 = Instant::now();
        ctx.stage(Stage::Solve, (0.08, 0.97));
        let est_periods = Self::estimated_periods(p);
        let run = dft::run(
            &mut engine,
            &dft::RunParams {
                min_periods: min_periods(p),
                max_periods: grid::max_periods(p),
                steady_tol: p.settings.fdtd.steady_tol,
                inc_probe_norm,
                dft_periods: DFT_PERIODS,
            },
            |periods| {
                ctx.report((periods / est_periods).min(0.95));
                ctx.is_cancelled()
            },
        )
        .ok_or(SolveError::Cancelled)?;
        timings.push(("time stepping".to_string(), t1.elapsed().as_secs_f64()));

        // Output: the scattered phasor and the matched incident field.
        let t2 = Instant::now();
        ctx.stage(Stage::Sample, (0.97, 1.0));
        let grid = l.interior_grid();
        let scale = 2.0 / (DFT_PERIODS * l.steps_per_period) as f64;
        let scattered: Vec<C64> =
            engine.acc_re.iter().zip(&engine.acc_im).map(|(&re, &im)| C64::new(re * scale, im * scale)).collect();
        drop(engine);
        ctx.checkpoint()?;
        let incident = matched.eval_grid(&grid);
        timings.push(("output".to_string(), t2.elapsed().as_secs_f64()));

        let mut warnings = Vec::new();
        if !run.converged {
            warnings.push(format!(
                "not fully settled (Δ = {:.1e}) after {} periods; FEM or MoM may suit this scene better",
                run.last_change, run.periods
            ));
        }
        warnings.extend(p.incident.warnings.iter().cloned());
        Ok(SolverOutput {
            grid,
            scattered,
            incident: Some(incident),
            meta: SolverMeta {
                unknowns: l.cells() as u64,
                periods: Some(run.periods as f64),
                converged: run.converged,
                residual: Some(run.last_change),
                cond_estimate: None,
                timings,
                warnings,
            },
        })
    }
}
