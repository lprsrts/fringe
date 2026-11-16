//! Incident fields: a plane wave, or a Gaussian beam built from propagating plane
//! waves (spec §4). Both solve the background Helmholtz equation exactly, so the
//! scattered-field solvers can use them everywhere in the plane.

pub mod gaussian;
pub mod yee;

use rayon::prelude::*;

use crate::linalg::gemm;
use crate::scene::{Scene, Source};
use crate::solver::field::GridSpec;
use crate::types::{cis, Rect, Vec2, C64, J};

/// One plane wave: `E += c · exp(−j k·(r − origin))`.
#[derive(Clone, Debug, PartialEq)]
pub struct PlaneComponent {
    pub k: [f64; 2],
    pub c: C64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum IncidentKind {
    PlaneWave,
    Gaussian,
}

#[derive(Clone, Debug)]
pub struct Incident {
    pub kind: IncidentKind,
    /// Waist centre (Gaussian) or the origin (plane wave).
    pub origin: Vec2,
    /// Propagation direction in radians.
    pub axis_angle: f64,
    pub amplitude: f64,
    pub k_b: f64,
    pub comps: Vec<PlaneComponent>,
    /// Accuracy warnings from the construction (never errors).
    pub warnings: Vec<String>,
}

impl Incident {
    /// The scene's source, accurate to about 1e−10·A on `accurate_in` (the PML
    /// outer rectangle).
    pub fn from_scene(scene: &Scene, accurate_in: Rect) -> Incident {
        let k_b = 2.0 * std::f64::consts::PI / scene.wavelength_um * scene.background.n;
        match scene.source {
            Source::PlaneWave { angle_deg, amplitude, phase_deg } => {
                Incident::plane_wave(k_b, angle_deg.to_radians(), amplitude, phase_deg.to_radians())
            }
            Source::GaussianBeam { waist_um, waist_x_um, waist_y_um, angle_deg, amplitude, phase_deg } => {
                Incident::gaussian(
                    k_b,
                    waist_um,
                    Vec2::new(waist_x_um, waist_y_um),
                    angle_deg.to_radians(),
                    amplitude,
                    phase_deg.to_radians(),
                    accurate_in,
                )
            }
        }
    }

    pub fn plane_wave(k_b: f64, angle: f64, amplitude: f64, phase: f64) -> Incident {
        let d = Vec2::from_angle(angle);
        Incident {
            kind: IncidentKind::PlaneWave,
            origin: Vec2::ZERO,
            axis_angle: angle,
            amplitude,
            k_b,
            comps: vec![PlaneComponent { k: [k_b * d.x, k_b * d.y], c: amplitude * cis(phase) }],
            warnings: Vec::new(),
        }
    }

    pub fn gaussian(k_b: f64, w0: f64, waist: Vec2, angle: f64, amplitude: f64, phase: f64, accurate_in: Rect) -> Incident {
        let (comps, warnings) = gaussian::components(k_b, w0, waist, angle, amplitude, phase, accurate_in);
        Incident {
            kind: IncidentKind::Gaussian,
            origin: waist,
            axis_angle: angle,
            amplitude,
            k_b,
            comps,
            warnings,
        }
    }

    /// The field scale used for "incident" normalisation.
    pub fn peak(&self) -> f64 {
        self.amplitude
    }

    pub fn eval(&self, p: Vec2) -> C64 {
        let d = p - self.origin;
        self.comps.iter().map(|m| m.c * cis(-(m.k[0] * d.x + m.k[1] * d.y))).sum()
    }

    /// The field and its gradient.
    pub fn eval_grad(&self, p: Vec2) -> (C64, [C64; 2]) {
        let d = p - self.origin;
        let mut e = C64::new(0.0, 0.0);
        let mut gx = C64::new(0.0, 0.0);
        let mut gy = C64::new(0.0, 0.0);
        for m in &self.comps {
            let v = m.c * cis(-(m.k[0] * d.x + m.k[1] * d.y));
            e += v;
            gx += -J * m.k[0] * v;
            gy += -J * m.k[1] * v;
        }
        (e, [gx, gy])
    }

    pub fn eval_points(&self, ps: &[Vec2]) -> Vec<C64> {
        ps.par_iter().with_min_len(64).map(|&p| self.eval(p)).collect()
    }

    /// The field on every node of `g`, index j·nx + i.
    ///
    /// Separable for any tilt: `E[j, i] = Σ_m Y[j, m] X[i, m]` with
    /// `X[i, m] = c_m e^{−j k_mx (x_i − x_o)}` and `Y[j, m] = e^{−j k_my (y_j − y_o)}`,
    /// one complex GEMM. Row-major (ny × nx) output is the column-major (nx × ny)
    /// product X · Yᵀ.
    pub fn eval_grid(&self, g: &GridSpec) -> Vec<C64> {
        let (nx, ny, m) = (g.nx, g.ny, self.comps.len());
        let mut out = vec![C64::new(0.0, 0.0); nx * ny];
        if nx == 0 || ny == 0 || m == 0 {
            return out;
        }
        let mut x = vec![C64::new(0.0, 0.0); nx * m];
        x.par_chunks_mut(nx).zip(&self.comps).for_each(|(col, c)| {
            for (i, v) in col.iter_mut().enumerate() {
                let xi = g.x0 + i as f64 * g.dx - self.origin.x;
                *v = c.c * cis(-c.k[0] * xi);
            }
        });
        let mut yt = vec![C64::new(0.0, 0.0); m * ny];
        yt.par_chunks_mut(m).enumerate().for_each(|(j, col)| {
            let yj = g.y0 + j as f64 * g.dx - self.origin.y;
            for (v, c) in col.iter_mut().zip(&self.comps) {
                *v = cis(-c.k[1] * yj);
            }
        });
        gemm(nx, ny, m, &x, &yt, &mut out);
        out
    }

    /// The same components with each wavenumber replaced by `f(direction angle)`.
    /// Used to build the FDTD's dispersion-matched copy of the incident field.
    pub fn map_wavenumbers(&self, f: impl Fn(f64) -> f64) -> Incident {
        let comps = self
            .comps
            .iter()
            .map(|c| {
                let angle = c.k[1].atan2(c.k[0]);
                let k = f(angle);
                PlaneComponent { k: [k * angle.cos(), k * angle.sin()], c: c.c }
            })
            .collect();
        Incident { comps, ..self.clone() }
    }
}
