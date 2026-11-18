//! Material evaluation at the scene wavelength, and the preset library of
//! dispersive materials.
//!
//! A dispersive material is `ε(ω) = ε∞ + Σ poles` with ħω = 1.239841984 / λ0[µm]
//! eV and the e^{+jωt} convention, so absorption is ε″ > 0 in ε = ε′ − jε″:
//!
//! - Drude: `−ωp² / (ω² − jγω)`
//! - Lorentz: `Δε·ω0² / (ω0² − ω² + jγω)`
//!
//! A solve evaluates the material once, at λ0, to a complex ε and the index
//! n − jk with Re n ≥ 0 and Im n ≤ 0.

use serde::Serialize;
use serde_json::{json, Value};

use crate::types::C64;

use super::types::{Material, Pole};

/// hc in eV·µm: ħω [eV] = HC_EV_UM / λ [µm].
pub const HC_EV_UM: f64 = 1.239_841_984;

/// Most poles a dispersive material may have.
pub const MAX_POLES: usize = 8;

/// Photon energy in eV at vacuum wavelength `lambda0_um`.
pub fn photon_ev(lambda0_um: f64) -> f64 {
    HC_EV_UM / lambda0_um
}

impl Pole {
    /// The pole's contribution to ε at photon energy `w` (eV).
    pub fn eps(&self, w: f64) -> C64 {
        match *self {
            Pole::Drude { plasma_ev: wp, gamma_ev: g } => -wp * wp / C64::new(w * w, -g * w),
            Pole::Lorentz { strength, resonance_ev: w0, gamma_ev: g } => {
                strength * w0 * w0 / C64::new(w0 * w0 - w * w, g * w)
            }
        }
    }
}

/// ε∞ + Σ poles at vacuum wavelength `lambda0_um`.
pub fn dispersive_eps(eps_inf: f64, poles: &[Pole], lambda0_um: f64) -> C64 {
    let w = photon_ev(lambda0_um);
    poles.iter().fold(C64::new(eps_inf, 0.0), |e, p| e + p.eps(w))
}

/// The index n − jk with ε = n², on the branch Re n ≥ 0, Im n ≤ 0 (for a
/// passive ε, Im ε ≤ 0, this is the principal root; a lossless metal, ε < 0
/// real, gets n = −j√|ε|).
pub fn index_from_eps(eps: C64) -> C64 {
    let n = eps.sqrt();
    C64::new(n.re.abs(), -n.im.abs())
}

impl Material {
    /// Relative permittivity at `lambda0_um`; `None` for PEC.
    pub fn eps_at(&self, lambda0_um: f64) -> Option<C64> {
        match self {
            Material::Pec => None,
            Material::Dielectric { n, k } => {
                let nc = C64::new(*n, -k);
                Some(nc * nc)
            }
            Material::Dispersive { eps_inf, poles, .. } => Some(dispersive_eps(*eps_inf, poles, lambda0_um)),
        }
    }

    /// Complex index n − jk at `lambda0_um`; `None` for PEC.
    pub fn index_at(&self, lambda0_um: f64) -> Option<C64> {
        match self {
            Material::Pec => None,
            Material::Dielectric { n, k } => Some(C64::new(*n, -k)),
            Material::Dispersive { .. } => self.eps_at(lambda0_um).map(index_from_eps),
        }
    }

    pub fn is_dispersive(&self) -> bool {
        matches!(self, Material::Dispersive { .. })
    }
}

/// One entry of the preset library.
#[derive(Clone, Debug, Serialize)]
pub struct Preset {
    pub id: &'static str,
    pub name: &'static str,
    /// "metal" or "glass".
    pub kind: &'static str,
    pub source: &'static str,
    /// Wavelength range of the fit or formula, µm.
    pub range_um: [f64; 2],
    pub material: Material,
}

const RAKIC: &str = "Rakić et al., Appl. Opt. 37, 5271 (1998), Lorentz–Drude fit";

/// `x` to six significant digits, far below the accuracy of any fit here, so
/// that preset numbers read and round-trip as short decimals.
fn sig6(x: f64) -> f64 {
    format!("{x:.5e}").parse().unwrap_or(x)
}

/// A Rakić Lorentz–Drude fit, written as in the paper:
/// `ε = 1 − f0 ωp² / (ω(ω − jΓ0)) + Σ_j f_j ωp² / (ω_j² − ω² + jωΓ_j)`.
/// The Drude term has plasma energy √f0·ωp, and a Lorentz term Δε = f_j ωp²/ω_j².
fn rakic(id: &'static str, wp: f64, f0: f64, g0: f64, terms: &[(f64, f64, f64)]) -> Material {
    let mut poles = vec![Pole::Drude { plasma_ev: sig6(f0.sqrt() * wp), gamma_ev: g0 }];
    poles.extend(terms.iter().map(|&(f, g, w0)| Pole::Lorentz {
        strength: sig6(f * wp * wp / (w0 * w0)),
        resonance_ev: w0,
        gamma_ev: g,
    }));
    Material::Dispersive { preset: Some(id.into()), eps_inf: 1.0, poles }
}

/// A Sellmeier formula `n² = 1 + Σ B λ²/(λ² − C)` (C in µm²) as lossless
/// Lorentz poles: Δε = B and ħω0 = hc/√C.
fn sellmeier(id: &'static str, terms: &[(f64, f64)]) -> Material {
    let poles = terms
        .iter()
        .map(|&(b, c)| Pole::Lorentz { strength: b, resonance_ev: sig6(HC_EV_UM / c.sqrt()), gamma_ev: 0.0 })
        .collect();
    Material::Dispersive { preset: Some(id.into()), eps_inf: 1.0, poles }
}

/// The preset library. The metal parameters are Table 2 of Rakić et al. (ωp,
/// then (f_j, Γ_j, ω_j) in eV); the glasses are the Schott N-BK7 and the
/// Malitson (1965) fused silica Sellmeier coefficients.
pub fn presets() -> Vec<Preset> {
    let metal = |id, name, range_um, material| Preset { id, name, kind: "metal", source: RAKIC, range_um, material };
    vec![
        metal(
            "gold",
            "Gold",
            [0.248, 6.2],
            rakic(
                "gold",
                9.03,
                0.760,
                0.053,
                &[(0.024, 0.241, 0.415), (0.010, 0.345, 0.830), (0.071, 0.870, 2.969), (0.601, 2.494, 4.304), (4.384, 2.214, 13.32)],
            ),
        ),
        metal(
            "silver",
            "Silver",
            [0.248, 12.4],
            rakic(
                "silver",
                9.01,
                0.845,
                0.048,
                &[(0.065, 3.886, 0.816), (0.124, 0.452, 4.481), (0.011, 0.065, 8.185), (0.840, 0.916, 9.083), (5.646, 2.419, 20.29)],
            ),
        ),
        metal(
            "aluminium",
            "Aluminium",
            [0.062, 248.0],
            rakic(
                "aluminium",
                14.98,
                0.523,
                0.047,
                &[(0.227, 0.333, 0.162), (0.050, 0.312, 1.544), (0.166, 1.351, 1.808), (0.030, 3.382, 3.473)],
            ),
        ),
        metal(
            "copper",
            "Copper",
            [0.207, 12.4],
            rakic(
                "copper",
                10.83,
                0.575,
                0.030,
                &[(0.061, 0.378, 0.291), (0.104, 1.056, 2.957), (0.723, 3.213, 5.300), (0.638, 4.305, 11.18)],
            ),
        ),
        Preset {
            id: "bk7",
            name: "BK7 glass",
            kind: "glass",
            source: "Schott N-BK7 Sellmeier coefficients, as lossless Lorentz poles",
            range_um: [0.3, 2.5],
            material: sellmeier(
                "bk7",
                &[(1.039_612_12, 0.006_000_698_67), (0.231_792_344, 0.020_017_914_4), (1.010_469_45, 103.560_653)],
            ),
        },
        Preset {
            id: "fused_silica",
            name: "Fused silica",
            kind: "glass",
            source: "Malitson, J. Opt. Soc. Am. 55, 1205 (1965), Sellmeier coefficients as lossless Lorentz poles",
            range_um: [0.21, 3.71],
            material: sellmeier(
                "fused_silica",
                &[(0.696_166_3, 0.068_404_3f64.powi(2)), (0.407_942_6, 0.116_241_4f64.powi(2)), (0.897_479_4, 9.896_161f64.powi(2))],
            ),
        },
    ]
}

/// The material of preset `id`.
pub fn preset(id: &str) -> Option<Material> {
    presets().into_iter().find(|p| p.id == id).map(|p| p.material)
}

/// The library as JSON for the app and the CLI: `[{id, name, kind, source,
/// range_um, material}]`, `material` in scene JSON form.
pub fn presets_json() -> Value {
    Value::Array(
        presets()
            .into_iter()
            .map(|p| {
                json!({
                    "id": p.id, "name": p.name, "kind": p.kind, "source": p.source,
                    "range_um": p.range_um, "material": p.material,
                })
            })
            .collect(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn nk(id: &str, lambda: f64) -> (f64, f64) {
        let n = preset(id).unwrap().index_at(lambda).unwrap();
        (n.re, -n.im)
    }

    /// The fits reproduce the n, k that refractiveindex.info tabulates from the
    /// Rakić LD model (rounded there to five digits).
    #[test]
    fn metals_match_the_rakic_tables() {
        let table: [(&str, f64, f64, f64); 16] = [
            ("gold", 0.40285, 1.4112, 1.7490),
            ("gold", 0.54779, 0.50606, 2.3486),
            ("gold", 0.69821, 0.25791, 3.7028),
            ("gold", 0.99662, 0.25469, 5.9622),
            ("silver", 0.40535, 0.15377, 1.8860),
            ("silver", 0.54437, 0.13381, 3.1276),
            ("silver", 0.70289, 0.15482, 4.3257),
            ("silver", 1.0013, 0.21994, 6.4341),
            ("copper", 0.39916, 1.2496, 2.2459),
            ("copper", 0.55477, 0.53052, 2.8106),
            ("copper", 0.69567, 0.27955, 4.0869),
            ("copper", 1.0075, 0.25557, 6.5372),
            ("aluminium", 0.40143, 0.45683, 4.7236),
            ("aluminium", 0.55033, 0.96708, 6.4617),
            ("aluminium", 0.70015, 1.6945, 7.9618),
            ("aluminium", 1.0005, 1.4765, 9.2887),
        ];
        for (id, lambda, n, k) in table {
            let (a, b) = nk(id, lambda);
            let err = C64::new(a - n, b - k).norm() / C64::new(n, k).norm();
            assert!(err < 3e-4, "{id} at {lambda} µm: {a:.4} + {b:.4}i, table {n} + {k}i ({err:.1e})");
        }
    }

    /// Against Johnson & Christy (1972). The Rakić fits are to other data sets
    /// as well, and differ from J&C by up to 13 % in k (silver) and 0.18 in n,
    /// so the tolerance is |Δk| ≤ 15 % and |Δn| ≤ 0.2. Away from the interband
    /// edges (gold near 0.5 µm, copper near 0.55 µm), where the fits deviate more.
    #[test]
    fn metals_are_close_to_johnson_christy() {
        let table: [(&str, f64, f64, f64); 12] = [
            ("gold", 0.4133, 1.46, 1.958),
            ("gold", 0.6168, 0.21, 3.272),
            ("gold", 0.7045, 0.13, 4.103),
            ("gold", 0.9840, 0.22, 6.350),
            ("silver", 0.4133, 0.05, 2.275),
            ("silver", 0.6168, 0.06, 4.152),
            ("silver", 0.7045, 0.04, 4.838),
            ("silver", 0.9840, 0.04, 6.992),
            ("copper", 0.4133, 1.28, 2.207),
            ("copper", 0.6168, 0.30, 3.205),
            ("copper", 0.7045, 0.21, 4.205),
            ("copper", 0.9840, 0.32, 6.421),
        ];
        for (id, lambda, n, k) in table {
            let (a, b) = nk(id, lambda);
            assert!((b - k).abs() <= 0.15 * k && (a - n).abs() <= 0.2, "{id} at {lambda} µm: {a:.3} + {b:.3}i, J&C {n} + {k}i");
        }
    }

    #[test]
    fn glasses_match_their_sellmeier_index() {
        // n_d at the helium d line, 587.56 nm.
        let (n, k) = nk("bk7", 0.58756);
        assert!((n - 1.5168).abs() < 1e-4 && k == 0.0, "{n} {k}");
        let (n, k) = nk("fused_silica", 0.58756);
        assert!((n - 1.4585).abs() < 1e-4 && k == 0.0, "{n} {k}");
        let (n, _) = nk("bk7", 1.064);
        assert!((n - 1.5066).abs() < 2e-4, "{n}");
    }

    #[test]
    fn poles_are_passive_and_branch_is_decaying() {
        for p in presets() {
            for l in [0.3, 0.45, 0.6, 0.9, 1.5] {
                let eps = p.material.eps_at(l).unwrap();
                assert!(eps.im <= 0.0, "{} at {l}: {eps}", p.id);
                let n = p.material.index_at(l).unwrap();
                assert!(n.re >= 0.0 && n.im <= 0.0);
                assert!((n * n - eps).norm() < 1e-12 * eps.norm().max(1.0));
            }
        }
        // A lossless Drude metal has a purely imaginary, decaying index.
        let m = Material::Dispersive { preset: None, eps_inf: 1.0, poles: vec![Pole::Drude { plasma_ev: 9.0, gamma_ev: 0.0 }] };
        let n = m.index_at(0.5).unwrap();
        assert!(n.re == 0.0 && n.im < 0.0, "{n}");
    }
}
