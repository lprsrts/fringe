//! Incident fields: plane waves, Gaussian beams built from propagating plane
//! waves, and line sources (cylindrical waves). Each solves the background
//! Helmholtz equation exactly (a line source away from its own point), so the
//! scattered-field solvers can use them everywhere in the plane. All sources of
//! a scene are coherent and their fields add.

pub mod gaussian;
pub mod yee;

use rayon::prelude::*;

use crate::linalg::gemm;
use crate::scene::{Scene, SourceKind};
use crate::solver::field::GridSpec;
use crate::special::h2_01;
use crate::types::{cis, Rect, Vec2, C64, J};

/// One plane wave: `E += c · exp(−j k·(r − origin))`.
#[derive(Clone, Debug, PartialEq)]
pub struct PlaneComponent {
    pub k: [f64; 2],
    pub c: C64,
}

/// One line source: `E += c · H0⁽²⁾(k r)` with r the distance from `pos`.
#[derive(Clone, Debug, PartialEq)]
pub struct LineComponent {
    pub pos: Vec2,
    pub c: C64,
}

/// The Yee grid the FDTD's matched copy of a line source is built for: the
/// wavenumber then depends on the direction from the source (see
/// [`yee::yee_wavenumber`]).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct YeeGrid {
    pub eps_b: f64,
    pub omega: f64,
    pub dx: f64,
    pub dt: f64,
}

/// `|H0⁽²⁾(2π)|`: a line source of amplitude A has |E| ≈ A one background
/// wavelength away.
pub fn line_source_norm() -> f64 {
    h2_01(C64::new(2.0 * std::f64::consts::PI, 0.0)).0.norm()
}

/// Line sources are evaluated no closer than this (in background
/// wavelengths), so the singular point itself gives a large finite value
/// rather than infinity or NaN.
const LINE_CORE_WL: f64 = 1e-6;

/// The sum of every enabled source's field. Plane waves (plane-wave sources
/// and the angular spectra of Gaussian beams) share one reference point
/// `origin`; a source with another origin has the phase folded into its
/// coefficients.
#[derive(Clone, Debug)]
pub struct Incident {
    pub k_b: f64,
    pub origin: Vec2,
    pub comps: Vec<PlaneComponent>,
    pub lines: Vec<LineComponent>,
    /// Propagation angles (radians) of the plane-wave and Gaussian sources.
    pub directions: Vec<f64>,
    /// `Some` for the FDTD's dispersion-matched copy: line sources use the Yee
    /// wavenumber along the direction from the source to each point.
    pub line_grid: Option<YeeGrid>,
    /// Accuracy warnings from the construction (never errors).
    pub warnings: Vec<String>,
}

impl Incident {
    /// No field at all.
    pub fn empty(k_b: f64) -> Incident {
        Incident {
            k_b,
            origin: Vec2::ZERO,
            comps: Vec::new(),
            lines: Vec::new(),
            directions: Vec::new(),
            line_grid: None,
            warnings: Vec::new(),
        }
    }

    /// The scene's enabled sources, accurate to about 1e−10·A on
    /// `accurate_in` (the PML outer rectangle).
    pub fn from_scene(scene: &Scene, accurate_in: Rect) -> Incident {
        let k_b = 2.0 * std::f64::consts::PI / scene.wavelength_um * scene.background.n;
        let mut inc = Incident::empty(k_b);
        for s in scene.enabled_sources() {
            let part = match s.kind {
                SourceKind::PlaneWave { angle_deg, amplitude, phase_deg } => {
                    Incident::plane_wave(k_b, angle_deg.to_radians(), amplitude, phase_deg.to_radians())
                }
                SourceKind::GaussianBeam { waist_um, waist_x_um, waist_y_um, angle_deg, amplitude, phase_deg } => {
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
                SourceKind::LineSource { x_um, y_um, amplitude, phase_deg } => {
                    Incident::line_source(k_b, Vec2::new(x_um, y_um), amplitude, phase_deg.to_radians())
                }
            };
            inc.add(part);
        }
        inc
    }

    pub fn plane_wave(k_b: f64, angle: f64, amplitude: f64, phase: f64) -> Incident {
        let d = Vec2::from_angle(angle);
        Incident {
            comps: vec![PlaneComponent { k: [k_b * d.x, k_b * d.y], c: amplitude * cis(phase) }],
            directions: vec![angle],
            ..Incident::empty(k_b)
        }
    }

    pub fn gaussian(k_b: f64, w0: f64, waist: Vec2, angle: f64, amplitude: f64, phase: f64, accurate_in: Rect) -> Incident {
        let (comps, warnings) = gaussian::components(k_b, w0, waist, angle, amplitude, phase, accurate_in);
        Incident { origin: waist, comps, directions: vec![angle], warnings, ..Incident::empty(k_b) }
    }

    /// `A e^{jφ} H0⁽²⁾(k_b r) / |H0⁽²⁾(2π)|` about `pos`.
    pub fn line_source(k_b: f64, pos: Vec2, amplitude: f64, phase: f64) -> Incident {
        let c = amplitude * cis(phase) / line_source_norm();
        Incident { lines: vec![LineComponent { pos, c }], ..Incident::empty(k_b) }
    }

    /// Adds another field (same k_b) to this one.
    pub fn add(&mut self, other: Incident) {
        if self.comps.is_empty() {
            self.origin = other.origin;
            self.comps = other.comps;
        } else {
            // c e^{−jk·(r − o₂)} = [c e^{−jk·(o₁ − o₂)}] e^{−jk·(r − o₁)}
            let d = self.origin - other.origin;
            self.comps.extend(
                other.comps.into_iter().map(|m| PlaneComponent { c: m.c * cis(-(m.k[0] * d.x + m.k[1] * d.y)), k: m.k }),
            );
        }
        self.lines.extend(other.lines);
        self.directions.extend(other.directions);
        self.warnings.extend(other.warnings);
    }

    /// The direction the FDTD's dispersion correction makes exact. The
    /// numerical phase velocity depends on the direction only through
    /// sin²(2θ); with one beam (or several sharing that value) it is the beam
    /// axis, as before. A line source radiates in every direction, and beams
    /// in different directions disagree, so then it is 22.5°, where sin²(2θ)
    /// is ½: half-way between the grid axes and the diagonals, which halves
    /// the worst phase error over all directions.
    pub fn dispersion_axis(&self) -> f64 {
        let key = |a: f64| (2.0 * a).sin().powi(2);
        match self.directions.first() {
            Some(&a) if self.lines.is_empty() && self.directions.iter().all(|&b| (key(b) - key(a)).abs() < 1e-9) => a,
            None if self.lines.is_empty() => 0.0,
            _ => std::f64::consts::FRAC_PI_8,
        }
    }

    /// Wavenumber of line source `l` towards `p`: k_b, or on the Yee grid the
    /// numerical wavenumber along that direction.
    #[inline]
    fn line_k(&self, d: Vec2) -> f64 {
        match self.line_grid {
            None => self.k_b,
            Some(g) => {
                let angle = if d.x == 0.0 && d.y == 0.0 { 0.0 } else { d.y.atan2(d.x) };
                yee::yee_wavenumber(angle, g.eps_b, g.omega, g.dx, g.dt)
            }
        }
    }

    #[inline]
    fn line_eval(&self, l: &LineComponent, p: Vec2) -> C64 {
        let d = p - l.pos;
        let k = self.line_k(d);
        let r = d.norm().max(LINE_CORE_WL * 2.0 * std::f64::consts::PI / k);
        l.c * h2_01(C64::new(k * r, 0.0)).0
    }

    pub fn eval(&self, p: Vec2) -> C64 {
        let d = p - self.origin;
        let plane: C64 = self.comps.iter().map(|m| m.c * cis(-(m.k[0] * d.x + m.k[1] * d.y))).sum();
        self.lines.iter().fold(plane, |e, l| e + self.line_eval(l, p))
    }

    /// The field and its gradient. On the Yee grid copy, a line source's
    /// gradient treats its direction-dependent wavenumber as constant.
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
        for l in &self.lines {
            let d = p - l.pos;
            let k = self.line_k(d);
            let r = d.norm().max(LINE_CORE_WL * 2.0 * std::f64::consts::PI / k);
            let (h0, h1) = h2_01(C64::new(k * r, 0.0));
            e += l.c * h0;
            // d/dr H0⁽²⁾(kr) = −k H1⁽²⁾(kr); zero at the singular point itself.
            if d.x != 0.0 || d.y != 0.0 {
                let dr = -k * l.c * h1 / r;
                gx += dr * d.x;
                gy += dr * d.y;
            }
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
        let mut out = self.eval_grid_planes(g);
        if !self.lines.is_empty() && !out.is_empty() {
            out.par_chunks_mut(g.nx).enumerate().for_each(|(j, row)| {
                for (i, v) in row.iter_mut().enumerate() {
                    let p = g.point(i, j);
                    for l in &self.lines {
                        *v += self.line_eval(l, p);
                    }
                }
            });
        }
        out
    }

    fn eval_grid_planes(&self, g: &GridSpec) -> Vec<C64> {
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

    /// The FDTD's dispersion-matched copy: every plane wave gets the Yee
    /// wavenumber of its direction, and every line source the Yee wavenumber
    /// along the direction to the point it is evaluated at. For a plane wave
    /// that is an exact discrete solution; for a line source it is the
    /// far-field phase to second order in the grid anisotropy (the near field
    /// within a few cells of the source is not a discrete solution, but no
    /// body comes that close).
    pub fn yee_matched(&self, grid: YeeGrid) -> Incident {
        let mut m = self.map_wavenumbers(|phi| yee::yee_wavenumber(phi, grid.eps_b, grid.omega, grid.dx, grid.dt));
        m.line_grid = Some(grid);
        m
    }

    /// Whether every wavenumber of a Yee-matched copy exists (the step is
    /// within the Courant limit).
    pub fn is_finite(&self) -> bool {
        let lines_ok = match self.line_grid {
            None => true,
            Some(g) => [0.0, std::f64::consts::FRAC_PI_4]
                .iter()
                .all(|&a| yee::yee_wavenumber(a, g.eps_b, g.omega, g.dx, g.dt).is_finite()),
        };
        lines_ok && self.comps.iter().all(|c| c.k[0].is_finite() && c.k[1].is_finite())
    }

    /// The same plane-wave components with each wavenumber replaced by
    /// `f(direction angle)`; line sources are kept as they are.
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
