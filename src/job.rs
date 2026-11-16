//! A solve running on its own thread, observed by polling.

use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{Arc, Mutex, OnceLock};

use crate::scene::Scene;
use crate::solver::context::{STATE_CANCELLED, STATE_DONE, STATE_FAILED};
use crate::solver::{solve, FieldGrid, ProgressSnapshot, Quality, SolveContext, SolveError};

/// One pool for all solves, leaving a core for the UI and for rendering (which
/// uses rayon's global pool).
pub fn solve_pool() -> &'static rayon::ThreadPool {
    static POOL: OnceLock<rayon::ThreadPool> = OnceLock::new();
    POOL.get_or_init(|| {
        let n = std::thread::available_parallelism().map_or(1, |n| n.get());
        rayon::ThreadPoolBuilder::new()
            .num_threads(n.saturating_sub(1).max(1))
            .thread_name(|i| format!("fringe-solve-{i}"))
            .build()
            .expect("solver thread pool")
    })
}

struct JobShared {
    ctx: SolveContext,
    result: Mutex<Option<Result<Arc<FieldGrid>, SolveError>>>,
}

pub struct Job {
    shared: Arc<JobShared>,
}

impl Job {
    /// Starts solving on a background thread and returns immediately.
    pub fn spawn(scene: Scene, quality: Quality) -> Job {
        let shared = Arc::new(JobShared { ctx: SolveContext::new(), result: Mutex::new(None) });
        let worker = shared.clone();
        std::thread::Builder::new()
            .name("fringe-job".into())
            .spawn(move || {
                let ctx = worker.ctx.clone();
                let outcome = solve_pool().install(|| {
                    catch_unwind(AssertUnwindSafe(|| solve(&scene, quality, &ctx))).unwrap_or_else(|p| {
                        let msg = p
                            .downcast_ref::<&str>()
                            .map(|s| s.to_string())
                            .or_else(|| p.downcast_ref::<String>().cloned())
                            .unwrap_or_else(|| "unknown".into());
                        Err(SolveError::Internal(format!("panic: {msg}")))
                    })
                });
                let state = match &outcome {
                    Ok(_) => STATE_DONE,
                    Err(SolveError::Cancelled) => STATE_CANCELLED,
                    Err(_) => STATE_FAILED,
                };
                *worker.result.lock().unwrap_or_else(|e| e.into_inner()) = Some(outcome.map(Arc::new));
                // Publish the state last, so a poller that sees DONE can take the result.
                worker.ctx.progress().set_state(state);
            })
            .expect("spawn solve thread");
        Job { shared }
    }

    pub fn poll(&self) -> ProgressSnapshot {
        self.shared.ctx.progress().snapshot()
    }

    pub fn cancel(&self) {
        self.shared.ctx.cancel_flag().store(true, std::sync::atomic::Ordering::Relaxed);
    }

    /// The outcome once the job has finished; `None` while it runs or after the
    /// result was taken.
    pub fn take_result(&self) -> Option<Result<Arc<FieldGrid>, SolveError>> {
        if self.poll().state == crate::solver::context::STATE_RUNNING {
            return None;
        }
        self.shared.result.lock().unwrap_or_else(|e| e.into_inner()).take()
    }

    /// Blocks until the job finishes, polling every `interval`.
    pub fn wait(&self, interval: std::time::Duration) -> Result<Arc<FieldGrid>, SolveError> {
        loop {
            if let Some(r) = self.take_result() {
                return r;
            }
            std::thread::sleep(interval);
        }
    }
}

impl Drop for Job {
    /// Dropping a running job cancels it; the worker finishes on its own.
    fn drop(&mut self) {
        self.cancel();
    }
}
