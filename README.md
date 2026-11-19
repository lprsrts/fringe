# Fringe

![Interference fringes behind a double slit, solved with Fringe](https://fringe.lprsrts.com/assets/social.png)

Fringe solves 2D optics scenes with full-wave electromagnetics and draws the
field. You place lenses, slabs, prisms, mirrors, slits, gratings, cylinders
and waveguides in Gaussian beams, plane waves or the light of point emitters,
pick one of three solvers
(FDTD, FEM or MoM), and get the complex field Ez on a grid, which you can
render as intensity, magnitude, a snapshot of the real part or phase, or
animate over one optical cycle.

The core is a Rust library with a C ABI. On top of it sit `fringe-cli`, which
solves scene files and writes PNG and NumPy output, and a native macOS app
for editing scenes and exporting images. I use it to make cover images, so
some colormaps (`laser_glow`, `asympton`, `spectral_glow`) are there to look
good as much as to read well.

## Gallery

Each frame of these loops is a separate solve, drawn as intensity with a fixed
colour scale. Nothing between the frames is interpolated.

<table>
<tr>
<td width="50%"><img src="https://fringe.lprsrts.com/assets/gallery/crystal.gif" width="320" alt="Light following a channel through a grid of rods as the rods are removed one at a time"></td>
<td width="50%"><img src="https://fringe.lprsrts.com/assets/gallery/wgm_adddrop.gif" width="320" alt="A glass disk between two waveguides switching light from one waveguide to the other as the wavelength changes"></td>
</tr>
<tr>
<td><b>Photonic crystal.</b> Light at this wavelength can't travel through a
grid of rods (n = 3.4, spacing 0.38 λ). Removing rods one at a time opens a
channel, and the light follows it around six corners.</td>
<td><b>Disk resonator.</b> Off resonance the beam runs straight along the top
waveguide. Shorten the wavelength by 1% and it fills a whispering-gallery mode
of the disk, then leaves backwards along the bottom waveguide.</td>
</tr>
<tr>
<td><img src="https://fringe.lprsrts.com/assets/gallery/phc_z_rainbow.gif" width="320" alt="A beam sweeping through the visible spectrum into a rod lattice with a Z-shaped channel"></td>
<td><img src="https://fringe.lprsrts.com/assets/gallery/mandala.gif" width="320" alt="A point source inside three rings of glass rods, two of them turning"></td>
</tr>
<tr>
<td><b>Wavelength sweep.</b> The same kind of lattice with a Z-shaped channel,
from 412 to 665 nm, each frame in the colour of its wavelength. Green to gold
light can only go around the corners, violet leaks through the grid and red gets
into the rods. The rods are a lossless n = 3.4, so this is a scaled model, not
silicon.</td>
<td><b>Rotating rings.</b> One point emitter inside three rings of glass rods
(n = 2.4). The two outer rings turn in opposite directions, so the pattern
twists into a pinwheel and back.</td>
</tr>
</table>

The app has a simulator for building your own scenes and 20 puzzles where you
place parts to steer light, build interference effects and make logic gates:

![The Fringe window in simulator mode: a lens focusing a Gaussian beam onto two detectors, with their readings and a profile plot](https://fringe.lprsrts.com/assets/simulator.jpg)

![The Fringe window in puzzle mode: an XOR gate built from one glass slab, with its truth table and contrast chart](https://fringe.lprsrts.com/assets/puzzle.jpg)

## Install

Fringe needs macOS 26 or later on Apple silicon.

With [Homebrew](https://brew.sh):

```sh
brew install --cask lprsrts/tap/fringe      # the app
brew install lprsrts/tap/fringe-cli         # the command-line tool, built from source
```

Or download `Fringe-<version>-macos-arm64.dmg` from
[Releases](https://github.com/lprsrts/fringe/releases) and drag Fringe to
Applications. The app is signed with a Developer ID and notarized by Apple, and
it works offline. Each release also has a prebuilt `fringe-cli` tarball and
`SHA256SUMS`.

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
- **Dispersive materials** (`"type": "dispersive"`) are Lorentz–Drude models,
  `ε(ω) = ε∞ − Σ ωp²/(ω² − jγω) + Σ Δε ω0²/(ω0² − ω² + jγω)` with frequencies
  as photon energies in eV (ħω = 1.239841984/λ0[µm]). They allow metals
  (ε′ < 0). FEM and MoM use ε at the scene wavelength; FDTD integrates the
  poles in time (one auxiliary current per pole) and matches ε at the scene
  wavelength exactly. Mesh and grid sizes follow |n|, so a metal is resolved by
  its skin depth; FDTD run lengths follow Re n, since light does not cross a
  metal. The preset library (`fringe-cli materials`) has gold, silver,
  aluminium and copper (Rakić et al., Appl. Opt. 37, 5271 (1998)) and BK7 and
  fused silica (Sellmeier formulas as lossless poles). The fits differ from
  Johnson & Christy by up to about 13 % in k. With E along z there is no
  localised surface plasmon on a cylinder: that resonance needs E in the plane.
- **Sources.** A scene has a list of sources, all coherent at the scene
  wavelength; their incident fields add. Each is a plane wave, a Gaussian
  beam or a line source (`"type": "line_source"`): a line current along z,
  which in the plane is a point emitter of cylindrical waves,
  `E = A e^{jφ} H0⁽²⁾(k_b r) / |H0⁽²⁾(2π)|`, so that |E| ≈ A one background
  wavelength away. An emitter must sit in the background, inside the domain
  and at least 0.1 λ_b from every body.
- **Detectors.** A scene may list detectors, read from the solved field
  without another solve. A line detector (`"kind": "line"`, end points p1 and
  p2) gives the time-averaged power flux through the segment per µm in z,
  `S = −Im(E* ∇E) / (2 k0)` with η0 = 1, positive along the normal to the
  right of p1 → p2; a plane wave of amplitude A in background index n_b
  carries `n_b A² / 2` per µm. It reports the total, incident and scattered
  flux (flux is quadratic, so the total is not their sum). A box detector
  (`"kind": "box"`, centre, width and height) gives the mean, integral and
  largest sample of |E|² over the box, for the total and the incident field.
  Values and gradients come from a degree-7 local polynomial on the output
  grid: a plane wave's flux is within 0.15 % at preview resolution and 1e-5
  at final. Detectors must lie inside the domain; near an emitter their
  readings are rough (a warning says so).
- **Units.** Lengths are in µm, angles in degrees in the JSON. The source
  amplitude A sets the field scale; intensity is `|E|²`, shown as `|E|²/A²`
  when normalised to the incident field (with several sources, A is the sum
  of their amplitudes). The automatic colour scale leaves out a disc of
  λ_b/4 around each emitter, where its field is singular.
- **Scattered-field formulation.** The incident field is an exact solution of
  the background: a plane wave, or a Gaussian beam built from propagating
  plane waves (so it is exact, not paraxial; `E_inc` at the waist centre is
  exactly `A e^{jφ0}`), or the Hankel function of a line source. Each solver computes the scattered field `E_s`, and
  `E_tot = E_inc + E_s`, with `E_tot = 0` inside conductors.
- **Geometry rules.** Bodies are closed, do not touch or overlap (gap at least
  0.05 λ_b), and lie inside the domain. The domain is the interior rectangle;
  FDTD and FEM add a perfectly matched layer (PML) around it, `pml_wl`
  background wavelengths thick.

Scenes are JSON, schema version 3 (`fringe-cli example lens` prints one);
version 2 files are read and upgraded (their single `source` becomes the
first entry of `sources`, with id `source-1`; they have no detectors). The app and the CLI read and write the
same files.

## Solvers

| | FDTD | FEM | MoM |
|---|---|---|---|
| Method | Yee grid in time, run to steady state, then a DFT | P3 Lagrange triangles (P2 optional), curved boundaries, sparse LU | boundary integrals on curved panels, dense LU |
| Boundaries | staircased, with sub-pixel ε averaging and conductor surfaces placed between grid nodes | exact to the mesh | exact |
| Open space | CPML | complex-stretch PML | exact (Green's function) |
| Default resolution, preview / final | 10 / 24 cells per λ | 9 / 15 per λ | 8 / 16 panels per λ |

Limits worth knowing:

- **FDTD** has trouble with high-Q resonances. It ramps the source in over
  four periods and waits for the field to settle; a mode that rings for longer
  than the period cap (ramp + 3 transit times + 30 periods) stops it unsettled,
  and the result then carries a "not fully settled" warning. The validation
  case `mie_high_index` (n = 3.5, r = 0.5 µm, with a Q ≈ 240 resonance near
  the drive) is one: the field is still within 2 % of Mie, but it does not
  settle. A conductor's surface is placed between grid nodes along each grid
  line, so a flat face is accurate wherever it falls on the grid (the
  `mirror_off_grid` case checks this), but corners are still staircased, and
  on PEC scenes FDTD is the least accurate of the three solvers. Conductors
  thinner than a cell are rejected. The grid's phase velocity depends on the
  direction; FDTD corrects it exactly along one axis, the beam's when there is
  one beam, and otherwise (an emitter, or beams in different directions)
  along 22.5°, half-way between the grid axes and the diagonals, which halves
  the worst error. An emitter's incident field uses the grid's wavenumber in
  each direction from it; with the remaining anisotropy it is within 9.4e-3
  of the exact Hankel function over the 8 µm `line_free` domain at
  24 cells/λ, and the error grows with the distance in wavelengths. An
  emitter close to a high-index body can excite modes that ring past the
  period cap (it then warns as above).
- **FEM** factorises one sparse matrix. That factorisation cannot be
  interrupted: Cancel takes effect before or after it, not during, so a large
  final solve can take a few seconds to stop.
- **MoM** needs piecewise-homogeneous bodies in a homogeneous background:
  every body is one material, separated from the others. The dense LU grows as
  N³ in the number of panels, so it suits scenes with a modest total perimeter
  in wavelengths. It needs no PML, and it is the most accurate of the three on
  the scenes it handles, which is why it is the reference below.

`fringe-cli check` and the app show the estimated unknowns, time and memory
before solving; a scene whose estimate is over the memory limit is refused
(`too_large`) rather than started. A preview over the limits first drops its
resolution, to no less than 60 % of the default, and the check says so
(`preview_coarsened`); a preview resolution set in the scene is never lowered.

## Validation

`fringe-cli validate --case all --solver all --slow` runs every case against an
analytic reference: Mie series for cylinders (PEC, dielectric, lossy, high
index, silver and gold), the series by Graf's addition theorem for a line
source next to a cylinder, the Airy formula for a slab under a Gaussian beam,
and the image method for a flat PEC mirror. The error is the relative L2 norm of the total
field over the case region, at final quality; FDTD leaves out points within
two cells of an interface. The metal cylinders are small, so `validate` also
prints the error of the scattered field alone (FDTD 1.9e-3 to 9.9e-3, FEM
6.0e-4 to 6.9e-4, MoM 2.3e-5 to 3.0e-4). The line-source cases leave out a
disc of λ_b/4 around the emitter. Measured on the release build:

| Case | MoM | FEM | FDTD |
|---|---|---|---|
| `mie_pec` (PEC cylinder r = 1, FDTD at 30 cells/λ) | 3.2e-5 | 4.3e-4 | 6.8e-3 |
| `mie_pec_37` (same, incidence 37°) | 3.1e-5 | 4.3e-4 | 4.1e-3 |
| `mie_pec_resonance` (PEC at an interior resonance, CFIE, 9 radii) | 3.8e-5 | – | – |
| `mie_diel` (n = 1.5, r = 1) | 1.1e-4 | 4.0e-4 | 8.9e-3 |
| `mie_lossy` (n = 1.5 + 0.05i) | 4.7e-5 | 3.0e-4 | 4.0e-3 |
| `mie_high_index` (n = 3.5, r = 0.5) | 7.5e-5 | 5.4e-4 | 1.8e-2, unsettled |
| `slab_airy_0` (slab, Gaussian beam, 0°) | 1.3e-6 | 1.1e-3 | 5.6e-4 |
| `slab_airy_30` (30°) | 1.0e-5 | 8.5e-4 | 1.1e-2 |
| `slab_lossy` (k = 0.05) | 8.6e-7 | 9.2e-4 | 2.6e-3 |
| `mirror_0` (flat PEC mirror, Gaussian beam) | 1.8e-6 | 5.0e-4 | 2.7e-3 |
| `mirror_25` (25°) | 1.1e-5 | 4.7e-4 | 1.1e-2 |
| `mirror_off_grid` (`mirror_0` with the face Δ/4 off the FDTD grid) | 1.8e-6 | 5.4e-4 | 4.1e-3 |
| `mom_self` (12 against 16 panels/λ) | 2.5e-4 | – | – |
| `pml_hygiene` (domain 8 µm against 16 µm; FEM at 25 per λ) | – | 5.2e-5 | 9.4e-7 |
| `balance` (energy balance, lossy cylinder) | 1.1e-4 | 8.0e-5 | 1.0e-3 |
| `mie_silver` (silver r = 0.1 µm, λ0 = 0.5 µm) | 3.1e-5 | 2.2e-4 | 7.6e-4 |
| `mie_gold` (gold r = 0.15 µm, λ0 = 0.633 µm) | 8.9e-6 | 2.3e-4 | 7.2e-4 |
| `mie_silver_plasmon` (silver r = 0.06 µm at ε′ ≈ −1, λ0 = 0.345 µm) | 6.5e-5 | 1.5e-4 | 2.1e-3 |
| `bk7_plain` (BK7 preset against the plain index at λ0 = 1 µm) | 0 | 9e-15 | 3.8e-5 |
| `line_pec` (line source 0.9 µm from a PEC cylinder r = 1, FDTD at 30 cells/λ) | 4.1e-5 | 5.1e-4 | 6.8e-3 |
| `line_diel` (same, n = 1.5) | 1.4e-4 | 4.7e-4 | 4.5e-3 |
| `line_plane_diel` (the line source and a plane wave at 30° together) | 1.4e-4 | 4.4e-4 | 4.5e-3 |
| `free_beam`, `transparent`, `line_free` (no scattering) | 0 | 0 | 0 |
| `detector_plane` (line flux and box mean intensity in a plane wave at 30°, n_b = 1.33) | 2.6e-6 | 2.6e-6 | 9.8e-9 |
| `slab_power` (|R + T − incident| / incident, slab with R ≈ 0.15, Gaussian beam) | 1.2e-6 | 4.7e-4 | 7.3e-8 |
| `slab_lossy_power` (absorbed fraction ≈ 0.82 against the Airy field's) | 6.5e-7 | 1.8e-4 | 2.3e-3 |

The detector rows measure readings rather than fields. In `slab_power` the
solvers conserve power to the errors shown; the split into R and T is less
exact for FDTD (R = 0.1442 against the Airy field's 0.1484 at 24 cells/λ;
the field itself is off by 4.2e-3 in this scene) than for FEM (0.1485) and
MoM (0.1484). Both slab rows also bound the larger of |R − R_Airy| and
|T − T_Airy| at final quality, at twice the measured 1.1e-6 (MoM), 5.4e-4
(FEM) and 4.2e-3 (FDTD).

Convergence: FEM P3 between 9 and 15 per λ converges at order 5.8; FDTD with
sub-pixel averaging converges at order 2.0 (least squares over 12–30 cells/λ)
and is 4.1 times more accurate at 24 cells/λ than without it. The MoM EFIE at
the PEC resonance is ill-conditioned (condition number 7.9e5) where the CFIE
stays at 4.7.

Each case passes if its error is within the bound in `src/analytic/cases.rs`:
twice the value above, or the accuracy target the case was written with if
that is smaller. A change that makes a solver less accurate therefore fails
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
within 2.0e-2 of MoM and FDTD within 4.3e-2.

The paraxial focus that the app marks for a lens (and `fringe-cli check`
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

## fringe-cli

```sh
cargo build --release --bin fringe-cli
target/release/fringe-cli --help
```

Examples:

```sh
# List the example scenes, then solve one and write a PNG (final quality).
fringe-cli example
fringe-cli example lens | fringe-cli solve - -o lens.png

# The real part with a diverging map, at a given phase, 3000 px wide, with outlines.
fringe-cli example double_slit > slit.json
fringe-cli solve slit.json -o slit.png --quantity real --phase-deg 90 --width 3000 --outlines

# A quick preview with another solver, plus the complex field as NumPy data.
fringe-cli solve slit.json -o slit_fem.png --solver fem --quality preview --npy slit.npy

# 24 frames over one optical cycle (one solve).
fringe-cli frames slit.json -o frames/ --frames 24 --quantity real

# Detector readings (printed after the solve, and in the --stats JSON).
fringe-cli example emitter_mirror | fringe-cli solve - -o mirror.png --stats mirror.json

# Check a scene: validation issues, cost estimates, derived values.
fringe-cli check slit.json

# The material presets with n + ik at 633 nm, and gold as scene material JSON.
fringe-cli materials --wavelength 0.633
fringe-cli materials gold

# Solve one scene with all three solvers: time, the intensity peak on the axis
# past the last element, and the difference between each pair.
fringe-cli compare slit.json

# The validation cases (add --slow for all of them).
fringe-cli validate --case mie_diel,balance --solver all

# Puzzles: list them, print one, score a design, check every reference solution.
fringe-cli puzzle list
fringe-cli puzzle show logic-xor -o xor.json
fringe-cli puzzle score logic-xor design.json
fringe-cli puzzle verify --all
```

`SCENE` may be `-` for standard input. Colormaps: `viridis`, `inferno`,
`plasma`, `turbo`, `laser_glow`, `asympton`, `spectral_glow` (sequential),
`rdbu` (diverging, for the real part), `twilight`, `phase_wheel` (cyclic, for
phase). Exit codes: 0 ok, 1 check or validation failure, 2 usage, 3 solve
error or a file that could not be read or written, 130 cancelled (Ctrl-C).

The `.npy` file is complex128 with row 0 at the top (y_max); a `.npy.json`
sidecar next to it records the grid.

The app's Export Field Data writes the same field as one NumPy archive instead,
which a sandboxed app can save through a single save panel:

```python
import json, numpy as np
f = np.load("fringe-fdtd-total.npz")
field, x, y = f["field"], f["x"], f["y"]   # (ny, nx) complex128; x[i], y[row] in µm, y[0] = top row
info = json.loads(f["info"].item())        # grid, solver and run info
```

## Puzzles

A puzzle is a scene with fixed parts, sources and detectors, a goal and rules
for what the player may add: which shapes and materials, how many, and where.
The puzzles are JSON files in `puzzles/`, one per puzzle, named
`<chapter>-<slug>.json`; they are built into the library and listed by
`fringe-cli puzzle list` and the app. The chapters are Steering light,
Interference, Logic with light, and Metals and emitters.

A design is scored at a fixed method and resolution (the method's preview
setting, so a few tenths of a second per source for the bundled puzzles). The
solvers are linear, so each enabled source is solved once on its own and every
case, one setting of the input sources switched on and off, is the sum of
those fields; the detectors are read on each sum. The goals:

| goal | score |
|---|---|
| `truth_table` | contrast in dB between the weakest output that should be 1 and the strongest that should be 0 |
| `maximize` | a line detector's power in % of a reference (by default the source's power; for an emitter, the power it gives off with the design in place), or a box's mean \|E\|² as a multiple of one |
| `minimize` | suppression in dB, −10 log10 of the measured fraction (scattered power, power or \|E\|²) |
| `target` | a split between two detectors: the share must be within a tolerance, and the score is the weaker side's power over its due, in % |

Each puzzle has a pass threshold and three star thresholds, and one known
solution; `fringe-cli puzzle verify` checks that every known solution passes
with at least one star and that no puzzle passes as it opens. The format and
the metrics are described in `src/puzzle/mod.rs` and `src/puzzle/eval.rs`.

In the app, View > Puzzles (⌘2) opens the puzzle browser and ⌘1 goes back to
the simulator, which keeps its own scene. A puzzle shows its goal, the parts
you may place and the allowed region. Check (⌘R) scores the design. For a
logic puzzle you can then switch the inputs on and off to see each case
without another solve. Progress and your last design for each puzzle stay in
the app's preferences on your Mac.

## Building

You need a Rust toolchain and the Xcode command-line tools (no Xcode). The
app needs macOS 26.

```sh
cargo test --release                       # fast tests
cargo test --release -- --ignored          # slow tests (validation, cross-solver)
FRINGE_PERF=1 cargo test --release -- --ignored --test-threads=1   # with timing asserts
scripts/build.sh                           # static library, then the Swift app
scripts/bundle.sh                          # the above, then target/Fringe.app, signed ad hoc
                                           # (or with FRINGE_SIGN_IDENTITY="Developer ID Application: …")
scripts/release.sh                         # signed, notarized DMG + CLI tarball + SHA256SUMS in dist/
scripts/bump-tap.sh                        # after gh release create: point lprsrts/homebrew-tap at it
scripts/appstore.sh                        # sandboxed Mac App Store build + signed .pkg in dist/
scripts/check-schema.sh                    # build, then check that the app and the core agree on the scene JSON
scripts/ui-shots.sh [PREFIX]               # render app window states offscreen to target/ui-shots/, without opening the app
```

The app icon is a Liquid Glass icon, `icon/AppIcon.icon`: a double slit with
its fan of interference maxima, the rays at the true angles sin θ = m λ/d. Its
SVG layers come from `icon/layers.py`. `icon/build.sh` writes them, compiles the
icon with `actool` into `icon/compiled` and renders `icon/preview.png`; it needs
Xcode, or open the `.icon` in Icon Composer. The compiled files are checked in,
so `scripts/bundle.sh` works with the command-line tools alone.

The images in this README (the header, the gallery GIFs and the app screenshots)
are served by the website from `site/public/assets/`, so they live in one place.

`scripts/release.sh` builds with the build machine's paths remapped
(`FRINGE_RELEASE=1`), signs the app and `fringe-cli` with the Developer ID
identity in the keychain (hardened runtime, secure timestamp), packs the DMG,
notarizes and staples it, and writes `SHA256SUMS`; tagging and `gh release` are
left to you. After the release is public, `scripts/bump-tap.sh` sets the cask's
version and DMG checksum and the formula's source tarball and checksum in
`lprsrts/homebrew-tap`, taking both checksums from GitHub, and pushes
(`FRINGE_TAP_PUSH=0` only shows the change). Notarization needs a stored `notarytool` profile, once:
`xcrun notarytool store-credentials fringe-notary --apple-id … --team-id …`.
`FRINGE_NOTARIZE=0` does a dry run without it, `FRINGE_SIGN_IDENTITY` and
`FRINGE_NOTARY_PROFILE` override the defaults, and `FRINGE_ALLOW_DIRTY=1` allows
uncommitted changes.

`scripts/appstore.sh` builds the Mac App Store variant: the same bundle, signed
with the App Sandbox entitlements in `appstore/Fringe.entitlements`, an Apple
Distribution identity and the Mac App Store provisioning profile named by
`FRINGE_PROVISIONING_PROFILE`, then packed with `productbuild` and the Mac
Installer Distribution identity. It checks the profile against the identity and
bundle ID first, lists anything missing, and uploads with `altool` only when
`FRINGE_APPSTORE_UPLOAD=1`. `FRINGE_APPSTORE_DRY=1` builds an ad hoc signed
sandboxed app without any of the Apple-side setup.

The app's minimum macOS is tied to the Rust toolchain: Homebrew's `rustc`
ships its standard library built for macOS 26, and the Swift target must not
claim anything older or `ld` warns about every std object.

The crate `fringe_core` builds as an rlib (for the CLI and tests) and a static
library. The Swift package links `target/release/libfringe_core.a` through the
`CFringeCore` module, which wraps `include/fringe_core.h`. The header exists twice
(`include/` and `swift/Sources/CFringeCore/include/`); a test checks that the
copies are identical, so change both.

## Layout

```
src/scene/          scene JSON types, validation, examples, derived values
src/geometry/       shapes, curved contours, inside tests, intersections
src/source/         incident fields: plane wave, angular-spectrum Gaussian, line source, Yee matching
src/special/        Bessel and Hankel functions, Green's function, quadrature
src/solver/fdtd/    FDTD
src/solver/fem/     FEM
src/solver/mom/     MoM
src/solver/         shared solver interface, field grid, cancellation
src/analytic/       Mie, Graf (line source), Airy slab, PEC image references; validation cases and metrics
src/render/         colormaps, field to RGBA, PNG, .npy and .npz export
src/detectors.rs    detector readings (flux, |E|² over a box) from a field on a grid
src/puzzle/         puzzle types, the bundled catalog, rule checks and scoring
puzzles/            the puzzles, one JSON file each (listed by build.rs)
src/problem.rs      a scene compiled for one solve: bodies, incident field, settings per quality
src/check.rs        the check report: issues, cost estimates, derived values
src/types.rs        complex numbers, 2D vectors, rectangles
src/linalg.rs       dense and sparse LU (faer)
src/job.rs, ffi.rs  background jobs and the C ABI
src/lib.rs          crate root and re-exports
src/bin/fringe_cli.rs fringe-cli
include/            C header for the ABI
swift/              SwiftUI app (Swift package "Fringe")
scripts/            build, bundle, release, App Store, tap and schema-check scripts
appstore/           App Sandbox entitlements for the Mac App Store build
icon/               app icon: the Icon Composer document, its layer generator and the compiled icon
site/               fringe.lprsrts.com: the app page, privacy and support (a static Worker), and the README's images
tests/              integration tests; tests/fixtures holds example scenes and Bessel references
```

## License

Fringe is licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
- MIT license ([LICENSE-MIT](LICENSE-MIT))

at your option. Unless you explicitly state otherwise, any contribution you
submit for inclusion in Fringe, as defined in the Apache-2.0 license, is dual
licensed as above, without any additional terms or conditions.

The app and `fringe-cli` link third-party crates; their licenses are collected in
[THIRD-PARTY-LICENSES.txt](THIRD-PARTY-LICENSES.txt), which `scripts/third-party-licenses.py`
writes from `Cargo.lock` and which ships inside the app and the CLI tarball.
