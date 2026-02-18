param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("godgame", "space4x")]
    [string]$Project,

    [Parameter(Mandatory = $true)]
    [int]$PrNumber,

    [string]$PrRepo = "",
    [string]$WorkflowRepo = "MoniVibe/HeadlessRebuildTool",
    [string]$WorkflowFile = "buildbox_on_demand.yml",
    [string]$PuredotsRef = "",
    [string]$ScenarioRel = "",
    [string]$EnvJson = "",
    [int]$Repeat = 1,
    [switch]$CleanCache,
    [switch]$NoWaitForResult,
    [int]$ResultWaitTimeoutSec = 600,
    [string]$QueueRoot = "",
    [string]$ToolsRef = "",
    [switch]$SkipIntakeChecks
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-GhRaw {
    param([string[]]$Args)
    $output = & gh @Args
    if ($LASTEXITCODE -ne 0) {
        throw "gh command failed: gh $($Args -join ' ')"
    }
    return $output
}

function Add-PrLabel {
    param(
        [string]$Repo,
        [int]$Number,
        [string]$Label
    )
    & gh api "repos/$Repo/issues/$Number/labels" -X POST -f "labels[]=$Label" *> $null
}

function Remove-PrLabel {
    param(
        [string]$Repo,
        [int]$Number,
        [string]$Label
    )
    & gh api "repos/$Repo/issues/$Number/labels/$Label" -X DELETE *> $null
}

if ([string]::IsNullOrWhiteSpace($PrRepo)) {
    $PrRepo = if ($Project -eq "godgame") { "MoniVibe/Godgame" } else { "MoniVibe/Space4x" }
}

$dispatchStartUtc = [DateTime]::UtcNow

$prJson = Invoke-GhRaw -Args @("api", "repos/$PrRepo/pulls/$PrNumber")
$pr = $prJson | ConvertFrom-Json
$headRef = [string]$pr.head.ref
if ([string]::IsNullOrWhiteSpace($headRef)) {
    throw "PR head ref is empty for $PrRepo#$PrNumber"
}

$labels = @($pr.labels | ForEach-Object { [string]$_.name })
$body = [string]$pr.body

if (-not $SkipIntakeChecks) {
    if (-not ($labels -contains "needs-validate")) {
        throw "PR $PrRepo#$PrNumber must have label 'needs-validate' before dispatch."
    }

    $requiredSections = @(
        "## intent card",
        "### what changed",
        "### invariants",
        "### acceptance checks",
        "### risk flags",
        "### validation routing",
        "### notes for validator"
    )

    $bodyLower = if ([string]::IsNullOrWhiteSpace($body)) { "" } else { $body.ToLowerInvariant() }
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($section in $requiredSections) {
        if (-not $bodyLower.Contains($section)) {
            $missing.Add($section)
        }
    }
    if ($missing.Count -gt 0) {
        throw "PR $PrRepo#$PrNumber is missing intent card sections: $($missing -join ', ')"
    }
}

$waitForResultValue = if ($NoWaitForResult.IsPresent) { "false" } else { "true" }
$cleanCacheValue = if ($CleanCache.IsPresent) { "true" } else { "false" }

$runArgs = @(
    "workflow", "run", $WorkflowFile,
    "-R", $WorkflowRepo,
    "-f", "title=$Project",
    "-f", "ref=$headRef",
    "-f", "repeat=$Repeat",
    "-f", "wait_for_result=$waitForResultValue",
    "-f", "result_wait_timeout_sec=$ResultWaitTimeoutSec",
    "-f", "clean_cache=$cleanCacheValue",
    "-f", "source_repo=$PrRepo",
    "-f", "source_pr=$PrNumber"
)

if (-not [string]::IsNullOrWhiteSpace($PuredotsRef)) { $runArgs += @("-f", "puredots_ref=$PuredotsRef") }
if (-not [string]::IsNullOrWhiteSpace($ScenarioRel)) { $runArgs += @("-f", "scenario_rel=$ScenarioRel") }
if (-not [string]::IsNullOrWhiteSpace($EnvJson)) { $runArgs += @("-f", "env_json=$EnvJson") }
if (-not [string]::IsNullOrWhiteSpace($QueueRoot)) { $runArgs += @("-f", "queue_root=$QueueRoot") }
if (-not [string]::IsNullOrWhiteSpace($ToolsRef)) { $runArgs += @("-f", "tools_ref=$ToolsRef") }

Invoke-GhRaw -Args $runArgs | Out-Null

try {
    Add-PrLabel -Repo $PrRepo -Number $PrNumber -Label "validator-running"
} catch {
}
try {
    Remove-PrLabel -Repo $PrRepo -Number $PrNumber -Label "needs-validate"
} catch {
}

Start-Sleep -Seconds 2
$runsJson = Invoke-GhRaw -Args @(
    "run", "list",
    "-R", $WorkflowRepo,
    "--workflow", $WorkflowFile,
    "--limit", "15",
    "--json", "databaseId,createdAt,status,url,event"
)
$runs = $runsJson | ConvertFrom-Json
$candidate = $runs |
    Where-Object {
        $_.event -eq "workflow_dispatch" -and
        ([DateTime]$_.createdAt).ToUniversalTime() -ge $dispatchStartUtc.AddMinutes(-1)
    } |
    Sort-Object createdAt -Descending |
    Select-Object -First 1

$commentMarker = "<!-- validator-dispatch -->"
$summary = if ($null -ne $candidate) {
    "$commentMarker`nValidator dispatched buildbox run: $($candidate.url)`n- workflow repo: $WorkflowRepo`n- project: $Project`n- ref: $headRef"
} else {
    "$commentMarker`nValidator dispatched buildbox run for project '$Project' ref '$headRef'. (Run URL not resolved; check recent Actions in $WorkflowRepo.)"
}

try {
    & gh api "repos/$PrRepo/issues/$PrNumber/comments" -X POST -f "body=$summary" *> $null
} catch {
}

if ($null -ne $candidate) {
    Write-Host ("validator_dispatch run_id={0} status={1} url={2}" -f $candidate.databaseId, $candidate.status, $candidate.url)
} else {
    Write-Host "validator_dispatch run_id=unknown status=dispatched"
}
