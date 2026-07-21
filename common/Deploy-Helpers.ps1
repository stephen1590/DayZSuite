#requires -Version 7
<#
  Shared SHIP+RUN helpers for this repo's deploy scripts — the P1 deploy-layer
  extraction from MAINTENANCE-PLAN.md ("Extract Invoke-RemoteDeploy + New-SshArgs...
  replaces the ~25-line SHIP+RUN block duplicated in all four Deploy-*.ps1").

  First consumer: Monitoring/deploy/Deploy-Monitoring.ps1. The four older
  Deploy-*.ps1 still carry their own copies — migrate them ONE AT A TIME, diffing
  stage output before switching (per the plan; do not batch-migrate).

  Dot-source from a service's deploy/ dir:
    . (Join-Path $PSScriptRoot '../../common/Deploy-Helpers.ps1')
#>

# ssh argument list from the merged deploy config (SshPort/SshKey are optional keys).
# NO SshPort => emit NO -p, so ~/.ssh/config decides. This is load-bearing: an explicit
# -p on the command line OVERRIDES a Host alias's Port, so a hardcoded default of 22
# silently sends a deploy meant for `staging-vm` (alias: 127.0.0.1 port 2222) to
# 127.0.0.1:22 — the dev machine's own sshd. Only set SshPort for a box reached by real
# hostname; alias-reached boxes leave it unset (../STAGING-PLAN.md).
function New-SshArgs([hashtable]$Cfg) {
    $list = @()
    if ($Cfg.SshPort) { $list += @('-p', "$([int]$Cfg.SshPort)") }
    if ($Cfg.SshKey)  { $list += @('-i', $Cfg.SshKey) }
    return ,$list
}

<#
  Ship a staged directory to the box and run a script inside it.

  - $RemoteStage is relative to the SSH user's home (convention: .deploy/<SiteName>).
  - rsync --delete: the remote stage mirrors the local stage exactly, so a removed
    file cannot survive on the box.
  - The remote script's combined output streams back live; with -RunLog it is also
    teed to that file (the caller decides where logs live).
  Throws on any failed step — callers rely on $ErrorActionPreference = 'Stop'.
#>
function Invoke-RemoteDeploy {
    param(
        [Parameter(Mandatory)][hashtable]$Cfg,
        [Parameter(Mandatory)][string]$StageDir,
        [Parameter(Mandatory)][string]$RemoteStage,
        [Parameter(Mandatory)][string]$Script,      # filename inside the stage
        [string]$RunLog
    )
    $target  = "$($Cfg.SshUser)@$($Cfg.Server)"
    $sshArgs = New-SshArgs $Cfg

    & ssh @sshArgs $target "mkdir -p '$RemoteStage'"
    if ($LASTEXITCODE -ne 0) { throw "ssh mkdir failed (exit $LASTEXITCODE)." }

    $sshCmd = (@('ssh') + $sshArgs) -join ' '
    & rsync -az --delete -e $sshCmd "$StageDir/" "${target}:$RemoteStage/"
    if ($LASTEXITCODE -ne 0) { throw "rsync failed (exit $LASTEXITCODE)." }

    if ($RunLog) {
        & ssh @sshArgs $target "bash '$RemoteStage/$Script'" 2>&1 | Tee-Object -FilePath $RunLog
    } else {
        & ssh @sshArgs $target "bash '$RemoteStage/$Script'" 2>&1
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Remote script failed (exit $LASTEXITCODE)$(if ($RunLog) { ". See $RunLog" })."
    }
}
