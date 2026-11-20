// Runs fringe_wasm off the main thread, one request at a time:
// {id, op, args} in, {id, ok, value | error, fatal} out.
//
// A Rust panic traps the wasm instance (panics abort on wasm32) and leaves it
// unusable, so such errors come back with fatal: true and the page replaces
// this worker. Stopping a solve also replaces the worker: a solve runs
// synchronously here and can't be interrupted.
import init, * as fringe from './pkg/fringe_wasm.js';

const ready = init();

const memMb = () => fringe.memory_bytes() / 2 ** 20;

const ops = {
  examples: () => JSON.parse(fringe.examples()),
  example: (name: string) => fringe.example_scene(name),
  materialPresets: () => JSON.parse(fringe.material_presets()),
  outlines: (scene: string) => JSON.parse(fringe.outlines(scene)),
  check: (scene: string) => JSON.parse(fringe.check(scene)),
  solve: (scene: string, method: string, quality: string) => {
    const meta = JSON.parse(fringe.solve(scene, method, quality));
    meta.wasm_memory_mb = memMb();
    return meta;
  },
  measureDetectors: (detectorsJson: string) => JSON.parse(fringe.measure_detectors(detectorsJson)),
  render: (view: string, width: number, height: number) => fringe.render(view, width, height),
  puzzles: () => JSON.parse(fringe.puzzles()),
  puzzle: (id: string) => JSON.parse(fringe.puzzle(id)),
  puzzleCheck: (id: string, designJson: string) => JSON.parse(fringe.puzzle_check(id, designJson)),
  puzzleEvaluate: (id: string, designJson: string) => {
    const res = JSON.parse(fringe.puzzle_evaluate(id, designJson));
    res.wasm_memory_mb = memMb();
    return res;
  },
  selectPuzzleCase: (weights: number[]) => {
    const meta = JSON.parse(fringe.select_puzzle_case(new Float64Array(weights)));
    meta.wasm_memory_mb = memMb();
    return meta;
  },
  clearPuzzleFields: () => {
    fringe.clear_puzzle_fields();
    return null;
  },
} as const;

type Op = keyof typeof ops;

self.onmessage = async ({data: {id, op, args}}: MessageEvent<{id: number; op: Op; args: unknown[]}>) => {
  try {
    await ready;
    const value = (ops[op] as (...a: unknown[]) => unknown)(...args);
    // Hand pixel buffers over instead of copying them.
    const transfer = value instanceof Uint8Array ? [value.buffer as ArrayBuffer] : [];
    (self as unknown as Worker).postMessage({id, ok: true, value}, transfer);
  } catch (e) {
    const fatal = e instanceof WebAssembly.RuntimeError;
    self.postMessage({id, ok: false, error: String((e as Error)?.message ?? e), fatal});
  }
};
