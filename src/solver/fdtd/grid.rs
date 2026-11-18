//! Yee grid layout: cell size, time step, PML width and node indexing.
//!
//! The full grid has `nx × ny` Ez nodes. Node (I, J) sits at
//! `(x0 + I·Δ, y0 + J·Δ)` with `x0 = interior.x_min − N_p·Δ`, so the interior node
//! (i, j) is the full node (i + N_p, j + N_p). The outermost ring of Ez nodes is
//! PEC (never updated). Hx(I, J) sits at (I, J + ½) and Hy(I, J) at (I + ½, J).

use crate::problem::Problem;
use crate::solver::field::GridSpec;
use crate::types::Vec2;

/// Ramp-up time of the source, in periods.
pub const RAMP_PERIODS: f64 = 4.0;

#[derive(Clone, Copy, Debug)]
pub struct Layout {
    /// Cell size Δ in µm.
    pub dx: f64,
    /// Time step Δt in µm of light travel (c = 1).
    pub dt: f64,
    /// Steps per period P; ωΔt = 2π/P exactly.
    pub steps_per_period: usize,
    /// PML cells N_p on every side.
    pub np: usize,
    /// Interior Ez nodes per row / column.
    pub nxi: usize,
    pub nyi: usize,
    /// Full grid Ez nodes (interior + 2 N_p).
    pub nx: usize,
    pub ny: usize,
    /// Position of full node (0, 0).
    pub x0: f64,
    pub y0: f64,
}

impl Layout {
    pub fn new(p: &Problem) -> Layout {
        let s = &p.settings;
        let dx = p.lambda0 / (s.ppw * p.n_max);
        let steps_per_period = (s.ppw * p.n_max / s.fdtd.courant).ceil().max(4.0) as usize;
        let dt = p.lambda0 / steps_per_period as f64;
        let np = ((p.pml_um / dx - 1e-9).ceil().max(0.0) as usize).max(s.fdtd.min_pml_cells);
        let g = GridSpec::covering(p.interior, dx);
        Layout {
            dx,
            dt,
            steps_per_period,
            np,
            nxi: g.nx,
            nyi: g.ny,
            nx: g.nx + 2 * np,
            ny: g.ny + 2 * np,
            x0: p.interior.x_min - np as f64 * dx,
            y0: p.interior.y_min - np as f64 * dx,
        }
    }

    pub fn cells(&self) -> usize {
        self.nx * self.ny
    }

    pub fn interior_cells(&self) -> usize {
        self.nxi * self.nyi
    }

    /// Position of full Ez node (I, J).
    #[inline]
    pub fn point(&self, i: usize, j: usize) -> Vec2 {
        Vec2::new(self.x0 + i as f64 * self.dx, self.y0 + j as f64 * self.dx)
    }

    /// The interior Ez nodes as an output grid.
    pub fn interior_grid(&self) -> GridSpec {
        GridSpec {
            x0: self.x0 + self.np as f64 * self.dx,
            y0: self.y0 + self.np as f64 * self.dx,
            dx: self.dx,
            nx: self.nxi,
            ny: self.nyi,
        }
    }

    /// ω = k0 in normalised units.
    pub fn omega(&self) -> f64 {
        2.0 * std::f64::consts::PI / (self.dt * self.steps_per_period as f64)
    }
}

/// Transit time `diag(outer) · n_wave / λ0`, in periods. Re n rather than |n|:
/// light does not cross a metal at c/|n|, it decays within a skin depth.
pub fn transit_periods(p: &Problem) -> f64 {
    p.outer().diag() * p.n_wave / p.lambda0
}

/// The default cap on periods: `ceil(T_r + 3 T_tr + 30)`.
pub fn max_periods(p: &Problem) -> usize {
    match p.settings.fdtd.max_periods {
        Some(m) => m.max(1) as usize,
        None => (RAMP_PERIODS + 3.0 * transit_periods(p) + 30.0).ceil() as usize,
    }
}

/// The minimum run `T_r + T_tr`, in whole periods.
pub fn min_periods(p: &Problem) -> usize {
    (RAMP_PERIODS + transit_periods(p)).ceil() as usize
}
