#requires -Version 7
<#
.SYNOPSIS
  S1 - the model of TODAY's effective access rules, before WS-S changes anything.

  WHY: WS-S requirement 3 is "reconfigure the application to be equivalent to today's
  access map". Equivalent to WHAT is not reviewable until today's map is written down, so
  S1 captures it and S3 must reproduce it file-for-file.

  This tests the MODEL of today's rules (Get-TodayAccess). The model is a re-implementation
  of the box's `_own_check` + `emit_allowed` + the registry's mirror fields, so it can be
  wrong in exactly one way: by disagreeing with the box. Capture-AccessBaseline.ps1 spot-
  checks it against real dayz-ctl calls for that reason - the model alone is not the proof.

  Today's rules, as read from Api/deploy/templates/dayz-ctl.template (_own_check) and
  DayZ-Server/Pull-Configs.ps1:
    writable  = .json|.xml AND (exact line in OWNED_FILES OR prefix match on OWNED_DIRS)
                AND NOT generated AND NOT a disabled mod's target AND present on disk
    listed    = a registry row with web != 'none', or reachable via a browse folder row
    mirrored  = registry row with mirror == 'live' (pulled into its seed path)
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path (Split-Path -Parent $here) 'AccessBaseline.ps1')

$pass = 0; $fail = 0
function Check([bool]$ok, [string]$what) {
    if ($ok) { $script:pass++; Write-Host "  [PASS] $what" }
    else     { $script:fail++; Write-Host "  [FAIL] $what" }
}

# A miniature but structurally real box: the same shapes prod has.
$masks = @{
    OwnedFiles = @(
        'server-settings.json',
        'mpmissions/dayzOffline.sakhal/db/types.xml',
        'profiles/AIB_Unleashed/AIB_UL_Config.json'
    )
    OwnedDirs  = @('profiles/ExpansionMod/Loadouts', 'profiles/ExpansionMod/Settings')
    Generated  = @('serverDZ.cfg', 'profiles/AI_Bandits/DynamicAIB.json', 'mpmissions/*/expansion/settings/AIPatrols.draft.json')
    Disabled   = @('profiles/AIB_Unleashed/AIB_UL_Config.json')
    OnDisk     = @(
        'server-settings.json',
        'mpmissions/dayzOffline.sakhal/db/types.xml',
        'mpmissions/dayzOffline.sakhal/db/types.defaults.xml',
        'mpmissions/dayzOffline.sakhal/mapgroupproto.xml',
        'profiles/AIB_Unleashed/AIB_UL_Config.json',
        'profiles/ExpansionMod/Loadouts/SniperLoadout.json',
        'profiles/ExpansionMod/Settings/AirdropSettings.json',
        'profiles/AI_Bandits/DynamicAIB.json',
        'profiles/VPPAdminTools/BanList.json',
        'mods.conf'
    )
}
$registry = @(
    @{ name = 'Server-settings'; box = 'server-settings.json'; web = 'file'; mirror = 'live' }
    @{ name = 'typesSakhal';     box = 'mpmissions/dayzOffline.sakhal/db/types.xml'; web = 'file'; mirror = 'live' }
    @{ name = 'mapGroupProtoS';  box = 'mpmissions/dayzOffline.sakhal/mapgroupproto.xml'; web = 'view'; mirror = $null }
    @{ name = 'Aib-ul-config';   box = 'profiles/AIB_Unleashed/AIB_UL_Config.json'; web = 'none'; mirror = 'live' }
    @{ name = 'loadoutsDir';     dir = 'profiles/ExpansionMod/Loadouts'; web = 'browse' }
    @{ name = 'settingsDir';     dir = 'profiles/ExpansionMod/Settings'; web = 'browse' }
)
function A([string]$rel) { Get-TodayAccess -RelPath $rel -Masks $masks -Registry $registry }

# --- writable: the OWNED_FILES exact-match path ---
Check ((A 'server-settings.json').Writable) 'an OWNED_FILES entry is writable'

# --- writable: the OWNED_DIRS prefix path ---
Check ((A 'profiles/ExpansionMod/Loadouts/SniperLoadout.json').Writable) 'a file under an OWNED_DIRS folder is writable (prefix match)'

# --- the measured prod defect: a .defaults companion is NOT writable, and today NOT readable ---
$def = A 'mpmissions/dayzOffline.sakhal/db/types.defaults.xml'
Check (-not $def.Writable) 'a .defaults companion of an OWNED_FILES row is NOT writable'
Check (-not $def.Listed)   'a .defaults companion of a FILE row is not served today (the grep -qxF defect: served=0/33)'

# --- a .defaults under an OWNED_DIR *is* reachable today (prefix match) - the asymmetry ---
Check ((A 'profiles/ExpansionMod/Settings/AirdropSettings.defaults.json').Listed) 'a .defaults under an OWNED_DIRS folder IS served today (prefix match)'

# --- generated wins over owned ---
Check (-not (A 'profiles/AI_Bandits/DynamicAIB.json').Writable) 'a generated artifact is never writable'

# --- a disabled mod target is dropped even though it is in OWNED_FILES ---
Check (-not (A 'profiles/AIB_Unleashed/AIB_UL_Config.json').Writable) "a disabled mod's config is not writable"

# --- not json/xml -> never writable through the own path ---
Check (-not (A 'mods.conf').Writable) 'a non-json/xml file is not writable through own-write'

# --- listed vs writable are different axes ---
$proto = A 'mpmissions/dayzOffline.sakhal/mapgroupproto.xml'
Check ($proto.Listed -and -not $proto.Writable) "a web:'view' row is listed but read-only"

# --- an undeclared file is invisible today. THIS is the failure WS-S inverts. ---
$vpp = A 'profiles/VPPAdminTools/BanList.json'
Check ((-not $vpp.Listed) -and (-not $vpp.Writable) -and (-not $vpp.Mirrored)) 'an undeclared file is invisible AND unmirrored today (the silent-omission failure)'

# --- mirrored follows the registry, not the masks ---
Check ((A 'mpmissions/dayzOffline.sakhal/db/types.xml').Mirrored) "mirror:'live' means mirrored"
Check (-not $proto.Mirrored) 'a row without a live mirror is not mirrored'

Write-Host "`naccess-baseline: $pass passed, $fail failed"
exit ($fail -gt 0 ? 1 : 0)
