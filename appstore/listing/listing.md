# App Store Connect listing: Fringe: Wave Optics

Paste-ready text for every App Store Connect field of the macOS app
`com.asympton.fringe` (Apple ID 6835856633). Text inside a fenced block is the exact
value; copy it without the fences. Counts come from `python3 appstore/listing/count.py`
(characters are Python `len()`, keywords are UTF-8 bytes, which is what App Store
Connect limits).

| Field | Count | Limit |
|---|---|---|
| Name | 19 | 30 |
| Subtitle | 28 | 30 |
| Promotional Text | 163 | 170 |
| Description | 3167 | 4000 |
| Keywords | 97 bytes | 100 bytes |
| App Review Notes | 1550 | 4000 |
| What's New | 766 | 4000 |

Before submitting, deploy the site (`site/`, see `site/wrangler.jsonc`): the Privacy
Policy, Support and Marketing URLs below point at fringe.lprsrts.com and are 404 until
then.

The version in App Store Connect must match the build's `CFBundleShortVersionString`,
which is 0.3.0 for build 99 (from `Cargo.toml`), not 1.0. Version 0.2.0 (build 88) was
the first submission; 0.3.0 can be added as a new version once 0.2.0 is approved.

## App Information (shared by all versions)

### Name

```text
Fringe: Wave Optics
```

### Subtitle

```text
Full-wave 2D light simulator
```

- **Bundle ID:** com.asympton.fringe
- **SKU:** fringe-mac.
- **Primary language:** English (U.S.)
- **Primary category:** Education
- **Secondary category:** Graphics & Design. The Mac App Store has no Science category;
  the app's other half is making images (high-resolution PNG exports, cover-art
  colormaps, animation frames), which is what Graphics & Design lists. The other
  candidates, Developer Tools, Reference, Productivity and Utilities, describe it less
  well.
- **Content Rights:** "Does your app contain, show, or access third-party content?"
  **No.** Every field image is computed by the app from the user's own scene; the
  ten templates are written by the developer. The app bundles no third-party media.
  Its open-source Rust libraries are code, licensed under MIT/Apache-2.0 and listed in
  `THIRD-PARTY-LICENSES.txt` inside the app; math is set in STIX Two, a font that
  ships with macOS and is not bundled.
- **Age Rating:** 4+ (questionnaire below).
- **License Agreement:** Apple's standard EULA.

### Age Rating questionnaire

Every answer is None or No, which gives 4+ in every region.

| Group | Question | Answer |
|---|---|---|
| In-App Controls | Parental controls | No |
| In-App Controls | Age assurance | No |
| Capabilities | Unrestricted web access | No (the app has no network access) |
| Capabilities | User-generated content shared with others | No |
| Capabilities | Messaging and chat | No |
| Capabilities | Advertising | No |
| Mature Themes | Profanity or crude humor | None |
| Mature Themes | Horror or fear themes | None |
| Mature Themes | Alcohol, tobacco or drug use or references | None |
| Medical or Wellness | Medical or treatment information | None |
| Medical or Wellness | Health or wellness topics | No |
| Sexuality or Nudity | Mature or suggestive themes | None |
| Sexuality or Nudity | Sexual content or nudity | None |
| Sexuality or Nudity | Graphic sexual content and nudity | None |
| Violence | Cartoon or fantasy violence | None |
| Violence | Realistic violence | None |
| Violence | Prolonged graphic or sadistic realistic violence | None |
| Violence | Guns or other weapons | None |
| Chance-Based Activities | Simulated gambling | None |
| Chance-Based Activities | Contests | None |
| Chance-Based Activities | Gambling | No |
| Chance-Based Activities | Loot boxes | No |

"Made for Kids": not selected (the app is not designed for children under 13 in
particular; it suits students and adults).

## App Privacy

- **Privacy Policy URL:** `https://fringe.lprsrts.com/privacy/` (built from `PRIVACY.md`)
- **Data collection:** "Do you or your third-party partners collect data from this
  app?" **No, we do not collect data from this app.** The label then reads
  **Data Not Collected**.

Why that is true, checked in the source:

- The App Store build's entitlements (`appstore/Fringe.entitlements`) are only
  `com.apple.security.app-sandbox` and
  `com.apple.security.files.user-selected.read-write`. There is no
  `com.apple.security.network.client`, so the sandbox blocks every outgoing
  connection.
- No networking code: nothing in `swift/Sources` uses URLSession, Network.framework,
  sockets or URLs of web services, and the Rust core's dependencies (`rayon`, `image`
  with PNG only, `serde`, `serde_json`, `num-complex`, `faer`, `spade`, `ctrlc`,
  `crc32fast`) include no HTTP or socket crate.
- No analytics, crash reporting, advertising or account SDK is linked.
- The only data the app keeps is the current scene and display settings, in its own
  sandboxed preferences (`UserDefaults`, key `fringe.document.v2`) on the Mac.
  Files are read or written only where the user picks them in an Open or Save panel.

## Pricing and Availability

- **Price:** Free (USD 0, tier 0).
- **Availability:** all countries and regions.
- **Distribution:** public on the Mac App Store. Not offered for iPhone or iPad
  ("Make this app available" for Apple silicon iPhone/iPad apps does not apply: it is a
  macOS app).
- **Pre-order:** no.
- **EU Digital Services Act trader status:** set by the account holder under
  Business > Agreements; a trader must show contact details on the EU product page.
  Without a declaration the app cannot be distributed in the EU.

## Export Compliance

`ITSAppUsesNonExemptEncryption` is `false` in the build's `Info.plist`, so App Store
Connect does not ask. If it ever does: the app uses no encryption at all (no network,
no file encryption of its own), so "None of the algorithms mentioned above" / not
subject to export documentation.

## Version information (macOS App, 0.3.0)

### Promotional Text

```text
New in 0.3: twenty puzzles scored by a real solve, gold, silver, copper and aluminium with their true dispersion, point emitters, and detectors that measure power.
```

### Description

```text
Fringe is a 2D wave optics simulator. You build a scene from lenses, slits, prisms, gratings and other elements, and Fringe solves the wave equation for it and draws the field. Focusing, diffraction, interference and scattering come out of the solution; there is no ray tracing.

Place elements in a Gaussian beam or a plane wave and drag them on the canvas. A coarse preview solve follows your edits. Run a final solve before you export.

BUILD A SCENE
• Lenses, slabs, wedges, prisms, cylinders, waveguides, gratings and your own polygons, in any glass or absorbing material, entered as n + ik
• Gold, silver, copper, aluminium, BK7 and fused silica as dispersive Lorentz–Drude materials that are right at every wavelength, or a model of your own from Drude and Lorentz terms
• Mirrors and slits as perfect conductors
• A Gaussian beam or a plane wave at any wavelength and angle; drag the beam's waist and direction on the canvas
• Point emitters with their own strength and phase, with or without the beam
• Detectors that measure the power crossing a line you draw
• Twelve templates to start from: a lens focusing a beam, a photonic nanojet, Young's double slit, Talbot self-imaging, a prism, a concave mirror, a slab waveguide, a tilted glass slab, plane waves scattered by metal and glass cylinders, a pair of silver nanocylinders, and an emitter at a mirror's focus
• Undo and redo for your edits

THREE SOLVERS
• Finite-difference time-domain (FDTD), finite elements (FEM) and the method of moments (MoM), on the same scene
• Each is checked against exact solutions: Mie scattering by a cylinder, the Airy formula for a slab, and the image method for a mirror
• Fringe estimates time and memory before it solves, points out problems in the scene, and lets you cancel a running solve

SEE THE FIELD
• Intensity, magnitude, real part or phase of the total, scattered or incident field
• Animate the field over one optical cycle
• Ten colormaps, including Viridis and Inferno
• Overlays: element outlines, the source, a lens's paraxial focus, a scale bar, a caption and a color legend
• Point at the field to read the intensity and phase there

PUZZLES
• Twenty puzzles in four chapters: steering light, interference, metals, and logic gates made of light
• Each one gives you a few parts and a region to place them in. Check runs a full solve and scores your design against the goal, with up to three stars
• The result is revealed one case at a time, with a short sound made from the light each detector measured. You can turn the sound off in Settings

EXPORT
• PNG images up to 16384 pixels on the long edge, in 16:9, 3:2, 4:3, 1:1, 4:5, 3:4, 9:16 or a ratio of your own
• A numbered PNG sequence over one optical cycle, for animations
• The complex field as a NumPy .npz archive with its coordinates, for your own analysis
• Scenes as plain JSON files you can save, open and share

Fringe works in two dimensions: every element extends without end along z, and the electric field points along z (s-polarized, TMz).

Fringe runs on your Mac with no account and no network access, and collects no data. It is open source under the MIT or Apache 2.0 license.
```

### What's New in This Version

```text
• Puzzles: twenty puzzles in four chapters. Place parts in a marked region and press Check; a full solve scores the design and the result is revealed case by case, with a short sound made from the measured light. Turn the sound off in Settings.
• Dispersive materials: gold, silver, copper, aluminium, BK7 and fused silica as Lorentz–Drude models, or your own model from Drude and Lorentz terms.
• Point emitters with their own strength and phase.
• Detectors that measure the power crossing a line.
• Two new templates: a pair of silver nanocylinders, and an emitter at the focus of a concave mirror.
• The canvas now draws the field on the GPU. Fringe uses almost no CPU while idle, and animating the phase takes a few percent of one core instead of several cores.
```

### Keywords

```text
physics,FDTD,FEM,electromagnetic,diffraction,interference,lens,laser,photonics,Maxwell,scattering
```

No term repeats a word of the name or subtitle (fringe, wave, optics, full, 2D, light,
simulator), none is a plural of another, and none is a trademark or a competitor's name.

- **Support URL:** `https://fringe.lprsrts.com/support/` (built from `SUPPORT.md`; it
  gives an email address and the GitHub issues page, what to include in a report, and
  answers to common questions).
- **Marketing URL:** `https://fringe.lprsrts.com/`
- **Copyright:** `2026 Alper Saritas` (App Store Connect adds the ©; matches
  `NSHumanReadableCopyright` in the build).
- **What's New in This Version:** the block below.
- **Routing App Coverage File:** not applicable (macOS).
- **Build:** 99 (0.3.0).
- **Version release:** "Manually release this version" or "Automatically release",
  as the owner prefers.

### Screenshots

Upload `appstore/screenshots/01-*.png` … `05-*.png` in that order (2880 × 1800, no
alpha, no text overlays; `appstore/screenshots/build.sh` regenerates them).

## App Review Information

- **Sign-in required:** No. There are no accounts; leave the user name and password
  empty.
- **Contact first name / last name / phone / email:** filled in by the owner in
  App Store Connect (Apple does not publish them).
- **Attachment:** none needed.

### App Review Notes

```text
Fringe is a 2D optics simulator. It needs no account, no network and no setup, and it works fully offline.

To try it in 30 seconds:
1. Launch Fringe. It opens a lens focusing a light beam and solves a quick preview at once; the colored field appears in the middle of the window.
2. Choose File > Templates and pick another scene, for example "Young's Double Slit" or "Photonic Nanojet Behind a Dielectric Cylinder". It loads and solves on its own.
3. Change what is shown with the quantity menu in the toolbar (Intensity, Magnitude, Real Part, Phase), or with the Display menu. Press Play in the toolbar to animate the field over one optical cycle.
4. Drag an element on the canvas, or select it in the sidebar and edit it in the inspector on the right; the preview updates.
5. Choose Simulation > Run Final (Command-R) for a full-resolution solve, then File > Export Image (Command-E) and save a PNG. File > Export Field Data writes the complex field as a NumPy .npz file.
6. Click Puzzles in the toolbar (or View > Puzzles, Command-2), open a puzzle, add a part from the sidebar into the dashed region, and press Check. The result is revealed over about two seconds with a soft sound; click or press Space to skip. Sound can be turned off in Fringe > Settings.

The app is sandboxed with only the user-selected file read/write entitlement: it reads and writes files only where the user picks them in an Open or Save panel. The current scene is kept in the app's own preferences between launches. It has no network entitlement and collects no data.
```
