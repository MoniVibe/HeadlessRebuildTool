param(
    [Parameter(Mandatory = $true)]
    [string]$ResultDir,
    [string]$OutPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Read-JsonIfExists {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    return (Get-Content -Raw -Path $Path | ConvertFrom-Json)
}

function Read-Tail {
    param([string]$Path, [int]$Lines = 6)
    if (-not (Test-Path $Path)) { return @() }
    return Get-Content -Path $Path -Tail $Lines
}

function Find-FirstMatch {
    param(
        [string]$Path,
        [string[]]$Patterns
    )
    if (-not (Test-Path $Path)) { return $null }
    foreach ($pattern in $Patterns) {
        $match = Select-String -Path $Path -Pattern $pattern -SimpleMatch -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($match) { return $match.Line }
    }
    return $null
}

$resultFull = (Resolve-Path $ResultDir).Path
$outPathResolved = if ($OutPath) { $OutPath } else { Join-Path $resultFull "diag_summary.md" }

$meta = Read-JsonIfExists -Path (Join-Path $resultFull "meta.json")
$runSummary = Read-JsonIfExists -Path (Join-Path $resultFull "out\\run_summary.json")
$watchdog = Read-JsonIfExists -Path (Join-Path $resultFull "out\\watchdog.json")
$invariants = Read-JsonIfExists -Path (Join-Path $resultFull "out\\invariants.json")

$playerLog = Join-Path $resultFull "out\\player.log"
$stdoutLog = Join-Path $resultFull "out\\stdout.log"
$stderrLog = Join-Path $resultFull "out\\stderr.log"
$stdoutTail = Join-Path $resultFull "out\\diag_stdout_tail.txt"
$stderrTail = Join-Path $resultFull "out\\diag_stderr_tail.txt"

$failInv = @()
if ($invariants -and $invariants.invariants) {
    foreach ($inv in $invariants.invariants) {
        if ($inv.status -and $inv.status -ne "PASS") {
            $failInv += $inv
        }
    }
}

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("# Diag Summary")
$lines.Add("")

if ($meta) {
    $lines.Add("* scenario_id: $($meta.scenario_id)")
    $lines.Add("* seed: $($meta.seed)")
    $lines.Add("* exit_code: $($meta.exit_code)")
    $lines.Add("* exit_reason: $($meta.exit_reason)")
    if ($meta.failure_signature) { $lines.Add("* failure_signature: $($meta.failure_signature)") }
    if ($meta.commit) { $lines.Add("* commit: $($meta.commit)") }
    if ($meta.build_id) { $lines.Add("* build_id: $($meta.build_id)") }
}

if ($watchdog) {
    if ($watchdog.raw_signature_string) { $lines.Add("* raw_signature: $($watchdog.raw_signature_string)") }
    if ($watchdog.exit_reason) { $lines.Add("* watchdog_exit_reason: $($watchdog.exit_reason)") }
}

if ($runSummary) {
    if ($runSummary.runtime_sec) { $lines.Add("* runtime_sec: $($runSummary.runtime_sec)") }
    if ($runSummary.telemetry_summary -and $runSummary.telemetry_summary.event_total) {
        $lines.Add("* telemetry_event_total: $($runSummary.telemetry_summary.event_total)")
    }
    if ($runSummary.telemetry -and $runSummary.telemetry.bytes_total) {
        $lines.Add("* telemetry_bytes: $($runSummary.telemetry.bytes_total)")
    }
}

if ($failInv.Count -gt 0) {
    $lines.Add("")
    $lines.Add("## Failing Invariants")
    foreach ($inv in $failInv) {
        $id = $inv.id
        $status = $inv.status
        $obs = $inv.observed
        $exp = $inv.expected
        $lines.Add("- $id status=$status observed=$obs expected=$exp")
    }
}

$evidencePatterns = @(
    "Exception",
    "ERROR",
    "Error",
    "FAIL",
    "Quit requested",
    "Scenario duration reached",
    "required questions",
    "HeadlessExitSystem"
)

$playerFirst = Find-FirstMatch -Path $playerLog -Patterns $evidencePatterns
$stdoutFirst = Find-FirstMatch -Path $stdoutLog -Patterns $evidencePatterns
$stderrFirst = Find-FirstMatch -Path $stderrLog -Patterns $evidencePatterns

$lines.Add("")
$lines.Add("## Evidence")
if ($playerFirst) { $lines.Add("* player_log_first: $playerFirst") }
if ($stdoutFirst) { $lines.Add("* stdout_first: $stdoutFirst") }
if ($stderrFirst) { $lines.Add("* stderr_first: $stderrFirst") }

if (Test-Path $stdoutTail) {
    $lines.Add("")
    $lines.Add("### stdout_tail")
    foreach ($line in (Read-Tail -Path $stdoutTail -Lines 8)) { $lines.Add($line) }
}

if (Test-Path $stderrTail) {
    $lines.Add("")
    $lines.Add("### stderr_tail")
    foreach ($line in (Read-Tail -Path $stderrTail -Lines 8)) { $lines.Add($line) }
}

if (Test-Path $playerLog) {
    $lines.Add("")
    $lines.Add("### player_log_tail")
    foreach ($line in (Read-Tail -Path $playerLog -Lines 8)) { $lines.Add($line) }
}

$lines | Set-Content -Path $outPathResolved -Encoding ascii
Write-Host ("diag_summary={0}" -f $outPathResolved)
