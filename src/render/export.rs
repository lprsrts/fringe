//! PNG, .npy and .npz export.

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

/// A NumPy format 1.0 header (magic, version, length, dict) padded so the data
/// starts on a 64-byte boundary. `shape` is the C-order shape; empty is 0-d.
fn npy_header(descr: &str, shape: &[usize]) -> Vec<u8> {
    let dims = match shape {
        [] => "()".to_string(),
        [n] => format!("({n},)"),
        _ => format!("({})", shape.iter().map(usize::to_string).collect::<Vec<_>>().join(", ")),
    };
    let mut header = format!("{{'descr': '{descr}', 'fortran_order': False, 'shape': {dims}, }}");
    // Magic (6) + version (2) + length (2) + header + '\n' must be a multiple of 64.
    let total = 10 + header.len() + 1;
    header.push_str(&" ".repeat((64 - total % 64) % 64));
    header.push('\n');
    let mut out = Vec::with_capacity(10 + header.len());
    out.extend_from_slice(b"\x93NUMPY\x01\x00");
    out.extend_from_slice(&(header.len() as u16).to_le_bytes());
    out.extend_from_slice(header.as_bytes());
    out
}

/// The (ny, nx) complex128 data, row 0 at the top (max y), little-endian.
fn write_c128_rows<W: Write>(w: &mut W, field: &FieldGrid, part: Part) -> std::io::Result<()> {
    let g = &field.grid;
    for j in (0..g.ny).rev() {
        for i in 0..g.nx {
            let v = field.value(part, g.index(i, j));
            w.write_all(&v.re.to_le_bytes())?;
            w.write_all(&v.im.to_le_bytes())?;
        }
    }
    Ok(())
}

fn export_info(field: &FieldGrid, part: Part, layout: &str) -> serde_json::Value {
    let mut info = field.info_json();
    info["part"] = serde_json::Value::from(part.name());
    info["layout"] = serde_json::Value::from(layout);
    info
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
    let tmp = tmp_path(path);
    let written = (|| -> Result<(), RenderError> {
        let mut w = BufWriter::new(File::create(&tmp)?);
        w.write_all(&npy_header("<c16", &[g.ny, g.nx]))?;
        write_c128_rows(&mut w, field, part)?;
        w.flush()?;
        Ok(())
    })()
    .and_then(|()| fs::rename(&tmp, path).map_err(RenderError::Io));
    if written.is_err() {
        let _ = fs::remove_file(&tmp);
        return written;
    }
    let info = export_info(field, part, "shape (ny, nx), row 0 at y_max, column 0 at x_min");
    let mut side = path.as_os_str().to_os_string();
    side.push(".json");
    fs::write(side, serde_json::to_string_pretty(&info).unwrap_or_default())?;
    Ok(())
}

/// `part` of the field as an uncompressed NumPy .npz, built in memory so the caller
/// can write it in one step (a sandboxed app may write only the file the user
/// chose, with no sibling temp file or sidecar). Members:
/// - `field`: complex128, shape (ny, nx), laid out as by [`write_npy_c128`];
/// - `x`: float64 (nx,), the x of each column; `y`: float64 (ny,), the y of each
///   row, so `y[0]` is the top. Both are grid node positions in µm, not cell
///   centres: x[0] is the interior's x_min itself;
/// - `info`: a 0-d unicode array holding the .npy sidecar's JSON, readable
///   without pickle as `json.loads(np.load(f)["info"].item())`.
pub fn npz_c128(field: &FieldGrid, part: Part) -> Result<Vec<u8>, RenderError> {
    let g = &field.grid;

    let mut data = npy_header("<c16", &[g.ny, g.nx]);
    data.reserve(16 * g.len());
    write_c128_rows(&mut data, field, part)?;

    let mut x = npy_header("<f8", &[g.nx]);
    for i in 0..g.nx {
        x.extend_from_slice(&g.point(i, 0).x.to_le_bytes());
    }
    let mut y = npy_header("<f8", &[g.ny]);
    for j in (0..g.ny).rev() {
        y.extend_from_slice(&g.point(0, j).y.to_le_bytes());
    }

    let layout = "field shape (ny, nx), row 0 at y_max, column 0 at x_min; \
                  x[i] = x0_um + i*dx_um and y[r] = y0_um + (ny-1-r)*dx_um are grid node positions in um";
    let json = serde_json::to_string_pretty(&export_info(field, part, layout)).unwrap_or_default();
    // NumPy's '<U' strings are fixed-width UTF-32LE; '<U0' is not a valid dtype.
    let chars: Vec<char> = json.chars().collect();
    let width = chars.len().max(1);
    let mut info = npy_header(&format!("<U{width}"), &[]);
    for k in 0..width {
        info.extend_from_slice(&chars.get(k).map_or(0, |&c| c as u32).to_le_bytes());
    }

    zip_stored(&[("field.npy", &data), ("x.npy", &x), ("y.npy", &y), ("info.npy", &info)])
}

/// A ZIP archive of `entries` with no compression. ZIP64 is not written, so every
/// size and offset must stay below 4 GiB.
fn zip_stored(entries: &[(&str, &[u8])]) -> Result<Vec<u8>, RenderError> {
    const LIMIT: usize = u32::MAX as usize; // 0xFFFFFFFF itself means "see ZIP64"
    let too_large = || {
        RenderError::TooLarge("the field is too large for a .npz (over 4 GiB); use fringe-cli --npy instead".into())
    };
    let check = |n: usize| if n < LIMIT { Ok(n as u32) } else { Err(too_large()) };
    if entries.len() >= u16::MAX as usize {
        return Err(too_large());
    }
    let capacity = entries.iter().map(|(name, d)| 30 + 46 + 2 * name.len() + d.len()).sum::<usize>() + 22;
    let mut out = Vec::with_capacity(capacity);
    let mut central = Vec::new();
    // 1980-01-01 00:00 in MS-DOS format: a fixed stamp keeps the output reproducible.
    let (dos_time, dos_date): (u16, u16) = (0, (1 << 5) | 1);
    for (name, data) in entries {
        let offset = check(out.len())?;
        let size = check(data.len())?;
        let crc = crc32fast::hash(data);
        let name_len = name.len() as u16;
        // Local file header.
        out.extend_from_slice(&0x0403_4b50u32.to_le_bytes());
        out.extend_from_slice(&10u16.to_le_bytes()); // version needed: 1.0, stored
        out.extend_from_slice(&0u16.to_le_bytes()); // flags
        out.extend_from_slice(&0u16.to_le_bytes()); // method: stored
        out.extend_from_slice(&dos_time.to_le_bytes());
        out.extend_from_slice(&dos_date.to_le_bytes());
        out.extend_from_slice(&crc.to_le_bytes());
        out.extend_from_slice(&size.to_le_bytes()); // compressed
        out.extend_from_slice(&size.to_le_bytes()); // uncompressed
        out.extend_from_slice(&name_len.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes()); // extra length
        out.extend_from_slice(name.as_bytes());
        out.extend_from_slice(data);
        // Central directory entry.
        central.extend_from_slice(&0x0201_4b50u32.to_le_bytes());
        central.extend_from_slice(&20u16.to_le_bytes()); // made by: MS-DOS, 2.0
        central.extend_from_slice(&10u16.to_le_bytes());
        central.extend_from_slice(&0u16.to_le_bytes());
        central.extend_from_slice(&0u16.to_le_bytes());
        central.extend_from_slice(&dos_time.to_le_bytes());
        central.extend_from_slice(&dos_date.to_le_bytes());
        central.extend_from_slice(&crc.to_le_bytes());
        central.extend_from_slice(&size.to_le_bytes());
        central.extend_from_slice(&size.to_le_bytes());
        central.extend_from_slice(&name_len.to_le_bytes());
        central.extend_from_slice(&[0u8; 8]); // extra, comment, disk start, internal attrs
        central.extend_from_slice(&0u32.to_le_bytes()); // external attrs
        central.extend_from_slice(&offset.to_le_bytes());
        central.extend_from_slice(name.as_bytes());
    }
    let central_offset = check(out.len())?;
    let central_size = check(central.len())?;
    check(out.len() + central.len() + 22)?;
    out.extend_from_slice(&central);
    // End of central directory record.
    let count = entries.len() as u16;
    out.extend_from_slice(&0x0605_4b50u32.to_le_bytes());
    out.extend_from_slice(&[0u8; 4]); // this disk, disk with the directory
    out.extend_from_slice(&count.to_le_bytes());
    out.extend_from_slice(&count.to_le_bytes());
    out.extend_from_slice(&central_size.to_le_bytes());
    out.extend_from_slice(&central_offset.to_le_bytes());
    out.extend_from_slice(&0u16.to_le_bytes()); // comment length
    Ok(out)
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
