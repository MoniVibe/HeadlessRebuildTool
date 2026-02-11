[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Title,
    [string]$QueueRoot = "C:\\polish\\queue",
    [int]$PollSeconds = 15,
    [int]$Repeat = 1,
    [string]$ScenarioId,
    [string]$ScenarioRel,
    [string]$GoalId,
    [string]$GoalSpec,
    [int]$Seed,
    [string[]]$Args,
    [switch]$WaitForResult,
    [int]$WaitTimeoutSec = 1800,
    [string]$StatePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Directory {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try { return (Get-Content -Raw -Path $Path | ConvertFrom-Json) } catch { return $null }
}

function Write-JsonFile {
    param([string]$Path, [object]$Value)
    $json = $Value | ConvertTo-Json -Depth 6
    Set-Content -Path $Path -Value $json -Encoding ascii
}

function Read-BuildOutcome {
    param([string]$ZipPath)
    if (-not (Test-Path $ZipPath)) { return $null }
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
        $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        try {
            $entry = $archive.GetEntry("logs/build_outcome.json")
            if (-not $entry) { return $null }
            $reader = New-Object System.IO.StreamReader($entry.Open())
            try { return ($reader.ReadToEnd() | ConvertFrom-Json) } finally { $reader.Dispose() }
        }
        finally {
            $archive.Dispose()
        }
    }
    catch {
        Write-Warning ("build_outcome_read_failed artifact={0} error={1}" -f $ZipPath, $_.Exception.Message)
        return $null
    }
}

function Read-ZipEntryText {
    param(
        [System.IO.Compression.ZipArchive]$Archive,
        [string]$EntryPath
    )
    $entry = $Archive.GetEntry($EntryPath)
    if (-not $entry) { return $null }
    $reader = New-Object System.IO.StreamReader($entry.Open())
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function Get-ArtifactTitle {
    param([string]$ZipPath)
    if (-not (Test-Path $ZipPath)) { return "" }
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
        $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        try {
            $manifestText = Read-ZipEntryText -Archive $archive -EntryPath "build_manifest.json"
            if (-not $manifestText) {
                $manifestText = Read-ZipEntryText -Archive $archive -EntryPath "logs/build_report.json"
            }
            if (-not $manifestText) { return "" }
            try { $manifest = $manifestText | ConvertFrom-Json } catch { return "" }
            $candidate = ""
            if ($manifest.entrypoint) { $candidate = $manifest.entrypoint }
            elseif ($manifest.summary -and $manifest.summary.output_path) { $candidate = $manifest.summary.output_path }
            if ([string]::IsNullOrWhiteSpace($candidate)) { return "" }
            $lower = $candidate.ToLowerInvariant()
            if ($lower -like "*space4x*") { return "space4x" }
            if ($lower -like "*godgame*") { return "godgame" }
            if ($lower -like "*puredots*") { return "puredots" }
            if ($lower -like "*headless*") { return "headless" }
            return ""
        }
        finally {
            $archive.Dispose()
        }
    }
    catch {
        Write-Warning ("manifest_read_failed artifact={0} error={1}" -f $ZipPath, $_.Exception.Message)
        return ""
    }
}

function Test-BuildAlreadyQueued {
    param(
        [string]$QueueRoot,
        [string]$BuildId
    )
    if ([string]::IsNullOrWhiteSpace($QueueRoot) -or [string]::IsNullOrWhiteSpace($BuildId)) { return $false }
    $jobsDir = Join-Path $QueueRoot "jobs"
    $leasesDir = Join-Path $QueueRoot "leases"
    $resultsDir = Join-Path $QueueRoot "results"
    $archiveDir = Join-Path $leasesDir "archive"

    $jobPattern = ("{0}_*.json" -f $BuildId)
    $resultPattern = ("result_{0}_*.zip" -f $BuildId)

    if (Test-Path $jobsDir) {
        $hit = Get-ChildItem -Path $jobsDir -Filter $jobPattern -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $true }
    }
    if (Test-Path $leasesDir) {
        $hit = Get-ChildItem -Path $leasesDir -Filter $jobPattern -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $true }
    }
    if (Test-Path $archiveDir) {
        $hit = Get-ChildItem -Path $archiveDir -Filter $jobPattern -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $true }
    }
    if (Test-Path $resultsDir) {
        $hit = Get-ChildItem -Path $resultsDir -Filter $resultPattern -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $true }
    }
    return $false
}

$runnerConfigPath = Join-Path $PSScriptRoot "runner_config.json"
$runnerConfig = $null
$projectPathOverride = $null
if (Test-Path $runnerConfigPath) {
    $runnerConfig = Read-JsonFile -Path $runnerConfigPath
}

$titleKey = $Title.ToLowerInvariant()
if ($runnerConfig) {
    if ($runnerConfig.tri_root) {
        $env:TRI_ROOT = $runnerConfig.tri_root
    }
    if ($runnerConfig.tri_root_candidates) {
        $env:TRI_ROOT_CANDIDATES = ($runnerConfig.tri_root_candidates -join ';')
    }
    $configQueueRoot = $null
    if ($runnerConfig.queue_root_overrides -and $runnerConfig.queue_root_overrides.$titleKey) {
        $configQueueRoot = $runnerConfig.queue_root_overrides.$titleKey
    } elseif ($runnerConfig.queue_root) {
        $configQueueRoot = $runnerConfig.queue_root
    }
    if (-not [string]::IsNullOrWhiteSpace($configQueueRoot)) {
        $QueueRoot = $configQueueRoot
    }
    if ($runnerConfig.project_path_overrides -and $runnerConfig.project_path_overrides.$titleKey) {
        $projectPathOverride = $runnerConfig.project_path_overrides.$titleKey
    }
}

$queueRootFull = [System.IO.Path]::GetFullPath($QueueRoot)
$artifactsDir = Join-Path $queueRootFull "artifacts"
$reportsDir = Join-Path $queueRootFull "reports"
Ensure-Directory $artifactsDir
Ensure-Directory $reportsDir

if ([string]::IsNullOrWhiteSpace($StatePath)) {
    $StatePath = Join-Path $reportsDir ("watch_state_{0}.json" -f $Title)
}

$state = Read-JsonFile -Path $StatePath
if (-not $state) {
    $state = [ordered]@{
        title = $Title
        last_build_id = ""
        last_artifact = ""
        updated_utc = ""
    }
}

$enqueueScript = Join-Path $PSScriptRoot "pipeline_enqueue.ps1"
if (-not (Test-Path $enqueueScript)) {
    throw "Missing pipeline_enqueue.ps1: $enqueueScript"
}

Write-Host ("watch_daemon_start title={0} poll_sec={1} state={2}" -f $Title, $PollSeconds, $StatePath)
if ($runnerConfigPath -and (Test-Path $runnerConfigPath)) {
    Write-Host ("watch_daemon_config tri_root={0} queue_root={1} project_override={2}" -f $env:TRI_ROOT, $queueRootFull, $projectPathOverride)
}

while ($true) {
    $artifacts = Get-ChildItem -Path $artifactsDir -Filter "artifact_*.zip" -File | Sort-Object LastWriteTime -Descending
    foreach ($artifact in $artifacts) {
        if ($state.last_artifact -and $artifact.FullName -eq $state.last_artifact) {
            break
        }

        $outcome = Read-BuildOutcome -ZipPath $artifact.FullName
        if (-not $outcome) { continue }
        if ($outcome.result -ne "Succeeded") { continue }

        $artifactTitle = Get-ArtifactTitle -ZipPath $artifact.FullName
        if (-not [string]::IsNullOrWhiteSpace($artifactTitle) -and $artifactTitle -ne $Title.ToLowerInvariant()) {
            Write-Host ("skip_mismatch title={0} artifact_title={1} artifact={2}" -f $Title, $artifactTitle, $artifact.FullName)
            continue
        }

        $buildId = $outcome.build_id
        if ([string]::IsNullOrWhiteSpace($buildId)) { continue }

        if (Test-BuildAlreadyQueued -QueueRoot $queueRootFull -BuildId $buildId) {
            Write-Host ("skip_existing build_id={0} artifact={1}" -f $buildId, $artifact.FullName)
            $state.last_build_id = $buildId
            $state.last_artifact = $artifact.FullName
            $state.updated_utc = (Get-Date).ToUniversalTime().ToString("o")
            Write-JsonFile -Path $StatePath -Value $state
            break
        }

        Write-Host ("enqueue_detected build_id={0} artifact={1}" -f $buildId, $artifact.FullName)

        $invokeArgs = @{
            Title = $Title
            ArtifactZip = $artifact.FullName
            QueueRoot = $QueueRoot
            Repeat = $Repeat
        }
        if (-not [string]::IsNullOrWhiteSpace($projectPathOverride)) { $invokeArgs.ProjectPathOverride = $projectPathOverride }
        if ($PSBoundParameters.ContainsKey("Seed")) { $invokeArgs.Seed = $Seed }
        if ($PSBoundParameters.ContainsKey("ScenarioId")) { $invokeArgs.ScenarioId = $ScenarioId }
        if ($PSBoundParameters.ContainsKey("ScenarioRel")) { $invokeArgs.ScenarioRel = $ScenarioRel }
        if ($PSBoundParameters.ContainsKey("GoalId")) { $invokeArgs.GoalId = $GoalId }
        if ($PSBoundParameters.ContainsKey("GoalSpec")) { $invokeArgs.GoalSpec = $GoalSpec }
        if ($PSBoundParameters.ContainsKey("Args")) { $invokeArgs.Args = $Args }
        if ($WaitForResult) { $invokeArgs.WaitForResult = $true }
        if ($PSBoundParameters.ContainsKey("WaitTimeoutSec")) { $invokeArgs.WaitTimeoutSec = $WaitTimeoutSec }

        $enqueueOk = $false
        try {
            & $enqueueScript @invokeArgs
            $enqueueOk = $true
        }
        catch {
            $errorMessage = $_.Exception.Message
            Write-Warning ("enqueue_failed build_id={0} artifact={1} error={2}" -f $buildId, $artifact.FullName, $errorMessage)
            $state.last_error = $errorMessage
            $state.last_error_utc = (Get-Date).ToUniversalTime().ToString("o")
            $state.last_error_artifact = $artifact.FullName
        }

        $state.last_build_id = $buildId
        $state.last_artifact = $artifact.FullName
        $state.updated_utc = (Get-Date).ToUniversalTime().ToString("o")
        Write-JsonFile -Path $StatePath -Value $state

        break
    }

    Start-Sleep -Seconds $PollSeconds
}
