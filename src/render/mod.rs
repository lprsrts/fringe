//! Rasterising beam intensity into RGBA buffers, colormaps, and PNG export.

pub mod colormap;
pub mod export;
pub mod grid;

pub use colormap::{
    asympton_tokens, colormap_asympton, colormap_inferno, colormap_laser_glow, colormap_plasma,
    colormap_turbo, colormap_viridis, map_colormap, map_intensity_to_rgba,
    map_intensity_with_transfer, wavelength_to_nm, wavelength_to_rgb, Colormap, ColormapLut,
    RenderStyle, Rgba, TransferFunction,
};
pub use export::{encode_png, export_beam_to_png_file, export_png_file};
pub use grid::{
    check_buffer_capacity, normalize_grid_bounds, render_longitudinal_rgba,
    render_longitudinal_slice, render_transverse_rgba, render_transverse_slice, safe_exp,
    IntensityGrid, RenderError, MAX_DIMENSION,
};
