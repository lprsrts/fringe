# Beam

Beam solves 2D optics scenes with full-wave electromagnetics and draws the
field. You place lenses, slabs, prisms, mirrors, slits, gratings, cylinders
and waveguides in a Gaussian beam or a plane wave, pick one of three solvers
(FDTD, FEM or MoM), and get the complex field Ez on a grid, which you can
render as intensity, magnitude, a snapshot of the real part or phase, or
animate over one optical cycle.

The core is a Rust library with a C ABI. On top of it sit `beam-cli`, which
solves scene files and writes PNG and NumPy output, and a native macOS app
for editing scenes and exporting images. I use it to make cover images, so
some colormaps (`laser_glow`, `asympton`, `spectral_glow`) are there to look
good as much as to read well.

## Physics and conventions

- **2D, Ez only.** Every element is an infinite extrusion along z, so a "lens"
  is a cylindrical lens. The only unknown is the out-of-plane field
  `E = Ez(x, y)` (TM_z, s-polarised in optics terms), which obeys the scalar
  Helmholtz equation `∇²E + k0² εr E = 0`. There is no Brewster angle, and an
  Ez-polarised slit in a conductor narrower than λ/2 is cut off, as it should be.
- **Time convention** `E(r, t) = Re{E(r) e^{+jωt}}`. A wave travelling along
  ê is `e^{−jk ê·r}`; outgoing waves are H⁽²⁾ and the Green's function is
  `G = −(j/4) H0⁽²⁾(kR)`.
- **Materials** are entered as `n + ik` (optics convention, `k ≥ 0` absorbs)
  and used internally as `ε = (n − jk)²`. Dielectrics need `1 ≤ n ≤ 6`,
  `0 ≤ k ≤ 1` and `n² − k² ≥ 1`; conductors are perfect (PEC). The background
  index `n_b` is real, from 1 to 4.
- **Units.** Lengths are in µm, angles in degrees in the JSON. The source
  amplitude A sets the field scale; intensity is `|E|²`, shown as `|E|²/A²`
  when normalised to the incident field.
- **Scattered-field formulation.** The incident field is an exact solution of
  the background: a plane wave, or a Gaussian beam built from propagating
  plane waves (so it is exact, not paraxial; `E_inc` at the waist centre is
  exactly `A e^{jφ0}`). Each solver computes the scattered field `E_s`, and
  `E_tot = E_inc + E_s`, with `E_tot = 0` inside conductors.
- **Geometry rules.** Bodies are closed, do not touch or overlap (gap at least
  0.05 λ_b), and lie inside the domain. The domain is the interior rectangle;
  FDTD and FEM add a perfectly matched layer (PML) around it, `pml_wl`
  background wavelengths thick.

Scenes are JSON, schema version 2 (`beam-cli example lens` prints one). The
app and the CLI read and write the same files.

## Solvers

| | FDTD | FEM | MoM |
|---|---|---|---|
| Method | Yee grid in time, run to steady state, then a DFT | P3 Lagrange triangles (P2 optional), curved boundaries, sparse LU | boundary integrals on curved panels, dense LU |
| Boundaries | staircased, with sub-pixel ε averaging | exact to the mesh | exact |
| Open space | CPML | complex-stretch PML | exact (Green's function) |
| Default resolution, preview / final | 10 / 24 cells per λ | 9 / 15 per λ | 8 / 16 panels per λ |

Limits worth knowing:

- **FDTD** has trouble with high-Q resonances. It ramps the source in over
  four periods and waits for the field to settle; a mode that rings for longer
  than the period cap (ramp + 3 transit times + 30 periods) stops it unsettled,
  and the result then carries a "not fully settled" warning. The validation
  case `mie_high_index` (n = 3.5, r = 0.5 µm, with a Q ≈ 240 resonance near
  the drive) is one: the field is still within 2 % of Mie, but it does not
  settle. Conductors thinner than a cell are rejected.
- **FEM** factorises one sparse matrix. That factorisation cannot be
  interrupted: Cancel takes effect before or after it, not during, so a large
  final solve can take a few seconds to stop.
- **MoM** needs piecewise-homogeneous bodies in a homogeneous background:
  every body is one material, separated from the others. The dense LU grows as
  N³ in the number of panels, so it suits scenes with a modest total perimeter
  in wavelengths. It needs no PML, and it is the most accurate of the three on
  the scenes it handles, which is why it is the reference below.

`beam-cli check` and the app show the estimated unknowns, time and memory
before solving; a scene whose estimate is over the memory limit is refused
(`too_large`) rather than started.

## Validation

`beam-cli validate --case all --solver all --slow` runs every case against an
analytic reference: Mie series for cylinders (PEC, dielectric, lossy, high
index), the Airy formula for a slab under a Gaussian beam, and the image
method for a flat PEC mirror. The error is the relative L2 norm of the total
field over the case region, at final quality; FDTD leaves out points within
two cells of an interface. Measured on the release build:

| Case | MoM | FEM | FDTD |
|---|---|---|---|
| `mie_pec` (PEC cylinder r = 1, FDTD at 30 cells/λ) | 3.2e-5 | 4.3e-4 | 4.0e-2 |
| `mie_pec_37` (same, incidence 37°) | 3.1e-5 | 4.3e-4 | 4.4e-2 |
| `mie_pec_resonance` (PEC at an interior resonance, CFIE, 9 radii) | 3.8e-5 | – | – |
| `mie_diel` (n = 1.5, r = 1) | 1.1e-4 | 4.0e-4 | 8.9e-3 |
| `mie_lossy` (n = 1.5 + 0.05i) | 4.7e-5 | 3.0e-4 | 4.0e-3 |
| `mie_high_index` (n = 3.5, r = 0.5) | 7.5e-5 | 5.4e-4 | 1.8e-2, unsettled |
| `slab_airy_0` (slab, Gaussian beam, 0°) | 1.3e-6 | 1.1e-3 | 5.6e-4 |
| `slab_airy_30` (30°) | 1.0e-5 | 8.5e-4 | 1.1e-2 |
| `slab_lossy` (k = 0.05) | 8.6e-7 | 9.2e-4 | 2.6e-3 |
| `mirror_0` (flat PEC mirror, Gaussian beam) | 1.8e-6 | 5.0e-4 | 2.7e-3 |
| `mirror_25` (25°) | 1.1e-5 | 4.7e-4 | 1.1e-2 |
| `mom_self` (12 against 16 panels/λ) | 2.5e-4 | – | – |
| `pml_hygiene` (domain 8 µm against 16 µm) | – | 4.9e-4 | 9.4e-7 |
| `balance` (energy balance, lossy cylinder) | 1.1e-4 | 8.0e-5 | 1.0e-3 |
| `free_beam`, `transparent` (no scattering) | 0 | 0 | 0 |

Convergence: FEM P3 between 9 and 15 per λ converges at order 5.8; FDTD with
sub-pixel averaging converges at order 2.0 (least squares over 12–30 cells/λ)
and is 4.1 times more accurate at 24 cells/λ than without it. The MoM EFIE at
the PEC resonance is ill-conditioned (condition number 7.9e5) where the CFIE
stays at 4.7.

Each case passes if its error is at most twice the value above (and within the
upper bound of the spec), so a change that makes a solver less accurate fails
`validate` and `cargo test`.

The three solvers are also compared with each other
(`cargo test --release --test cross_solver -- --ignored`). On the default lens
scene, against MoM at 20 panels/λ (itself within 4.8e-5 of 16 panels/λ):

| | FEM | FDTD | MoM |
|---|---|---|---|
| final, relative L2 difference | 1.4e-3 | 7.6e-3 | 4.8e-5 |
| final, focal peak x (reference 5.62 µm) | 5.57 µm | 5.57 µm | 5.62 µm |
| final, peak \|E\|² (reference 2.415) | +0.14 % | +0.08 % | 0 |
| preview, relative L2 difference | 3.4e-2 | 4.3e-2 | 8.4e-3 |
| preview, focal peak x | 6.13 µm | 5.35 µm | 5.62 µm |
| energy balance of the lossless lens | 1.4e-4 | 4.0e-5 | 5.5e-6 |

The intensity maximum along the axis is very flat (it changes by 0.1 % over
±0.1 µm), so the focal peak position moves by a few hundredths of a micrometre
with errors of 1e-3 in the field. On the double slit (x ≥ −4 µm), FEM is
within 2.0e-2 of MoM and FDTD within 3.6e-2.

The paraxial focus that the app marks for a lens (and `beam-cli check`
reports) is the thick-lens geometric focus, x ≈ 9.0 µm on the default
scene. The computed intensity peak is near 5.6 µm: a 3 µm waist in a 10 µm
aperture is far from the paraxial limit.

Timings for the default lens scene on an M-series Mac, release build, best
of three runs (other jobs on the machine make single runs noisy):

| | FDTD | FEM | MoM |
|---|---|---|---|
| preview | 0.19 s | 0.64 s | 0.08 s |
| final | 1.38 s | 2.30 s | 0.98 s |
| final, memory | 76 MB (estimate) | 1.6 GB (measured peak) | 50 MB (estimate) |

Most of the FEM time is the sparse LU; most of the MoM final time is
evaluating the field on the output grid. Cancelling takes under 30 ms in
every stage except inside the FEM factorisation.

## beam-cli

```sh
cargo build --release --bin beam-cli
target/release/beam-cli --help
```

Examples:

```sh
# List the example scenes, then solve one and write a PNG (final quality).
beam-cli example
beam-cli example lens | beam-cli solve - -o lens.png

# The real part with a diverging map, at a given phase, 3000 px wide, with outlines.
beam-cli example double_slit > slit.json
beam-cli solve slit.json -o slit.png --quantity real --phase-deg 90 --width 3000 --outlines

# A quick preview with another solver, plus the complex field as NumPy data.
beam-cli solve slit.json -o slit_fem.png --solver fem --quality preview --npy slit.npy

# 24 frames over one optical cycle (one solve).
beam-cli frames slit.json -o frames/ --frames 24 --quantity real

# Check a scene: validation issues, cost estimates, derived values.
beam-cli check slit.json

# Solve one scene with all three solvers and compare them.
beam-cli compare slit.json

# The validation cases (add --slow for all of them).
beam-cli validate --case mie_diel,balance --solver all
```

`SCENE` may be `-` for standard input. Colormaps: `viridis`, `inferno`,
`plasma`, `turbo`, `laser_glow`, `asympton`, `spectral_glow` (sequential),
`rdbu` (diverging, for the real part), `twilight`, `phase_wheel` (cyclic, for
phase). Exit codes: 0 ok, 1 check or validation failure, 2 usage, 3 solve
error, 130 cancelled (Ctrl-C).

The `.npy` file is complex128 with row 0 at the top (y_max); a `.npy.json`
sidecar next to it records the grid.

## Building

You need a Rust toolchain and the Xcode command-line tools (no Xcode). The
app needs macOS 26.

```sh
cargo test --release                       # fast tests
cargo test --release -- --ignored          # slow tests (validation, cross-solver)
BEAM_PERF=1 cargo test --release -- --ignored --test-threads=1   # with timing asserts
scripts/build.sh                           # static library, then the Swift app
scripts/bundle.sh                          # the above, then target/Beam.app, signed ad hoc
scripts/check-schema.sh                    # build, then check that the app and the core agree on the scene JSON
```

The app's minimum macOS is tied to the Rust toolchain: Homebrew's `rustc`
ships its standard library built for macOS 26, and the Swift target must not
claim anything older or `ld` warns about every std object.

The crate `beam_core` builds as an rlib (for the CLI and tests) and a static
library. The Swift package links `target/release/libbeam_core.a` through the
`CBeamCore` module, which wraps `include/beam_core.h`. The header exists twice
(`include/` and `swift/Sources/CBeamCore/include/`); a test checks that the
copies are identical, so change both.

## Layout

```
src/scene/          scene JSON types, validation, examples, derived values
src/geometry/       shapes, curved contours, inside tests, intersections
src/source/         incident fields: plane wave, angular-spectrum Gaussian, Yee matching
src/special/        Bessel and Hankel functions, Green's function, quadrature
src/solver/fdtd/    FDTD
src/solver/fem/     FEM
src/solver/mom/     MoM
src/solver/         shared solver interface, field grid, cancellation
src/analytic/       Mie, Airy slab, PEC image references; validation cases and metrics
src/render/         colormaps, field to RGBA, PNG and .npy export
src/linalg.rs       dense and sparse LU (faer)
src/job.rs, ffi.rs  background jobs and the C ABI
src/bin/beam_cli.rs beam-cli
include/            C header for the ABI
swift/              SwiftUI app (Swift package "Beam")
scripts/            build, bundle and schema-check scripts
tests/              integration tests; tests/fixtures holds example scenes and Bessel references
```
