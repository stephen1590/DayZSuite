#requires -Version 7
<#
.SYNOPSIS
  S1 - capture TODAY's effective config access map from PROD into a committed CSV baseline.

.DESCRIPTION
  WS-S requirement 3 (owner): "reconfigure the application to be equivalent to today's
  access map". This writes down what "today" IS, file by file, so S3 can be asserted
  against it instead of argued about.

  READ-ONLY against the box: it reads the rendered dayz-ctl masks, lists files, and calls
  `own-read` on a SAMPLE (a read verb) to prove the model matches reality. It never writes
  to the server. The only thing it writes is the CSV baseline + its CSV log.

  The model lives in AccessBaseline.ps1 and is a re-implementation of the box's rules, so
  the spot-check is not optional decoration - it is the evidence the baseline is true.
  Any mismatch is reported and sets a non-zero exit: a wrong baseline would make the whole
  WS-S migration unreviewable.

.EXAMPLE
  ./Capture-AccessBaseline.ps1                       # capture from prod, spot-check 14 files
  ./Capture-AccessBaseline.ps1 -SampleSize 40        # wider proof, slower (1 ssh per file)
#>
[CmdletBinding()]
param(
    [string]$Target     = 'ubuntu@cytonicmushroom.ddns.net',
    [string]$RemotePath = '~/servers/dayz-server',
    [string]$OutFile,
    [int]$SampleSize    = 14,
    [switch]$NoLog
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AccessBaseline.ps1')
if (-not $OutFile) { $OutFile = Join-Path $PSScriptRoot '../Scale-Ready/access-baseline.csv' }

function Remote([string]$cmd) { ssh -o ConnectTimeout=10 $Target $cmd }

Write-Host "--- S1: capturing today's access map from $Target ---" -ForegroundColor Cyan

# 1. the rendered masks, straight out of the deployed control plane
$maskRaw = Remote @'
python3 - <<'PY'
import re, json
src = open('/usr/local/bin/dayz-ctl').read()
out = {}
for var in ('OWNED_FILES','OWNED_DIRS','GENERATED','DISABLED_TARGETS'):
    m = re.search(r"^" + var + r"='([^']*)'", src, re.M)
    out[var] = [x for x in (m.group(1).split() if m else []) if x]
print(json.dumps(out))
PY
'@
$masksBox = $maskRaw | ConvertFrom-Json

# 2. every candidate config file on the box (same exclusions the WS-S sizing used)
$fileRaw = Remote "find $RemotePath -maxdepth 6 \( -name '@*' -o -name '.*' -o -name 'deploy-stage' -o -name 'storage_*' \) -prune -o -type f \( -name '*.json' -o -name '*.xml' \) -printf '%P\n'"
$files = @($fileRaw -split "`n" | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() } | Sort-Object)
Write-Host "  files on box: $($files.Count)"

$masks = @{
    OwnedFiles = @($masksBox.OWNED_FILES)
    OwnedDirs  = @($masksBox.OWNED_DIRS)
    Generated  = @($masksBox.GENERATED)
    Disabled   = @($masksBox.DISABLED_TARGETS)
    OnDisk     = $files
}
Write-Host "  masks: OWNED_FILES $($masks.OwnedFiles.Count)  OWNED_DIRS $($masks.OwnedDirs.Count)  GENERATED $($masks.Generated.Count)  DISABLED $($masks.Disabled.Count)"

$registry = @((Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'config-registry.json') | ConvertFrom-Json).surfaces)

# 3. resolve every file
$rows = foreach ($f in $files) {
    $a = Get-TodayAccess -RelPath $f -Masks $masks -Registry $registry
    [pscustomobject]@{
        relpath = $a.RelPath; listed = $a.Listed; writable = $a.Writable
        mirrored = $a.Mirrored; generated = $a.Generated; disabled = $a.Disabled
        isDefault = ($f -match '\.defaults\.[^.]+$')
    }
}
$rows | Export-Csv -NoTypeInformation -Path $OutFile
Write-Host "  wrote $OutFile ($($rows.Count) rows)"

$sum = [ordered]@{
    listed    = @($rows | Where-Object listed).Count
    writable  = @($rows | Where-Object writable).Count
    mirrored  = @($rows | Where-Object mirrored).Count
    invisible = @($rows | Where-Object { -not $_.listed -and -not $_.writable }).Count
    defaults  = @($rows | Where-Object isDefault).Count
}
Write-Host "  listed=$($sum.listed)  writable=$($sum.writable)  mirrored=$($sum.mirrored)  INVISIBLE=$($sum.invisible)  (.defaults files: $($sum.defaults))"

# 4. PROVE the model matches the box. own-read shares _own_check with own-write, so a
#    success/refusal here is exactly the gate the model claims to reproduce.
Write-Host "`n--- spot-check: model vs real dayz-ctl own-read (sample $SampleSize) ---" -ForegroundColor Cyan
$wr  = @($rows | Where-Object writable)
$nwr = @($rows | Where-Object { -not $_.writable })
$half = [Math]::Max(1, [int]($SampleSize / 2))
# Deterministic spread, not random: evenly-spaced picks so a re-run samples the same files.
function Spread($set, $n) {
    if ($set.Count -le $n) { return $set }
    $step = [Math]::Floor($set.Count / $n)
    return @(0..($n - 1) | ForEach-Object { $set[$_ * $step] })
}
$sample = @(Spread $wr $half) + @(Spread $nwr ($SampleSize - $half))
$mismatch = 0
foreach ($r in $sample) {
    $rc = (Remote "sudo -n dayz-ctl own-read '$($r.relpath)' >/dev/null 2>&1; echo `$?").Trim()
    $boxWritable = ($rc -eq '0')
    $agree = ($boxWritable -eq $r.writable)
    if (-not $agree) { $mismatch++ }
    $tag = if ($agree) { 'ok  ' } else { 'MISMATCH' }
    Write-Host ("  {0} model={1,-5} box={2,-5} {3}" -f $tag, $r.writable, $boxWritable, $r.relpath)
}

if (-not $NoLog) {
    $logDir = Join-Path $PSScriptRoot 'logs'
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    [pscustomobject]@{
        timestamp = $stamp; files = $rows.Count; listed = $sum.listed; writable = $sum.writable
        mirrored = $sum.mirrored; invisible = $sum.invisible; sampled = $sample.Count; mismatches = $mismatch
    } | Export-Csv -Append -Path (Join-Path $logDir 'access-baseline.csv') -NoTypeInformation
}

if ($mismatch) {
    Write-Host "`nS1: $mismatch of $($sample.Count) sampled files DISAGREE with the box - the baseline is not trustworthy." -ForegroundColor Red
    exit 1
}
Write-Host "`nS1: baseline captured; model agreed with the box on all $($sample.Count) sampled files." -ForegroundColor Green
exit 0
