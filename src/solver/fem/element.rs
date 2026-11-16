//! Lagrange P_p reference triangle (p = 1, 2, 3) with equispaced nodes.
//!
//! The reference triangle is {(ξ, η): ξ, η ≥ 0, ξ + η ≤ 1} with vertices
//! v0 = (0, 0), v1 = (1, 0), v2 = (0, 1). Local node order:
//! - the three vertices;
//! - p − 1 nodes on each edge e0 = (v0, v1), e1 = (v1, v2), e2 = (v2, v0), at
//!   fractions 1/p, …, (p−1)/p from the edge's first vertex;
//! - the (p−1)(p−2)/2 interior (face) nodes.
//!
//! The basis is built from the inverse Vandermonde matrix of the monomials
//! ξ^a η^b (a + b ≤ p) at the nodes; gradients come from the same coefficients.

#![allow(clippy::needless_range_loop)]

/// Largest number of nodes per element (P3).
pub const MAX_NODES: usize = 10;

/// Local edges as pairs of local vertex indices.
pub const EDGES: [[usize; 2]; 3] = [[0, 1], [1, 2], [2, 0]];

#[derive(Clone, Debug)]
pub struct RefElement {
    pub order: usize,
    /// Number of nodes, (p + 1)(p + 2)/2.
    pub n: usize,
    pub nodes: Vec<[f64; 2]>,
    /// Monomial exponents (a, b).
    monos: Vec<(i32, i32)>,
    /// coef[k][m]: φ_k = Σ_m coef[k][m] ξ^a_m η^b_m.
    coef: Vec<Vec<f64>>,
}

/// Values and reference gradients of every basis function at one point.
#[derive(Clone, Copy, Debug)]
pub struct BasisAt {
    pub phi: [f64; MAX_NODES],
    pub dphi: [[f64; 2]; MAX_NODES],
}

impl RefElement {
    pub fn new(order: usize) -> RefElement {
        assert!((1..=3).contains(&order), "element order must be 1, 2 or 3");
        let p = order;
        let pf = p as f64;
        let mut nodes: Vec<[f64; 2]> = vec![[0.0, 0.0], [1.0, 0.0], [0.0, 1.0]];
        for e in EDGES {
            let a = nodes[e[0]];
            let b = nodes[e[1]];
            for i in 1..p {
                let t = i as f64 / pf;
                nodes.push([a[0] + t * (b[0] - a[0]), a[1] + t * (b[1] - a[1])]);
            }
        }
        for j in 1..p {
            for i in 1..p {
                if i + j < p {
                    nodes.push([i as f64 / pf, j as f64 / pf]);
                }
            }
        }
        let n = nodes.len();
        debug_assert_eq!(n, (p + 1) * (p + 2) / 2);
        let mut monos = Vec::with_capacity(n);
        for deg in 0..=p as i32 {
            for b in 0..=deg {
                monos.push((deg - b, b));
            }
        }
        // Vandermonde V[i][m] = mono_m(node_i). φ_k(node_i) = δ_ik means
        // Σ_m coef[k][m] V[i][m] = δ_ik, i.e. coef = (V⁻¹)ᵀ.
        let mut v = vec![vec![0.0; n]; n];
        for (i, nd) in nodes.iter().enumerate() {
            for (m, &(a, b)) in monos.iter().enumerate() {
                v[i][m] = nd[0].powi(a) * nd[1].powi(b);
            }
        }
        let inv = invert(v);
        let coef = (0..n).map(|k| (0..n).map(|m| inv[m][k]).collect()).collect();
        RefElement { order, n, nodes, monos, coef }
    }

    /// Number of nodes per edge excluding the vertices.
    pub fn edge_nodes(&self) -> usize {
        self.order - 1
    }

    /// Number of interior nodes.
    pub fn face_nodes(&self) -> usize {
        (self.order - 1) * (self.order.saturating_sub(2)) / 2
    }

    pub fn eval(&self, xi: [f64; 2]) -> BasisAt {
        let p = self.order as i32;
        // Powers of ξ and η up to p.
        let mut px = [1.0; 4];
        let mut py = [1.0; 4];
        for k in 1..=p as usize {
            px[k] = px[k - 1] * xi[0];
            py[k] = py[k - 1] * xi[1];
        }
        let mut mono = [0.0; MAX_NODES];
        let mut dmx = [0.0; MAX_NODES];
        let mut dmy = [0.0; MAX_NODES];
        for (m, &(a, b)) in self.monos.iter().enumerate() {
            let (a, b) = (a as usize, b as usize);
            mono[m] = px[a] * py[b];
            dmx[m] = if a > 0 { a as f64 * px[a - 1] * py[b] } else { 0.0 };
            dmy[m] = if b > 0 { b as f64 * px[a] * py[b - 1] } else { 0.0 };
        }
        let mut out = BasisAt { phi: [0.0; MAX_NODES], dphi: [[0.0; 2]; MAX_NODES] };
        for k in 0..self.n {
            let c = &self.coef[k];
            let (mut f, mut gx, mut gy) = (0.0, 0.0, 0.0);
            for m in 0..self.n {
                f += c[m] * mono[m];
                gx += c[m] * dmx[m];
                gy += c[m] * dmy[m];
            }
            out.phi[k] = f;
            out.dphi[k] = [gx, gy];
        }
        out
    }
}

/// Inverse of a small dense matrix by Gauss–Jordan elimination with partial pivoting.
fn invert(mut a: Vec<Vec<f64>>) -> Vec<Vec<f64>> {
    let n = a.len();
    let mut inv: Vec<Vec<f64>> = (0..n).map(|i| (0..n).map(|j| if i == j { 1.0 } else { 0.0 }).collect()).collect();
    for col in 0..n {
        let piv = (col..n).max_by(|&i, &j| a[i][col].abs().partial_cmp(&a[j][col].abs()).unwrap()).unwrap();
        a.swap(col, piv);
        inv.swap(col, piv);
        let d = a[col][col];
        assert!(d.abs() > 1e-14, "singular Vandermonde matrix");
        for j in 0..n {
            a[col][j] /= d;
            inv[col][j] /= d;
        }
        for i in 0..n {
            if i != col {
                let f = a[i][col];
                if f != 0.0 {
                    for j in 0..n {
                        a[i][j] -= f * a[col][j];
                        inv[i][j] -= f * inv[col][j];
                    }
                }
            }
        }
    }
    inv
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nodal_and_partition_of_unity() {
        for p in 1..=3 {
            let e = RefElement::new(p);
            for (i, nd) in e.nodes.iter().enumerate() {
                let b = e.eval(*nd);
                for k in 0..e.n {
                    let want = if i == k { 1.0 } else { 0.0 };
                    assert!((b.phi[k] - want).abs() < 1e-12);
                }
            }
            let b = e.eval([0.23, 0.41]);
            let s: f64 = b.phi[..e.n].iter().sum();
            let gx: f64 = b.dphi[..e.n].iter().map(|g| g[0]).sum();
            let gy: f64 = b.dphi[..e.n].iter().map(|g| g[1]).sum();
            assert!((s - 1.0).abs() < 1e-12 && gx.abs() < 1e-11 && gy.abs() < 1e-11);
            // Reproduces x exactly: Σ x_k φ_k = ξ and Σ x_k ∂φ_k = (1, 0).
            let x: f64 = (0..e.n).map(|k| e.nodes[k][0] * b.phi[k]).sum();
            let dx: f64 = (0..e.n).map(|k| e.nodes[k][0] * b.dphi[k][0]).sum();
            assert!((x - 0.23).abs() < 1e-12 && (dx - 1.0).abs() < 1e-11);
        }
    }
}
