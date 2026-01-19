param(
    [string]$QueueRoot = "C:\\polish\\queue",
    [int]$RetentionDays = 30,
    [int]$KeepLastPerScenario = 3,
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($RetentionDays -lt 0) {
    throw "RetentionDays must be >= 0."
}
if ($KeepLastPerScenario -lt 0) {
    throw "KeepLastPerScenario must be >= 0."
}

function Format-Bytes {
    param([long]$Bytes)
    if ($Bytes -lt 1kb) { return "$Bytes B" }
    if ($Bytes -lt 1mb) { return "{0:N1} KB" -f ($Bytes / 1kb) }
    if ($Bytes -lt 1gb) { return "{0:N1} MB" -f ($Bytes / 1mb) }
    if ($Bytes -lt 1tb) { return "{0:N2} GB" -f ($Bytes / 1gb) }
    return "{0:N2} TB" -f ($Bytes / 1tb)
}

function Get-JobIdFromResultName {
    param([string]$FileName)
    if ($FileName -match '^result_(.+)\.zip$') { return $matches[1] }
    return $null
}

function Get-JobIdFromTriageName {
    param([string]$FileName)
    if ($FileName -match '^triage_(.+)\.json$') { return $matches[1] }
    return $null
}

function Get-BuildIdFromArtifactName {
    param([string]$FileName)
    if ($FileName -match '^artifact_(.+)\.zip$') { return $matches[1] }
    return $null
}

function ConvertFrom-JobId {
    param([string]$JobId)
    if ([string]::IsNullOrWhiteSpace($JobId)) { return $null }
    $core = $JobId
    if ($core -match '^(?<base>.+)_r\d+$') {
        $core = $matches.base
    }
    if ($core -match '^(?<buildId>\d{8}_\d{6}_[0-9a-fA-F]+)_(?<scenario>.+)_(?<seed>\d+)$') {
        return [pscustomobject]@{
            build_id = $matches.buildId
            scenario = $matches.scenario
            seed = $matches.seed
        }
    }
    return $null
}

function Add-DeleteItem {
    param(
        [System.IO.FileInfo]$File,
        [string]$Category,
        [System.Collections.Generic.List[object]]$Target
    )
    $Target.Add([pscustomobject]@{
        path = $File.FullName
        length = $File.Length
        category = $Category
        last_write_utc = $File.LastWriteTimeUtc
    }) | Out-Null
}

$queueRootFull = [System.IO.Path]::GetFullPath($QueueRoot)
if (-not (Test-Path $queueRootFull)) {
    throw "QueueRoot does not exist: $queueRootFull"
}

$cutoffUtc = (Get-Date).ToUniversalTime().AddDays(-$RetentionDays)
$resultsDir = Join-Path $queueRootFull "results"
$artifactsDir = Join-Path $queueRootFull "artifacts"
$reportsDir = Join-Path $queueRootFull "reports"

$results = @()
if (Test-Path $resultsDir) {
    $resultFiles = Get-ChildItem -Path $resultsDir -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "result_*.zip" -and $_.FullName -notmatch '\\results\\\.tmp\\' }
    foreach ($file in $resultFiles) {
        $jobId = Get-JobIdFromResultName -FileName $file.Name
        $parsed = ConvertFrom-JobId -JobId $jobId
        $results += [pscustomobject]@{
            file = $file
            job_id = $jobId
            scenario = if ($parsed) { $parsed.scenario } else { $null }
            build_id = if ($parsed) { $parsed.build_id } else { $null }
        }
    }
}

$keepResultPaths = New-Object System.Collections.Generic.HashSet[string]
$keepJobIds = New-Object System.Collections.Generic.HashSet[string]
$keepBuildIds = New-Object System.Collections.Generic.HashSet[string]

if ($KeepLastPerScenario -gt 0 -and $results.Count -gt 0) {
    $groups = $results | Where-Object { $_.scenario } | Group-Object scenario
    foreach ($group in $groups) {
        $kept = $group.Group |
            Sort-Object { $_.file.LastWriteTimeUtc } -Descending |
            Select-Object -First $KeepLastPerScenario
        foreach ($entry in $kept) {
            [void]$keepResultPaths.Add($entry.file.FullName)
            if ($entry.job_id) { [void]$keepJobIds.Add($entry.job_id) }
            if ($entry.build_id) { [void]$keepBuildIds.Add($entry.build_id) }
        }
    }
}

$deleteItems = New-Object System.Collections.Generic.List[object]

foreach ($entry in $results) {
    $file = $entry.file
    if ($file.LastWriteTimeUtc -ge $cutoffUtc) { continue }
    if ($keepResultPaths.Contains($file.FullName)) { continue }
    Add-DeleteItem -File $file -Category "results" -Target $deleteItems
}

if (Test-Path $artifactsDir) {
    $artifactFiles = Get-ChildItem -Path $artifactsDir -File -Filter "artifact_*.zip" -ErrorAction SilentlyContinue
    foreach ($file in $artifactFiles) {
        $buildId = Get-BuildIdFromArtifactName -FileName $file.Name
        if ($buildId -and $keepBuildIds.Contains($buildId)) { continue }
        if ($file.LastWriteTimeUtc -ge $cutoffUtc) { continue }
        Add-DeleteItem -File $file -Category "artifacts" -Target $deleteItems
    }
}

if (Test-Path $reportsDir) {
    $reportFiles = Get-ChildItem -Path $reportsDir -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\reports\\\.tmp\\' }
    foreach ($file in $reportFiles) {
        $jobId = Get-JobIdFromTriageName -FileName $file.Name
        if ($jobId -and $keepJobIds.Contains($jobId)) { continue }
        if ($file.LastWriteTimeUtc -ge $cutoffUtc) { continue }
        Add-DeleteItem -File $file -Category "reports" -Target $deleteItems
    }
}

$modeLabel = if ($Apply) { "APPLY" } else { "DRY-RUN" }
$reclaimBytes = ($deleteItems | Measure-Object -Property length -Sum).Sum
if ($null -eq $reclaimBytes) { $reclaimBytes = 0 }

Write-Host ("Queue cleanup ({0})" -f $modeLabel)
Write-Host ("Queue root: {0}" -f $queueRootFull)
Write-Host ("Retention: {0} days (cutoff {1})" -f $RetentionDays, $cutoffUtc.ToString("yyyy-MM-dd"))
Write-Host ("Keep last per scenario: {0}" -f $KeepLastPerScenario)
Write-Host ("Delete candidates: {0}" -f $deleteItems.Count)

$counts = $deleteItems | Group-Object category | Sort-Object Name
foreach ($group in $counts) {
    Write-Host ("  {0}: {1}" -f $group.Name, $group.Count)
}

Write-Host ("Estimated reclaim: {0}" -f (Format-Bytes -Bytes $reclaimBytes))

if (-not $Apply) {
    Write-Host "Dry-run mode (no files deleted). Use -Apply to delete."
    return
}

$deletedBytes = 0
$deletedCount = 0
foreach ($item in $deleteItems) {
    try {
        Remove-Item -LiteralPath $item.path -Force -ErrorAction Stop
        $deletedCount += 1
        $deletedBytes += [long]$item.length
    }
    catch {
        Write-Warning ("Failed to delete: {0} ({1})" -f $item.path, $_.Exception.Message)
    }
}

Write-Host ("Deleted: {0} file(s)" -f $deletedCount)
Write-Host ("Reclaimed: {0}" -f (Format-Bytes -Bytes $deletedBytes))
