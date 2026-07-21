// Audit trail. Every decision the service makes (accepted, rejected, failed) is
// recorded two ways:
//   * a structured JSON line to stdout  -> captured by journald (`journalctl -u api`)
//   * a fixed-column CSV row            -> a durable who/what/when ledger
//
// The CSV columns are FIXED (variable detail is JSON-encoded into one `detail`
// column) so the schema can never drift and appends never fail — the same lesson
// as Write-CsvLog on the PowerShell side.
import { appendFileSync, existsSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';

const COLUMNS = ['ts', 'outcome', 'action', 'ip', 'path', 'detail'] as const;

function csvCell(value: string): string {
  // Always quote; escape embedded quotes by doubling. Handles commas/newlines.
  return `"${value.replace(/"/g, '""')}"`;
}

export interface AuditContext {
  ip: string;
  url: string;
  /** Who signed the request: 'wizard' or a derived key id. Folded into the detail JSON. */
  key?: string;
}

export type Audit = (
  outcome: string,
  action: string,
  ctx: AuditContext,
  detail?: Record<string, unknown>,
) => void;

export function makeAudit(auditDir: string): Audit {
  let csvPath: string | null = null;
  try {
    mkdirSync(auditDir, { recursive: true });
    csvPath = join(auditDir, 'api.csv');
    if (!existsSync(csvPath)) {
      appendFileSync(csvPath, COLUMNS.join(',') + '\n');
    }
  } catch {
    // If the audit dir is unwritable we still log to stdout — never crash a request
    // over the ledger.
    csvPath = null;
  }

  return (outcome, action, ctx, detail = {}) => {
    const row = {
      ts: new Date().toISOString(),
      outcome,
      action,
      ip: ctx.ip,
      path: ctx.url,
      // key first so attribution survives even if an action result also has a 'key'.
      detail: JSON.stringify(ctx.key ? { key: ctx.key, ...detail } : detail),
    };
    process.stdout.write(JSON.stringify({ audit: row }) + '\n');
    if (csvPath) {
      try {
        appendFileSync(csvPath, COLUMNS.map((c) => csvCell(String(row[c]))).join(',') + '\n');
      } catch {
        /* stdout already has it */
      }
    }
  };
}
