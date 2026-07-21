#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Procure + run the local staging VM (QEMU/KVM, Ubuntu cloud image, cloud-init).
    The staging half of STAGING-PLAN.md, retargeted from "second VPS" to a local VM:
    full isolation from prod, no port forwarding (slirp user-net + hostfwd), disposable
    by design (overlay disk over a pristine base image - wipe = delete one file).
.DESCRIPTION
    Report-only by default: checks prerequisites and prints exactly what -Fix would do.
      -Fix    download the Ubuntu cloud image (SHA256-verified), build the cloud-init
              seed ISO (NoCloud), create the qcow2 overlay disk, and print the ssh
              config alias + next steps. Idempotent - existing artifacts are kept.
      -Start  boot the VM in the foreground (-nographic serial console; Ctrl-A X quits).
      -Wipe   delete the overlay + seed (staging reset). The base image stays cached.
              Also clears the VM's known_hosts entry so the next boot's new host key
              doesn't scream MITM.

    Networking (slirp, no root, nothing exposed off-host - all binds are 127.0.0.1):
      2222/tcp -> 22    ssh            8080/tcp -> 80   nginx (http-only staging)
      8443/tcp -> 443   (future)       2301-2306/udp    DayZ game
      27016/udp         Steam query    (RCon is loopback-on-box; deliberately NOT forwarded)

    The game port is 2301 (serverDZ.cfg / the unit's -port=2301, same as prod - NOT the
    DayZ default 2302). The client joins via 127.0.0.1:2301; Steam queries 127.0.0.1:27016.
    Changing this list needs a VM restart - hostfwd is fixed at boot.

    After -Fix, deploys reach it via the printed ssh alias (Host staging-vm), so every
    deploy script just gets Server=staging-vm / DEPLOY_REMOTE_HOST=staging-vm - no port
    plumbing anywhere. PREREQ before the FIRST deploy: the prod-only mirror-pull guard
    (STAGING-PLAN.md phase 1) - without it a staging deploy auto-commits staging config
    into the prod mirror.
.EXAMPLE
    ./New-StagingVm.ps1                  # report: prereq check + plan
    ./New-StagingVm.ps1 -Fix             # procure everything
    ./New-StagingVm.ps1 -Start           # boot it
    ./New-StagingVm.ps1 -Wipe -Fix       # reset staging (keeps the cached base image)
#>
[CmdletBinding()]
param(
    [switch]$Fix,
    [switch]$Start,
    [switch]$Wipe,
    [string]$UbuntuVersion = '26.04',                    # match prod (lsb_release -rs on the box)
    [int]$DiskGB = 60,                                   # sparse; real use ~40GB after DayZ+mods
    [int]$MemGB  = 8,
    [int]$Cpus   = 4,
    [string]$VmDir = '',                                 # precedence: this param > $env:STAGING_VM_DIR > ./vm
    [string]$SshPubKey = '',                             # default: first ~/.ssh/id_*.pub (ed25519 preferred)
    [switch]$NoLog
)

$ErrorActionPreference = 'Stop'
# Dev-machine-local config file - the staging counterpart of DayZ-Server/deployer.env.
# KEY=VALUE, # comments, optional quotes. CLI params always win; the process env var
# STAGING_VM_DIR is a last fallback so one-off shells still work without the file.
$envFile = Join-Path $PSScriptRoot 'staging.env'
$fileCfg = @{}
if (Test-Path $envFile) {
    foreach ($line in Get-Content $envFile) {
        if ($line -match '^\s*(#|$)') { continue }
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') { $fileCfg[$Matches[1]] = $Matches[2].Trim().Trim('"').Trim("'") }
    }
    if (-not $PSBoundParameters.ContainsKey('UbuntuVersion') -and $fileCfg['STAGING_UBUNTU_VERSION']) { $UbuntuVersion = $fileCfg['STAGING_UBUNTU_VERSION'] }
    if (-not $PSBoundParameters.ContainsKey('DiskGB') -and $fileCfg['STAGING_VM_DISK_GB']) { $DiskGB = [int]$fileCfg['STAGING_VM_DISK_GB'] }
    if (-not $PSBoundParameters.ContainsKey('MemGB')  -and $fileCfg['STAGING_VM_MEM_GB'])  { $MemGB  = [int]$fileCfg['STAGING_VM_MEM_GB'] }
    if (-not $PSBoundParameters.ContainsKey('Cpus')   -and $fileCfg['STAGING_VM_CPUS'])    { $Cpus   = [int]$fileCfg['STAGING_VM_CPUS'] }
}
# Where the VM's files live (base image, overlay disk, seed): param > staging.env > process env > ./vm
$vmDirSource = 'param'
if (-not $VmDir) {
    if ($fileCfg['STAGING_VM_DIR'])  { $VmDir = $fileCfg['STAGING_VM_DIR'];  $vmDirSource = 'staging.env' }
    elseif ($env:STAGING_VM_DIR)     { $VmDir = $env:STAGING_VM_DIR;         $vmDirSource = 'env STAGING_VM_DIR' }
    else                             { $VmDir = Join-Path $PSScriptRoot 'vm'; $vmDirSource = 'default' }
}
$utils = Join-Path $PSScriptRoot '../../../common/Utils.ps1'   # Dev/common - Write-CsvLog (staging -> GameServices -> UbuntuHost -> Dev)
if (Test-Path $utils) { . $utils }
function Log($action, $detail) {
    if ($NoLog -or -not (Get-Command Write-CsvLog -ErrorAction SilentlyContinue)) { return }
    $logDir = Join-Path $PSScriptRoot 'logs'; New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    Write-CsvLog -Path (Join-Path $logDir 'staging-vm.csv') -Row ([pscustomobject]@{
        Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); Action = $action; Detail = $detail })
}
function Show-Ok($m)   { Write-Host "[ OK ] $m" -ForegroundColor Green }
function Show-Miss($m) { Write-Host "[MISS] $m" -ForegroundColor Red; $script:missing++ }
function Show-Plan($m) { Write-Host "  -> $m" }
$missing = 0

$img      = "ubuntu-$UbuntuVersion-server-cloudimg-amd64.img"
$imgUrl   = "https://cloud-images.ubuntu.com/releases/$UbuntuVersion/release/$img"
$sumUrl   = "https://cloud-images.ubuntu.com/releases/$UbuntuVersion/release/SHA256SUMS"
$basePath = Join-Path $VmDir $img
$diskPath = Join-Path $VmDir 'staging-disk.qcow2'
$seedPath = Join-Path $VmDir 'seed.iso'

# --- prerequisites (always checked, report and -Fix alike) --------------------------------
Write-Host "`n=== Prerequisites ===" -ForegroundColor Cyan
foreach ($bin in 'qemu-system-x86_64', 'qemu-img', 'xorriso', 'curl', 'ssh') {
    if (Get-Command $bin -ErrorAction SilentlyContinue) { Show-Ok $bin }
    else { Show-Miss "$bin - pacman -S qemu-base libisoburn curl openssh" }
}
if (Test-Path '/dev/kvm') {
    try { $s = [System.IO.File]::OpenWrite('/dev/kvm'); $s.Close(); Show-Ok '/dev/kvm writable (KVM acceleration)' }
    catch { Show-Miss '/dev/kvm exists but not writable - sudo usermod -aG kvm $USER, then re-login' }
} else { Show-Miss '/dev/kvm missing - enable virtualization in BIOS / load kvm modules' }
if (-not $SshPubKey) {
    $cand = @('~/.ssh/id_ed25519.pub', '~/.ssh/id_rsa.pub') | ForEach-Object { Resolve-Path $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
    if ($cand) { $SshPubKey = $cand.Path; Show-Ok "ssh pubkey: $SshPubKey" }
    else { Show-Miss 'no ~/.ssh/id_*.pub - ssh-keygen -t ed25519 (or pass -SshPubKey)' }
} elseif (Test-Path $SshPubKey) { Show-Ok "ssh pubkey: $SshPubKey" } else { Show-Miss "pubkey not found: $SshPubKey" }
Write-Host "[ -- ] VM dir: $VmDir  ($vmDirSource)"
# Headroom on the TARGET mount (VM dir may sit on a different disk than the repo) -
# probe the nearest existing ancestor so the check works before the dir is created.
$probe = $VmDir
while ($probe -and -not (Test-Path $probe)) { $probe = Split-Path $probe }
$free = try { [math]::Round(([System.IO.DriveInfo]::new($probe)).AvailableFreeSpace / 1GB) } catch { 0 }
if ($free) { if ($free -gt ($DiskGB * 0.6)) { Show-Ok "disk headroom ~${free}GB free on that mount" } else { Show-Miss "only ~${free}GB free on that mount - DayZ+mods want ~40GB real" } }

if ($Wipe) {
    Write-Host "`n=== Wipe (staging reset) ===" -ForegroundColor Cyan
    foreach ($f in $diskPath, $seedPath) {
        if (Test-Path $f) {
            if ($Fix) { Remove-Item $f; Show-Ok "deleted $f" ; Log 'wipe' $f }
            else { Show-Plan "would delete $f" }
        }
    }
    if ($Fix) { ssh-keygen -R '[127.0.0.1]:2222' 2>$null | Out-Null; Show-Ok 'cleared known_hosts for [127.0.0.1]:2222' }
    if (-not $Fix) { Show-Plan 'base image kept either way (re-used on next -Fix)' }
    if (-not $Start) { exit 0 }
}

# --- procurement --------------------------------------------------------------------------
if (-not $Start) {
    Write-Host "`n=== Procurement ($(if ($Fix) { 'APPLY' } else { 'report-only - rerun with -Fix' })) ===" -ForegroundColor Cyan
    if ($missing -and $Fix) { Write-Error "prerequisites missing - fix the [MISS] lines first"; exit 1 }
    New-Item -ItemType Directory -Force -Path $VmDir | Out-Null

    # 1. Base image (pristine, cached, SHA256-verified; never booted directly - overlays only).
    if (Test-Path $basePath) { Show-Ok "base image cached: $img" }
    elseif ($Fix) {
        Show-Plan "downloading $imgUrl"
        curl -fL --progress-bar -o $basePath $imgUrl
        $want = ((curl -fsL $sumUrl) -split "`n" | Where-Object { $_ -match [regex]::Escape($img) } | Select-Object -First 1) -split '\s+' | Select-Object -First 1
        $have = (Get-FileHash -Algorithm SHA256 $basePath).Hash.ToLower()
        if ($want -and $have -ne $want) { Remove-Item $basePath; Write-Error "SHA256 mismatch for $img - deleted. want=$want have=$have"; exit 1 }
        Show-Ok "downloaded + verified $img"; Log 'download' $img
    } else { Show-Plan "would download + SHA256-verify $imgUrl" }

    # 2. Cloud-init NoCloud seed: user ubuntu + your ssh key, hostname staging-vm, base tools.
    #    Everything else (pwsh, node, nginx, dayz) arrives via the SAME documented deploy flow
    #    prod used - the VM deliberately starts as bare as a fresh VPS so the docs get proven.
    if (Test-Path $seedPath) { Show-Ok 'seed.iso present' }
    elseif ($Fix) {
        $key = (Get-Content $SshPubKey -Raw).Trim()
        $ud = @"
#cloud-config
hostname: staging-vm
ssh_pwauth: false
users:
  - name: ubuntu
    groups: sudo
    shell: /bin/bash
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    ssh_authorized_keys:
      - $key
package_update: true
packages: [rsync, jq, curl]
"@
        $md = "instance-id: staging-vm-001`nlocal-hostname: staging-vm`n"
        $tmp = Join-Path $VmDir 'seed-src'; New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        Set-Content -Path (Join-Path $tmp 'user-data') -Value $ud -NoNewline
        Set-Content -Path (Join-Path $tmp 'meta-data') -Value $md -NoNewline
        xorriso -as mkisofs -volid cidata -joliet -rock -o $seedPath (Join-Path $tmp 'user-data') (Join-Path $tmp 'meta-data') 2>$null
        Remove-Item -Recurse -Force $tmp
        Show-Ok 'seed.iso built (NoCloud: user ubuntu + your key)'; Log 'seed' 'built'
    } else { Show-Plan 'would build seed.iso (cloud-init: user ubuntu, your ssh key, rsync/jq/curl)' }

    # 3. Overlay disk over the pristine base - THE disposable unit. Wipe = delete this file.
    if (Test-Path $diskPath) { Show-Ok 'overlay disk present' }
    elseif ($Fix) {
        Push-Location $VmDir   # relative backing path so the vm/ folder is relocatable
        qemu-img create -f qcow2 -F qcow2 -b $img 'staging-disk.qcow2' "${DiskGB}G" | Out-Null
        Pop-Location
        Show-Ok "overlay disk created (${DiskGB}G sparse over $img)"; Log 'disk' "${DiskGB}G"
    } else { Show-Plan "would create ${DiskGB}G qcow2 overlay over the base image" }

    # 4. SSH alias - makes the VM look like any other host to every deploy script.
    $alias = @"
Host staging-vm
    HostName 127.0.0.1
    Port 2222
    User ubuntu
    StrictHostKeyChecking accept-new
"@
    $sshCfg = Resolve-Path '~/.ssh/config' -ErrorAction SilentlyContinue
    $has = $sshCfg -and (Select-String -Path $sshCfg -Pattern '^\s*Host\s+staging-vm\b' -Quiet)
    if ($has) { Show-Ok 'ssh config alias staging-vm present' }
    elseif ($Fix) {
        Add-Content -Path (Join-Path $HOME '.ssh/config') -Value "`n$alias"
        Show-Ok 'appended Host staging-vm to ~/.ssh/config'; Log 'ssh-alias' 'appended'
    } else { Show-Plan "would append to ~/.ssh/config:`n$alias" }

    if ($Fix) { Write-Host "`nDone. Boot it:  ./New-StagingVm.ps1 -Start   then:  ssh staging-vm" -ForegroundColor Cyan }
    exit 0
}

# --- run ----------------------------------------------------------------------------------
foreach ($f in $basePath, $diskPath, $seedPath) { if (-not (Test-Path $f)) { Write-Error "missing $f - run -Fix first"; exit 1 } }
$fwd = @(
    'hostfwd=tcp:127.0.0.1:2222-:22',   'hostfwd=tcp:127.0.0.1:8080-:80', 'hostfwd=tcp:127.0.0.1:8443-:443'
    # 2301 is THE game port (the unit renders -port=2301, matching prod). Omitting it was
    # why the server was unjoinable from the host on 2026-07-21 - the client had nothing to
    # talk to. 2303 + 27016 carry the Steam query/report traffic the browser needs.
    'hostfwd=udp:127.0.0.1:2301-:2301'
    'hostfwd=udp:127.0.0.1:2302-:2302', 'hostfwd=udp:127.0.0.1:2303-:2303', 'hostfwd=udp:127.0.0.1:2304-:2304'
    'hostfwd=udp:127.0.0.1:2305-:2305', 'hostfwd=udp:127.0.0.1:2306-:2306'
    # NO RCon forward, deliberately. BattlEye binds RConIP 127.0.0.1 ON the box (port 2306, not the
    # 2310 this line used to forward), and dayz-rcon.ps1 runs on the box too - the Api reaches it via
    # sudo, never over the network. A forward here would be both wrong and useless.
    'hostfwd=udp:127.0.0.1:27016-:27016'
) -join ','
Write-Host "Booting staging-vm (${MemGB}G RAM, $Cpus cpus). Serial console below - Ctrl-A X to quit." -ForegroundColor Cyan
Log 'start' "${MemGB}G/$Cpus"
qemu-system-x86_64 -enable-kvm -cpu host -smp $Cpus -m "${MemGB}G" `
    -drive "file=$diskPath,if=virtio" `
    -drive "file=$seedPath,media=cdrom" `
    -netdev "user,id=n0,$fwd" -device 'virtio-net-pci,netdev=n0' `
    -nographic
