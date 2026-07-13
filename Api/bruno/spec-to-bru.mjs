#!/usr/bin/env node
// Scaffold .bru request files from ../openapi.yaml - the spec is the source of
// truth for the HTTP surface; this script turns it into Bruno requests so new
// endpoints don't mean hand-writing collection files.
//
// EXISTING .bru files are never touched: hand-tuned docs, bodies, and seq
// ordering stay yours. Delete a file (or pass --force) to regenerate it.
//
// Workflow for a new endpoint: implement it in ../app/src/actions.ts, document
// it in ../openapi.yaml, run `npm run generate` here, tune the new .bru.
import { readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync } from 'node:fs';
import { dirname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parse } from 'yaml';
import lang from '@usebruno/lang';

const { jsonToBruV2, bruToJsonV2 } = lang;
const root = dirname(fileURLToPath(import.meta.url));
const force = process.argv.includes('--force');
const spec = parse(readFileSync(join(root, '../openapi.yaml'), 'utf8'));

// Next free meta.seq in a folder, so generated requests append after existing ones.
function nextSeq(dir) {
  if (!existsSync(dir)) return 1;
  let max = 0;
  for (const f of readdirSync(dir)) {
    if (!f.endsWith('.bru')) continue;
    try {
      const j = bruToJsonV2(readFileSync(join(dir, f), 'utf8'));
      max = Math.max(max, parseInt(j.meta?.seq ?? '0', 10) || 0);
    } catch { /* unparseable file - ignore for seq purposes */ }
  }
  return max + 1;
}

const created = [];
const skipped = [];
const isParam = (s) => s.startsWith('{') && s.endsWith('}');

for (const [path, methods] of Object.entries(spec.paths ?? {})) {
  for (const [method, op] of Object.entries(methods)) {
    if (!['get', 'post', 'put', 'patch', 'delete'].includes(method)) continue;

    // File placement mirrors the URL: /dayz/log -> dayz/log.bru, /healthz -> healthz.bru.
    // File placement mirrors the URL at any depth: the last literal segment names
    // the file, every literal segment before it is a nested folder. Path params
    // ({token}) never name files. So /dayz/sources/vpp/{token} -> dayz/sources/vpp.bru.
    const segs = path.split('/').filter(Boolean);
    const nameSegs = segs.filter((s) => !isParam(s));
    const name = nameSegs[nameSegs.length - 1] || 'index'; // '/' -> index.bru
    const folderSegs = nameSegs.slice(0, -1);
    const dir = folderSegs.length ? join(root, ...folderSegs) : root;
    const file = join(dir, `${name}.bru`);
    if (existsSync(file) && !force) {
      skipped.push(relative(root, file));
      continue;
    }

    // Query params with spec defaults go straight into the URL (matching how the
    // hand-written requests look); path params become Bruno :params to fill in.
    const query = (op.parameters ?? []).filter((p) => p.in === 'query' && p.schema?.default !== undefined);
    const qs = query.map((p) => `${p.name}=${p.schema.default}`).join('&');
    const urlPath = segs.map((s) => (isParam(s) ? `:${s.slice(1, -1)}` : s)).join('/');
    const url = `{{baseUrl}}/${urlPath}${qs ? `?${qs}` : ''}`;

    const media = op.requestBody?.content?.['application/json'];
    const example = media?.example ?? media?.schema?.example;

    const json = {
      meta: { name, type: 'http', seq: String(nextSeq(dir)) },
      http: { method, url, body: example !== undefined ? 'json' : 'none', auth: 'none' },
    };
    const params = [
      ...query.map((p) => ({ name: p.name, value: String(p.schema.default), enabled: true, type: 'query' })),
      ...segs.filter(isParam).map((s) => ({ name: s.slice(1, -1), value: '', enabled: true, type: 'path' })),
    ];
    if (params.length) json.params = params;
    if (example !== undefined) json.body = { json: JSON.stringify(example, null, 2) };
    const docs = [op.summary, op.description?.trim()].filter(Boolean).join('\n\n').trim();
    if (docs) json.docs = docs;

    mkdirSync(dir, { recursive: true });
    writeFileSync(file, jsonToBruV2(json));
    created.push(relative(root, file));
  }
}

console.log(`created ${created.length}: ${created.join(', ') || '-'}`);
console.log(`skipped ${skipped.length} (already exist${force ? '' : '; --force overwrites'}): ${skipped.join(', ') || '-'}`);
