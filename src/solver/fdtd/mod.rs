//! Finite-difference time-domain solver.
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

use super::field::GridSpec;
use super::{Estimate, Issue, Method, Quality, SolveContext, SolveError, Solver, SolverMeta, SolverOutput, Stage};
use grid::{min_periods, Layout};
use materials::{body_eps, pec_edges, rasterize, NodeMat};
use update::{EdgeNode, Engine, EngineInit, PecNode, SrcNode};

pub struct FdtdSolver;

/// Seconds per cell-step and fixed seconds per step (thread synchronisation of
/// the two parallel sweeps), calibrated on an 8-core M-series Mac, release build.
const C_FDTD: f64 = 4.5e-10;
const T_STEP: f64 = 5e-5;
/// Periods beyond the minimum run that convergence typically takes, plus the
/// 2-period DFT.
const EXTRA_PERIODS: f64 = 6.0;
/// Index contrast n_max/n_b from which dielectric bodies may hold ringing
/// resonances (the `nanojet` cylinder at 1.6 settles after ~3× the typical run
/// at final quality; `mie_high_index` at 3.5 runs to the cap).
const RESONANT_CONTRAST: f64 = 1.6;
/// Cell limits per quality.
const MAX_CELLS_PREVIEW: usize = 4_000_000;
const MAX_CELLS_FINAL: usize = 40_000_000;

/// Number of whole periods of the final DFT.
const DFT_PERIODS: usize = 2;

impl FdtdSolver {
    /// Estimated number of periods a solve runs. A scene that may ring (a
    /// waveguide, a PEC cavity or a high-contrast dielectric) settles anywhere
    /// between the typical run and the cap, so it gets their geometric mean,
    /// which bounds the ratio to the measured time by √(cap/typical) either way.
    /// Gratings keep the typical run: they are warned about, but the `talbot`
    /// example settles in it.
    pub fn estimated_periods(p: &Problem) -> f64 {
        let cap = (grid::max_periods(p) + DFT_PERIODS) as f64;
        let typical = (min_periods(p) as f64 + EXTRA_PERIODS).min(cap);
        let resonant = p.n_max >= RESONANT_CONTRAST * p.eps_b.sqrt() - 1e-12;
        if resonant || slow_convergence(p).is_some_and(|s| s.kind != "grating") {
            (typical * cap).sqrt()
        } else {
            typical
        }
    }
}

/// Why a scene may converge slowly, for the `fdtd_slow_convergence` warning.
struct SlowConvergence {
    path: String,
    /// "grating", "waveguide" or "cavity".
    kind: &'static str,
}

impl SlowConvergence {
    fn message(&self) -> String {
        match self.kind {
            "cavity" => "the FDTD may converge slowly in a PEC cavity; FEM or MoM may be faster".into(),
            what => format!("the FDTD may converge slowly with a {what} (resonant fields); FEM or MoM may be faster"),
        }
    }
}

/// Scenes whose fields may ring for long: a grating, a waveguide, or two or
/// more PEC elements.
fn slow_convergence(p: &Problem) -> Option<SlowConvergence> {
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
    if let Some((i, kind)) = slow {
        Some(SlowConvergence { path: format!("elements[{i}]"), kind })
    } else if pec_elements >= 2 {
        Some(SlowConvergence { path: "solver.fdtd".into(), kind: "cavity" })
    } else {
        None
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

/// Grid rows per incident-field block between cancellation checks.
const BLOCK_ROWS: usize = 32;

/// `inc` on every node of `g`, one GEMM per block of rows with a cancellation
/// check after each.
fn incident_on_grid(inc: &Incident, g: &GridSpec, ctx: &SolveContext) -> Result<Vec<C64>, SolveError> {
    let mut out = Vec::with_capacity(g.len());
    for j0 in (0..g.ny).step_by(BLOCK_ROWS) {
        let rows = BLOCK_ROWS.min(g.ny - j0);
        out.extend(inc.eval_grid(&GridSpec { y0: g.y0 + j0 as f64 * g.dx, ny: rows, ..*g }));
        ctx.checkpoint()?;
    }
    Ok(out)
}

/// `inc` at the full-grid nodes `nodes` (sorted by index): GEMMs over the
/// bounding columns of each block of rows.
fn incident_at_nodes(
    inc: &Incident,
    l: &Layout,
    nodes: &[(usize, NodeMat)],
    ctx: &SolveContext,
) -> Result<Vec<C64>, SolveError> {
    let nx = l.nx;
    let mut out = Vec::with_capacity(nodes.len());
    let mut s = 0;
    while s < nodes.len() {
        let j0 = nodes[s].0 / nx;
        let e = s + nodes[s..].partition_point(|n| n.0 / nx < j0 + BLOCK_ROWS);
        let block = &nodes[s..e];
        let i0 = block.iter().map(|n| n.0 % nx).min().unwrap_or(0);
        let i1 = block.iter().map(|n| n.0 % nx).max().unwrap_or(0);
        let j1 = block[block.len() - 1].0 / nx;
        let g = GridSpec { x0: l.x0 + i0 as f64 * l.dx, y0: l.y0 + j0 as f64 * l.dx, dx: l.dx, nx: i1 - i0 + 1, ny: j1 - j0 + 1 };
        let v = inc.eval_grid(&g);
        out.extend(block.iter().map(|n| v[(n.0 / nx - j0) * g.nx + n.0 % nx - i0]));
        ctx.checkpoint()?;
        s = e;
    }
    Ok(out)
}

fn memory_mb(l: &Layout) -> f64 {
    // ez, hx, hy, Ca, Cb/Δ (f32) per cell; ψ strips; per interior node the f64
    // DFT accumulators, the scattered and incident outputs, the pipeline's total
    // field and region map; plus a fixed process baseline.
    let psi = 8.0 * 2.0 * l.np as f64 * (l.nx + l.ny) as f64;
    (20.0 * l.cells() as f64 + psi + 70.0 * l.interior_cells() as f64) / 1e6 + 5.0
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
        if let Some(slow) = slow_convergence(p) {
            out.push(Issue::warning(slow.path.clone(), "fdtd_slow_convergence", slow.message()));
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
            seconds: steps * periods * (T_STEP + cells as f64 * C_FDTD),
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
        let e_inc = incident_at_nodes(&matched, &l, &raster.nodes, ctx)?;
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
        let edges = if p.settings.fdtd.subpixel { pec_edges(p, &l, &raster) } else { Vec::new() };
        let dtdx = dt / l.dx;
        let edges: Vec<EdgeNode> = edges
            .iter()
            .map(|e| {
                let v = matched.eval(l.point(e.free % nx, e.free / nx));
                EdgeNode {
                    h: e.h as u32,
                    hx: e.hx,
                    free: e.free as u32,
                    coef: (e.sign * dtdx * (l.dx / e.len - 1.0)) as f32,
                    re: v.re as f32,
                    im: v.im as f32,
                }
            })
            .collect();
        ctx.checkpoint()?;
        let px = cpml::profiles(&l, nx, eps_bg, p.k_b);
        let py = cpml::profiles(&l, ny, eps_bg, p.k_b);
        let mut engine = Engine::new(l, EngineInit { ca, cbd, cb_bg: cb_bg as f32, src, pec, edges, px, py });
        // Matched incident at the probes, the scale for the convergence measure.
        let interior = l.interior_grid();
        let probes = GridSpec {
            dx: interior.dx * update::PROBE_STRIDE as f64,
            nx: engine.probe_cols,
            ny: engine.probe_rows,
            ..interior
        };
        let inc_probe_norm = incident_on_grid(&matched, &probes, ctx)?.iter().map(|v| v.norm_sqr()).sum::<f64>().sqrt();
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
        .map_err(|stop| match stop {
            dft::Stop::Cancelled => SolveError::Cancelled,
            dft::Stop::NonFinite => SolveError::Numerical("the FDTD field became infinite or NaN".into()),
        })?;
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
        let incident = incident_on_grid(&matched, &grid, ctx)?;
        timings.push(("output".to_string(), t2.elapsed().as_secs_f64()));

        let mut warnings = Vec::new();
        if !run.converged {
            let delta = run.last_change.map(|c| format!(" (Δ = {c:.1e})")).unwrap_or_default();
            warnings.push(format!(
                "not fully settled{delta} after {} periods; FEM or MoM may suit this scene better",
                run.periods
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
                residual: run.last_change,
                cond_estimate: None,
                timings,
                warnings,
            },
        })
    }
}
