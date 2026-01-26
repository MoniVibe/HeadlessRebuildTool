[CmdletBinding()]
param(
    [string]$UnityExe,
    [ValidateSet("space4x", "godgame", "both")]
    [string]$Title = "both",
    [string]$QueueRootSpace4x = "C:\\polish\\anviloop\\space4x\\queue",
    [string]$QueueRootGodgame = "C:\\polish\\anviloop\\godgame\\queue",
    [int]$Repeat = 10,
    [int]$WaitTimeoutSec = 1800,
    [ValidateSet("legacy", "tier0", "tier1", "all")]
    [string]$Tier = "legacy",
    [string]$TierConfigPath
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

function Get-ArtifactManifest {
    param([string]$ZipPath)
    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $text = Read-ZipEntryText -Archive $archive -EntryPath "build_manifest.json"
        if (-not $text) { return $null }
        return $text | ConvertFrom-Json
    }
    finally {
        $archive.Dispose()
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

function Get-TierConfig {
    param([string]$ConfigPath)
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) { return $null }
    if (-not (Test-Path $ConfigPath)) {
        throw "Tier config not found: $ConfigPath"
    }
    return (Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json)
}

function Get-TitleDefaults {
    param(
        [string]$Title,
        [string]$ScriptRoot,
        [string]$TriRoot
    )
    $defaultsPath = Join-Path $ScriptRoot "pipeline_defaults.json"
    if (-not (Test-Path $defaultsPath)) {
        throw "Missing defaults file: $defaultsPath"
    }
    $defaults = Get-Content -Raw -Path $defaultsPath | ConvertFrom-Json
    $titleKey = $Title.ToLowerInvariant()
    $titleDefaults = $defaults.titles.$titleKey
    if (-not $titleDefaults) {
        throw "Unknown title '$Title'. Check pipeline_defaults.json."
    }
    $projectPath = Join-Path $TriRoot $titleDefaults.project_path
    if (-not (Test-Path $projectPath)) {
        throw "Project path not found: $projectPath"
    }
    return [pscustomobject]@{
        project_path = $projectPath
        defaults = $titleDefaults
    }
}

function Invoke-Build {
    param(
        [string]$Title,
        [string]$UnityExePath,
        [string]$QueueRootPath,
        [string]$ScriptRoot,
        [string]$TriRoot
    )
    $titleInfo = Get-TitleDefaults -Title $Title -ScriptRoot $ScriptRoot -TriRoot $TriRoot
    $projectPath = $titleInfo.project_path

    if (-not (Test-Path $UnityExePath)) {
        throw "Unity exe not found: $UnityExePath"
    }

    $commitFull = & git -C $projectPath rev-parse HEAD 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git rev-parse HEAD failed: $commitFull"
    }
    $commitShort = & git -C $projectPath rev-parse --short=8 HEAD 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git rev-parse --short failed: $commitShort"
    }
    $commitFull = $commitFull.ToString().Trim()
    $commitShort = $commitShort.ToString().Trim()

    $timestamp = ([DateTime]::UtcNow).ToString("yyyyMMdd_HHmmss_fff")
    $buildId = "${timestamp}_$commitShort"

    $queueRootFull = [System.IO.Path]::GetFullPath($QueueRootPath)
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

    $supervisorProject = Join-Path $TriRoot "Tools\\HeadlessBuildSupervisor\\HeadlessBuildSupervisor.csproj"
    if (-not (Test-Path $supervisorProject)) {
        throw "HeadlessBuildSupervisor.csproj not found: $supervisorProject"
    }

    $supervisorArgs = @(
        "run", "--project", $supervisorProject, "--",
        "--unity-exe", $UnityExePath,
        "--project-path", $projectPath,
        "--build-id", $buildId,
        "--commit", $commitFull,
        "--artifact-dir", $artifactsDir
    )

    $syncScript = Join-Path $TriRoot "Tools\\sync_headless_manifest.ps1"
    $swapScript = Join-Path $TriRoot "Tools\\Tools\\use_headless_manifest_windows.ps1"
    if (-not (Test-Path $syncScript)) {
        throw "Missing headless manifest sync script: $syncScript"
    }
    if (-not (Test-Path $swapScript)) {
        throw "Missing headless manifest swap script: $swapScript"
    }

    $swapApplied = $false
    & $syncScript -ProjectPath $projectPath | Out-Null
    & $swapScript -ProjectPath $projectPath | Out-Null
    $swapApplied = $true
    try {
        & dotnet @supervisorArgs | ForEach-Object { Write-Host $_ }
    }
    finally {
        if ($swapApplied) {
            & $swapScript -ProjectPath $projectPath -Restore | Out-Null
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
        throw $summary
    }

    return [pscustomobject][ordered]@{
        build_id = $buildId
        commit = $commitFull
        artifact_zip = $artifactZip
    }
}

function Queue-TierJob {
    param(
        [string]$JobsDir,
        [object]$Job
    )
    $jobId = $Job.job_id
    $jobJson = $Job | ConvertTo-Json -Depth 8
    $jobTempPath = Join-Path $JobsDir (".tmp_{0}.json" -f $jobId)
    $jobPath = Join-Path $JobsDir ("{0}.json" -f $jobId)
    Set-Content -Path $jobTempPath -Value $jobJson -Encoding ascii
    Move-Item -Path $jobTempPath -Destination $jobPath -Force
    return $jobPath
}

function Wait-ForResultZip {
    param(
        [string]$ResultsDir,
        [string]$JobId,
        [int]$WaitTimeoutSec
    )
    $resultZip = Join-Path $ResultsDir ("result_{0}.zip" -f $JobId)
    $deadline = (Get-Date).AddSeconds($WaitTimeoutSec)
    $stableSeconds = 5
    $stableDeadline = $null
    $lastSize = -1
    while ($true) {
        $now = Get-Date
        if (Test-Path $resultZip) {
            $item = Get-Item $resultZip -ErrorAction SilentlyContinue
            if ($item) {
                if ($item.Length -ne $lastSize) {
                    $lastSize = $item.Length
                    $stableDeadline = $now.AddSeconds($stableSeconds)
                }
                if ($stableDeadline -and $now -ge $stableDeadline) {
                    return $resultZip
                }
            }
        }
        elseif ($now -ge $deadline) {
            break
        }

        Start-Sleep -Seconds 2
    }
    return $null
}

function Get-ResultSummary {
    param([string]$ZipPath)
    $runSummary = Get-ResultRunSummary -ZipPath $ZipPath
    $meta = if ($runSummary) { $null } else { Get-ResultMeta -ZipPath $ZipPath }
    if (-not $runSummary -and -not $meta) { return $null }

    $exitReason = if ($runSummary -and $runSummary.exit_reason) { $runSummary.exit_reason } else { $meta.exit_reason }
    if ([string]::IsNullOrWhiteSpace($exitReason)) { $exitReason = "UNKNOWN" }
    $exitCode = if ($runSummary -and $runSummary.exit_code -ne $null) { $runSummary.exit_code } else { $meta.exit_code }
    $determinismHash = $null
    if ($runSummary -and $runSummary.determinism_hash) { $determinismHash = [string]$runSummary.determinism_hash }
    $failingInvariants = @()
    if ($runSummary -and $runSummary.failing_invariants) {
        $failingInvariants = @($runSummary.failing_invariants)
    }
    $runtime = $null
    if ($runSummary -and $runSummary.runtime_sec -ne $null) {
        $runtime = [double]$runSummary.runtime_sec
    }
    elseif ($meta -and $meta.duration_sec -ne $null) {
        $runtime = [double]$meta.duration_sec
    }
    return [pscustomobject]@{
        exit_reason = $exitReason
        exit_code = $exitCode
        determinism_hash = $determinismHash
        failing_invariants = $failingInvariants
        runtime_sec = $runtime
    }
}

function Invoke-Tier {
    param(
        [string]$Title,
        [string]$UnityExePath,
        [string]$QueueRootPath,
        [string]$TierName,
        [object]$TierConfig,
        [int]$WaitTimeoutSec,
        [string]$ScriptRoot,
        [string]$TriRoot,
        [object]$Build
    )
    $titleKey = $Title.ToLowerInvariant()
    $tierSpec = $TierConfig.tiers.$TierName.$titleKey
    if (-not $tierSpec) {
        return [pscustomobject]@{
            has_errors = $true
            error = "tier_not_defined:${TierName}:${Title}"
        }
    }

    if (-not $Build) {
        $Build = Invoke-Build -Title $Title -UnityExePath $UnityExePath -QueueRootPath $QueueRootPath -ScriptRoot $ScriptRoot -TriRoot $TriRoot
    }

    $queueRootFull = [System.IO.Path]::GetFullPath($QueueRootPath)
    $jobsDir = Join-Path $queueRootFull "jobs"
    $resultsDir = Join-Path $queueRootFull "results"
    $reportsDir = Join-Path $queueRootFull "reports"
    Ensure-Directory $jobsDir
    Ensure-Directory $resultsDir
    Ensure-Directory $reportsDir

    $artifactUri = Convert-ToWslPath $Build.artifact_zip
    $runEntries = New-Object System.Collections.Generic.List[object]
    $hasErrors = $false

    foreach ($scenario in $tierSpec) {
        $scenarioId = [string]$scenario.scenario_id
        if ([string]::IsNullOrWhiteSpace($scenarioId)) {
            $hasErrors = $true
            Write-Host ("tier_error=missing_scenario_id tier={0} title={1}" -f $TierName, $Title)
            continue
        }

        $seed = if ($scenario.seed -ne $null) { [int]$scenario.seed } else { 0 }
        $timeoutSec = if ($scenario.timeout_sec -ne $null) { [int]$scenario.timeout_sec } else { 600 }
        $repeatCount = if ($scenario.repeat -ne $null -and [int]$scenario.repeat -gt 0) { [int]$scenario.repeat } else { 1 }

        $args = @()
        if ($scenario.scenario_path) {
            $scenarioPath = Join-Path $TriRoot $scenario.scenario_path
            $args += @("--scenario", (Convert-ToWslPath $scenarioPath))
        }
        if ($scenario.args) {
            $args += @($scenario.args)
        }

        $envBlock = @{}
        $envProp = $scenario.PSObject.Properties["env"]
        if ($envProp -and $envProp.Value) {
            foreach ($prop in $envProp.Value.PSObject.Properties) {
                $envBlock[$prop.Name] = [string]$prop.Value
            }
        }

        $baselineHash = $null
        for ($i = 1; $i -le $repeatCount; $i++) {
            $suffix = ""
            if ($repeatCount -gt 1) {
                $suffix = "_r{0:D2}" -f $i
            }
            $jobId = "{0}_{1}_{2}{3}" -f $Build.build_id, $scenarioId, $seed, $suffix
            $job = [ordered]@{
                job_id = $jobId
                commit = $Build.commit
                build_id = $Build.build_id
                scenario_id = $scenarioId
                seed = [int]$seed
                timeout_sec = [int]$timeoutSec
                args = @($args)
                env = $envBlock
                param_overrides = [ordered]@{}
                feature_flags = [ordered]@{}
                artifact_uri = $artifactUri
                created_utc = (Get-Date).ToUniversalTime().ToString("o")
            }

            $jobPath = Queue-TierJob -JobsDir $jobsDir -Job $job
            Write-Host ("job={0}" -f $jobPath)

            if ($WaitTimeoutSec -gt 0) {
                $resultZip = Wait-ForResultZip -ResultsDir $resultsDir -JobId $jobId -WaitTimeoutSec $WaitTimeoutSec
                if (-not $resultZip) {
                    $hasErrors = $true
                    Write-Host ("tier_result scenario_id={0} seed={1} run_index={2} exit_reason=RESULT_TIMEOUT" -f $scenarioId, $seed, $i)
                    continue
                }

                $summary = Get-ResultSummary -ZipPath $resultZip
                if (-not $summary) {
                    $hasErrors = $true
                    Write-Host ("tier_result scenario_id={0} seed={1} run_index={2} exit_reason=SUMMARY_MISSING" -f $scenarioId, $seed, $i)
                    continue
                }

                $invText = if ($summary.failing_invariants -and $summary.failing_invariants.Count -gt 0) {
                    [string]::Join(",", $summary.failing_invariants)
                } else {
                    ""
                }
                $hashText = if ($summary.determinism_hash) { $summary.determinism_hash } else { "" }
                $exitCodeText = if ($summary.exit_code -ne $null) { $summary.exit_code } else { "" }
                Write-Host ("tier_result scenario_id={0} seed={1} run_index={2} exit_reason={3} exit_code={4} determinism_hash={5} failing_invariants={6}" -f $scenarioId, $seed, $i, $summary.exit_reason, $exitCodeText, $hashText, $invText)

                if ($summary.exit_reason -in @("INFRA_FAIL", "CRASH", "HANG_TIMEOUT")) {
                    $hasErrors = $true
                }
                if ($repeatCount -gt 1 -and $summary.determinism_hash) {
                    if (-not $baselineHash) {
                        $baselineHash = $summary.determinism_hash
                    }
                    elseif ($summary.determinism_hash -ne $baselineHash) {
                        $hasErrors = $true
                        Write-Host ("tier_determinism_mismatch scenario_id={0} baseline={1} current={2}" -f $scenarioId, $baselineHash, $summary.determinism_hash)
                    }
                }

                $runEntries.Add([pscustomobject]@{
                    job_id = $jobId
                    scenario_id = $scenarioId
                    seed = $seed
                    run_index = $i
                    result_zip = $resultZip
                    exit_reason = $summary.exit_reason
                    exit_code = $summary.exit_code
                    determinism_hash = $summary.determinism_hash
                    failing_invariants = $summary.failing_invariants
                    runtime_sec = $summary.runtime_sec
                })
            }
        }
    }

    $dateStamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd")
    $summaryPath = Join-Path $reportsDir ("nightly_{0}_{1}_{2}.json" -f $dateStamp, $Title, $TierName)
    $summary = [ordered]@{
        date_utc = $dateStamp
        tier = $TierName
        queue_root = $QueueRootPath
        build_id = $Build.build_id
        commit = $Build.commit
        artifact_zip = $Build.artifact_zip
        runs = $runEntries.ToArray()
    }
    $summaryJson = $summary | ConvertTo-Json -Depth 8
    Set-Content -Path $summaryPath -Value $summaryJson -Encoding ascii
    Write-Host ("Wrote nightly summary: {0}" -f $summaryPath)

    return [pscustomobject]@{
        has_errors = $hasErrors
        error = $null
        build = $Build
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

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$TriRoot = (Resolve-Path (Join-Path $ScriptRoot "..\\..")).Path
$UnityExe = Resolve-UnityExe -ExePath $UnityExe
$dateStamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd")
if ([string]::IsNullOrWhiteSpace($TierConfigPath)) {
    $TierConfigPath = Join-Path $ScriptRoot "pipeline_tiers.json"
}

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

$tierConfig = $null
if ($Tier -ne "legacy") {
    $tierConfig = Get-TierConfig -ConfigPath $TierConfigPath
}

$hasErrors = $false
foreach ($title in $titles) {
    $queueRoot = if ($title -eq "space4x") { $QueueRootSpace4x } else { $QueueRootGodgame }
    $reportsDir = Join-Path $queueRoot "reports"
    Ensure-Directory $reportsDir

    if ($Tier -eq "legacy") {
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
    else {
        $tierList = if ($Tier -eq "all") { @("tier0", "tier1") } else { @($Tier) }
        $build = $null
        foreach ($tierName in $tierList) {
            $tierResult = Invoke-Tier -Title $title -UnityExePath $UnityExe -QueueRootPath $queueRoot -TierName $tierName -TierConfig $tierConfig -WaitTimeoutSec $WaitTimeoutSec -ScriptRoot $ScriptRoot -TriRoot $TriRoot -Build $build
            if ($tierResult.build) { $build = $tierResult.build }
            if ($tierResult.has_errors) { $hasErrors = $true }
            if ($tierResult.error) {
                Write-Host ("tier_error={0}" -f $tierResult.error)
                $hasErrors = $true
            }
        }
    }
}

if ($hasErrors) {
    exit 1
}
