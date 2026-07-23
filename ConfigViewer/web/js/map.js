// map.js — the Map tab: tiled terrain canvas (pan/zoom/pinch), overlay layers (labels, loot,
// spawns, buildings, iZurvive markers), live player/bandit positions, and the spawn-point
// editor (drag/add/save via configs/set-spawns). Extracted from index.html (P1 modular split).
// Routing stays in the shell: it injects syncHash/syncHashSoon/updateThemeToggle via
// setMapShellHooks(), reads mapHashFrag() for the URL, and hands over #map/... targets
// through setPendingMapView().
import { el } from './dom.js';
import { toast, setGlobalMsg, escapeHtml, attr, stripBom } from './ui.js';
import { apiPost, rateLimited } from './api-client.js';
import { loadCred, handle } from './auth.js';
import { getActiveMission, setActiveMission } from './state.js';

let shellHooks = { syncHash: () => {}, syncHashSoon: () => {}, updateThemeToggle: () => {} };
export function setMapShellHooks(h) { shellHooks = { ...shellHooks, ...h }; }

// {short, cx?, cz?, ppm?} from a #map/... hash, applied once the map data is loaded.
let pendingMapView = null;
export function setPendingMapView(v) { pendingMapView = v || null; }

// ===================== Map tab (browsable terrain map + AI coordinates) ====
// A dependency-free "maps app" viewer: pre-rendered terrain tile pyramids
// (MapDataExtraction/Build-MapTiles.ps1 → web/tiles/<map>/terrain/<z>/<x>_<y>.png,
// z0 = whole world in one 256px tile) drawn on a canvas with drag-pan and
// wheel/pinch zoom, a coordinate grid that rescales with zoom, live X/Y/Z under
// the crosshair (Y sampled client-side from tiles/<map>/height.bin, fetched
// once), and right-click → copy "X Y Z" (exact Y re-fetched from
// terrain/surface-y; the local grid is the offline fallback).
//
// Overlaid: the VPP spawn bookmarks (read via the Vpp-coordinates config), each
// bookmark's terrain Y resolved in ONE bulk terrain/surface-y call, showing
// Δ = bookmark Y − heightmap Y. Δ bands: ≤0.5 m ok (the heightmap's validated
// error bound), ≤2 m warn, >2 m serious (likely a stale bookmark). Serious
// points render as SQUARES and every Δ is printed as a number — color is never
// the only channel. NonSpawn bookmarks (no map prefix) are admin teleports: skipped.
let mapData = null;      // { coords, classes, hms } after first fetch
let mapMission = '';     // selected mission folder (dayzOffline.*)
let mapPts = [];         // spawn bookmarks of the selected map (plot order)
let mapWs = 15360;       // world size in meters for the current map
let mapHm = null;        // API heightmap meta for the current map (null = none shipped)
let mapSelPt = -1;       // selected point index into mapPts
let mapCatFilter = new Set();  // active class/type keys ('(base)' = uncategorized); a point shows only if its key is in here
let mapEdit = false;           // edit mode: drag markers to move, click empty to add, panel to edit fields

// --- Deprecations (AI map/location settings rework, 2026-07-23) ------------------------------
// Phase 1: the authored map-points store is being replaced by points DERIVED from the live
// Expansion AIPatrol/AILocation settings. Its on-map layer is turned OFF here (render + new-point
// creation) while that inversion is built - Phase 3 re-renders the derived points read-only. One
// switch, reversible: set false to restore the old editable layer.
const MAP_POINTS_DEPRECATED = true;
// BanditAI is retired (its mods are already disabled in mods.conf). Stop drawing its live-position
// layer too. Reversible.
const BANDIT_RENDER_DEPRECATED = true;
let mapSpawnDirty = false;     // unsaved spawn-point edits held in memory (mapData.spawns)
let mapSpawnBaseline = null;   // JSON of the last-saved points, for Discard
let mapLoadSeq = 0;      // async guard: stale fetches/resolves must not render
let mapTiles = null;     // { man, base, cache } once tiles/<map>/manifest.json loads
let mapLocs = [];        // location labels (tiles/<map>/locations.json, tier-sorted)
let mapSpawns = null;    // { fresh:[[x,z]…], travel:[[x,z]…] } from tiles/<map>/spawns.json
let mapLoot = null;      // { categories, points, colors, legend } from tiles/<map>/loot.json
let mapBuildings = null; // { n, pts:[x,z,…] } building footprints from tiles/<map>/buildings.json
let mapMarkers = null;   // { layers:[{key,name,color,kind,pts}] } from tiles/<map>/markers.json (iZurvive-derived)
let mapHgt = null;       // { grid, gridN, minY, maxY } once height.bin loads
let mapView = null;      // { cx, cz, ppm } camera: world center + pixels-per-meter
let mapAssetSeq = 0;     // async guard for tile/height fetches across map switches
let mapHover = -1;       // bookmark index under the pointer (-1 = none)
let mapPlayers = [];     // live player positions [{x,z}] (anonymized) — the overlay layer
let mapPlayersAt = null; // server-clock HH:MM:SS of the freshest fix (staleness hint)
let mapPlayersTimer = null;
let mapBandits = { positions: [], stale: false, ageSec: null };  // live bandit positions from the AIB_Tracker serverMod
let mapCursor = null;    // world { x, z } under the pointer (null = outside)
let mapDrawQueued = false;

function mapShort(mission) { return String(mission || '').replace(/^dayzOffline\./, ''); }
// Class/type filter: a point's key is its category token, or '(base)' when uncategorized
// (which the builder composes as a base holdout). A point renders only if its key is active.
function mapCatKey(p) { return p.cat || '(base)'; }
function mapVisible(p) { return mapCatFilter.has(mapCatKey(p)); }
function mapBand(p) { return p.ty === undefined ? 'mnull' : Math.abs(p.delta) <= 0.5 ? 'mok' : Math.abs(p.delta) <= 2 ? 'mwarn' : 'mbad'; }
function fmtDelta(d) { return (d >= 0 ? '+' : '') + d.toFixed(2) + ' m'; }
function mapStageMsg(msg) {
  el.mapEmpty.textContent = msg || '';
  el.mapEmpty.classList.toggle('hidden', !msg);
}

export async function loadMapTab(force) {
  const cred = loadCred();
  if (!cred) return;
  const seq = ++mapLoadSeq;
  if (!mapData || force) {
    mapStageMsg('Loading spawn points…');
    try {
      const [spawnsR, classesR, hmsR] = await Promise.all([
        apiPost('/dayz/configs/get?name=Map-points', cred),
        apiPost('/dayz/configs/get?name=AI-Classes', cred),
        apiPost('/dayz/terrain/heightmaps', cred).catch(() => ({ maps: [] })),  // older API -> no deltas, map still plots
      ]);
      if (seq !== mapLoadSeq) return;
      const doc = JSON.parse(stripBom(spawnsR.content || '{}'));
      const spawns = (doc && Array.isArray(doc.points)) ? doc : { version: 1, points: [] };
      mapData = {
        spawns,
        classes: JSON.parse(stripBom(classesR.content || '{}')),
        hms: hmsR.maps || [],
      };
      mapSpawnBaseline = JSON.stringify(spawns.points);
      mapSpawnDirty = false;
    } catch (err) {
      if (handle(err)) return;
      mapStageMsg(err.status === 404
        ? 'The API does not expose Map-points — redeploy it with the updated Configs allowlist.'
        : 'Could not load spawn points: ' + err.message);
      return;
    }
    if (getActiveMission() === null) {
      try { const s = await apiPost('/dayz/status', cred); setActiveMission(s.map || null); } catch { /* leave null */ }
      if (seq !== mapLoadSeq) return;
    }
  }
  buildMapOptions();
  let target = el.mapSel.value || mapMission;
  // A deep link (#map/<short>/…) targets a specific mission — switch to it before drawing.
  if (pendingMapView && pendingMapView.short) {
    const m = missionForShort(pendingMapView.short);
    if (m) { target = m; el.mapSel.value = m; }
  }
  // Revisiting the tab keeps the camera where you left it; only a real map
  // switch (or Refresh) rebuilds the scene.
  if (force || target !== mapMission || !mapView) setMapMission(target);
  else { applyPendingMapView(); mapStageMsg(''); requestMapDraw(); shellHooks.syncHash(); }
}
// Reverse of mapShort(): find the mission whose short name matches a hash fragment.
function missionForShort(short) {
  const letters = (mapData && mapData.classes && mapData.classes.maps) || {};
  for (const mission of new Set(Object.values(letters))) if (mapShort(mission) === short) return mission;
  return null;
}
// Apply a pending deep-link camera onto the live view, once mapView exists and the mission
// matches. Center is authoritative; ppm is clamped to this viewport's sane zoom range. It is
// NOT consumed here: an async tile load can refit the map, so we re-apply at each fit and only
// drop the pending camera once the user actually pans/zooms (mapTakeControl).
function applyPendingMapView() {
  if (!pendingMapView || !mapView) return;
  const pv = pendingMapView;
  if (pv.short && pv.short !== mapShort(mapMission)) return;   // its map hasn't loaded yet
  if (isFinite(pv.cx)) mapView.cx = pv.cx;
  if (isFinite(pv.cz)) mapView.cz = pv.cz;
  if (isFinite(pv.ppm)) mapView.ppm = mapClampPpm(pv.ppm);
  mapClampCenter();
}
// The user grabbed the camera — stop forcing the deep-link view and start tracking theirs.
function mapTakeControl() { pendingMapView = null; }

// The selector lists every mission letter from classification.json, spawn-bookmark
// count included, defaulting to the server's active mission.
function buildMapOptions() {
  const letters = (mapData.classes && mapData.classes.maps) || {};
  const countFor = (mission) => mapData.spawns.points.filter((e) => letters[e.map] === mission).length;
  const opts = Object.values(letters).map((mission) => ({ mission, n: countFor(mission) }));
  if (!mapMission) mapMission = (opts.find((o) => o.mission === getActiveMission()) || opts.find((o) => o.n > 0) || opts[0] || { mission: '' }).mission;
  el.mapSel.innerHTML = opts.map((o) =>
    '<option value="' + attr(o.mission) + '"' + (o.mission === mapMission ? ' selected' : '') + '>' +
    escapeHtml(mapShort(o.mission)) + ' (' + o.n + ')' + (o.mission === getActiveMission() ? ' · live' : '') + '</option>').join('');
}

// The map letters that resolve to a mission (classification.maps is letter -> mission).
function mapLettersFor(mission) {
  const letters = (mapData.classes && mapData.classes.maps) || {};
  return Object.keys(letters).filter((k) => letters[k] === mission);
}
// Valid Expansion AI factions — MIRROR of the API validator in Api/app/src/actions.ts
// (keep both in sync). Source: DayZ-Expansion-Scripts wiki, "How to create AI Patrols".
const AI_FACTIONS = ['West', 'East', 'Raiders', 'Mercenaries', 'Civilian', 'Passive', 'Guards', 'InvincibleGuards', 'Shamans', 'Observers', 'InvincibleObservers', 'YeetBrigade', 'InvincibleYeetBrigade', 'Brawlers', 'RANDOM'];
// The doc-level default any point falls back to; a point's own faction overrides it.
function docDefaultFaction() { return (mapData && mapData.spawns && mapData.spawns.defaultFaction) || 'Raiders'; }
function effFaction(p) { return p.faction || docDefaultFaction(); }

// Expansion roaming-location Types (from the maps' CfgWorlds; 'Local' is the safe default).
const LOCATION_TYPES = ['Local', 'Village', 'City', 'Capital', 'Hill', 'Camp', 'Ruin'];
// Which spawn systems a point feeds (own `spawns`, else the doc's defaultSpawns, else both).
function docDefaultSpawns() { return (mapData && mapData.spawns && mapData.spawns.defaultSpawns) || ['aib', 'expansion']; }
function effSpawns(p) { return p.spawns || docDefaultSpawns(); }

// Per-point ExpansionAI patrol tuning. Each key, when set in a point's `patrol` object, overrides
// the safe template default in the builder; blank = inherit. THIS list is the UI half of a 3-way
// contract — MIRROR of $PATROL_OVERRIDABLE (DayZ-Server/Build-AIPatrols.ps1) and PATROL_KEYS
// (Api/app/src/actions.ts). Add a knob = add it to all three. t: num | int | bool | str.
// def = the builder's template default, shown as the input placeholder so a blank field tells you
// what it currently resolves to (blank still means "inherit", it does not write an override).
const PATROL_FIELDS = [
  { k: 'numberOfAIMax', label: 'Num AI max', t: 'int', def: '= count' },
  { k: 'chance', label: 'Spawn chance', t: 'num', def: '1' },
  { k: 'loadBalancingCategory', label: 'Load-balancing', t: 'str', def: 'Survivor' },
  { k: 'minDistRadius', label: 'Min dist', t: 'num', def: '0' },
  { k: 'maxDistRadius', label: 'Max dist', t: 'num', def: '-1' },
  { k: 'despawnRadius', label: 'Despawn dist', t: 'num', def: '-1' },
  { k: 'useRandomWaypointAsStartPoint', label: 'Random start WP', t: 'bool', def: '0' },
  { k: 'canBeLooted', label: 'Can be looted', t: 'bool', def: '1' },
  { k: 'accuracyMin', label: 'Accuracy min', t: 'num', def: '-1' },
  { k: 'accuracyMax', label: 'Accuracy max', t: 'num', def: '-1' },
  { k: 'speed', label: 'Speed', t: 'str', def: 'JOG' },
  { k: 'underThreatSpeed', label: 'Threat speed', t: 'str', def: 'SPRINT' },
  { k: 'defaultStance', label: 'Stance', t: 'str', def: 'STANDING' },
  { k: 'formation', label: 'Formation', t: 'str', def: '(none)' },
  { k: 'formationScale', label: 'Formation scale', t: 'num', def: '1.5' },
  { k: 'threatDistanceLimit', label: 'Threat dist limit', t: 'num', def: '-1' },
  { k: 'respawnTime', label: 'Respawn time', t: 'num', def: '-2' },
  { k: 'despawnTime', label: 'Despawn time', t: 'num', def: '-1' },
  { k: 'damageMultiplier', label: 'Damage x', t: 'num', def: '-1' },
  { k: 'damageReceivedMultiplier', label: 'Dmg received x', t: 'num', def: '-1' },
  { k: 'headshotResistance', label: 'Headshot resist', t: 'num', def: '0' },
  { k: 'lootDropOnDeath', label: 'Loot drop', t: 'str', def: '(none)' },
];

// Serialise an in-memory point back to the stored map-points.json shape.
function mapToStored(p) {
  const o = { name: p.name, map: p.map };
  if (p.cat) o.category = p.cat;
  if (p.size) o.size = p.size;
  if (p.faction) o.faction = p.faction;      // omitted => inherits defaultFaction
  if (p.spawns) o.spawns = p.spawns;         // omitted => inherits defaultSpawns
  if (p.type) o.type = p.type;               // omitted => builder uses base Type / 'Local'
  if (p.radius != null) o.radius = p.radius; // omitted => builder uses base average radius
  if (p.patrol && Object.keys(p.patrol).length) o.patrol = p.patrol; // per-point patrol tuning overrides
  if (p.waypoints && p.waypoints.length) o.waypoints = p.waypoints;   // extra roam-path waypoints (after the spawn)
  o.x = p.x; o.y = p.y; o.z = p.z;
  return o;
}
// Fold the current map's in-memory edits back into the full document, so switching maps
// (or saving) never loses them. Replaces just this map's letters within spawns.points.
function flushMapEdits() {
  // Only when there are edits to preserve: a clean switch must not reorder the doc, and
  // discard (which clears the flag first) must not re-inject the very edits it's dropping.
  if (!mapData || !mapData.spawns || !mapMission || !mapSpawnDirty) return;
  const mine = mapLettersFor(mapMission);
  const others = (mapData.spawns.points || []).filter((p) => !mine.includes(p.map));
  mapData.spawns.points = others.concat(mapPts.map(mapToStored));
}

function setMapMission(mission) {
  if (!mission) { mapStageMsg('No maps declared in classification.json.'); return; }
  flushMapEdits();                       // preserve edits on the map we're leaving
  mapMission = mission;
  mapSelPt = -1;
  mapHover = -1;
  mapCursor = null;
  const mine = mapLettersFor(mission);
  mapPts = mapData.spawns.points
    .filter((e) => mine.includes(e.map))
    .map((e) => ({ name: e.name, map: e.map, cat: e.category || null, size: e.size || null, faction: e.faction || null, spawns: e.spawns || null, type: e.type || null, radius: (e.radius != null ? e.radius : null), patrol: e.patrol || null, waypoints: e.waypoints || null, x: e.x, y: e.y, z: e.z }));
  initMapFilter();
  mapHm = mapData.hms.find((h) => h.map === mapShort(mission)) || null;
  // Without a shipped heightmap there's no worldSize either — scale to the data.
  // (The tile manifest, when it arrives, is the final authority.)
  mapWs = mapHm ? mapHm.worldSize : Math.max(15360, ...mapPts.map((p) => Math.max(p.x, p.z)), 1) * 1.02;
  mapStageMsg('');
  fitMapView();
  applyPendingMapView();                  // a deep-link camera (#map/…) overrides the default fit
  loadMapAssets(mapShort(mission));
  renderMap();
  resolveMapDeltas();
  shellHooks.syncHash();                             // URL now reflects this map + camera
}

// Static assets rendered by MapDataExtraction: the tile pyramid manifest (v2:
// layers[] — satellite extracted from the game files, terrain rendered from
// the heightmap) and the height grid the crosshair Y readout samples locally.
function setMapLayer(name) {
  if (!mapTiles) return;
  const layer = mapTiles.man.layers.find((l) => l.name === name) || mapTiles.man.layers[0];
  if (!layer) return;
  mapTiles.layer = layer;
  mapTiles.base = mapTiles.root + layer.name + '/';
  mapTiles.cache = new Map();
  try { localStorage.setItem('cfgview-maplayer', layer.name); } catch { /* private mode */ }
  renderMapLayerSeg();
  requestMapDraw();
}
function renderMapLayerSeg() {
  const layers = mapTiles ? mapTiles.man.layers : [];
  el.mapLayerSeg.classList.toggle('hidden', layers.length < 2);
  el.mapLayerSeg.innerHTML = layers.map((l) =>
    '<button type="button" data-layer="' + attr(l.name) + '"' + (mapTiles.layer.name === l.name ? ' class="active"' : '') + '>' +
    escapeHtml(l.label || (l.name.charAt(0).toUpperCase() + l.name.slice(1))) + '</button>').join('');
}
async function loadMapAssets(short) {
  const seq = ++mapAssetSeq;
  mapTiles = null;
  mapHgt = null;
  mapLocs = [];
  mapSpawns = null;
  mapLoot = null;
  mapBuildings = null;
  mapMarkers = null;
  renderMapLayerSeg();
  renderLootFilter();
  renderSpawnFilter();
  renderBuildingsFilter();
  renderMarkersFilter();
  try {
    const root = 'tiles/' + encodeURIComponent(short) + '/';
    fetch(root + 'locations.json')
      .then((r) => (r.ok ? r.json() : []))
      .then((l) => { if (seq === mapAssetSeq && Array.isArray(l)) { mapLocs = l; requestMapDraw(); } })
      .catch(() => { /* labels are optional */ });
    fetch(root + 'spawns.json')
      .then((r) => (r.ok ? r.json() : null))
      .then((s) => { if (seq === mapAssetSeq && s) { mapSpawns = s; renderSpawnFilter(); requestMapDraw(); } })
      .catch(() => { /* spawn overlay is optional */ });
    fetch(root + 'loot.json')
      .then((r) => (r.ok ? r.json() : null))
      .then((l) => { if (seq === mapAssetSeq && l && Array.isArray(l.points)) { mapLoot = prepLoot(l); renderLootFilter(); requestMapDraw(); } })
      .catch(() => { /* loot overlay is optional */ });
    fetch(root + 'buildings.json')
      .then((r) => (r.ok ? r.json() : null))
      .then((b) => { if (seq === mapAssetSeq && b && Array.isArray(b.pts)) { mapBuildings = b; renderBuildingsFilter(); requestMapDraw(); } })
      .catch(() => { /* building overlay is optional */ });
    fetch(root + 'markers.json')
      .then((r) => (r.ok ? r.json() : null))
      .then((m) => { if (seq === mapAssetSeq && m && Array.isArray(m.layers)) { mapMarkers = m; renderMarkersFilter(); requestMapDraw(); } })
      .catch(() => { /* marker overlay is optional */ });
    const mR = await fetch(root + 'manifest.json');
    if (seq !== mapAssetSeq) return;
    if (!mR.ok) { requestMapDraw(); return; }        // no tiles delivered for this map
    const man = await mR.json();
    if (seq !== mapAssetSeq) return;
    if (!Array.isArray(man.layers) || !man.layers.length || typeof man.layers[0] === 'string') { requestMapDraw(); return; }
    mapTiles = { man, root, layer: null, base: '', cache: new Map() };
    let want = 'satellite';
    try { want = localStorage.getItem('cfgview-maplayer') || 'satellite'; } catch { /* default */ }
    setMapLayer(want);
    if (man.worldSize && Math.abs(man.worldSize - mapWs) > 1) { mapWs = man.worldSize; fitMapView(); applyPendingMapView(); shellHooks.syncHash(); }
    requestMapDraw();
    const hR = await fetch('tiles/' + encodeURIComponent(short) + '/height.bin');
    if (!hR.ok) return;
    const buf = await hR.arrayBuffer();
    if (seq !== mapAssetSeq) return;
    const hm = man.height || {};
    if (buf.byteLength === hm.gridN * hm.gridN * 2) {
      mapHgt = { grid: new Uint16Array(buf), gridN: hm.gridN, minY: hm.minY, maxY: hm.maxY };
    }
  } catch { /* tiles are progressive enhancement — the plot still works bare */ }
  requestMapDraw();
}

// Bilinear terrain Y from the local grid (docs/FORMAT.md sampler). Null when
// the grid isn't loaded or the point is off-map.
function mapLocalY(x, z) {
  if (!mapHgt || x < 0 || z < 0 || x > mapWs || z > mapWs) return null;
  const n = mapHgt.gridN;
  const gx = (x / mapWs) * (n - 1);
  const gz = ((mapWs - z) / mapWs) * (n - 1);            // row 0 = north
  const x0 = Math.floor(gx), z0 = Math.floor(gz);
  const x1 = Math.min(x0 + 1, n - 1), z1 = Math.min(z0 + 1, n - 1);
  const fx = gx - x0, fz = gz - z0;
  const g = mapHgt.grid;
  const top = g[z0 * n + x0] * (1 - fx) + g[z0 * n + x1] * fx;
  const bot = g[z1 * n + x0] * (1 - fx) + g[z1 * n + x1] * fx;
  return mapHgt.minY + ((top * (1 - fz) + bot * fz) / 65535) * (mapHgt.maxY - mapHgt.minY);
}

// ONE bulk call for the whole point set (per-point calls would eat the rate limit).
async function resolveMapDeltas() {
  if (!mapHm || !mapPts.length) return;
  const cred = loadCred();
  if (!cred) return;
  const mission = mapMission;
  try {
    const r = await apiPost('/dayz/terrain/surface-y', cred, {
      map: mapShort(mission),
      points: mapPts.map((p) => ({ x: p.x, z: p.z })),
    });
    if (mission !== mapMission) return;              // user switched maps mid-flight
    (r.points || []).forEach((rp, i) => {
      const p = mapPts[i];
      if (!p || rp.y === null || rp.y === undefined) return;
      p.ty = rp.y;
      p.delta = p.y - rp.y;
    });
    renderMap();
  } catch (err) {
    if (handle(err)) return;
    setGlobalMsg('Height lookup failed: ' + err.message, true);
  }
}

function renderMap() {
  requestMapDraw();
  renderMapFilter();
  renderLootFilter();
  renderSpawnFilter();
  renderBuildingsFilter();
  renderMarkersFilter();
  renderLiveFilter();
  renderMapList();
  renderMapSummary();
  renderMapDetail();
  updateMapEditUi();
}

// Reflect edit mode + dirty state in the head toolbar.
function updateMapEditUi() {
  if (!el.mapEditSeg) return;
  const btn = el.mapEditSeg.querySelector('button');
  if (btn) btn.classList.toggle('active', mapEdit);
  el.mapSaveWrap.classList.toggle('hidden', !mapEdit);
  el.mapSaveBtn.disabled = !mapSpawnDirty;
  el.mapDiscardBtn.disabled = !mapSpawnDirty;
  el.mapSaveBtn.textContent = mapSpawnDirty ? 'Save' : 'Saved';
  el.mapCanvas.classList.toggle('editing', mapEdit);
}

function toggleMapEdit() {
  mapEdit = !mapEdit;
  if (!mapEdit) { mapHover = -1; el.mapTip.style.display = 'none'; }
  renderMap();
}

// Save the WHOLE document (every map's points), box-authoritative — applies at next restart.
async function saveSpawns() {
  const cred = loadCred(); if (!cred) return;
  flushMapEdits();
  const seen = new Set();
  for (const p of mapData.spawns.points) {
    if (!p.name || !String(p.name).trim()) { toast('A point has an empty name', 'err'); return; }
    if (seen.has(p.name)) { toast('Duplicate point name: ' + p.name, 'err'); return; }
    seen.add(p.name);
  }
  const doc = { version: mapData.spawns.version || 1, defaultFaction: docDefaultFaction(), points: mapData.spawns.points };
  try {
    el.mapSaveBtn.disabled = true;
    const r = await apiPost('/dayz/configs/set-spawns', cred, { document: doc });
    mapSpawnDirty = false;
    mapSpawnBaseline = JSON.stringify(mapData.spawns.points);
    toast((r.points ?? doc.points.length) + ' spawn points saved — restart the server to apply', 'ok');
    renderMap();
  } catch (e) {
    if (!handle(e)) toast('Save failed: ' + e.message, 'err');
  } finally {
    updateMapEditUi();
  }
}

// Drop in-memory edits, restoring the last-saved points.
function discardSpawns() {
  if (!mapSpawnDirty) return;
  if (mapSpawnBaseline) mapData.spawns.points = JSON.parse(mapSpawnBaseline);
  mapSpawnDirty = false;
  mapSelPt = -1;
  setMapMission(mapMission);   // rebuild mapPts from the restored document
}

// ---------- camera ----------
function mapVp() { return { w: el.mapCanvas.clientWidth, h: el.mapCanvas.clientHeight }; }
function mapFitPpm() {
  const { w, h } = mapVp();
  return (Math.min(w, h) || 600) / mapWs * 0.98;      // whole map just fits
}
function mapClampPpm(ppm) { return Math.min(3, Math.max(mapFitPpm() * 0.7, ppm)); }
function fitMapView() { mapView = { cx: mapWs / 2, cz: mapWs / 2, ppm: mapFitPpm() }; }
function mapClampCenter() {
  mapView.cx = Math.min(mapWs, Math.max(0, mapView.cx));
  mapView.cz = Math.min(mapWs, Math.max(0, mapView.cz));
}
function mapToScreen(wx, wz) {
  const { w, h } = mapVp();
  return [w / 2 + (wx - mapView.cx) * mapView.ppm, h / 2 - (wz - mapView.cz) * mapView.ppm];
}
function mapToWorld(sx, sy) {
  const { w, h } = mapVp();
  return { x: mapView.cx + (sx - w / 2) / mapView.ppm, z: mapView.cz - (sy - h / 2) / mapView.ppm };
}
function mapZoomAt(sx, sy, factor) {
  mapTakeControl();                                    // user zoom overrides any deep-link camera
  const anchor = mapToWorld(sx, sy);
  mapView.ppm = mapClampPpm(mapView.ppm * factor);
  const { w, h } = mapVp();
  mapView.cx = anchor.x - (sx - w / 2) / mapView.ppm;  // keep the anchor under the cursor
  mapView.cz = anchor.z + (sy - h / 2) / mapView.ppm;
  mapClampCenter();
  requestMapDraw();
  shellHooks.syncHashSoon();                                      // reflect the new zoom/centre in the URL
}

// ---------- tiles ----------
function mapTile(z, tx, ty) {
  const cache = mapTiles.cache;
  const key = z + '/' + tx + '_' + ty;
  let t = cache.get(key);
  if (!t) {
    if (cache.size > 420) {                            // decoded tiles hold real memory
      for (const k of cache.keys()) { cache.delete(k); if (cache.size <= 260) break; }
    }
    t = { img: new Image(), ok: false };
    t.img.onload = () => { t.ok = true; requestMapDraw(); };
    t.img.src = mapTiles.base + key + '.' + (mapTiles.layer.ext || 'png');
    cache.set(key, t);
  }
  return t;
}

// Exported: the shell pokes a redraw after a theme flip (canvas colors come from CSS vars).
export function requestMapDraw() {
  if (mapDrawQueued) return;
  mapDrawQueued = true;
  requestAnimationFrame(() => { mapDrawQueued = false; drawMap(); });
}

function drawMap() {
  const c = el.mapCanvas;
  if (!mapView || el.maptab.classList.contains('hidden')) return;
  const dpr = window.devicePixelRatio || 1;
  const w = c.clientWidth, h = c.clientHeight;
  if (!w || !h) return;
  if (c.width !== Math.round(w * dpr) || c.height !== Math.round(h * dpr)) {
    c.width = Math.round(w * dpr);
    c.height = Math.round(h * dpr);
  }
  const ctx = c.getContext('2d');
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, w, h);
  const mv = mapView;
  const wx0 = mv.cx - w / 2 / mv.ppm, wx1 = mv.cx + w / 2 / mv.ppm;
  const wzB = mv.cz - h / 2 / mv.ppm, wzT = mv.cz + h / 2 / mv.ppm;
  if (mapTiles) {
    const layer = mapTiles.layer;
    const tileSize = layer.tileSize || mapTiles.man.tileSize || 256;
    // level whose native resolution first meets the screen's (cap: layer maxZoom)
    const zBest = Math.max(0, Math.min(layer.maxZoom, Math.ceil(Math.log2(mapWs * mv.ppm / tileSize))));
    ctx.imageSmoothingEnabled = true;
    // draw coarse→fine: lower levels backfill while the exact tiles stream in
    for (let z = 0; z <= zBest; z++) {
      const across = 1 << z;
      const tw = mapWs / across;                       // meters per tile at this level
      const tx0 = Math.max(0, Math.floor(wx0 / tw)), tx1 = Math.min(across - 1, Math.floor(wx1 / tw));
      const ty0 = Math.max(0, Math.floor((mapWs - wzT) / tw)), ty1 = Math.min(across - 1, Math.floor((mapWs - wzB) / tw));
      for (let ty = ty0; ty <= ty1; ty++) {
        for (let tx = tx0; tx <= tx1; tx++) {
          const t = mapTile(z, tx, ty);
          if (!t.ok) continue;
          const [sx, sy] = mapToScreen(tx * tw, mapWs - ty * tw);
          const s = tw * mv.ppm;
          ctx.drawImage(t.img, sx, sy, s + 0.5, s + 0.5);  // +0.5 hides subpixel seams
        }
      }
    }
  }
  drawMapGrid(ctx, w, h);
  drawMapBuildings(ctx);                               // footprints sit under the datascraped dots
  drawMapLoot(ctx);                                    // dense loot dots go under labels
  drawMapSpawns(ctx);                                  // sparse spawn markers over loot
  drawMapPoi(ctx);                                     // iZurvive-derived: crashes/vehicles/hazards/wildlife/infected
  drawMapLabels(ctx, w, h);
  drawMapMarkers(ctx);                                 // bookmarks stay on top of labels
  drawMapBandits(ctx);                                 // AIB activity under the players
  drawMapPlayers(ctx);                                 // live players on top of the bookmarks
  drawMapCrosshair(ctx, w, h);
  updateMapBar();
}

// ---------- location labels (CfgWorlds Names, dumped by MapDataExtraction) ----
// Tiers gate visibility by zoom: Capital/City always, villages from ~2x,
// POIs deeper, hills/viewpoints deepest. First-come collision skipping keeps
// the map readable (the list is tier-sorted, so big names win the space).
function drawMapLabels(ctx, w, h) {
  if (!mapLocs.length || !mapView) return;
  const TH = [0, 0, 0.10, 0.25, 0.5];                  // min px-per-meter per tier
  const FONTS = ['700 13px', '600 12.5px', '600 11.5px', '500 11px', '500 10.5px'];
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  ctx.lineJoin = 'round';
  const boxes = [];
  for (const L of mapLocs) {
    if (mapView.ppm < TH[L.tier] || L.tier > 4) continue;
    const [sx, sy] = mapToScreen(L.x, L.z);
    if (sx < -90 || sy < -20 || sx > w + 90 || sy > h + 20) continue;
    const label = L.tier === 0 ? L.name.toUpperCase() : L.name;
    ctx.font = FONTS[L.tier] + ' system-ui, sans-serif';
    const tw = ctx.measureText(label).width;
    const bx = sx - tw / 2 - 3, by = sy - 9, bw = tw + 6, bh = 18;
    let clash = false;
    for (const b of boxes) {
      if (bx < b[0] + b[2] && bx + bw > b[0] && by < b[1] + b[3] && by + bh > b[1]) { clash = true; break; }
    }
    if (clash) continue;
    boxes.push([bx, by, bw, bh]);
    ctx.lineWidth = 3;
    ctx.strokeStyle = 'rgba(255,255,255,0.82)';        // halo: readable on imagery + sea
    ctx.strokeText(label, sx, sy);
    ctx.fillStyle = 'rgba(24,32,42,0.95)';
    ctx.fillText(label, sx, sy);
  }
  ctx.textAlign = 'left';
}

// ---------- grid (spacing rescales with zoom) ----------
// Each line is a light halo under a dark core so it reads on dark forest and
// bright snow alike. Intensity is user-set (Off/Subtle/Bold, persisted).
const MAP_GRIDS = {
  off: null,
  subtle: { halo: 0.16, minor: 0.18, major: 0.34, wMaj: 1 },
  bold: { halo: 0.28, minor: 0.32, major: 0.56, wMaj: 1 },
};
let mapGrid = 'bold';
try { mapGrid = localStorage.getItem('cfgview-mapgrid') || 'bold'; } catch { /* default */ }
if (!(mapGrid in MAP_GRIDS)) mapGrid = 'bold';
function setMapGrid(mode) {
  if (!(mode in MAP_GRIDS)) mode = 'bold';
  mapGrid = mode;
  try { localStorage.setItem('cfgview-mapgrid', mode); } catch { /* private mode */ }
  for (const b of el.mapGridSeg.querySelectorAll('button')) b.classList.toggle('active', b.dataset.grid === mode);
  requestMapDraw();
}
function drawMapGrid(ctx, w, h) {
  const G = MAP_GRIDS[mapGrid];
  if (!G) return;
  const mv = mapView;
  const steps = [10000, 5000, 2000, 1000, 500, 200, 100, 50, 20, 10];
  let step = steps[0];
  for (const s of steps) if (s * mv.ppm >= 56) step = s;  // smallest spacing ≥ 56px
  const major = step * 5;
  const wx0 = mv.cx - w / 2 / mv.ppm, wx1 = mv.cx + w / 2 / mv.ppm;
  const wzB = mv.cz - h / 2 / mv.ppm, wzT = mv.cz + h / 2 / mv.ppm;
  // Game-native map coordinate: metres / 10000, so 8000 -> 0.8, 10000 -> 1.0.
  const fmtC = (v) => { let s = (v / 10000).toFixed(3).replace(/0+$/, ''); return s.endsWith('.') ? s + '0' : s; };
  ctx.textBaseline = 'middle';
  const line = (x0, y0, x1, y1, isMaj) => {
    ctx.beginPath();
    ctx.moveTo(x0, y0); ctx.lineTo(x1, y1);
    ctx.lineWidth = (isMaj ? G.wMaj : 1) + 2;
    ctx.strokeStyle = 'rgba(255,255,255,' + G.halo + ')';
    ctx.stroke();
    ctx.lineWidth = isMaj ? G.wMaj : 1;
    ctx.strokeStyle = 'rgba(20,32,44,' + (isMaj ? G.major : G.minor) + ')';
    ctx.stroke();
  };
  // Every line gets a chip; majors are bolder and darker so they read first.
  const chip = (x, y, txt, anchor, maj) => {
    ctx.font = (maj ? '700 10.5px ' : '400 9px ') + 'ui-monospace, SFMono-Regular, Menlo, monospace';
    const tw = ctx.measureText(txt).width, bw = tw + 8;
    const bx = anchor === 'left' ? x : x - bw / 2;
    ctx.fillStyle = maj ? 'rgba(255,255,255,0.92)' : 'rgba(255,255,255,0.62)';
    ctx.beginPath();
    ctx.roundRect(bx, y - 8, bw, 16, 4);
    ctx.fill();
    ctx.fillStyle = maj ? 'rgba(16,24,34,0.98)' : 'rgba(46,58,70,0.82)';
    ctx.fillText(txt, bx + 4, y + 0.5);
  };
  for (let gx = Math.ceil(Math.max(0, wx0) / step) * step; gx <= Math.min(mapWs, wx1); gx += step) {
    const isMaj = gx % major === 0;
    const sx = Math.round(mapToScreen(gx, 0)[0]) + 0.5;
    line(sx, 0, sx, h, isMaj);
    chip(sx, h - 12, fmtC(gx), 'center', isMaj);
  }
  for (let gz = Math.ceil(Math.max(0, wzB) / step) * step; gz <= Math.min(mapWs, wzT); gz += step) {
    const isMaj = gz % major === 0;
    const sy = Math.round(mapToScreen(0, gz)[1]) + 0.5;
    line(0, sy, w, sy, isMaj);
    chip(6, sy, fmtC(gz), 'left', isMaj);
  }
}

// ---------- datascraped overlays: player spawns + loot (toggle each) ----------
// Both come from the map's own CE files (MapDataExtraction/tools/build-overlays.mjs),
// the same primary source iZurvive parses. Off by default so the map stays clean.
// Loot colours by category with a fixed priority so rare/important sites
// (military, medical) win the colour over ubiquitous village/industrial.
const LOOT_COLORS = {
  // iZurvive-dataset top-level categories (the standard where a map has a dataset)
  Medical: '#e5a0d8', Urban: '#12a594', Rural: '#46a758', Wreck: '#f7b955', Landmark: '#8e4ec6',
  // game-derived categories (fallback maps) + shared names
  Military: '#e5484d', Medic: '#e5a0d8', Police: '#3e63dd', Firefighter: '#f76b15',
  Prison: '#a18072', Underground: '#8b7355', ContaminatedArea: '#8bcd00',
  Lunapark: '#e93d82', SeasonalEvent: '#ffcc00', Office: '#8e4ec6', School: '#d6409f',
  Special: '#ffffff', Hunting: '#5c7f3a', Coast: '#2ec9e0', Town: '#12a594',
  Farm: '#9bbb2f', Industrial: '#c8890a', Village: '#46a758',
};
// Higher priority first — the dominant category picked for a multi-tag site.
const LOOT_PRIORITY = ['Military', 'Medical', 'Medic', 'Police', 'Firefighter', 'Prison', 'Underground',
  'ContaminatedArea', 'Lunapark', 'SeasonalEvent', 'Office', 'School', 'Special',
  'Hunting', 'Coast', 'Wreck', 'Landmark', 'Urban', 'Town', 'Rural', 'Farm', 'Industrial', 'Village'];
const LOOT_FALLBACK = '#9aa4ad';
// Spawn kinds are a fixed pair, coloured like their on-map diamonds.
const SPAWN_KINDS = [{ key: 'fresh', label: 'Fresh', color: '#7ee787' }, { key: 'travel', label: 'Travel', color: '#4cc9e0' }];
// Readable ink for a swatch fill — dark text on light chips, white on dark.
function inkOn(hex) {
  const h = String(hex).replace('#', '');
  if (h.length < 6) return '#fff';
  const r = parseInt(h.slice(0, 2), 16), g = parseInt(h.slice(2, 4), 16), b = parseInt(h.slice(4, 6), 16);
  return (0.299 * r + 0.587 * g + 0.114 * b) > 150 ? '#10161e' : '#fff';
}
// Precompute each point's categories in priority order + present-category counts, once per load.
function prepLoot(l) {
  const cats = l.categories || [];
  const order = LOOT_PRIORITY.map((n) => cats.indexOf(n)).filter((i) => i >= 0);
  cats.forEach((n, i) => { if (!LOOT_PRIORITY.includes(n)) order.push(i); });   // unknown cats last
  const catNames = new Array(l.points.length);
  const counts = new Map();
  for (let i = 0; i < l.points.length; i++) {
    const mask = l.points[i][2], names = [];
    for (const ci of order) if (mask & (1 << ci)) { const nm = cats[ci]; names.push(nm); counts.set(nm, (counts.get(nm) || 0) + 1); }
    catNames[i] = names;
  }
  const present = order.map((ci) => cats[ci]).filter((nm) => counts.has(nm));
  return { points: l.points, catNames, counts, present };
}

// Active overlay categories. Empty set = nothing drawn. Persisted by name so a
// preference (e.g. "just Military loot") carries across maps.
const readSet = (key) => { try { const v = JSON.parse(localStorage.getItem(key) || '[]'); return new Set(Array.isArray(v) ? v : []); } catch { return new Set(); } };
const mapLootSel = readSet('cfgview-maploot');
const mapSpawnSel = readSet('cfgview-mapspawns');
const mapBuildingsSel = readSet('cfgview-mapbuildings');   // single 'Structures' toggle
const mapMarkersSel = readSet('cfgview-mapmarkers');       // iZurvive POI sublayers by name
const saveSet = (key, set) => { try { localStorage.setItem(key, JSON.stringify([...set])); } catch { /* private mode */ } };

// Live overlays (player dots, NPC diamonds) default ON — readSet's empty-set default is
// right for the datascraped bars but would blank live positions on everyone's first visit.
const readSetOr = (key, dflt) => { try { return localStorage.getItem(key) === null ? new Set(dflt) : readSet(key); } catch { return new Set(dflt); } };
const LIVE_KINDS = ['Players', 'NPCs'];
const mapLiveSel = readSetOr('cfgview-maplive', LIVE_KINDS);

// "All" is a three-state toggle: off/partial -> enable every present category;
// fully on -> disable every one. That's "check All twice = disable all".
function toggleOverlay(sel, key, cat, present) {
  if (cat === '*') { if (present.every((n) => sel.has(n))) present.forEach((n) => sel.delete(n)); else present.forEach((n) => sel.add(n)); }
  else if (sel.has(cat)) sel.delete(cat);
  else sel.add(cat);
  if (key) saveSet(key, sel);   // key is null for the class filter (resets per map, not persisted)
}

// One colour-coded chip bar per overlay, mirroring the AI-location Class filter.
function chipBar(bar, label, present, sel, dataAttr, colorOf, countOf) {
  if (!bar) return;
  bar.classList.toggle('hidden', !present.length);
  if (!present.length) { bar.innerHTML = ''; return; }
  const allOn = present.every((n) => sel.has(n));
  bar.innerHTML =
    '<span class="mf-label">' + label + '</span>' +
    '<button type="button" class="mf-chip mf-all' + (allOn ? ' active' : '') + '" ' + dataAttr + '="*">All</button>' +
    present.map((n) => {
      const c = colorOf(n);
      return '<button type="button" class="mf-chip mf-dot' + (sel.has(n) ? ' active' : '') + '" ' + dataAttr + '="' + attr(n) +
        '" style="--dot:' + c + ';--dot-fg:' + inkOn(c) + '">' +
        '<span class="mf-swatch"></span>' + escapeHtml(n) + ' <b>' + countOf(n) + '</b></button>';
    }).join('');
}
function renderLootFilter() {
  const present = mapLoot ? mapLoot.present : [];
  chipBar(el.mapLootFilter, 'Loot', present, mapLootSel, 'data-loot',
    (n) => LOOT_COLORS[n] || LOOT_FALLBACK, (n) => (mapLoot.counts.get(n) || 0));
}
function spawnPresent() { return mapSpawns ? SPAWN_KINDS.filter((k) => Array.isArray(mapSpawns[k.key]) && mapSpawns[k.key].length) : []; }
function renderSpawnFilter() {
  const present = spawnPresent();
  const byKey = Object.fromEntries(SPAWN_KINDS.map((k) => [k.label, k]));
  chipBar(el.mapSpawnFilter, 'Spawns', present.map((k) => k.label), mapSpawnSel, 'data-spawn',
    (lbl) => byKey[lbl].color, (lbl) => (mapSpawns[byKey[lbl].key] || []).length);
}
// Buildings: one on/off chip (a single 'Structures' category), same chip machinery.
const BUILDINGS_COLOR = '#8a9199';
function renderBuildingsFilter() {
  const present = mapBuildings ? ['Structures'] : [];
  chipBar(el.mapBuildingsFilter, 'Buildings', present, mapBuildingsSel, 'data-buildings',
    () => BUILDINGS_COLOR, () => mapBuildings.n);
}
// Markers: iZurvive-derived POI layers (crashes, vehicles, hazards, wildlife…).
// Each layer carries its own name + colour, so the chip bar is data-driven.
function markerLayer(name) { return mapMarkers && mapMarkers.layers.find((l) => l.name === name); }
function renderMarkersFilter() {
  const layers = mapMarkers ? mapMarkers.layers : [];
  const present = layers.map((l) => l.name);
  chipBar(el.mapMarkersFilter, 'Markers', present, mapMarkersSel, 'data-markers',
    (n) => { const l = markerLayer(n); return l ? l.color : LOOT_FALLBACK; },
    (n) => { const l = markerLayer(n); return l ? l.pts.length : 0; });
}
// Live positions: one grouped bar, a chip each for Players (blue circles) and NPCs (red
// diamonds). Always present — 0-count chips stay clickable so the preference can be set
// before anyone is online. The NPC count reads 0 off the live map (the draw gate hides them).
function renderLiveFilter() {
  const css = (v, fb) => (getComputedStyle(document.documentElement).getPropertyValue(v) || fb).trim();
  chipBar(el.mapLiveFilter, 'Live', LIVE_KINDS, mapLiveSel, 'data-live',
    (n) => (n === 'Players' ? css('--info', '#2f6fd0') : css('--map-bad', '#c33327')),
    (n) => (mapMission !== getActiveMission() ? 0 : (n === 'Players' ? mapPlayers.length : mapBandits.positions.length)));
}

// Building footprints: small dark squares, culled to the viewport. 5-12k points,
// so this is a tight fillRect loop — footprint size eases up as you zoom in.
function drawMapBuildings(ctx) {
  if (!mapBuildings || !mapView || !mapBuildingsSel.has('Structures')) return;
  const { w, h } = mapVp();
  const pts = mapBuildings.pts, n = mapBuildings.n;
  const r = mapView.ppm > 0.5 ? 1.7 : mapView.ppm > 0.2 ? 1.1 : 0.8;
  ctx.fillStyle = 'rgba(26,24,22,0.72)';
  for (let i = 0; i < n; i++) {
    const [sx, sy] = mapToScreen(pts[i * 2], pts[i * 2 + 1]);
    if (sx < -2 || sy < -2 || sx > w + 2 || sy > h + 2) continue;
    ctx.fillRect(sx - r, sy - r, r * 2, r * 2);
  }
}

function drawMapLoot(ctx) {
  if (!mapLoot || !mapView || !mapLootSel.size) return;
  const { w, h } = mapVp();
  const r = mapView.ppm > 0.4 ? 2.4 : 1.6;             // a touch bigger when zoomed in
  const pts = mapLoot.points, names = mapLoot.catNames;
  ctx.globalAlpha = 0.85;
  for (let i = 0; i < pts.length; i++) {
    let col = null;                                    // dominant selected category wins the colour
    const nm = names[i];
    for (let k = 0; k < nm.length; k++) if (mapLootSel.has(nm[k])) { col = LOOT_COLORS[nm[k]] || LOOT_FALLBACK; break; }
    if (!col) continue;
    const [sx, sy] = mapToScreen(pts[i][0], pts[i][1]);
    if (sx < -4 || sy < -4 || sx > w + 4 || sy > h + 4) continue;
    ctx.fillStyle = col;
    ctx.fillRect(sx - r, sy - r, r * 2, r * 2);
  }
  ctx.globalAlpha = 1;
}

// Spawn markers: hollow diamonds, fresh vs travel by colour. Sparse (~40-60).
// Sakhal reuses the same points for both — travel then wins the colour.
function drawMapSpawns(ctx) {
  if (!mapSpawns || !mapView || !mapSpawnSel.size) return;
  const { w, h } = mapVp();
  const draw = (list, color) => {
    if (!Array.isArray(list)) return;
    ctx.strokeStyle = color;
    ctx.lineWidth = 2;
    for (const [x, z] of list) {
      const [sx, sy] = mapToScreen(x, z);
      if (sx < -12 || sy < -12 || sx > w + 12 || sy > h + 12) continue;
      ctx.beginPath();
      ctx.moveTo(sx, sy - 6); ctx.lineTo(sx + 6, sy); ctx.lineTo(sx, sy + 6); ctx.lineTo(sx - 6, sy);
      ctx.closePath();
      ctx.fillStyle = 'rgba(10,16,22,0.55)';
      ctx.fill();
      ctx.stroke();
    }
  };
  for (const k of SPAWN_KINDS) if (mapSpawnSel.has(k.label)) draw(mapSpawns[k.key], k.color);
}

// iZurvive-derived POI: 'point' layers are filled dots (dark halo for contrast);
// 'circle' layers (wildlife territories) are metre-radius rings that scale with zoom.
function drawMapPoi(ctx) {
  if (!mapMarkers || !mapView || !mapMarkersSel.size) return;
  const { w, h } = mapVp();
  for (const L of mapMarkers.layers) {
    if (!mapMarkersSel.has(L.name)) continue;
    if (L.kind === 'circle') {
      ctx.strokeStyle = L.color;
      ctx.lineWidth = 1.2;
      ctx.globalAlpha = 0.5;
      for (const [x, z, r] of L.pts) {
        const [sx, sy] = mapToScreen(x, z);
        const rp = (r || 60) * mapView.ppm;
        if (sx + rp < 0 || sy + rp < 0 || sx - rp > w || sy - rp > h) continue;
        ctx.beginPath();
        ctx.arc(sx, sy, Math.max(2, rp), 0, Math.PI * 2);
        ctx.stroke();
      }
      ctx.globalAlpha = 1;
      continue;
    }
    const rad = mapView.ppm > 0.5 ? 3.4 : mapView.ppm > 0.2 ? 2.6 : 2;
    for (const [x, z] of L.pts) {
      const [sx, sy] = mapToScreen(x, z);
      if (sx < -6 || sy < -6 || sx > w + 6 || sy > h + 6) continue;
      ctx.beginPath();
      ctx.arc(sx, sy, rad, 0, Math.PI * 2);
      ctx.fillStyle = L.color;
      ctx.fill();
      ctx.lineWidth = 1;
      ctx.strokeStyle = 'rgba(10,14,20,0.75)';
      ctx.stroke();
    }
  }
}

// ---------- bookmark markers ----------
// Each spawn CLASS gets its own icon SHAPE + shade, chosen to stand clear of the loot
// overlay (loot = small filled SQUARES, ~18 hues) — so no class uses a square, and the shade
// is spaced off the co-located loot colour. Shape is the unambiguous channel; height-Δ rides
// a thin outline RING around the marker. Related tokens share a shape family (military=triangle,
// patrol/road=triangle-down, scav/hermit=circle), separated by colour.
const SPAWN_CLASS = {
  Mil:    { shape: 'triangle', color: '#a78bfa' },
  MilH:   { shape: 'triangle', color: '#7c3aed' },
  Scav:   { shape: 'circle',   color: '#f59e0b' },
  Desp:   { shape: 'diamond',  color: '#fb7185' },
  Hold:   { shape: 'hexagon',  color: '#38bdf8' },
  Guard:  { shape: 'pentagon', color: '#34d399' },
  Air:    { shape: 'plus',     color: '#f472b6' },
  AKM:    { shape: 'triDown',  color: '#c084fc' },
  Road:   { shape: 'triDown',  color: '#eab308' },
  Hermit: { shape: 'circle',   color: '#cbd5e1' },
  Sniper: { shape: 'star',     color: '#f8fafc' },
};
const SPAWN_BASE = { shape: 'ring', color: '#94a3b8' };   // uncategorized -> base holdout (hollow)
function spawnClassDef(cat) { return (cat && SPAWN_CLASS[cat]) || SPAWN_BASE; }

// Path a class shape (caller fills/strokes). No axis-aligned square — that's the loot glyph.
function spawnPath(ctx, shape, x, y, r) {
  ctx.beginPath();
  if (shape === 'circle' || shape === 'ring') { ctx.arc(x, y, r, 0, Math.PI * 2); return; }
  if (shape === 'plus') {
    const t = r * 0.42;
    const pts = [[-t, -r], [t, -r], [t, -t], [r, -t], [r, t], [t, t], [t, r], [-t, r], [-t, t], [-r, t], [-r, -t], [-t, -t]];
    pts.forEach(([dx, dy], i) => (i ? ctx.lineTo(x + dx, y + dy) : ctx.moveTo(x + dx, y + dy)));
    ctx.closePath(); return;
  }
  if (shape === 'star') {
    for (let i = 0; i < 10; i++) { const a = -Math.PI / 2 + i * Math.PI / 5, rad = i % 2 ? r * 0.45 : r; const px = x + Math.cos(a) * rad, py = y + Math.sin(a) * rad; i ? ctx.lineTo(px, py) : ctx.moveTo(px, py); }
    ctx.closePath(); return;
  }
  const sides = shape === 'diamond' ? 4 : shape === 'pentagon' ? 5 : shape === 'hexagon' ? 6 : 3;
  const rot = shape === 'triDown' ? Math.PI / 2 : -Math.PI / 2;
  for (let i = 0; i < sides; i++) { const a = rot + i * 2 * Math.PI / sides; const px = x + Math.cos(a) * r, py = y + Math.sin(a) * r; i ? ctx.lineTo(px, py) : ctx.moveTo(px, py); }
  ctx.closePath();
}

// Inline SVG swatch of a class glyph — the legend chips + tooltip reuse the same shapes.
function spawnClassSvg(def, size) {
  const s = size || 13, c = s / 2, r = c - 1.5, edge = 'rgba(10,16,22,.55)';
  const poly = (pts) => '<polygon points="' + pts.map((p) => p[0].toFixed(1) + ',' + p[1].toFixed(1)).join(' ') + '" fill="' + def.color + '" stroke="' + edge + '" stroke-width="1"/>';
  const ngon = (n, rot) => { const a = []; for (let i = 0; i < n; i++) { const g = rot + i * 2 * Math.PI / n; a.push([c + Math.cos(g) * r, c + Math.sin(g) * r]); } return poly(a); };
  let inner;
  const sh = def.shape;
  if (sh === 'circle') inner = '<circle cx="' + c + '" cy="' + c + '" r="' + r + '" fill="' + def.color + '" stroke="' + edge + '" stroke-width="1"/>';
  else if (sh === 'ring') inner = '<circle cx="' + c + '" cy="' + c + '" r="' + (r - 0.5) + '" fill="none" stroke="' + def.color + '" stroke-width="2"/>';
  else if (sh === 'star') { const a = []; for (let i = 0; i < 10; i++) { const g = -Math.PI / 2 + i * Math.PI / 5, rr = i % 2 ? r * 0.45 : r; a.push([c + Math.cos(g) * rr, c + Math.sin(g) * rr]); } inner = poly(a); }
  else if (sh === 'plus') { const t = r * 0.42; inner = poly([[c - t, c - r], [c + t, c - r], [c + t, c - t], [c + r, c - t], [c + r, c + t], [c + t, c + t], [c + t, c + r], [c - t, c + r], [c - t, c + t], [c - r, c + t], [c - r, c - t], [c - t, c - t]]); }
  else inner = ngon(sh === 'diamond' ? 4 : sh === 'pentagon' ? 5 : sh === 'hexagon' ? 6 : 3, sh === 'triDown' ? Math.PI / 2 : -Math.PI / 2);
  return '<svg class="mf-ico" width="' + s + '" height="' + s + '" viewBox="0 0 ' + s + ' ' + s + '" aria-hidden="true">' + inner + '</svg>';
}

function mapColors() {
  const cs = getComputedStyle(document.documentElement);
  const v = (name) => cs.getPropertyValue(name).trim();
  return { mok: v('--map-ok'), mwarn: v('--map-warn'), mbad: v('--map-bad'), mnull: v('--faint'), ring: v('--accent'), edge: v('--card') };
}
// The selected point's roam path: spawn -> wp1 -> wp2 …, a dashed line + numbered dots. Shown only
// for the selected point (click a marker to reveal); draggable/addable/deletable in edit mode.
function drawSelectedWaypoints(ctx) {
  if (mapSelPt < 0) return;
  const p = mapPts[mapSelPt];
  if (!p || !p.waypoints || !p.waypoints.length) return;
  const C = mapColors();
  const path = [[p.x, p.z]].concat(p.waypoints.map((w) => [w.x, w.z]));
  ctx.save();
  ctx.beginPath();
  path.forEach((c, i) => { const [sx, sy] = mapToScreen(c[0], c[1]); if (i) ctx.lineTo(sx, sy); else ctx.moveTo(sx, sy); });
  ctx.strokeStyle = C.ring; ctx.lineWidth = 2; ctx.setLineDash([6, 4]); ctx.stroke(); ctx.setLineDash([]);
  ctx.font = '9px ui-monospace, SFMono-Regular, monospace'; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
  p.waypoints.forEach((w, i) => {
    const [sx, sy] = mapToScreen(w.x, w.z);
    ctx.beginPath(); ctx.arc(sx, sy, 6, 0, Math.PI * 2);
    ctx.fillStyle = C.ring; ctx.fill(); ctx.strokeStyle = C.edge; ctx.lineWidth = 1.4; ctx.stroke();
    ctx.fillStyle = C.edge; ctx.fillText(String(i + 1), sx, sy);
  });
  ctx.restore();
}
function drawMapMarkers(ctx) {
  if (MAP_POINTS_DEPRECATED) return;   // Phase 1: authored map-points layer deprecated (render off)
  if (!mapPts.length) return;
  drawSelectedWaypoints(ctx);
  const { w, h } = mapVp();
  const C = mapColors();
  mapPts.forEach((p, i) => {
    if (!mapVisible(p)) return;
    const [sx, sy] = mapToScreen(p.x, p.z);
    if (sx < -20 || sy < -20 || sx > w + 20 || sy > h + 20) return;
    const sel = (i === mapSelPt || i === mapHover);
    const r = sel ? 9 : 7;
    const def = spawnClassDef(p.cat);
    // Height-Δ ring: thin, in the band colour, just outside the class glyph.
    ctx.beginPath(); ctx.arc(sx, sy, r + 2.5, 0, Math.PI * 2);
    ctx.strokeStyle = C[mapBand(p)]; ctx.lineWidth = 2; ctx.stroke();
    // Class glyph: shape + shade. 'ring' (base) is hollow; everything else filled + dark edge.
    spawnPath(ctx, def.shape, sx, sy, r);
    if (def.shape === 'ring') { ctx.strokeStyle = def.color; ctx.lineWidth = 2.4; ctx.stroke(); }
    else { ctx.fillStyle = def.color; ctx.fill(); ctx.strokeStyle = C.edge; ctx.lineWidth = 1.4; ctx.stroke(); }
    if (i === mapSelPt) {                                  // selection accent, outside the Δ ring
      ctx.beginPath(); ctx.arc(sx, sy, r + 6, 0, Math.PI * 2);
      ctx.strokeStyle = C.ring; ctx.lineWidth = 2.5; ctx.stroke();
    }
  });
}
function mapHitTest(sx, sy) {
  let best = -1, bd = 18 * 18;                         // 18px pickup radius > 7px mark
  mapPts.forEach((p, i) => {
    if (!mapVisible(p)) return;                        // can't hover/select a filtered-out point
    const [px, py] = mapToScreen(p.x, p.z);
    const d2 = (px - sx) * (px - sx) + (py - sy) * (py - sy);
    if (d2 < bd) { bd = d2; best = i; }
  });
  return best;
}
// Hit-test the SELECTED point's waypoint dots (only shown/grabbable when a point is selected).
function mapHitWaypoint(sx, sy) {
  if (mapSelPt < 0) return -1;
  const p = mapPts[mapSelPt];
  if (!p || !p.waypoints) return -1;
  let best = -1, bd = 16 * 16;
  p.waypoints.forEach((w, i) => {
    const [px, py] = mapToScreen(w.x, w.z);
    const d2 = (px - sx) * (px - sx) + (py - sy) * (py - sy);
    if (d2 < bd) { bd = d2; best = i; }
  });
  return best;
}

// ---------- crosshair + readout ----------
function drawMapCrosshair(ctx, w, h) {
  if (!mapCursor) return;
  const [sx, sy] = mapToScreen(mapCursor.x, mapCursor.z);
  ctx.strokeStyle = 'rgba(20,32,44,0.42)';
  ctx.lineWidth = 1;
  ctx.setLineDash([5, 4]);
  ctx.beginPath();
  ctx.moveTo(Math.round(sx) + 0.5, 0); ctx.lineTo(Math.round(sx) + 0.5, h);
  ctx.moveTo(0, Math.round(sy) + 0.5); ctx.lineTo(w, Math.round(sy) + 0.5);
  ctx.stroke();
  ctx.setLineDash([]);
}

// ---------- live player overlay (anonymized {x,z}, polled on the Map tab) ----------
function drawMapPlayers(ctx) {
  if (mapMission !== getActiveMission()) return;   // live players belong to the running server's map only
  if (!mapLiveSel.has('Players')) return;
  if (!mapPlayers.length || !mapView) return;
  const fill = (getComputedStyle(document.documentElement).getPropertyValue('--info') || '#2f6fd0').trim();
  for (const p of mapPlayers) {
    const [sx, sy] = mapToScreen(p.x, p.z);
    ctx.beginPath();
    ctx.arc(sx, sy, 5, 0, Math.PI * 2);
    ctx.fillStyle = fill;
    ctx.fill();
    ctx.lineWidth = 2;
    ctx.strokeStyle = 'rgba(255,255,255,0.92)';   // white ring reads on any terrain, either theme
    ctx.stroke();
  }
}
async function loadPlayers() {
  if (rateLimited()) return;      // API said back off — skip this tick, timer stays armed
  const cred = loadCred();
  if (!cred) return;
  try {
    const r = await apiPost('/dayz/positions', cred);
    mapPlayers = Array.isArray(r.players) ? r.players : [];
    mapPlayersAt = r.at || null;
    requestMapDraw();
    updateMapBar();
    renderLiveFilter();   // keep the chip count current
  } catch (err) {
    if (handle(err)) return;   // 401 -> signed out (stops the poll via showLogin)
    /* transient error: keep the last-known dots rather than blanking the map */
  }
}
// ---------- AI bandit overlay (recent activity from the AIB Unleashed log) ----------
// Approximate on purpose: these are SPAWN coords (bandits patrol away) + recent KILL spots,
// not live tracking. Spawns = red diamonds, kills = faded rings. The -serverMod route is the
// precise-live upgrade; this is the no-mod activity view.
function drawMapBandits(ctx) {
  if (BANDIT_RENDER_DEPRECATED) return;   // BanditAI retired 2026-07-23
  if (!mapView || !mapLiveSel.has('NPCs')) return;
  // Live NPC coordinates only mean anything on the mission the server is actually running —
  // on any other selected map they'd plot at arbitrary spots, so they're hidden entirely
  // (unknown live mission counts as no match). Polling continues; switching back to the
  // live map shows current positions immediately.
  if (mapMission !== getActiveMission()) return;
  // The API already dropped positions when the file was stale/missing, so whatever is here is
  // fresh (<=60s) — plot every live bandit as a diamond, distinct from the player circles.
  const spawn = (getComputedStyle(document.documentElement).getPropertyValue('--map-bad') || '#c33327').trim();
  for (const s of mapBandits.positions) {
    const [sx, sy] = mapToScreen(s.x, s.z);
    ctx.save();
    ctx.translate(sx, sy);
    ctx.rotate(Math.PI / 4);            // a diamond (rotated square) — distinct from player circles
    ctx.fillStyle = spawn;
    ctx.fillRect(-4, -4, 8, 8);
    ctx.lineWidth = 1.5;
    ctx.strokeStyle = 'rgba(255,255,255,0.9)';
    ctx.strokeRect(-4, -4, 8, 8);
    ctx.restore();
  }
}
async function loadBandits() {
  if (rateLimited()) return;      // API said back off — skip this tick, timer stays armed
  const cred = loadCred();
  if (!cred) return;
  try {
    const r = await apiPost('/dayz/bandits', cred);
    mapBandits = {
      positions: Array.isArray(r.positions) ? r.positions : [],
      stale: !!r.stale,
      ageSec: typeof r.ageSec === 'number' ? r.ageSec : null,
    };
    requestMapDraw();
    updateMapBar();
    renderLiveFilter();   // keep the chip count current
  } catch (err) {
    if (handle(err)) return;
    /* transient (torn read / pre-deploy 404): keep last-known, don't blank */
  }
}
const MAP_POLL_MS = 45000;   // map players+bandits — relaxed; Refresh button + refresh-on-return for immediacy
export function startPlayers() { stopPlayers(); loadPlayers(); loadBandits(); mapPlayersTimer = setInterval(() => { loadPlayers(); loadBandits(); }, MAP_POLL_MS); }
export function stopPlayers() { if (mapPlayersTimer) { clearInterval(mapPlayersTimer); mapPlayersTimer = null; } mapPlayers = []; mapBandits = { positions: [], stale: false, ageSec: null }; }

function updateMapBar() {
  const scale = mapView ? (1 / mapView.ppm) : 0;
  const scaleTxt = scale >= 1 ? scale.toFixed(1) + ' m/px' : (1 / scale).toFixed(1) + ' px/m';
  const players = (mapMission !== getActiveMission() || !mapLiveSel.has('Players')) ? '' : mapPlayers.length
    ? '<span class="mp-live"><span class="mp-dot"></span>' + mapPlayers.length + ' player' + (mapPlayers.length === 1 ? '' : 's')
      + (mapPlayersAt ? ' · as of ' + escapeHtml(mapPlayersAt) : '') + '</span>'
    : '';
  // Bandit badge only when toggled on AND on the live mission's map — matches
  // drawMapBandits, so the bar never claims "N bandits" while the canvas shows none.
  const bandits = mapMission !== getActiveMission() || !mapLiveSel.has('NPCs')
    ? ''
    : mapBandits.positions.length
      ? '<span class="mp-bandit" title="Live AI-bandit positions from the AIB_Tracker serverMod (updated every 20s)">'
        + '<span class="mb-dot"></span>' + mapBandits.positions.length + ' bandit' + (mapBandits.positions.length === 1 ? '' : 's') + '</span>'
      : mapBandits.stale
        ? '<span class="mp-stale" title="AIB tracker has not updated in over a minute — the server or the AIB_Tracker serverMod may be down">bandit tracker stale</span>'
        : '';
  if (!mapCursor) {
    el.mapBar.innerHTML = '<span>hover the map for coordinates</span><span>' + escapeHtml(scaleTxt) + '</span>' + players + bandits +
      (mapTiles ? '' : '<span style="color:var(--danger)">no map tiles delivered for this map — run Build-MapTiles.ps1 -Execute -Deliver + redeploy</span>');
    return;
  }
  const y = mapLocalY(mapCursor.x, mapCursor.z);
  el.mapBar.innerHTML =
    '<span>X <b>' + mapCursor.x.toFixed(1) + '</b></span>' +
    '<span>Y <b>' + (y === null ? '—' : y.toFixed(2)) + '</b></span>' +
    '<span>Z <b>' + mapCursor.z.toFixed(1) + '</b></span>' +
    '<span>' + escapeHtml(scaleTxt) + '</span>' + players + bandits +
    '<span class="meta">right-click copies X Y Z</span>';
}

// Right-click → copy "X Y Z". The local grid answers instantly; the API's full
// grid (validated ≤0.5 m) refines Y when reachable — that call is what makes
// the copied Y spawn-grade rather than readout-grade.
async function copyMapCoords(wpt) {
  if (!wpt) return;
  let y = mapLocalY(wpt.x, wpt.z);
  const cred = loadCred();
  if (cred && mapHm) {
    try {
      const r = await apiPost('/dayz/terrain/surface-y', cred, { map: mapShort(mapMission), x: wpt.x, z: wpt.z });
      if (typeof r.y === 'number') y = r.y;
    } catch { /* offline / rate-limited → local grid value stands */ }
  }
  const txt = wpt.x.toFixed(2) + ' ' + (y === null ? '0.00' : y.toFixed(2)) + ' ' + wpt.z.toFixed(2);
  try {
    await navigator.clipboard.writeText(txt);
    toast('Copied ' + txt, 'ok');
  } catch {
    toast(txt, 'err');                                 // clipboard blocked — show it instead
  }
}

// Sidebar list, worst |Δ| first (that's the triage order); unresolved sink to the end.
// Reset the class/type filter to "everything on" for the current map's points.
function initMapFilter() { mapCatFilter = new Set(mapPts.map(mapCatKey)); }
function classKeys() { return [...new Set(mapPts.map(mapCatKey))]; }

// Draw the class/type chip bar: one chip per class present (with a count), plus an "All"
// reset. Hidden when there's nothing to filter (fewer than two classes on the map).
function renderMapFilter() {
  if (!el.mapFilter) return;
  const counts = new Map();
  for (const p of mapPts) { const k = mapCatKey(p); counts.set(k, (counts.get(k) || 0) + 1); }
  el.mapFilter.classList.toggle('hidden', counts.size < 2);
  if (counts.size < 2) { el.mapFilter.innerHTML = ''; return; }
  const cats = (mapData.classes && mapData.classes.categories) || {};
  // Known categories first (alphabetical), base holdouts last.
  const keys = [...counts.keys()].sort((a, b) => (a === '(base)') - (b === '(base)') || a.localeCompare(b));
  const allOn = keys.every((k) => mapCatFilter.has(k));
  el.mapFilter.innerHTML =
    '<span class="mf-label">Class</span>' +
    '<button type="button" class="mf-chip mf-all' + (allOn ? ' active' : '') + '" data-cat="*">All</button>' +
    keys.map((k) => {
      const label = k === '(base)' ? 'Base' : k;
      const tmpl = k === '(base)' ? 'holdout' : (cats[k] || '?');
      const def = spawnClassDef(k === '(base)' ? null : k);   // '(base)' -> the base/hollow glyph
      return '<button type="button" class="mf-chip' + (mapCatFilter.has(k) ? ' active' : '') +
        '" data-cat="' + attr(k) + '" title="' + attr(label + ' → ' + tmpl) + '">' +
        spawnClassSvg(def) + escapeHtml(label) + ' <b>' + counts.get(k) + '</b></button>';
    }).join('');
}

function renderMapList() {
  const order = mapPts.map((p, i) => i).filter((i) => mapVisible(mapPts[i])).sort((a, b) => {
    const da = mapPts[a].delta, db = mapPts[b].delta;
    if (da === undefined && db === undefined) return mapPts[a].name.localeCompare(mapPts[b].name);
    if (da === undefined) return 1;
    if (db === undefined) return -1;
    return Math.abs(db) - Math.abs(da);
  });
  const shown = order.length, total = mapPts.length;
  const count = shown === total ? total + ' spawn bookmark' + (total === 1 ? '' : 's') : shown + ' of ' + total + ' shown';
  el.mapNav.innerHTML = '<div class="side-sub2">' + count + ' · worst Δ first</div>' +
    order.map((i) => {
      const p = mapPts[i], band = mapBand(p);
      return '<div class="side-item mp-item' + (i === mapSelPt ? ' active' : '') + '" data-i="' + i + '" title="' + attr(p.name) + '">' +
        '<span class="fn">' + escapeHtml(p.name) + '</span>' +
        '<span class="mp-badge ' + band + '">' + (p.delta === undefined ? '—' : fmtDelta(p.delta)) + '</span></div>';
    }).join('');
}

function renderMapSummary() {
  if (!mapPts.length) {
    el.mapSum.innerHTML = '<span class="meta">No spawn points for ' + escapeHtml(mapShort(mapMission)) +
      (mapEdit ? ' — click the map to add one.' : ' — turn on Edit and click the map to add one.') + ' The map is still browsable.</span>';
    return;
  }
  const vis = mapPts.filter(mapVisible);
  const n = { mok: 0, mwarn: 0, mbad: 0, mnull: 0 };
  let worst = null;
  for (const p of vis) {
    n[mapBand(p)]++;
    if (p.delta !== undefined && (worst === null || Math.abs(p.delta) > Math.abs(worst))) worst = p.delta;
  }
  const filtered = vis.length !== mapPts.length;
  const chip = (band, label, count) => count ? '<span class="stat"><span class="dot ' + band + '"></span>' + label + ' <b>' + count + '</b></span>' : '';
  el.mapSum.innerHTML =
    '<span class="stat"><b>' + vis.length + '</b>' + (filtered ? ' of ' + mapPts.length : '') + ' spawn points</span>' +
    chip('mok', 'Δ ≤ 0.5 m', n.mok) + chip('mwarn', '0.5–2 m', n.mwarn) + chip('mbad', '&gt; 2 m', n.mbad) + chip('mnull', 'no height', n.mnull) +
    (worst !== null ? '<span class="stat">worst Δ <b>' + escapeHtml(fmtDelta(worst)) + '</b></span>' : '') +
    (!mapHm ? '<span class="stat" style="color:var(--danger)">no heightmap shipped for this map — Δ unavailable</span>' : '') +
    (mapSpawnDirty ? '<span class="stat" style="margin-left:auto;color:var(--warn,#c90)">unsaved edits</span>' : '');
}

function renderMapDetail() {
  const p = mapPts[mapSelPt];
  el.mapDetail.classList.toggle('hidden', !p);
  el.mapDetail.classList.toggle('editing', !!p && mapEdit);
  if (!p) return;
  const cats = (mapData.classes && mapData.classes.categories) || {};
  if (mapEdit) { el.mapDetail.innerHTML = mapEditFormHtml(p, cats); return; }
  const band = mapBand(p);
  const role = p.cat ? p.cat + ' → ' + (cats[p.cat] || '?') : 'base → holdout';
  el.mapDetail.innerHTML =
    '<span><span class="k2">Name</span><b class="mono">' + escapeHtml(p.name) + '</b></span>' +
    '<span><span class="k2">Role</span>' + escapeHtml(role) + (p.size ? ' · size ' + escapeHtml(p.size) : '') + '</span>' +
    '<span><span class="k2">Faction</span>' + escapeHtml(effFaction(p)) + (p.faction ? '' : ' <span class="k2">(default)</span>') + '</span>' +
    '<span><span class="k2">Systems</span>' + escapeHtml(effSpawns(p).slice().sort().join(' + ') || 'none') + (p.spawns ? '' : ' <span class="k2">(default)</span>') + '</span>' +
    '<span><span class="k2">Roam</span>' + escapeHtml((p.type || 'Local') + ' · r' + (p.radius != null ? p.radius : 'default')) + '</span>' +
    '<span><span class="k2">X / Z</span><span class="mono">' + p.x.toFixed(1) + ' / ' + p.z.toFixed(1) + '</span></span>' +
    '<span><span class="k2">Y</span><span class="mono">' + p.y.toFixed(2) + '</span></span>' +
    '<span><span class="k2">Terrain Y</span><span class="mono">' + (p.ty === undefined ? '—' : p.ty.toFixed(2)) + '</span></span>' +
    '<span><span class="k2">Δ</span><span class="mp-badge ' + band + '">' + (p.delta === undefined ? '—' : fmtDelta(p.delta)) + '</span></span>';
}

// The editable form shown in the detail bar when a point is selected in edit mode.
function mapEditFormHtml(p, cats) {
  const sizes = (mapData.classes && mapData.classes.sizes) || {};
  const catOpts = ['(base)'].concat(Object.keys(cats));
  const sizeOpts = ['(default)'].concat(Object.keys(sizes));
  const cur = p.cat || '(base)', curSize = p.size || '(default)';
  const catSel = catOpts.map((k) => '<option value="' + attr(k) + '"' + (k === cur ? ' selected' : '') + '>' +
    escapeHtml(k === '(base)' ? 'Base (holdout)' : k + ' → ' + (cats[k] || '?')) + '</option>').join('');
  const sizeSel = sizeOpts.map((k) => '<option value="' + attr(k) + '"' + (k === curSize ? ' selected' : '') + '>' +
    escapeHtml(k === '(default)' ? 'Default' : k + ' (' + sizes[k] + ')') + '</option>').join('');
  const curFac = p.faction || '(default)';
  const facSel = ['(default)'].concat(AI_FACTIONS).map((k) => '<option value="' + attr(k) + '"' + (k === curFac ? ' selected' : '') + '>' +
    escapeHtml(k === '(default)' ? 'Default (' + docDefaultFaction() + ')' : k) + '</option>').join('');
  const spVal = p.spawns ? p.spawns.slice().sort().join('+') : '(default)';
  const sysSel = [['(default)', 'Default (' + docDefaultSpawns().slice().sort().join('+') + ')'], ['aib', 'AIB only'], ['expansion', 'Expansion only'], ['aib+expansion', 'Both'], ['', 'None']]
    .map(([v, lbl]) => '<option value="' + attr(v) + '"' + (v === spVal ? ' selected' : '') + '>' + escapeHtml(lbl) + '</option>').join('');
  const typeCur = p.type || '(default)';
  const typeSel = ['(default)'].concat(LOCATION_TYPES).map((k) => '<option value="' + attr(k) + '"' + (k === typeCur ? ' selected' : '') + '>' +
    escapeHtml(k === '(default)' ? 'Default (Local)' : k) + '</option>').join('');
  const num = (id, v) => '<label class="me-f"><span class="k2">' + id.slice(2) + '</span>' +
    '<input class="me-in me-num" id="me' + id.slice(2) + '" type="number" step="0.1" value="' + v.toFixed(2) + '"></label>';
  const pVal = (k) => (p.patrol && p.patrol[k] != null) ? p.patrol[k] : '';
  const advRows = PATROL_FIELDS.map((f) => {
    if (f.t === 'bool') {
      const cur = pVal(f.k) === '' ? '' : (pVal(f.k) ? '1' : '0');
      return '<label class="me-f"><span class="k2">' + f.label + '</span><select class="me-in" id="mePatrol_' + f.k + '">' +
        [['', 'Default (' + (f.def === '1' ? 'Yes' : 'No') + ')'], ['1', 'Yes'], ['0', 'No']].map((o) => '<option value="' + o[0] + '"' + (o[0] === cur ? ' selected' : '') + '>' + o[1] + '</option>').join('') +
        '</select></label>';
    }
    const isNum = (f.t === 'num' || f.t === 'int');
    return '<label class="me-f"><span class="k2">' + f.label + '</span><input class="me-in' + (isNum ? ' me-num' : '') + '" id="mePatrol_' + f.k + '"' +
      (isNum ? ' type="number" step="' + (f.t === 'int' ? '1' : '0.01') + '"' : ' type="text"') +
      ' value="' + attr(pVal(f.k)) + '" placeholder="' + attr(f.def || 'default') + '"></label>';
  }).join('');
  const advanced = '<details class="me-adv"><summary class="me-adv-sum">Patrol tuning (advanced) — blank inherits</summary>' + advRows + '</details>';
  const wps = p.waypoints || [];
  const wpSection = '<div class="me-wps"><span class="k2">Waypoints (' + wps.length + ')</span>' +
    wps.map((w, i) => '<div class="me-wp"><span class="mono">' + (i + 1) + '. ' + w.x.toFixed(0) + ' / ' + w.z.toFixed(0) + '</span><button type="button" class="me-wp-del" data-wp="' + i + '" title="Delete waypoint">✕</button></div>').join('') +
    '<span class="me-wp-hint">Shift-click the map to add · drag dots to move</span></div>';
  return '<label class="me-f me-wide"><span class="k2">Name</span><input class="me-in" id="meName" value="' + attr(p.name) + '"></label>' +
    '<label class="me-f"><span class="k2">Class</span><select class="me-in" id="meCat">' + catSel + '</select></label>' +
    '<label class="me-f"><span class="k2">Size</span><select class="me-in" id="meSize">' + sizeSel + '</select></label>' +
    '<label class="me-f"><span class="k2">Faction</span><select class="me-in" id="meFaction">' + facSel + '</select></label>' +
    '<label class="me-f"><span class="k2">Systems</span><select class="me-in" id="meSystems">' + sysSel + '</select></label>' +
    '<label class="me-f"><span class="k2">Type</span><select class="me-in" id="meType">' + typeSel + '</select></label>' +
    '<label class="me-f"><span class="k2">Radius</span><input class="me-in me-num" id="meRadius" type="number" step="10" value="' + attr(p.radius != null ? p.radius : '') + '" placeholder="default"></label>' +
    num('meX', p.x) + num('meZ', p.z) + num('meY', p.y) +
    '<button class="ghost me-btn" id="meSnap" type="button" title="Set Y to the terrain height at this X/Z">Snap Y</button>' +
    '<button class="ghost me-btn me-del" id="meDel" type="button">Delete</button>' + wpSection + advanced;
}

function markSpawnDirty() { mapSpawnDirty = true; updateMapEditUi(); }

// Add a new point at a world position (edit mode, click on empty map). Auto-named unique.
function addSpawnAt(wx, wz) {
  if (MAP_POINTS_DEPRECATED) return;   // Phase 1: no new points on the deprecated authored layer
  const letter = mapLettersFor(mapMission)[0] || 'S';
  const taken = new Set(mapPts.map((p) => p.name).concat((mapData.spawns.points || []).map((p) => p.name)));
  let i = 1, name; do { name = letter + '_New' + i++; } while (taken.has(name));
  const gy = mapLocalY(wx, wz);
  const p = { name, map: letter, cat: null, size: null, faction: null, spawns: null, type: null, radius: null, waypoints: null, x: wx, z: wz,
    y: gy == null ? 0 : gy, ty: gy == null ? undefined : gy, delta: gy == null ? undefined : 0 };
  mapPts.push(p);
  mapCatFilter.add(mapCatKey(p));          // keep the new point visible under the current filter
  mapSelPt = mapPts.length - 1;
  markSpawnDirty();
  renderMap();
}

function deleteSelSpawn() {
  if (mapSelPt < 0) return;
  mapPts.splice(mapSelPt, 1);
  mapSelPt = -1;
  markSpawnDirty();
  renderMap();
}

// Append a roam-path waypoint to a point (Y snaps to terrain); shift-click on the map calls this.
function addWaypointTo(idx, wx, wz) {
  const p = mapPts[idx]; if (!p) return;
  if (!p.waypoints) p.waypoints = [];
  const gy = mapLocalY(wx, wz);
  p.waypoints.push({ x: wx, z: wz, y: gy == null ? 0 : gy });
  markSpawnDirty();
  renderMap();
}
function deleteWaypoint(idx, wi) {
  const p = mapPts[idx]; if (!p || !p.waypoints) return;
  p.waypoints.splice(wi, 1);
  if (!p.waypoints.length) delete p.waypoints;
  markSpawnDirty();
  renderMap();
}

function snapSelY() {
  const p = mapPts[mapSelPt]; if (!p) return;
  const gy = mapLocalY(p.x, p.z);
  if (gy == null) { toast('No heightmap for this map — set Y by hand', 'err'); return; }
  p.y = gy; p.ty = gy; p.delta = 0;
  markSpawnDirty();
  renderMap();
}

// Live field edits from the detail form. Never re-renders the detail panel (that would drop
// input focus mid-keystroke) — updates the canvas, list, and dirty state only.
function onMapEditInput(e) {
  const p = mapPts[mapSelPt]; if (!p || !mapEdit) return;
  const id = e.target.id, v = e.target.value;
  if (id === 'meName') p.name = v;
  else if (id === 'meCat') { p.cat = v === '(base)' ? null : v; mapCatFilter.add(mapCatKey(p)); }
  else if (id === 'meSize') p.size = v === '(default)' ? null : v;
  else if (id === 'meFaction') p.faction = v === '(default)' ? null : v;
  else if (id === 'meSystems') p.spawns = v === '(default)' ? null : (v === '' ? [] : v.split('+'));
  else if (id === 'meType') p.type = v === '(default)' ? null : v;
  else if (id === 'meRadius') p.radius = (v === '' ? null : (parseFloat(v) || 0));
  else if (id === 'meX') p.x = parseFloat(v) || 0;
  else if (id === 'meZ') p.z = parseFloat(v) || 0;
  else if (id === 'meY') p.y = parseFloat(v) || 0;
  else if (id.indexOf('mePatrol_') === 0) {
    const pk = id.slice(9), pf = PATROL_FIELDS.find((x) => x.k === pk);
    if (!pf) return;
    if (!p.patrol) p.patrol = {};
    if (v === '') delete p.patrol[pk];
    else if (pf.t === 'bool') p.patrol[pk] = (v === '1') ? 1 : 0;
    else if (pf.t === 'int') p.patrol[pk] = parseInt(v, 10) || 0;
    else if (pf.t === 'num') p.patrol[pk] = parseFloat(v) || 0;
    else p.patrol[pk] = v;
    if (!Object.keys(p.patrol).length) delete p.patrol;
  }
  else return;
  markSpawnDirty();
  requestMapDraw();
  renderMapList();
}

function selectMapPt(i, center) {
  mapSelPt = i === mapSelPt ? -1 : i;
  if (center && mapSelPt > -1 && mapView) {            // sidebar pick → fly to it
    const p = mapPts[mapSelPt];
    mapView.cx = p.x;
    mapView.cz = p.z;
    if (mapView.ppm < 0.35) mapView.ppm = mapClampPpm(0.5);
    mapClampCenter();
  }
  renderMap();
  const row = el.mapNav.querySelector('.mp-item.active');
  if (row) row.scrollIntoView({ block: 'nearest' });
}

function mapTipHtml(p) {
  const cats = (mapData.classes && mapData.classes.categories) || {};
  return '<b class="mono">' + escapeHtml(p.name) + '</b><br>' +
    spawnClassSvg(spawnClassDef(p.cat)) + escapeHtml(p.cat ? p.cat + ' → ' + (cats[p.cat] || '?') : 'base → holdout') + '<br>' +
    '<span class="mono">' + p.x.toFixed(0) + ' / ' + p.z.toFixed(0) + '</span> · Y ' + p.y.toFixed(2) +
    (p.ty !== undefined ? '<br>terrain Y ' + p.ty.toFixed(2) + ' · Δ ' + escapeHtml(fmtDelta(p.delta)) : '');
}
function moveMapTip(e) {
  if (el.mapTip.style.display !== 'block') return;
  const w = el.mapTip.offsetWidth, h = el.mapTip.offsetHeight;
  el.mapTip.style.left = Math.min(e.clientX + 14, window.innerWidth - w - 8) + 'px';
  el.mapTip.style.top = Math.min(e.clientY + 14, window.innerHeight - h - 8) + 'px';
}

// The #map hash fragment for the CURRENT camera. The shell calls this only while the map
// tab is active, so the old currentTab guard is gone (mapView null = no camera yet).
export function mapHashFrag() {
  if (!mapView) return 'map';
  return 'map/' + encodeURIComponent(mapShort(mapMission)) + '/' +
    Math.round(mapView.cx) + ',' + Math.round(mapView.cz) + ',' + (+mapView.ppm.toFixed(4));
}

// Unsaved spawn edits? — the shell's beforeunload guard asks.
export function mapIsDirty() { return mapSpawnDirty; }

export function initMap() {

  // Map tab: selector, refresh, and the canvas camera (drag pan, wheel/pinch
  // zoom, hover tooltip, click select, right-click copy).
  el.mapSel.addEventListener('change', () => { mapTakeControl(); setMapMission(el.mapSel.value); });
  el.mapRefresh.addEventListener('click', () => { mapData = null; loadMapTab(true); });
  (() => {
    const c = el.mapCanvas;
    const touches = new Map();                            // active pointers (pinch = 2)
    let drag = null;                                      // { id, sx, sy, cx0, cz0, moved }
    let pinch = null;                                     // { d0, ppm0 }
    let moving = null;                                    // edit-mode marker drag: { id, idx }
    const dist = () => {
      const [a, b] = [...touches.values()];
      return Math.hypot(a.x - b.x, a.y - b.y) || 1;
    };
    c.addEventListener('pointerdown', (e) => {
      if (!mapView || e.button === 2) return;
      c.setPointerCapture(e.pointerId);
      touches.set(e.pointerId, { x: e.offsetX, y: e.offsetY });
      if (touches.size === 2) { drag = null; moving = null; pinch = { d0: dist(), ppm0: mapView.ppm }; mapTakeControl(); }
      else if (touches.size === 1) {
        // Edit mode: grab a waypoint of the selected point, or a marker, to move it; empty space pans (a click adds).
        const wp = (mapEdit && mapSelPt > -1) ? mapHitWaypoint(e.offsetX, e.offsetY) : -1;
        const hit = (mapEdit && wp < 0) ? mapHitTest(e.offsetX, e.offsetY) : -1;
        if (wp > -1) { moving = { id: e.pointerId, idx: mapSelPt, wp: wp }; el.mapTip.style.display = 'none'; }
        else if (hit > -1) { moving = { id: e.pointerId, idx: hit, wp: -1 }; mapSelPt = hit; el.mapTip.style.display = 'none'; renderMap(); }
        else { mapTakeControl(); drag = { id: e.pointerId, sx: e.offsetX, sy: e.offsetY, cx0: mapView.cx, cz0: mapView.cz, moved: false }; }
      }
    });
    c.addEventListener('pointermove', (e) => {
      if (!mapView) return;
      if (touches.has(e.pointerId)) touches.set(e.pointerId, { x: e.offsetX, y: e.offsetY });
      if (pinch && touches.size === 2) {
        const [a, b] = [...touches.values()];
        mapView.ppm = mapClampPpm(pinch.ppm0 * (dist() / pinch.d0));
        mapClampCenter();
        mapCursor = mapToWorld((a.x + b.x) / 2, (a.y + b.y) / 2);
        requestMapDraw();
        shellHooks.syncHashSoon();
        return;
      }
      if (moving && e.pointerId === moving.id) {          // drag a marker or a waypoint to a new X/Z (edit mode)
        const w = mapToWorld(e.offsetX, e.offsetY);
        const gy = mapLocalY(w.x, w.z);
        if (moving.wp > -1) {                             // a waypoint of the selected point
          const wp = mapPts[moving.idx].waypoints[moving.wp];
          wp.x = w.x; wp.z = w.z; if (gy != null) wp.y = gy;
        } else {                                          // the spawn marker itself
          const p = mapPts[moving.idx];
          p.x = w.x; p.z = w.z;
          if (gy != null) { p.y = gy; p.ty = gy; p.delta = 0; }   // snap to ground; Y is editable in the panel
        }
        mapCursor = w;
        markSpawnDirty();
        renderMapDetail();                                // live-update the X/Z/Y fields + waypoint list
        requestMapDraw();
        return;
      }
      if (drag && e.pointerId === drag.id) {
        const dx = e.offsetX - drag.sx, dy = e.offsetY - drag.sy;
        if (Math.abs(dx) + Math.abs(dy) > 4) drag.moved = true;
        if (drag.moved) {
          mapView.cx = drag.cx0 - dx / mapView.ppm;
          mapView.cz = drag.cz0 + dy / mapView.ppm;
          mapClampCenter();
        }
      }
      mapCursor = mapToWorld(e.offsetX, e.offsetY);
      const hov = (drag && drag.moved) ? -1 : mapHitTest(e.offsetX, e.offsetY);
      if (hov !== mapHover) {
        mapHover = hov;
        c.style.cursor = hov > -1 ? (mapEdit ? 'move' : 'pointer') : 'crosshair';
        if (hov > -1) { el.mapTip.innerHTML = mapTipHtml(mapPts[hov]); el.mapTip.style.display = 'block'; }
        else el.mapTip.style.display = 'none';
      }
      if (mapHover > -1) moveMapTip(e);
      requestMapDraw();
    });
    const endPointer = (e) => {
      touches.delete(e.pointerId);
      if (touches.size < 2) pinch = null;
      if (moving && e.pointerId === moving.id) { moving = null; renderMap(); return; }
      if (drag && e.pointerId === drag.id) {
        if (!drag.moved && e.type === 'pointerup') {
          const i = mapHitTest(e.offsetX, e.offsetY);
          if (i > -1) selectMapPt(i);
          else if (mapEdit) {
            const w = mapToWorld(e.offsetX, e.offsetY);
            if (e.shiftKey && mapSelPt > -1) addWaypointTo(mapSelPt, w.x, w.z);  // shift+click empty = append a waypoint to the selected point
            else addSpawnAt(w.x, w.z);                                            // click empty = add a new point
          }
        }
        drag = null;
      }
      shellHooks.syncHash();                             // pan/pinch settled — commit the camera to the URL
    };
    c.addEventListener('pointerup', endPointer);
    c.addEventListener('pointercancel', endPointer);
    c.addEventListener('pointerleave', () => {
      mapCursor = null;
      if (mapHover > -1) { mapHover = -1; el.mapTip.style.display = 'none'; c.style.cursor = 'crosshair'; }
      requestMapDraw();
    });
    c.addEventListener('wheel', (e) => {
      if (!mapView) return;
      e.preventDefault();
      mapZoomAt(e.offsetX, e.offsetY, Math.exp(-e.deltaY * 0.0016));
    }, { passive: false });
    c.addEventListener('dblclick', (e) => { if (mapView) mapZoomAt(e.offsetX, e.offsetY, 2); });
    c.addEventListener('contextmenu', (e) => {
      e.preventDefault();
      if (mapView) copyMapCoords(mapToWorld(e.offsetX, e.offsetY));
    });
    window.addEventListener('resize', () => { if (!el.maptab.classList.contains('hidden')) requestMapDraw(); });
    // Follow the OS while no explicit choice is stored; a pinned theme ignores OS changes.
    if (window.matchMedia) window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', (e) => {
      try { if (!localStorage.getItem('cfgview-theme')) { document.documentElement.dataset.theme = e.matches ? 'dark' : 'light'; shellHooks.updateThemeToggle(); } } catch { /* ignore */ }
      requestMapDraw();
    });
  })();
  el.mapNav.addEventListener('click', (e) => { const r = e.target.closest('.mp-item'); if (r) selectMapPt(+r.dataset.i, true); });
  el.mapFilter.addEventListener('click', (e) => {
    const b = e.target.closest('.mf-chip'); if (!b) return;
    toggleOverlay(mapCatFilter, null, b.dataset.cat, classKeys());     // same All-then-none logic as the overlay bars
    if (mapSelPt > -1 && !mapVisible(mapPts[mapSelPt])) mapSelPt = -1;  // drop a now-hidden selection
    if (mapHover > -1 && !mapVisible(mapPts[mapHover])) mapHover = -1;
    renderMap();
  });
  el.mapLayerSeg.addEventListener('click', (e) => { const b = e.target.closest('button[data-layer]'); if (b) setMapLayer(b.dataset.layer); });
  el.mapGridSeg.addEventListener('click', (e) => { const b = e.target.closest('button[data-grid]'); if (b) setMapGrid(b.dataset.grid); });
  setMapGrid(mapGrid);   // mark the persisted choice active
  el.mapLootFilter.addEventListener('click', (e) => {
    const b = e.target.closest('.mf-chip'); if (!b) return;
    toggleOverlay(mapLootSel, 'cfgview-maploot', b.dataset.loot, mapLoot ? mapLoot.present : []);
    renderLootFilter(); requestMapDraw();
  });
  el.mapSpawnFilter.addEventListener('click', (e) => {
    const b = e.target.closest('.mf-chip'); if (!b) return;
    toggleOverlay(mapSpawnSel, 'cfgview-mapspawns', b.dataset.spawn, spawnPresent().map((k) => k.label));
    renderSpawnFilter(); requestMapDraw();
  });
  el.mapBuildingsFilter.addEventListener('click', (e) => {
    const b = e.target.closest('.mf-chip'); if (!b) return;
    toggleOverlay(mapBuildingsSel, 'cfgview-mapbuildings', b.dataset.buildings, mapBuildings ? ['Structures'] : []);
    renderBuildingsFilter(); requestMapDraw();
  });
  el.mapMarkersFilter.addEventListener('click', (e) => {
    const b = e.target.closest('.mf-chip'); if (!b) return;
    toggleOverlay(mapMarkersSel, 'cfgview-mapmarkers', b.dataset.markers, mapMarkers ? mapMarkers.layers.map((l) => l.name) : []);
    renderMarkersFilter(); requestMapDraw();
  });
  el.mapLiveFilter.addEventListener('click', (e) => {
    const b = e.target.closest('.mf-chip'); if (!b) return;
    toggleOverlay(mapLiveSel, 'cfgview-maplive', b.dataset.live, LIVE_KINDS);
    renderLiveFilter(); requestMapDraw(); updateMapBar();
  });
  el.mapEditSeg.addEventListener('click', () => toggleMapEdit());
  el.mapSaveBtn.addEventListener('click', () => saveSpawns());
  el.mapDiscardBtn.addEventListener('click', () => discardSpawns());
  el.mapDetail.addEventListener('input', onMapEditInput);
  el.mapDetail.addEventListener('change', onMapEditInput);
  el.mapDetail.addEventListener('click', (e) => {
    if (e.target.id === 'meDel') deleteSelSpawn();
    else if (e.target.id === 'meSnap') snapSelY();
    else if (e.target.classList.contains('me-wp-del')) deleteWaypoint(mapSelPt, +e.target.dataset.wp);
  });
}
