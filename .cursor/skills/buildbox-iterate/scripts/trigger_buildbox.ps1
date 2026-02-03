[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('space4x', 'godgame')]
    [string]$Title,
    [Parameter(Mandatory = $true)]
    [string]$Ref,
    [int]$Repeat = 1,
    [switch]$WaitForResult,
    [switch]$CleanCache,
    [string]$QueueRoot = "",
    [string]$PuredotsRef = "",
    [string]$ScenarioRel = "",
    [string]$WorkflowRef = "",
    [string]$EnvJson = "",
    [string]$Repo = "MoniVibe/HeadlessRebuildTool",
    [string]$Workflow = "buildbox_on_demand.yml",
    [int]$PollSec = 10,
    [int]$TimeoutSec = 600
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Convert-ToUtc {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return [DateTime]::MinValue }
    try {
        return [DateTimeOffset]::Parse(
            $Value,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal
        ).UtcDateTime
    } catch {
        try {
            return [DateTimeOffset]::Parse($Value).UtcDateTime
        } catch {
            return [DateTime]::MinValue
        }
    }
}

function Require-Gh {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw "GitHub CLI (gh) not found. Install gh and run 'gh auth login'."
    }
}

function Get-WorkflowRuns {
    param(
        [string]$RepoName,
        [string]$WorkflowName
    )
    $json = & gh api "/repos/$RepoName/actions/workflows/$WorkflowName/runs?per_page=10"
    if ([string]::IsNullOrWhiteSpace($json)) { return @() }
    return (ConvertFrom-Json $json).workflow_runs
}

function Get-RunById {
    param(
        [string]$RepoName,
        [long]$RunId
    )
    $json = & gh api "/repos/$RepoName/actions/runs/$RunId"
    if ([string]::IsNullOrWhiteSpace($json)) { return $null }
    return (ConvertFrom-Json $json)
}

Require-Gh

$start = Get-Date

$inputArgs = @(
    "title=$Title",
    "ref=$Ref",
    "repeat=$Repeat",
    ("wait_for_result={0}" -f ($(if ($WaitForResult) { "true" } else { "false" }))),
    ("clean_cache={0}" -f ($(if ($CleanCache) { "true" } else { "false" })))
)
if (-not [string]::IsNullOrWhiteSpace($QueueRoot)) {
    $inputArgs += "queue_root=$QueueRoot"
}
if (-not [string]::IsNullOrWhiteSpace($PuredotsRef)) {
    $inputArgs += "puredots_ref=$PuredotsRef"
}
if (-not [string]::IsNullOrWhiteSpace($ScenarioRel)) {
    $inputArgs += "scenario_rel=$ScenarioRel"
}
if (-not [string]::IsNullOrWhiteSpace($EnvJson)) {
    $inputArgs += "env_json=$EnvJson"
}

$ghArgs = @("workflow", "run", $Workflow, "-R", $Repo)
if (-not [string]::IsNullOrWhiteSpace($WorkflowRef)) {
    $ghArgs += @("--ref", $WorkflowRef)
}
foreach ($arg in $inputArgs) {
    $ghArgs += @("-f", $arg)
}

& gh @ghArgs | Out-Null

$deadline = (Get-Date).AddSeconds($TimeoutSec)
$run = $null
while ($null -eq $run -and (Get-Date) -lt $deadline) {
    $runs = Get-WorkflowRuns -RepoName $Repo -WorkflowName $Workflow
    $run = $runs | Where-Object {
        (Convert-ToUtc $_.created_at) -ge $start.ToUniversalTime().AddSeconds(-10)
    } | Select-Object -First 1
    if ($null -eq $run) { Start-Sleep -Seconds 3 }
}

if ($null -eq $run) {
    Write-Host "run_id=UNKNOWN"
    exit 1
}

Write-Host "run_id=$($run.id)"
Write-Host "run_url=$($run.html_url)"
Write-Host "status=$($run.status)"

if ($WaitForResult) {
    $runId = [long]$run.id
    while ((Get-Date) -lt $deadline) {
        $current = Get-RunById -RepoName $Repo -RunId $runId
        if ($null -eq $current) { Start-Sleep -Seconds $PollSec; continue }
        if ($current.status -eq "completed") {
            Write-Host "status=$($current.status)"
            Write-Host "conclusion=$($current.conclusion)"
            exit 0
        }
        Start-Sleep -Seconds $PollSec
    }
    Write-Host "status=timeout"
    exit 2
}
