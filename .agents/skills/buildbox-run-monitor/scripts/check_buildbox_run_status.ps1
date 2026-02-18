[CmdletBinding()]
param(
    [long]$RunId = 0,
    [ValidateSet("space4x", "godgame")]
    [string]$Title,
    [string]$Ref = "",
    [string]$Repo = "MoniVibe/HeadlessRebuildTool",
    [string]$Workflow = "buildbox_on_demand.yml"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Require-Gh {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw "GitHub CLI (gh) not found. Install gh and run 'gh auth login'."
    }
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Resolve-RepoRoot {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    return (Resolve-Path (Join-Path $scriptDir "..\..\..\..")).Path
}

function Get-RunByRef {
    param(
        [string]$RepoValue,
        [string]$WorkflowValue,
        [string]$RefValue
    )
    $runsJson = & gh run list -R $RepoValue -w $WorkflowValue -L 25 --json databaseId,status,conclusion,headBranch,url,createdAt,updatedAt
    $runs = $runsJson | ConvertFrom-Json
    if (-not $runs) { return $null }
    $filtered = $runs
    if (-not [string]::IsNullOrWhiteSpace($RefValue)) {
        $filtered = @($runs | Where-Object { $_.headBranch -eq $RefValue })
    }
    return @($filtered | Sort-Object createdAt -Descending | Select-Object -First 1)[0]
}

Require-Gh

$repoRoot = Resolve-RepoRoot
$artifactDir = Join-Path $repoRoot ".agents\skills\artifacts\buildbox-run-monitor"
Ensure-Directory -Path $artifactDir

$resolvedRunId = $RunId
if ($resolvedRunId -le 0) {
    $run = Get-RunByRef -RepoValue $Repo -WorkflowValue $Workflow -RefValue $Ref
    if (-not $run) {
        throw "No matching run found for workflow '$Workflow' and ref '$Ref'."
    }
    $resolvedRunId = [long]$run.databaseId
}

$runJson = & gh run view $resolvedRunId -R $Repo --json databaseId,status,conclusion,url,workflowName,headBranch,headSha,createdAt,updatedAt
$runInfo = $runJson | ConvertFrom-Json

$artifactsJson = & gh api "/repos/$Repo/actions/runs/$resolvedRunId/artifacts"
$artifactData = $artifactsJson | ConvertFrom-Json
$artifacts = @()
if ($artifactData -and $artifactData.artifacts) {
    $artifacts = @($artifactData.artifacts)
}

$diagPrefix = if ($Title) { "buildbox_diag_$Title" } else { "buildbox_diag" }
$diagArtifact = @($artifacts | Where-Object { $_.name -like "$diagPrefix*" } | Sort-Object created_at -Descending | Select-Object -First 1)[0]

$nextSkill = "buildbox-run-monitor"
$nextReason = "run still active"
if ($runInfo.status -eq "completed") {
    if ($diagArtifact) {
        $nextSkill = "buildbox-diag-triage"
        $nextReason = "completed run with diagnostics available"
    }
    else {
        $nextSkill = "buildbox-dispatch"
        $nextReason = "completed run has no diagnostics artifact; inspect logs and decide retry"
    }
}

$statusObj = [ordered]@{
    schema_version = 1
    generated_utc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    repo = $Repo
    workflow = $Workflow
    run = [ordered]@{
        id = $runInfo.databaseId
        url = $runInfo.url
        status = $runInfo.status
        conclusion = $runInfo.conclusion
        head_branch = $runInfo.headBranch
        head_sha = $runInfo.headSha
        created_at = $runInfo.createdAt
        updated_at = $runInfo.updatedAt
    }
    diagnostics = [ordered]@{
        expected_prefix = $diagPrefix
        found = [bool]$diagArtifact
        artifact_name = if ($diagArtifact) { $diagArtifact.name } else { "" }
        artifact_id = if ($diagArtifact) { $diagArtifact.id } else { "" }
    }
    next_skill = $nextSkill
    next_reason = $nextReason
}

$stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$statusPath = Join-Path $artifactDir ("monitor_status_{0}.json" -f $stamp)
$reportPath = Join-Path $artifactDir ("monitor_report_{0}.md" -f $stamp)
$statusObj | ConvertTo-Json -Depth 8 | Set-Content -Path $statusPath -Encoding ascii

$report = @(
    "# Buildbox Run Monitor",
    "",
    "* run_id: $($statusObj.run.id)",
    "* run_url: $($statusObj.run.url)",
    "* status: $($statusObj.run.status)",
    "* conclusion: $($statusObj.run.conclusion)",
    "* diagnostics_found: $($statusObj.diagnostics.found)",
    "* diagnostics_artifact: $($statusObj.diagnostics.artifact_name)",
    "* next_skill: $($statusObj.next_skill)",
    "* next_reason: $($statusObj.next_reason)"
)
$report | Set-Content -Path $reportPath -Encoding ascii

Write-Host ("monitor_status={0}" -f $statusPath)
Write-Host ("monitor_report={0}" -f $reportPath)
