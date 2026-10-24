// The cells of Project Zomboid maps on a canvas: the maps on each cell in Map= order, the first being the one the game
// takes first, what kind of cell that makes, and how it looks. Pages that show maps share it; it needs only a 2D
// canvas. A change to how pages call it gets a new major version, published as grid-<major>.js.

export const VERSION = '1.0.0';

// One number per cell, for cells within LIMIT of the origin.
export const LIMIT = 1 << 20;
export const cellKey = (x, y) => (y + LIMIT) * 2 * LIMIT + x + LIMIT;
export const cellX = key => (key % (2 * LIMIT)) - LIMIT;
export const cellY = key => Math.floor(key / (2 * LIMIT)) - LIMIT;

// The keys of the cells in runs [y, first x, last x], each once.
export function runKeys(runs) {
  const keys = new Set();
  for (const [y, from, to] of runs) for (let x = from; x <= to; x++) keys.add(cellKey(x, y));
  return [...keys];
}

// The maps on each cell, from maps in Map= order without the vanilla map: {keys, item} and whatever else a page keeps.
export function cellMaps(maps) {
  const owners = new Map();
  for (const m of maps) {
    for (const key of m.keys) {
      const here = owners.get(key);
      if (here) here.push(m);
      else owners.set(key, [m]);
    }
  }
  return owners;
}

// A cell with maps of different items, maps of one item over the vanilla map or not, or the vanilla map alone.
export function cellKind(here, vanilla) {
  if (here?.length) return here.some(m => m.item !== here[0].item) ? 'shared' : vanilla ? 'over' : 'mod';
  return vanilla ? 'vanilla' : null;
}

// The kinds of cell, outlined maps of mods that don't load (other), the map outlined in full and spawn points without
// a problem (focus), points with one (warn, bad) and the ring around points (edge), for light and dark pages.
export const COLORS = {
  light: {
    vanilla: '#d6d6cf', mod: '#3f74b8', over: '#d39b16', shared: '#c43a2f', other: '#8a4fc4', focus: '#1d1d1b',
    warn: '#8a5a00', bad: '#b3261e', edge: '#f7f7f5',
  },
  dark: {
    vanilla: '#3b3d36', mod: '#6f9fe0', over: '#e8b94a', shared: '#f07a6c', other: '#c39af0', focus: '#f4f4ee',
    warn: '#e3b558', bad: '#f08c7e', edge: '#161714',
  },
};

// Draws on canvas view's owners (cellMaps of the maps in Map=) and vanillaKeys, others (maps only outlined, {keys}),
// points (spawn points {x, y, level} in squares, level null, 'warn' or 'bad'), the keys of the map to outline in full
// (focus, or null), in cells of squares squares (300 for Build 41, 256 after), size pixels a cell (null to fit width
// pixels) and the colours of COLORS[dark ? 'dark' : 'light']. Returns where it drew, for cellAt, and the number of
// cells of each kind, or null when there is nothing to draw.
export function draw(canvas, view) {
  const { owners, vanillaKeys, others = [], points = [], focus = null, squares, size: wanted = null, width, dark = false } = view;
  const colors = COLORS[dark ? 'dark' : 'light'];
  const pointKey = pt => cellKey(Math.floor(pt.x / squares), Math.floor(pt.y / squares));
  let minX = Infinity;
  let minY = Infinity;
  let maxX = -Infinity;
  let maxY = -Infinity;
  for (const keys of [vanillaKeys, owners.keys(), ...others.map(o => o.keys), points.map(pointKey)]) {
    for (const key of keys) {
      const x = cellX(key);
      const y = cellY(key);
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
  }
  if (minX === Infinity) return null;
  const cols = maxX - minX + 1;
  const rows = maxY - minY + 1;
  // A canvas side stays within 16384 pixels, which browsers draw.
  const fit = Math.max(1, Math.min(16, Math.floor((width - 2) / cols)));
  const size = Math.max(1, Math.min(32, wanted ?? fit, Math.floor(16384 / Math.max(cols, rows))));
  const ratio = Math.min(globalThis.devicePixelRatio || 1, Math.max(1, Math.floor(16384 / (Math.max(cols, rows) * size))));
  canvas.width = cols * size * ratio;
  canvas.height = rows * size * ratio;
  canvas.style.width = `${cols * size}px`;
  canvas.style.height = `${rows * size}px`;
  const ctx = canvas.getContext('2d');
  ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
  const gap = size >= 5 ? 1 : 0;
  const fill = (key, color) => {
    ctx.fillStyle = color;
    ctx.fillRect((cellX(key) - minX) * size, (cellY(key) - minY) * size, size - gap, size - gap);
  };
  const counts = { vanilla: 0, mod: 0, over: 0, shared: 0 };
  for (const key of vanillaKeys) {
    if (owners.has(key)) continue;
    counts.vanilla++;
    fill(key, colors.vanilla);
  }
  for (const [key, here] of owners) {
    const kind = cellKind(here, vanillaKeys.has(key));
    counts[kind]++;
    fill(key, colors[kind]);
  }
  ctx.strokeStyle = colors.other;
  ctx.lineWidth = Math.max(1, Math.min(2, size / 4));
  const inset = ctx.lineWidth / 2;
  for (const o of others) {
    for (const key of o.keys) ctx.strokeRect((cellX(key) - minX) * size + inset, (cellY(key) - minY) * size + inset, size - 2 * inset - gap, size - 2 * inset - gap);
  }
  // Spawn points where they are inside their cells, after the cells and outlines so they stay visible, and those with a
  // problem last, so that none hides under a point without one.
  const radius = Math.max(1.5, Math.min(4, size / 5));
  ctx.lineWidth = 1;
  ctx.strokeStyle = colors.edge;
  const rank = { null: 0, warn: 1, bad: 2 };
  for (const pt of [...points].sort((a, b) => rank[a.level] - rank[b.level])) {
    ctx.fillStyle = pt.level ? colors[pt.level] : colors.focus;
    ctx.beginPath();
    ctx.arc((pt.x / squares - minX) * size, (pt.y / squares - minY) * size, radius, 0, 2 * Math.PI);
    ctx.fill();
    ctx.stroke();
  }
  if (focus) {
    // The outline of its area: the cell edges that no other cell of the map shares.
    const own = new Set(focus);
    ctx.strokeStyle = colors.focus;
    ctx.lineWidth = 2;
    ctx.beginPath();
    for (const key of own) {
      const x = (cellX(key) - minX) * size;
      const y = (cellY(key) - minY) * size;
      if (!own.has(key - 2 * LIMIT)) { ctx.moveTo(x, y + 1); ctx.lineTo(x + size, y + 1); }
      if (!own.has(key + 2 * LIMIT)) { ctx.moveTo(x, y + size - 1); ctx.lineTo(x + size, y + size - 1); }
      if (!own.has(key - 1)) { ctx.moveTo(x + 1, y); ctx.lineTo(x + 1, y + size); }
      if (!own.has(key + 1)) { ctx.moveTo(x + size - 1, y); ctx.lineTo(x + size - 1, y + size); }
    }
    ctx.stroke();
  }
  return { minX, minY, size, cols, rows, counts };
}

// The cell under a point of the page (clientX, clientY) on a canvas draw drew as drawn, or null.
export function cellAt(drawn, canvas, clientX, clientY) {
  if (!drawn) return null;
  const box = canvas.getBoundingClientRect();
  const x = Math.floor((clientX - box.left) / drawn.size);
  const y = Math.floor((clientY - box.top) / drawn.size);
  if (x < 0 || y < 0 || x >= drawn.cols || y >= drawn.rows) return null;
  return { x: x + drawn.minX, y: y + drawn.minY, key: cellKey(x + drawn.minX, y + drawn.minY) };
}
