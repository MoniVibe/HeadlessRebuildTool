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
    [int]$Repeat = 1,
    [int]$WaitTimeoutSec = 900,
    [int]$BuildTimeoutMinutes = 90,
    [int]$RunLockTimeoutSec = 0,
    [switch]$AllowConcurrent
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Directory {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function Acquire-HeadlessRunLock {
    param([int]$TimeoutSec)
    $mutexName = "Local\TRI_HEADLESS_UNITY_LOCK"
    $mutex = New-Object System.Threading.Mutex($false, $mutexName)
    $acquired = $false
    try {
        if ($TimeoutSec -le 0) {
            $acquired = $mutex.WaitOne(0)
        } else {
            $acquired = $mutex.WaitOne($TimeoutSec * 1000)
        }
    }
    catch [System.Threading.AbandonedMutexException] {
        $acquired = $true
    }
    if (-not $acquired) {
        $mutex.Dispose()
        throw "Headless run lock is busy (another Unity headless run is active)."
    }
    return $mutex
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
    if (-not $entry) {
        $entry = $Archive.Entries | Where-Object { $_.FullName -ieq $EntryPath } | Select-Object -First 1
    }
    if (-not $entry) { return $null }
    $reader = New-Object System.IO.StreamReader($entry.Open())
    try {
        return $reader.ReadToEnd()
    }
    finally {
        $reader.Dispose()
    }
}

function Get-ResultDetails {
    param([string]$ZipPath)
    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $metaText = Read-ZipEntryText -Archive $archive -EntryPath "meta.json"
        $exitReason = "UNKNOWN"
        $exitCode = ""
        $failureSignature = ""
        if ($metaText) {
            try {
                $meta = $metaText | ConvertFrom-Json
                if ($meta.exit_reason) { $exitReason = $meta.exit_reason }
                if ($meta.exit_code -ne $null) { $exitCode = $meta.exit_code }
                if ($meta.failure_signature) { $failureSignature = $meta.failure_signature }
            }
            catch {
            }
        }

        $determinismHash = ""
        $invText = Read-ZipEntryText -Archive $archive -EntryPath "out/invariants.json"
        $failingInvariants = @()
        if ($invText) {
            try {
                $inv = $invText | ConvertFrom-Json
                if ($inv.determinism_hash) { $determinismHash = $inv.determinism_hash }
                if ($inv.invariants) {
                    foreach ($record in $inv.invariants) {
                        if ($record.status -and $record.status -ne "PASS") {
                            $failingInvariants += $record.id
                        }
                    }
                }
            }
            catch {
            }
        }

        return [ordered]@{
            exit_reason = $exitReason
            exit_code = $exitCode
            failure_signature = $failureSignature
            determinism_hash = $determinismHash
            failing_invariants = $failingInvariants
        }
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
        try { return ($invText | ConvertFrom-Json) } catch { return $null }
    }
    finally {
        $archive.Dispose()
    }
}

function Format-ResultSummary {
    param(
        [int]$Index,
        [int]$Total,
        [hashtable]$Details
    )
    $parts = @(
        "run_index=$Index",
        "run_total=$Total",
        "exit_reason=$($Details.exit_reason)"
    )
    if ($Details.exit_code -ne "") { $parts += "exit_code=$($Details.exit_code)" }
    if ($Details.failure_signature) { $parts += "failure_signature=$($Details.failure_signature)" }
    if ($Details.determinism_hash) { $parts += "determinism_hash=$($Details.determinism_hash)" }
    if ($Details.failing_invariants -and $Details.failing_invariants.Count -gt 0) {
        $parts += "failing_invariants=$([string]::Join(',', $Details.failing_invariants))"
    }
    return ($parts -join " ")
}

function Write-InvariantDiff {
    param(
        [object]$Baseline,
        [object]$Current,
        [string]$BaselineLabel,
        [string]$CurrentLabel
    )
    if (-not $Baseline -or -not $Current) {
        Write-Host "determinism_diff: invariants missing in one or both runs"
        return
    }

    Write-Host ("determinism_diff sim_ticks {0}={1} {2}={3}" -f $BaselineLabel, $Baseline.sim_ticks, $CurrentLabel, $Current.sim_ticks)

    $metricsA = if ($Baseline.metrics) { $Baseline.metrics | ConvertTo-Json -Compress } else { "null" }
    $metricsB = if ($Current.metrics) { $Current.metrics | ConvertTo-Json -Compress } else { "null" }
    Write-Host ("determinism_diff metrics {0}={1} {2}={3}" -f $BaselineLabel, $metricsA, $CurrentLabel, $metricsB)

    $mapA = @{}
    if ($Baseline.invariants) {
        foreach ($record in $Baseline.invariants) {
            $mapA[$record.id] = $record
        }
    }
    $mapB = @{}
    if ($Current.invariants) {
        foreach ($record in $Current.invariants) {
            $mapB[$record.id] = $record
        }
    }
    $ids = @($mapA.Keys + $mapB.Keys) | Sort-Object -Unique
    $ids = @($ids)
    if ($ids.Count -eq 0) {
        Write-Host ("determinism_diff invariants {0}=[] {1}=[]" -f $BaselineLabel, $CurrentLabel)
        return
    }
    foreach ($id in $ids) {
        $a = $mapA[$id]
        $b = $mapB[$id]
        $aStatus = if ($a) { $a.status } else { "<missing>" }
        $bStatus = if ($b) { $b.status } else { "<missing>" }
        $aObserved = if ($a) { $a.observed } else { "<missing>" }
        $bObserved = if ($b) { $b.observed } else { "<missing>" }
        $aExpected = if ($a) { $a.expected } else { "<missing>" }
        $bExpected = if ($b) { $b.expected } else { "<missing>" }
        Write-Host ("determinism_diff invariant {0} {1} status={2} observed={3} expected={4} {5} status={6} observed={7} expected={8}" -f $id, $BaselineLabel, $aStatus, $aObserved, $aExpected, $CurrentLabel, $bStatus, $bObserved, $bExpected)
    }
}

function Get-ArtifactPreflight {
    param([string]$ZipPath)
    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $outcomeText = Read-ZipEntryText -Archive $archive -EntryPath "logs/build_outcome.json"
        if (-not $outcomeText) {
            return @{ ok = $false; reason = "build_outcome_missing" }
        }
        $manifestText = Read-ZipEntryText -Archive $archive -EntryPath "build_manifest.json"
        if (-not $manifestText) {
            return @{ ok = $false; reason = "build_manifest_missing" }
        }

        try { $outcome = $outcomeText | ConvertFrom-Json } catch { return @{ ok = $false; reason = "build_outcome_invalid" } }
        try { $manifest = $manifestText | ConvertFrom-Json } catch { return @{ ok = $false; reason = "build_manifest_invalid" } }

        if ($outcome.result -ne "Succeeded") {
            $message = if ($outcome.message) { $outcome.message } else { "build_failed" }
            return @{ ok = $false; reason = "build_failed"; message = $message; result = $outcome.result }
        }
        if ([string]::IsNullOrWhiteSpace($manifest.entrypoint)) {
            return @{ ok = $false; reason = "entrypoint_missing" }
        }
        return @{ ok = $true }
    }
    finally {
        $archive.Dispose()
    }
}

$runLock = $null
try {
if (-not $AllowConcurrent) {
    $runLock = Acquire-HeadlessRunLock -TimeoutSec $RunLockTimeoutSec
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

$syncScript = Join-Path $triRoot "Tools\\sync_headless_manifest.ps1"
$swapScript = Join-Path $triRoot "Tools\\Tools\\use_headless_manifest_windows.ps1"
if (-not (Test-Path $syncScript)) {
    throw "Missing headless manifest sync script: $syncScript"
}
if (-not (Test-Path $swapScript)) {
    throw "Missing headless manifest swap script: $swapScript"
}

$scenarioIdValue = if ($PSBoundParameters.ContainsKey("ScenarioId")) { $ScenarioId } else { $titleDefaults.scenario_id }
$seedValue = if ($PSBoundParameters.ContainsKey("Seed")) { $Seed } else { [int]$titleDefaults.seed }
$timeoutValue = if ($PSBoundParameters.ContainsKey("TimeoutSec")) { $TimeoutSec } else { [int]$titleDefaults.timeout_sec }
$argsValue = if ($PSBoundParameters.ContainsKey("Args")) { $Args } else { $titleDefaults.args }
if ($null -eq $argsValue) { $argsValue = @() }
if ($Repeat -lt 1) {
    throw "Repeat must be >= 1."
}

$commitFull = & git -C $projectPath rev-parse HEAD 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "git rev-parse HEAD failed: $commitFull"
}
$commitShort = & git -C $projectPath rev-parse --short=8 HEAD 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "git rev-parse --short failed: $commitShort"
}

$timestamp = ([DateTime]::UtcNow).ToString("yyyyMMdd_HHmmss_fff")
$buildId = "${timestamp}_$commitShort"

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
    "--artifact-dir", $artifactsDir,
    "--timeout-minutes", $BuildTimeoutMinutes
)

$swapApplied = $false
& $syncScript -ProjectPath $projectPath
& $swapScript -ProjectPath $projectPath
$swapApplied = $true
try {
    & dotnet @supervisorArgs
}
finally {
    if ($swapApplied) {
        & $swapScript -ProjectPath $projectPath -Restore
    }
}
$supervisorExit = $LASTEXITCODE
if ($supervisorExit -ne 0) {
    Write-Warning "HeadlessBuildSupervisor exited with code $supervisorExit"
}

$artifactZip = Join-Path $artifactsDir ("artifact_{0}.zip" -f $buildId)
if (-not (Test-Path $artifactZip)) {
    throw "Artifact zip not found: $artifactZip"
}

$preflight = Get-ArtifactPreflight -ZipPath $artifactZip
if (-not $preflight.ok) {
    $summary = "BUILD_FAIL reason={0}" -f $preflight.reason
    if ($preflight.result) { $summary += " result=$($preflight.result)" }
    if ($preflight.message) { $summary += " message=$($preflight.message)" }
    Write-Host $summary
    exit 1
}

$artifactUri = Convert-ToWslPath $artifactZip
Write-Host ("build_id={0} commit={1}" -f $buildId, $commitFull)
Write-Host ("artifact={0}" -f $artifactZip)

$baselineHash = $null
$baselineZip = $null
$baselineIndex = 0

for ($i = 1; $i -le $Repeat; $i++) {
    $suffix = ""
    if ($Repeat -gt 1) {
        $suffix = "_r{0:D2}" -f $i
    }
    $jobId = "{0}_{1}_{2}{3}" -f $buildId, $scenarioIdValue, $seedValue, $suffix
    $createdUtc = ([DateTime]::UtcNow).ToString("o")

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

        $details = Get-ResultDetails -ZipPath $resultZip
        $summary = Format-ResultSummary -Index $i -Total $Repeat -Details $details
        Write-Host $summary

        if ($details.exit_reason -in @("INFRA_FAIL", "CRASH", "HANG_TIMEOUT")) {
            Write-Host ("stop_reason={0}" -f $details.exit_reason)
            exit 2
        }

        if ([string]::IsNullOrWhiteSpace($details.determinism_hash)) {
            Write-Host ("stop_reason=determinism_hash_missing run_index={0}" -f $i)
            exit 3
        }

        if ($i -eq 1) {
            $baselineHash = $details.determinism_hash
            $baselineZip = $resultZip
            $baselineIndex = $i
        }
        elseif ($details.determinism_hash -ne $baselineHash) {
            Write-Host ("stop_reason=determinism_hash_divergence baseline={0} current={1}" -f $baselineHash, $details.determinism_hash)
            $baselineInv = Get-ResultInvariants -ZipPath $baselineZip
            $currentInv = Get-ResultInvariants -ZipPath $resultZip
            Write-InvariantDiff -Baseline $baselineInv -Current $currentInv -BaselineLabel ("run{0}" -f $baselineIndex) -CurrentLabel ("run{0}" -f $i)
            exit 3
        }
    }
}
}
finally {
    if ($runLock) {
        try { $runLock.ReleaseMutex() } catch { }
        $runLock.Dispose()
    }
}
