# Beam

Beam draws Gaussian laser beams. You set a waist, a wavelength and a few
optical elements (lenses, mirrors, dielectric interfaces, apertures), and it
propagates the beam through them and renders the intensity along the optical
axis as an image. The physics is a small Rust library; on top of it sit a
command-line exporter and a native macOS app for playing with parameters and
saving high-resolution PNGs. I use it to make cover images, so the colormaps
lean towards looking good as much as reading well.

## Layout

```
src/physics/        beam formulas, complex q, ABCD matrices, optical elements
src/render/         intensity grid (rayon), colormaps, PNG export
src/ffi.rs          C ABI used by the app
src/bin/beam_cli.rs beam-cli
include/beam_core.h C header for the ABI above
swift/              SwiftUI app (Swift package "Beam")
scripts/            build and bundle scripts
tests/              cargo integration tests
```

The crate `beam_core` builds as both an rlib (for the CLI and tests) and a
static library. The Swift package links `target/release/libbeam_core.a`
through the `CBeamCore` module, which wraps `include/beam_core.h`. If you
change the ABI, change the header in both places.

## Building

You need a Rust toolchain and the Xcode command-line tools.

```sh
scripts/build.sh      # cargo build --release --lib, then swift build -c release
scripts/bundle.sh     # the above, then target/Beam.app (ad-hoc signed)
open target/Beam.app
```

`swift build` on its own works too, as long as the static library has been
built first.

The app's minimum macOS is tied to the Rust toolchain: Homebrew's `rustc`
ships its standard library built for macOS 26, and the Swift target must not
claim to support anything older or `ld` warns about every std object. With a
rustup toolchain the floor could be lower.

Tests:

```sh
cargo test
```

## beam-cli

```sh
cargo run --release --bin beam-cli -- --help
```

Print the derived parameters of a beam (Rayleigh range, divergence, peak
intensity):

```sh
beam-cli info --waist 0.5mm --wavelength 632.8nm --power 1
```

Render a beam to PNG:

```sh
beam-cli export -o cover.png --waist 200um --wavelength 532nm \
    --colormap laser_glow --width 3000 --height 3000 --fringe 0.4

beam-cli export -o banner.png --waist 100um --colormap asympton \
    --width 3840 --height 1080 --z-min -20cm --z-max 20cm --x-max 1mm
```

Lengths accept `nm`, `um`, `mm`, `cm` or `m` suffixes; bare numbers are
metres. Without `--z-min`, `--z-max` and `--x-max` the window is
plus or minus 1.5 Rayleigh ranges along the axis and 3 waist radii across
it. Colormaps: `viridis`, `inferno`, `plasma`, `turbo`, `laser_glow`,
`asympton`. The CLI renders a free beam only; optical elements are set up in
the app.

## Physics

Everything is paraxial: the beam is the fundamental Gaussian mode, valid
while the divergence angle stays small (`info` tells you when it doesn't).
For a waist `w0` at wavelength `lambda` in a medium of index `n`:

```
z_R  = pi * n * w0^2 / lambda          Rayleigh range
w(z) = w0 * sqrt(1 + (z/z_R)^2)        beam radius
R(z) = z + z_R^2 / z                   wavefront radius of curvature
psi  = atan(z/z_R)                     Gouy phase
```

All of that is packed into the complex beam parameter `q(z) = z + i z_R`.
An element with ray-transfer matrix `[[A, B], [C, D]]` maps

```
q' = (A q + B) / (C q + D)
```

and free space of length `d` is just `q' = q + d`. So propagation through a
train of elements is: advance `q` to the next element, apply its matrix,
repeat, then read the local `w` and `R` back out of `1/q`. A Gaussian
(soft) aperture is a complex-valued matrix and also scales the power; a hard
aperture only clips power and ignores diffraction from the edge.

The rendered image is `|E(z, x)|^2` on a grid, optionally modulated by the
wavefront phase to show curved fringes, then gamma-corrected and mapped
through a colormap.
