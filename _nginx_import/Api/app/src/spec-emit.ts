// Emit the generated OpenAPI spec to ../openapi.json — the artifact the Bruno generator
// reads. Run: `npm run spec`. Pure (no server): builds the registry with a stub bridge,
// since only the static per-action schemas are needed to shape the doc.
import { writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { buildActions } from './actions.js';
import { buildSpec } from './spec.js';

const spec = buildSpec(buildActions({} as never, 0, {} as never));
const out = join(dirname(fileURLToPath(import.meta.url)), '../../openapi.json');
writeFileSync(out, JSON.stringify(spec, null, 2) + '\n');
console.log(`wrote ${out} — ${Object.keys((spec as { paths: Record<string, unknown> }).paths).length} paths`);
