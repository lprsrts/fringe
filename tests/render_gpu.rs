//! The core side of the GPU viewport: the CPU renderer's per-pixel `powf` hoist is
//! bit-identical to the renderer as it was, and the calls the viewport uploads from
//! (grid, f32 parts, scale, 1024-entry LUT, tracking previews) agree with the renderer.

use std::f64::consts::PI;

use fringe_core::render::view::{
    column_stencils, part_f32, phase_factor, render_lut, scale, NormMode, Normalization, PartName, ViewRect, LUT_SIZE,
};
use fringe_core::render::{render_rgba, Colormap, Quantity, View};
use fringe_core::scene::examples;
use fringe_core::solver::field::catmull_rom;
use fringe_core::solver::{solve, FieldGrid, Part, Quality, SolveContext};
use fringe_core::types::C64;

fn solved(name: &str) -> FieldGrid {
    let scene = examples::example(name).unwrap();
    solve(&scene, Quality::Preview, &SolveContext::new()).unwrap()
}

/// `render_rgba` as it was before the transfer decisions moved out of the pixel loop.
fn reference_rgba(field: &FieldGrid, view: &View, width: u32, height: u32) -> Vec<u8> {
    let mut out = vec![0u8; (width * height * 4) as usize];
    let colormap: Colormap = view.colormap.parse().unwrap();
    let gamma = if view.gamma.is_finite() && view.gamma > 0.0 { view.gamma } else { 1.0 };
    let lut = colormap.lut(field.scene.wavelength_um * 1000.0, LUT_SIZE);
    let g = field.grid;
    let rect = view.view_um.unwrap_or_else(|| {
        let r = g.rect();
        ViewRect { x_min_um: r.x_min, x_max_um: r.x_max, y_min_um: r.y_min, y_max_um: r.y_max }
    });
    let s = scale(field, view);
    let rot = phase_factor(view.phase_deg);
    let part: Part = view.part.into();
    let values: Vec<C64> = (0..g.len()).map(|i| field.value(part, i)).collect();
    let (w, h) = (width as usize, height as usize);
    let px = (rect.x_max_um - rect.x_min_um) / w as f64;
    let py = (rect.y_max_um - rect.y_min_um) / h as f64;
    let last_x = (g.nx - 1) as f64;
    let last_y = (g.ny - 1) as f64;
    const EDGE: f64 = 1e-9;
    let columns: Vec<Option<(usize, [f64; 4])>> = (0..w)
        .map(|i| {
            let x = rect.x_min_um + (i as f64 + 0.5) * px;
            let fx = (x - g.x0) / g.dx;
            (fx >= -EDGE && fx <= last_x + EDGE).then(|| {
                let fx = fx.clamp(0.0, last_x);
                let i0 = (fx.floor() as usize).min(g.nx.saturating_sub(2));
                (i0, catmull_rom(fx - i0 as f64))
            })
        })
        .collect();
    let transfer = |v: f64| -> f64 {
        let t = if let Some(db) = view.log_db.filter(|d| *d > 0.0) {
            let factor = if view.quantity == Quantity::Intensity { 10.0 } else { 20.0 };
            if v > 0.0 {
                1.0 + factor * v.log10() / db
            } else {
                0.0
            }
        } else if gamma == 1.0 {
            v.clamp(0.0, 1.0)
        } else {
            v.clamp(0.0, 1.0).powf(gamma)
        };
        t.clamp(0.0, 1.0)
    };
    let lut_at = |t: f64| lut[((t * LUT_SIZE as f64) as usize).min(LUT_SIZE - 1)];
    for (row, line) in out.chunks_mut(w * 4).enumerate() {
        let y = rect.y_max_um - (row as f64 + 0.5) * py;
        let fy = (y - g.y0) / g.dx;
        if !(fy >= -EDGE && fy <= last_y + EDGE) {
            for p in line.chunks_mut(4) {
                p.copy_from_slice(&view.outside_rgba);
            }
            continue;
        }
        let fy = fy.clamp(0.0, last_y);
        let j0 = (fy.floor() as usize).min(g.ny.saturating_sub(2));
        let wy = catmull_rom(fy - j0 as f64);
        let rows: [usize; 4] = std::array::from_fn(|b| (j0 as isize + b as isize - 1).clamp(0, g.ny as isize - 1) as usize);
        for (col, pxl) in columns.iter().zip(line.chunks_mut(4)) {
            let Some((i0, wx)) = *col else {
                pxl.copy_from_slice(&view.outside_rgba);
                continue;
            };
            let mut e = C64::new(0.0, 0.0);
            for (b, &r) in rows.iter().enumerate() {
                let mut acc = C64::new(0.0, 0.0);
                for (a, wa) in wx.iter().enumerate() {
                    let i = (i0 as isize + a as isize - 1).clamp(0, g.nx as isize - 1) as usize;
                    acc += values[r * g.nx + i] * *wa;
                }
                e += acc * wy[b];
            }
            let rgba = match view.quantity {
                Quantity::Intensity => lut_at(transfer(e.norm_sqr() / (s * s))),
                Quantity::Magnitude => lut_at(transfer(e.norm() / s)),
                Quantity::Real => {
                    let v = (e * rot).re / s;
                    let m = v.abs().min(1.0);
                    let u = if gamma == 1.0 { m } else { m.powf(gamma) }.copysign(v);
                    lut_at(0.5 + 0.5 * u)
                }
                Quantity::Phase => {
                    let z = e * rot;
                    let mut c = lut_at((z.arg() + PI) / (2.0 * PI));
                    if view.phase_weighted {
                        let b = (z.norm() / s).min(1.0).sqrt();
                        for ch in c.iter_mut().take(3) {
                            *ch = (*ch as f64 * b).round() as u8;
                        }
                    }
                    c
                }
            };
            pxl.copy_from_slice(&rgba);
        }
    }
    out
}

fn fnv(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf29ce484222325u64, |h, &b| (h ^ b as u64).wrapping_mul(0x100000001b3))
}

#[test]
fn render_rgba_is_bit_identical_to_the_reference() {
    let field = solved("mie_pec");
    let g = field.grid;
    let r = g.rect();
    // A zoomed rect that crosses the grid edge, to exercise the outside mask.
    let zoom = ViewRect { x_min_um: r.x_min - 0.3 * r.width(), x_max_um: r.x_min + 0.4 * r.width(), y_min_um: r.y_min + 0.2 * r.height(), y_max_um: r.y_max + 0.1 * r.height() };
    let mut cases = 0;
    for colormap in Colormap::ALL {
        for quantity in [Quantity::Intensity, Quantity::Magnitude, Quantity::Real, Quantity::Phase] {
            for (gamma, log_db, weighted) in [(1.0, None, false), (0.5, None, true), (1.0, Some(30.0), false), (0.6, Some(20.0), true)] {
                for part in [PartName::Total, PartName::Scattered, PartName::Incident] {
                    for (phase, view_um) in [(0.0, None), (37.0, Some(zoom)), (271.0, None)] {
                        let view = View {
                            quantity,
                            part,
                            phase_deg: phase,
                            colormap: colormap.name().into(),
                            gamma,
                            normalization: Normalization { mode: NormMode::Auto, value: 1.0 },
                            log_db,
                            phase_weighted: weighted,
                            view_um,
                            outside_rgba: [0, 0, 0, 0],
                            pec_rgba: None,
                            outlines: false,
                        };
                        let (w, h) = (97, 61);
                        let mut out = vec![0u8; w * h * 4];
                        render_rgba(&field, &view, w as u32, h as u32, &mut out).unwrap();
                        let want = reference_rgba(&field, &view, w as u32, h as u32);
                        assert_eq!(fnv(&out), fnv(&want), "{colormap:?} {quantity:?} gamma {gamma} log {log_db:?} {part:?} phase {phase}");
                        cases += 1;
                    }
                }
            }
        }
    }
    assert_eq!(cases, 10 * 4 * 4 * 3 * 3);
}

#[test]
fn gpu_inputs_agree_with_the_renderer() {
    let field = solved("mie_pec");
    let g = field.grid;
    for part in [Part::Total, Part::Scattered, Part::Incident] {
        let mut out = vec![0f32; 2 * g.len()];
        part_f32(&field, part, &mut out).unwrap();
        for i in (0..g.len()).step_by(97) {
            let v = field.value(part, i);
            assert_eq!(out[2 * i], v.re as f32);
            assert_eq!(out[2 * i + 1], v.im as f32);
        }
        assert!(part_f32(&field, part, &mut out[..2 * g.len() - 1]).is_err());
    }
    for c in Colormap::ALL {
        assert_eq!(render_lut(c, field.scene.wavelength_um, LUT_SIZE), c.lut(field.scene.wavelength_um * 1000.0, LUT_SIZE));
    }
    let view = View { part: PartName::Scattered, ..View::default() };
    assert_eq!(scale(&field, &view), field.norms().p995[Part::Scattered as usize]);
    let r = g.rect();
    let rect = ViewRect { x_min_um: r.x_min - 1.0, x_max_um: r.x_max, y_min_um: r.y_min, y_max_um: r.y_max };
    let cols = column_stencils(&g, &rect, 200);
    assert!(cols[0].is_none() && cols[199].is_some());
}

#[test]
fn tracking_previews_are_capped() {
    let mut scene = examples::default();
    scene.domain.x_max_um += 40.0;
    scene.domain.y_max_um += 20.0;
    let capped = fringe_core::ffi::tracking_scene(&scene);
    let p = fringe_core::problem::compile_unchecked(&capped, Quality::Preview);
    let cells = fringe_core::solver::fdtd::grid::Layout::new(&p).cells();
    assert!(cells <= fringe_core::ffi::MAX_CELLS_TRACKING, "{cells} cells");
    let small = examples::default();
    let p = fringe_core::problem::compile_unchecked(&small, Quality::Preview);
    let before = fringe_core::solver::fdtd::grid::Layout::new(&p).cells();
    let after = fringe_core::solver::fdtd::grid::Layout::new(&fringe_core::problem::compile_unchecked(&fringe_core::ffi::tracking_scene(&small), Quality::Preview)).cells();
    assert!(after <= before.min(fringe_core::ffi::MAX_CELLS_TRACKING), "default scene: {before} -> {after}");
}
