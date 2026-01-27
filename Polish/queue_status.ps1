[CmdletBinding()]
param(
    [string]$QueueRoot = "C:\\polish\\queue",
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Directory {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function Read-ZipEntryText {
    param(
        [System.IO.Compression.ZipArchive]$Archive,
        [string]$EntryPath
    )
    $entry = $Archive.GetEntry($EntryPath)
    if (-not $entry) {
        $entry = $Archive.Entries | Where-Object { $_.FullName -ieq $EntryPath } | Select-Object -First 1
    }
    if (-not $entry) { return $null }
    $reader = New-Object System.IO.StreamReader($entry.Open())
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function Read-BuildOutcome {
    param([string]$ZipPath)
    if (-not (Test-Path $ZipPath)) { return $null }
    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $text = Read-ZipEntryText -Archive $archive -EntryPath "logs/build_outcome.json"
        if (-not $text) { return $null }
        try { return ($text | ConvertFrom-Json) } catch { return $null }
    }
    finally {
        $archive.Dispose()
    }
}

function Read-ResultMeta {
    param([string]$ZipPath)
    if (-not (Test-Path $ZipPath)) { return $null }
    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $text = Read-ZipEntryText -Archive $archive -EntryPath "meta.json"
        if (-not $text) { return $null }
        try { return ($text | ConvertFrom-Json) } catch { return $null }
    }
    finally {
        $archive.Dispose()
    }
}

$queueRootFull = [System.IO.Path]::GetFullPath($QueueRoot)
$reportsDir = Join-Path $queueRootFull "reports"
Ensure-Directory $reportsDir

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $reportsDir "queue_status.md"
}

$artifactsDir = Join-Path $queueRootFull "artifacts"
$jobsDir = Join-Path $queueRootFull "jobs"
$leasesDir = Join-Path $queueRootFull "leases"
$resultsDir = Join-Path $queueRootFull "results"

$artifact = Get-ChildItem -Path $artifactsDir -Filter "artifact_*.zip" -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$job = Get-ChildItem -Path $jobsDir -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$lease = Get-ChildItem -Path $leasesDir -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$result = Get-ChildItem -Path $resultsDir -Filter "result_*.zip" -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("# Queue Status")
$lines.Add("")
$lines.Add("* utc: " + (Get-Date).ToUniversalTime().ToString("o"))
$lines.Add("* artifacts_dir: $artifactsDir")
$lines.Add("* jobs_dir: $jobsDir")
$lines.Add("* leases_dir: $leasesDir")
$lines.Add("* results_dir: $resultsDir")

if ($artifact) {
    $lines.Add("* latest_artifact: $($artifact.FullName)")
    $outcome = Read-BuildOutcome -ZipPath $artifact.FullName
    if ($outcome) {
        $lines.Add("  - build_id: $($outcome.build_id)")
        $lines.Add("  - commit: $($outcome.commit)")
        $lines.Add("  - result: $($outcome.result)")
        if ($outcome.message) { $lines.Add("  - message: $($outcome.message)") }
    }
}
else {
    $lines.Add("* latest_artifact: (none)")
}

if ($job) {
    $lines.Add("* latest_job: $($job.FullName)")
}
else {
    $lines.Add("* latest_job: (none)")
}

if ($lease) {
    $lines.Add("* latest_lease: $($lease.FullName)")
}
else {
    $lines.Add("* latest_lease: (none)")
}

if ($result) {
    $lines.Add("* latest_result: $($result.FullName)")
    $meta = Read-ResultMeta -ZipPath $result.FullName
    if ($meta) {
        if ($meta.exit_reason) { $lines.Add("  - exit_reason: $($meta.exit_reason)") }
        if ($meta.exit_code -ne $null) { $lines.Add("  - exit_code: $($meta.exit_code)") }
        if ($meta.failure_signature) { $lines.Add("  - failure_signature: $($meta.failure_signature)") }
    }
}
else {
    $lines.Add("* latest_result: (none)")
}

$lines.Add("")
Set-Content -Path $OutputPath -Value ($lines -join "`r`n") -Encoding ascii
Write-Host ("queue_status_written path={0}" -f $OutputPath)
