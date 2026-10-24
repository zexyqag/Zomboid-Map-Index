// Tests the grid script against a canvas that records what is drawn. Run: node test/grid.mjs
import { VERSION, LIMIT, cellKey, cellX, cellY, runKeys, cellMaps, cellKind, COLORS, draw, cellAt } from '../site/grid.js';

let failed = 0;
const eq = (name, actual, expected) => {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    failed++;
    console.error(`FAIL [grid]: ${name}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
};

function canvas(box = { left: 0, top: 0 }) {
  const calls = [];
  const ctx = {
    fillStyle: null, strokeStyle: null, lineWidth: null,
    setTransform: (...a) => calls.push(['setTransform', ...a]),
    fillRect: (...a) => calls.push(['fillRect', ctx.fillStyle, ...a]),
    strokeRect: (...a) => calls.push(['strokeRect', ctx.strokeStyle, ctx.lineWidth, ...a]),
    beginPath: () => calls.push(['beginPath']),
    arc: (x, y, r) => calls.push(['arc', ctx.fillStyle, ctx.strokeStyle, x, y, r]),
    fill: () => {},
    stroke: () => calls.push(['stroke', ctx.strokeStyle, ctx.lineWidth]),
    moveTo: (...a) => calls.push(['moveTo', ...a]),
    lineTo: (...a) => calls.push(['lineTo', ...a]),
  };
  return { calls, style: {}, getContext: () => ctx, getBoundingClientRect: () => box };
}
const of = (calls, name) => calls.filter(c => c[0] === name).map(c => c.slice(1));

eq('version', /^[0-9]+\.[0-9]+\.[0-9]+$/.test(VERSION), true);

// Keys: neighbours one apart in x, 2 * LIMIT in y, and back again on both sides of the origin.
for (const [x, y] of [[0, 0], [-5, 7], [LIMIT - 1, 1 - LIMIT]]) eq(`key ${x},${y}`, [cellX(cellKey(x, y)), cellY(cellKey(x, y))], [x, y]);
eq('neighbours', [cellKey(4, 9) - cellKey(3, 9), cellKey(3, 10) - cellKey(3, 9)], [1, 2 * LIMIT]);
eq('runs', runKeys([[3, 1, 2], [3, 2, 3], [-1, 0, 0]]), [cellKey(1, 3), cellKey(2, 3), cellKey(3, 3), cellKey(0, -1)]);

// Maps on cells in Map= order, and the kinds.
const k = (x, y) => cellKey(x, y);
const a = { name: 'A', item: '1', keys: [k(2, 1), k(3, 1), k(4, 1)] };
const b = { name: 'B', item: '2', keys: [k(4, 1), k(5, 1)] };
const c = { name: 'C', item: '1', keys: [k(3, 1)] };
const owners = cellMaps([a, b, c]);
eq('owners', [...owners].map(([key, here]) => [cellX(key), cellY(key), here.map(m => m.name)]),
  [[2, 1, ['A']], [3, 1, ['A', 'C']], [4, 1, ['A', 'B']], [5, 1, ['B']]]);
eq('kinds', [cellKind([a, b], false), cellKind([a, c], true), cellKind([a, c], false), cellKind(undefined, true), cellKind([], false)],
  ['shared', 'over', 'mod', 'vanilla', null]);

// Nothing to draw leaves the canvas alone.
const empty = canvas();
eq('nothing', draw(empty, { owners: new Map(), vanillaKeys: new Set(), squares: 256, width: 100 }), null);
eq('nothing drawn', empty.calls, []);

// The vanilla map on 0..3 x 0..1; A, B and C as above; an outlined map on 7,0; three spawn points on 1,0; A outlined.
const vanillaKeys = new Set(runKeys([[0, 0, 3], [1, 0, 3]]));
const points = [{ x: 256 + 128, y: 64, level: 'bad' }, { x: 256 + 32, y: 32, level: null }, { x: 256 + 64, y: 128, level: 'warn' }];
const view = { owners, vanillaKeys, others: [{ keys: [k(7, 0)] }], points, focus: a.keys, squares: 256, width: 82 };
const light = COLORS.light;
let cv = canvas();
let drawn = draw(cv, view);
eq('drawn', drawn, { minX: 0, minY: 0, size: 10, cols: 8, rows: 2, counts: { vanilla: 6, mod: 1, over: 2, shared: 1 } });
eq('canvas size', [cv.width, cv.height, cv.style], [80, 20, { width: '80px', height: '20px' }]);
eq('scale', of(cv.calls, 'setTransform'), [[1, 0, 0, 1, 0, 0]]);
eq('cells', of(cv.calls, 'fillRect'), [
  [light.vanilla, 0, 0, 9, 9], [light.vanilla, 10, 0, 9, 9], [light.vanilla, 20, 0, 9, 9], [light.vanilla, 30, 0, 9, 9],
  [light.vanilla, 0, 10, 9, 9], [light.vanilla, 10, 10, 9, 9],
  [light.over, 20, 10, 9, 9], [light.over, 30, 10, 9, 9], [light.shared, 40, 10, 9, 9], [light.mod, 50, 10, 9, 9]]);
eq('outlines', of(cv.calls, 'strokeRect'), [[light.other, 2, 71, 1, 7, 7]]);
eq('points, problems last', of(cv.calls, 'arc'), [[light.focus, light.edge, 11.25, 1.25, 2], [light.warn, light.edge, 12.5, 5, 2], [light.bad, light.edge, 15, 2.5, 2]]);
const lines = cv.calls.slice(cv.calls.findLastIndex(c => c[0] === 'beginPath'));
eq('outline of A', lines.filter(c => c[0] === 'moveTo').map(c => c.slice(1)), [
  [20, 11], [20, 19], [21, 10], [30, 11], [30, 19], [40, 11], [40, 19], [49, 10]]);
eq('outline colour', lines.at(-1), ['stroke', light.focus, 2]);
// A map two cells tall: the top edge on the upper cell only, the bottom one on the lower.
cv = canvas();
draw(cv, { ...view, focus: [k(2, 0), k(2, 1)] });
eq('outline of a column', cv.calls.slice(cv.calls.findLastIndex(c => c[0] === 'beginPath')).filter(c => c[0] === 'moveTo').map(c => c.slice(1)),
  [[20, 1], [21, 0], [29, 0], [20, 19], [21, 10], [29, 10]]);

// Dark colours, a size asked for, a sharper canvas, and small cells without gaps.
cv = canvas();
draw(cv, { ...view, dark: true, size: 20 });
eq('dark', of(cv.calls, 'fillRect')[0], [COLORS.dark.vanilla, 0, 0, 19, 19]);
globalThis.devicePixelRatio = 2;
cv = canvas();
drawn = draw(cv, { ...view, focus: null, points: [], others: [] });
eq('ratio', [cv.width, cv.height, cv.style.width, of(cv.calls, 'setTransform')[0]], [156, 52, '78px', [2, 0, 0, 2, 0, 0]]);
eq('no outline', of(cv.calls, 'moveTo'), []);
delete globalThis.devicePixelRatio;
cv = canvas();
drawn = draw(cv, { ...view, width: 20 });
eq('small cells', [drawn.size, of(cv.calls, 'fillRect')[0]], [2, [light.vanilla, 0, 0, 2, 2]]);
// The grid fits the width, at most 16 pixels a cell unless asked, at most 32, and at most 16384 pixels a side.
eq('fit cap', draw(canvas(), { ...view, width: 10000 }).size, 16);
eq('fit margin', draw(canvas(), { ...view, width: 81 }).size, 9);
eq('size cap', draw(canvas(), { ...view, size: 99 }).size, 32);
const wide = { owners: new Map(), vanillaKeys: new Set(runKeys([[0, 0, 5000]])), squares: 256, width: 100, size: 32 };
eq('side cap', draw(canvas(), wide).size, 3);
// Bounds take every kind of cell: a point (square -301 is on cell -2) and an outlined map alone.
eq('bounds', draw(canvas(), { owners: new Map(), vanillaKeys: new Set(), points: [{ x: -301, y: 600, level: null }], others: [{ keys: [k(2, 3)] }], squares: 300, width: 100 }),
  { minX: -2, minY: 2, size: 16, cols: 5, rows: 2, counts: { vanilla: 0, mod: 0, over: 0, shared: 0 } });

// The cell under a point.
cv = canvas({ left: 100, top: 50 });
drawn = draw(cv, view);
eq('at', cellAt(drawn, cv, 145, 65), { x: 4, y: 1, key: k(4, 1) });
eq('at the edge', [cellAt(drawn, cv, 99, 55), cellAt(drawn, cv, 180, 55), cellAt(drawn, cv, 105, 70), cellAt(drawn, cv, 179, 69)?.x],
  [null, null, null, 7]);
eq('at nothing', cellAt(null, cv, 0, 0), null);

if (failed) process.exit(1);
