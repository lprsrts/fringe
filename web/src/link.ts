// Shareable state in the URL hash, so a link or an iframe carries the scene:
//   #ex=lens                    a built-in example, unmodified
//   #s=<base64url deflate-raw>  any scene, as compressed scene JSON
//   &m=fdtd|mom|fem             solver override
//   &q=intensity|real|...       displayed quantity, &c=<colormap>, &a=1 animate
//   embed                       only the field, for an <iframe>
// The hash never reaches a server, so links work on any static host.

/** The longest #s= the page will read, and the most JSON it will inflate to. A
 * real scene is a few hundred to a few thousand characters either way. */
export const MAX_LINK_CHARS = 32_000;
export const MAX_SCENE_BYTES = 1_000_000;

export const METHODS = ['fdtd', 'mom', 'fem'] as const;
export const QUANTITIES = ['intensity', 'real', 'magnitude', 'phase'] as const;
export const COLORMAPS = [
  'inferno', 'viridis', 'plasma', 'turbo', 'laser_glow', 'spectral_glow',
  'asympton', 'rdbu', 'twilight', 'phase_wheel',
] as const;

const oneOf = <T extends string>(allowed: readonly T[], v: string | null): T | null =>
  v !== null && (allowed as readonly string[]).includes(v) ? (v as T) : null;

export interface LinkState {
  embed: boolean;
  example: string | null;
  scene: string | null;
  method: string;
  quantity: string | null;
  colormap: string;
  animate: boolean;
}

function toBase64Url(bytes: Uint8Array) {
  let s = '';
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function fromBase64Url(text: string) {
  const s = atob(text.replace(/-/g, '+').replace(/_/g, '/'));
  return Uint8Array.from(s, (c) => c.charCodeAt(0));
}

async function pipe(bytes: Uint8Array, stream: ReadableWritablePair<Uint8Array, Uint8Array>) {
  const out = new Blob([bytes as BlobPart]).stream().pipeThrough(stream);
  return new Uint8Array(await new Response(out).arrayBuffer());
}

export async function compress(text: string) {
  return toBase64Url(await pipe(new TextEncoder().encode(text), new CompressionStream('deflate-raw') as unknown as ReadableWritablePair<Uint8Array, Uint8Array>));
}

/** Inflates a #s= value, refusing oversized input and stopping as soon as the
 * output passes MAX_SCENE_BYTES, so a crafted link can't fill memory. */
export async function decompress(text: string) {
  if (text.length > MAX_LINK_CHARS) throw new Error('the scene in this link is too long');
  const inflated = new Blob([fromBase64Url(text) as BlobPart])
    .stream()
    .pipeThrough(new DecompressionStream('deflate-raw') as unknown as ReadableWritablePair<Uint8Array, Uint8Array>);
  const reader = inflated.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const {done, value} = await reader.read();
    if (done) break;
    total += value.length;
    if (total > MAX_SCENE_BYTES) {
      await reader.cancel();
      throw new Error('the scene in this link is too large');
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(total);
  let at = 0;
  for (const c of chunks) {
    bytes.set(c, at);
    at += c.length;
  }
  return new TextDecoder().decode(bytes);
}

export function readLink(hash = location.hash): LinkState {
  const p = new URLSearchParams(hash.slice(1));
  return {
    embed: p.has('embed'),
    example: p.get('ex'),
    scene: p.get('s'),
    method: oneOf(METHODS, p.get('m')) ?? '',
    quantity: oneOf(QUANTITIES, p.get('q')),
    colormap: oneOf(COLORMAPS, p.get('c')) ?? '',
    animate: p.get('a') === '1',
  };
}

export async function writeLink(state: {
  example: string | null;
  sceneJson: string;
  method: string;
  quantity: string;
  colormap: string;
  animate: boolean;
  embed?: boolean;
}) {
  const p = new URLSearchParams();
  if (state.embed) p.set('embed', '');
  if (state.example) p.set('ex', state.example);
  else p.set('s', await compress(state.sceneJson));
  if (state.method) p.set('m', state.method);
  if (state.quantity !== 'intensity') p.set('q', state.quantity);
  if (state.colormap) p.set('c', state.colormap);
  if (state.animate) p.set('a', '1');
  return p.toString().replace(/^embed=&/, 'embed&');
}

export const pageUrl = () => location.href.split('#')[0];
