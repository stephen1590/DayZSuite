#requires -Version 7
<#
  Shared deploy-config loader for the NginxService repo.

  Dot-source it, then call Import-DeployConfig. It replaces the old
  "execute a deploy.config.ps1 hashtable" pattern with declarative data:

    host.config.env                      flat KEY=VALUE for the box (one source
                                         of truth: Server/SshUser/BaseDomain/...)
    <service>/deploy/deploy.config.json  JSON (comments allowed) for that service

  Import-DeployConfig merges the two (service keys win) and then resolves
  ${Key} references in every string value against the merged config, so a value
  like "hooks.${BaseDomain}" or "localhost:${Port}" keeps its primitive in ONE
  place and cannot drift. The returned hashtable has exactly the keys the deploy
  scripts already expect (Server, SshUser, SiteName, Hostnames, TemplateVars, ...).

  host.config.env always lives at the NginxService root, i.e. two levels above a
  service's deploy/ dir (deploy -> <service> -> NginxService), so callers only
  pass their own deploy dir.
#>

# Parse a flat KEY=VALUE .env file into a hashtable. Blank lines and #-comments
# are skipped; surrounding single/double quotes on a value are stripped.
function ConvertFrom-EnvFile([string]$Path) {
    $h = @{}
    foreach ($line in Get-Content -Path $Path) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        $eq = $t.IndexOf('=')
        if ($eq -lt 1) { continue }
        $k = $t.Substring(0, $eq).Trim()
        $v = $t.Substring($eq + 1).Trim()
        if ($v.Length -ge 2 -and (
                ($v[0] -eq '"'  -and $v[-1] -eq '"') -or
                ($v[0] -eq "'"  -and $v[-1] -eq "'"))) {
            $v = $v.Substring(1, $v.Length - 2)
        }
        $h[$k] = $v
    }
    return $h
}

# Recursively replace ${Key} in every string leaf with the matching TOP-LEVEL
# value from $Root. Unknown ${...} are left untouched (so a typo is visible, not
# silently blanked). Hashtables and arrays are walked in place.
function Resolve-ConfigRefs($Node, [hashtable]$Root) {
    if ($Node -is [string]) {
        return [regex]::Replace($Node, '\$\{(\w+)\}', {
            param($m)
            $key = $m.Groups[1].Value
            if ($Root.ContainsKey($key)) { [string]$Root[$key] } else { $m.Value }
        })
    }
    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($k in @($Node.Keys)) { $Node[$k] = Resolve-ConfigRefs $Node[$k] $Root }
        return $Node
    }
    if ($Node -is [System.Collections.IList]) {
        for ($i = 0; $i -lt $Node.Count; $i++) { $Node[$i] = Resolve-ConfigRefs $Node[$i] $Root }
        return ,$Node   # leading comma: keep it an array (PowerShell unwraps 1-element returns)
    }
    return $Node
}

function Import-DeployConfig {
    param(
        [Parameter(Mandatory)][string]$ServiceDeployDir,  # the <service>/deploy folder
        [string]$HostConfigPath                            # override; default = repo root host.config.env
    )
    $ServiceDeployDir = (Resolve-Path $ServiceDeployDir).Path
    if (-not $HostConfigPath) {
        $HostConfigPath = Join-Path $ServiceDeployDir '../../host.config.env'
    }
    if (-not (Test-Path $HostConfigPath)) {
        throw "Missing host config: $HostConfigPath (copy host.config.example.env -> host.config.env)."
    }
    $svcPath = Join-Path $ServiceDeployDir 'deploy.config.json'
    if (-not (Test-Path $svcPath)) {
        throw "Missing service config: $svcPath (copy deploy.config.example.json -> deploy.config.json)."
    }

    $hostCfg = ConvertFrom-EnvFile (Resolve-Path $HostConfigPath).Path
    $svcCfg  = (Get-Content -Raw $svcPath) | ConvertFrom-Json -AsHashtable
    if ($svcCfg -isnot [System.Collections.IDictionary]) {
        throw "Service config $svcPath must be a JSON object."
    }

    # Merge: host first, service overrides (there should be no overlap).
    $cfg = @{}
    foreach ($k in $hostCfg.Keys) { $cfg[$k] = $hostCfg[$k] }
    foreach ($k in $svcCfg.Keys)  { $cfg[$k] = $svcCfg[$k] }

    return (Resolve-ConfigRefs $cfg $cfg)
}
