[CmdletBinding()]
param(
    [string]$UnityExe,
    [string]$QueueRoot = "C:\\polish\\queue",
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

function Invoke-Smoke {
    param(
        [string]$Title,
        [string]$UnityExePath,
        [string]$QueueRootPath,
        [int]$RepeatCount,
        [int]$WaitTimeoutSec
    )
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    $pipelineSmoke = Join-Path $scriptRoot "pipeline_smoke.ps1"
    if (-not (Test-Path $pipelineSmoke)) {
        throw "pipeline_smoke.ps1 not found: $pipelineSmoke"
    }

    $args = @(
        "-Title", $Title,
        "-UnityExe", $UnityExePath,
        "-QueueRoot", $QueueRootPath,
        "-Repeat", $RepeatCount,
        "-WaitForResult",
        "-WaitTimeoutSec", $WaitTimeoutSec
    )

    $output = & $pipelineSmoke @args 2>&1 | ForEach-Object { $_.ToString() }
    $exitCode = $LASTEXITCODE
    $buildId = $null
    foreach ($line in $output) {
        if ($line -match "build_id=([^ ]+)") {
            $buildId = $Matches[1]
            break
        }
    }

    return [ordered]@{
        title = $Title
        build_id = $buildId
        exit_code = $exitCode
        output = $output
    }
}

function Summarize-Results {
    param(
        [string]$QueueRootPath,
        [string]$BuildId,
        [string]$ReportsDir
    )
    $resultsDir = Join-Path $QueueRootPath "results"
    $pattern = "result_{0}_*.zip" -f $BuildId
    $zips = Get-ChildItem -Path $resultsDir -Filter $pattern -File | Sort-Object Name

    $counts = @{}
    $hashes = New-Object System.Collections.Generic.HashSet[string]
    $triagePaths = New-Object System.Collections.Generic.List[string]

    foreach ($zip in $zips) {
        $meta = Get-ResultMeta -ZipPath $zip.FullName
        if (-not $meta) { continue }
        $exitReason = $meta.exit_reason
        if ([string]::IsNullOrWhiteSpace($exitReason)) { $exitReason = "UNKNOWN" }
        if ($counts.ContainsKey($exitReason)) {
            $counts[$exitReason] += 1
        }
        else {
            $counts[$exitReason] = 1
        }

        $jobId = $meta.job_id
        if ($exitReason -ne "SUCCESS" -and -not [string]::IsNullOrWhiteSpace($jobId)) {
            $triagePaths.Add((Join-Path $ReportsDir ("triage_{0}.json" -f $jobId)))
        }

        $inv = Get-ResultInvariants -ZipPath $zip.FullName
        if ($inv -and $inv.determinism_hash) {
            [void]$hashes.Add([string]$inv.determinism_hash)
        }
    }

    return [ordered]@{
        total = $zips.Count
        exit_counts = $counts
        determinism_hashes = @($hashes | Sort-Object)
        triage_paths = @($triagePaths)
    }
}

$UnityExe = Resolve-UnityExe -ExePath $UnityExe
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$reportsDir = Join-Path $QueueRoot "reports"
Ensure-Directory $reportsDir

$runs = @()
$runs += Invoke-Smoke -Title "space4x" -UnityExePath $UnityExe -QueueRootPath $QueueRoot -RepeatCount $Repeat -WaitTimeoutSec $WaitTimeoutSec
$runs += Invoke-Smoke -Title "godgame" -UnityExePath $UnityExe -QueueRootPath $QueueRoot -RepeatCount $Repeat -WaitTimeoutSec $WaitTimeoutSec

$dateStamp = (Get-Date).ToString("yyyy-MM-dd")
$summaryPath = Join-Path $reportsDir ("nightly_{0}.json" -f $dateStamp)

$summary = [ordered]@{
    date = $dateStamp
    queue_root = $QueueRoot
    runs = @()
}

$triageAll = New-Object System.Collections.Generic.List[string]

foreach ($run in $runs) {
    $entry = [ordered]@{
        title = $run.title
        build_id = $run.build_id
        exit_code = $run.exit_code
    }
    if ([string]::IsNullOrWhiteSpace($run.build_id)) {
        $entry.error = "build_id_missing"
    }
    else {
        $stats = Summarize-Results -QueueRootPath $QueueRoot -BuildId $run.build_id -ReportsDir $reportsDir
        $entry.total = $stats.total
        $entry.exit_counts = $stats.exit_counts
        $entry.determinism_hashes = $stats.determinism_hashes
        $entry.triage_paths = $stats.triage_paths
        foreach ($path in $stats.triage_paths) {
            $triageAll.Add($path)
        }
    }
    $summary.runs += $entry
}

$summaryJson = $summary | ConvertTo-Json -Depth 6
Set-Content -Path $summaryPath -Value $summaryJson -Encoding ascii

Write-Host ("Wrote nightly summary: {0}" -f $summaryPath)
foreach ($path in $triageAll) {
    Write-Host ("triage={0}" -f $path)
}
