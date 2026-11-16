//! Linear algebra used by the solvers: complex sparse LU (FEM), dense LU (MoM)
//! and complex GEMM (incident fields). This is the only module that touches faer.
//!
//! Pinned to faer 0.24.4. The calls used, so the next upgrade knows where to look:
//! - `faer::sparse::{SymbolicSparseColMatRef::new_checked, SparseColMatRef::new}` to
//!   wrap a CSC matrix built here (row indices sorted, duplicates already summed);
//! - `faer::sparse::linalg::solvers::{SymbolicLu::try_new, Lu::try_new_with_symbolic}`
//!   (COLAMD column ordering, supernodal or simplicial chosen by faer) and the
//!   `faer::linalg::solvers::Solve` trait for `solve_in_place`;
//! - `faer::linalg::lu::partial_pivoting::{factor::lu_in_place, solve::*}` for dense
//!   LU in place, so a dense system is stored once;
//! - `faer::linalg::matmul::matmul` with `faer::get_global_parallelism()`.
//!
//! faer's `c64` is `num_complex::Complex<f64>`, the same type as [`C64`], so no
//! conversion is needed. faer parallelises over the rayon pool it is called from,
//! which inside a solve is the job's dedicated pool.

use faer::dyn_stack::{MemBuffer, MemStack};
use faer::linalg::lu::partial_pivoting;
use faer::linalg::solvers::Solve;
use faer::perm::PermRef;
use faer::sparse::linalg::solvers::{Lu, SymbolicLu};
use faer::sparse::{SparseColMatRef, SymbolicSparseColMatRef};
use faer::{Accum, MatMut, MatRef};
use rayon::prelude::*;

pub use num_complex::Complex64 as C64;

#[derive(Clone, Debug, PartialEq)]
pub enum LinalgError {
    /// The matrix is structurally or numerically singular.
    Singular(String),
    OutOfMemory,
    Other(String),
}

impl std::fmt::Display for LinalgError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LinalgError::Singular(m) => write!(f, "singular matrix: {m}"),
            LinalgError::OutOfMemory => write!(f, "out of memory in the factorisation"),
            LinalgError::Other(m) => write!(f, "{m}"),
        }
    }
}

impl std::error::Error for LinalgError {}

/// Square sparse matrix collected as (row, column, value) triplets. Duplicates are
/// summed when the matrix is factored.
#[derive(Clone, Debug, Default)]
pub struct SparseBuilder {
    n: usize,
    rows: Vec<u32>,
    cols: Vec<u32>,
    vals: Vec<C64>,
}

impl SparseBuilder {
    pub fn new(n: usize) -> Self {
        assert!(n < u32::MAX as usize, "sparse matrix too large");
        Self {
            n,
            ..Default::default()
        }
    }

    pub fn n(&self) -> usize {
        self.n
    }

    pub fn len(&self) -> usize {
        self.vals.len()
    }

    pub fn is_empty(&self) -> bool {
        self.vals.is_empty()
    }

    pub fn reserve(&mut self, nnz: usize) {
        self.rows.reserve(nnz);
        self.cols.reserve(nnz);
        self.vals.reserve(nnz);
    }

    #[inline]
    pub fn add(&mut self, i: usize, j: usize, v: C64) {
        debug_assert!(i < self.n && j < self.n);
        self.rows.push(i as u32);
        self.cols.push(j as u32);
        self.vals.push(v);
    }

    /// Appends the triplets of `other`, which must have the same size.
    pub fn extend(&mut self, other: SparseBuilder) {
        assert_eq!(self.n, other.n, "sparse builders of different size");
        if self.vals.is_empty() {
            *self = other;
            return;
        }
        self.rows.extend_from_slice(&other.rows);
        self.cols.extend_from_slice(&other.cols);
        self.vals.extend_from_slice(&other.vals);
    }

    /// Compressed sparse columns with sorted row indices and duplicates summed.
    fn into_csc(self) -> Csc {
        let n = self.n;
        let mut col_ptr = vec![0usize; n + 1];
        for &c in &self.cols {
            col_ptr[c as usize + 1] += 1;
        }
        for j in 0..n {
            col_ptr[j + 1] += col_ptr[j];
        }
        let total = self.vals.len();
        let mut row_idx = vec![0usize; total];
        let mut vals = vec![C64::new(0.0, 0.0); total];
        let mut next = col_ptr.clone();
        for k in 0..total {
            let c = self.cols[k] as usize;
            let dst = next[c];
            next[c] += 1;
            row_idx[dst] = self.rows[k] as usize;
            vals[dst] = self.vals[k];
        }
        drop(self);

        // Sort and merge each column in parallel. Columns are contiguous, so the
        // arrays can be split into disjoint per-column slices.
        let mut pieces: Vec<(&mut [usize], &mut [C64])> = Vec::with_capacity(n);
        let (mut r_rest, mut v_rest) = (&mut row_idx[..], &mut vals[..]);
        for j in 0..n {
            let len = col_ptr[j + 1] - col_ptr[j];
            let (r, rr) = r_rest.split_at_mut(len);
            let (v, vr) = v_rest.split_at_mut(len);
            pieces.push((r, v));
            r_rest = rr;
            v_rest = vr;
        }
        let kept: Vec<usize> = pieces
            .into_par_iter()
            .map(|(r, v)| {
                let mut order: Vec<usize> = (0..r.len()).collect();
                order.sort_unstable_by_key(|&k| r[k]);
                let rs: Vec<usize> = order.iter().map(|&k| r[k]).collect();
                let vs: Vec<C64> = order.iter().map(|&k| v[k]).collect();
                let mut m = 0usize;
                for k in 0..rs.len() {
                    if m > 0 && r[m - 1] == rs[k] {
                        v[m - 1] += vs[k];
                    } else {
                        r[m] = rs[k];
                        v[m] = vs[k];
                        m += 1;
                    }
                }
                m
            })
            .collect();

        // Compact the merged columns to the front.
        let mut new_ptr = vec![0usize; n + 1];
        let mut w = 0usize;
        for j in 0..n {
            let start = col_ptr[j];
            for k in 0..kept[j] {
                row_idx[w + k] = row_idx[start + k];
                vals[w + k] = vals[start + k];
            }
            w += kept[j];
            new_ptr[j + 1] = w;
        }
        row_idx.truncate(w);
        vals.truncate(w);
        row_idx.shrink_to_fit();
        vals.shrink_to_fit();
        Csc {
            n,
            col_ptr: new_ptr,
            row_idx,
            vals,
        }
    }
}

struct Csc {
    n: usize,
    col_ptr: Vec<usize>,
    row_idx: Vec<usize>,
    vals: Vec<C64>,
}

/// Sparse LU with partial pivoting and a COLAMD fill-reducing column ordering.
pub struct SparseLu {
    n: usize,
    nnz_matrix: usize,
    lu: Lu<usize, C64>,
}

impl SparseLu {
    pub fn factor(b: SparseBuilder) -> Result<SparseLu, LinalgError> {
        let csc = b.into_csc();
        let n = csc.n;
        let symbolic = SymbolicSparseColMatRef::new_checked(n, n, &csc.col_ptr, None, &csc.row_idx);
        let mat = SparseColMatRef::new(symbolic, &csc.vals);
        let sym = SymbolicLu::try_new(symbolic).map_err(faer_error)?;
        let lu = Lu::try_new_with_symbolic(sym, mat).map_err(|e| match e {
            faer::sparse::linalg::LuError::SymbolicSingular { index } => {
                LinalgError::Singular(format!("no pivot in column {index}"))
            }
            faer::sparse::linalg::LuError::Generic(e) => faer_error(e),
        })?;
        Ok(SparseLu {
            n,
            nnz_matrix: csc.vals.len(),
            lu,
        })
    }

    pub fn n(&self) -> usize {
        self.n
    }

    /// Stored entries of the assembled matrix after duplicates were summed.
    pub fn nnz_matrix(&self) -> usize {
        self.nnz_matrix
    }

    pub fn solve(&self, rhs: &[C64]) -> Vec<C64> {
        assert_eq!(rhs.len(), self.n);
        let mut x = rhs.to_vec();
        let col = MatMut::from_column_major_slice_mut(&mut x, self.n, 1);
        self.lu.solve_in_place(col);
        x
    }

    /// faer does not expose the factor fill through its high-level LU, so this is
    /// `None` for now; callers fall back to their own estimate.
    pub fn nnz_factors(&self) -> Option<usize> {
        None
    }
}

fn faer_error(e: faer::sparse::FaerError) -> LinalgError {
    match e {
        faer::sparse::FaerError::OutOfMemory => LinalgError::OutOfMemory,
        other => LinalgError::Other(format!("{other:?}")),
    }
}

/// Dense square matrix, column-major: entry (i, j) is `data[j * n + i]`.
#[derive(Clone, Debug)]
pub struct DenseMatrix {
    pub n: usize,
    pub data: Vec<C64>,
}

impl DenseMatrix {
    pub fn zeros(n: usize) -> Self {
        Self {
            n,
            data: vec![C64::new(0.0, 0.0); n * n],
        }
    }

    #[inline]
    pub fn get(&self, i: usize, j: usize) -> C64 {
        self.data[j * self.n + i]
    }

    #[inline]
    pub fn set(&mut self, i: usize, j: usize, v: C64) {
        self.data[j * self.n + i] = v;
    }

    pub fn matvec(&self, x: &[C64]) -> Vec<C64> {
        let mut y = vec![C64::new(0.0, 0.0); self.n];
        gemm(self.n, 1, self.n, &self.data, x, &mut y);
        y
    }

    /// Largest column sum of absolute values.
    pub fn norm1(&self) -> f64 {
        self.data
            .par_chunks(self.n.max(1))
            .map(|c| c.iter().map(|v| v.norm()).sum::<f64>())
            .reduce(|| 0.0, f64::max)
    }
}

/// Dense LU with partial (row) pivoting, factored in place.
pub struct DenseLu {
    n: usize,
    lu: Vec<C64>,
    perm: Vec<usize>,
    perm_inv: Vec<usize>,
}

impl DenseLu {
    /// A singular matrix does not fail here; the solves then return non-finite values.
    pub fn factor(a: DenseMatrix) -> DenseLu {
        let n = a.n;
        let mut lu = a.data;
        let mut perm = vec![0usize; n];
        let mut perm_inv = vec![0usize; n];
        let par = faer::get_global_parallelism();
        let mut mem = MemBuffer::new(partial_pivoting::factor::lu_in_place_scratch::<usize, C64>(
            n,
            n,
            par,
            Default::default(),
        ));
        partial_pivoting::factor::lu_in_place(
            MatMut::from_column_major_slice_mut(&mut lu, n, n),
            &mut perm,
            &mut perm_inv,
            par,
            MemStack::new(&mut mem),
            Default::default(),
        );
        DenseLu {
            n,
            lu,
            perm,
            perm_inv,
        }
    }

    pub fn n(&self) -> usize {
        self.n
    }

    fn perm(&self) -> PermRef<'_, usize> {
        PermRef::new_checked(&self.perm, &self.perm_inv, self.n)
    }

    pub fn solve(&self, rhs: &[C64]) -> Vec<C64> {
        assert_eq!(rhs.len(), self.n);
        let mut x = rhs.to_vec();
        let par = faer::get_global_parallelism();
        let f = MatRef::from_column_major_slice(&self.lu, self.n, self.n);
        let mut mem = MemBuffer::new(partial_pivoting::solve::solve_in_place_scratch::<usize, C64>(
            self.n, 1, par,
        ));
        partial_pivoting::solve::solve_in_place(
            f,
            f,
            self.perm(),
            MatMut::from_column_major_slice_mut(&mut x, self.n, 1),
            par,
            MemStack::new(&mut mem),
        );
        x
    }

    /// Solves `Aᵀ x = rhs` (transpose, not conjugate transpose).
    pub fn solve_transpose(&self, rhs: &[C64]) -> Vec<C64> {
        assert_eq!(rhs.len(), self.n);
        let mut x = rhs.to_vec();
        let par = faer::get_global_parallelism();
        let f = MatRef::from_column_major_slice(&self.lu, self.n, self.n);
        let mut mem = MemBuffer::new(
            partial_pivoting::solve::solve_transpose_in_place_scratch::<usize, C64>(self.n, 1, par),
        );
        partial_pivoting::solve::solve_transpose_in_place(
            f,
            f,
            self.perm(),
            MatMut::from_column_major_slice_mut(&mut x, self.n, 1),
            par,
            MemStack::new(&mut mem),
        );
        x
    }

    /// Estimate of the 1-norm condition number `‖A‖₁ ‖A⁻¹‖₁`, given `‖A‖₁`.
    ///
    /// Hager's method as refined by Higham (LAPACK's `zlacon`): at most five
    /// solves with A and five with Aᴴ, plus one extra solve with an alternating
    /// test vector. It is a lower bound on ‖A⁻¹‖₁ that is almost always within a
    /// factor of 3.
    pub fn cond1_estimate(&self, a_norm1: f64) -> f64 {
        let n = self.n;
        if n == 0 {
            return 0.0;
        }
        let norm1 = |v: &[C64]| v.iter().map(|z| z.norm()).sum::<f64>();
        let mut x = vec![C64::new(1.0 / n as f64, 0.0); n];
        let mut est = 0.0f64;
        let mut last_j = usize::MAX;
        for iter in 0..5 {
            let y = self.solve(&x);
            let y_norm = norm1(&y);
            if !y_norm.is_finite() {
                return f64::INFINITY;
            }
            if iter > 0 && y_norm <= est {
                break;
            }
            est = y_norm;
            let xi: Vec<C64> = y
                .iter()
                .map(|z| {
                    let a = z.norm();
                    if a > 0.0 {
                        z / a
                    } else {
                        C64::new(1.0, 0.0)
                    }
                })
                .collect();
            // z = A⁻ᴴ ξ = conj(A⁻ᵀ conj(ξ))
            let conj_xi: Vec<C64> = xi.iter().map(|v| v.conj()).collect();
            let z: Vec<C64> = self
                .solve_transpose(&conj_xi)
                .into_iter()
                .map(|v| v.conj())
                .collect();
            let (j, zmax) = z
                .iter()
                .enumerate()
                .map(|(i, v)| (i, v.norm()))
                .fold((0, -1.0), |a, b| if b.1 > a.1 { b } else { a });
            let ztx: f64 = z.iter().zip(&x).map(|(a, b)| (a.conj() * b).re).sum();
            if iter > 0 && (zmax <= ztx || j == last_j) {
                break;
            }
            last_j = j;
            x.iter_mut().for_each(|v| *v = C64::new(0.0, 0.0));
            x[j] = C64::new(1.0, 0.0);
        }
        // Higham's extra test vector catches matrices where the iteration stalls.
        let alt: Vec<C64> = (0..n)
            .map(|i| {
                let s = if i % 2 == 0 { 1.0 } else { -1.0 };
                C64::new(s * (1.0 + i as f64 / (n.max(2) - 1) as f64), 0.0)
            })
            .collect();
        let alt_est = 2.0 * norm1(&self.solve(&alt)) / (3.0 * n as f64);
        est.max(alt_est) * a_norm1
    }
}

/// `out = a · b` for column-major `a` (m × k), `b` (k × n) and `out` (m × n).
pub fn gemm(m: usize, n: usize, k: usize, a: &[C64], b: &[C64], out: &mut [C64]) {
    assert_eq!(a.len(), m * k);
    assert_eq!(b.len(), k * n);
    assert_eq!(out.len(), m * n);
    if m == 0 || n == 0 {
        return;
    }
    if k == 0 {
        out.iter_mut().for_each(|v| *v = C64::new(0.0, 0.0));
        return;
    }
    faer::linalg::matmul::matmul(
        MatMut::from_column_major_slice_mut(out, m, n),
        Accum::Replace,
        MatRef::from_column_major_slice(a, m, k),
        MatRef::from_column_major_slice(b, k, n),
        C64::new(1.0, 0.0),
        faer::get_global_parallelism(),
    );
}
