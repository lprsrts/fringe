//! The default scene and the named examples (spec §3.4, §3.5).

use crate::solver::Method;

use super::types::*;

pub struct ExampleInfo {
    pub name: &'static str,
    pub title: &'static str,
    pub method: Method,
    /// Suggested display: quantity and colormap.
    pub quantity: &'static str,
    pub colormap: &'static str,
}

pub const EXAMPLES: [ExampleInfo; 10] = [
    ex("lens", "Biconvex lens focusing a Gaussian beam", Method::Fdtd),
    ex("nanojet", "Photonic nanojet behind a dielectric cylinder", Method::Fdtd),
    ex("mie_pec", "Plane wave on a PEC cylinder", Method::Mom),
    ex("mie_dielectric", "Plane wave on a glass cylinder", Method::Fem),
    ExampleInfo {
        name: "double_slit",
        title: "Young's double slit",
        method: Method::Mom,
        quantity: "real",
        colormap: "rdbu",
    },
    ex("talbot", "Talbot self-imaging behind a grating", Method::Fdtd),
    ex("prism", "Gaussian beam refracted by a prism", Method::Fem),
    ex("mirror", "Concave mirror focusing a Gaussian beam", Method::Mom),
    ex("waveguide", "Gaussian beam coupled into a slab waveguide", Method::Fem),
    ex("slab", "Gaussian beam through a glass slab at 30°", Method::Fdtd),
];

const fn ex(name: &'static str, title: &'static str, method: Method) -> ExampleInfo {
    ExampleInfo { name, title, method, quantity: "intensity", colormap: "inferno" }
}

fn scene(source: Source, elements: Vec<Element>, domain: [f64; 4], method: Method) -> Scene {
    Scene {
        version: SCHEMA_VERSION,
        wavelength_um: 1.0,
        background: Background { n: 1.0 },
        polarization: Polarization::Ez,
        source,
        elements,
        domain: Domain {
            x_min_um: domain[0],
            x_max_um: domain[1],
            y_min_um: domain[2],
            y_max_um: domain[3],
            pml_wl: 1.0,
        },
        solver: SolverSettings { method, ..Default::default() },
    }
}

fn plane_wave() -> Source {
    Source::PlaneWave { angle_deg: 0.0, amplitude: 1.0, phase_deg: 0.0 }
}

fn gaussian(w0: f64, x: f64, y: f64, angle_deg: f64) -> Source {
    Source::GaussianBeam { waist_um: w0, waist_x_um: x, waist_y_um: y, angle_deg, amplitude: 1.0, phase_deg: 0.0 }
}

fn element(id: &str, name: &str, material: Material, x: f64, y: f64, shape: Shape) -> Element {
    Element {
        id: id.into(),
        name: name.into(),
        enabled: true,
        material,
        x_um: x,
        y_um: y,
        rotation_deg: 0.0,
        shape,
    }
}

fn glass(n: f64) -> Material {
    Material::Dielectric { n, k: 0.0 }
}

/// The default scene: a biconvex lens focusing a Gaussian beam.
pub fn default() -> Scene {
    scene(
        gaussian(3.0, -6.0, 0.0, 0.0),
        vec![element(
            "lens-1",
            "Lens",
            glass(1.5),
            -4.0,
            0.0,
            Shape::Lens { r1_um: Some(12.0), r2_um: Some(-12.0), center_thickness_um: 3.0, aperture_um: 10.0 },
        )],
        [-12.0, 20.0, -9.0, 9.0],
        Method::Fdtd,
    )
}

pub fn example(name: &str) -> Option<Scene> {
    let cylinder = |id: &str, name: &str, m: Material, x: f64, r: f64| {
        element(id, name, m, x, 0.0, Shape::Cylinder { radius_um: r })
    };
    Some(match name {
        "lens" => default(),
        "nanojet" => scene(
            plane_wave(),
            vec![cylinder("cylinder-1", "Cylinder", glass(1.6), -2.0, 1.5)],
            [-8.0, 12.0, -5.625, 5.625],
            Method::Fdtd,
        ),
        "mie_pec" => scene(
            plane_wave(),
            vec![cylinder("cylinder-1", "PEC cylinder", Material::Pec, 0.0, 1.0)],
            [-6.0, 10.0, -4.5, 4.5],
            Method::Mom,
        ),
        "mie_dielectric" => scene(
            plane_wave(),
            vec![cylinder("cylinder-1", "Glass cylinder", glass(1.5), 0.0, 1.0)],
            [-6.0, 10.0, -4.5, 4.5],
            Method::Fem,
        ),
        "double_slit" => scene(
            plane_wave(),
            vec![element(
                "slits-1",
                "Double slit",
                Material::Pec,
                -6.0,
                0.0,
                Shape::Slits { count: 2, slit_width_um: 1.0, pitch_um: 4.0, screen_height_um: 16.0, thickness_um: 0.5 },
            )],
            [-10.0, 22.0, -9.0, 9.0],
            Method::Mom,
        ),
        "talbot" => scene(
            plane_wave(),
            vec![element(
                "grating-1",
                "Grating",
                glass(1.5),
                -8.0,
                0.0,
                Shape::Grating { period_um: 2.0, fill_factor: 0.5, depth_um: 1.0, count: 7, substrate_um: 0.0 },
            )],
            [-10.0, 22.0, -9.0, 9.0],
            Method::Fdtd,
        ),
        "prism" => scene(
            gaussian(2.0, -7.0, -1.0, 10.0),
            vec![element("prism-1", "Prism", glass(1.5168), 0.0, 0.0, Shape::Prism { base_um: 8.0, apex_deg: 60.0 })],
            [-12.0, 12.0, -6.75, 6.75],
            Method::Fem,
        ),
        // The spec's [−10, 10] × [−5.625, 5.625] domain cuts the 12 µm aperture; this
        // keeps the mirror and the 16:9 shape with a larger domain.
        "mirror" => scene(
            gaussian(2.5, -6.0, 0.0, 0.0),
            vec![element(
                "mirror-1",
                "Concave mirror",
                Material::Pec,
                8.0,
                0.0,
                Shape::Mirror { aperture_um: 12.0, thickness_um: 0.5, radius_um: Some(20.0) },
            )],
            [-12.0, 12.0, -6.75, 6.75],
            Method::Mom,
        ),
        "waveguide" => scene(
            gaussian(0.6, -3.0, 0.0, 0.0),
            vec![element(
                "waveguide-1",
                "Waveguide",
                glass(2.0),
                4.0,
                0.0,
                Shape::Waveguide { width_um: 0.8, length_um: 14.0 },
            )],
            [-6.0, 12.0, -5.0625, 5.0625],
            Method::Fem,
        ),
        "slab" => scene(
            gaussian(2.5, -1.5, 0.0, 30.0),
            vec![element(
                "slab-1",
                "Slab",
                glass(1.5),
                0.0,
                0.0,
                Shape::Slab { thickness_um: 3.0, height_um: 16.0 },
            )],
            [-8.0, 8.0, -9.0, 9.0],
            Method::Fdtd,
        ),
        _ => return None,
    })
}

pub fn info(name: &str) -> Option<&'static ExampleInfo> {
    EXAMPLES.iter().find(|e| e.name == name)
}
