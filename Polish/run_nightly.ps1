[CmdletBinding()]
param(
    [string]$UnityExe,
    [ValidateSet("space4x", "godgame", "both")]
    [string]$Title = "both",
    [string]$QueueRootSpace4x = "C:\\polish\\anviloop\\space4x\\queue",
    [string]$QueueRootGodgame = "C:\\polish\\anviloop\\godgame\\queue",
    [int]$Repeat = 10,
    [int]$WaitTimeoutSec = 1800
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
        $resolved = $env:UNITY_EXE
    }
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        throw "UnityExe not provided (use -UnityExe or set UNITY_WIN/UNITY_EXE)."
    }
    if (-not (Test-Path $resolved)) {
        throw "Unity exe not found: $resolved"
    }
    return $resolved
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
    $name = [System.IO.Path]::GetFileName($ArtifactPath)
    if ($name -match "^artifact_(.+)\\.zip$") { return $Matches[1] }
    return $null
}

function Get-LatestResultZip {
    param(
        [string]$ResultsDir,
        [string]$Title
    )
    if (-not (Test-Path $ResultsDir)) { return $null }
    $pattern = "result_*_{0}_*.zip" -f $Title
    $candidates = @(Get-ChildItem -Path $ResultsDir -Filter $pattern -File)
    if ($null -eq $candidates -or $candidates.Count -eq 0) { return $null }
    return ($candidates | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
}

function Parse-BuildIdFromResult {
    param(
        [string]$ResultPath,
        [string]$Title
    )
    if ([string]::IsNullOrWhiteSpace($ResultPath)) { return $null }
    if ([string]::IsNullOrWhiteSpace($Title)) { return $null }
    $name = [System.IO.Path]::GetFileName($ResultPath)
    $pattern = "^result_(.+?)_{0}_.*\\.zip$" -f [regex]::Escape($Title)
    $match = [regex]::Match($name, $pattern)
    if ($match.Success) { return $match.Groups[1].Value }
    return $null
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

function Get-ResultMeta {
    param([string]$ZipPath)
    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $metaText = Read-ZipEntryText -Archive $archive -EntryPath "meta.json"
        if (-not $metaText) { return $null }
        return $metaText | ConvertFrom-Json
    }
    finally {
        $archive.Dispose()
    }
}

function Get-ResultRunSummary {
    param([string]$ZipPath)
    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $text = Read-ZipEntryText -Archive $archive -EntryPath "out/run_summary.json"
        if (-not $text) { return $null }
        return $text | ConvertFrom-Json
    }
    finally {
        $archive.Dispose()
    }
}

function Get-ResultPolishScore {
    param([string]$ZipPath)
    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $text = Read-ZipEntryText -Archive $archive -EntryPath "out/polish_score_v0.json"
        if (-not $text) { return $null }
        return $text | ConvertFrom-Json
    }
    finally {
        $archive.Dispose()
    }
}

function Get-TelemetryBytesFromZip {
    param([string]$ZipPath)
    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $entry = $archive.GetEntry("out/telemetry.ndjson")
        if (-not $entry) { return $null }
        return [double]$entry.Length
    }
    finally {
        $archive.Dispose()
    }
}

function Get-ResultInvariants {
    param([string]$ZipPath)
    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $invText = Read-ZipEntryText -Archive $archive -EntryPath "out/invariants.json"
        if (-not $invText) { return $null }
        return $invText | ConvertFrom-Json
    }
    finally {
        $archive.Dispose()
    }
}

function Get-MinMax {
    param([double[]]$Values)
    if (-not $Values -or $Values.Count -eq 0) { return $null }
    $min = ($Values | Measure-Object -Minimum).Minimum
    $max = ($Values | Measure-Object -Maximum).Maximum
    return [ordered]@{
        min = $min
        max = $max
    }
}

function Get-MinMaxAvg {
    param([double[]]$Values)
    if (-not $Values -or $Values.Count -eq 0) { return $null }
    $min = ($Values | Measure-Object -Minimum).Minimum
    $max = ($Values | Measure-Object -Maximum).Maximum
    $avg = ($Values | Measure-Object -Average).Average
    return [ordered]@{
        min = $min
        avg = [Math]::Round($avg, 3)
        max = $max
    }
}

function Invoke-Smoke {
    param(
        [string]$Title,
        [string]$UnityExePath,
        [string]$QueueRootPath,
        [int]$RepeatCount,
        [int]$WaitTimeoutSec
    )
    $pipelineSmoke = Join-Path $PSScriptRoot "pipeline_smoke.ps1"
    if (-not (Test-Path $pipelineSmoke)) {
        throw "pipeline_smoke.ps1 not found: $pipelineSmoke"
    }

    $startUtc = [DateTime]::UtcNow
    $invoke = @{
        Title = $Title
        UnityExe = $UnityExePath
        QueueRoot = $QueueRootPath
        LockReason = "run_nightly"
        Repeat = $RepeatCount
        WaitForResult = $true
        WaitTimeoutSec = $WaitTimeoutSec
    }

    $output = @()
    $errorText = $null
    $exitCode = 0
    try {
        $output = & $pipelineSmoke @invoke 2>&1 | ForEach-Object { $_.ToString() }
        $exitCode = $LASTEXITCODE
    }
    catch {
        $errorText = $_.Exception.Message
        $exitCode = 1
    }
    $endUtc = [DateTime]::UtcNow
    $artifactsDir = Join-Path $QueueRootPath "artifacts"
    $artifact = Get-ArtifactZip -ArtifactsDir $artifactsDir -SinceUtc $startUtc
    $artifactPath = if ($artifact) { $artifact.FullName } else { $null }
    $buildId = Parse-BuildIdFromArtifact -ArtifactPath $artifactPath

        return [pscustomobject][ordered]@{
            title = $Title
            build_id = $buildId
            artifact_zip = $artifactPath
            exit_code = $exitCode
            error = $errorText
            start_utc = $startUtc.ToString("o")
            end_utc = $endUtc.ToString("o")
        }
}

function Summarize-Results {
    param(
        [string]$QueueRootPath,
        [string]$BuildId,
        [string]$Title,
        [string]$ReportsDir
    )
    $counts = @{}
    $hashes = New-Object System.Collections.Generic.HashSet[string]
    $triagePaths = New-Object System.Collections.Generic.List[string]
    $telemetryBytes = New-Object System.Collections.Generic.List[double]
    $runtimeSec = New-Object System.Collections.Generic.List[double]
    $failingInvariants = New-Object System.Collections.Generic.HashSet[string]
    $scoreLosses = New-Object System.Collections.Generic.List[double]
    $scoreGrades = New-Object System.Collections.Generic.HashSet[string]

    $resultsDir = Join-Path $QueueRootPath "results"
    if (-not (Test-Path $resultsDir)) {
        return [pscustomobject][ordered]@{
            result_count = 0
            exit_reason_counts = $counts
            determinism_hashes = @()
            telemetry_bytes = $null
            runtime_sec = $null
            triage_paths = @()
            failing_invariants = @()
            polish_score_total_loss = $null
            polish_score_grades = @()
            error = "results_dir_missing"
        }
    }
    $pattern = "result_{0}_{1}_*.zip" -f $BuildId, $Title
    $zips = @(Get-ChildItem -Path $resultsDir -Filter $pattern -File | Sort-Object Name)

    if ($null -eq $zips -or $zips.Count -eq 0) {
        return [pscustomobject][ordered]@{
            result_count = 0
            exit_reason_counts = $counts
            determinism_hashes = @()
            telemetry_bytes = $null
            runtime_sec = $null
            triage_paths = @()
            failing_invariants = @()
            polish_score_total_loss = $null
            polish_score_grades = @()
            error = "results_not_found"
        }
    }

    foreach ($zip in $zips) {
        $runSummary = Get-ResultRunSummary -ZipPath $zip.FullName
        $polishScore = Get-ResultPolishScore -ZipPath $zip.FullName
        $meta = if ($runSummary) { $null } else { Get-ResultMeta -ZipPath $zip.FullName }
        if (-not $runSummary -and -not $meta) { continue }

        $exitReason = if ($runSummary -and $runSummary.exit_reason) { $runSummary.exit_reason } else { $meta.exit_reason }
        if ([string]::IsNullOrWhiteSpace($exitReason)) { $exitReason = "UNKNOWN" }
        if ($counts.ContainsKey($exitReason)) {
            $counts[$exitReason] += 1
        }
        else {
            $counts[$exitReason] = 1
        }

        $jobId = if ($runSummary -and $runSummary.job_id) { $runSummary.job_id } else { $meta.job_id }
        if ($exitReason -ne "SUCCESS" -and -not [string]::IsNullOrWhiteSpace($jobId)) {
            $triagePath = Join-Path $ReportsDir ("triage_{0}.json" -f $jobId)
            if (Test-Path $triagePath) {
                $triagePaths.Add($triagePath)
            }
        }

        $determinismHash = $null
        if ($runSummary -and $runSummary.determinism_hash) {
            $determinismHash = [string]$runSummary.determinism_hash
        }
        if (-not $determinismHash) {
            $inv = Get-ResultInvariants -ZipPath $zip.FullName
            if ($inv -and $inv.determinism_hash) {
                $determinismHash = [string]$inv.determinism_hash
            }
        }
        if ($determinismHash) {
            [void]$hashes.Add($determinismHash)
        }

        $telemetryValue = $null
        if ($runSummary -and $runSummary.telemetry -and $runSummary.telemetry.bytes_total -ne $null) {
            $telemetryValue = [double]$runSummary.telemetry.bytes_total
        }
        if ($telemetryValue -eq $null) {
            $telemetryValue = Get-TelemetryBytesFromZip -ZipPath $zip.FullName
        }
        if ($telemetryValue -ne $null) {
            $telemetryBytes.Add([double]$telemetryValue)
        }

        $runtime = $null
        if ($runSummary -and $runSummary.runtime_sec -ne $null) {
            $runtime = [double]$runSummary.runtime_sec
        }
        elseif ($meta -and $meta.duration_sec -ne $null) {
            $runtime = [double]$meta.duration_sec
        }
        if ($runtime -ne $null) {
            $runtimeSec.Add($runtime)
        }

        if ($runSummary -and $runSummary.failing_invariants) {
            foreach ($invId in $runSummary.failing_invariants) {
                if (-not [string]::IsNullOrWhiteSpace($invId)) {
                    [void]$failingInvariants.Add([string]$invId)
                }
            }
        }

        if ($polishScore) {
            if ($polishScore.total_loss -ne $null) {
                $scoreLosses.Add([double]$polishScore.total_loss)
            }
            if ($polishScore.grade) {
                [void]$scoreGrades.Add([string]$polishScore.grade)
            }
        }
    }

    return [pscustomobject][ordered]@{
        result_count = $zips.Count
        exit_counts = $counts
        determinism_hashes = @($hashes | Sort-Object)
        telemetry_bytes = (Get-MinMax -Values $telemetryBytes)
        runtime_sec = (Get-MinMaxAvg -Values $runtimeSec)
        triage_paths = @($triagePaths)
        failing_invariants = @($failingInvariants | Sort-Object)
        polish_score_total_loss = (Get-MinMaxAvg -Values $scoreLosses)
        polish_score_grades = @($scoreGrades | Sort-Object)
        error = $null
    }
}

$UnityExe = Resolve-UnityExe -ExePath $UnityExe
$dateStamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd")

function Get-ToolsSha {
    $toolsRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    try {
        $sha = & git -C $toolsRoot rev-parse HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($sha)) {
            return $sha.Trim()
        }
    }
    catch {
    }
    return $null
}

$toolsSha = Get-ToolsSha
$titleValue = $Title.ToLowerInvariant()
switch ($titleValue) {
    "space4x" { $titles = @("space4x") }
    "godgame" { $titles = @("godgame") }
    "both" { $titles = @("space4x", "godgame") }
    default { throw "Unknown Title: $Title" }
}

$hasErrors = $false
foreach ($title in $titles) {
    $queueRoot = if ($title -eq "space4x") { $QueueRootSpace4x } else { $QueueRootGodgame }
    $reportsDir = Join-Path $queueRoot "reports"
    Ensure-Directory $reportsDir

    try {
        $run = Invoke-Smoke -Title $title -UnityExePath $UnityExe -QueueRootPath $queueRoot -RepeatCount $Repeat -WaitTimeoutSec $WaitTimeoutSec
    }
    catch {
        $run = [pscustomobject][ordered]@{
            title = $title
            build_id = $null
            artifact_zip = $null
            exit_code = 1
            error = $_.Exception.Message
            start_utc = (Get-Date).ToUniversalTime().ToString("o")
            end_utc = (Get-Date).ToUniversalTime().ToString("o")
        }
    }

    $summary = [ordered]@{
        date_utc = $dateStamp
        queue_root = $queueRoot
        tools_sha = $toolsSha
        runs = [ordered]@{}
    }

    $triageAll = New-Object System.Collections.Generic.List[string]
    $entry = [pscustomobject][ordered]@{
        build_id = $run.build_id
        artifact_zip = $run.artifact_zip
        pipeline_exit_code = $run.exit_code
        result_count = 0
        exit_reason_counts = @{}
        determinism_hashes = @()
        telemetry_bytes = $null
        runtime_sec = $null
        triage_paths = @()
        failing_invariants = @()
        polish_score_total_loss = $null
        polish_score_grades = @()
        notes = @()
        error = $null
    }
    $runErrorProp = $run.PSObject.Properties["error"]
    if ($runErrorProp -and -not [string]::IsNullOrWhiteSpace([string]$runErrorProp.Value)) {
        $entry.error = $runErrorProp.Value
        $hasErrors = $true
    }
    $buildIdValue = $null
    $buildIdProp = $run.PSObject.Properties["build_id"]
    if ($buildIdProp) { $buildIdValue = [string]$buildIdProp.Value }
    if ([string]::IsNullOrWhiteSpace($buildIdValue)) {
        $artifactProp = $run.PSObject.Properties["artifact_zip"]
        if ($artifactProp -and -not [string]::IsNullOrWhiteSpace([string]$artifactProp.Value)) {
            $buildIdValue = Parse-BuildIdFromArtifact -ArtifactPath ([string]$artifactProp.Value)
        }
        if ([string]::IsNullOrWhiteSpace($buildIdValue)) {
            $artifactsDir = Join-Path $queueRoot "artifacts"
            $artifact = Get-ArtifactZip -ArtifactsDir $artifactsDir -SinceUtc $null
            if ($artifact) {
                $buildIdValue = Parse-BuildIdFromArtifact -ArtifactPath $artifact.FullName
            }
        }
        if ([string]::IsNullOrWhiteSpace($buildIdValue)) {
            $resultsDir = Join-Path $queueRoot "results"
            $latestResult = Get-LatestResultZip -ResultsDir $resultsDir -Title $run.title
            if ($latestResult) {
                $buildIdValue = Parse-BuildIdFromResult -ResultPath $latestResult.FullName -Title $run.title
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($buildIdValue)) {
            $entry.build_id = $buildIdValue
        }
    }
    if ([string]::IsNullOrWhiteSpace($buildIdValue)) {
        if (-not $entry.error) { $entry.error = "build_id_missing" }
        $hasErrors = $true
    }
    else {
        $stats = @(Summarize-Results -QueueRootPath $queueRoot -BuildId $buildIdValue -Title $run.title -ReportsDir $reportsDir)[0]
        $entry.result_count = $stats.result_count
        $entry.exit_reason_counts = $stats.exit_counts
        $entry.determinism_hashes = $stats.determinism_hashes
        $entry.telemetry_bytes = $stats.telemetry_bytes
        $entry.runtime_sec = $stats.runtime_sec
        $entry.triage_paths = $stats.triage_paths
        $entry.failing_invariants = $stats.failing_invariants
        $entry.polish_score_total_loss = $stats.polish_score_total_loss
        $entry.polish_score_grades = $stats.polish_score_grades
        $statsErrorProp = $stats.PSObject.Properties["error"]
        if ($statsErrorProp -and $statsErrorProp.Value) {
            $entry.error = $statsErrorProp.Value
            $hasErrors = $true
        }
        foreach ($path in $stats.triage_paths) {
            $triageAll.Add($path)
        }
    }
    $summary.runs[$run.title] = $entry

    $summaryPath = Join-Path $reportsDir ("nightly_{0}_{1}.json" -f $dateStamp, $title)
    $summaryJson = $summary | ConvertTo-Json -Depth 6
    Set-Content -Path $summaryPath -Value $summaryJson -Encoding ascii
    Write-Host ("Wrote nightly summary: {0}" -f $summaryPath)
    foreach ($path in $triageAll) {
        Write-Host ("triage={0}" -f $path)
    }
}

if ($hasErrors) {
    exit 1
}
