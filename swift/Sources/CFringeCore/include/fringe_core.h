#ifndef FRINGE_CORE_H
#define FRINGE_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// C interface to fringe_core v2 (src/ffi.rs).
// Scenes and views are UTF-8 JSON (schema version 2; lengths in micrometres,
// angles in degrees). Every char* returned by this library is owned by the
// caller and must be released with fringe_string_free; returned uint8_t*
// buffers likewise with fringe_bytes_free. Error outputs
// (char** error_json_out, may be NULL) receive {"code","message","issues":[...]}
// or are left untouched on success. No function unwinds across the boundary.
// All functions are thread-safe. A FringeField is immutable and may be read and
// rendered from several threads at once.

#define FRINGE_ABI_VERSION 2u

#define FRINGE_QUALITY_PREVIEW 0u
#define FRINGE_QUALITY_FINAL 1u

#define FRINGE_JOB_RUNNING 0u
#define FRINGE_JOB_DONE 1u
#define FRINGE_JOB_FAILED 2u
#define FRINGE_JOB_CANCELLED 3u

#define FRINGE_STAGE_SETUP 0u     // parse, validate, incident field
#define FRINGE_STAGE_GEOMETRY 1u  // rasterise / mesh / panelise
#define FRINGE_STAGE_ASSEMBLE 2u  // matrix fill
#define FRINGE_STAGE_SOLVE 3u     // time stepping / factorisation (FEM LU is not interruptible)
#define FRINGE_STAGE_SAMPLE 4u    // field onto the output grid
#define FRINGE_STAGE_FINISHED 5u

#define FRINGE_PART_TOTAL 0u
#define FRINGE_PART_SCATTERED 1u
#define FRINGE_PART_INCIDENT 2u

#define FRINGE_MAX_DIMENSION 16384u

typedef struct FringeJob FringeJob;     // one solve on a background thread
typedef struct FringeField FringeField; // solved complex Ez phasor grid (total + incident)

typedef struct {
    uint32_t state;     // FRINGE_JOB_*
    uint32_t stage;     // FRINGE_STAGE_*
    double fraction;    // overall progress 0..1, monotone non-decreasing
    double elapsed_s;
    uint64_t unknowns;  // cells, DOFs or MoM unknowns; 0 until known
} FringeProgress;

#ifdef __cplusplus
extern "C" {
#endif

uint32_t fringe_abi_version(void);
const char* fringe_version(void);          // static string, do not free
void fringe_string_free(char* s);          // NULL is fine
void fringe_bytes_free(uint8_t* bytes, size_t len);  // NULL is fine

// Scenes
char* fringe_scene_default(void);
// Example scene JSON by name; "" returns a JSON array of {"name","title","method"}; NULL if unknown.
char* fringe_scene_example(const char* name);
// Validation, per-quality cost estimates and derived quantities.
// Never NULL for non-NULL input; parse failures are reported inside the JSON.
char* fringe_scene_check(const char* scene_json);
// Geometry for overlays without solving:
// {"domain":{...},"pml_um":..,"bodies":[{"element_id","enabled","pec","outline":[[x,y],..]}],
//  "source":{"kind","waist_um":[x,y],"angle_deg","w0_um"}} or {"error":{...}}.
// Bodies of disabled elements are included with "enabled": false.
char* fringe_scene_outlines(const char* scene_json);

// Solving
// Returns NULL (and sets *error_json_out) on NULL input, parse or validation
// errors. Later failures surface as FRINGE_JOB_FAILED.
FringeJob* fringe_job_start(const char* scene_json, uint32_t quality, char** error_json_out);
void fringe_job_poll(const FringeJob* job, FringeProgress* out);   // lock-free, any rate
void fringe_job_cancel(FringeJob* job);                          // idempotent, returns immediately
// Non-NULL exactly once, after state == DONE. For FAILED or CANCELLED returns
// NULL and sets *error_json_out (code "cancelled" for CANCELLED).
FringeField* fringe_job_take_result(FringeJob* job, char** error_json_out);
// Cancels if running and releases the handle without blocking; the worker
// thread finishes on its own. NULL is fine.
void fringe_job_free(FringeJob* job);

// Results
// {"grid":{"x0_um","y0_um","dx_um","nx","ny"},"domain":{...},"pml_um",
//  "wavelength_um","background_n","incident_peak","total_peak","quality",
//  "method","meta":{...},"bodies":[{"element_id","name","pec","n","k","outline"}]}
char* fringe_field_info(const FringeField* field);
// Bicubic sample of a part at a point; false outside the grid.
bool fringe_field_sample(const FringeField* field, double x_um, double y_um, uint32_t part,
                       double* out_re, double* out_im);
// Renders view_json as sRGB RGBA8, row 0 = top (max y), into a
// caller buffer of at least width*height*4 bytes.
bool fringe_field_render_rgba(const FringeField* field, const char* view_json,
                            uint32_t width, uint32_t height,
                            uint8_t* out_rgba, size_t out_len, char** error_json_out);
// Renders and writes a PNG atomically (temporary file + rename).
bool fringe_field_export_png(const FringeField* field, const char* view_json,
                           uint32_t width, uint32_t height, const char* path,
                           char** error_json_out);
// complex128 .npy, shape (ny, nx), row 0 = max y, plus "<path>.json" grid sidecar.
bool fringe_field_export_npy(const FringeField* field, uint32_t part, const char* path,
                           char** error_json_out);
// The part as an uncompressed NumPy .npz built in memory, for callers that must
// write the file themselves (e.g. a sandboxed app): "field" complex128 (ny, nx)
// laid out as above, "x" float64 (nx,) and "y" float64 (ny,) node positions in
// um of its columns and rows (y[0] = top), "info" a 0-d unicode array holding
// the .npy sidecar JSON. Returns NULL and sets *error_json_out on failure;
// otherwise *out_len is set and the caller owns the buffer, released with
// fringe_bytes_free(buffer, *out_len).
uint8_t* fringe_field_npz(const FringeField* field, uint32_t part, size_t* out_len,
                          char** error_json_out);
void fringe_field_free(FringeField* field);  // NULL is fine

// 256 RGBA8 entries (out_len >= 1024) for a colour legend.
bool fringe_colormap_lut(const char* name, double wavelength_um, uint8_t* out_rgba, size_t out_len);

#ifdef __cplusplus
}
#endif

#endif // FRINGE_CORE_H
