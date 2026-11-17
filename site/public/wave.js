// A plane wave hits a wall with two slits, and the field behind it is the sum of
// Huygens wavelets from points across each slit: Young's double slit, the textbook
// version of what Fringe solves in full. The complex field is computed once; each
// frame only turns its phase (Re{U e^{-iωt}}), so it costs one multiply-add per pixel.
(() => {
  const canvas = document.querySelector("canvas.field");
  if (!canvas) return;
  const W = 640, H = 320;
  canvas.width = W;
  canvas.height = H;
  const ctx = canvas.getContext("2d");
  const image = ctx.createImageData(W, H);

  const lambda = 13;                       // wavelength in pixels
  const k = (2 * Math.PI) / lambda;
  const wall = 150;                        // x of the wall
  const half = 3;                          // wall half-thickness
  const slits = [H / 2 - 34, H / 2 + 34];  // slit centres
  const slitHalf = 7;                      // slit half-width
  const samples = 9;                       // wavelets per slit

  const re0 = new Float32Array(W * H), im0 = new Float32Array(W * H);
  const isWall = new Uint8Array(W * H);
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const i = y * W + x;
      if (Math.abs(x - wall) <= half) {
        const open = slits.some((c) => Math.abs(y - c) <= slitHalf);
        if (!open) { isWall[i] = 1; continue; }
      }
      if (x < wall) {
        // incident plane wave, a little dimmer so the fringes are the subject
        re0[i] = 0.4 * Math.cos(k * x);
        im0[i] = 0.4 * Math.sin(k * x);
        continue;
      }
      let re = 0, im = 0;
      for (const c of slits) {
        for (let s = 0; s < samples; s++) {
          const sy = c - slitHalf + (2 * slitHalf * (s + 0.5)) / samples;
          const dx = x - wall, dy = y - sy;
          const r = Math.max(1, Math.hypot(dx, dy));
          // 2D Green's function far form: e^{ikr}/sqrt(r), with an obliquity factor
          const a = (dx / r + 1) / (2 * Math.sqrt(r));
          const phase = k * (r + wall);
          re += a * Math.cos(phase);
          im += a * Math.sin(phase);
        }
      }
      re0[i] = re * 1.9 / samples;
      im0[i] = im * 1.9 / samples;
    }
  }

  // brand ramp: troughs fade into graphite and slate, crests into fringe yellow
  const bg = [11, 13, 15], slate = [58, 66, 73], yellow = [243, 198, 35], white = [255, 246, 216];
  const mix = (a, b, t) => [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t];
  const color = (v) => {
    if (v < 0) return mix(bg, slate, Math.min(1, -v) * 0.55);
    if (v < 0.7) return mix(bg, yellow, v / 0.7);
    return mix(yellow, white, Math.min(1, (v - 0.7) / 0.3));
  };
  const lut = new Uint8ClampedArray(512 * 3);
  for (let j = 0; j < 512; j++) lut.set(color(j / 255.5 - 1), j * 3);

  // Brightness follows the local amplitude |U| raised to 0.55: the cancellation lines
  // between the fringes stay dark, and the far field isn't lost next to the slits.
  const amp = new Float32Array(W * H);
  for (let i = 0; i < W * H; i++) amp[i] = Math.hypot(re0[i], im0[i]);
  const sorted = Float32Array.from(amp.filter((a, i) => !isWall[i])).sort();
  const ref = sorted[Math.floor(sorted.length * 0.97)] || 1;
  const gain = new Float32Array(W * H);
  for (let i = 0; i < W * H; i++) gain[i] = amp[i] > 0 ? Math.pow(amp[i] / ref, 0.55) / amp[i] : 0;

  const data = image.data;
  const draw = (t) => {
    const c = Math.cos(t), s = Math.sin(t);
    for (let i = 0, p = 0; i < W * H; i++, p += 4) {
      if (isWall[i]) { data[p] = 46; data[p + 1] = 50; data[p + 2] = 55; data[p + 3] = 255; continue; }
      const v = (re0[i] * c + im0[i] * s) * gain[i];
      const j = Math.max(0, Math.min(511, Math.round((v + 1) * 255.5))) * 3;
      data[p] = lut[j]; data[p + 1] = lut[j + 1]; data[p + 2] = lut[j + 2]; data[p + 3] = 255;
    }
    ctx.putImageData(image, 0, 0);
  };

  const still = matchMedia("(prefers-reduced-motion: reduce)");
  let visible = true, start = performance.now(), frame = 0;
  const loop = (now) => {
    frame = 0;
    if (!visible || still.matches) return;
    draw(-((now - start) / 1000) * 2.4);   // about one optical cycle per 2.6 s
    frame = requestAnimationFrame(loop);
  };
  const resume = () => { if (!frame && visible && !still.matches) frame = requestAnimationFrame(loop); };
  new IntersectionObserver(([e]) => { visible = e.isIntersecting; resume(); }).observe(canvas);
  still.addEventListener("change", () => { draw(0); resume(); });
  draw(0);
  resume();
})();
