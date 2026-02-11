[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SessionDir,
    [string]$QueueRoot = "C:\\polish\\queue",
    [string]$UnityExe
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Directory {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function Resolve-UnityExe {
    param([string]$ExePath)
    $resolved = $ExePath
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        $resolved = $env:UNITY_WIN
    }
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        $hubRoot = "C:\\Program Files\\Unity\\Hub\\Editor"
        if (-not (Test-Path $hubRoot)) {
            throw "Unity exe not found. Set UNITY_WIN or install Unity Hub."
        }
        $candidates = Get-ChildItem -Path $hubRoot -Directory | ForEach-Object {
            $exe = Join-Path $_.FullName "Editor\\Unity.exe"
            if (Test-Path $exe) {
                Get-Item $exe
            }
        }
        if (-not $candidates) {
            throw "Unity exe not found under $hubRoot."
        }
        $resolved = ($candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
    }
    if (-not (Test-Path $resolved)) {
        throw "Unity exe not found: $resolved"
    }
    return $resolved
}

function Resolve-TaskScenarioId {
    param(
        [string]$TasksPath,
        [string]$TaskId,
        [string]$Fallback
    )
    if ([string]::IsNullOrWhiteSpace($TaskId)) { return $Fallback }
    if (-not (Test-Path $TasksPath)) { return $Fallback }
    try {
        $tasksDoc = Get-Content -Raw -Path $TasksPath | ConvertFrom-Json
    }
    catch {
        return $Fallback
    }
    if (-not $tasksDoc -or -not $tasksDoc.tasks) { return $Fallback }
    $tasks = $tasksDoc.tasks
    $prop = $tasks.PSObject.Properties[$TaskId]
    if (-not $prop) { return $Fallback }
    $task = $prop.Value
    if ($task -and $task.scenario_id) { return $task.scenario_id }
    if ($TaskId.StartsWith("S0.SPACE4X_")) { return "space4x" }
    if ($TaskId.StartsWith("P1.SPACE4X_")) { return "puredots_samples" }
    return $Fallback
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


function Write-JobFile {
    param(
        [string]$JobsDir,
        [object]$Job
    )
    $jobJson = $Job | ConvertTo-Json -Depth 6
    $jobTempPath = Join-Path $JobsDir (".tmp_{0}.json" -f $Job.job_id)
    $jobPath = Join-Path $JobsDir ("{0}.json" -f $Job.job_id)
    Set-Content -Path $jobTempPath -Value $jobJson -Encoding ascii
    Move-Item -Path $jobTempPath -Destination $jobPath -Force
    Write-Host ("job={0}" -f $jobPath)
    return $jobPath
}

function Invoke-WorkerOnce {
    param([string]$QueueRoot)
    $runnerWin = Join-Path $scriptRoot "WSL\\wsl_runner.sh"
    $queueWsl = Convert-ToWslPath -Path $QueueRoot
    $tmpRunnerWin = Join-Path $SessionDir "wsl_runner_pitchpack.sh"
    $runnerText = Get-Content -Raw -Path $runnerWin
    $normalized = $runnerText -replace "`r`n", "`n"
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($tmpRunnerWin, $normalized, $utf8NoBom)

    $tmpRunnerWsl = Convert-ToWslPath -Path $tmpRunnerWin
    $cmd = "set -e; chmod +x '$tmpRunnerWsl'; '$tmpRunnerWsl' --queue $queueWsl --once --print-summary"
    $null = & wsl.exe -e bash -lc $cmd
    if ($LASTEXITCODE -ne 0) {
        throw "wsl_worker_failed exit_code=$LASTEXITCODE"
    }
}

function Wait-ForResultOrFail {
    param(
        [string]$JobPath,
        [int]$TimeoutMinutes
    )
    if ([string]::IsNullOrWhiteSpace($JobPath)) {
        throw "job_path_missing"
    }

    $stem = [IO.Path]::GetFileNameWithoutExtension($JobPath)
    $triagePath = "C:\\polish\\queue\\reports\\triage_$stem.json"
    $resultPath = "C:\\polish\\queue\\results\\result_$stem.zip"
    Write-Host ("triage={0}" -f $triagePath)
    Write-Host ("result={0}" -f $resultPath)

    $jobTimeUtc = (Get-Date).ToUniversalTime()
    if (Test-Path $JobPath) {
        $jobTimeUtc = (Get-Item $JobPath).LastWriteTimeUtc
    }

    Invoke-WorkerOnce -QueueRoot $QueueRoot

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $resultPath) {
            $resultItem = Get-Item $resultPath
            if ($resultItem.LastWriteTimeUtc -ge $jobTimeUtc) {
                return $resultPath
            }
        }

        if (Test-Path $triagePath) {
            $triageItem = Get-Item $triagePath
            if ($triageItem.LastWriteTimeUtc -ge $jobTimeUtc) {
                $triageText = Get-Content -Raw -Path $triagePath
                $triage = $null
                try {
                    $triage = $triageText | ConvertFrom-Json
                }
                catch {
                    $triage = $null
                }

                $exitCode = 1
                $exitReason = "triage_parse_failed"
                $failureSignature = ""
                if ($triage) {
                    if ($triage.exit_code -ne $null) { $exitCode = [int]$triage.exit_code }
                    if ($triage.exit_reason) { $exitReason = $triage.exit_reason }
                    if ($triage.failure_signature) { $failureSignature = $triage.failure_signature }
                }

                Write-Host ("JOB {0} triage exit_code={1} exit_reason={2}" -f $stem, $exitCode, $exitReason)

                $reportPath = Join-Path $SessionDir "pitchpack_failfast_last_error.md"
                $lines = @(
                    "triagePath: $triagePath",
                    "exit_reason: $exitReason",
                    "exit_code: $exitCode",
                    "failure_signature: $failureSignature"
                )
                Set-Content -Encoding ascii -Path $reportPath -Value $lines
                exit 1
            }
        }

        Start-Sleep -Seconds 2
    }

    throw "result_or_triage_timeout job=$JobPath"
}

function Assert-JobScenarioId {
    param(
        [string]$JobPath,
        [string]$ExpectedScenarioId
    )
    if (-not (Test-Path $JobPath)) {
        $reportPath = Join-Path $SessionDir "pitchpack_failfast_last_error.md"
        @("job_path_missing: $JobPath") | Set-Content -Encoding ascii -Path $reportPath
        throw "job_path_missing: $JobPath"
    }

    $jobJson = Get-Content -Raw -Path $JobPath | ConvertFrom-Json
    $scenarioValue = $null
    $scenarioProp = $jobJson.PSObject.Properties["scenario_id"]
    if ($scenarioProp) { $scenarioValue = $scenarioProp.Value }
    $aliasValue = $null
    $aliasProp = $jobJson.PSObject.Properties["scenarioId"]
    if ($aliasProp) { $aliasValue = $aliasProp.Value }
    $aliasOk = $true
    if ($aliasValue) {
        $aliasOk = ($aliasValue -eq $ExpectedScenarioId)
    }
    $ok = ($scenarioValue -eq $ExpectedScenarioId) -and $aliasOk
    if (-not $ok) {
        $reportPath = Join-Path $SessionDir "pitchpack_failfast_last_error.md"
        $lines = @(
            "job_path: $JobPath",
            "expected_scenario_id: $ExpectedScenarioId",
            "scenario_id: $scenarioValue",
            "scenarioId: $aliasValue"
        )
        Set-Content -Encoding ascii -Path $reportPath -Value $lines
        throw "scenario_id_mismatch: expected=$ExpectedScenarioId scenario_id=$scenarioValue scenarioId=$aliasValue"
    }
}

function Run-HeadlessJob {
    param(
        [string]$ScenarioId,
        [string]$ScenarioIdForJob,
        [int]$Seed,
        [int]$TimeoutSec,
        [string]$BuildId,
        [string]$Commit,
        [string]$ArtifactUri,
        [string]$QueueRoot,
        [string]$Suffix,
        [int]$WaitTimeoutSec
    )
    $jobsDir = Join-Path $QueueRoot "jobs"
    $resultsDir = Join-Path $QueueRoot "results"
    Ensure-Directory $jobsDir
    Ensure-Directory $resultsDir

    $suffixValue = if ([string]::IsNullOrWhiteSpace($Suffix)) { "" } else { $Suffix }
    $jobId = "{0}_{1}_{2}{3}" -f $BuildId, $ScenarioId, $Seed, $suffixValue
    $createdUtc = ([DateTime]::UtcNow).ToString("o")

    $scenarioIdValue = if ([string]::IsNullOrWhiteSpace($ScenarioIdForJob)) { $ScenarioId } else { $ScenarioIdForJob }
    $job = [ordered]@{
        job_id = $jobId
        commit = $Commit
        build_id = $BuildId
        scenario_id = $scenarioIdValue
        scenarioId = $scenarioIdValue
        seed = [int]$Seed
        timeout_sec = [int]$TimeoutSec
        args = @()
        param_overrides = [ordered]@{}
        feature_flags = [ordered]@{}
        artifact_uri = $ArtifactUri
        created_utc = $createdUtc
    }

    $jobPath = Write-JobFile -JobsDir $jobsDir -Job $job
    Assert-JobScenarioId -JobPath $jobPath -ExpectedScenarioId $scenarioIdValue
    $resultZip = Wait-ForResultOrFail -JobPath $jobPath -TimeoutMinutes 10

    return [ordered]@{
        job_id = $jobId
        result_zip = $resultZip
    }
}

function Get-ArtifactZip {
    param(
        [string]$ArtifactsDir,
        [datetime]$SinceUtc
    )
    if (-not (Test-Path $ArtifactsDir)) { return $null }
    $candidates = @(Get-ChildItem -Path $ArtifactsDir -Filter "artifact_*.zip" -File)
    if ($SinceUtc) {
        $candidates = @($candidates | Where-Object { $_.LastWriteTimeUtc -ge $SinceUtc })
    }
    if ($null -eq $candidates -or $candidates.Count -eq 0) {
        $candidates = @(Get-ChildItem -Path $ArtifactsDir -Filter "artifact_*.zip" -File)
    }
    if ($null -eq $candidates -or $candidates.Count -eq 0) { return $null }
    return ($candidates | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
}

function Parse-BuildIdFromArtifact {
    param([string]$ArtifactPath)
    if ([string]::IsNullOrWhiteSpace($ArtifactPath)) { return $null }
    $name = [System.IO.Path]::GetFileNameWithoutExtension($ArtifactPath)
    if ($name -like "artifact_*") { return $name.Substring("artifact_".Length) }
    return $null
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$triRoot = (Resolve-Path (Join-Path $scriptRoot "..\\..")).Path
$pipelineScript = Join-Path $scriptRoot "pipeline_smoke.ps1"
if (-not (Test-Path $pipelineScript)) {
    throw "Missing pipeline script: $pipelineScript"
}

Ensure-Directory $SessionDir
$queueRootFull = [System.IO.Path]::GetFullPath($QueueRoot)
$artifactsDir = Join-Path $queueRootFull "artifacts"
Ensure-Directory $artifactsDir
$tasksPath = Join-Path $triRoot "Tools\\Tools\\Headless\\headless_tasks.json"

$unityResolved = Resolve-UnityExe -ExePath $UnityExe
$env:TRI_ENFORCE_LICENSE_ERROR = "0"

$smokeScenario = "S0.SPACE4X_SMOKE"
$smokeSeed = 77
$rewindScenario = "P1.SPACE4X_REWIND_GATE2"
$rewindSeed = 9102
$smokeScenarioIdForJob = "space4x"
$rewindScenarioIdForJob = "puredots_samples"
$timeoutSec = 600
$waitTimeoutSec = 1800

$buildStartUtc = (Get-Date).ToUniversalTime()
& $pipelineScript -Title space4x -UnityExe $unityResolved -ScenarioId $smokeScenario -Seed $smokeSeed -Repeat 1 -WaitTimeoutSec $waitTimeoutSec
$pipelineExit = $LASTEXITCODE
if ($pipelineExit -ne 0) {
    throw "pipeline_smoke_failed exit_code=$pipelineExit"
}

$artifact = Get-ArtifactZip -ArtifactsDir $artifactsDir -SinceUtc $buildStartUtc
if (-not $artifact) {
    throw "Artifact zip not found under $artifactsDir."
}
$artifactZip = $artifact.FullName
$buildId = Parse-BuildIdFromArtifact -ArtifactPath $artifactZip
if ([string]::IsNullOrWhiteSpace($buildId)) {
    throw "Failed to parse build id from $artifactZip."
}

$projectPath = Join-Path $triRoot "space4x"
$commitFull = & git -C $projectPath rev-parse HEAD 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "git rev-parse HEAD failed: $commitFull"
}
$artifactUri = Convert-ToWslPath -Path $artifactZip

$resultsDir = Join-Path $queueRootFull "results"
Ensure-Directory $resultsDir
$smokeJobId = "{0}_{1}_{2}" -f $buildId, $smokeScenario, $smokeSeed
$smokeJobPath = Join-Path $queueRootFull ("jobs\\{0}.json" -f $smokeJobId)
Assert-JobScenarioId -JobPath $smokeJobPath -ExpectedScenarioId $smokeScenarioIdForJob
$smokeResultZip = Wait-ForResultOrFail -JobPath $smokeJobPath -TimeoutMinutes 10
$smokeRun = [ordered]@{
    job_id = $smokeJobId
    seed = $smokeSeed
    result_zip = $smokeResultZip
}

$rewindRun = Run-HeadlessJob -ScenarioId $rewindScenario -ScenarioIdForJob $rewindScenarioIdForJob -Seed $rewindSeed -TimeoutSec $timeoutSec -BuildId $buildId -Commit $commitFull -ArtifactUri $artifactUri -QueueRoot $queueRootFull -Suffix "" -WaitTimeoutSec $waitTimeoutSec

$summaryLines = @()
$summaryLines += "# Space4x PitchPack LITE v0"
$summaryLines += ""
$summaryLines += ("smoke: stem={0} seed={1} result_zip={2}" -f $smokeRun.job_id, $smokeRun.seed, $smokeRun.result_zip)
$summaryLines += ("rewind: stem={0} seed={1} result_zip={2}" -f $rewindRun.job_id, $rewindSeed, $rewindRun.result_zip)
$summaryLines += ""
$summaryLines += "note: determinism hashing disabled (invariants.json not emitted by smoke runs)"

$summaryPath = Join-Path $SessionDir "pitchpack_space4x_lite_v0.md"
Set-Content -Path $summaryPath -Value $summaryLines -Encoding ascii

$timestamp = ([DateTime]::UtcNow).ToString("yyyyMMdd_HHmmss")
$zipPath = Join-Path $SessionDir ("pitchpack_space4x_lite_v0_{0}.zip" -f $timestamp)
if (Test-Path $zipPath) {
    Remove-Item -Force $zipPath
}

Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
$archive = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $summaryPath, "pitchpack_space4x_lite_v0.md") | Out-Null
    $smokeEntry = [System.IO.Path]::GetFileName($smokeRun.result_zip)
    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $smokeRun.result_zip, $smokeEntry) | Out-Null
    $rewindEntry = [System.IO.Path]::GetFileName($rewindRun.result_zip)
    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $rewindRun.result_zip, $rewindEntry) | Out-Null
}
finally {
    $archive.Dispose()
}

Write-Host ("pitchpack_zip={0}" -f $zipPath)
