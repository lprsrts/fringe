# Fringe

![Interference fringes behind a double slit, solved with Fringe](https://fringe.lprsrts.com/assets/social.png)

Fringe simulates light as a wave. You put lenses, prisms, mirrors, slits,
gratings and waveguides in a beam, and it solves Maxwell's equations in 2D for
one polarisation (Ez) and draws the field: as intensity, magnitude, the real
part or phase, or animated over one optical cycle. There are three solvers
(FDTD, FEM and MoM), checked against textbook solutions and against each other.

You can use it three ways:

- **in your browser** at [fringe.lprsrts.com/web](https://fringe.lprsrts.com/web/),
  nothing to install;
- **as a Mac app**, with a simulator for building your own scenes, image export,
  and 20 puzzles where you steer light, set up interference and build logic
  gates out of it;
- **as a command-line tool** on macOS, Linux and Windows, which solves scene
  files and writes PNG and NumPy output.

I use it to make cover images, so some colormaps (`laser_glow`, `asympton`,
`spectral_glow`) are there to look good as much as to read well.

<table>
<tr>
<td width="50%"><img src="https://fringe.lprsrts.com/assets/gallery/crystal.gif" width="320" alt="Light following a channel through a grid of rods as the rods are removed one at a time"></td>
<td width="50%"><img src="https://fringe.lprsrts.com/assets/gallery/wgm_adddrop.gif" width="320" alt="A glass disk between two waveguides switching light from one waveguide to the other as the wavelength changes"></td>
</tr>
<tr>
<td>Light can't cross this grid of rods, so it follows the gap where rods are missing.</td>
<td>A 1% change in wavelength sends the light around the disk and out the other waveguide.</td>
</tr>
<tr>
<td><img src="https://fringe.lprsrts.com/assets/gallery/phc_z_rainbow.gif" width="320" alt="A beam sweeping through the visible spectrum into a rod lattice with a Z-shaped channel"></td>
<td><img src="https://fringe.lprsrts.com/assets/gallery/mandala.gif" width="320" alt="A point source inside three rings of glass rods, two of them turning"></td>
</tr>
<tr>
<td>A similar grid with a Z-shaped channel, from violet to red. Only green to gold light takes the corners.</td>
<td>One point of light inside three rings of glass rods, two of them turning.</td>
</tr>
</table>

Every frame above is its own solve. More about these in the
[gallery](https://github.com/lprsrts/fringe/wiki/Gallery).

![The Fringe window in simulator mode: a lens focusing a Gaussian beam onto two detectors, with their readings and a profile plot](https://fringe.lprsrts.com/assets/simulator.jpg)

![The Fringe window in puzzle mode: an XOR gate built from one glass slab, with its truth table and contrast chart](https://fringe.lprsrts.com/assets/puzzle.jpg)

## Install

The Mac app needs macOS 26 or later on Apple silicon. With
[Homebrew](https://brew.sh):

```sh
brew install --cask lprsrts/tap/fringe     # the app
brew install lprsrts/tap/fringe-cli        # the command-line tool
```

Or download the DMG from [Releases](https://github.com/lprsrts/fringe/releases).
It's signed and notarized, and works offline.

`fringe-cli` also runs on Linux and Windows: from 0.4.0, each release has
archives for both. See [Installation](https://github.com/lprsrts/fringe/wiki/Installation)
for the details.

## Quick start

```sh
fringe-cli example                              # list the example scenes
fringe-cli example lens | fringe-cli solve - -o lens.png
```

Scenes are JSON files; the app, the command-line tool and the browser all read
the same ones.

## More

Everything else is in the [wiki](https://github.com/lprsrts/fringe/wiki):

- [Physics and conventions](https://github.com/lprsrts/fringe/wiki/Physics-and-conventions): what is solved, units, materials, sources, detectors
- [Solvers](https://github.com/lprsrts/fringe/wiki/Solvers): how the three differ, their limits, timings
- [Validation](https://github.com/lprsrts/fringe/wiki/Validation): the accuracy against analytic solutions
- [Command-line tool](https://github.com/lprsrts/fringe/wiki/Command-line-tool): every command, colormaps, exit codes, field export
- [Browser viewer](https://github.com/lprsrts/fringe/wiki/Browser-viewer): share links and embedding a simulation in a page
- [Puzzles](https://github.com/lprsrts/fringe/wiki/Puzzles) and [making your own](https://github.com/lprsrts/fringe/wiki/Puzzle-authoring)
- [Building from source](https://github.com/lprsrts/fringe/wiki/Building-from-source) and [releasing](https://github.com/lprsrts/fringe/wiki/Releasing)

Bugs and results that look wrong go in the [issues](https://github.com/lprsrts/fringe/issues).

## Citing

If you use Fringe in a paper, a thesis or course material, please cite it.
[CITATION.cff](CITATION.cff) has the details, and GitHub's "Cite this repository"
button (in the sidebar) turns it into APA or BibTeX:

```bibtex
@software{saritas_fringe,
  author  = {Sarıtaş, Alper},
  title   = {Fringe: full-wave 2D optics simulator},
  year    = {2026},
  url     = {https://github.com/lprsrts/fringe}
}
```

Please add the version you used, since results can change between releases.

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
