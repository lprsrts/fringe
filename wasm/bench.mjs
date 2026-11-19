// Times each solver on the lens example at preview quality, single-threaded,
// in node's V8 (the same engine as Chrome). Usage: node bench.mjs [runs] [pkg dir]
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const runs = Number(process.argv[2] ?? 3);
const w = require(`./${process.argv[3] ?? "pkg"}/fringe_wasm.js`);
const scene = w.example_scene("lens");
for (const method of ["mom", "fdtd", "fem"]) {
  const times = [];
  let out;
  for (let r = 0; r < runs; r++) {
    const t0 = performance.now();
    out = w.solve(scene, method, "preview");
    times.push((performance.now() - t0) / 1000);
  }
  const [nx, ny, wall, estMb] = out;
  let max = 0, sum = 0;
  for (let i = 4; i < out.length; i++) { max = Math.max(max, out[i]); sum += out[i]; }
  times.sort((a, b) => a - b);
  console.log(JSON.stringify({
    method, grid: `${nx}x${ny}`, first_s: +times.at(-1).toFixed(3), best_s: +times[0].toFixed(3),
    median_s: +times[Math.floor(times.length / 2)].toFixed(3), core_wall_s: +wall.toFixed(3),
    est_mb: Math.round(estMb), wasm_mem_mb: Math.round(w.memory_bytes() / 2 ** 20),
    max_I: +max.toFixed(4), mean_I: +(sum / (out.length - 4)).toFixed(5),
  }));
  const meta = JSON.parse(w.last_meta());
  if (meta.timings) console.log("  stages:", JSON.stringify(meta.timings));
}
