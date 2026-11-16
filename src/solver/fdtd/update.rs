//! The leapfrog time step: H sweep, then E sweep with the CPML ψ terms, the
//! scattered-field source, PEC nodes and the running DFTs fused into the E
//! sweep. Rows are split into chunks processed in parallel; every chunk writes
//! only its own rows, so the shared buffers are accessed through raw row
//! pointers.

use rayon::prelude::*;

use super::cpml::{strip_node, Profile};
use super::grid::Layout;

/// A dielectric node with ε ≠ ε_b,u: after the E update,
/// `Ez −= u1·Δa + u2·Σa − v1·Δb − v2·Σb`, which is `Cb·J` with
/// `J = (ε′ − ε_b,u)(E_inc^{n+1} − E_inc^n)/Δt + σ(E_inc^{n+1} + E_inc^n)/2` and
/// `E_inc^n = a_n Re Ê − b_n Im Ê`.
#[derive(Clone, Copy, Debug)]
pub struct SrcNode {
    pub idx: u32,
    pub u1: f32,
    pub u2: f32,
    pub v1: f32,
    pub v2: f32,
}

/// A PEC node: `E_s^{n+1} = −E_inc^{n+1} = −(a Re Ê − b Im Ê)`.
#[derive(Clone, Copy, Debug)]
pub struct PecNode {
    pub idx: u32,
    pub re: f32,
    pub im: f32,
}

/// Source and DFT phases of one step (producing E^{n+1}).
#[derive(Clone, Copy, Debug, Default)]
pub struct StepPhase {
    /// a_{n+1} − a_n, a_{n+1} + a_n, b_{n+1} − b_n, b_{n+1} + b_n.
    pub da: f32,
    pub sa: f32,
    pub db: f32,
    pub sb: f32,
    /// a_{n+1}, b_{n+1} for PEC nodes.
    pub a1: f32,
    pub b1: f32,
    /// e^{−jωt_{n+1}} for the probe DFT, if accumulating.
    pub probe: Option<(f64, f64)>,
    /// e^{−jωt_{n+1}} for the full interior DFT, if accumulating.
    pub full: Option<(f64, f64)>,
}

const CHUNKS_PER_THREAD: usize = 8;

/// Probe spacing in interior nodes.
pub const PROBE_STRIDE: usize = 8;

pub struct Engine {
    pub l: Layout,
    pub ez: Vec<f32>,
    hx: Vec<f32>,
    hy: Vec<f32>,
    ca: Vec<f32>,
    /// Cb / Δ.
    cbd: Vec<f32>,
    psi_hyx: Vec<f32>,
    psi_ex: Vec<f32>,
    psi_hxy: Vec<f32>,
    psi_ey: Vec<f32>,
    px_e: Profile,
    px_h: Profile,
    py_e: Profile,
    py_h: Profile,
    dtdx: f32,
    dt: f32,
    /// Background Cb (= Δt/ε_b,u), used for the ψ terms in the PML.
    cb_bg: f32,
    src: Vec<SrcNode>,
    src_row: Vec<usize>,
    pec: Vec<PecNode>,
    pec_row: Vec<usize>,
    /// Probe accumulators, `probe_rows × probe_cols`.
    pub probe_re: Vec<f64>,
    pub probe_im: Vec<f64>,
    pub probe_cols: usize,
    pub probe_rows: usize,
    /// Interior DFT accumulators (allocated when the final DFT starts).
    pub acc_re: Vec<f64>,
    pub acc_im: Vec<f64>,
    chunks: Vec<(usize, usize)>,
}

#[derive(Clone, Copy)]
struct Ptr<T>(*mut T);
unsafe impl<T> Send for Ptr<T> {}
unsafe impl<T> Sync for Ptr<T> {}

impl<T> Ptr<T> {
    fn new(v: &mut [T]) -> Self {
        Ptr(v.as_mut_ptr())
    }
    /// # Safety
    /// `start..start + len` must be in bounds and not accessed mutably elsewhere
    /// while the slice lives.
    #[inline]
    #[allow(clippy::mut_from_ref)]
    unsafe fn slice(&self, start: usize, len: usize) -> &mut [T] {
        std::slice::from_raw_parts_mut(self.0.add(start), len)
    }
}

/// Offsets into `items` (sorted by idx) per grid row.
fn row_offsets(idx: impl Iterator<Item = usize>, nx: usize, ny: usize) -> Vec<usize> {
    let mut counts = vec![0usize; ny + 1];
    for i in idx {
        counts[i / nx + 1] += 1;
    }
    for j in 0..ny {
        counts[j + 1] += counts[j];
    }
    counts
}

/// Strip index of node `i` along an axis of `n` nodes, if it is in a strip.
#[inline]
fn strip_index(i: usize, np: usize, n: usize) -> Option<usize> {
    if i < np {
        Some(i)
    } else if i >= n - 1 - np {
        Some(np + i - (n - 1 - np))
    } else {
        None
    }
}

pub struct EngineInit {
    pub ca: Vec<f32>,
    pub cbd: Vec<f32>,
    pub cb_bg: f32,
    pub src: Vec<SrcNode>,
    pub pec: Vec<PecNode>,
    pub px: (Profile, Profile),
    pub py: (Profile, Profile),
}

impl Engine {
    pub fn new(l: Layout, init: EngineInit) -> Engine {
        let (nx, ny, np) = (l.nx, l.ny, l.np);
        let n = nx * ny;
        let src_row = row_offsets(init.src.iter().map(|s| s.idx as usize), nx, ny);
        let pec_row = row_offsets(init.pec.iter().map(|s| s.idx as usize), nx, ny);
        let probe_cols = (l.nxi - 1) / PROBE_STRIDE + 1;
        let probe_rows = (l.nyi - 1) / PROBE_STRIDE + 1;
        let threads = rayon::current_num_threads().max(1);
        // Several chunks per thread, so work stealing evens out slower (efficiency)
        // cores and preempted threads.
        let target = (threads * CHUNKS_PER_THREAD).min(ny);
        let per = ny.div_ceil(target.max(1));
        let chunks = (0..ny).step_by(per.max(1)).map(|s| (s, (s + per).min(ny))).collect();
        Engine {
            l,
            ez: vec![0.0; n],
            hx: vec![0.0; n],
            hy: vec![0.0; n],
            ca: init.ca,
            cbd: init.cbd,
            psi_hyx: vec![0.0; ny * 2 * np],
            psi_ex: vec![0.0; ny * 2 * np],
            psi_hxy: vec![0.0; 2 * np * nx],
            psi_ey: vec![0.0; 2 * np * nx],
            px_e: init.px.0,
            px_h: init.px.1,
            py_e: init.py.0,
            py_h: init.py.1,
            dtdx: (l.dt / l.dx) as f32,
            dt: l.dt as f32,
            cb_bg: init.cb_bg,
            src: init.src,
            src_row,
            pec: init.pec,
            pec_row,
            probe_re: vec![0.0; probe_rows * probe_cols],
            probe_im: vec![0.0; probe_rows * probe_cols],
            probe_cols,
            probe_rows,
            acc_re: Vec::new(),
            acc_im: Vec::new(),
            chunks,
        }
    }

    pub fn start_full_dft(&mut self) {
        self.acc_re = vec![0.0; self.l.interior_cells()];
        self.acc_im = vec![0.0; self.l.interior_cells()];
    }

    pub fn reset_probes(&mut self) {
        self.probe_re.iter_mut().for_each(|v| *v = 0.0);
        self.probe_im.iter_mut().for_each(|v| *v = 0.0);
    }

    /// One leapfrog step: H^{n+½} from E^n, then E^{n+1}.
    pub fn step(&mut self, ph: &StepPhase) {
        self.sweep_h();
        self.sweep_e(ph);
    }

    fn sweep_h(&mut self) {
        let (nx, ny, np) = (self.l.nx, self.l.ny, self.l.np);
        let ez = &self.ez;
        let hx = Ptr::new(&mut self.hx);
        let hy = Ptr::new(&mut self.hy);
        let psi_hyx = Ptr::new(&mut self.psi_hyx);
        let psi_hxy = Ptr::new(&mut self.psi_hxy);
        let (px, py) = (&self.px_h, &self.py_h);
        let (dtdx, dt) = (self.dtdx, self.dt);
        self.chunks.par_iter().for_each(|&(j0, j1)| {
            for j in j0..j1 {
                let ez0 = &ez[j * nx..(j + 1) * nx];
                // SAFETY: each chunk owns rows j0..j1 of hx, hy and their ψ rows.
                let hy_r = unsafe { hy.slice(j * nx, nx) };
                {
                    let m = nx - 1;
                    let (h, e1, e0) = (&mut hy_r[..m], &ez0[1..], &ez0[..m]);
                    for i in 0..m {
                        h[i] += dtdx * (e1[i] - e0[i]);
                    }
                }
                if np > 0 {
                    let ps = unsafe { psi_hyx.slice(j * 2 * np, 2 * np) };
                    for (k, (p, (&b, &a))) in ps.iter_mut().zip(px.b.iter().zip(&px.a)).enumerate() {
                        let i = strip_node(k, np, nx);
                        *p = b * *p + a * (ez0[i + 1] - ez0[i]);
                        hy_r[i] += dt * *p;
                    }
                }
                if j + 1 < ny {
                    let ez1 = &ez[(j + 1) * nx..(j + 2) * nx];
                    let hx_r = unsafe { hx.slice(j * nx, nx) };
                    for i in 0..nx {
                        hx_r[i] -= dtdx * (ez1[i] - ez0[i]);
                    }
                    if let Some(k) = strip_index(j, np, ny) {
                        let ps = unsafe { psi_hxy.slice(k * nx, nx) };
                        let (b, a) = (py.b[k], py.a[k]);
                        for i in 0..nx {
                            ps[i] = b * ps[i] + a * (ez1[i] - ez0[i]);
                            hx_r[i] -= dt * ps[i];
                        }
                    }
                }
            }
        });
    }

    fn sweep_e(&mut self, ph: &StepPhase) {
        let l = self.l;
        let (nx, ny, np) = (l.nx, l.ny, l.np);
        let (hx, hy, ca, cbd) = (&self.hx, &self.hy, &self.ca, &self.cbd);
        let ez = Ptr::new(&mut self.ez);
        let psi_ex = Ptr::new(&mut self.psi_ex);
        let psi_ey = Ptr::new(&mut self.psi_ey);
        let (px, py) = (&self.px_e, &self.py_e);
        let cb_bg = self.cb_bg;
        let (src, src_row, pec, pec_row) = (&self.src, &self.src_row, &self.pec, &self.pec_row);
        let acc_re = Ptr::new(&mut self.acc_re);
        let acc_im = Ptr::new(&mut self.acc_im);
        let pr_re = Ptr::new(&mut self.probe_re);
        let pr_im = Ptr::new(&mut self.probe_im);
        let pcols = self.probe_cols;
        let ph = *ph;
        self.chunks.par_iter().for_each(|&(j0, j1)| {
            for j in j0.max(1)..j1.min(ny - 1) {
                // SAFETY: each chunk owns rows j0..j1 of ez, its ψ rows and the
                // accumulator rows of those grid rows.
                let ez_r = unsafe { ez.slice(j * nx, nx) };
                let hy_r = &hy[j * nx..(j + 1) * nx];
                let hx_r = &hx[j * nx..(j + 1) * nx];
                let hx_m = &hx[(j - 1) * nx..j * nx];
                {
                    let m = nx - 2;
                    let e = &mut ez_r[1..1 + m];
                    let c1 = &ca[j * nx + 1..j * nx + 1 + m];
                    let c2 = &cbd[j * nx + 1..j * nx + 1 + m];
                    let y1 = &hy_r[1..1 + m];
                    let y0 = &hy_r[..m];
                    let x1 = &hx_r[1..1 + m];
                    let x0 = &hx_m[1..1 + m];
                    for i in 0..m {
                        let curl = (y1[i] - y0[i]) - (x1[i] - x0[i]);
                        e[i] = c1[i] * e[i] + c2[i] * curl;
                    }
                }
                if np > 0 {
                    let ps = unsafe { psi_ex.slice(j * 2 * np, 2 * np) };
                    // Strip index 0 is the PEC ring (never updated).
                    for (k, (p, (&b, &a))) in ps.iter_mut().zip(px.b.iter().zip(&px.a)).enumerate().skip(1) {
                        let i = strip_node(k, np, nx);
                        *p = b * *p + a * (hy_r[i] - hy_r[i - 1]);
                        ez_r[i] += cb_bg * *p;
                    }
                    if let Some(k) = strip_index(j, np, ny) {
                        let ps = unsafe { psi_ey.slice(k * nx, nx) };
                        let (b, a) = (py.b[k], py.a[k]);
                        for i in 1..nx - 1 {
                            ps[i] = b * ps[i] + a * (hx_r[i] - hx_m[i]);
                            ez_r[i] -= cb_bg * ps[i];
                        }
                    }
                }
                let base = j * nx;
                for s in &src[src_row[j]..src_row[j + 1]] {
                    ez_r[s.idx as usize - base] -= s.u1 * ph.da + s.u2 * ph.sa - s.v1 * ph.db - s.v2 * ph.sb;
                }
                for p in &pec[pec_row[j]..pec_row[j + 1]] {
                    ez_r[p.idx as usize - base] = -(ph.a1 * p.re - ph.b1 * p.im);
                }
                if j < np || j >= np + l.nyi {
                    continue;
                }
                let ji = j - np;
                let row = &ez_r[np..np + l.nxi];
                if let Some((c, s)) = ph.full {
                    let are = unsafe { acc_re.slice(ji * l.nxi, l.nxi) };
                    let aim = unsafe { acc_im.slice(ji * l.nxi, l.nxi) };
                    for i in 0..l.nxi {
                        let v = row[i] as f64;
                        are[i] += v * c;
                        aim[i] += v * s;
                    }
                }
                if let Some((c, s)) = ph.probe {
                    if ji % PROBE_STRIDE == 0 {
                        let r = ji / PROBE_STRIDE;
                        let pre = unsafe { pr_re.slice(r * pcols, pcols) };
                        let pim = unsafe { pr_im.slice(r * pcols, pcols) };
                        for (q, i) in (0..l.nxi).step_by(PROBE_STRIDE).enumerate() {
                            let v = row[i] as f64;
                            pre[q] += v * c;
                            pim[q] += v * s;
                        }
                    }
                }
            }
        });
    }
}
