// Shareable state in the URL hash, so a link or an iframe carries the scene:
//   #ex=lens                    a built-in example, unmodified
//   #s=<base64url deflate-raw>  any scene, as compressed scene JSON
//   &m=fdtd|mom|fem             solver override
//   &q=intensity|real|...       displayed quantity, &c=<colormap>, &a=1 animate
//   embed                       only the field, for an <iframe>
// The hash never reaches a server, so links work on any static host.

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

export async function decompress(text: string) {
  return new TextDecoder().decode(await pipe(fromBase64Url(text), new DecompressionStream('deflate-raw') as unknown as ReadableWritablePair<Uint8Array, Uint8Array>));
}

export function readLink(hash = location.hash): LinkState {
  const p = new URLSearchParams(hash.slice(1));
  return {
    embed: p.has('embed'),
    example: p.get('ex'),
    scene: p.get('s'),
    method: p.get('m') ?? '',
    quantity: p.get('q'),
    colormap: p.get('c') ?? '',
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
