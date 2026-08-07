#requires -Version 7
<#
  config-backup.test.ps1 - the nightly config snapshot.

  WHAT GETS BACKED UP IS NOT A LIST. A file earns a backup by having a frozen default beside it,
  and the box writes that default the first time the file is edited through the editor. So the
  set maintains itself: edit a new file, it joins the backup; nothing else has to be told.

  That rule replaced include patterns plus three exclusion lists. Those lists were a second
  definition of "what is config", they had to be hand-maintained, and they would have drifted
  from the box the first time a mod folder appeared.

  A backup is also not a rotation: the log archiver MOVES yesterday's logs into a zip, while
  this COPIES a live tree the server is still reading. Asserted first, because losing that
  distinction deletes live config.

  Exercised against a temp tree - no box, no network.
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
# common/ lives beside the repo, not inside it: DayZ-Server/tests -> ... -> Dev/common.
$devRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $here)))
$script = Join-Path $devRoot 'common/Backup-Snapshot.ps1'

$pass = 0; $fail = 0
function Check([bool]$ok, [string]$what) {
    if ($ok) { $script:pass++; Write-Host "  [PASS] $what" }
    else     { $script:fail++; Write-Host "  [FAIL] $what" }
}

Check (Test-Path $script) "common/Backup-Snapshot.ps1 exists"
if (-not (Test-Path $script)) { Write-Host "`nconfig-backup: $pass passed, $fail failed"; exit 1 }

$work = Join-Path ([IO.Path]::GetTempPath()) ("cfgbak-" + [Guid]::NewGuid().ToString('N'))
$src = Join-Path $work 'server'
$out = Join-Path $work 'backups'
try {
    New-Item -ItemType Directory -Force -Path (Join-Path $src 'mpmissions/dayzOffline.sakhal/db') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $src 'profiles/users') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $src 'storage_1') | Out-Null

    # EDITED (has a frozen default beside it) - these are the backup set, whatever their type.
    Set-Content (Join-Path $src 'server-settings.json') '{"hostname":"live"}'
    Set-Content (Join-Path $src 'server-settings.defaults.json') '{"hostname":"state-0"}'
    Set-Content (Join-Path $src 'mpmissions/dayzOffline.sakhal/db/types.xml') '<types><type name="live"/></types>'
    Set-Content (Join-Path $src 'mpmissions/dayzOffline.sakhal/db/types.defaults.xml') '<types/>'
    Set-Content (Join-Path $src 'ban.txt') '76561'                       # not json/xml on purpose
    Set-Content (Join-Path $src 'ban.defaults.txt') ''
    Set-Content (Join-Path $src 'map.env') 'MISSION=sakhal'              # no extension family at all
    Set-Content (Join-Path $src 'map.defaults.env') 'MISSION=chernarus'

    # NEVER EDITED - no default, so no backup. None of these needs naming anywhere.
    Set-Content (Join-Path $src 'mpmissions/dayzOffline.sakhal/mapgroupcluster.xml') '<vendor/>'
    Set-Content (Join-Path $src 'profiles/users/player.json') '{"steam":"765"}'
    Set-Content (Join-Path $src 'storage_1/data.bin') 'persistence'
    Set-Content (Join-Path $src 'dayz.log') 'noise'
    # An orphaned default (its live file is gone) is not a pair and must not be captured alone.
    Set-Content (Join-Path $src 'retired.defaults.json') '{"was":"here"}'

    # --- 1. report mode writes NOTHING ---------------------------------------------------
    & $script -SourceDir $src -ArchiveDir $out -Name cfg -NoLog | Out-Null
    Check (-not (Test-Path $out)) 'a report run creates no archive directory - read-only by default'

    # --- 2. -Fix writes one zip and KEEPS every original ----------------------------------
    & $script -SourceDir $src -ArchiveDir $out -Name cfg -Fix -NoLog | Out-Null
    $zips = @(Get-ChildItem -Path $out -Filter 'cfg-*.zip' -File -ErrorAction SilentlyContinue)
    Check ($zips.Count -eq 1) "one snapshot zip written (found $($zips.Count))"
    Check (Test-Path (Join-Path $src 'server-settings.json')) 'THE POINT: the live file is still there - a backup copies, never moves'

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $za = [IO.Compression.ZipFile]::OpenRead($zips[0].FullName)
    try { $names = @($za.Entries | ForEach-Object { $_.FullName -replace '\\', '/' }) } finally { $za.Dispose() }

    # --- 3. THE RULE: a file with a frozen default is captured, WITH its default -----------
    Check ($names -contains 'server-settings.json' -and $names -contains 'server-settings.defaults.json') `
        'an edited file is captured together with its frozen default - restore needs both'
    Check ($names -contains 'mpmissions/dayzOffline.sakhal/db/types.xml' -and
           $names -contains 'mpmissions/dayzOffline.sakhal/db/types.defaults.xml') `
        'nested pairs are captured with their paths'
    Check ($names -contains 'ban.txt' -and $names -contains 'ban.defaults.txt') `
        'a .txt pair is captured - the rule is the default, never the file type'
    Check ($names -contains 'map.env' -and $names -contains 'map.defaults.env') `
        'and a .env pair too - no extension list exists to leave one out'

    # --- 4. everything else is absent because it was never edited, not because it was listed
    Check (-not ($names | Where-Object { $_ -like '*mapgroup*' })) 'vendor map geometry: no default, no backup'
    Check (-not ($names | Where-Object { $_ -like 'profiles/users/*' })) 'player profile data: no default, no backup'
    Check (-not ($names | Where-Object { $_ -like 'storage_*' })) 'persistence: no default, no backup'
    Check (-not ($names | Where-Object { $_ -like '*.log' })) 'logs: no default, no backup'
    Check (-not ($names | Where-Object { $_ -like 'retired*' })) 'an orphaned default is not a pair - captured alone it would restore nothing'

    # --- 5. a NEW edit joins the backup with no configuration anywhere ----------------------
    Set-Content (Join-Path $src 'mpmissions/dayzOffline.sakhal/cfggameplay.json') '{"new":"edit"}'
    Set-Content (Join-Path $src 'mpmissions/dayzOffline.sakhal/cfggameplay.defaults.json') '{}'
    & $script -SourceDir $src -ArchiveDir $out -Name cfg -Fix -NoLog | Out-Null
    $za = [IO.Compression.ZipFile]::OpenRead((Get-ChildItem -Path $out -Filter 'cfg-*.zip' -File)[0].FullName)
    try { $names2 = @($za.Entries | ForEach-Object { $_.FullName -replace '\\', '/' }) } finally { $za.Dispose() }
    Check ($names2 -contains 'mpmissions/dayzOffline.sakhal/cfggameplay.json') `
        'THE PAYOFF: a newly edited file backs itself up - nothing had to be added to a list'

    # --- 6. retention prunes old snapshots, and only its own ------------------------------
    $old = Join-Path $out 'cfg-19990101.zip'
    Copy-Item $zips[0].FullName $old
    (Get-Item $old).LastWriteTime = (Get-Date).AddDays(-40)
    $keep = Join-Path $out 'something-else.zip'
    Copy-Item $zips[0].FullName $keep
    (Get-Item $keep).LastWriteTime = (Get-Date).AddDays(-40)
    & $script -SourceDir $src -ArchiveDir $out -Name cfg -RetentionDays 30 -Fix -NoLog | Out-Null
    Check (-not (Test-Path $old)) 'a snapshot past its retention window is pruned'
    Check (Test-Path $keep) 'a file that is not one of its snapshots is left alone'
    Check (@(Get-ChildItem -Path $out -Filter 'cfg-*.zip' -File).Count -eq 1) 'one snapshot per day, replaced in place'

    # --- 7. the CSV log is opt-out ---------------------------------------------------------
    & $script -SourceDir $src -ArchiveDir $out -Name cfg -Fix | Out-Null
    Check (Test-Path (Join-Path $out 'backup-log.csv')) 'a -Fix run appends a CSV run log unless -NoLog'

    # --- 8. THE UNIT'S OWN ARGUMENTS actually work -----------------------------------------
    # Calling the script from PowerShell passes real values; systemd passes a flat string, and
    # `pwsh -File` binds them differently. The service died on its first run because of exactly
    # that, so this runs the unit's own ExecStart rather than trusting it.
    $unit = Join-Path (Split-Path -Parent $here) 'deploy/dayz-configbackup.service'
    Check (Test-Path $unit) 'the systemd unit exists'
    $exec = ((Get-Content -Raw $unit) -split "`n" | Where-Object { $_ -match '^ExecStart=' }) -join ' '
    $exec = $exec -replace '^ExecStart=\S*pwsh\s+', ''
    $unitOut = Join-Path $work 'unit-backups'
    $argv = @($exec.Trim() -split '\s+' | ForEach-Object {
        $_.Replace('{{DEPLOY_HOME}}/servers/dayz-server/Backup-Snapshot.ps1', $script).
           Replace('{{DEPLOY_HOME}}/servers/dayz-server/config-backups', $unitOut).
           Replace('{{DEPLOY_HOME}}/servers/dayz-server', $src)
    })
    & pwsh -NoProfile @argv *> (Join-Path $work 'unit-run.txt')
    Check ($LASTEXITCODE -eq 0) "the unit's exact ExecStart arguments run clean (exit $LASTEXITCODE)"
    $unitZips = @(Get-ChildItem -Path $unitOut -Filter 'config-*.zip' -File -ErrorAction SilentlyContinue)
    Check ($unitZips.Count -eq 1) "and produce a snapshot (found $($unitZips.Count))"
    if ($unitZips.Count -eq 1) {
        $za2 = [IO.Compression.ZipFile]::OpenRead($unitZips[0].FullName)
        try { $un = @($za2.Entries | ForEach-Object { $_.FullName -replace '\\', '/' }) } finally { $za2.Dispose() }
        Check ($un -contains 'ban.txt' -and $un -contains 'map.env') 'capturing pairs of any file type'
        Check (-not ($un | Where-Object { $_ -like 'storage_*' -or $_ -like '*mapgroup*' })) 'and nothing that was never edited'
    }

    # --- 9. NO GATE-KEEPING LISTS ----------------------------------------------------------
    # The rule is self-maintaining only while nothing re-introduces a hand-kept set of paths.
    $unitText = Get-Content -Raw $unit
    foreach ($flag in '-Include', '-Exclude', '-ExcludeName', '-MaxFileBytes') {
        Check (-not ($unitText -match [regex]::Escape($flag))) `
            "the unit passes no $flag list - what to back up is decided by the frozen default, not by a list"
    }
    $scriptText = Get-Content -Raw $script
    Check (-not ($scriptText -match '(?m)^\s*\[string\[\]\]\$(Include|Exclude|ExcludeName)\b')) `
        'and the script no longer offers those parameters - an unused knob is how the lists come back'
} finally { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host "`nconfig-backup: $pass passed, $fail failed"
if ($fail) { exit 1 } else { exit 0 }
