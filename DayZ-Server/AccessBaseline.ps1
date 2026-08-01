#requires -Version 7
<#
.SYNOPSIS
  S1 - a model of TODAY's effective config access rules. Read-only, no side effects.

.DESCRIPTION
  Dot-source this; it defines Get-TodayAccess and nothing else.

  This is a RE-IMPLEMENTATION of rules that live in three places, written down so WS-S has
  something concrete to be "equivalent to" (owner requirement 3). It is deliberately a model
  and not the truth: `Capture-AccessBaseline.ps1` spot-checks it against real `dayz-ctl`
  calls, because a model that silently disagrees with the box would make the whole migration
  unreviewable.

  The three rule sources it mirrors:
    - `_own_check` in Api/deploy/templates/dayz-ctl.template - the WRITE gate
    - `emit_allowed` / config-list                            - the READ/list gate
    - the registry `mirror` field + Pull-Configs               - the MIRROR gate

  Two asymmetries worth naming, because they are defects this model must reproduce faithfully
  rather than quietly fix (WS-S S4 fixes them):
    1. OWNED_FILES is matched with `grep -qxF` (EXACT line) but OWNED_DIRS with a prefix, so a
       `<stem>.defaults.<ext>` companion is served under a DIR row and refused under a FILE
       row. Measured on prod 2026-08-01: served=0, REFUSED=33.
    2. `listed` and `writable` are independent axes; a row can be listed and read-only, and a
       file can be absent from the registry entirely, which makes it invisible AND unmirrored.
       That silent-omission case is the failure WS-S inverts.
#>

# Compile a `generated` glob the same way dayz-ctl does: '*' spans '/'.
function Test-GeneratedMatch {
    param([string]$Rel, [string[]]$Globs)
    foreach ($g in $Globs) {
        if (-not $g) { continue }
        $rx = '^' + ([regex]::Escape($g) -replace '\\\*', '.*') + '$'
        if ($Rel -match $rx) { return $true }
    }
    return $false
}

function Get-TodayAccess {
    [OutputType([hashtable])]
    param(
        # ServerDir-relative path, forward slashes.
        [Parameter(Mandatory)][string]$RelPath,
        # @{ OwnedFiles=@(); OwnedDirs=@(); Generated=@(); Disabled=@(); OnDisk=@() }
        [Parameter(Mandatory)][hashtable]$Masks,
        # The registry `surfaces` array (rows as hashtables or PSCustomObjects).
        [Parameter(Mandatory)][object[]]$Registry
    )
    $rel = $RelPath -replace '\\', '/'
    $ext = [IO.Path]::GetExtension($rel).ToLowerInvariant()
    $isDoc = $ext -in @('.json', '.xml')

    $generated = Test-GeneratedMatch -Rel $rel -Globs @($Masks.Generated)
    $disabled  = @($Masks.Disabled) -contains $rel
    $onDisk    = @($Masks.OnDisk) -contains $rel

    # --- WRITE gate: _own_check, reproduced including its exact/prefix asymmetry ---
    $inOwnedFiles = @($Masks.OwnedFiles) -contains $rel          # grep -qxF: EXACT line
    $inOwnedDir   = $false
    foreach ($d in @($Masks.OwnedDirs)) {
        if ($d -and $rel.StartsWith("$d/")) { $inOwnedDir = $true; break }   # case "$_r" in "$_d"/*
    }
    # own-write's own gate. NOT the same as "can an operator change this file" - see below.
    $ownWritable = $isDoc -and ($inOwnedFiles -or $inOwnedDir) -and -not $generated -and -not $disabled -and $onDisk

    # --- WRITE gate, part 2: the FOUR bespoke verbs that bypass own-write entirely ---
    # Corrected 2026-08-01. The first cut equated "writable" with the own-write gate, which
    # understated reality for 5 files: the two CE tuning files are NOT in OWNED_FILES and are
    # written by `types-write`; ban.txt/whitelist.txt by `file-write`; map-points by
    # `spawn-write`. S3 must reproduce today's map, so today's map has to include them.
    # These five are also every WS-S/WS-U collision point: making one `rw` would give it a
    # SECOND write path unless its bespoke verb retires in the same change.
    $writableVia = 'none'
    if ($ownWritable) {
        $writableVia = 'own-write'
    } else {
        foreach ($row in $Registry) {
            if ([string]$row.box -ne $rel) { continue }
            $web = [string]$row.web
            if ($generated -or $disabled) { break }          # both still veto every path
            if ($web -eq 'types')      { $writableVia = 'types-write'; break }
            elseif ($web -eq 'store')  { $writableVia = 'spawn-write'; break }
            elseif ($row.writable -eq $true) { $writableVia = 'file-write'; break }
            break
        }
    }
    $writable = ($writableVia -ne 'none')

    # --- READ/list gate: a registry row that is not web:'none', or a browse folder ---
    $listed = $false
    foreach ($row in $Registry) {
        $box = [string]$row.box
        $dir = [string]$row.dir
        $web = [string]$row.web
        if ($box -and $box -eq $rel) { if ($web -and $web -ne 'none') { $listed = $true }; break }
        if ($dir -and $rel.StartsWith("$dir/")) { if ($web -and $web -ne 'none') { $listed = $true } }
    }
    # An owned-DIR file is reachable through the box read path even without its own row -
    # this is why a .defaults under a dir row is served while one under a file row is not.
    if (-not $listed -and $inOwnedDir -and $isDoc -and $onDisk) { $listed = $true }
    if ($disabled) { $listed = $false }   # the UI drops a turned-off mod's rows entirely

    # --- MIRROR gate: the registry field, independent of the masks ---
    $mirrored = $false
    foreach ($row in $Registry) {
        if ([string]$row.box -eq $rel -and [string]$row.mirror -eq 'live') { $mirrored = $true; break }
    }

    return @{
        RelPath     = $rel
        Listed      = [bool]$listed
        Writable    = [bool]$writable        # editable by ANY verb - the operator's view
        OwnWritable = [bool]$ownWritable     # passes _own_check - what own-read/own-write allow
        WritableVia = [string]$writableVia
        Mirrored    = [bool]$mirrored
        Generated = [bool]$generated
        Disabled  = [bool]$disabled
        OnDisk    = [bool]$onDisk
    }
}
