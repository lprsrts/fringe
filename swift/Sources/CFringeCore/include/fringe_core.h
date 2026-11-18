#ifndef FRINGE_CORE_H
#define FRINGE_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// C interface to fringe_core, ABI version 3 (src/ffi.rs).
// Scenes and views are UTF-8 JSON (schema version 3, version 2 is read and
// upgraded; lengths in micrometres, angles in degrees). Every char* returned
// by this library is owned by the caller and must be released with
// fringe_string_free; returned uint8_t* buffers likewise with fringe_bytes_free. Error outputs
// (char** error_json_out, may be NULL) receive {"code","message","issues":[...]}
// or are left untouched on success. No function unwinds across the boundary.
// All functions are thread-safe. A FringeField is immutable and may be read and
// rendered from several threads at once.

#define FRINGE_ABI_VERSION 3u

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
//  "source":{"kind","waist_um":[x,y],"angle_deg","w0_um"},
//  "sources":[{"id","name","enabled","kind","position_um":[x,y],"angle_deg","w0_um"}],
//  "detectors":[{"id","name","enabled","kind","points_um":[[x,y],..],"normal":[nx,ny]}]}
// or {"error":{...}}. Bodies of disabled elements are included with "enabled": false.
// "sources" lists every source; kind is plane_wave, gaussian_beam or line_source, and
// position_um is the waist (the domain centre for a plane wave) or the emitter's point
// (angle_deg and w0_um null). "source" is the first enabled source in the version 2 shape.
// "detectors" lists every detector: a line has its two end points and the unit normal its
// flux counts positive along (p1 -> p2 turned by -90 degrees); a box has its four corners
// counter-clockwise from the lower left and a null normal.
char* fringe_scene_outlines(const char* scene_json);
// The core's version 3 JSON for a scene of any readable version (a version 2 "source"
// becomes sources: [{"id":"source-1","name":"","enabled":true,...}]), or
// {"error":{"code","message"}}. NULL only for NULL input.
char* fringe_scene_upgrade(const char* scene_json);

// Materials
// The dispersive material presets: [{"id","name","kind","source","range_um":[min,max],
//  "material":{scene material JSON}}].
char* fringe_material_presets(void);
// Evaluates a scene material at wavelengths, request
// {"material":{...},"wavelengths_um":[...]} -> {"n":[...],"k":[...],"eps1":[...],"eps2":[...]}
// (optics convention n + ik, eps1 + i eps2; PEC gives nulls), or {"error":{"code","message"}}.
// NULL only for NULL input.
char* fringe_material_evaluate(const char* request_json);
// A material over a wavelength range, for plotting: count (1..10000) wavelengths evenly
// spaced from lambda_min_um to lambda_max_um, and the value at lambda0_um:
// {"wavelength_um":[...],"n":[...],"k":[...],"eps_re":[...],"eps_im":[...],
//  "at":{"wavelength_um","n","k","eps_re","eps_im"}}
// in the optics convention n + ik, eps_re + i eps_im (k, eps_im >= 0 absorb; PEC and
// non-finite values are null), or {"error":{"code","message"}}. NULL only for NULL input.
char* fringe_material_curve(const char* material_json, double lambda_min_um, double lambda_max_um,
                            uint32_t count, double lambda0_um);

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
//  "method","meta":{...,"memory_mb"},"bodies":[{"element_id","name","pec","n","k","outline"}],
//  "detectors":[reading,..]}
// meta.memory_mb is the solver's estimate of its peak memory. One reading per enabled
// detector, in scene order:
//  line: {"id","name","kind":"line","length_um","normal":[nx,ny],
//         "flux":{"total","incident","scattered"}}
//  box:  {"id","name","kind":"box","area_um2","total":{"mean","integral","max"},
//         "incident":{"mean","integral","max"},
//         "mean_intensity":{"total","incident"},"integral":{"total","incident"}}
// Flux is time-averaged power per um in z with eta0 = 1: a plane wave of amplitude A in
// background index n_b carries n_b*A^2/2 per um. Box values are |E|^2 (integral in um^2).
// The readings are measured once per field and kept.
char* fringe_field_info(const FringeField* field);
// Readings, as in fringe_field_info, of detectors_json (a JSON array of scene detectors)
// on this field, without a solve; or {"error":{"code","message","issues"}} when they do
// not parse or do not validate against the field's scene (e.g. outside the domain).
// NULL only for NULL input.
char* fringe_field_measure(const FringeField* field, const char* detectors_json);
// sum_i (weights_re[i] + j weights_im[i]) * fields[i], for fields on the same grid with the
// same bodies (such as the per-source fields of a puzzle result). Its scene is the first
// field's with each source enabled when some field with a non-zero weight has it enabled;
// its info carries the readings of the combined field. Returns a new field, or NULL and
// sets *error_json_out. For FEM and MoM the sum equals a direct solve to round-off. For
// FDTD each per-source run corrects the grid dispersion for its own source, so the sum
// differs from a direct solve by about 1e-7 of the peak for real weights and about 5e-4
// for complex ones (a phase change), well inside the FDTD's own error.
FringeField* fringe_field_combine(const FringeField* const* fields, const double* weights_re,
                                  const double* weights_im, size_t count, char** error_json_out);
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
