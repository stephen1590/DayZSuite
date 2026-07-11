#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Reports (default) or performs (-Fix) daily zip archiving of a service's log files.
.DESCRIPTION
    Generic log archiver, service-agnostic: point it at any directory of rotating
    log files. Designed to run from a systemd timer (see dayz-logarchive.*), but
    works standalone for any service.

    - Candidates: top-level files in -SourceDir matching -Include whose last write
      is before today (per-day granularity). Files still open by a process are
      skipped (fuser) and picked up on a later run.
    - Files are grouped by last-write DATE, one zip per day:
      <ArchiveDir>/<Name>-logs-<yyyyMMdd>.zip. Zips are built streaming via .NET
      ZipArchive (multi-GB safe; Compress-Archive buffers in memory and dies) into
      a .tmp that atomically replaces the target. Originals are deleted only after
      their entry is verified present with a matching size.
    - Archive zips older than -RetentionDays (default: a month) are pruned, judged
      by the zip's own mtime so even freshly archived old logs get a full window.

    Read-only by default: reports what would happen, writes nothing. -Fix applies
    and appends a CSV run log to <ArchiveDir>/archive-log.csv (-NoLog disables).
    Standalone on purpose (no common/Utils.ps1): it runs under systemd on hosts
    that have only the deployed payload, not the tooling checkout.
.EXAMPLE
    ./Archive-Logs.ps1 -SourceDir ~/servers/dayz-server/profiles         # report only
    ./Archive-Logs.ps1 -SourceDir ~/servers/dayz-server/profiles -Fix    # archive
    ./Archive-Logs.ps1 -SourceDir /var/log/myapp -Name myapp -Fix        # any service
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceDir,
    [string[]]$Include = @('*.log', '*.RPT', '*.ADM', '*.mdmp'),
    [string]$ArchiveDir,                 # default: <SourceDir>/archive
    [string]$Name,                       # zip name prefix; default: leaf of SourceDir
    [int]$RetentionDays = 31,
    [switch]$Fix,
    [switch]$NoLog
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$SourceDir = (Resolve-Path $SourceDir).Path
if (-not $ArchiveDir) { $ArchiveDir = Join-Path $SourceDir 'archive' }
if (-not $Name)       { $Name = Split-Path -Leaf $SourceDir }
$csvPath = Join-Path $ArchiveDir 'archive-log.csv'
$today   = (Get-Date).Date
$mode    = if ($Fix) { 'fix' } else { 'report' }

function Write-Row($file, $archive, $state, $action) {
    Write-Host ("{0,-10} {1,-14} {2}  ->  {3}" -f $state, $action, $file, $archive)
    if ($Fix -and -not $NoLog) {   # report mode writes nothing, including the CSV
        $row = [PSCustomObject]@{ Timestamp = Get-Date -Format 's'; Mode = $mode
                                  File = $file; Archive = $archive; State = $state; Action = $action }
        if (Test-Path $csvPath) { $row | Export-Csv $csvPath -Append } else { $row | Export-Csv $csvPath }
    }
}

# A file still open by the service must never be zipped/removed: its content is
# incomplete and deleting it would orphan the writer's handle. fuser exit 0 = in use.
$fuser = Get-Command fuser -ErrorAction SilentlyContinue
if (-not $fuser) { Write-Warning "fuser not found — cannot detect open files; relying on last-write date alone." }
function Test-InUse($path) {
    if (-not $fuser) { return $false }
    & $fuser -s $path 2>$null   # no '--': fuser rejects it
    return ($LASTEXITCODE -eq 0)
}

# Rebuild the zip as <zip>.tmp in Create mode (pure streaming, any file size),
# carrying over existing entries, then swap into place. ZipArchiveMode.Update is
# deliberately avoided: it memory-buffers appended entries, same flaw as Compress-Archive.
function Update-Zip([string]$zipPath, [object[]]$files) {
    $tmp = "$zipPath.tmp"
    if (Test-Path $tmp) { Remove-Item $tmp }   # leftover from an interrupted run
    $dst = [IO.Compression.ZipFile]::Open($tmp, [IO.Compression.ZipArchiveMode]::Create)
    try {
        if (Test-Path $zipPath) {
            $src = [IO.Compression.ZipFile]::OpenRead($zipPath)
            try {
                foreach ($e in $src.Entries) {
                    if ($e.Name -in $files.Name) { continue }   # superseded by the fresh copy
                    $ne = $dst.CreateEntry($e.FullName, [IO.Compression.CompressionLevel]::Optimal)
                    $ne.LastWriteTime = $e.LastWriteTime
                    $in = $e.Open(); $out = $ne.Open()
                    try { $in.CopyTo($out) } finally { $out.Dispose(); $in.Dispose() }
                }
            } finally { $src.Dispose() }
        }
        foreach ($f in $files) {
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($dst, $f.FullName, $f.Name,
                [IO.Compression.CompressionLevel]::Optimal) | Out-Null
        }
    } finally { $dst.Dispose() }
    Move-Item $tmp $zipPath -Force
}

Write-Host "Archive-Logs [$mode]: $SourceDir -> $ArchiveDir (patterns: $($Include -join ', '); retention: $RetentionDays days)`n"

$candidates = @(Get-ChildItem -Path (Join-Path $SourceDir '*') -Include $Include -File |
    Where-Object { $_.LastWriteTime -lt $today } | Sort-Object LastWriteTime)

$archived = 0; $failed = 0
foreach ($g in ($candidates | Group-Object { $_.LastWriteTime.ToString('yyyyMMdd') })) {
    $zipName = "$Name-logs-$($g.Name).zip"
    $zip     = Join-Path $ArchiveDir $zipName
    $toZip   = @()
    foreach ($f in $g.Group) {
        if (Test-InUse $f.FullName) { Write-Row $f.Name $zipName 'InUse' 'skipped' }
        elseif (-not $Fix)          { Write-Row $f.Name $zipName 'Pending' 'would-zip' }
        else                        { $toZip += $f }
    }
    if (-not $toZip) { continue }

    New-Item -ItemType Directory -Force -Path $ArchiveDir | Out-Null
    Update-Zip $zip $toZip
    $za = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        foreach ($f in $toZip) {
            $ok = $za.Entries | Where-Object { $_.Name -eq $f.Name -and $_.Length -eq $f.Length }
            if ($ok) { Remove-Item $f.FullName; Write-Row $f.Name $zipName 'Archived' 'zipped+removed'; $archived++ }
            else     { Write-Row $f.Name $zipName 'VerifyFail' 'kept'; $failed++ }
        }
    } finally { $za.Dispose() }
}

# Retention by the ZIP's own mtime, not the datestamp in its name: a very old log
# archived today must still get its full retention window, never zip-then-prune.
$cutoff = $today.AddDays(-$RetentionDays)
$expired = @(Get-ChildItem -Path (Join-Path $ArchiveDir "$Name-logs-*.zip") -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '-logs-\d{8}\.zip$' -and $_.LastWriteTime -lt $cutoff })
foreach ($z in $expired) {
    if ($Fix) { Remove-Item $z.FullName; Write-Row $z.Name '-' 'Expired' 'pruned' }
    else      { Write-Row $z.Name '-' 'Expired' 'would-prune' }
}

Write-Host "`nSummary [$mode]: $($candidates.Count) candidate(s), $archived archived, $failed verify-failed, $($expired.Count) expired zip(s)."
if ($Fix -and -not $NoLog -and (Test-Path $csvPath)) {
    Write-Row '(summary)' '-' "candidates=$($candidates.Count)" "archived=$archived failed=$failed pruned=$($expired.Count)"
}
if ($failed) { exit 5 }
