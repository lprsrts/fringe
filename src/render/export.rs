//! PNG and .npy export.

use std::fs::{self, File};
use std::io::{BufWriter, Write};
use std::path::Path;

use image::codecs::png::PngEncoder;
use image::{ExtendedColorType, ImageEncoder};

use super::{RenderError, MAX_DIMENSION};
use crate::solver::{FieldGrid, Part};

/// Byte length of a `width` x `height` RGBA8 image, checking the size limits.
fn rgba_len(width: u32, height: u32) -> Result<usize, RenderError> {
    if width == 0 || height == 0 || width > MAX_DIMENSION || height > MAX_DIMENSION {
        return Err(RenderError::InvalidDimensions { width, height });
    }
    (width as usize)
        .checked_mul(height as usize)
        .and_then(|p| p.checked_mul(4))
        .ok_or(RenderError::InvalidDimensions { width, height })
}

fn check_rgba_buffer(buffer: &[u8], width: u32, height: u32) -> Result<(), RenderError> {
    let expected = rgba_len(width, height)?;
    if buffer.len() != expected {
        return Err(RenderError::BufferTooSmall { need: expected, got: buffer.len() });
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
    let tmp_path = tmp_path(path);

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

/// The temporary sibling `<name>.tmp` used for atomic writes.
fn tmp_path(path: &Path) -> std::path::PathBuf {
    match path.file_name() {
        Some(name) => {
            let mut tmp_name = name.to_os_string();
            tmp_name.push(".tmp");
            path.with_file_name(tmp_name)
        }
        None => path.with_extension("tmp"),
    }
}

/// Writes `part` of the field as a complex128 .npy array of shape (ny, nx), row 0
/// at the top (max y), plus a `<path>.json` sidecar with the grid and run info.
pub fn write_npy_c128<P: AsRef<Path>>(path: P, field: &FieldGrid, part: Part) -> Result<(), RenderError> {
    let path = path.as_ref();
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() && !parent.exists() {
            fs::create_dir_all(parent)?;
        }
    }
    let g = &field.grid;
    let mut header = format!("{{'descr': '<c16', 'fortran_order': False, 'shape': ({}, {}), }}", g.ny, g.nx);
    // Magic (6) + version (2) + length (2) + header must be a multiple of 64.
    let total = 10 + header.len() + 1;
    header.push_str(&" ".repeat((64 - total % 64) % 64));
    header.push('\n');
    let tmp = tmp_path(path);
    let written = (|| -> Result<(), RenderError> {
        let mut w = BufWriter::new(File::create(&tmp)?);
        w.write_all(b"\x93NUMPY\x01\x00")?;
        w.write_all(&(header.len() as u16).to_le_bytes())?;
        w.write_all(header.as_bytes())?;
        for j in (0..g.ny).rev() {
            for i in 0..g.nx {
                let v = field.value(part, g.index(i, j));
                w.write_all(&v.re.to_le_bytes())?;
                w.write_all(&v.im.to_le_bytes())?;
            }
        }
        w.flush()?;
        Ok(())
    })()
    .and_then(|()| fs::rename(&tmp, path).map_err(RenderError::Io));
    if written.is_err() {
        let _ = fs::remove_file(&tmp);
        return written;
    }
    let mut info = field.info_json();
    info["part"] = serde_json::Value::from(part.name());
    info["layout"] = serde_json::Value::from("shape (ny, nx), row 0 at y_max, column 0 at x_min");
    let mut side = path.as_os_str().to_os_string();
    side.push(".json");
    fs::write(side, serde_json::to_string_pretty(&info).unwrap_or_default())?;
    Ok(())
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
        let dir = std::env::temp_dir().join("fringe_test_export");
        let path = dir.join("test_atomic.png");
        let buffer = vec![128u8; 16];
        export_png_file(&path, &buffer, 2, 2).unwrap();
        assert!(path.exists());
        assert!(!dir.join("test_atomic.png.tmp").exists());
        let _ = fs::remove_dir_all(dir);
    }
}
