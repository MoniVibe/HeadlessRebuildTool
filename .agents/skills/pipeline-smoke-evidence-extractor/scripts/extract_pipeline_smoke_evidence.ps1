[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InputPath,
    [string]$OutputRoot = "",
    [string]$Label = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Read-JsonSafe {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try {
        return (Get-Content -Raw -Path $Path | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Find-FirstEvidenceLine {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    $patterns = @("Exception", "ERROR", "FAIL", "Quit requested", "HeadlessExitSystem")
    foreach ($pattern in $patterns) {
        $hit = Select-String -Path $Path -Pattern $pattern -SimpleMatch -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $hit.Line }
    }
    return $null
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = (Resolve-Path (Join-Path $scriptDir "..\..\..\..")).Path

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $repoRoot ".agents\skills\artifacts\pipeline-smoke-evidence-extractor"
}
Ensure-Directory -Path $OutputRoot

$inputFull = (Resolve-Path $InputPath).Path
$runStamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$runSuffix = if ([string]::IsNullOrWhiteSpace($Label)) { $runStamp } else { "{0}_{1}" -f $runStamp, $Label }
$runDir = Join-Path $OutputRoot $runSuffix
Ensure-Directory -Path $runDir

$bundleRoot = $inputFull
$inputType = "directory"
if ([System.IO.Path]::GetExtension($inputFull).ToLowerInvariant() -eq ".zip") {
    $inputType = "zip"
    $expandedDir = Join-Path $runDir "expanded"
    Ensure-Directory -Path $expandedDir
    Expand-Archive -Path $inputFull -DestinationPath $expandedDir -Force
    $bundleRoot = $expandedDir
}

$metaFile = Get-ChildItem -Path $bundleRoot -Recurse -File -Filter "meta.json" -ErrorAction SilentlyContinue | Select-Object -First 1
$runSummaryFile = Get-ChildItem -Path $bundleRoot -Recurse -File -Filter "run_summary.json" -ErrorAction SilentlyContinue | Select-Object -First 1
$watchdogFile = Get-ChildItem -Path $bundleRoot -Recurse -File -Filter "watchdog.json" -ErrorAction SilentlyContinue | Select-Object -First 1
$invariantsFile = Get-ChildItem -Path $bundleRoot -Recurse -File -Filter "invariants.json" -ErrorAction SilentlyContinue | Select-Object -First 1
$playerLogFile = Get-ChildItem -Path $bundleRoot -Recurse -File -Filter "player.log" -ErrorAction SilentlyContinue | Select-Object -First 1
$stdoutLogFile = Get-ChildItem -Path $bundleRoot -Recurse -File -Filter "stdout.log" -ErrorAction SilentlyContinue | Select-Object -First 1
$stderrLogFile = Get-ChildItem -Path $bundleRoot -Recurse -File -Filter "stderr.log" -ErrorAction SilentlyContinue | Select-Object -First 1
$buildOutcomeFile = Get-ChildItem -Path $bundleRoot -Recurse -File -Filter "build_outcome.json" -ErrorAction SilentlyContinue | Select-Object -First 1

$meta = if ($metaFile) { Read-JsonSafe -Path $metaFile.FullName } else { $null }
$runSummary = if ($runSummaryFile) { Read-JsonSafe -Path $runSummaryFile.FullName } else { $null }
$watchdog = if ($watchdogFile) { Read-JsonSafe -Path $watchdogFile.FullName } else { $null }
$invariants = if ($invariantsFile) { Read-JsonSafe -Path $invariantsFile.FullName } else { $null }
$buildOutcome = if ($buildOutcomeFile) { Read-JsonSafe -Path $buildOutcomeFile.FullName } else { $null }

$bundleKind = "unknown"
if ($meta -or $runSummary -or $watchdog) { $bundleKind = "result" }
elseif ($buildOutcome) { $bundleKind = "artifact" }

$exitReason = ""
$exitCode = $null
$failureSignature = ""
$rawSignature = ""

if ($bundleKind -eq "result") {
    if ($meta -and $meta.exit_reason) { $exitReason = [string]$meta.exit_reason }
    if ($meta -and $meta.PSObject.Properties["exit_code"]) { $exitCode = $meta.exit_code }
    if ($meta -and $meta.failure_signature) { $failureSignature = [string]$meta.failure_signature }
    if ($watchdog -and $watchdog.raw_signature_string) { $rawSignature = [string]$watchdog.raw_signature_string }
}
elseif ($bundleKind -eq "artifact") {
    if ($buildOutcome -and $buildOutcome.result) { $exitReason = [string]$buildOutcome.result }
    if ($buildOutcome -and $buildOutcome.message) { $failureSignature = [string]$buildOutcome.message }
}

$failingInvariantIds = New-Object System.Collections.Generic.List[string]
if ($runSummary -and $runSummary.failing_invariants) {
    foreach ($inv in $runSummary.failing_invariants) {
        if ($null -ne $inv -and "$inv".Trim() -ne "") { $failingInvariantIds.Add([string]$inv) }
    }
}
if ($invariants -and $invariants.invariants) {
    foreach ($inv in $invariants.invariants) {
        $status = if ($inv.status) { [string]$inv.status } else { "" }
        if ($status -and $status -ne "PASS" -and $inv.id) {
            $failingInvariantIds.Add([string]$inv.id)
        }
    }
}
$failingInvariantIds = @($failingInvariantIds | Sort-Object -Unique)

$summary = [ordered]@{
    schema_version = 1
    generated_utc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    input_path = $inputFull
    input_type = $inputType
    bundle_kind = $bundleKind
    exit_reason = $exitReason
    exit_code = $exitCode
    failure_signature = $failureSignature
    raw_signature = $rawSignature
    failing_invariants = $failingInvariantIds
    evidence_lines = [ordered]@{
        player_log_first = if ($playerLogFile) { Find-FirstEvidenceLine -Path $playerLogFile.FullName } else { $null }
        stdout_log_first = if ($stdoutLogFile) { Find-FirstEvidenceLine -Path $stdoutLogFile.FullName } else { $null }
        stderr_log_first = if ($stderrLogFile) { Find-FirstEvidenceLine -Path $stderrLogFile.FullName } else { $null }
    }
    evidence_files = [ordered]@{
        meta = if ($metaFile) { $metaFile.FullName } else { "" }
        run_summary = if ($runSummaryFile) { $runSummaryFile.FullName } else { "" }
        watchdog = if ($watchdogFile) { $watchdogFile.FullName } else { "" }
        invariants = if ($invariantsFile) { $invariantsFile.FullName } else { "" }
        player_log = if ($playerLogFile) { $playerLogFile.FullName } else { "" }
        stdout_log = if ($stdoutLogFile) { $stdoutLogFile.FullName } else { "" }
        stderr_log = if ($stderrLogFile) { $stderrLogFile.FullName } else { "" }
        build_outcome = if ($buildOutcomeFile) { $buildOutcomeFile.FullName } else { "" }
    }
}

$summaryPath = Join-Path $runDir "evidence_summary.json"
$summary | ConvertTo-Json -Depth 10 | Set-Content -Path $summaryPath -Encoding ascii

$reportLines = New-Object System.Collections.Generic.List[string]
$reportLines.Add("# Pipeline Smoke Evidence Report")
$reportLines.Add("")
$reportLines.Add(("* generated_utc: {0}" -f $summary.generated_utc))
$reportLines.Add(("* input_path: {0}" -f $summary.input_path))
$reportLines.Add(("* bundle_kind: {0}" -f $summary.bundle_kind))
$reportLines.Add(("* exit_reason: {0}" -f $summary.exit_reason))
$reportLines.Add(("* exit_code: {0}" -f $(if ($null -ne $summary.exit_code) { $summary.exit_code } else { "" })))
$reportLines.Add(("* failure_signature: {0}" -f $summary.failure_signature))
$reportLines.Add(("* raw_signature: {0}" -f $summary.raw_signature))
$reportLines.Add("")
$reportLines.Add("## Failing Invariants")
if ($summary.failing_invariants.Count -gt 0) {
    foreach ($invId in $summary.failing_invariants) { $reportLines.Add("- $invId") }
}
else {
    $reportLines.Add("- (none)")
}
$reportLines.Add("")
$reportLines.Add("## Evidence Files")
$reportLines.Add(("- meta: {0}" -f $summary.evidence_files.meta))
$reportLines.Add(("- run_summary: {0}" -f $summary.evidence_files.run_summary))
$reportLines.Add(("- watchdog: {0}" -f $summary.evidence_files.watchdog))
$reportLines.Add(("- invariants: {0}" -f $summary.evidence_files.invariants))
$reportLines.Add(("- player_log: {0}" -f $summary.evidence_files.player_log))
$reportLines.Add(("- stdout_log: {0}" -f $summary.evidence_files.stdout_log))
$reportLines.Add(("- stderr_log: {0}" -f $summary.evidence_files.stderr_log))
$reportLines.Add(("- build_outcome: {0}" -f $summary.evidence_files.build_outcome))

$reportPath = Join-Path $runDir "evidence_report.md"
$reportLines | Set-Content -Path $reportPath -Encoding ascii

Write-Host ("evidence_summary={0}" -f $summaryPath)
Write-Host ("evidence_report={0}" -f $reportPath)
