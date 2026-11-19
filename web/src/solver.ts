// The page's side of the worker: typed calls, and replacing the worker (with
// its wasm instance and stored field) when a solve is stopped or crashes.

export interface Example {
  name: string;
  title: string;
  method: string;
  quantity: string;
  colormap: string;
}

export interface Issue {
  path: string;
  code?: string;
  severity: 'error' | 'warning' | 'info';
  message: string;
}

export interface CheckReport {
  ok: boolean;
  issues: Issue[];
  estimates?: {preview?: {method: string; seconds: number; memory_mb: number} | null} | null;
}

export interface SolveMeta {
  method: string;
  nx: number;
  ny: number;
  wall_s: number;
  wasm_memory_mb: number;
}

type Pending = {resolve: (v: unknown) => void; reject: (e: Error) => void};

export class Solver {
  private worker!: Worker;
  private nextId = 0;
  private pending = new Map<number, Pending>();
  /** Called when the worker was replaced, so the page knows the stored field is gone. */
  onReset: (reason: string) => void = () => {};

  constructor() {
    this.start();
  }

  private start() {
    this.worker = new Worker(new URL('./worker.ts', import.meta.url), {type: 'module'});
    this.worker.onmessage = ({data}) => {
      const p = this.pending.get(data.id);
      if (!p) return;
      this.pending.delete(data.id);
      if (data.ok) p.resolve(data.value);
      else {
        if (data.fatal) this.reset('The solver crashed and was restarted.');
        p.reject(new Error(data.error));
      }
    };
    this.worker.onerror = (e) => {
      e.preventDefault();
      this.reset(e.message || 'The solver failed to start.');
    };
  }

  /** Drops the worker and everything in it, and starts a fresh one. */
  reset(reason: string) {
    this.worker.terminate();
    for (const p of this.pending.values()) p.reject(new Error(reason));
    this.pending.clear();
    this.start();
    this.onReset(reason);
  }

  private call<T>(op: string, ...args: unknown[]): Promise<T> {
    return new Promise((resolve, reject) => {
      const id = this.nextId++;
      this.pending.set(id, {resolve: resolve as (v: unknown) => void, reject});
      this.worker.postMessage({id, op, args});
    });
  }

  examples = () => this.call<Example[]>('examples');
  example = (name: string) => this.call<string>('example', name);
  check = (scene: string) => this.call<CheckReport>('check', scene);
  solve = (scene: string, method: string) => this.call<SolveMeta>('solve', scene, method, 'preview');
  render = (view: string, width: number, height: number) => this.call<Uint8Array>('render', view, width, height);
}
