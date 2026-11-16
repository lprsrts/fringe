//! Run control: source ramp, the per-period probe DFT that decides when the
//! field has settled, and the final whole-period DFT on every interior node.
//!
//! With `t_m = mΔt` and `ωΔt = 2π/P`, the incident field at step m is
//! `E_inc^m = Re(r(t_m) Ê e^{jωt_m}) = a_m Re Ê − b_m Im Ê` with the ramp
//! `r(t) = (1 − cos(π t/T_r))/2` for t < T_r = 4 periods. A one-period DFT
//! `P_k = (2/P) Σ E_s^m e^{−jωt_m}` at the probes gives
//! `change = ‖P_k − P_{k−1}‖ / max(‖P_k‖, 0.01 ‖Ê_inc,probes‖)`.

use std::f64::consts::PI;

use super::grid::RAMP_PERIODS;
use super::update::{Engine, StepPhase};

pub struct RunParams {
    pub min_periods: usize,
    pub max_periods: usize,
    pub steady_tol: f64,
    pub inc_probe_norm: f64,
    pub dft_periods: usize,
}

#[derive(Clone, Copy, Debug)]
pub struct RunResult {
    /// Periods run in total, including the final DFT.
    pub periods: usize,
    pub converged: bool,
    pub last_change: f64,
}

/// Ramp-weighted source phase (a_m, b_m) at step m.
fn source_phase(m: usize, p: usize) -> (f64, f64) {
    let t = m as f64 / p as f64;
    let r = if t < RAMP_PERIODS { 0.5 * (1.0 - (PI * t / RAMP_PERIODS).cos()) } else { 1.0 };
    let th = 2.0 * PI * (m % p) as f64 / p as f64;
    (r * th.cos(), r * th.sin())
}

fn phase(n: usize, p: usize, probe: bool, full: bool) -> StepPhase {
    let (a0, b0) = source_phase(n, p);
    let (a1, b1) = source_phase(n + 1, p);
    let th = 2.0 * PI * ((n + 1) % p) as f64 / p as f64;
    let e = (th.cos(), -th.sin());
    StepPhase {
        da: (a1 - a0) as f32,
        sa: (a1 + a0) as f32,
        db: (b1 - b0) as f32,
        sb: (b1 + b0) as f32,
        a1: a1 as f32,
        b1: b1 as f32,
        probe: probe.then_some(e),
        full: full.then_some(e),
    }
}

/// Runs to steady state and accumulates the final DFT into `engine.acc_*`.
/// `tick(periods_done)` is called after every step and returns true to cancel;
/// the run then returns `None`.
pub fn run(engine: &mut Engine, prm: &RunParams, mut tick: impl FnMut(f64) -> bool) -> Option<RunResult> {
    let p = engine.l.steps_per_period;
    let mut n = 0usize;
    let mut prev: Option<(Vec<f64>, Vec<f64>)> = None;
    let mut settled = 0;
    let mut last_change = f64::INFINITY;
    let mut converged = false;
    let mut period = 0usize;
    let scale = 2.0 / p as f64;
    while period < prm.max_periods {
        engine.reset_probes();
        for _ in 0..p {
            engine.step(&phase(n, p, true, false));
            n += 1;
            if tick(n as f64 / p as f64) {
                return None;
            }
        }
        period += 1;
        if let Some((pre, pim)) = &prev {
            let (mut diff, mut norm) = (0.0, 0.0);
            for q in 0..pre.len() {
                let (re, im) = (engine.probe_re[q] * scale, engine.probe_im[q] * scale);
                diff += (re - pre[q]).powi(2) + (im - pim[q]).powi(2);
                norm += re * re + im * im;
            }
            let den = norm.sqrt().max(0.01 * prm.inc_probe_norm);
            last_change = if diff == 0.0 { 0.0 } else { diff.sqrt() / den };
        }
        prev = Some((
            engine.probe_re.iter().map(|v| v * scale).collect(),
            engine.probe_im.iter().map(|v| v * scale).collect(),
        ));
        if period >= prm.min_periods {
            if last_change < prm.steady_tol {
                settled += 1;
            } else {
                settled = 0;
            }
            if settled >= 2 {
                converged = true;
                break;
            }
        }
    }
    engine.start_full_dft();
    for _ in 0..prm.dft_periods * p {
        engine.step(&phase(n, p, false, true));
        n += 1;
        if tick(n as f64 / p as f64) {
            return None;
        }
    }
    Some(RunResult { periods: period + prm.dft_periods, converged, last_change })
}
