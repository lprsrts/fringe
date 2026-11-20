# Fringe Support

Fringe is made by Alper Saritas. For help, bug reports and suggestions, email
<alper@saritas.io>, or open an issue at <https://github.com/lprsrts/fringe/issues>
(that needs a free GitHub account).

When you report a problem, please include:

- your macOS version and Mac model (Apple menu > About This Mac),
- the Fringe version (Fringe > About Fringe),
- the scene, if it is about a solve or an image: File > Save Scene… writes it as a
  JSON file you can attach to the issue,
- what you expected and what happened instead.

## Common questions

**What does Fringe need?** macOS 26 or later on a Mac with Apple silicon.

**Why is a lens drawn as a flat shape, and why are there no 3D effects?** Fringe
works in two dimensions. Every element extends without end along z, so a lens is a
cylindrical lens, and the electric field points along z (s-polarized, TMz). There is
no Brewster angle in this polarization, and a slit in a metal screen narrower than
half a wavelength lets almost no light through, as it should.

**What is the difference between the preview and Run Final?** The preview is a
coarse solve that follows your edits. Run Final (Simulation > Run Final, ⌘R)
solves at full resolution; use it before you export.

**A solve is slow or refused as too large.** Fringe estimates time and memory before
it solves and shows them in the Simulation inspector. Make the domain smaller, lower
the resolution, or switch to another solver and compare its estimates. MoM is
usually fastest for a few small bodies.

**FDTD says "not fully settled".** The scene has a strong resonance that rings for
longer than FDTD runs. The field is often still close; FEM or MoM give the
steady-state answer directly.

**Which solver should I trust?** All three are checked against exact solutions
(Mie scattering, the Airy formula for a slab, the image method for a mirror). Where
it applies, MoM is the most accurate; the measured errors are on the
[Validation](https://github.com/lprsrts/fringe/wiki/Validation) page of the wiki.

**How do I read exported field data?** File > Export Field Data writes a NumPy
`.npz` archive:

```python
import json, numpy as np
f = np.load("fringe-fdtd-total.npz")
field, x, y = f["field"], f["x"], f["y"]   # (ny, nx) complex128; x and y in µm, y[0] = top row
info = json.loads(f["info"].item())        # grid, solver and run info
```

**Where are my settings kept?** In the app's own preferences on your Mac. Fringe
collects no data and never connects to the internet; see the
[privacy policy](PRIVACY.md).
