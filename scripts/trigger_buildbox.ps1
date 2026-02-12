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
    [string]$QueueRoot = '',
    [string]$ScenarioRel = '',
    [string]$EnvJson = '',
    [string]$PuredotsRef = '',
    [string]$ToolsRef = '',
    [string]$Repo = 'MoniVibe/HeadlessRebuildTool',
    [string]$Workflow = 'buildbox_on_demand.yml',
    [string]$WorkflowRef = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Require-Gh {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw "GitHub CLI (gh) not found in PATH."
    }
}

function Invoke-GhJson {
    param([string[]]$GhArgs)
    $raw = & gh @GhArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ("gh failed: {0}" -f ($raw -join "`n"))
    }
    if (-not $raw) { return $null }
    $joined = ($raw -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($joined)) { return $null }
    $first = $joined.Substring(0, 1)
    if ($first -ne '{' -and $first -ne '[') {
        throw ("gh returned non-json output: {0}" -f $joined)
    }
    return ($joined | ConvertFrom-Json)
}

Require-Gh

$inputs = [ordered]@{
    title = $Title
    ref = $Ref
    repeat = "$Repeat"
    wait_for_result = ($(if ($WaitForResult) { 'true' } else { 'false' }))
    clean_cache = ($(if ($CleanCache) { 'true' } else { 'false' }))
}
if (-not [string]::IsNullOrWhiteSpace($QueueRoot)) { $inputs.queue_root = $QueueRoot }
if (-not [string]::IsNullOrWhiteSpace($ScenarioRel)) { $inputs.scenario_rel = $ScenarioRel }
if (-not [string]::IsNullOrWhiteSpace($EnvJson)) { $inputs.env_json = $EnvJson }
if (-not [string]::IsNullOrWhiteSpace($PuredotsRef)) { $inputs.puredots_ref = $PuredotsRef }
if (-not [string]::IsNullOrWhiteSpace($ToolsRef)) { $inputs.tools_ref = $ToolsRef }

Write-Host ("enqueue_request title={0} ref={1} queue_root={2} scenario_rel={3} puredots_ref={4} tools_ref={5} workflow_ref={6}" -f `
    $Title, $Ref, $QueueRoot, $ScenarioRel, $PuredotsRef, $ToolsRef, $WorkflowRef)

$ghArgs = @('workflow', 'run', $Workflow, '-R', $Repo)
if (-not [string]::IsNullOrWhiteSpace($WorkflowRef)) { $ghArgs += @('--ref', $WorkflowRef) }
foreach ($item in $inputs.GetEnumerator()) {
    $ghArgs += @('-f', ("{0}={1}" -f $item.Key, $item.Value))
}

$startUtc = [DateTimeOffset]::UtcNow
& gh @ghArgs | Out-Null
Start-Sleep -Seconds 2

$runs = Invoke-GhJson @(
    'run', 'list',
    '-R', $Repo,
    '-w', $Workflow,
    '-L', '10',
    '--json', 'databaseId,url,status,conclusion,event,createdAt,headBranch'
)

$run = $null
if ($runs) {
    $expectedHeadBranch = if (-not [string]::IsNullOrWhiteSpace($WorkflowRef)) { $WorkflowRef } else { $Ref }
    $recent = $runs | Where-Object {
        $_.event -eq 'workflow_dispatch' -and $_.createdAt
    } | Where-Object {
        try { [DateTimeOffset]::Parse($_.createdAt) -ge $startUtc.AddMinutes(-2) } catch { $false }
    }
    if (-not [string]::IsNullOrWhiteSpace($expectedHeadBranch)) {
        $recent = $recent | Where-Object { $_.headBranch -eq $expectedHeadBranch }
    }
    $run = $recent | Sort-Object createdAt -Descending | Select-Object -First 1
    if (-not $run) {
        $run = $runs | Where-Object { $_.event -eq 'workflow_dispatch' } | Sort-Object createdAt -Descending | Select-Object -First 1
    }
}

if ($run) {
    Write-Host ("run_id={0}" -f $run.databaseId)
    if ($run.url) { Write-Host ("run_url={0}" -f $run.url) }
    if ($WaitForResult) {
        & gh run watch $run.databaseId -R $Repo --exit-status
    } else {
        Write-Host ("status={0}" -f $run.status)
    }
} else {
    Write-Host "run_id=unknown"
    Write-Host "run_url=unknown"
}
