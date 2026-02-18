[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$QueueRoot,
    [ValidateSet("space4x", "godgame")]
    [string]$Title,
    [int]$Limit = 25,
    [string]$WslDistro = "Ubuntu",
    [string]$WslRepoRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-RepoRoot {
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $resolved = Resolve-Path (Join-Path $scriptDir "..\..\..\..")
    if ($resolved -is [string]) { return $resolved }
    return @($resolved)[0].Path
}

function Convert-ToWslPath {
    param([string]$PathValue)
    if ([string]::IsNullOrWhiteSpace($PathValue)) { return "" }
    $full = [System.IO.Path]::GetFullPath($PathValue)
    $m = [regex]::Match($full, '^([A-Za-z]):\\(.*)$')
    if ($m.Success) {
        $d = $m.Groups[1].Value.ToLowerInvariant()
        $rest = $m.Groups[2].Value -replace '\\', '/'
        return "/mnt/$d/$rest"
    }
    return ($full -replace '\\', '/')
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

$repoRoot = Resolve-RepoRoot
$queueFull = [System.IO.Path]::GetFullPath($QueueRoot)
$resultsDir = Join-Path $queueFull "results"
$reportsDir = Join-Path $queueFull "reports"
$intelDir = Join-Path $reportsDir "intel"
Ensure-Directory -Path $reportsDir
Ensure-Directory -Path $intelDir

if (-not (Test-Path $resultsDir)) {
    throw "Results directory not found: $resultsDir"
}

if ([string]::IsNullOrWhiteSpace($WslRepoRoot)) {
    $WslRepoRoot = Convert-ToWslPath -PathValue $repoRoot
}

$resultZips = @(Get-ChildItem -Path $resultsDir -File -Filter "result_*.zip" | Sort-Object LastWriteTime -Descending | Select-Object -First $Limit)
if ($resultZips.Count -eq 0) {
    throw "No result_*.zip files found in $resultsDir"
}

$ingested = 0
foreach ($zip in $resultZips) {
    $zipWsl = Convert-ToWslPath -PathValue $zip.FullName
    $ingestCmd = "python3 $WslRepoRoot/Polish/Intel/anviloop_intel.py ingest-result-zip --result-zip $zipWsl"
    & wsl.exe -d $WslDistro -- bash -lc $ingestCmd 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $ingested += 1
    }
}

$resultsWsl = Convert-ToWslPath -PathValue $resultsDir
$reportsWsl = Convert-ToWslPath -PathValue $reportsDir
$intelWsl = Convert-ToWslPath -PathValue $intelDir
$scoreCmd = "python3 $WslRepoRoot/Polish/Goals/scoreboard.py --results-dir $resultsWsl --reports-dir $reportsWsl --intel-dir $intelWsl --limit $Limit"
& wsl.exe -d $WslDistro -- bash -lc $scoreCmd 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "scoreboard.py failed for queue root: $queueFull"
}

$headline = Get-ChildItem -Path $reportsDir -File -Filter "nightly_headline_*.md" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$summaryDir = Join-Path $repoRoot ".agents\skills\artifacts\intel-scoreboard-review"
Ensure-Directory -Path $summaryDir
$stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$summaryPath = Join-Path $summaryDir ("review_summary_{0}.md" -f $stamp)

$lines = @(
    "# Intel Scoreboard Review",
    "",
    "* queue_root: $queueFull",
    "* title: $Title",
    "* results_seen: $($resultZips.Count)",
    "* ingested: $ingested",
    "* scoreboard: $(Join-Path $reportsDir 'scoreboard.json')",
    "* triage_next: $(Join-Path $reportsDir 'triage_next.md')",
    "* headline: $(if ($headline) { $headline.FullName } else { '(none)' })"
)
$lines | Set-Content -Path $summaryPath -Encoding ascii

Write-Host ("review_summary={0}" -f $summaryPath)
Write-Host ("scoreboard_path={0}" -f (Join-Path $reportsDir "scoreboard.json"))
Write-Host ("triage_path={0}" -f (Join-Path $reportsDir "triage_next.md"))
