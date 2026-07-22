#requires -Version 7
<#
.SYNOPSIS
  Render serverDZ.cfg from its template + host.env secrets + the web-editable toggles,
  every prestart.

.DESCRIPTION
  serverDZ.cfg used to be deploy-rendered CODE: changing maxPlayers or the day/night cycle
  meant a repo edit and a redeploy, which is the one config surface the web editor could not
  reach. It is now a prestart ARTIFACT, built from three inputs:

    serverDZ.cfg.template   CODE, ships on drift. Holds every field, its comment, and its
                            default. The two passwords appear only as {{...}} placeholders.
    host.env                HOST-LOCAL secrets. DEPLOY_SERVER_PASSWORD / DEPLOY_ADMIN_PASSWORD
                            are read here and never leave the box - they are not in the repo,
                            not in the deploy payload, and never in the web editor.
    server-settings.json    BOX-OWNED config content, web:'patch' in config-registry.json.
                            The web editor writes it; this script folds it into the template.

  CLOSED ALLOWLIST: only the keys in $ALLOWED below may be set from server-settings.json.
  Anything else in that file is ignored with a warning, so a hand-added key can never reach
  serverDZ.cfg. Everything unlisted stays template-owned on purpose - instanceId/shardId
  select the persistence folder (a change reads as a wipe), verifySignatures is a security
  control, and the active map comes from map.env, not the Missions class.

  FAIL-SOFT PER FIELD, ATOMIC PER FILE: a value of the wrong type, out of range, or naming a
  key the template does not contain is skipped with a warning and the template default stands -
  one bad toggle never costs the others. But the FILE is written only if it renders whole: a
  missing host.env, an unresolved {{placeholder}}, or an unreadable template aborts the write
  and leaves the previous serverDZ.cfg in place. The server never boots with a literal
  placeholder as its password.

  Report-only by default (prints what WOULD change); -Fix writes. Run by prestart.sh AFTER
  Apply-ConfigOverrides (so a web patch to server-settings.json is already applied), wrapped
  in `|| true` so it can NEVER block boot. Values are never echoed - only key names.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ServerDir,
    [Alias('Apply')][switch]$Fix
)

$ErrorActionPreference = 'Stop'

function Show-Info($m) { Write-Host $m }
function Show-Warn($m) { Write-Host "[WARN] $m" -ForegroundColor Yellow }

# --- The closed allowlist: cfg key -> how a value from server-settings.json is validated ----
# kind: 'string' = quoted in the cfg;  'int'/'num' = written bare.
# The 14 keys the owner chose to expose. Adding one here is deliberate - read the
# "everything unlisted stays template-owned" note above before you do.
$ALLOWED = [ordered]@{
    hostname                    = @{ kind = 'string'; max = 63 }
    description                 = @{ kind = 'string'; max = 255 }
    maxPlayers                  = @{ kind = 'int';    min = 1;   max = 127 }
    enableWhitelist             = @{ kind = 'int';    min = 0;   max = 1 }
    forceSameBuild              = @{ kind = 'int';    min = 0;   max = 1 }
    disableVoN                  = @{ kind = 'int';    min = 0;   max = 1 }
    vonCodecQuality             = @{ kind = 'int';    min = 0;   max = 30 }
    disable3rdPerson            = @{ kind = 'int';    min = 0;   max = 1 }
    disableCrosshair            = @{ kind = 'int';    min = 0;   max = 1 }
    disablePersonalLight        = @{ kind = 'int';    min = 0;   max = 1 }
    lightingConfig              = @{ kind = 'int';    min = 0;   max = 1 }
    serverTimeAcceleration      = @{ kind = 'num';    min = 0.1; max = 24 }
    serverNightTimeAcceleration = @{ kind = 'num';    min = 0.1; max = 64 }
    serverTimePersistent        = @{ kind = 'int';    min = 0;   max = 1 }
}

$templatePath = Join-Path $ServerDir 'serverDZ.cfg.template'
$settingsPath = Join-Path $ServerDir 'server-settings.json'
$hostEnvPath  = Join-Path $ServerDir 'host.env'
$outPath      = Join-Path $ServerDir 'serverDZ.cfg'

if (-not (Test-Path $templatePath)) { Show-Warn "no serverDZ.cfg.template under $ServerDir - leaving serverDZ.cfg untouched."; return }
try { $text = [IO.File]::ReadAllText($templatePath) }
catch { Show-Warn "serverDZ.cfg.template is unreadable - leaving serverDZ.cfg untouched ($($_.Exception.Message))."; return }

# --- 1. secrets from host.env (host-local, never echoed) -------------------------------------
$secrets = @{}
if (Test-Path $hostEnvPath) {
    foreach ($line in (Get-Content -LiteralPath $hostEnvPath)) {
        if ($line -match '^\s*(DEPLOY_SERVER_PASSWORD|DEPLOY_ADMIN_PASSWORD)\s*=\s*(.+?)\s*$') { $secrets[$Matches[1]] = $Matches[2] }
    }
}
foreach ($k in 'DEPLOY_SERVER_PASSWORD', 'DEPLOY_ADMIN_PASSWORD') {
    if (-not $secrets[$k]) { Show-Warn "$k not set in host.env - REFUSING to render serverDZ.cfg (a placeholder must never become the live password). Existing file left as-is."; return }
    $text = $text.Replace("{{$k}}", $secrets[$k])
}

# --- 2. web-editable toggles ------------------------------------------------------------------
$settings = $null
if (Test-Path $settingsPath) {
    try { $settings = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json }
    catch { Show-Warn "server-settings.json is not valid JSON - ignoring it, template defaults stand ($($_.Exception.Message))." }
} else {
    Show-Warn "no server-settings.json under $ServerDir - template defaults stand."
}

$applied = @(); $skipped = @()
if ($settings) {
    foreach ($prop in $settings.PSObject.Properties) {
        $key = $prop.Name
        if ($key.StartsWith('_')) { continue }                       # _readme and friends
        if (-not $ALLOWED.Contains($key)) { $skipped += $key; Show-Warn "'$key' is not an allowlisted serverDZ.cfg toggle - ignored."; continue }

        $rule = $ALLOWED[$key]
        $val  = $prop.Value
        $lit  = $null

        if ($rule.kind -eq 'string') {
            if ($val -isnot [string]) { $skipped += $key; Show-Warn "'$key' must be a string - skipped, template default stands."; continue }
            if ($val -match '["\r\n]') { $skipped += $key; Show-Warn "'$key' must not contain a double quote or newline - skipped, template default stands."; continue }
            if ($val.Length -gt $rule.max) { $skipped += $key; Show-Warn "'$key' is longer than $($rule.max) characters - skipped, template default stands."; continue }
            $lit = '"' + $val + '"'
        } else {
            $num = 0.0
            if (-not [double]::TryParse([string]$val, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$num)) {
                $skipped += $key; Show-Warn "'$key' must be a number - skipped, template default stands."; continue
            }
            if ($num -lt $rule.min -or $num -gt $rule.max) { $skipped += $key; Show-Warn "'$key' is outside $($rule.min)-$($rule.max) - skipped, template default stands."; continue }
            if ($rule.kind -eq 'int') {
                if ($num -ne [math]::Floor($num)) { $skipped += $key; Show-Warn "'$key' must be a whole number - skipped, template default stands."; continue }
                $lit = [string][int]$num
            } else {
                # Invariant formatting so 4.5 never renders as 4,5 on a comma-decimal host.
                $lit = $num.ToString([Globalization.CultureInfo]::InvariantCulture)
            }
        }

        # Rewrite the value in place, preserving the template's spacing and trailing comment.
        # The template's own line is the only place a key may be defined, so a key the template
        # does not carry is a typo, not a new field - we warn instead of appending it blind.
        $pattern = '(?m)^(\s*' + [regex]::Escape($key) + '\s*=\s*)(.*?)(\s*;)'
        if ($text -notmatch $pattern) { $skipped += $key; Show-Warn "'$key' is not present in serverDZ.cfg.template - skipped (template out of sync?)."; continue }
        $text = [regex]::Replace($text, $pattern, { param($m) $m.Groups[1].Value + $lit + $m.Groups[3].Value }, 1)
        $applied += $key
    }
}

# --- 3. never write a half-rendered or unbootable cfg ------------------------------------------
if ($text -match '\{\{[A-Za-z0-9_]+\}\}') {
    $left = ([regex]::Matches($text, '\{\{([A-Za-z0-9_]+)\}\}') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique) -join ', '
    Show-Warn "serverDZ.cfg.template still has unresolved placeholder(s): $left - REFUSING to write. Existing serverDZ.cfg left as-is."
    return
}
# MAP SELECTION IS NOT OURS: the active map comes from map.env -> the unit's -mission=. But the
# engine still needs a `class Missions { class DayZ { template=...; } }` block to PRESENT to run
# a mission at all (-mission= alone loads the world and leaves no mission running; see
# Generate-ConfigDefaults.ps1). Its template VALUE is overridden by -mission= and is deliberately
# not in the allowlist - the block just has to survive rendering. If it doesn't, refuse.
if ($text -notmatch '(?s)class\s+Missions\s*\{.*?class\s+\w+\s*\{.*?template\s*=') {
    Show-Warn "rendered serverDZ.cfg has no 'class Missions { class DayZ { template=...' block - REFUSING to write (the engine needs it to run a mission). Existing serverDZ.cfg left as-is."
    return
}

$state = if (-not (Test-Path $outPath)) { 'Missing' }
         elseif ([IO.File]::ReadAllText($outPath) -eq $text) { 'InSync' }
         else { 'Drift' }

Show-Info ("ServerCfg: {0} toggle(s) applied, {1} skipped, serverDZ.cfg {2}{3}." -f $applied.Count, $skipped.Count, $state, $(if (-not $Fix) { ' (report-only)' }))
if ($applied.Count) { Show-Info "ServerCfg: set $($applied -join ', ')." }
if (-not $Fix -or $state -eq 'InSync') { return }

[IO.File]::WriteAllText($outPath, $text)
# The rendered file carries both passwords - keep it owner-only, like the deploy left it.
if ($IsLinux -or $IsMacOS) { chmod 600 $outPath }
Show-Info "ServerCfg: serverDZ.cfg written."
