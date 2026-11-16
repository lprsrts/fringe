//! Gauss–Legendre rules on [−1, 1] and collapsed product rules on the reference
//! triangle.

use std::f64::consts::PI;
use std::sync::{Arc, OnceLock};

#[derive(Clone, Debug)]
pub struct GaussLegendre {
    pub nodes: Vec<f64>,
    pub weights: Vec<f64>,
}

impl GaussLegendre {
    /// Nodes and weights mapped to [a, b].
    pub fn on(&self, a: f64, b: f64) -> impl Iterator<Item = (f64, f64)> + '_ {
        let (m, h) = (0.5 * (a + b), 0.5 * (b - a));
        self.nodes.iter().zip(&self.weights).map(move |(&x, &w)| (m + h * x, h * w))
    }
}

const CACHED: usize = 64;

/// The n-point rule, exact for polynomials of degree 2n − 1. Rules up to 64
/// points are computed once and shared.
pub fn gauss_legendre(n: usize) -> Arc<GaussLegendre> {
    static CACHE: OnceLock<Vec<OnceLock<Arc<GaussLegendre>>>> = OnceLock::new();
    if n == 0 || n > CACHED {
        return Arc::new(compute_gl(n));
    }
    let cache = CACHE.get_or_init(|| (0..=CACHED).map(|_| OnceLock::new()).collect());
    cache[n].get_or_init(|| Arc::new(compute_gl(n))).clone()
}

/// Newton's method on P_n from Tricomi's initial guesses; the three-term
/// recurrence gives P_n and P_n′. Symmetric nodes are mirrored.
fn compute_gl(n: usize) -> GaussLegendre {
    let mut nodes = vec![0.0; n];
    let mut weights = vec![0.0; n];
    let nf = n as f64;
    for i in 0..n.div_ceil(2) {
        let theta = PI * (i as f64 + 0.75) / (nf + 0.5);
        let mut x = (1.0 - (nf - 1.0) / (8.0 * nf * nf * nf)) * theta.cos();
        let mut dp = 1.0;
        for _ in 0..100 {
            let (p, d) = legendre(n, x);
            dp = d;
            let dx = p / d;
            x -= dx;
            if dx.abs() < 1e-16 {
                break;
            }
        }
        let (_, d) = legendre(n, x);
        if d.is_finite() {
            dp = d;
        }
        let w = 2.0 / ((1.0 - x * x) * dp * dp);
        nodes[i] = -x;
        nodes[n - 1 - i] = x;
        weights[i] = w;
        weights[n - 1 - i] = w;
    }
    if n % 2 == 1 {
        nodes[n / 2] = 0.0;
    }
    GaussLegendre { nodes, weights }
}

/// P_n(x) and P_n′(x).
fn legendre(n: usize, x: f64) -> (f64, f64) {
    let mut p0 = 1.0;
    let mut p1 = x;
    if n == 0 {
        return (1.0, 0.0);
    }
    for k in 2..=n {
        let kf = k as f64;
        let p2 = ((2.0 * kf - 1.0) * x * p1 - (kf - 1.0) * p0) / kf;
        p0 = p1;
        p1 = p2;
    }
    let d = n as f64 * (x * p1 - p0) / (x * x - 1.0);
    (p1, d)
}

/// Quadrature on the reference triangle {(ξ, η): ξ, η ≥ 0, ξ + η ≤ 1} (area ½).
#[derive(Clone, Debug)]
pub struct TriangleRule {
    pub points: Vec<[f64; 2]>,
    pub weights: Vec<f64>,
}

/// Collapsed Gauss–Legendre product rule exact for total degree ≤ `degree`:
/// n = ⌈(degree + 2)/2⌉ points per direction, (u, v) ∈ [0, 1]² mapped to
/// (u, v(1 − u)) with weight w_u w_v (1 − u).
pub fn triangle_rule(degree: usize) -> Arc<TriangleRule> {
    static CACHE: OnceLock<Vec<OnceLock<Arc<TriangleRule>>>> = OnceLock::new();
    const MAX: usize = 30;
    if degree > MAX {
        return Arc::new(compute_triangle(degree));
    }
    let cache = CACHE.get_or_init(|| (0..=MAX).map(|_| OnceLock::new()).collect());
    cache[degree].get_or_init(|| Arc::new(compute_triangle(degree))).clone()
}

fn compute_triangle(degree: usize) -> TriangleRule {
    let n = (degree + 2).div_ceil(2);
    let gl = gauss_legendre(n);
    let mut points = Vec::with_capacity(n * n);
    let mut weights = Vec::with_capacity(n * n);
    for (u, wu) in gl.on(0.0, 1.0) {
        for (v, wv) in gl.on(0.0, 1.0) {
            points.push([u, v * (1.0 - u)]);
            weights.push(wu * wv * (1.0 - u));
        }
    }
    TriangleRule { points, weights }
}
