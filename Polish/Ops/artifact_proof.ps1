param(
    [string]$RunId,
    [string]$Title = "",
    [string]$DiagRoot = "C:\\polish\\queue\\reports\\_diag_downloads",
    [string]$OutFile = ""
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Find-DiagPath {
    param([string]$RunId)
    $runRoot = Join-Path $DiagRoot $RunId
    if (-not (Test-Path $runRoot)) { return $null }
    if ($Title) {
        $candidate = Join-Path $runRoot ("buildbox_diag_{0}_{1}" -f $Title, $RunId)
        if (Test-Path $candidate) { return $candidate }
    }
    $dirs = Get-ChildItem -Path $runRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending
    if ($dirs) { return $dirs[0].FullName }
    return $null
}

function Read-JsonSafe {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try { return (Get-Content -Raw -Path $Path | ConvertFrom-Json) } catch { return $null }
}

if ([string]::IsNullOrWhiteSpace($RunId)) { throw "RunId required" }
$diag = Find-DiagPath -RunId $RunId
if (-not $diag) { Write-Host "artifact_proof: diag not found for run $RunId"; exit 1 }

$resultsRoot = Join-Path $diag "results"
$resultDir = Get-ChildItem -Path $resultsRoot -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $resultDir) { Write-Host "artifact_proof: result dir missing under $resultsRoot"; exit 1 }

$meta = Read-JsonSafe -Path (Join-Path $resultDir.FullName "meta.json")
$summary = Read-JsonSafe -Path (Join-Path $resultDir.FullName "out\\run_summary.json")
$inv = Read-JsonSafe -Path (Join-Path $resultDir.FullName "out\\invariants.json")

$telemetryTrunc = $false
if ($summary -and $summary.telemetry_summary -and $summary.telemetry_summary.top_event_types) {
    foreach ($t in $summary.telemetry_summary.top_event_types) {
        if ($t.type -eq "telemetryTruncated") { $telemetryTrunc = $true }
    }
}

$lines = @()
$lines += "artifact_proof run_id=$RunId"
$lines += "exit_reason=$($meta.exit_reason) exit_code=$($meta.exit_code)"
$lines += "scenario_id=$($meta.scenario_id) seed=$($meta.seed) commit=$($meta.commit)"
$lines += "failure_signature=$($meta.failure_signature)"
$lines += "determinism_hash=$($inv.determinism_hash)"
$lines += "telemetry_bytes=$($summary.telemetry.bytes_total) truncated=$telemetryTrunc"
$lines += "result_dir=$($resultDir.FullName)"

if ($OutFile) {
    $lines | Set-Content -Path $OutFile -Encoding ascii
    Write-Host "artifact_proof: wrote $OutFile"
} else {
    $lines | ForEach-Object { Write-Host $_ }
}

