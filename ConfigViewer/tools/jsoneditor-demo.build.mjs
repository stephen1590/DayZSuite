// Demo builder for the REUSABLE json-editor wrapper. This no longer embeds its own theme/glue -
// it inlines the actual repo files (web/jsoneditor-theme.css + web/js/json-editor-ui.js) into a
// self-contained artifact, so the demo runs the exact code any page on the site would. If the demo
// looks right, the shipped module is right. Only the two-pane chrome + Live-value dump is demo-only.
import { readFileSync, writeFileSync } from 'node:fs';

const WEB = '/home/meshy/Documents/Dev/UbuntuHost/GameServices/ConfigViewer/web';
const SCRATCH = '/tmp/claude-1000/-home-meshy-Documents-Dev/98095c5b-f68b-406e-b361-cc318d3064d3/scratchpad';

const lib = readFileSync(WEB + '/vendor/jsoneditor-2.17.1.min.js', 'utf8');
const themeCss = readFileSync(WEB + '/jsoneditor-theme.css', 'utf8');
// the real module, minus the ES export so it runs as a plain <script> global inside the artifact
const moduleSrc = readFileSync(WEB + '/js/json-editor-ui.js', 'utf8').replace(/^export\s+/gm, '');
const schema = JSON.parse(readFileSync(SCRATCH + '/loadout.schema.json', 'utf8'));
let data = JSON.parse(readFileSync(SCRATCH + '/loadout.json', 'utf8'));

const cap = (v, n = 3) => Array.isArray(v) ? v.slice(0, n).map((x) => cap(x, n))
  : (v && typeof v === 'object') ? Object.fromEntries(Object.keys(v).map((k) => [k, cap(v[k], n)])) : v;
data = cap(data, 3);
data.Unknown_New_Field = 'a mod update added this - schema never saw it';

const loosen = (node) => {
  if (!node || typeof node !== 'object') return;
  if (node.type === 'object') { node.additionalProperties = true; if (node.required) node.required = []; }
  if (node.type === 'integer') node.type = 'number';
  for (const k of Object.keys(node)) loosen(node[k]);
};
loosen(schema);

// demo-only init: mount the shared module, wire the Live-value dump + density chrome around it
const initJs = `
const DEMO_SCHEMA = ${JSON.stringify(schema)};
const DEMO_DATA = ${JSON.stringify(data)};
const out = document.getElementById('out');
const HLRE = /("[^"]*"\\s*:)|("[^"]*")|\\b(true|false|null)\\b|(-?\\d[\\d.eE+-]*)/g;
const hl = (o) => JSON.stringify(o, null, 2).replace(/[&<]/g, (c) => c === '&' ? '&amp;' : '&lt;')
  .replace(HLRE, (m, a, b, c) => '<span class="hl-' + (a ? 'key' : b ? 'str' : c === 'null' ? 'nul' : c ? 'bool' : 'num') + '">' + m + '</span>');
const dump = (val) => { try { out.innerHTML = hl(val); } catch(e){ out.textContent = String(e); } };
const DK = 'je-demo-density';
const saved = (() => { try { return localStorage.getItem(DK) || 'inline'; } catch(e){ return 'inline'; } })();
mountJsonEditor(document.getElementById('editor'), { schema: DEMO_SCHEMA, startval: DEMO_DATA, density: saved, onChange: dump })
  .then((h) => {
    const setD = (d) => { h.setDensity(d); document.querySelectorAll('.dens button').forEach((b) => b.classList.toggle('on', b.dataset.d === d)); try { localStorage.setItem(DK, d); } catch(e){} };
    document.querySelectorAll('.dens button').forEach((b) => b.onclick = () => setD(b.dataset.d));
    setD(saved);
  });
`;

const html = `<title>json-editor - themed</title>
<style>
:root{ --bg:#0e1217; --fg:#e7edf3; --muted:#8b98a7; --faint:#5c6875; --card:#151b23; --panel2:#1a222c;
  --border:#263140; --border-soft:#1c2530; --accent:#d7a13b; --accent-fg:#1a1205; --danger:#ef5b52; --ok:#57c98a; --drift:#e8843c; --tree-guide:#33455a; --pre-bg:#0b1017; --pre-fg:#cfd9e4; }
@media (prefers-color-scheme: light){ :root{ --bg:#eaeef3; --fg:#1a2028; --muted:#59636f; --faint:#8592a0; --card:#fff; --panel2:#f2f5f8; --border:#d2dae2; --border-soft:#e5eaef; --accent:#a9741a; --accent-fg:#fff; --danger:#c33327; --ok:#1a8a44; --drift:#c2570b; --tree-guide:#b7c3d0; } }
:root[data-theme=light]{ --bg:#eaeef3; --fg:#1a2028; --muted:#59636f; --faint:#8592a0; --card:#fff; --panel2:#f2f5f8; --border:#d2dae2; --border-soft:#e5eaef; --accent:#a9741a; --accent-fg:#fff; --danger:#c33327; --ok:#1a8a44; --drift:#c2570b; --tree-guide:#b7c3d0; }
:root[data-theme=dark]{ --bg:#0e1217; --fg:#e7edf3; --muted:#8b98a7; --faint:#5c6875; --card:#151b23; --panel2:#1a222c; --border:#263140; --border-soft:#1c2530; --accent:#d7a13b; --accent-fg:#1a1205; --danger:#ef5b52; --ok:#57c98a; --drift:#e8843c; --tree-guide:#33455a; }
*{box-sizing:border-box}
body{ margin:0; background:var(--bg); color:var(--fg); padding:22px 20px 60px; font-size:14px; line-height:1.5; font-family:system-ui,-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif; }
.wrap{ max-width:1000px; margin:0 auto; }
h1{ font-size:20px; margin:0 0 4px; }
.sub{ color:var(--muted); font-size:13px; margin:0 0 14px; max-width:80ch; } .sub b{ color:var(--fg); }
.tag{ display:inline-block; font-size:10px; font-weight:700; letter-spacing:.4px; text-transform:uppercase; padding:2px 7px; border-radius:5px; background:color-mix(in srgb,var(--accent) 14%,transparent); color:var(--accent); border:1px solid color-mix(in srgb,var(--accent) 40%,transparent); }
.cols{ display:flex; gap:16px; align-items:flex-start; flex-wrap:wrap; }
.pane{ flex:1; min-width:320px; border:1px solid var(--border); border-radius:11px; background:var(--card); padding:12px 14px; }
.pane h2{ font-size:11px; text-transform:uppercase; letter-spacing:.6px; color:var(--muted); margin:0 0 10px; display:flex; align-items:center; }
#out{ margin:0; font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; font-size:11px; color:var(--pre-fg); background:var(--pre-bg); border:1px solid var(--border); border-radius:8px; padding:10px; white-space:pre; overflow:auto; max-height:78vh; }
#out .hl-key{ color:#7ca8ff; } #out .hl-str{ color:#8fd6a0; } #out .hl-num{ color:#e0a458; } #out .hl-bool{ color:#c792ea; } #out .hl-nul{ color:#6b7a8a; font-style:italic; }
.dens{ margin-left:8px; display:inline-flex; border:1px solid var(--border); border-radius:6px; overflow:hidden; }
.dens button{ background:var(--panel2); color:var(--muted); border:0; border-left:1px solid var(--border); font-size:10px; font-weight:700; letter-spacing:.3px; padding:2px 8px; cursor:pointer; }
.dens button:first-child{ border-left:0; } .dens button.on{ background:var(--accent); color:var(--accent-fg); }

/* ===== inlined from web/jsoneditor-theme.css (the real, shipped theme) ===== */
${themeCss}
</style>

<div class="wrap">
  <h1>json-editor - themed <span class="tag">shared module: jsoneditor-theme.css + json-editor-ui.js</span></h1>
  <p class="sub">This demo runs the <b>actual repo files</b> - <b>web/js/json-editor-ui.js</b> (mountJsonEditor) + <b>web/jsoneditor-theme.css</b> - inlined, so what you see is what any page gets. Array items titled <b>Key [i/N]</b>; per-item <b>✕ / ↑ / ↓</b> lifted right into the title row; object <b>+</b> green by the name; status <b>[N] / [ ] (null) / null</b>, empties dimmed gold; sticky path bar with copy. Inline/Stacked top-right.</p>
  <div class="cols">
    <div class="pane"><h2>Editor <span class="dens"><button data-d="inline">Inline</button><button data-d="stacked">Stacked</button></span></h2><div id="editor"></div></div>
    <div class="pane"><h2>Live value</h2><pre id="out"></pre></div>
  </div>
</div>

<script>${lib}</script>
<script>${moduleSrc}</script>
<script>${initJs}</script>`;

writeFileSync(SCRATCH + '/jsoneditor-demo.html', html);
console.log('wrote jsoneditor-demo.html (' + (html.length / 1024).toFixed(0) + ' KB)');
console.log('theme css bytes: ' + themeCss.length + '  |  module (export-stripped) has mountJsonEditor: ' + /function mountJsonEditor/.test(moduleSrc) + '  |  export left: ' + /\bexport\b/.test(moduleSrc));
