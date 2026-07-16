// The OpenAPI spec, GENERATED from the live action registry + a root-route manifest,
// so it cannot structurally drift from the code: add/rename/remove an action or a root
// route and the spec follows automatically. buildSpec() is PURE (no running server) —
// server.ts serves it at GET /openapi.json, `npm run spec` writes it out for Bruno, and
// the dev-mode response check (see validateResponse) keeps the declared shapes honest.
//
// Why not @fastify/swagger route-scanning? The 10 /dayz commands share ONE dynamic
// route (POST /dayz/:action) with a common pipeline; scanning would collapse them into a
// single /dayz/{action}. The registry is the real source of that surface, so we drive
// the spec from it instead.
import type { Action } from './actions.js';

export type JSONSchema = Record<string, unknown>;

const S = {
  str: { type: 'string' } as JSONSchema,
  strNull: { type: 'string', nullable: true } as JSONSchema,
  int: { type: 'integer' } as JSONSchema,
  intNull: { type: 'integer', nullable: true } as JSONSchema,
  num: { type: 'number' } as JSONSchema,
  bool: { type: 'boolean' } as JSONSchema,
  obj: (properties: Record<string, JSONSchema>, required?: string[]): JSONSchema => ({
    type: 'object',
    properties,
    ...(required && required.length ? { required } : {}),
  }),
  arr: (items: JSONSchema): JSONSchema => ({ type: 'array', items }),
};

// --- reusable component schemas ---------------------------------------------------
const Player: JSONSchema = S.obj({
  num: S.int, name: S.str, guid: S.str, verified: S.bool,
  ip: S.str, port: S.int, ping: S.intNull, inLobby: S.bool,
});
const Mod: JSONSchema = S.obj({ folder: S.str, name: S.str });

// --- root-route manifest (everything that is NOT a /dayz action) ------------------
// Declared here beside the generator; the dev response check validates handler output
// against these, so a drifted root route trips in dev before it can ship a lie.
export interface RootRoute {
  method: 'get' | 'post';
  path: string;         // OpenAPI path (path params as {name})
  summary: string;
  auth?: boolean;       // requires an HMAC signature (X-Key-Id + X-Signature-256)
  wizardOnly?: boolean; // master secret only — no X-Key-Id
  tokenInPath?: string; // a secret carried in the URL path (documents the {param})
  body?: JSONSchema;
  noContent?: boolean;  // 204 (no body) on success
  response?: JSONSchema; // the 200 body (omit when noContent)
}

const keyShape = S.obj({ id: S.str, scope: S.str, namespaces: S.arr(S.str) });

export const ROOT_ROUTES: RootRoute[] = [
  { method: 'get', path: '/', summary: 'API index: every endpoint + the dayz action allowlist (public).',
    response: S.obj({ service: S.str, namespaces: S.arr(S.str), endpoints: S.arr(S.obj({ method: S.str, path: S.str })), actions: S.obj({}) }) },
  { method: 'get', path: '/openapi.json', summary: 'This OpenAPI document (generated from the code).', response: S.obj({}) },
  { method: 'get', path: '/healthz', summary: 'Liveness probe (public).', response: S.obj({ ok: S.bool }) },
  { method: 'get', path: '/dayz/actions', summary: 'The dayz action allowlist with destructive/describe flags (public).',
    response: S.obj({ actions: S.obj({}) }) },
  { method: 'post', path: '/sysload', summary: 'Host load overview (cpu/mem/disk/uptime) + the dayz unit footprint.', auth: true,
    response: S.obj({
      uptimeSec: S.int,
      cpu: S.obj({ cores: S.int, load1: S.num, load5: S.num, load15: S.num, busyPct: S.num }),
      memoryMb: S.obj({ total: S.int, available: S.int, usedPct: S.num }),
      swapMb: S.obj({ total: S.int, used: S.int }),
      diskRootGb: S.obj({ total: S.num, free: S.num, usedPct: S.num }),
      dayz: { nullable: true, ...S.obj({ state: S.str, mainPid: S.intNull, memoryMb: S.num, tasks: S.int, cpuTimeSec: S.int, unitRestarts: S.int, logDirMb: S.num, persistenceMb: S.num }) },
    }) },
  { method: 'post', path: '/whoami', summary: "The caller's own authenticated identity + capability (scope, namespaces).", auth: true,
    response: S.obj({ ok: S.bool, action: S.str, identity: S.str, scope: S.str, namespaces: S.arr(S.str) }) },
  { method: 'post', path: '/keys/create', summary: 'Mint a derived API key (wizard only). Secret returned ONCE.', wizardOnly: true,
    body: S.obj({ id: S.str, scope: { type: 'string', enum: ['full', 'observe'] }, namespaces: S.arr(S.str) }, ['id']),
    response: S.obj({ ok: S.bool, id: S.str, scope: S.str, namespaces: S.arr(S.str), secret: S.str, message: S.str }) },
  { method: 'post', path: '/keys/list', summary: 'List derived keys (wizard only). Never includes secrets.', wizardOnly: true,
    response: S.obj({ ok: S.bool, keys: S.arr(keyShape) }) },
  { method: 'post', path: '/keys/update', summary: "Change a key's scope and/or namespaces (wizard only); secret unchanged.", wizardOnly: true,
    body: S.obj({ id: S.str, scope: { type: 'string', enum: ['full', 'observe'] }, namespaces: S.arr(S.str) }, ['id']),
    response: S.obj({ ok: S.bool, id: S.str, scope: S.str, namespaces: S.arr(S.str), message: S.str }) },
  { method: 'post', path: '/keys/revoke', summary: 'Revoke a derived key (wizard only).', wizardOnly: true,
    body: S.obj({ id: S.str }, ['id']),
    response: S.obj({ ok: S.bool, id: S.str, message: S.str }) },
  { method: 'post', path: '/dayz/sources/vpp/{token}',
    summary: 'VPP WebHooks event ingress (Discord-format). Auth = secret token in the URL path; opt-in rules can fire actions.',
    tokenInPath: 'token', noContent: true,
    body: S.obj({ content: S.str, embeds: S.arr(S.obj({ title: S.str, description: S.str })) }) },
];

// --- the /dayz action response envelope: { ok, action, ...result } ----------------
function envelope(resultSchema: JSONSchema | undefined): JSONSchema {
  const props: Record<string, JSONSchema> = { ok: S.bool, action: S.str };
  const rp = (resultSchema?.properties as Record<string, JSONSchema>) ?? {};
  return S.obj({ ...props, ...rp });
}

const SEC = [{ HmacSignature: [] as string[] }];

function jsonBody(schema: JSONSchema): JSONSchema {
  return { required: true, content: { 'application/json': { schema } } };
}
function jsonResp(desc: string, schema: JSONSchema): JSONSchema {
  return { description: desc, content: { 'application/json': { schema } } };
}

const ERRORS: Record<string, JSONSchema> = {
  '401': jsonResp('Missing/invalid HMAC signature.', S.obj({ ok: S.bool, error: S.str })),
  '403': jsonResp("Key lacks the namespace or scope for this action.", S.obj({ ok: S.bool, error: S.str, message: S.str })),
  '404': jsonResp('Unknown action.', S.obj({ ok: S.bool, error: S.str, message: S.str })),
  '409': jsonResp('Player guard / cooldown blocked the action.', S.obj({ ok: S.bool, error: S.str, message: S.str })),
};

export function buildSpec(actions: Record<string, Action>): JSONSchema {
  const paths: Record<string, JSONSchema> = {};

  // /dayz/<action> — one path per registry entry.
  for (const [name, a] of Object.entries(actions)) {
    const sc = a.schema;
    const op: JSONSchema = {
      summary: sc?.summary ?? a.describe,
      operationId: `dayz_${name.replace(/\//g, '_')}`,
      tags: ['dayz'],
      security: SEC,
      responses: {
        '200': jsonResp(`${name} result`, envelope(sc?.response)),
        ...ERRORS,
      },
      ...(a.destructive ? { 'x-destructive': true } : {}),
      ...(a.readOnly ? { 'x-read-only': true } : {}),
    };
    if (sc?.body) op.requestBody = jsonBody(sc.body);
    if (sc?.query) {
      op.parameters = Object.entries((sc.query.properties as Record<string, JSONSchema>) ?? {}).map(([pn, ps]) => ({
        name: pn, in: 'query', required: ((sc.query!.required as string[]) ?? []).includes(pn), schema: ps,
      }));
    }
    paths[`/dayz/${name}`] = { post: op };
  }

  // Root routes.
  for (const r of ROOT_ROUTES) {
    const responses: Record<string, JSONSchema> = r.noContent
      ? { '204': { description: 'accepted' }, '404': { description: 'disabled or bad token' } }
      : { '200': jsonResp('OK', r.response ?? S.obj({})), ...(r.auth || r.wizardOnly ? { '401': ERRORS['401'] } : {}) };
    const op: JSONSchema = {
      summary: r.summary,
      operationId: (r.method + r.path).replace(/[^a-zA-Z0-9]+/g, '_').replace(/_+$/, ''),
      ...(r.auth || r.wizardOnly ? { security: SEC } : {}),
      responses,
    };
    if (r.tokenInPath) op.parameters = [{ name: r.tokenInPath, in: 'path', required: true, schema: S.str, description: 'secret token (treat the URL like a password)' }];
    if (r.body) op.requestBody = jsonBody(r.body);
    paths[r.path] = { ...(paths[r.path] as JSONSchema | undefined), [r.method]: op };
  }

  return {
    openapi: '3.0.3',
    info: {
      title: 'servermander-api',
      version: '2.0.0',
      description: 'Control-plane API for the box (DayZ first). GENERATED from the code — do not hand-edit.',
    },
    // Servers for DIRECT callers (Bruno/curl). The Config Viewer ignores these — its
    // Swagger interceptor forces every call onto its same-origin /api proxy.
    servers: [
      { url: 'https://api.cytonicmushroom.ddns.net', description: 'production (nginx TLS -> localhost Node)' },
      { url: 'http://127.0.0.1:3100', description: 'on-box direct (bypasses nginx)' },
    ],
    tags: [{ name: 'dayz', description: 'DayZ server actions (HMAC-signed).' }],
    components: {
      securitySchemes: {
        HmacSignature: {
          type: 'apiKey', in: 'header', name: 'X-Signature-256',
          description: '`sha256=<hex>` = HMAC-SHA256 over the exact raw request body. Pair with X-Key-Id for a derived key (omit for the master secret).',
        },
      },
      schemas: { Player, Mod },
    },
    paths,
  };
}

// --- dev-mode response check ------------------------------------------------------
// Not a full JSON-schema validator — a cheap "does the handler still return the keys
// the spec promises?" guard. Dev-only (cfg gate in the caller): logs a loud warning on
// a missing/extra top-level key so declared shapes can't silently drift from reality.
export function responseDrift(schema: JSONSchema | undefined, data: unknown): string[] {
  if (!schema || typeof data !== 'object' || data === null) return [];
  const props = (schema.properties as Record<string, JSONSchema>) ?? {};
  const declared = new Set(Object.keys(props));
  const actual = new Set(Object.keys(data as Record<string, unknown>));
  const drift: string[] = [];
  for (const k of declared) if (!actual.has(k)) drift.push(`missing '${k}'`);
  for (const k of actual) if (!declared.has(k)) drift.push(`undeclared '${k}'`);
  return drift;
}
