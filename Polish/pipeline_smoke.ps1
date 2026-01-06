[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Title,
    [Parameter(Mandatory = $true)]
    [string]$UnityExe,
    [string]$QueueRoot = "C:\\polish\\queue",
    [string]$ScenarioId,
    [int]$Seed,
    [int]$TimeoutSec,
    [string[]]$Args,
    [switch]$WaitForResult,
    [int]$WaitTimeoutSec = 900
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Directory {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function Convert-ToWslPath {
    param([string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    $match = [regex]::Match($full, '^([A-Za-z]):\\(.*)$')
    if ($match.Success) {
        $drive = $match.Groups[1].Value.ToLowerInvariant()
        $rest = $match.Groups[2].Value -replace '\\', '/'
        return "/mnt/$drive/$rest"
    }
    return ($full -replace '\\', '/')
}

function Read-ZipEntryText {
    param(
        [System.IO.Compression.ZipArchive]$Archive,
        [string]$EntryPath
    )
    $entry = $Archive.GetEntry($EntryPath)
    if (-not $entry) { return $null }
    $reader = New-Object System.IO.StreamReader($entry.Open())
    try {
        return $reader.ReadToEnd()
    }
    finally {
        $reader.Dispose()
    }
}

function Get-ResultSummary {
    param([string]$ZipPath)
    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $metaText = Read-ZipEntryText -Archive $archive -EntryPath "meta.json"
        $exitReason = "UNKNOWN"
        $failureSignature = ""
        if ($metaText) {
            $meta = $metaText | ConvertFrom-Json
            if ($meta.exit_reason) { $exitReason = $meta.exit_reason }
            if ($meta.failure_signature) { $failureSignature = $meta.failure_signature }
        }

        $determinismHash = ""
        $invText = Read-ZipEntryText -Archive $archive -EntryPath "out/invariants.json"
        if ($invText) {
            $inv = $invText | ConvertFrom-Json
            if ($inv.determinism_hash) { $determinismHash = $inv.determinism_hash }
        }

        $parts = @($exitReason)
        if ($failureSignature) { $parts += "failure_signature=$failureSignature" }
        if ($determinismHash) { $parts += "determinism_hash=$determinismHash" }
        return ($parts -join " ")
    }
    finally {
        $archive.Dispose()
    }
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$triRoot = (Resolve-Path (Join-Path $scriptRoot "..\\..")).Path
$defaultsPath = Join-Path $scriptRoot "pipeline_defaults.json"
if (-not (Test-Path $defaultsPath)) {
    throw "Missing defaults file: $defaultsPath"
}

$defaults = Get-Content -Raw -Path $defaultsPath | ConvertFrom-Json
$titleKey = $Title.ToLowerInvariant()
$titleDefaults = $defaults.titles.$titleKey
if (-not $titleDefaults) {
    throw "Unknown title '$Title'. Check pipeline_defaults.json."
}

$projectPath = Join-Path $triRoot $titleDefaults.project_path
if (-not (Test-Path $projectPath)) {
    throw "Project path not found: $projectPath"
}

if (-not (Test-Path $UnityExe)) {
    throw "Unity exe not found: $UnityExe"
}

$scenarioIdValue = if ($PSBoundParameters.ContainsKey("ScenarioId")) { $ScenarioId } else { $titleDefaults.scenario_id }
$seedValue = if ($PSBoundParameters.ContainsKey("Seed")) { $Seed } else { [int]$titleDefaults.seed }
$timeoutValue = if ($PSBoundParameters.ContainsKey("TimeoutSec")) { $TimeoutSec } else { [int]$titleDefaults.timeout_sec }
$argsValue = if ($PSBoundParameters.ContainsKey("Args")) { $Args } else { $titleDefaults.args }
if ($null -eq $argsValue) { $argsValue = @() }

$commitFull = & git -C $projectPath rev-parse HEAD 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "git rev-parse HEAD failed: $commitFull"
}
$commitShort = & git -C $projectPath rev-parse --short=8 HEAD 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "git rev-parse --short failed: $commitShort"
}

$timestamp = Get-Date -AsUTC -Format "yyyyMMdd_HHmmss"
$buildId = "${timestamp}_$commitShort"

$queueRootFull = [System.IO.Path]::GetFullPath($QueueRoot)
$artifactsDir = Join-Path $queueRootFull "artifacts"
$jobsDir = Join-Path $queueRootFull "jobs"
$leasesDir = Join-Path $queueRootFull "leases"
$resultsDir = Join-Path $queueRootFull "results"
Ensure-Directory $artifactsDir
Ensure-Directory $jobsDir
Ensure-Directory $leasesDir
Ensure-Directory $resultsDir

$supervisorProject = Join-Path $triRoot "Tools\\HeadlessBuildSupervisor\\HeadlessBuildSupervisor.csproj"
if (-not (Test-Path $supervisorProject)) {
    throw "HeadlessBuildSupervisor.csproj not found: $supervisorProject"
}

$supervisorArgs = @(
    "run", "--project", $supervisorProject, "--",
    "--unity-exe", $UnityExe,
    "--project-path", $projectPath,
    "--build-id", $buildId,
    "--commit", $commitFull,
    "--artifact-dir", $artifactsDir
)

& dotnet @supervisorArgs
$supervisorExit = $LASTEXITCODE
if ($supervisorExit -ne 0) {
    Write-Warning "HeadlessBuildSupervisor exited with code $supervisorExit"
}

$artifactZip = Join-Path $artifactsDir ("artifact_{0}.zip" -f $buildId)
if (-not (Test-Path $artifactZip)) {
    throw "Artifact zip not found: $artifactZip"
}

$artifactUri = Convert-ToWslPath $artifactZip
$jobId = "{0}_{1}_{2}" -f $buildId, $scenarioIdValue, $seedValue
$createdUtc = Get-Date -AsUTC -Format "yyyy-MM-ddTHH:mm:ssZ"

$job = [ordered]@{
    job_id = $jobId
    commit = $commitFull
    build_id = $buildId
    scenario_id = $scenarioIdValue
    seed = [int]$seedValue
    timeout_sec = [int]$timeoutValue
    args = @($argsValue)
    param_overrides = [ordered]@{}
    feature_flags = [ordered]@{}
    artifact_uri = $artifactUri
    created_utc = $createdUtc
}

$jobJson = $job | ConvertTo-Json -Depth 6
$jobTempPath = Join-Path $jobsDir (".tmp_{0}.json" -f $jobId)
$jobPath = Join-Path $jobsDir ("{0}.json" -f $jobId)
Set-Content -Path $jobTempPath -Value $jobJson -Encoding ascii
Move-Item -Path $jobTempPath -Destination $jobPath -Force

Write-Host ("build_id={0} commit={1}" -f $buildId, $commitFull)
Write-Host ("artifact={0}" -f $artifactZip)
Write-Host ("job={0}" -f $jobPath)

if ($WaitForResult) {
    $resultZip = Join-Path $resultsDir ("result_{0}.zip" -f $jobId)
    $deadline = (Get-Date).AddSeconds($WaitTimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $resultZip) { break }
        Start-Sleep -Seconds 2
    }

    if (-not (Test-Path $resultZip)) {
        throw "Timed out waiting for result: $resultZip"
    }

    $summary = Get-ResultSummary -ZipPath $resultZip
    Write-Host $summary
}
