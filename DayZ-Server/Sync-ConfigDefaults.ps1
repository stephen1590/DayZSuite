#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pull box-born <name>.defaults<ext> baselines off the box into the repo (config-defaults/)
    — the deploy's pull-before-push step for the FROZEN DEFAULTS of every owned surface.

.DESCRIPTION
    A default is BORN on the box: Capture-OwnedDefaults copies the pristine file the first
    time prestart patches it (see that script). This pulls those box-born defaults DOWN into
    config-defaults/ - a committed MIRROR (backup + fresh-box seed).

    BOX-AUTHORITATIVE (pull-only config model, 2026-07-16): the mirror FOLLOWS the box - a
    default the box re-captured (e.g. after a mod update: delete it on the box, restart,
    prestart re-freezes the current pristine file) is pulled over the repo copy, reported
    [DIFF]. The mirror is git-tracked, so history is the rollback path. The deploy ships
    the mirror back ONLY to a box that lacks a baseline (seed-if-missing / disaster
    recovery) - never over a live one. Hand-editing the mirror is a config push and gone
    from the model; make config changes in the web editor instead.

    Read-only by default (shows what pulling WOULD change); -Execute writes. A pulled default
    that is not valid for its kind (JSON/XML) is REJECTED - a corrupt baseline never enters the repo.

    Box-authoritative: the box owns the file, the repo holds a mirror. Only targets live under
    profiles/ and mpmissions/, so the box scan is scoped there (persistence trees pruned).
.EXAMPLE
    ./Sync-ConfigDefaults.ps1                 # dry-run: which box defaults the repo would capture
.EXAMPLE
    ./Sync-ConfigDefaults.ps1 -Execute        # pull the box-born defaults the repo lacks
#>
[CmdletBinding()]
param(
    [string]$RemoteHost,
    [string]$RemoteUser = "ubuntu",
    [string]$RemotePath = "/home/ubuntu/servers/dayz-server",
    [string]$MirrorDir  = (Join-Path $PSScriptRoot "config-defaults"),   # repo mirror; server-relative paths beneath
    [switch]$Execute,
    [switch]$NoLog
)

. (Join-Path $PSScriptRoot "_DZSync.ps1")
. (Join-Path $PSScriptRoot "../../../common/Utils.ps1")

Resolve-DZDeployerEnv -ScriptRoot $PSScriptRoot -RemoteHost ([ref]$RemoteHost) -RemoteUser ([ref]$RemoteUser) -BoundParameters $PSBoundParameters
Assert-DZHost @{ RemoteHost = $RemoteHost; RemoteUser = $RemoteUser; RemotePath = $RemotePath }
$target = "${RemoteUser}@${RemoteHost}"

# A pulled default must PARSE for its kind before it may enter the repo (never capture a corrupt
# baseline). XML defaults carry a UTF-8 BOM (XmlDocument.Save writes one; the box copies it
# verbatim) which [xml] rejects as a stray U+FEFF - strip it before validating/storing.
function Remove-Bom([string]$text) { if ($text) { $text.TrimStart([char]0xFEFF) } else { $text } }
function Test-Parses([string]$text, [string]$ext) {
    if (-not $text -or -not $text.Trim()) { return $false }
    switch ($ext) {
        '.json' { try { $null = $text | ConvertFrom-Json; return $true } catch { return $false } }
        '.xml'  { try { $null = [xml]$text; return $true } catch { return $false } }
        default { return $true }   # other kinds: non-empty is enough
    }
}

# List the box's frozen-default files as server-relative paths. Scoped to profiles/ + mpmissions/
# (where every owned surface lives), with persistence trees pruned so the scan stays cheap.
Write-Host "Listing frozen defaults on ${target}:$RemotePath (profiles/, mpmissions/ ; *.defaults.*)"
$find = "cd '$RemotePath' && find profiles mpmissions -type d -name 'storage_*' -prune -o -type f -name '*.defaults.*' -print 2>/dev/null"
$list = Get-Stdout { ssh -o ConnectTimeout=10 $target $find } | Out-String
$rels = @($list -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '\.\.' })

# Only MANAGED missions are pulled. This used to read the mpmissions.<mission> keys of
# config-overrides.json; that document is deleted (2026-07-31), so the DECLARATION now comes
# from the same place every other surface fact does - config-registry.json's box paths. One
# source of truth, which is what the registry is for. A foreign dir under mpmissions/ (a side
# project, an admin copy) may carry copied .defaults - those are not ours and never enter the repo.
$declared = @()
$registryPath = Join-Path $PSScriptRoot 'config-registry.json'
if (Test-Path $registryPath) {
    try {
        $reg = Get-Content -Raw -LiteralPath $registryPath | ConvertFrom-Json
        $declared = @($reg.surfaces | ForEach-Object { $_.box } | Where-Object { $_ -match '^mpmissions/([^/]+)/' } |
                      ForEach-Object { [regex]::Match($_, '^mpmissions/([^/]+)/').Groups[1].Value } |
                      Sort-Object -Unique)
    } catch { Write-Warning "could not parse $registryPath for declared missions - pulling profiles/ defaults only" }
}
$foreign = 0
$rels = @($rels | Where-Object {
    if ($_ -notmatch '^mpmissions/([^/]+)/') { return $true }        # profiles/ etc.
    if ($declared -contains $Matches[1]) { return $true }
    $script:foreign++
    Write-Host "  [SKIP] $_ (mission not declared in config-registry.json - foreign dir, not managed)"
    return $false
})

$captured = 0; $have = 0; $rejected = 0
foreach ($rel in $rels) {
    $repoPath = Join-Path $MirrorDir $rel
    $raw = Get-Stdout { ssh -o ConnectTimeout=10 $target "cat '$RemotePath/$rel'" } | Out-String
    $raw = Remove-Bom $raw
    $ext = [IO.Path]::GetExtension($rel).ToLowerInvariant()
    if (-not (Test-Parses $raw $ext)) { $rejected++; Write-Warning "  [SKIP] $rel - unreadable or not valid $ext (not captured)"; continue }
    $boxTrim = $raw.TrimEnd()
    $tag = "PULL"
    if (Test-Path -LiteralPath $repoPath) {
        $curTrim = (Get-Content -Raw -LiteralPath $repoPath).TrimEnd()
        if ($curTrim -eq $boxTrim) { $have++; Write-Host "  [SAME] $rel (mirror matches the box)"; continue }
        $tag = "DIFF"   # box re-captured this baseline since the last pull - the mirror follows it
    }
    if ($Execute) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $repoPath) | Out-Null
        $boxTrim | Set-Content -LiteralPath $repoPath -Encoding utf8
        $captured++; Write-Host "  [$tag] $rel -> config-defaults/$rel$(if ($tag -eq 'DIFF') { ' (replaced - git history keeps the old one)' })"
    } else {
        $captured++; Write-Host "  [$tag] $rel (dry-run - -Execute would $(if ($tag -eq 'DIFF') { 'replace the mirror copy' } else { 'capture it' }))"
    }
}
$tag = if ($Execute) { 'pulled' } else { 'DRY-RUN' }
Write-Host ("Config defaults: {0} to pull, {1} in sync, {2} rejected, {3} foreign-skipped  [{4}]" -f $captured, $have, $rejected, $foreign, $tag)

if (-not $NoLog) {
    $logDir = Join-Path $PSScriptRoot "logs"; New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    Write-CsvLog -Path (Join-Path $logDir "configdefaults.csv") -Row ([PSCustomObject]@{
        Timestamp = Get-Date -Format "s"; Source = "${target}:$RemotePath"; DryRun = (-not $Execute)
        Captured = $captured; Have = $have; Rejected = $rejected
    })
}

# Explicit success: without this, $LASTEXITCODE from the last inner ssh/native call leaks
# to callers that check it (Pull-Configs, Deploy).
exit 0
