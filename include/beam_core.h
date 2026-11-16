#ifndef BEAM_CORE_H
#define BEAM_CORE_H

#include <stdint.h>
#include <stdbool.h>

// C interface to beam_core (src/ffi.rs). All lengths are in metres.

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    double wavelength;       // vacuum wavelength
    double w0;               // 1/e^2 waist radius
    double z0;               // waist position on the axis
    double refractive_index; // >= 1
    double power;            // watts
} CBeamParams;

typedef enum {
    ELEMENT_THIN_LENS = 0,
    ELEMENT_CURVED_MIRROR = 1,
    ELEMENT_FLAT_MIRROR = 2,
    ELEMENT_DIELECTRIC_INTERFACE = 3,
    ELEMENT_GAUSSIAN_APERTURE = 4,
} COpticalElementType;

typedef struct {
    double z;
    COpticalElementType element_type;
    double param1; // focal length, mirror or aperture radius, or n1
    double param2; // n2 for a dielectric interface, otherwise unused
} CPlacedElement;

typedef enum {
    COLORMAP_VIRIDIS = 0,
    COLORMAP_INFERNO = 1,
    COLORMAP_PLASMA = 2,
    COLORMAP_TURBO = 3,
    COLORMAP_LASER_GLOW = 4,
    COLORMAP_ASYMPTON = 5,
} CColormap;

typedef struct {
    CColormap colormap;
    double gamma;             // 1.0 is linear
    bool show_wavefront_composite;
    double fringe_modulation; // 0 to 1
} CRenderStyle;

// Closed-form beam quantities. Each returns 0 for invalid input.
double beam_calc_rayleigh_range(double w0, double wavelength, double n);
double beam_calc_waist_at_z(double w0, double z, double z_r);
double beam_calc_curvature_at_z(double z, double z_r); // 1/R(z), 0 at the waist
double beam_calc_gouy_phase(double z, double z_r);

// Renders the (z, x) field as RGBA8 into a caller-owned buffer of at least
// width * height * 4 bytes. Returns false on invalid input.
bool beam_render_longitudinal_rgba(
    const CBeamParams* beam,
    const CPlacedElement* elements,
    uint32_t element_count,
    const CRenderStyle* style,
    double z_min, double z_max,
    double x_max,
    uint32_t width, uint32_t height,
    uint8_t* out_rgba_buffer,
    uint32_t buffer_len
);

// Renders and writes a PNG. Returns false on invalid input or I/O error.
bool beam_export_png_file(
    const char* file_path,
    const CBeamParams* beam,
    const CPlacedElement* elements,
    uint32_t element_count,
    const CRenderStyle* style,
    double z_min, double z_max,
    double x_max,
    uint32_t width, uint32_t height
);

#ifdef __cplusplus
}
#endif

#endif // BEAM_CORE_H
