#requires -Version 7
<#
.SYNOPSIS
  Register extra Central Economy types files on the active mission, update-safe.

.DESCRIPTION
  DayZ only loads extra CE types when a <ce folder="..."> block in the mission's
  cfgeconomycore.xml registers them - you cannot append to vanilla db/types.xml (a game
  update rewrites it). This reads custom-ce/custom-ce.json (a list of types files), and at
  prestart, for the active mission:

    1. copy each listed 'from' file  ->  mpmissions/<mission>/custom/<name>
    2. regenerate ONE <ce folder="custom"> block in that mission's cfgeconomycore.xml
       listing every file that copied successfully

  'from' is relative to the server dir: custom-ce/<file> for our own repo-authored types
  (e.g. custom_types.xml = CodeLock), or a mod's own doc file (e.g. @aibandits/doc/
  bandit_types.xml) so it tracks the INSTALLED mod version instead of a hand-duplicated copy.
  A map-tuned variant at custom-ce/maps/<mission>/<name> beats 'from' for that mission.

  IDEMPOTENT and NON-DESTRUCTIVE: vanilla db/types.xml is never touched; the block is
  REGENERATED each run (so adding/removing a manifest line just works, and a vanilla rewrite
  re-adds it next boot); other <ce> blocks are left alone. Read-only by default (reports what
  it WOULD do); -Fix performs the copies + edit. Run by prestart.sh with the active mission,
  wrapped in `|| true` so it can NEVER block boot. A missing/invalid source is skipped
  fail-soft, never shipped into the mission.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ServerDir,
    [string]$Mission,
    [Alias('Apply')][switch]$Fix
)

$ErrorActionPreference = 'Stop'

function Show-Info($m) { Write-Host $m }
function Show-Warn($m) { Write-Host "[WARN] $m" -ForegroundColor Yellow }

# Resolve the active mission the same way the engine does (map.env), unless one was passed.
if (-not $Mission) {
    $mapEnv = Join-Path $ServerDir 'map.env'
    if (Test-Path $mapEnv) {
        $m = Select-String -LiteralPath $mapEnv -Pattern '^\s*DAYZ_MISSION=(.+)$' | Select-Object -First 1
        if ($m) { $Mission = $m.Matches[0].Groups[1].Value.Trim() }
    }
    if (-not $Mission) { $Mission = 'dayzOffline.chernarusplus' }
}

$CE_FOLDER    = 'custom'                 # folder registered in cfgeconomycore, relative to the mission root
$manifestPath = Join-Path $ServerDir 'custom-ce/custom-ce.json'
$missionDir   = Join-Path $ServerDir "mpmissions/$Mission"
$corePath     = Join-Path $missionDir 'cfgeconomycore.xml'
$destDir      = Join-Path $missionDir $CE_FOLDER

if (-not (Test-Path $manifestPath)) { Show-Warn "no custom-ce/custom-ce.json under $ServerDir - nothing to register."; return }
if (-not (Test-Path $missionDir))   { Show-Warn "mission dir not found: mpmissions/$Mission - skipped."; return }
if (-not (Test-Path $corePath))     { Show-Warn "no cfgeconomycore.xml for '$Mission' - cannot register custom types; skipped."; return }

try { $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json }
catch { Show-Warn "custom-ce.json is not valid JSON - skipped ($($_.Exception.Message))."; return }
$entries = @($manifest.files)
if (-not $entries.Count) { Show-Warn "custom-ce.json lists no files - nothing to register."; return }

# --- 1. copy each source into mpmissions/<mission>/custom/, collecting the ones that stick ---
$registered = @()
foreach ($e in $entries) {
    $name = [string]$e.name
    $type = if ($e.type) { [string]$e.type } else { 'types' }
    if (-not $name -or -not $e.from) { Show-Warn "manifest entry missing name/from - skipped."; continue }
    # "disabled": true keeps the entry documented but OUT of the CE - a mod's types file must be
    # dropped from registration when its mod is turned off in mods.conf, or the CE loads types for
    # classes the engine no longer has and the server SEGV-crashes on boot (bandit_types.xml when
    # @aibandits is disabled). Disable, don't delete: flip it back when the mod returns.
    if ($e.disabled) { Show-Info "CustomCE[$Mission]: '$name' disabled in manifest - skipped."; continue }
    # A map-tuned variant at custom-ce/maps/<mission>/<name> beats the shared 'from' for that
    # mission (e.g. Enoch defines no Tier4 - its expansion_types re-tiers those entries).
    $from = [string]$e.from
    $mapFrom = "custom-ce/maps/$Mission/$name"
    if (Test-Path (Join-Path $ServerDir $mapFrom)) { $from = $mapFrom }
    $src = Join-Path $ServerDir $from
    if (-not (Test-Path $src))      { Show-Warn "source not found for '$name': $from - skipped (mod not installed?)."; continue }
    try { $doc = [xml](Get-Content -Raw -LiteralPath $src) }
    catch { Show-Warn "source for '$name' ($from) is not valid XML - skipped ($($_.Exception.Message))."; continue }
    $count = @($doc.DocumentElement.ChildNodes | Where-Object { $_.NodeType -eq 'Element' }).Count
    Show-Info "CustomCE[$Mission]: $name <- $from ($count entries, type=$type)$(if (-not $Fix) { ' (report-only)' })."
    if ($Fix) {
        New-Item -ItemType Directory -Force -Path $destDir | Out-Null
        Copy-Item -LiteralPath $src -Destination (Join-Path $destDir $name) -Force
    }
    $registered += [pscustomobject]@{ name = $name; type = $type }
}
if (-not $registered.Count) { Show-Warn "no valid types files to register for '$Mission' - leaving cfgeconomycore.xml unchanged."; return }

# --- 2. regenerate the single <ce folder="custom"> block from what copied ---
$core = Get-Content -Raw -LiteralPath $corePath
if ($core -notmatch '</economycore>') { Show-Warn "cfgeconomycore.xml has no </economycore> close tag - refusing to edit."; return }

$fileLines = ($registered | ForEach-Object { "`t`t<file name=`"$($_.name)`" type=`"$($_.type)`" />" }) -join "`r`n"
$block     = "`t<ce folder=`"$CE_FOLDER`">`r`n$fileLines`r`n`t</ce>`r`n"

# Strip any existing folder="custom" block (regenerate, so add/remove in the manifest is reflected),
# leave every other <ce> alone, then insert the fresh block right before </economycore>.
$stripped = [regex]::Replace($core, '(?s)[\t ]*<ce\s+folder="' + [regex]::Escape($CE_FOLDER) + '">.*?</ce>\s*\r?\n', '')
$patched  = $stripped.Replace('</economycore>', $block + '</economycore>')

$names = ($registered.name -join ', ')
Show-Info "CustomCE[$Mission]: cfgeconomycore.xml registers <ce folder='$CE_FOLDER'> -> [$names]$(if (-not $Fix) { ' (report-only)' })."
if (-not $Fix) { return }

try { [xml]$patched | Out-Null }             # never write XML we just broke
catch { Show-Warn "patched cfgeconomycore.xml would be invalid XML - refusing to write ($($_.Exception.Message))."; return }
Set-Content -LiteralPath $corePath -Value $patched -Encoding utf8 -NoNewline
Show-Info "CustomCE[$Mission]: cfgeconomycore.xml updated."
