[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Repo,
    [Parameter(Mandatory = $true)]
    [string]$Branch,
    [Parameter(Mandatory = $true)]
    [string]$GoalId,
    [Parameter(Mandatory = $true)]
    [string]$ScenarioId,
    [string[]]$JobIds,
    [string[]]$ResultZips,
    [string]$WorkspaceRoot = "C:\\Dev\\unity_clean",
    [string]$QueueRoot = "C:\\polish\\queue",
    [string]$OutputRoot = "C:\\dev\\Tri\\reports"
)

$ErrorActionPreference = "Stop"

function Get-OptionalProp {
    param(
        [object]$Object,
        [string]$Name
    )
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Normalize-JobIdFromZip {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $name = [System.IO.Path]::GetFileName($Path)
    if ($name -match '^result_(.+)\.zip$') {
        return $Matches[1]
    }
    return $null
}

function Format-PathLine {
    param(
        [string]$Label,
        [string]$Path
    )
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return "- $Label: (missing)"
    }
    if (Test-Path $Path) {
        return "- $Label: $Path"
    }
    return "- $Label: $Path (missing)"
}

if (-not $JobIds -and -not $ResultZips) {
    throw "Provide JobIds or ResultZips."
}

$repoPath = Join-Path $WorkspaceRoot $Repo
if (-not (Test-Path $repoPath)) { throw "Repo path not found: $repoPath" }

$commitRef = $Branch
$commitFull = & git -C $repoPath rev-parse $commitRef 2>$null
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($commitFull)) {
    $commitRef = "HEAD"
    $commitFull = & git -C $repoPath rev-parse $commitRef 2>$null
}
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($commitFull)) {
    throw "Unable to resolve commit for $Repo at $Branch."
}
$commitFull = $commitFull.Trim()
$commitShort = (& git -C $repoPath rev-parse --short=8 $commitFull).Trim()
$summary = (& git -C $repoPath show -s --format="%h %s" $commitFull).Trim()
$statLines = & git -C $repoPath show --stat --oneline -1 $commitFull 2>$null

$resultsDir = Join-Path $QueueRoot "results"
$intelDir = Join-Path $QueueRoot "reports\\intel"
$headline = Get-ChildItem -Path (Join-Path $QueueRoot "reports") -Filter "nightly_headline_*.md" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1

$jobIdSet = New-Object System.Collections.Generic.HashSet[string]
$zipPaths = New-Object System.Collections.Generic.List[string]

foreach ($zip in $ResultZips) {
    if ([string]::IsNullOrWhiteSpace($zip)) { continue }
    $zipPaths.Add($zip)
    $jobId = Normalize-JobIdFromZip -Path $zip
    if ($jobId) { $null = $jobIdSet.Add($jobId) }
}

foreach ($jobId in $JobIds) {
    if ([string]::IsNullOrWhiteSpace($jobId)) { continue }
    $null = $jobIdSet.Add($jobId)
    $zipPath = Join-Path $resultsDir ("result_{0}.zip" -f $jobId)
    if (-not $zipPaths.Contains($zipPath)) {
        $zipPaths.Add($zipPath)
    }
}

$jobIdsResolved = @($jobIdSet)
if ($jobIdsResolved.Count -eq 0) { throw "No job ids resolved from inputs." }

$explainPaths = @()
$questionPaths = @()
foreach ($jobId in $jobIdsResolved) {
    $explainPaths += (Join-Path $intelDir ("explain_{0}.json" -f $jobId))
    $questionPaths += (Join-Path $intelDir ("questions_{0}.json" -f $jobId))
}

$verdict = "VERDICT: UNKNOWN (missing explain)"
foreach ($explainPath in $explainPaths) {
    if (-not (Test-Path $explainPath)) { continue }
    $explain = Get-Content -Raw -Path $explainPath | ConvertFrom-Json
    $validity = Get-OptionalProp $explain "validity"
    $nextAction = Get-OptionalProp $explain "next_action"
    $questionSummary = Get-OptionalProp $explain "question_summary"
    $required = if ($questionSummary) { Get-OptionalProp $questionSummary "required" } else { $null }
    $requiredPass = if ($required) { Get-OptionalProp $required "pass" } else { $null }
    $requiredUnknown = if ($required) { Get-OptionalProp $required "unknown" } else { $null }
    $validityText = if ($validity) { $validity } else { "UNKNOWN" }
    $passText = if ($requiredPass -ne $null) { $requiredPass } else { "?" }
    $unknownText = if ($requiredUnknown -ne $null) { $requiredUnknown } else { "?" }
    $nextText = if ($nextAction) { $nextAction } else { "n/a" }
    $jobTag = Normalize-JobIdFromZip -Path $explainPath
    if (-not $jobTag) { $jobTag = $jobIdsResolved[0] }
    $verdict = "VERDICT: validity=$validityText required_pass=$passText required_unknown=$unknownText next=$nextText job=$jobTag"
    break
}

if (-not (Test-Path $OutputRoot)) {
    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
}

$goalSlug = ($GoalId -replace '[^A-Za-z0-9._-]', '_')
$timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmm")
$outputPath = Join-Path $OutputRoot ("pr_ready_{0}_{1}.md" -f $goalSlug, $timestamp)

$lines = @()
$lines += "# PR Evidence Pack"
$lines += ""
$lines += "- repo: $repoPath"
$lines += "- branch: $Branch"
$lines += "- commit: $commitFull"
$lines += ""
$lines += "## Change summary"
$lines += $summary
if ($statLines) {
    $lines += ""
    $lines += "``````"
    $lines += $statLines
    $lines += "``````"
}
$lines += ""
$lines += "## Goal / Scenario"
$lines += "- goal_id: $GoalId"
$lines += "- scenario_id: $ScenarioId"
$lines += ""
$lines += "## Evidence"
foreach ($zip in $zipPaths) {
    $lines += (Format-PathLine -Label "result_zip" -Path $zip)
}
foreach ($path in $explainPaths) {
    $lines += (Format-PathLine -Label "explain_json" -Path $path)
}
foreach ($path in $questionPaths) {
    $lines += (Format-PathLine -Label "questions_json" -Path $path)
}
if ($headline) {
    $lines += (Format-PathLine -Label "nightly_headline" -Path $headline.FullName)
} else {
    $lines += "- nightly_headline: (missing)"
}
$lines += ""
$lines += $verdict

$lines | Set-Content -Path $outputPath -Encoding ascii
Write-Host $outputPath
