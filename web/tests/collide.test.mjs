import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import {transformWithOxc} from 'vite';

const source = await readFile(new URL('../src/collide.ts', import.meta.url), 'utf8');
const {code} = await transformWithOxc(source, 'collide.ts');
const {Clearance} = await import(`data:text/javascript,${encodeURIComponent(code)}`);

const pose = (dx) => ({dx, dy: 0, dRot: 0, k: 1});
const square = (x) => [[x, 0], [x + 0.02, 0], [x + 0.02, 0.02], [x, 0.02]];

test('a fast drag stops before a thin neighbor', () => {
  const clearance = new Clearance([square(0)], [square(1)], [0, 0], 0.01);
  const stopped = clearance.limit(pose(0), pose(10));

  assert.ok(stopped.dx > 0.95 && stopped.dx < 0.98, `stopped at ${stopped.dx}`);
  assert.equal(clearance.clear(stopped), true);
  assert.equal(clearance.clear(pose(1)), false);
});

test('an extreme jump advances only through the checked path', () => {
  const clearance = new Clearance([square(0)], [square(100)], [0, 0], 0.01);
  const stopped = clearance.limit(pose(0), pose(1000));

  assert.ok(stopped.dx > 40 && stopped.dx < 42, `stopped at ${stopped.dx}`);
  assert.equal(clearance.clear(stopped), true);
});
