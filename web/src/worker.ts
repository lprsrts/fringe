// Runs fringe_wasm off the main thread, one request at a time:
// {id, op, args} in, {id, ok, value | error, fatal} out.
//
// A Rust panic traps the wasm instance (panics abort on wasm32) and leaves it
// unusable, so such errors come back with fatal: true and the page replaces
// this worker. Stopping a solve also replaces the worker: a solve runs
// synchronously here and can't be interrupted.
import init, * as fringe from './pkg/fringe_wasm.js';

const ready = init();

const ops = {
  examples: () => JSON.parse(fringe.examples()),
  example: (name: string) => fringe.example_scene(name),
  check: (scene: string) => JSON.parse(fringe.check(scene)),
  solve: (scene: string, method: string, quality: string) => {
    const meta = JSON.parse(fringe.solve(scene, method, quality));
    meta.wasm_memory_mb = fringe.memory_bytes() / 2 ** 20;
    return meta;
  },
  render: (view: string, width: number, height: number) => fringe.render(view, width, height),
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
