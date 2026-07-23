// ===================== per-layer map calibration =====================
// The Map tab draws every tile layer onto the SAME world rectangle [0,worldSize]^2 with one
// shared camera transform (map.js drawMap). A layer only lines up if its source image already
// spans exactly that rectangle - true for the heightmap-derived 'terrain' layer, false for the
// higher-res rips whose pixel bounding box differs. This module supplies the missing piece: a
// per-layer AFFINE that maps a layer's "assumed world" position (what the uncalibrated renderer
// places a pixel at) to its TRUE world position, solved from control points the user marks.
//
// Affine M (2x3), applied as  [x' z'] = M . [x z 1]:
//     x' = a*x + c*z + e
//     z' = b*x + d*z + f
// Identity = {a:1,b:0,c:0,d:1,e:0,f:0} -> no change (the renderer's today-exact path).
//
// PURE + dependency-free so it is unit-testable offline (see the harness in scratch): the solver
// is the one piece whose correctness must be provable without a browser.

export const IDENTITY = { a: 1, b: 0, c: 0, d: 1, e: 0, f: 0 };

export function isIdentity(m) {
  return !m || (m.a === 1 && m.b === 0 && m.c === 0 && m.d === 1 && m.e === 0 && m.f === 0);
}

// Apply an affine to a world point [x,z] -> [x',z'].
export function applyAffine(m, x, z) {
  if (!m) return [x, z];
  return [m.a * x + m.c * z + m.e, m.b * x + m.d * z + m.f];
}

// Inverse affine (true-world -> assumed-world). The renderer needs it to cull a calibrated
// layer's tiles: it maps the visible screen window back to assumed-world tile indices. Null if
// the linear part is singular (a degenerate calibration that never survives the solver anyway).
export function invertAffine(m) {
  if (!m || isIdentity(m)) return IDENTITY;
  const det = m.a * m.d - m.b * m.c;
  if (Math.abs(det) < 1e-12) return null;
  const ia = m.d / det, ib = -m.b / det, ic = -m.c / det, id = m.a / det;
  return { a: ia, b: ib, c: ic, d: id, e: -(ia * m.e + ic * m.f), f: -(ib * m.e + id * m.f) };
}

// Solve a 3-variable ordinary least squares  y ~ b0*u + b1*v + b2  via the 3x3 normal equations.
// Returns [b0,b1,b2] or null if the system is singular (degenerate / collinear points).
function solve3(rows, ys) {
  // Normal matrix A^T A (3x3, symmetric) and A^T y (3).
  const N = [[0, 0, 0], [0, 0, 0], [0, 0, 0]];
  const g = [0, 0, 0];
  for (let i = 0; i < rows.length; i++) {
    const r = rows[i], y = ys[i];
    for (let a = 0; a < 3; a++) {
      g[a] += r[a] * y;
      for (let b = 0; b < 3; b++) N[a][b] += r[a] * r[b];
    }
  }
  return gauss3(N, g);
}

// Gaussian elimination with partial pivoting for a 3x3 system. Null if singular.
function gauss3(A, y) {
  const M = [[A[0][0], A[0][1], A[0][2], y[0]], [A[1][0], A[1][1], A[1][2], y[1]], [A[2][0], A[2][1], A[2][2], y[2]]];
  for (let col = 0; col < 3; col++) {
    let piv = col;
    for (let r = col + 1; r < 3; r++) if (Math.abs(M[r][col]) > Math.abs(M[piv][col])) piv = r;
    if (Math.abs(M[piv][col]) < 1e-9) return null;
    if (piv !== col) { const t = M[piv]; M[piv] = M[col]; M[col] = t; }
    for (let r = 0; r < 3; r++) {
      if (r === col) continue;
      const f = M[r][col] / M[col][col];
      for (let k = col; k < 4; k++) M[r][k] -= f * M[col][k];
    }
  }
  return [M[0][3] / M[0][0], M[1][3] / M[1][1], M[2][3] / M[2][2]];
}

// Solve the calibration affine from control points.
//   points: [{ assumed:[ax,az], world:[wx,wz] }, ...]
//     assumed = where the UNCALIBRATED renderer places the spot (from a click -> mapToWorld)
//     world   = the spot's TRUE world coordinate (typed, or picked off the accurate layer)
// >=3 points -> full affine (offset+scale+rotation+shear). Exactly 2 -> offset+scale only
// (rotation/shear forced to identity; enough to un-crop an axis-aligned rip). <2 -> null.
// Returns { affine, residuals:[m per point], rms, maxResidual, rotationDeg, model } or
// { error } when the points are degenerate.
export function solveCalibration(points) {
  const pts = (points || []).filter((p) => p && p.assumed && p.world);
  if (pts.length < 2) return { error: 'Need at least 2 control points.' };

  let m, model;
  if (pts.length === 2) {
    // Offset + per-axis scale: x' = sx*x + tx ; z' = sz*z + tz. Two 1-var fits (exact for 2 pts).
    const [p, q] = pts;
    const dax = q.assumed[0] - p.assumed[0], daz = q.assumed[1] - p.assumed[1];
    if (Math.abs(dax) < 1e-6 || Math.abs(daz) < 1e-6) return { error: 'The 2 points share an X or Z - spread them diagonally, or add a third.' };
    const sx = (q.world[0] - p.world[0]) / dax;
    const sz = (q.world[1] - p.world[1]) / daz;
    m = { a: sx, b: 0, c: 0, d: sz, e: p.world[0] - sx * p.assumed[0], f: p.world[1] - sz * p.assumed[1] };
    model = 'offset+scale';
  } else {
    // Full affine via two 3-param least squares over all points.
    const rows = pts.map((p) => [p.assumed[0], p.assumed[1], 1]);
    const xs = solve3(rows, pts.map((p) => p.world[0]));   // -> a,c,e
    const zs = solve3(rows, pts.map((p) => p.world[1]));   // -> b,d,f
    if (!xs || !zs) return { error: 'Control points are collinear - spread them across the map (corners are ideal).' };
    m = { a: xs[0], c: xs[1], e: xs[2], b: zs[0], d: zs[1], f: zs[2] };
    model = 'affine';
  }

  // Residual = distance in meters between the fitted world point and the true one.
  const residuals = pts.map((p) => {
    const [x, z] = applyAffine(m, p.assumed[0], p.assumed[1]);
    return Math.hypot(x - p.world[0], z - p.world[1]);
  });
  const rms = Math.sqrt(residuals.reduce((s, r) => s + r * r, 0) / residuals.length);
  // Rotation of the linear part (mean of the two basis-vector angles) - so the user can SEE
  // whether the layer is actually rotated or the offset+scale model would have sufficed.
  const rotationDeg = (Math.atan2(m.b, m.a) + Math.atan2(-m.c, m.d)) / 2 * 180 / Math.PI;

  return { affine: m, residuals, rms, maxResidual: Math.max(...residuals), rotationDeg, model, n: pts.length };
}
