//! `Instant` that works on wasm32-unknown-unknown, where `std::time::Instant::now`
//! panics; there it reads `performance.now()` through `web-time`.

#[cfg(not(target_arch = "wasm32"))]
pub use std::time::Instant;
#[cfg(target_arch = "wasm32")]
pub use web_time::Instant;
