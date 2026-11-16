//! `beam-cli`: render a Gaussian beam to PNG, or print its parameters.
//!
//! Argument parsing is hand-rolled to keep the crate free of a CLI dependency.

use std::env;
use std::path::PathBuf;
use std::process;

use beam_core::physics::{GaussianBeam, OpticalTrain};
use beam_core::render::colormap::{Colormap, RenderStyle};
use beam_core::render::export::export_beam_to_png_file;

#[derive(Debug)]
enum Subcommand {
    Export(ExportConfig),
    Info(InfoConfig),
    Help,
    Version,
}

#[derive(Debug)]
struct ExportConfig {
    output: PathBuf,
    waist: f64,
    wavelength: f64,
    z: f64,
    colormap: String,
    width: u32,
    height: u32,
    gamma: f64,
    fringe_modulation: f64,
    z_min: Option<f64>,
    z_max: Option<f64>,
    x_max: Option<f64>,
}

#[derive(Debug)]
struct InfoConfig {
    waist: f64,
    wavelength: f64,
    n: f64,
    power: f64,
}

/// Parses a length with an optional `nm`, `um`/`µm`, `mm`, `cm` or `m` suffix into metres.
/// A bare number is taken as metres.
fn parse_metric(s: &str) -> Result<f64, String> {
    let s = s.trim();
    if s.is_empty() {
        return Err("empty value".to_string());
    }
    let (val_str, multiplier) = if let Some(stripped) = s.strip_suffix("nm") {
        (stripped, 1e-9)
    } else if let Some(stripped) = s.strip_suffix("um").or_else(|| s.strip_suffix("µm")) {
        (stripped, 1e-6)
    } else if let Some(stripped) = s.strip_suffix("mm") {
        (stripped, 1e-3)
    } else if let Some(stripped) = s.strip_suffix("cm") {
        (stripped, 1e-2)
    } else if let Some(stripped) = s.strip_suffix("m") {
        (stripped, 1.0)
    } else {
        (s, 1.0)
    };

    let val = val_str
        .trim()
        .parse::<f64>()
        .map_err(|e| format!("invalid number: {}", e))?;
    if !val.is_finite() {
        return Err("value must be finite".to_string());
    }
    Ok(val * multiplier)
}

fn parse_args<I: Iterator<Item = String>>(mut args: I) -> Result<Subcommand, String> {
    args.next();
    let first = match args.next() {
        Some(arg) => arg,
        None => return Ok(Subcommand::Help),
    };

    match first.as_str() {
        "--help" | "-h" => Ok(Subcommand::Help),
        "--version" | "-V" => Ok(Subcommand::Version),
        "help" => Ok(Subcommand::Help),
        "info" => parse_info_args(args),
        "export" => parse_export_args(args, true),
        other if other.starts_with('-') => {
            // Bare flags with no subcommand mean `export`, defaulting to cover.png.
            let mut reconstructed = vec![other.to_string()];
            reconstructed.extend(args);
            parse_export_args(reconstructed.into_iter(), false)
        }
        unknown => Err(format!("unknown command '{}'", unknown)),
    }
}

fn parse_export_args<I: Iterator<Item = String>>(
    args: I,
    strict_output: bool,
) -> Result<Subcommand, String> {
    let mut output: Option<PathBuf> = None;
    let mut waist: f64 = 0.5e-3;
    let mut wavelength: f64 = 632.8e-9; // He-Ne
    let mut z: f64 = 0.0;
    let mut colormap = "viridis".to_string();
    let mut width: u32 = 1920;
    let mut height: u32 = 1080;
    let mut gamma: f64 = 1.0;
    let mut fringe_modulation: f64 = 0.0;
    let mut z_min: Option<f64> = None;
    let mut z_max: Option<f64> = None;
    let mut x_max: Option<f64> = None;

    let args_vec: Vec<String> = args.collect();
    let mut i = 0;
    while i < args_vec.len() {
        let flag = &args_vec[i];
        match flag.as_str() {
            "--help" | "-h" => return Ok(Subcommand::Help),
            "--output" | "-o" => {
                i += 1;
                if i >= args_vec.len() {
                    return Err("--output needs a value".to_string());
                }
                output = Some(PathBuf::from(&args_vec[i]));
            }
            "--waist" | "--w0" => {
                i += 1;
                if i >= args_vec.len() {
                    return Err("--waist needs a value".to_string());
                }
                let w = parse_metric(&args_vec[i])?;
                if w <= 0.0 {
                    return Err("--waist must be positive".to_string());
                }
                waist = w;
            }
            "--wavelength" | "--lambda" => {
                i += 1;
                if i >= args_vec.len() {
                    return Err("--wavelength needs a value".to_string());
                }
                let l = parse_metric(&args_vec[i])?;
                if l <= 0.0 {
                    return Err("--wavelength must be positive".to_string());
                }
                wavelength = l;
            }
            "--z" | "--z0" => {
                i += 1;
                if i >= args_vec.len() {
                    return Err("--z needs a value".to_string());
                }
                z = parse_metric(&args_vec[i])?;
            }
            "--colormap" => {
                i += 1;
                if i >= args_vec.len() {
                    return Err("--colormap needs a value".to_string());
                }
                let cm = args_vec[i].to_lowercase();
                match cm.as_str() {
                    "viridis" | "inferno" | "plasma" | "turbo" | "laser_glow" | "asympton" => {
                        colormap = cm;
                    }
                    _ => return Err(format!("unknown colormap '{}'", cm)),
                }
            }
            "--width" => {
                i += 1;
                if i >= args_vec.len() {
                    return Err("--width needs a value".to_string());
                }
                let w: u32 = args_vec[i]
                    .parse()
                    .map_err(|_| "invalid --width".to_string())?;
                if w == 0 {
                    return Err("--width must be positive".to_string());
                }
                if w > beam_core::render::MAX_DIMENSION {
                    return Err(format!(
                        "--width must be at most {}",
                        beam_core::render::MAX_DIMENSION
                    ));
                }
                width = w;
            }
            "--height" => {
                i += 1;
                if i >= args_vec.len() {
                    return Err("--height needs a value".to_string());
                }
                let h: u32 = args_vec[i]
                    .parse()
                    .map_err(|_| "invalid --height".to_string())?;
                if h == 0 {
                    return Err("--height must be positive".to_string());
                }
                if h > beam_core::render::MAX_DIMENSION {
                    return Err(format!(
                        "--height must be at most {}",
                        beam_core::render::MAX_DIMENSION
                    ));
                }
                height = h;
            }
            "--gamma" => {
                i += 1;
                if i >= args_vec.len() {
                    return Err("--gamma needs a value".to_string());
                }
                let g: f64 = args_vec[i]
                    .parse()
                    .map_err(|e| format!("invalid --gamma: {}", e))?;
                if !g.is_finite() || g <= 0.0 {
                    return Err("--gamma must be a positive number".to_string());
                }
                gamma = g;
            }
            "--fringe" | "--fringe-modulation" => {
                i += 1;
                if i >= args_vec.len() {
                    return Err("--fringe needs a value".to_string());
                }
                let f: f64 = args_vec[i]
                    .parse()
                    .map_err(|e| format!("invalid --fringe: {}", e))?;
                if f.is_nan() {
                    return Err("invalid --fringe: NaN".to_string());
                }
                fringe_modulation = f.clamp(0.0, 1.0);
            }
            "--z-min" => {
                i += 1;
                if i >= args_vec.len() {
                    return Err("--z-min needs a value".to_string());
                }
                z_min = Some(parse_metric(&args_vec[i])?);
            }
            "--z-max" => {
                i += 1;
                if i >= args_vec.len() {
                    return Err("--z-max needs a value".to_string());
                }
                z_max = Some(parse_metric(&args_vec[i])?);
            }
            "--x-max" => {
                i += 1;
                if i >= args_vec.len() {
                    return Err("--x-max needs a value".to_string());
                }
                x_max = Some(parse_metric(&args_vec[i])?);
            }
            other => return Err(format!("unknown option '{}'", other)),
        }
        i += 1;
    }

    if x_max.is_some_and(|x| x <= 0.0) {
        return Err("--x-max must be positive".to_string());
    }
    if let (Some(lo), Some(hi)) = (z_min, z_max) {
        if lo >= hi {
            return Err("--z-min must be less than --z-max".to_string());
        }
    }

    let final_output = match output {
        Some(p) => p,
        None => {
            if strict_output {
                return Err("export needs --output".to_string());
            } else {
                PathBuf::from("cover.png")
            }
        }
    };

    Ok(Subcommand::Export(ExportConfig {
        output: final_output,
        waist,
        wavelength,
        z,
        colormap,
        width,
        height,
        gamma,
        fringe_modulation,
        z_min,
        z_max,
        x_max,
    }))
}

fn parse_info_args<I: Iterator<Item = String>>(args: I) -> Result<Subcommand, String> {
    let mut waist: f64 = 0.5e-3;
    let mut wavelength: f64 = 632.8e-9;
    let mut n: f64 = 1.0;
    let mut power: f64 = 1.0;

    let args_vec: Vec<String> = args.collect();
    let mut i = 0;
    while i < args_vec.len() {
        match args_vec[i].as_str() {
            "--help" | "-h" => return Ok(Subcommand::Help),
            "--waist" | "--w0" => {
                i += 1;
                if i >= args_vec.len() {
                    return Err("--waist needs a value".to_string());
                }
                waist = parse_metric(&args_vec[i])?;
            }
            "--wavelength" | "--lambda" => {
                i += 1;
                if i >= args_vec.len() {
                    return Err("--wavelength needs a value".to_string());
                }
                wavelength = parse_metric(&args_vec[i])?;
            }
            "--n" | "--refractive-index" => {
                i += 1;
                if i >= args_vec.len() {
                    return Err("--n needs a value".to_string());
                }
                n = args_vec[i]
                    .parse()
                    .map_err(|e| format!("invalid --n: {}", e))?;
            }
            "--power" | "-p" => {
                i += 1;
                if i >= args_vec.len() {
                    return Err("--power needs a value".to_string());
                }
                power = parse_metric(&args_vec[i])?;
            }
            other => return Err(format!("unknown option '{}' for info", other)),
        }
        i += 1;
    }

    Ok(Subcommand::Info(InfoConfig {
        waist,
        wavelength,
        n,
        power,
    }))
}

fn run_export(config: ExportConfig) -> Result<(), String> {
    let beam = GaussianBeam::new(config.wavelength, config.waist, config.z, 1.0, 1.0)
        .map_err(|e| format!("invalid beam: {}", e))?;

    let z_r = beam.rayleigh_range();
    let z_min = config.z_min.unwrap_or(-1.5 * z_r);
    let z_max = config.z_max.unwrap_or(1.5 * z_r);
    let x_max = config.x_max.unwrap_or(3.0 * beam.w0);

    let cmap = match config.colormap.as_str() {
        "inferno" => Colormap::Inferno,
        "plasma" => Colormap::Plasma,
        "turbo" => Colormap::Turbo,
        "laser_glow" => Colormap::LaserGlow,
        "asympton" => Colormap::Asympton,
        _ => Colormap::Viridis,
    };

    let style = RenderStyle {
        colormap: cmap,
        gamma: config.gamma,
        show_wavefront_composite: config.fringe_modulation > 0.0,
        fringe_modulation: config.fringe_modulation,
    };

    let train = OpticalTrain::new();

    export_beam_to_png_file(
        &config.output,
        &beam,
        &train,
        &style,
        z_min,
        z_max,
        x_max,
        config.width,
        config.height,
    )
    .map_err(|e| format!("export failed: {}", e))?;

    println!(
        "wrote {} ({}x{}, {}, z_R = {:.4} m)",
        config.output.display(),
        config.width,
        config.height,
        config.colormap,
        z_r
    );
    Ok(())
}

fn run_info(config: InfoConfig) -> Result<(), String> {
    let beam = GaussianBeam::new(config.wavelength, config.waist, 0.0, config.n, config.power)
        .map_err(|e| format!("invalid beam: {}", e))?;

    let z_r = beam.rayleigh_range();
    let theta = beam.divergence_half_angle();
    let confocal = 2.0 * z_r;
    let i0 = beam.peak_intensity();
    let paraxial = if beam.is_paraxial_valid() {
        "yes"
    } else {
        "no"
    };

    println!("wavelength      {:.2} nm", beam.wavelength * 1e9);
    println!("waist w0        {:.3} um", beam.w0 * 1e6);
    println!("index n         {:.4}", beam.refractive_index);
    println!("power           {:.3} W", beam.power);
    println!("rayleigh z_R    {:.6} m", z_r);
    println!("confocal b      {:.6} m", confocal);
    println!(
        "divergence      {:.4} mrad ({:.4} deg)",
        theta * 1e3,
        theta.to_degrees()
    );
    println!("peak intensity  {:.3e} W/m^2", i0);
    println!("paraxial        {}", paraxial);
    Ok(())
}

fn print_help() {
    print!(
        "\
beam-cli: render a Gaussian beam to PNG, or print its parameters

Usage:
  beam-cli export --output <PATH> [OPTIONS]
  beam-cli info [--waist <LEN>] [--wavelength <LEN>] [--n <N>] [--power <W>]
  beam-cli [OPTIONS]            same as export, writing cover.png by default

Lengths accept nm, um, mm, cm or m suffixes; a bare number is metres.

Export options:
  -o, --output <PATH>     PNG to write
      --waist <LEN>       waist radius w0 [0.5mm]
      --wavelength <LEN>  vacuum wavelength [632.8nm]
      --z <LEN>           waist position [0]
      --colormap <NAME>   viridis, inferno, plasma, turbo, laser_glow, asympton [viridis]
      --width <PX>        [1920]
      --height <PX>       [1080]
      --gamma <G>         display gamma [1.0]
      --fringe <F>        wavefront fringe depth, 0 to 1 [0]
      --z-min <LEN>       axial window start [-1.5 z_R]
      --z-max <LEN>       axial window end [1.5 z_R]
      --x-max <LEN>       transverse half-height [3 w0]

Info options:
      --n <N>             refractive index [1.0]
  -p, --power <W>         power in watts [1.0]

  -h, --help              show this help
  -V, --version           show version
"
    );
}

fn main() {
    match parse_args(env::args()) {
        Ok(Subcommand::Help) => {
            print_help();
            process::exit(0);
        }
        Ok(Subcommand::Version) => {
            println!("beam-cli {}", env!("CARGO_PKG_VERSION"));
            process::exit(0);
        }
        Ok(Subcommand::Export(cfg)) => {
            if let Err(e) = run_export(cfg) {
                eprintln!("beam-cli: {}", e);
                process::exit(1);
            }
        }
        Ok(Subcommand::Info(cfg)) => {
            if let Err(e) = run_info(cfg) {
                eprintln!("beam-cli: {}", e);
                process::exit(1);
            }
        }
        Err(e) => {
            eprintln!("beam-cli: {}", e);
            eprintln!("try 'beam-cli --help'");
            process::exit(1);
        }
    }
}
