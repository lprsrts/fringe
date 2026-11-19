// Fringe in the browser: pick or edit a scene, solve it in a Web Worker with the
// Rust core compiled to WebAssembly, render it with the core's own colormaps,
// and share it as a link or an <iframe>.
//
// State lives in the URL hash so any view can be shared:
//   #ex=lens                    a built-in example, unmodified
//   #s=<base64url deflate-raw>  any scene, as compressed scene JSON
//   &m=fdtd|mom|fem             solver override
//   &q=intensity|real|...       displayed quantity, &c=<colormap>, &a=1 animate
//   embed                       just the field, for an <iframe>

const $ = (id) => document.getElementById(id);
const ui = {
  example: $("example"), method: $("method"), quantity: $("quantity"), colormap: $("colormap"),
  animate: $("animate"), solve: $("solve"), cancel: $("cancel"), share: $("share"),
  embedBtn: $("embed-btn"), png: $("png"), canvas: $("field"), overlay: $("overlay"),
  status: $("status"), issues: $("issues"), scene: $("scene"), editor: $("editor"),
  openFull: $("open-full"), embedDialog: $("embed-dialog"), embedCode: $("embed-code"),
  embedCopy: $("embed-copy"),
};
const ctx2d = ui.canvas.getContext("2d");

// ---- worker -----------------------------------------------------------------

let worker, nextId = 0;
const pending = new Map();

function startWorker() {
  worker = new Worker(new URL("./worker.js", import.meta.url), { type: "module" });
  worker.onmessage = ({ data }) => {
    const p = pending.get(data.id);
    if (!p) return;
    pending.delete(data.id);
    if (data.ok) p.resolve(data.value);
    else {
      if (data.fatal) restartWorker("the solver crashed");
      p.reject(new Error(data.error));
    }
  };
  worker.onerror = (e) => {
    e.preventDefault();
    restartWorker(e.message || "the worker failed to start");
  };
}

/** Drops the worker (and the wasm instance and field in it) and starts a new one. */
function restartWorker(reason) {
  worker.terminate();
  for (const p of pending.values()) p.reject(new Error(reason));
  pending.clear();
  hasField = false;
  startWorker();
}

function call(op, ...args) {
  return new Promise((resolve, reject) => {
    const id = nextId++;
    pending.set(id, { resolve, reject });
    worker.postMessage({ id, op, args });
  });
}

// ---- URL state --------------------------------------------------------------

const b64url = {
  encode(bytes) {
    let s = "";
    for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  },
  decode(text) {
    const s = atob(text.replace(/-/g, "+").replace(/_/g, "/"));
    return Uint8Array.from(s, (c) => c.charCodeAt(0));
  },
};

async function pipe(bytes, stream) {
  return new Uint8Array(await new Response(new Blob([bytes]).stream().pipeThrough(stream)).arrayBuffer());
}
const compress = async (text) => b64url.encode(await pipe(new TextEncoder().encode(text), new CompressionStream("deflate-raw")));
const decompress = async (text) => new TextDecoder().decode(await pipe(b64url.decode(text), new DecompressionStream("deflate-raw")));

function readHash() {
  const params = new URLSearchParams(location.hash.slice(1));
  return {
    embed: params.has("embed"),
    example: params.get("ex"),
    scene: params.get("s"),
    method: params.get("m") ?? "",
    quantity: params.get("q"),
    colormap: params.get("c") ?? "",
    animate: params.get("a") === "1",
  };
}

/** The hash for the current state: the example's name when the scene is one, else the scene itself. */
async function stateHash({ embed = false } = {}) {
  const p = new URLSearchParams();
  const text = ui.scene.value;
  if (ui.example.value && text === exampleText.get(ui.example.value)) p.set("ex", ui.example.value);
  else p.set("s", await compress(JSON.stringify(JSON.parse(text))));
  if (ui.method.value) p.set("m", ui.method.value);
  if (ui.quantity.value !== "intensity") p.set("q", ui.quantity.value);
  if (ui.colormap.value) p.set("c", ui.colormap.value);
  if (ui.animate.checked) p.set("a", "1");
  const hash = p.toString();
  return embed ? `embed&${hash}` : hash;
}

async function syncHash() {
  if (embedded) return;
  try {
    history.replaceState(null, "", `#${await stateHash()}`);
  } catch {
    // Invalid JSON in the editor: leave the last good URL.
  }
}

// ---- solving and drawing ----------------------------------------------------

let examples = [];
const exampleText = new Map();
let hasField = false, solving = false, grid = null, solveSeq = 0;
let phaseDeg = 0, rendering = false, renderAgain = false;

function setOverlay(text) {
  ui.overlay.hidden = !text;
  ui.overlay.textContent = text ?? "";
}

function view() {
  const q = ui.quantity.value;
  const fallback = { intensity: "inferno", magnitude: "inferno", real: "rdbu", phase: "twilight" }[q];
  const animated = ui.animate.checked && (q === "real" || q === "phase");
  return JSON.stringify({
    quantity: q,
    colormap: ui.colormap.value || exampleColormap() || fallback,
    phase_deg: animated ? phaseDeg : 0,
    // The auto scale comes from |E|, which doesn't change with the phase, so
    // the colors hold still while an animation turns it.
    outlines: true,
  });
}

/** The example's suggested colormap, when the shown quantity is the one it suggests. */
function exampleColormap() {
  const e = examples.find((x) => x.name === ui.example.value);
  return e && e.quantity === ui.quantity.value ? e.colormap : "";
}

function sizeCanvas() {
  if (!grid) return;
  const cssWidth = embedded ? window.innerWidth : ui.canvas.parentElement.clientWidth;
  const cssHeight = embedded ? window.innerHeight : cssWidth * (grid.ny / grid.nx);
  const scale = Math.min(cssWidth / grid.nx, cssHeight / grid.ny);
  const dpr = Math.min(window.devicePixelRatio || 1, 2);
  ui.canvas.width = Math.max(1, Math.round(grid.nx * scale * dpr));
  ui.canvas.height = Math.max(1, Math.round(grid.ny * scale * dpr));
}

async function draw() {
  if (!hasField) return;
  if (rendering) { renderAgain = true; return; }
  rendering = true;
  try {
    const { width, height } = ui.canvas;
    const rgba = await call("render", view(), width, height);
    ctx2d.putImageData(new ImageData(new Uint8ClampedArray(rgba.buffer), width, height), 0, 0);
  } catch (e) {
    ui.status.textContent = `render failed: ${e.message}`;
  } finally {
    rendering = false;
  }
  if (renderAgain) { renderAgain = false; draw(); }
}

function animationLoop() {
  const q = ui.quantity.value;
  if (ui.animate.checked && hasField && !solving && (q === "real" || q === "phase")) {
    if (!rendering) {
      phaseDeg = (phaseDeg + 6) % 360;
      draw();
    }
  }
  requestAnimationFrame(animationLoop);
}

const fmtTime = (s) => (s < 1 ? `${Math.round(s * 1000)} ms` : `${s.toFixed(2)} s`);

async function solve() {
  if (solving) return;
  const seq = ++solveSeq;
  let text = ui.scene.value;
  try {
    text = JSON.stringify(JSON.parse(text));
  } catch (e) {
    showIssues([{ severity: "error", path: "", message: `invalid JSON: ${e.message}` }]);
    return;
  }
  const report = await call("check", text).catch((e) => ({ ok: false, issues: [{ severity: "error", path: "", message: e.message }] }));
  showIssues(report.issues);
  if (!report.ok) { ui.status.textContent = "fix the errors above to solve"; return; }

  solving = true;
  ui.solve.disabled = true;
  ui.cancel.hidden = embedded;
  const t0 = performance.now();
  const method = ui.method.value;
  const est = report.estimates?.preview;
  const label = (est?.method ?? method).toUpperCase().replace("MOM", "MoM");
  const tick = setInterval(() => setOverlay(`solving with ${label}… ${fmtTime((performance.now() - t0) / 1000)}`), 100);
  setOverlay(`solving with ${label}…`);
  try {
    const meta = await call("solve", text, method, "preview");
    if (seq !== solveSeq) return;
    grid = { nx: meta.nx, ny: meta.ny };
    hasField = true;
    sizeCanvas();
    await draw();
    const wall = (performance.now() - t0) / 1000;
    ui.status.textContent = `${meta.method.toUpperCase().replace("MOM", "MoM")} · ${meta.nx}×${meta.ny} · ` +
      `solved in ${fmtTime(meta.wall_s)} (${fmtTime(wall)} with transfer and drawing) · ` +
      `${Math.round(meta.wasm_memory_mb)} MB · preview quality, one thread`;
    setOverlay(null);
  } catch (e) {
    if (seq !== solveSeq) return;
    setOverlay(hasField ? null : "no field");
    ui.status.textContent = `solve failed: ${e.message}`;
  } finally {
    clearInterval(tick);
    if (seq === solveSeq) {
      solving = false;
      ui.solve.disabled = false;
      ui.cancel.hidden = true;
    }
  }
}

function cancel() {
  solveSeq++;
  solving = false;
  restartWorker("cancelled");
  ui.solve.disabled = false;
  ui.cancel.hidden = true;
  setOverlay(null);
  ctx2d.clearRect(0, 0, ui.canvas.width, ui.canvas.height);
  ui.status.textContent = "cancelled";
}

function showIssues(issues = []) {
  ui.issues.replaceChildren(...issues.map((i) => {
    const li = document.createElement("li");
    li.className = i.severity;
    li.textContent = `${i.severity}${i.path ? ` at ${i.path}` : ""}: ${i.message}`;
    return li;
  }));
}

// ---- controls ---------------------------------------------------------------

async function loadExample(name) {
  if (!exampleText.has(name)) exampleText.set(name, await call("example", name));
  ui.scene.value = exampleText.get(name);
  ui.example.value = name;
  const e = examples.find((x) => x.name === name);
  if (e) ui.quantity.value = e.quantity;
}

ui.example.onchange = async () => {
  if (!ui.example.value) return;
  await loadExample(ui.example.value);
  ui.colormap.value = "";
  syncHash();
  solve();
};
ui.method.onchange = () => { syncHash(); solve(); };
for (const el of [ui.quantity, ui.colormap, ui.animate]) el.onchange = () => { phaseDeg = 0; syncHash(); draw(); };
ui.scene.oninput = () => {
  if (ui.example.value && ui.scene.value !== exampleText.get(ui.example.value)) ui.example.value = "";
};
ui.scene.onchange = syncHash;
ui.solve.onclick = () => { syncHash(); solve(); };
ui.cancel.onclick = cancel;
document.addEventListener("keydown", (e) => {
  if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) { e.preventDefault(); syncHash(); solve(); }
});

async function copy(text, button) {
  const label = button.textContent;
  try {
    await navigator.clipboard.writeText(text);
    button.textContent = "copied";
  } catch {
    button.textContent = "copy failed";
  }
  setTimeout(() => (button.textContent = label), 1500);
}

const pageUrl = () => location.href.split("#")[0];

ui.share.onclick = async () => {
  try {
    const url = `${pageUrl()}#${await stateHash()}`;
    history.replaceState(null, "", url);
    copy(url, ui.share);
  } catch (e) {
    ui.status.textContent = `can't share: ${e.message}`;
  }
};

ui.embedBtn.onclick = async () => {
  try {
    const src = `${pageUrl()}#${await stateHash({ embed: true })}`;
    const aspect = grid ? grid.ny / grid.nx : 9 / 16;
    const attr = (s) => s.replace(/&/g, "&amp;").replace(/"/g, "&quot;");
    ui.embedCode.value = `<iframe src="${attr(src)}" width="640" height="${Math.round(640 * aspect)}" ` +
      `style="border:0;border-radius:8px" loading="lazy" title="Fringe simulation"></iframe>`;
    ui.embedDialog.showModal();
    ui.embedCode.select();
  } catch (e) {
    ui.status.textContent = `can't embed: ${e.message}`;
  }
};
ui.embedCopy.onclick = () => copy(ui.embedCode.value, ui.embedCopy);

ui.png.onclick = () => {
  if (!hasField) return;
  ui.canvas.toBlob((blob) => {
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = `fringe-${ui.example.value || "scene"}.png`;
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 1000);
  });
};

let resizeTimer;
window.addEventListener("resize", () => {
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(() => { sizeCanvas(); draw(); }, 150);
});

// ---- start ------------------------------------------------------------------

const state = readHash();
const embedded = state.embed;
document.body.classList.toggle("embed", embedded);

async function start() {
  startWorker();
  examples = await call("examples");
  for (const e of examples) {
    const o = document.createElement("option");
    o.value = e.name;
    o.textContent = `${e.name} · ${e.method}`;
    o.title = e.title;
    ui.example.append(o);
  }
  if (state.scene) {
    try {
      ui.scene.value = JSON.stringify(JSON.parse(await decompress(state.scene)), null, 2);
      ui.example.value = "";
    } catch {
      ui.status.textContent = "the link's scene couldn't be read; showing the lens instead";
      await loadExample("lens");
    }
  } else {
    await loadExample(examples.some((e) => e.name === state.example) ? state.example : "lens");
  }
  ui.method.value = state.method;
  if (state.quantity) ui.quantity.value = state.quantity;
  ui.colormap.value = state.colormap;
  ui.animate.checked = state.animate;

  if (embedded) {
    const full = new URLSearchParams(location.hash.slice(1));
    full.delete("embed");
    ui.openFull.href = `${pageUrl()}#${full}`;
    ui.openFull.hidden = false;
    // An embed further down a page solves when it scrolls into view.
    await new Promise((resolve) => {
      const io = new IntersectionObserver((entries) => {
        if (entries.some((e) => e.isIntersecting)) { io.disconnect(); resolve(); }
      });
      io.observe(ui.canvas);
    });
  }
  setOverlay(null);
  requestAnimationFrame(animationLoop);
  await solve();
}

window.addEventListener("hashchange", () => location.reload());

start().catch((e) => {
  setOverlay(`couldn't start: ${e.message}`);
  console.error(e);
});
