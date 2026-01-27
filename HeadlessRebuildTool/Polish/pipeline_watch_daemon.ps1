[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Title,
    [Parameter(Mandatory = $true)]
    [string]$QueueRoot,
    [int]$PollSeconds = 15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

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

function Load-Defaults {
    param([string]$ScriptRoot, [string]$Title)
    $defaultsPath = Join-Path $ScriptRoot 'pipeline_defaults.json'
    if (-not (Test-Path $defaultsPath)) {
        throw "pipeline_defaults.json not found at $defaultsPath"
    }
    $data = Get-Content -Path $defaultsPath -Raw | ConvertFrom-Json
    $titleConfig = $data.titles.$Title
    if (-not $titleConfig) {
        throw "No defaults for title '$Title' in pipeline_defaults.json"
    }
    return $titleConfig
}

function Load-State {
    param([string]$StatePath)
    if (-not (Test-Path $StatePath)) { return @{} }
    try {
        $json = Get-Content -Path $StatePath -Raw | ConvertFrom-Json
        if ($json -and $json.processed) { return $json.processed }
    } catch {}
    return @{}
}

function Save-State {
    param([string]$StatePath, [hashtable]$Processed)
    $payload = [ordered]@{
        updated_utc = ([DateTime]::UtcNow).ToString("o")
        processed = $Processed
    } | ConvertTo-Json -Depth 4
    Set-Content -Path $StatePath -Value $payload -Encoding ascii
}

$queueRootFull = [System.IO.Path]::GetFullPath($QueueRoot)
$artifactsDir = Join-Path $queueRootFull "artifacts"
$jobsDir = Join-Path $queueRootFull "jobs"
$leasesDir = Join-Path $queueRootFull "leases"
$resultsDir = Join-Path $queueRootFull "results"
$reportsDir = Join-Path $queueRootFull "reports"
Ensure-Directory $artifactsDir
Ensure-Directory $jobsDir
Ensure-Directory $leasesDir
Ensure-Directory $resultsDir
Ensure-Directory $reportsDir

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$defaults = Load-Defaults -ScriptRoot $scriptRoot -Title $Title

$scenarioId = $defaults.scenario_id
$seed = [int]$defaults.seed
$timeoutSec = [int]$defaults.timeout_sec
$args = @()
if ($defaults.args) { $args = @($defaults.args) }

$statePath = Join-Path $reportsDir "watch_daemon_state.json"
$processed = @{}
$loaded = Load-State -StatePath $statePath
if ($loaded -is [hashtable]) {
    foreach ($key in $loaded.Keys) {
        $processed[$key] = $true
    }
} elseif ($loaded) {
    foreach ($prop in $loaded.PSObject.Properties) {
        $processed[$prop.Name] = $true
    }
}

Write-Host ("watch_daemon title={0} queue={1}" -f $Title, $queueRootFull)

while ($true) {
    $artifacts = Get-ChildItem -Path $artifactsDir -File -Filter "artifact_*.zip" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime
    foreach ($artifact in $artifacts) {
        $name = $artifact.BaseName
        $buildId = $name
        if ($name -match '^artifact_(.+)$') {
            $buildId = $Matches[1]
        }
        if ($processed.ContainsKey($buildId)) { continue }

        $jobId = "{0}_{1}_{2}" -f $buildId, $scenarioId, $seed
        $jobPath = Join-Path $jobsDir ("{0}.json" -f $jobId)
        $leasePath = Join-Path $leasesDir ("{0}.json" -f $jobId)
        $resultPath = Join-Path $resultsDir ("result_{0}.zip" -f $jobId)

        if ((Test-Path $jobPath) -or (Test-Path $leasePath) -or (Test-Path $resultPath)) {
            $processed[$buildId] = $true
            continue
        }

        $artifactUri = Convert-ToWslPath $artifact.FullName
        $createdUtc = ([DateTime]::UtcNow).ToString("o")

        $job = [ordered]@{
            job_id = $jobId
            commit = ""
            build_id = $buildId
            scenario_id = $scenarioId
            seed = $seed
            timeout_sec = $timeoutSec
            args = @($args)
            param_overrides = [ordered]@{}
            feature_flags = [ordered]@{}
            artifact_uri = $artifactUri
            created_utc = $createdUtc
        }

        $jobJson = $job | ConvertTo-Json -Depth 6
        $tmpPath = Join-Path $jobsDir (".tmp_{0}.json" -f $jobId)
        Set-Content -Path $tmpPath -Value $jobJson -Encoding ascii
        Move-Item -Path $tmpPath -Destination $jobPath -Force

        Write-Host ("enqueued job={0} artifact={1}" -f $jobId, $artifact.FullName)
        $processed[$buildId] = $true
    }

    Save-State -StatePath $statePath -Processed $processed
    Start-Sleep -Seconds $PollSeconds
}
