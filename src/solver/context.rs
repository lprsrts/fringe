//! Cancellation and progress shared between a running solve and its observers.

use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::Arc;
use crate::time::Instant;

use super::{SolveError, Stage};

pub const STATE_RUNNING: u32 = 0;
pub const STATE_DONE: u32 = 1;
pub const STATE_FAILED: u32 = 2;
pub const STATE_CANCELLED: u32 = 3;

/// Lock-free progress record: everything is an atomic, the fraction is f64 bits
/// raised only by compare-and-swap, so readers see a monotone value.
pub struct Progress {
    state: AtomicU32,
    stage: AtomicU32,
    fraction: AtomicU64,
    unknowns: AtomicU64,
    span_lo: AtomicU64,
    span_hi: AtomicU64,
    start: Instant,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ProgressSnapshot {
    pub state: u32,
    pub stage: u32,
    pub fraction: f64,
    pub elapsed_s: f64,
    pub unknowns: u64,
}

impl Default for Progress {
    fn default() -> Self {
        Self::new()
    }
}

impl Progress {
    pub fn new() -> Self {
        Self {
            state: AtomicU32::new(STATE_RUNNING),
            stage: AtomicU32::new(Stage::Setup as u32),
            fraction: AtomicU64::new(0f64.to_bits()),
            unknowns: AtomicU64::new(0),
            span_lo: AtomicU64::new(0f64.to_bits()),
            span_hi: AtomicU64::new(1f64.to_bits()),
            start: Instant::now(),
        }
    }

    pub fn snapshot(&self) -> ProgressSnapshot {
        ProgressSnapshot {
            state: self.state.load(Ordering::Acquire),
            stage: self.stage.load(Ordering::Relaxed),
            fraction: f64::from_bits(self.fraction.load(Ordering::Relaxed)),
            elapsed_s: self.start.elapsed().as_secs_f64(),
            unknowns: self.unknowns.load(Ordering::Relaxed),
        }
    }

    pub fn set_state(&self, state: u32) {
        self.state.store(state, Ordering::Release);
    }

    pub fn set_stage(&self, stage: Stage) {
        self.stage.store(stage as u32, Ordering::Relaxed);
    }

    /// Raises the overall fraction to `f` if it is higher.
    pub fn raise_fraction(&self, f: f64) {
        let f = f.clamp(0.0, 1.0);
        let mut cur = self.fraction.load(Ordering::Relaxed);
        while f > f64::from_bits(cur) {
            match self
                .fraction
                .compare_exchange_weak(cur, f.to_bits(), Ordering::Relaxed, Ordering::Relaxed)
            {
                Ok(_) => break,
                Err(actual) => cur = actual,
            }
        }
    }
}

/// Handed to a solver: a cancel flag to poll and a progress record to update.
///
/// A context may cover only part of the overall progress (see
/// [`SolveContext::window`]), so that several solves in a row, as in a puzzle
/// evaluation, report one monotone fraction.
#[derive(Clone)]
pub struct SolveContext {
    cancel: Arc<AtomicBool>,
    progress: Arc<Progress>,
    window: (f64, f64),
}

impl Default for SolveContext {
    fn default() -> Self {
        Self::new()
    }
}

impl SolveContext {
    pub fn new() -> Self {
        Self {
            cancel: Arc::new(AtomicBool::new(false)),
            progress: Arc::new(Progress::new()),
            window: (0.0, 1.0),
        }
    }

    /// The same cancel flag and progress record, with this context's progress
    /// span narrowed to the part from `lo` to `hi` (fractions of it).
    pub fn window(&self, lo: f64, hi: f64) -> SolveContext {
        SolveContext { cancel: self.cancel.clone(), progress: self.progress.clone(), window: (self.map(lo), self.map(hi)) }
    }

    fn map(&self, f: f64) -> f64 {
        self.window.0 + (self.window.1 - self.window.0) * f.clamp(0.0, 1.0)
    }

    pub fn cancel_flag(&self) -> Arc<AtomicBool> {
        self.cancel.clone()
    }

    pub fn progress(&self) -> Arc<Progress> {
        self.progress.clone()
    }

    pub fn is_cancelled(&self) -> bool {
        self.cancel.load(Ordering::Relaxed)
    }

    /// `Err(Cancelled)` once cancellation was requested. Solvers call this at
    /// least every 100 ms of work.
    pub fn checkpoint(&self) -> Result<(), SolveError> {
        if self.is_cancelled() {
            Err(SolveError::Cancelled)
        } else {
            Ok(())
        }
    }

    /// Enters stage `s`, which covers `span` (start, end) of the overall progress.
    pub fn stage(&self, s: Stage, span: (f64, f64)) {
        let (lo, hi) = (self.map(span.0), self.map(span.1));
        self.progress.set_stage(s);
        self.progress.span_lo.store(lo.to_bits(), Ordering::Relaxed);
        self.progress.span_hi.store(hi.to_bits(), Ordering::Relaxed);
        self.progress.raise_fraction(lo);
    }

    /// Progress within the current stage, 0..1.
    pub fn report(&self, within: f64) {
        let lo = f64::from_bits(self.progress.span_lo.load(Ordering::Relaxed));
        let hi = f64::from_bits(self.progress.span_hi.load(Ordering::Relaxed));
        self.progress.raise_fraction(lo + (hi - lo) * within.clamp(0.0, 1.0));
    }

    pub fn set_unknowns(&self, n: u64) {
        self.progress.unknowns.store(n, Ordering::Relaxed);
    }
}
