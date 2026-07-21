#!/bin/bash
# ============================================================================
# sync-shortcodes.sh — pull shortcodes (and their dependencies) from AFID so
# the two sites stay in sync.
#
# Read-only by default: prints the diff of what WOULD change. Pass --apply to
# actually copy. Every run is logged (CSV, timestamped) to ./logs/ unless
# --no-log is given.
#
#   ./sync-shortcodes.sh            # report only — show what would change
#   ./sync-shortcodes.sh --apply    # perform the sync
#   ./sync-shortcodes.sh --apply --no-log
#
# Source of truth is AFID. This copies FROM AFID INTO this site; it never
# writes back to AFID.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="${AFID_DIR:-$SCRIPT_DIR/../../AFID}"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/shortcode-sync.csv"

APPLY=false
LOG=true
for arg in "$@"; do
  case "$arg" in
    --apply)  APPLY=true ;;
    --no-log) LOG=false ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [[ ! -d "$SRC" ]]; then
  echo "ERROR: AFID source not found at: $SRC" >&2
  echo "Set AFID_DIR=/path/to/AFID to override." >&2
  exit 1
fi
SRC="$(cd "$SRC" && pwd)"

# What to sync: "relative/source/path -> relative/dest/path".
# Shortcodes need link.html (partial) and the shortcode/block CSS to work,
# so those travel with them.
MAPPINGS=(
  "layouts/shortcodes/                 layouts/shortcodes/"
  "layouts/_partials/link.html         layouts/_partials/link.html"
  "assets/css/extended/shortcodes.css  assets/css/extended/shortcodes.css"
  "assets/css/extended/blocks.css      assets/css/extended/blocks.css"
)

if ! command -v rsync >/dev/null 2>&1; then
  echo "ERROR: rsync is required." >&2
  exit 1
fi

$APPLY && echo "== SYNC (apply) ==" || echo "== SYNC (report only — use --apply to copy) =="
echo "Source: $SRC"
echo "Dest:   $SCRIPT_DIR"
echo

RSYNC_FLAGS=(-rci --checksum)          # -i itemize, -c checksum (ignore mtime)
$APPLY || RSYNC_FLAGS+=(--dry-run)

changed_total=0
declare -a CHANGED_ROWS=()

for m in "${MAPPINGS[@]}"; do
  read -r rel_src rel_dst <<< "$m"
  src_path="$SRC/$rel_src"
  dst_path="$SCRIPT_DIR/$rel_dst"

  if [[ ! -e "$src_path" ]]; then
    echo "  SKIP (missing in AFID): $rel_src"
    continue
  fi

  # Ensure dest parent exists (only when applying).
  $APPLY && mkdir -p "$(dirname "$dst_path")"

  # rsync itemized output: lines starting with '>' or 'c' are transfers/changes.
  out="$(rsync "${RSYNC_FLAGS[@]}" "$src_path" "$dst_path" 2>/dev/null || true)"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    echo "  $line"
    # itemize codes begin with a change flag block; count real file changes
    if [[ "$line" =~ ^(\>|c|\<) ]]; then
      changed_total=$((changed_total + 1))
      fname="${line##* }"
      CHANGED_ROWS+=("$rel_src|$fname")
    fi
  done <<< "$out"
done

echo
if [[ $changed_total -eq 0 ]]; then
  echo "In sync — nothing to do."
else
  $APPLY \
    && echo "Synced $changed_total file(s) from AFID." \
    || echo "$changed_total file(s) differ. Re-run with --apply to sync."
fi

# --- CSV log (append, timestamped) ---------------------------------------
if $LOG; then
  mkdir -p "$LOG_DIR"
  [[ -f "$LOG_FILE" ]] || echo "timestamp,mode,changed,file" > "$LOG_FILE"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mode=$($APPLY && echo apply || echo report)
  if [[ ${#CHANGED_ROWS[@]} -eq 0 ]]; then
    echo "$ts,$mode,0," >> "$LOG_FILE"
  else
    for row in "${CHANGED_ROWS[@]}"; do
      echo "$ts,$mode,1,\"${row//\"/\"\"}\"" >> "$LOG_FILE"
    done
  fi
fi
