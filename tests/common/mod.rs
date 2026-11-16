//! Helpers shared by the integration tests.
#![allow(dead_code)]

use beam_core::analytic::cases::{self, CaseResult, Status};
use beam_core::solver::{Method, Quality};
use beam_core::types::{Rect, Vec2};

/// Deterministic xorshift generator.
pub struct Rng(pub u64);

impl Rng {
    /// Uniform in [0, 1).
    pub fn next(&mut self) -> f64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        (self.0 >> 11) as f64 / (1u64 << 53) as f64
    }

    pub fn range(&mut self, lo: f64, hi: f64) -> f64 {
        lo + (hi - lo) * self.next()
    }

    pub fn point_in(&mut self, r: Rect) -> Vec2 {
        Vec2::new(self.range(r.x_min, r.x_max), self.range(r.y_min, r.y_max))
    }
}

pub fn fixture(name: &str) -> String {
    let path = format!("{}/tests/fixtures/{name}", env!("CARGO_MANIFEST_DIR"));
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{path}: {e}"))
}

/// Runs a validation case and asserts it passes; a stub solver passes vacuously.
pub fn assert_case(id: &str, method: Method, quality: Quality) -> CaseResult {
    let r = cases::run_case(id, method, quality).unwrap_or_else(|e| panic!("{id}: {e}"));
    eprintln!(
        "{id} {}: error {:?}, tolerance {:?}, {} unknowns, {:.2} s, {:?} {}",
        method.label(),
        r.error,
        r.tolerance,
        r.unknowns,
        r.seconds,
        r.status,
        r.detail
    );
    assert!(r.status != Status::Fail, "{id} with {} failed: {:?}", method.label(), r);
    r
}
