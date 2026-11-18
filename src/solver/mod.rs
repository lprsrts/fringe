//! Solver interface and the solve pipeline.

use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq, Hash, Default)]
#[serde(rename_all = "snake_case")]
pub enum Method {
    #[default]
    Fdtd,
    Fem,
    Mom,
}

impl Method {
    pub fn name(self) -> &'static str {
        match self {
            Method::Fdtd => "fdtd",
            Method::Fem => "fem",
            Method::Mom => "mom",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Method::Fdtd => "FDTD",
            Method::Fem => "FEM",
            Method::Mom => "MoM",
        }
    }

    pub fn parse(s: &str) -> Option<Method> {
        match s.trim().to_ascii_lowercase().as_str() {
            "fdtd" => Some(Method::Fdtd),
            "fem" => Some(Method::Fem),
            "mom" => Some(Method::Mom),
            _ => None,
        }
    }

    pub const ALL: [Method; 3] = [Method::Fdtd, Method::Fem, Method::Mom];
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum Quality {
    Preview,
    Final,
}

impl Quality {
    pub fn name(self) -> &'static str {
        match self {
            Quality::Preview => "preview",
            Quality::Final => "final",
        }
    }

    pub fn parse(s: &str) -> Option<Quality> {
        match s.trim().to_ascii_lowercase().as_str() {
            "preview" => Some(Quality::Preview),
            "final" => Some(Quality::Final),
            _ => None,
        }
    }
}

pub mod context;
pub mod fdtd;
pub mod fem;
pub mod field;
pub mod mom;

use std::time::Instant;

use rayon::prelude::*;

pub use crate::scene::Issue;
use crate::problem::{compile, Problem};
use crate::scene::Scene;
use crate::types::C64;

pub use context::{Progress, ProgressSnapshot, SolveContext};
pub use fdtd::FdtdSolver;
pub use fem::FemSolver;
pub use field::{BodyInfo, FieldGrid, GridSpec, Norms, Part, SolveMeta};
pub use mom::MomSolver;

pub trait Solver: Send + Sync {
    fn method(&self) -> Method;
    /// Capability errors and warnings, with paths like "solver.fdtd".
    fn check(&self, p: &Problem) -> Vec<Issue>;
    fn estimate(&self, p: &Problem) -> Estimate;
    fn solve(&self, p: &Problem, ctx: &SolveContext) -> Result<SolverOutput, SolveError>;
}

#[derive(Clone, Debug, PartialEq)]
pub struct Estimate {
    pub unknowns: u64,
    pub memory_mb: f64,
    pub seconds: f64,
    pub grid: Option<[usize; 2]>,
    pub detail: String,
}

pub struct SolverOutput {
    pub grid: GridSpec,
    /// Index j·nx + i; values inside PEC are ignored.
    pub scattered: Vec<C64>,
    /// `Some` only for FDTD (its dispersion-matched incident field); `None` means
    /// the pipeline evaluates the analytic incident field on `grid`.
    pub incident: Option<Vec<C64>>,
    pub meta: SolverMeta,
}

#[derive(Clone, Debug, Default, serde::Serialize)]
pub struct SolverMeta {
    pub unknowns: u64,
    pub periods: Option<f64>,
    pub converged: bool,
    pub residual: Option<f64>,
    pub cond_estimate: Option<f64>,
    pub timings: Vec<(String, f64)>,
    pub warnings: Vec<String>,
}

#[derive(Clone, Debug)]
pub enum SolveError {
    Invalid(Vec<Issue>),
    Unsupported(String),
    TooLarge { need_mb: f64, limit_mb: f64 },
    Numerical(String),
    Cancelled,
    Internal(String),
}

impl SolveError {
    pub fn code(&self) -> &'static str {
        match self {
            SolveError::Invalid(_) => "invalid",
            SolveError::Unsupported(_) => "unsupported",
            SolveError::TooLarge { .. } => "too_large",
            SolveError::Numerical(_) => "numerical",
            SolveError::Cancelled => "cancelled",
            SolveError::Internal(_) => "internal",
        }
    }

    pub fn issues(&self) -> &[Issue] {
        match self {
            SolveError::Invalid(v) => v,
            _ => &[],
        }
    }
}

impl std::fmt::Display for SolveError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SolveError::Invalid(issues) => match issues.first() {
                Some(i) => write!(f, "invalid scene: {} ({})", i.message, i.path),
                None => write!(f, "invalid scene"),
            },
            SolveError::Unsupported(m) => write!(f, "{m}"),
            SolveError::TooLarge { need_mb, limit_mb } => {
                write!(f, "needs about {need_mb:.0} MB, more than the {limit_mb:.0} MB limit")
            }
            SolveError::Numerical(m) => write!(f, "numerical failure: {m}"),
            SolveError::Cancelled => write!(f, "cancelled"),
            SolveError::Internal(m) => write!(f, "internal error: {m}"),
        }
    }
}

impl std::error::Error for SolveError {}

#[repr(u32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Stage {
    Setup = 0,
    Geometry = 1,
    Assemble = 2,
    Solve = 3,
    Sample = 4,
    Finished = 5,
}

pub fn solver_for(m: Method) -> &'static dyn Solver {
    match m {
        Method::Fdtd => &FdtdSolver,
        Method::Fem => &FemSolver,
        Method::Mom => &MomSolver,
    }
}

/// Seconds per output point and incident plane wave for evaluating the incident
/// field (one GEMM; release build, M-series Mac).
const C_INCIDENT: f64 = 5e-11;
/// The same per line source (one Hankel function per point, in parallel).
const C_LINE: f64 = 2e-8;

/// The selected solver's estimate for `p`, plus the cost of evaluating the
/// incident field on the output grid, which matters for a Gaussian beam with
/// thousands of plane waves.
pub fn estimate(p: &Problem) -> Estimate {
    let solver = solver_for(p.settings.method);
    let mut est = solver.estimate(p);
    let points = match p.settings.method {
        Method::Fdtd => est.grid.map_or(0, |[nx, ny]| nx * ny),
        Method::Fem | Method::Mom => p.output_grid().len(),
    };
    est.seconds += (C_INCIDENT * p.incident.comps.len() as f64 + C_LINE * p.incident.lines.len() as f64) * points as f64;
    est
}

/// Validates, compiles and solves `scene` with its selected method, and returns
/// the total and incident fields on the solver's grid.
pub fn solve(scene: &Scene, quality: Quality, ctx: &SolveContext) -> Result<FieldGrid, SolveError> {
    let t0 = Instant::now();
    ctx.stage(Stage::Setup, (0.0, 0.02));
    let p = compile(scene, quality).map_err(SolveError::Invalid)?;
    let solver = solver_for(p.settings.method);
    let est = estimate(&p);
    if let Some(e) = solver.check(&p).into_iter().find(|i| i.is_error()) {
        if e.code == "too_large" {
            return Err(SolveError::TooLarge { need_mb: est.memory_mb, limit_mb: p.settings.memory_limit_mb });
        }
        return Err(SolveError::Unsupported(e.message));
    }
    if est.memory_mb > p.settings.memory_limit_mb {
        return Err(SolveError::TooLarge { need_mb: est.memory_mb, limit_mb: p.settings.memory_limit_mb });
    }
    ctx.set_unknowns(est.unknowns);
    ctx.checkpoint()?;
    let out = solver.solve(&p, ctx)?;
    ctx.checkpoint()?;

    let grid = out.grid;
    if out.scattered.len() != grid.len() {
        return Err(SolveError::Internal(format!(
            "solver returned {} values for a {}×{} grid",
            out.scattered.len(),
            grid.nx,
            grid.ny
        )));
    }
    let (incident, incident_kind) = match out.incident {
        Some(v) if v.len() == grid.len() => (v, "yee_matched"),
        Some(_) => return Err(SolveError::Internal("incident field does not match the grid".into())),
        None => (p.incident.eval_grid(&grid), "analytic"),
    };
    let region = region_map(&p, &grid);
    let pec: Vec<bool> = p.bodies.iter().map(|b| b.is_pec()).collect();
    let total: Vec<C64> = out
        .scattered
        .par_iter()
        .zip(incident.par_iter())
        .zip(region.par_iter())
        .map(|((s, i), &r)| if r > 0 && pec[r as usize - 1] { C64::new(0.0, 0.0) } else { s + i })
        .collect();

    let outline_chord = p.lambda_min() / 20.0;
    let bodies = p.bodies.iter().map(|b| BodyInfo::from_body(b, outline_chord)).collect();
    let field = FieldGrid {
        grid,
        total,
        incident,
        region,
        bodies,
        scene: p.scene.clone(),
        quality,
        meta: SolveMeta {
            solver: out.meta,
            method: p.settings.method,
            quality,
            ppw: p.settings.ppw,
            incident_kind: incident_kind.into(),
            wall_s: t0.elapsed().as_secs_f64(),
            memory_mb: est.memory_mb,
        },
        norms: Default::default(),
        readings: Default::default(),
    };
    ctx.stage(Stage::Finished, (1.0, 1.0));
    Ok(field)
}

/// Body index + 1 of every grid node (0 for background), by rows in parallel with
/// bounding-box culling.
pub fn region_map(p: &Problem, g: &GridSpec) -> Vec<u16> {
    let mut region = vec![0u16; g.len()];
    if p.bodies.is_empty() {
        return region;
    }
    region.par_chunks_mut(g.nx).enumerate().for_each(|(j, row)| {
        let y = g.y0 + j as f64 * g.dx;
        for (b, body) in p.bodies.iter().enumerate() {
            if y < body.bbox.y_min || y > body.bbox.y_max {
                continue;
            }
            let i0 = ((body.bbox.x_min - g.x0) / g.dx).floor().max(0.0) as usize;
            let i1 = (((body.bbox.x_max - g.x0) / g.dx).ceil().max(0.0) as usize).min(g.nx.saturating_sub(1));
            for (i, cell) in row.iter_mut().enumerate().take(i1 + 1).skip(i0) {
                if *cell == 0 && body.inside(g.point(i, j)) {
                    *cell = (b + 1) as u16;
                }
            }
        }
    });
    region
}
