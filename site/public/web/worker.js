// Runs fringe_wasm off the main thread. One request at a time:
// {id, op, args} in, {id, ok, value | error, fatal} out.
//
// A Rust panic traps the wasm instance (panics abort on wasm32), which leaves
// it unusable. Such errors come back with fatal: true and the page replaces
// this worker. Cancelling a solve also means terminating the worker, because a
// solve runs synchronously here.
import init, * as fringe from "./pkg/fringe_wasm.js";

const ready = init();

const ops = {
  examples: () => JSON.parse(fringe.examples()),
  example: (name) => fringe.example_scene(name),
  check: (scene) => JSON.parse(fringe.check(scene)),
  solve: (scene, method, quality) => {
    const meta = JSON.parse(fringe.solve(scene, method, quality));
    meta.wasm_memory_mb = fringe.memory_bytes() / 2 ** 20;
    return meta;
  },
  render: (view, width, height) => fringe.render(view, width, height),
};

self.onmessage = async ({ data: { id, op, args } }) => {
  try {
    await ready;
    const value = ops[op](...args);
    // Hand pixel buffers over instead of copying them.
    self.postMessage({ id, ok: true, value }, value instanceof Uint8Array ? [value.buffer] : []);
  } catch (e) {
    const fatal = e instanceof WebAssembly.RuntimeError;
    self.postMessage({ id, ok: false, error: String(e?.message ?? e), fatal });
  }
};
