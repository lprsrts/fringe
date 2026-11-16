#ifndef BEAM_CORE_H
#define BEAM_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// C interface to beam_core v2 (src/ffi.rs).
// Scenes and views are UTF-8 JSON (schema version 2; lengths in micrometres,
// angles in degrees). Every char* returned by this library is owned by the
// caller and must be released with beam_string_free. Error outputs
// (char** error_json_out, may be NULL) receive {"code","message","issues":[...]}
// or are left untouched on success. No function unwinds across the boundary.
// All functions are thread-safe. A BeamField is immutable and may be read and
// rendered from several threads at once.

#define BEAM_ABI_VERSION 2u

#define BEAM_QUALITY_PREVIEW 0u
#define BEAM_QUALITY_FINAL 1u

#define BEAM_JOB_RUNNING 0u
#define BEAM_JOB_DONE 1u
#define BEAM_JOB_FAILED 2u
#define BEAM_JOB_CANCELLED 3u

#define BEAM_STAGE_SETUP 0u     // parse, validate, incident field
#define BEAM_STAGE_GEOMETRY 1u  // rasterise / mesh / panelise
#define BEAM_STAGE_ASSEMBLE 2u  // matrix fill
#define BEAM_STAGE_SOLVE 3u     // time stepping / factorisation (FEM LU is not interruptible)
#define BEAM_STAGE_SAMPLE 4u    // field onto the output grid
#define BEAM_STAGE_FINISHED 5u

#define BEAM_PART_TOTAL 0u
#define BEAM_PART_SCATTERED 1u
#define BEAM_PART_INCIDENT 2u

#define BEAM_MAX_DIMENSION 16384u

typedef struct BeamJob BeamJob;     // one solve on a background thread
typedef struct BeamField BeamField; // solved complex Ez phasor grid (total + incident)

typedef struct {
    uint32_t state;     // BEAM_JOB_*
    uint32_t stage;     // BEAM_STAGE_*
    double fraction;    // overall progress 0..1, monotone non-decreasing
    double elapsed_s;
    uint64_t unknowns;  // cells, DOFs or MoM unknowns; 0 until known
} BeamProgress;

#ifdef __cplusplus
extern "C" {
#endif

uint32_t beam_abi_version(void);
const char* beam_version(void);          // static string, do not free
void beam_string_free(char* s);          // NULL is fine

// Scenes
char* beam_scene_default(void);
// Example scene JSON by name; "" returns a JSON array of {"name","title","method"}; NULL if unknown.
char* beam_scene_example(const char* name);
// Validation, per-quality cost estimates and derived quantities (see spec §3.7).
// Never NULL for non-NULL input; parse failures are reported inside the JSON.
char* beam_scene_check(const char* scene_json);
// Geometry for overlays without solving:
// {"domain":{...},"pml_um":..,"bodies":[{"element_id","pec","outline":[[x,y],..]}],
//  "source":{"kind","waist_um":[x,y],"angle_deg","w0_um"}} or {"error":{...}}.
char* beam_scene_outlines(const char* scene_json);

// Solving
// Returns NULL (and sets *error_json_out) on NULL input, parse or validation
// errors. Later failures surface as BEAM_JOB_FAILED.
BeamJob* beam_job_start(const char* scene_json, uint32_t quality, char** error_json_out);
void beam_job_poll(const BeamJob* job, BeamProgress* out);   // lock-free, any rate
void beam_job_cancel(BeamJob* job);                          // idempotent, returns immediately
// Non-NULL exactly once, after state == DONE. For FAILED or CANCELLED returns
// NULL and sets *error_json_out (code "cancelled" for CANCELLED).
BeamField* beam_job_take_result(BeamJob* job, char** error_json_out);
// Cancels if running and releases the handle without blocking; the worker
// thread finishes on its own. NULL is fine.
void beam_job_free(BeamJob* job);

// Results
// {"grid":{"x0_um","y0_um","dx_um","nx","ny"},"domain":{...},"pml_um",
//  "wavelength_um","background_n","incident_peak","total_peak","quality",
//  "method","meta":{...},"bodies":[{"element_id","name","pec","n","k","outline"}]}
char* beam_field_info(const BeamField* field);
// Bicubic sample of a part at a point; false outside the grid.
bool beam_field_sample(const BeamField* field, double x_um, double y_um, uint32_t part,
                       double* out_re, double* out_im);
// Renders view_json (spec §3.6) as sRGB RGBA8, row 0 = top (max y), into a
// caller buffer of at least width*height*4 bytes.
bool beam_field_render_rgba(const BeamField* field, const char* view_json,
                            uint32_t width, uint32_t height,
                            uint8_t* out_rgba, size_t out_len, char** error_json_out);
// Renders and writes a PNG atomically (temporary file + rename).
bool beam_field_export_png(const BeamField* field, const char* view_json,
                           uint32_t width, uint32_t height, const char* path,
                           char** error_json_out);
// complex128 .npy, shape (ny, nx), row 0 = max y, plus "<path>.json" grid sidecar.
bool beam_field_export_npy(const BeamField* field, uint32_t part, const char* path,
                           char** error_json_out);
void beam_field_free(BeamField* field);  // NULL is fine

// 256 RGBA8 entries (out_len >= 1024) for a colour legend.
bool beam_colormap_lut(const char* name, double wavelength_um, uint8_t* out_rgba, size_t out_len);

#ifdef __cplusplus
}
#endif

#endif // BEAM_CORE_H
