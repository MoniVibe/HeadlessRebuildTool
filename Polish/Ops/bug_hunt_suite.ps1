[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('space4x', 'godgame')]
    [string]$Title = 'space4x',
    [Parameter(Mandatory = $false)]
    [string]$Ref = 'main',
    [string]$PuredotsRef = '',
    [string]$QueueRoot = '',
    [string[]]$ScenarioRels,
    [int]$Repeat = 1,
    [switch]$WaitForResult,
    [string]$Disable = '',
    [string]$EnvJson = '',
    [string]$WorkflowRef = '',
    [string]$ToolsRef = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-ScenarioDefaults {
    param([string]$Title)
    if ($Title -eq 'godgame') {
        return @(
            'Assets/Scenarios/Godgame/godgame_smoke.json'
        )
    }

    return @(
        'Assets/Scenarios/space4x_bug_hunt_headless.json',
        'Assets/Scenarios/space4x_collision_micro.json',
        'Assets/Scenarios/space4x_turnrate_micro.json',
        'Assets/Scenarios/space4x_comms_micro.json',
        'Assets/Scenarios/space4x_sensors_micro.json',
        'Assets/Scenarios/space4x_dogfight_headless.json'
    )
}

function Build-EnvJson {
    param([string]$Disable, [string]$EnvJson)
    if (-not [string]::IsNullOrWhiteSpace($EnvJson)) {
        return $EnvJson
    }
    $map = [ordered]@{
        PUREDOTS_BUGHUNT = '1'
        PUREDOTS_SHUTDOWN_AUDIT = '1'
    }
    if (-not [string]::IsNullOrWhiteSpace($Disable)) {
        $map.PUREDOTS_BUGHUNT_DISABLE = $Disable
    }
    return ($map | ConvertTo-Json -Compress)
}

$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$trigger = Join-Path $root '.cursor\skills\buildbox-iterate\scripts\trigger_buildbox.ps1'
if (-not (Test-Path $trigger)) {
    throw "trigger_buildbox.ps1 not found: $trigger"
}

if (-not $ScenarioRels -or $ScenarioRels.Count -eq 0) {
    $ScenarioRels = Resolve-ScenarioDefaults -Title $Title
}

$envJsonValue = Build-EnvJson -Disable $Disable -EnvJson $EnvJson

foreach ($scenarioRel in $ScenarioRels) {
    if ([string]::IsNullOrWhiteSpace($scenarioRel)) { continue }
    Write-Host ("queue scenario={0}" -f $scenarioRel)
    $args = @{
        Title = $Title
        Ref = $Ref
        Repeat = $Repeat
        ScenarioRel = $scenarioRel
        EnvJson = $envJsonValue
    }
    if ($WaitForResult) { $args.WaitForResult = $true }
    if (-not [string]::IsNullOrWhiteSpace($QueueRoot)) { $args.QueueRoot = $QueueRoot }
    if (-not [string]::IsNullOrWhiteSpace($PuredotsRef)) { $args.PuredotsRef = $PuredotsRef }
    if (-not [string]::IsNullOrWhiteSpace($WorkflowRef)) { $args.WorkflowRef = $WorkflowRef }
    if (-not [string]::IsNullOrWhiteSpace($ToolsRef)) { $args.ToolsRef = $ToolsRef }
    & $trigger @args
}
