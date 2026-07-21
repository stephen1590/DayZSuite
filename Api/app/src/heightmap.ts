// Terrain heightmap store — offline elevation lookup for the surface-y action.
//
// The data is NOT computed here: per-map grids are baked once by the DayZHeightmap
// project (a throwaway DayZ server sweeps GetGame().SurfaceY over a 2-4 m grid and
// the result is validated against a 1000-point engine oracle to <=0.5 m). This module
// only samples those grids, exactly like the ConfigViewer JS sampler in
// DayZHeightmap/docs/FORMAT.md — same math, same answers.
//
// Layout on disk (shipped by DayZHeightmap/Ship-Heightmaps.ps1):
//   <dir>/<map>/heightmap.bin   little-endian uint16, gridN x gridN, row 0 = north
//   <dir>/<map>/meta.json       { worldSize, gridN, minY, maxY, ... } — the contract
//
// Grids are lazy-loaded on first use and cached for the process lifetime (30-82 MB
// per map; the box has plenty). A missing dir or map is a normal condition (data not
// shipped yet), never a crash — callers get null and reply 404.
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';

export interface HeightmapMeta {
  map: string;
  worldSize: number;
  gridN: number;
  cellSize: number;
  minY: number;
  maxY: number;
}

export interface LoadedHeightmap {
  meta: HeightmapMeta;
  grid: Buffer; // gridN*gridN uint16 LE
}

const NAME_RE = /^[a-z0-9_-]+$/i;

export class HeightmapStore {
  private cache = new Map<string, LoadedHeightmap>();

  constructor(private dir: string) {}

  /** Available maps (meta only, no grid load) — drives discovery + the 404 hint. */
  list(): Array<HeightmapMeta & { sizeBytes: number }> {
    let entries: string[];
    try {
      entries = readdirSync(this.dir);
    } catch {
      return []; // no data shipped yet — an empty list, not an error
    }
    const out: Array<HeightmapMeta & { sizeBytes: number }> = [];
    for (const name of entries) {
      if (!NAME_RE.test(name)) continue;
      try {
        const meta = this.readMeta(name);
        const sizeBytes = statSync(join(this.dir, name, 'heightmap.bin')).size;
        out.push({ ...meta, sizeBytes });
      } catch {
        // half-shipped/corrupt entry: skip it rather than break discovery
      }
    }
    return out.sort((a, b) => a.map.localeCompare(b.map));
  }

  /** Load (and cache) one map's grid. null = unknown map / data not shipped. */
  get(map: string): LoadedHeightmap | null {
    if (!NAME_RE.test(map)) return null;
    const hit = this.cache.get(map);
    if (hit) return hit;
    let meta: HeightmapMeta;
    try {
      meta = this.readMeta(map);
    } catch {
      return null;
    }
    // From here failures are REAL errors (data present but unusable) — let them throw.
    const grid = readFileSync(join(this.dir, map, 'heightmap.bin'));
    const expected = meta.gridN * meta.gridN * 2;
    if (grid.length !== expected) {
      throw new Error(`heightmap.bin for '${map}' is ${grid.length} bytes, expected ${expected} (gridN ${meta.gridN})`);
    }
    const loaded = { meta, grid };
    this.cache.set(map, loaded);
    return loaded;
  }

  /**
   * Bilinear-sample terrain Y at world (x, z). Mirrors the ConfigViewer sampler in
   * DayZHeightmap/docs/FORMAT.md verbatim: row 0 = north (z = worldSize), so z flips;
   * u16 decodes as minY + s/65535 * (maxY - minY). Caller validates x/z bounds.
   */
  sample(hm: LoadedHeightmap, x: number, z: number): number {
    const { worldSize, gridN: N, minY, maxY } = hm.meta;
    const gx = (x / worldSize) * (N - 1);
    const gz = ((worldSize - z) / worldSize) * (N - 1);
    const x0 = Math.max(0, Math.min(Math.floor(gx), N - 1));
    const z0 = Math.max(0, Math.min(Math.floor(gz), N - 1));
    const x1 = Math.min(x0 + 1, N - 1);
    const z1 = Math.min(z0 + 1, N - 1);
    const fx = gx - x0;
    const fz = gz - z0;
    const at = (cx: number, cz: number) => hm.grid.readUInt16LE((cz * N + cx) * 2);
    const top = at(x0, z0) * (1 - fx) + at(x1, z0) * fx;
    const bot = at(x0, z1) * (1 - fx) + at(x1, z1) * fx;
    const s = top * (1 - fz) + bot * fz;
    return minY + (s / 65535) * (maxY - minY);
  }

  private readMeta(map: string): HeightmapMeta {
    const raw = JSON.parse(readFileSync(join(this.dir, map, 'meta.json'), 'utf8')) as Record<string, unknown>;
    const meta: HeightmapMeta = {
      map,
      worldSize: Number(raw.worldSize),
      gridN: Number(raw.gridN),
      cellSize: Number(raw.cellSize),
      minY: Number(raw.minY),
      maxY: Number(raw.maxY),
    };
    if (!(meta.worldSize > 0) || !Number.isInteger(meta.gridN) || meta.gridN < 2 || !(meta.maxY > meta.minY)) {
      throw new Error(`meta.json for '${map}' is invalid`);
    }
    return meta;
  }
}
