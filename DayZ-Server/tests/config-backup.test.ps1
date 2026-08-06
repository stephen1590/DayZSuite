#requires -Version 7
<#
  config-backup.test.ps1 - the nightly config snapshot.

  A backup is not a rotation. The log archiver MOVES yesterday's logs into a zip; a config
  snapshot must COPY, because the server is still reading every file it touches. Losing that
  distinction would delete live config, so it is the first thing asserted here.

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
    New-Item -ItemType Directory -Force -Path (Join-Path $src 'steamapps/workshop') | Out-Null
    Set-Content (Join-Path $src 'server-settings.json') '{"hostname":"t"}'
    Set-Content (Join-Path $src 'mpmissions/dayzOffline.sakhal/db/types.xml') '<types/>'
    Set-Content (Join-Path $src 'profiles/users/player.json') '{"steam":"765"}'
    Set-Content (Join-Path $src 'storage_1/data.bin') 'persistence'
    Set-Content (Join-Path $src 'steamapps/workshop/big.pbo') 'mod'
    Set-Content (Join-Path $src 'dayz.log') 'noise'
    Set-Content (Join-Path $src 'mpmissions/dayzOffline.sakhal/mapgroupcluster.xml') '<vendor/>'

    $excl = @('profiles/users', 'storage_', 'steamapps', '@')
    $inc  = @('*.json', '*.xml', '*.txt', '*.cfg')

    # --- 1. report mode writes NOTHING ---------------------------------------------------
    & $script -SourceDir $src -ArchiveDir $out -Name cfg -Include $inc -Exclude $excl -NoLog | Out-Null
    Check (-not (Test-Path $out)) 'a report run creates no archive directory - read-only by default'

    # --- 2. -Fix writes one zip and KEEPS every original ----------------------------------
    & $script -SourceDir $src -ArchiveDir $out -Name cfg -Include $inc -Exclude $excl -Fix -NoLog | Out-Null
    $zips = @(Get-ChildItem -Path $out -Filter 'cfg-*.zip' -File -ErrorAction SilentlyContinue)
    Check ($zips.Count -eq 1) "one snapshot zip written (found $($zips.Count))"
    Check (Test-Path (Join-Path $src 'server-settings.json')) 'THE POINT: the live file is still there - a backup copies, never moves'
    Check (Test-Path (Join-Path $src 'mpmissions/dayzOffline.sakhal/db/types.xml')) 'a nested live file is still there too'

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $za = [IO.Compression.ZipFile]::OpenRead($zips[0].FullName)
    try { $names = @($za.Entries | ForEach-Object { $_.FullName -replace '\\', '/' }) } finally { $za.Dispose() }

    # --- 3. it captures the config tree, recursively ---------------------------------------
    Check ($names -contains 'server-settings.json') 'a root config file is captured'
    Check ($names -contains 'mpmissions/dayzOffline.sakhal/db/types.xml') 'a nested config file is captured with its path'

    # --- 4. and captures NOTHING it was told to exclude ------------------------------------
    Check (-not ($names | Where-Object { $_ -like 'profiles/users/*' })) 'player profile data is excluded'
    Check (-not ($names | Where-Object { $_ -like 'storage_*' }))        'persistence is excluded'
    Check (-not ($names | Where-Object { $_ -like 'steamapps/*' }))      'the game install is excluded'
    Check (-not ($names | Where-Object { $_ -like '*.log' }))            'logs are excluded - they have their own archiver'

    # --- 5. retention prunes old snapshots, and only its own ------------------------------
    $old = Join-Path $out 'cfg-19990101.zip'
    Copy-Item $zips[0].FullName $old
    (Get-Item $old).LastWriteTime = (Get-Date).AddDays(-40)
    $keep = Join-Path $out 'something-else.zip'
    Copy-Item $zips[0].FullName $keep
    (Get-Item $keep).LastWriteTime = (Get-Date).AddDays(-40)
    & $script -SourceDir $src -ArchiveDir $out -Name cfg -Include $inc -Exclude $excl -RetentionDays 30 -Fix -NoLog | Out-Null
    Check (-not (Test-Path $old)) 'a snapshot past its retention window is pruned'
    Check (Test-Path $keep) 'a file that is not one of its snapshots is left alone'

    # --- 6. a second run the same day replaces, never accumulates -------------------------
    $today = @(Get-ChildItem -Path $out -Filter 'cfg-*.zip' -File)
    Check ($today.Count -eq 1) "one snapshot per day, replaced in place (found $($today.Count))"

    # --- 7. the CSV log is opt-out, and lands in the archive dir ---------------------------
    & $script -SourceDir $src -ArchiveDir $out -Name cfg -Include $inc -Exclude $excl -Fix | Out-Null
    Check (Test-Path (Join-Path $out 'backup-log.csv')) 'a -Fix run appends a CSV run log unless -NoLog'

    # --- 8. THE UNIT'S OWN ARGUMENTS actually work -----------------------------------------
    # Calling the script from PowerShell passes real arrays; systemd passes a flat string, and
    # `pwsh -File` binds a SPACE-separated list positionally - so `-Include *.json *.xml` fed
    # *.xml to the next parameter and the service died on its first run. Nothing but running the
    # unit's exact argument line catches that, so this runs it.
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
    $unitOk = $LASTEXITCODE -eq 0
    Check $unitOk "the unit's exact ExecStart arguments run clean (exit $LASTEXITCODE)"
    $unitZips = @(Get-ChildItem -Path $unitOut -Filter 'config-*.zip' -File -ErrorAction SilentlyContinue)
    Check ($unitZips.Count -eq 1) "and produce a snapshot (found $($unitZips.Count))"
    if ($unitZips.Count -eq 1) {
        $za2 = [IO.Compression.ZipFile]::OpenRead($unitZips[0].FullName)
        try { $un = @($za2.Entries | ForEach-Object { $_.FullName -replace '\\', '/' }) } finally { $za2.Dispose() }
        Check ($un -contains 'mpmissions/dayzOffline.sakhal/db/types.xml') `
            'including .xml - the pattern that was being swallowed by the wrong parameter'
        Check (-not ($un | Where-Object { $_ -like 'profiles/users/*' -or $_ -like 'storage_*' })) `
            'and still excluding what the unit lists'
        # Vendor map geometry repeats under EVERY mission, so a path prefix cannot express it -
        # the unit excludes it by filename, and this proves that reaches the archive decision.
        Check (-not ($un | Where-Object { $_ -like '*mapgroup*' })) `
            'and excluding vendor map geometry by filename, at any depth'
    }
} finally { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host "`nconfig-backup: $pass passed, $fail failed"
if ($fail) { exit 1 } else { exit 0 }
