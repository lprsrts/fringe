//! Rendering solved fields to RGBA, colormaps, and PNG, .npy and .npz export.

pub mod colormap;
pub mod export;
pub mod view;

pub use colormap::{Colormap, ColormapKind};
pub use export::{encode_png, export_png_file, npz_c128, write_npy_c128};
pub use view::{render_rgba, Quantity, View, MAX_DIMENSION};

#[derive(Debug)]
pub enum RenderError {
    InvalidDimensions { width: u32, height: u32 },
    BufferTooSmall { need: usize, got: usize },
    View(String),
    /// Output beyond a container format's size limits.
    TooLarge(String),
    Image(image::ImageError),
    Io(std::io::Error),
}

impl RenderError {
    /// Error code for the C ABI.
    pub fn code(&self) -> &'static str {
        match self {
            RenderError::InvalidDimensions { .. } | RenderError::BufferTooSmall { .. } | RenderError::TooLarge(_) => "buffer",
            RenderError::View(_) => "view",
            RenderError::Image(_) | RenderError::Io(_) => "io",
        }
    }
}

impl std::fmt::Display for RenderError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RenderError::InvalidDimensions { width, height } => {
                write!(f, "image size {width}×{height} is outside 1–{MAX_DIMENSION} pixels")
            }
            RenderError::BufferTooSmall { need, got } => write!(f, "buffer holds {got} bytes, {need} needed"),
            RenderError::View(m) => write!(f, "invalid view: {m}"),
            RenderError::TooLarge(m) => write!(f, "{m}"),
            RenderError::Image(e) => write!(f, "image encoding failed: {e}"),
            RenderError::Io(e) => write!(f, "{e}"),
        }
    }
}

impl std::error::Error for RenderError {}

impl From<image::ImageError> for RenderError {
    fn from(e: image::ImageError) -> Self {
        RenderError::Image(e)
    }
}

impl From<std::io::Error> for RenderError {
    fn from(e: std::io::Error) -> Self {
        RenderError::Io(e)
    }
}
