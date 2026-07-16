#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pull box-born <name>.defaults<ext> baselines off the box into the repo (config-defaults/)
    — the deploy's pull-before-push step for the FROZEN DEFAULTS behind config-overrides.

.DESCRIPTION
    A default is BORN on the box: Apply-ConfigOverrides captures the pristine file the first
    time prestart patches it (see that script). This pulls those born defaults DOWN so the repo
    has them - versioned, hand-editable, and shippable back.

    CAPTURE-ONCE / repo-authoritative: a default the repo ALREADY has is LEFT ALONE (so a
    hand-edit in config-defaults/ wins); only box defaults the repo LACKS are pulled in. The
    deploy then ships config-defaults/ back to the ServerDir (repo -> box), so a hand-edited
    default takes effect and the box's capture-if-missing never re-snapshots over it.

    To REFRESH a default after a mod update: delete it from BOTH config-defaults/ (repo) and the
    box, then redeploy - prestart re-captures the current pristine file and this pulls it back in.

    Read-only by default (shows what pulling WOULD capture); -Execute writes. A pulled default
    that is not valid for its kind (JSON/XML) is REJECTED - a corrupt baseline never enters the repo.

    Modelled on Sync-ConfigOverrides.ps1 (same box-authoritative shape). Only targets live under
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
. (Join-Path $PSScriptRoot "../../common/Utils.ps1")

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
# (where all override targets live), with persistence trees pruned so the scan stays cheap.
Write-Host "Listing frozen defaults on ${target}:$RemotePath (profiles/, mpmissions/ ; *.defaults.*)"
$find = "cd '$RemotePath' && find profiles mpmissions -type d -name 'storage_*' -prune -o -type f -name '*.defaults.*' -print 2>/dev/null"
$list = Get-Stdout { ssh -o ConnectTimeout=10 $target $find } | Out-String
$rels = @($list -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '\.\.' })

# Only MANAGED missions are pulled: the mpmissions.<mission> keys of config-overrides.json
# declare them (same rule as Apply-ConfigOverrides). A foreign dir under mpmissions/ (a side
# project, an admin copy) may carry copied .defaults - those are not ours and never enter the repo.
$declared = @()
$manifestPath = Join-Path $PSScriptRoot 'config-overrides.json'
if (Test-Path $manifestPath) {
    try {
        $mf = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
        if ($mf.PSObject.Properties.Name -contains 'mpmissions') {
            $declared = @($mf.mpmissions.PSObject.Properties.Name | Where-Object { $_ -ne 'common' -and -not $_.StartsWith('_') })
        }
    } catch { Write-Warning "could not parse $manifestPath for declared missions - pulling profiles/ defaults only" }
}
$foreign = 0
$rels = @($rels | Where-Object {
    if ($_ -notmatch '^mpmissions/([^/]+)/') { return $true }        # profiles/ etc.
    if ($declared -contains $Matches[1]) { return $true }
    $script:foreign++
    Write-Host "  [SKIP] $_ (mission not declared in config-overrides.json - foreign dir, not managed)"
    return $false
})

$captured = 0; $have = 0; $rejected = 0
foreach ($rel in $rels) {
    $repoPath = Join-Path $MirrorDir $rel
    if (Test-Path -LiteralPath $repoPath) { $have++; Write-Host "  [HAVE] $rel (repo authoritative - left as-is)"; continue }
    $raw = Get-Stdout { ssh -o ConnectTimeout=10 $target "cat '$RemotePath/$rel'" } | Out-String
    $raw = Remove-Bom $raw
    $ext = [IO.Path]::GetExtension($rel).ToLowerInvariant()
    if (-not (Test-Parses $raw $ext)) { $rejected++; Write-Warning "  [SKIP] $rel - unreadable or not valid $ext (not captured)"; continue }
    if ($Execute) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $repoPath) | Out-Null
        $raw.TrimEnd() | Set-Content -LiteralPath $repoPath -Encoding utf8
        $captured++; Write-Host "  [PULL] $rel -> config-defaults/$rel"
    } else {
        $captured++; Write-Host "  [PULL] $rel (dry-run - -Execute would capture it)"
    }
}
$tag = if ($Execute) { 'pulled' } else { 'DRY-RUN' }
Write-Host ("Config defaults: {0} to capture, {1} already in repo, {2} rejected, {3} foreign-skipped  [{4}]" -f $captured, $have, $rejected, $foreign, $tag)

if (-not $NoLog) {
    $logDir = Join-Path $PSScriptRoot "logs"; New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    Write-CsvLog -Path (Join-Path $logDir "configdefaults.csv") -Row ([PSCustomObject]@{
        Timestamp = Get-Date -Format "s"; Source = "${target}:$RemotePath"; DryRun = (-not $Execute)
        Captured = $captured; Have = $have; Rejected = $rejected
    })
}
