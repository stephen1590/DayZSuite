#requires -Version 7
<#
.SYNOPSIS
  Apply the COMMON custom Central Economy types file to the active mission, update-safe.

.DESCRIPTION
  DayZ only loads extra CE types when a <ce folder="..."> block in the mission's
  cfgeconomycore.xml registers them - you cannot just append to the vanilla db/types.xml
  (a game/mod update rewrites it and your additions vanish). So we keep ONE map-agnostic
  custom types file (custom-ce/custom_types.xml) and, at prestart, apply it to whatever
  mission is active:

    1. copy  custom-ce/custom_types.xml  ->  mpmissions/<mission>/custom/custom_types.xml
    2. ensure that mission's cfgeconomycore.xml registers  <ce folder="custom">

  Both steps are IDEMPOTENT and NON-DESTRUCTIVE: the vanilla db/types.xml is never touched,
  the registration is injected ONLY when missing (so a vanilla rewrite re-adds it next boot),
  and any other <ce> blocks are left alone. Add modded item types to custom_types.xml and
  they spawn on every live map.

  Read-only by default (reports what it WOULD do). -Fix performs the copy + inject. Run by
  prestart.sh with the active mission, wrapped in `|| true` so it can NEVER block server boot.
  A malformed custom_types.xml is reported and skipped, never shipped into the mission.
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

$CE_FOLDER = 'custom'                 # folder registered in cfgeconomycore, relative to the mission root
$CE_FILE   = 'custom_types.xml'

$src        = Join-Path $ServerDir "custom-ce/$CE_FILE"
$missionDir = Join-Path $ServerDir "mpmissions/$Mission"
$corePath   = Join-Path $missionDir 'cfgeconomycore.xml'
$destDir    = Join-Path $missionDir $CE_FOLDER
$destFile   = Join-Path $destDir $CE_FILE

if (-not (Test-Path $src))        { Show-Warn "no custom-ce/$CE_FILE under $ServerDir - nothing to apply."; return }
if (-not (Test-Path $missionDir)) { Show-Warn "mission dir not found: mpmissions/$Mission - skipped."; return }
if (-not (Test-Path $corePath))   { Show-Warn "no cfgeconomycore.xml for '$Mission' - cannot register custom types; skipped."; return }

# Refuse to ship a malformed types file (a bad db read breaks the whole economy). Parse first.
$typeCount = $null
try { $typeCount = @(([xml](Get-Content -Raw -LiteralPath $src)).types.type).Count }
catch { Show-Warn "custom-ce/$CE_FILE is not valid <types> XML - skipped ($($_.Exception.Message))."; return }

# --- 1. custom types file -> mpmissions/<mission>/custom/ ---
Show-Info "CustomCE[$Mission]: $typeCount custom type(s) from custom-ce/$CE_FILE -> $CE_FOLDER/$CE_FILE$(if (-not $Fix) { ' (report-only)' })."
if ($Fix) {
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    Copy-Item -LiteralPath $src -Destination $destFile -Force
}

# --- 2. register <ce folder="custom"> in cfgeconomycore.xml, only if missing ---
$core = Get-Content -Raw -LiteralPath $corePath
if ($core -match ('folder\s*=\s*"' + [regex]::Escape($CE_FOLDER) + '"')) {
    Show-Info "CustomCE[$Mission]: cfgeconomycore.xml already registers folder='$CE_FOLDER' - no change."
    return
}
Show-Info "CustomCE[$Mission]: registering <ce folder='$CE_FOLDER'> in cfgeconomycore.xml$(if (-not $Fix) { ' (report-only)' })."
if (-not $Fix) { return }

if ($core -notmatch '</economycore>') { Show-Warn "cfgeconomycore.xml has no </economycore> close tag - refusing to edit."; return }
$block   = "`t<ce folder=`"$CE_FOLDER`">`r`n`t`t<file name=`"$CE_FILE`" type=`"types`" />`r`n`t</ce>`r`n"
$patched = $core.Replace('</economycore>', $block + '</economycore>')
try { [xml]$patched | Out-Null }            # never write XML we just broke
catch { Show-Warn "patched cfgeconomycore.xml would be invalid XML - refusing to write ($($_.Exception.Message))."; return }
Set-Content -LiteralPath $corePath -Value $patched -Encoding utf8 -NoNewline
Show-Info "CustomCE[$Mission]: cfgeconomycore.xml updated."
