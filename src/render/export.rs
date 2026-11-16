//! PNG encoding and file export.

use std::fs::{self, File};
use std::io::{BufWriter, Write};
use std::path::Path;

use image::codecs::png::PngEncoder;
use image::{ExtendedColorType, ImageEncoder};

use super::colormap::RenderStyle;
use super::grid::{render_longitudinal_rgba, RenderError, MAX_DIMENSION};
use crate::physics::{GaussianBeam, OpticalTrain};

/// Byte length of a `width` x `height` RGBA8 image, checking the size limits.
fn rgba_len(width: u32, height: u32) -> Result<usize, RenderError> {
    if width == 0 || height == 0 || width > MAX_DIMENSION || height > MAX_DIMENSION {
        return Err(RenderError::InvalidDimensions {
            width: width as usize,
            height: height as usize,
        });
    }
    (width as usize)
        .checked_mul(height as usize)
        .and_then(|p| p.checked_mul(4))
        .ok_or(RenderError::BufferOverflow)
}

fn check_rgba_buffer(buffer: &[u8], width: u32, height: u32) -> Result<(), RenderError> {
    let expected = rgba_len(width, height)?;
    if buffer.len() != expected {
        return Err(RenderError::BufferLengthMismatch {
            expected,
            actual: buffer.len(),
        });
    }
    Ok(())
}

/// Encode an RGBA8 buffer as PNG in memory.
pub fn encode_png(buffer: &[u8], width: u32, height: u32) -> Result<Vec<u8>, RenderError> {
    check_rgba_buffer(buffer, width, height)?;
    let mut out = Vec::new();
    PngEncoder::new(&mut out).write_image(buffer, width, height, ExtendedColorType::Rgba8)?;
    Ok(out)
}

/// Write an RGBA8 buffer to `path` as PNG, creating parent directories as needed.
///
/// The image is written to `<path>.tmp` and renamed into place, so a failed export
/// never leaves a truncated file at `path`.
pub fn export_png_file<P: AsRef<Path>>(
    path: P,
    buffer: &[u8],
    width: u32,
    height: u32,
) -> Result<(), RenderError> {
    let path = path.as_ref();
    check_rgba_buffer(buffer, width, height)?;

    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() && !parent.exists() {
            fs::create_dir_all(parent)?;
        }
    }

    // Keep the temp file in the same directory so the rename stays on one filesystem.
    let tmp_path = match path.file_name() {
        Some(name) => {
            let mut tmp_name = name.to_os_string();
            tmp_name.push(".tmp");
            path.with_file_name(tmp_name)
        }
        None => path.with_extension("tmp"),
    };

    let written = (|| -> Result<(), RenderError> {
        let mut writer = BufWriter::new(File::create(&tmp_path)?);
        PngEncoder::new(&mut writer).write_image(
            buffer,
            width,
            height,
            ExtendedColorType::Rgba8,
        )?;
        writer.flush()?;
        Ok(())
    })()
    .and_then(|()| fs::rename(&tmp_path, path).map_err(RenderError::Io));

    if written.is_err() {
        let _ = fs::remove_file(&tmp_path);
    }
    written
}

/// Render a longitudinal (z, x) view of `beam` through `train` and save it as PNG.
///
/// See [`render_longitudinal_rgba`] for the meaning of the bounds.
#[allow(clippy::too_many_arguments)]
pub fn export_beam_to_png_file<P: AsRef<Path>>(
    path: P,
    beam: &GaussianBeam,
    train: &OpticalTrain,
    style: &RenderStyle,
    z_min: f64,
    z_max: f64,
    x_max: f64,
    width: u32,
    height: u32,
) -> Result<(), RenderError> {
    let mut rgba = vec![0u8; rgba_len(width, height)?];
    render_longitudinal_rgba(
        beam,
        train,
        style,
        z_min,
        z_max,
        x_max,
        width as usize,
        height as usize,
        &mut rgba,
    )?;
    export_png_file(path, &rgba, width, height)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encode_png_writes_png_signature() {
        let width = 4u32;
        let height = 4u32;
        let buffer = vec![255u8; (width * height * 4) as usize];
        let png_bytes = encode_png(&buffer, width, height).unwrap();

        assert_eq!(&png_bytes[0..8], b"\x89PNG\r\n\x1a\n");
    }

    #[test]
    fn encode_png_rejects_bad_input() {
        let buffer = vec![0u8; 16];
        assert!(encode_png(&buffer, 0, 4).is_err());
        assert!(encode_png(&buffer, 4, 0).is_err());
        assert!(encode_png(&buffer[..15], 2, 2).is_err());
    }

    #[test]
    fn export_png_file_creates_dirs_and_leaves_no_temp_file() {
        let dir = std::env::temp_dir().join("beam_bg_test_export");
        let path = dir.join("test_atomic.png");
        let buffer = vec![128u8; 16];
        export_png_file(&path, &buffer, 2, 2).unwrap();
        assert!(path.exists());
        assert!(!dir.join("test_atomic.png.tmp").exists());
        let _ = fs::remove_dir_all(dir);
    }
}
