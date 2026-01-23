[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$DeckPath,
    [Parameter(Mandatory = $true)]
    [string]$UnityExe,
    [string]$QueueRoot,
    [ValidateSet("run", "enqueue", "monitor")]
    [string]$Mode = "run",
    [int]$PollSec,
    [int]$PendingGraceSec,
    [int]$MaxMinutes,
    [string]$WslDistro = "Ubuntu"
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
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $full = [System.IO.Path]::GetFullPath($Path)
    $match = [regex]::Match($full, '^([A-Za-z]):\\(.*)$')
    if ($match.Success) {
        $drive = $match.Groups[1].Value.ToLowerInvariant()
        $rest = $match.Groups[2].Value -replace '\\', '/'
        return "/mnt/$drive/$rest"
    }
    return ($full -replace '\\', '/')
}

function Normalize-ScenarioRel {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
    $normalized = $Value -replace '\\', '/'
    if ($normalized -match '^[A-Za-z]:/' -or $normalized.StartsWith('/')) {
        $assetsIndex = $normalized.IndexOf('Assets/')
        if ($assetsIndex -ge 0) {
            return $normalized.Substring($assetsIndex)
        }
        throw "ScenarioRel must be relative or contain Assets/: $Value"
    }
    return $normalized.TrimStart("./")
}

function Normalize-GoalSpecPath {
    param(
        [string]$GoalSpecPath,
        [string]$RepoRoot
    )
    if ([string]::IsNullOrWhiteSpace($GoalSpecPath)) { return "" }
    $normalized = $GoalSpecPath -replace '\\', '/'
    if ($normalized -match '^[A-Za-z]:/' -or $normalized.StartsWith('/')) {
        $root = ($RepoRoot -replace '\\', '/').TrimEnd('/')
        if ($normalized.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $normalized.Substring($root.Length).TrimStart('/')
        }
        return $normalized
    }
    return $normalized.TrimStart("./")
}

function Load-Deck {
    param([string]$Path)
    if (-not (Test-Path $Path)) { throw "Deck not found: $Path" }
    return (Get-Content -Raw -Path $Path | ConvertFrom-Json)
}

function Load-PipelineDefaults {
    param([string]$ScriptRoot)
    $defaultsPath = Join-Path $ScriptRoot "pipeline_defaults.json"
    if (-not (Test-Path $defaultsPath)) { return $null }
    return (Get-Content -Raw -Path $defaultsPath | ConvertFrom-Json)
}

function Get-RepoStatus {
    param([string]$ProjectPath)
    try {
        return (& git -C $ProjectPath status --porcelain) -join "`n"
    }
    catch {
        return ""
    }
}

function Get-ManifestSnapshot {
    param([string]$ProjectPath)
    $files = @(
        "Packages\\manifest.json",
        "Packages\\manifest.headless.json",
        "Packages\\packages-lock.json",
        "Packages\\packages-lock.headless.json"
    )
    $snapshot = @{}
    foreach ($file in $files) {
        $path = Join-Path $ProjectPath $file
        if (Test-Path $path) {
            $hash = (Get-FileHash -Algorithm SHA256 -Path $path).Hash
            $snapshot[$file] = $hash
        }
    }
    return $snapshot
}

function Compare-ManifestSnapshot {
    param(
        [hashtable]$Before,
        [hashtable]$After
    )
    $changes = @()
    $keys = New-Object System.Collections.Generic.HashSet[string]
    foreach ($key in $Before.Keys) { $null = $keys.Add($key) }
    foreach ($key in $After.Keys) { $null = $keys.Add($key) }
    foreach ($key in $keys) {
        $beforeHash = if ($Before.ContainsKey($key)) { $Before[$key] } else { "" }
        $afterHash = if ($After.ContainsKey($key)) { $After[$key] } else { "" }
        if ($beforeHash -ne $afterHash) {
            $changes += [ordered]@{
                file = $key
                before = $beforeHash
                after = $afterHash
            }
        }
    }
    return [ordered]@{
        detected = ($changes.Count -gt 0)
        changes = $changes
    }
}

function Build-Artifact {
    param(
        [string]$ProjectPath,
        [string]$UnityExePath,
        [string]$ArtifactsDir,
        [string]$ScriptRoot,
        [string]$RepoRoot
    )
    if (-not (Test-Path $ProjectPath)) { throw "Project path not found: $ProjectPath" }
    if (-not (Test-Path $UnityExePath)) { throw "Unity exe not found: $UnityExePath" }

    $commitFull = & git -C $ProjectPath rev-parse HEAD 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git rev-parse HEAD failed: $commitFull" }
    $commitShort = & git -C $ProjectPath rev-parse --short=8 HEAD 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git rev-parse --short failed: $commitShort" }

    $timestamp = ([DateTime]::UtcNow).ToString("yyyyMMdd_HHmmss_fff")
    $buildId = "${timestamp}_$commitShort"

    $syncScript = Join-Path $RepoRoot "Tools\\sync_headless_manifest.ps1"
    $swapScript = Join-Path $RepoRoot "Tools\\Tools\\use_headless_manifest_windows.ps1"
    if (-not (Test-Path $syncScript)) { throw "Missing headless manifest sync script: $syncScript" }
    if (-not (Test-Path $swapScript)) { throw "Missing headless manifest swap script: $swapScript" }

    $supervisorProject = Join-Path $RepoRoot "Tools\\HeadlessBuildSupervisor\\HeadlessBuildSupervisor.csproj"
    if (-not (Test-Path $supervisorProject)) {
        throw "HeadlessBuildSupervisor.csproj not found: $supervisorProject"
    }

    Ensure-Directory $ArtifactsDir

    $supervisorArgs = @(
        "run", "--project", $supervisorProject, "--",
        "--unity-exe", $UnityExePath,
        "--project-path", $ProjectPath,
        "--build-id", $buildId,
        "--commit", $commitFull,
        "--artifact-dir", $ArtifactsDir
    )

    $repoStatusPre = Get-RepoStatus -ProjectPath $ProjectPath
    $manifestPre = Get-ManifestSnapshot -ProjectPath $ProjectPath
    $swapApplied = $false
    try {
        & $syncScript -ProjectPath $ProjectPath
        & $swapScript -ProjectPath $ProjectPath
        $swapApplied = $true
        & dotnet @supervisorArgs
    }
    finally {
        if ($swapApplied) {
            & $swapScript -ProjectPath $ProjectPath -Restore
        }
    }
    $repoStatusPost = Get-RepoStatus -ProjectPath $ProjectPath
    $manifestPost = Get-ManifestSnapshot -ProjectPath $ProjectPath
    $manifestDrift = Compare-ManifestSnapshot -Before $manifestPre -After $manifestPost

    $artifactZip = Join-Path $ArtifactsDir ("artifact_{0}.zip" -f $buildId)
    if (-not (Test-Path $artifactZip)) { throw "Artifact zip not found: $artifactZip" }

    return [ordered]@{
        build_id = $buildId
        commit = $commitFull.Trim()
        artifact_zip = $artifactZip
        repo_status_pre = $repoStatusPre
        repo_status_post = $repoStatusPost
        manifest_drift = $manifestDrift
    }
}

function Write-ExpectedJobsLedger {
    param(
        [string]$ReportsDir,
        [object[]]$ExpectedJobs
    )
    Ensure-Directory $ReportsDir
    $payload = [ordered]@{
        generated_utc = ([DateTime]::UtcNow).ToString("o")
        jobs = $ExpectedJobs
    }
    $path = Join-Path $ReportsDir "expected_jobs.json"
    $payload | ConvertTo-Json -Depth 6 | Set-Content -Path $path -Encoding ascii
    return $path
}

function Invoke-IntelIngest {
    param(
        [string]$ResultZipPath,
        [string]$Distro,
        [string]$RepoRootWsl
    )
    if (-not (Test-Path $ResultZipPath)) { return $false }
    $wslZip = Convert-ToWslPath $ResultZipPath
    $cmd = "python3 $RepoRootWsl/Polish/Intel/anviloop_intel.py ingest-result-zip --result-zip $wslZip"
    & wsl.exe -d $Distro -- bash -lc $cmd 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Invoke-Headline {
    param(
        [string]$ResultsDir,
        [string]$ReportsDir,
        [string]$IntelDir,
        [int]$Limit,
        [int]$GraceSec,
        [string]$Distro,
        [string]$RepoRootWsl
    )
    $wslResults = Convert-ToWslPath $ResultsDir
    $wslReports = Convert-ToWslPath $ReportsDir
    $wslIntel = Convert-ToWslPath $IntelDir
    $cmd = "python3 $RepoRootWsl/Polish/Goals/scoreboard.py --results-dir $wslResults --reports-dir $wslReports --intel-dir $wslIntel --limit $Limit --pending-grace-sec $GraceSec"
    & wsl.exe -d $Distro -- bash -lc $cmd 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = (Resolve-Path (Join-Path $scriptRoot "..")).Path
$defaults = Load-PipelineDefaults -ScriptRoot $scriptRoot
$deck = Load-Deck -Path $DeckPath

$queueRootValue = if ($QueueRoot) { $QueueRoot } elseif ($deck.queue_root) { $deck.queue_root } else { "C:\\polish\\queue" }
$pollSecValue = if ($PollSec -gt 0) { $PollSec } elseif ($deck.poll_sec) { [int]$deck.poll_sec } else { 60 }
$pendingGraceValue = if ($PendingGraceSec -gt 0) { $PendingGraceSec } elseif ($deck.pending_grace_sec) { [int]$deck.pending_grace_sec } else { 600 }
$maxMinutesValue = if ($MaxMinutes -gt 0) { $MaxMinutes } elseif ($deck.max_minutes) { [int]$deck.max_minutes } else { 720 }
$wslRepoRoot = Convert-ToWslPath $repoRoot

$artifactsDir = Join-Path $queueRootValue "artifacts"
$jobsDir = Join-Path $queueRootValue "jobs"
$resultsDir = Join-Path $queueRootValue "results"
$reportsDir = Join-Path $queueRootValue "reports"
$intelDir = Join-Path $reportsDir "intel"
Ensure-Directory $artifactsDir
Ensure-Directory $jobsDir
Ensure-Directory $resultsDir
Ensure-Directory $reportsDir
Ensure-Directory $intelDir

if (-not $deck.jobs) { throw "Deck has no jobs." }

$buildCache = @{}
$expectedJobs = New-Object System.Collections.Generic.List[object]

if ($Mode -in @("run", "enqueue")) {
    foreach ($job in $deck.jobs) {
        $title = [string]$job.title
        if ([string]::IsNullOrWhiteSpace($title)) { throw "Deck job missing title." }
        $titleKey = $title.ToLowerInvariant()
        $defaultsTitle = if ($defaults -and $defaults.titles) { $defaults.titles.$titleKey } else { $null }
        $projectPath = if ($job.project_path_override) { $job.project_path_override } elseif ($defaultsTitle) { Join-Path $repoRoot $defaultsTitle.project_path } else { "" }
        if ([string]::IsNullOrWhiteSpace($projectPath)) { throw "Project path missing for $title." }
        $projectPath = [System.IO.Path]::GetFullPath($projectPath)

        if (-not $buildCache.ContainsKey($projectPath)) {
            $buildCache[$projectPath] = Build-Artifact -ProjectPath $projectPath -UnityExePath $UnityExe -ArtifactsDir $artifactsDir -ScriptRoot $scriptRoot -RepoRoot $repoRoot
        }
        $build = $buildCache[$projectPath]

        $scenarioId = [string]$job.scenario_id
        $scenarioRel = if ($job.scenario_rel) { Normalize-ScenarioRel $job.scenario_rel } else { "" }
        $seed = if ($job.seed -ne $null) { [int]$job.seed } elseif ($defaultsTitle) { [int]$defaultsTitle.seed } else { 0 }
        $timeoutSec = if ($job.timeout_sec -ne $null) { [int]$job.timeout_sec } elseif ($defaultsTitle) { [int]$defaultsTitle.timeout_sec } else { 120 }
        $repeatCount = if ($job.repeat -ne $null) { [int]$job.repeat } else { 1 }
        $argsValue = if ($job.args) { @($job.args) } elseif ($defaultsTitle -and $defaultsTitle.args) { @($defaultsTitle.args) } else { @() }

        $artifactUri = Convert-ToWslPath $build.artifact_zip
        $repoRootWsl = Convert-ToWslPath $projectPath
        $goalSpecValue = if ($job.goal_spec) { Normalize-GoalSpecPath -GoalSpecPath $job.goal_spec -RepoRoot $repoRoot } else { "" }
        $goalIdValue = if ($job.goal_id) { [string]$job.goal_id } else { "" }
        $baseRefValue = if ($job.base_ref) { [string]$job.base_ref } else { "" }

        for ($i = 1; $i -le $repeatCount; $i++) {
            $suffix = ""
            if ($repeatCount -gt 1) {
                $suffix = "_r{0:D2}" -f $i
            }
            $jobId = "{0}_{1}_{2}{3}" -f $build.build_id, $scenarioId, $seed, $suffix
            $jobRecord = [ordered]@{
                job_id = $jobId
                commit = $build.commit
                build_id = $build.build_id
                scenario_id = $scenarioId
                seed = $seed
                timeout_sec = $timeoutSec
                args = @($argsValue)
                param_overrides = [ordered]@{}
                feature_flags = [ordered]@{}
                artifact_uri = $artifactUri
                created_utc = ([DateTime]::UtcNow).ToString("o")
                repo_root = $repoRootWsl
                repo_status_pre = $build.repo_status_pre
                repo_status_post = $build.repo_status_post
                manifest_drift = $build.manifest_drift
            }
            if ($scenarioRel) { $jobRecord.scenario_rel = $scenarioRel }
            if ($goalIdValue) { $jobRecord.goal_id = $goalIdValue }
            if ($goalSpecValue) { $jobRecord.goal_spec = $goalSpecValue }
            if ($baseRefValue) { $jobRecord.base_ref = $baseRefValue }

            $jobJson = $jobRecord | ConvertTo-Json -Depth 8
            $jobTempPath = Join-Path $jobsDir (".tmp_{0}.json" -f $jobId)
            $jobPath = Join-Path $jobsDir ("{0}.json" -f $jobId)
            Set-Content -Path $jobTempPath -Value $jobJson -Encoding ascii
            Move-Item -Path $jobTempPath -Destination $jobPath -Force
            Write-Host ("job={0}" -f $jobPath)

            $expectedJobs.Add([ordered]@{
                job_id = $jobId
                build_id = $build.build_id
                scenario_id = $scenarioId
                seed = $seed
                title = $titleKey
                created_utc = ([DateTime]::UtcNow).ToString("o")
                expected_result_prefix = ("result_{0}" -f $jobId)
                goal_id = $goalIdValue
                goal_spec = $goalSpecValue
                commit = $build.commit
                base_ref = $baseRefValue
            })
        }
    }

    $expectedPath = Write-ExpectedJobsLedger -ReportsDir $reportsDir -ExpectedJobs $expectedJobs
    Write-Host ("expected_jobs={0}" -f $expectedPath)
}

if ($Mode -eq "enqueue") {
    exit 0
}

$expectedFile = Join-Path $reportsDir "expected_jobs.json"
if (-not (Test-Path $expectedFile)) { throw "expected_jobs.json missing: $expectedFile" }
$expectedData = Get-Content -Raw -Path $expectedFile | ConvertFrom-Json
$expectedList = if ($expectedData.jobs) { @($expectedData.jobs) } else { @() }
if ($expectedList.Count -eq 0) { throw "expected_jobs.json has no jobs." }

$limitValue = [Math]::Max($expectedList.Count + 50, 25)
$startUtc = Get-Date

while ($true) {
    $completed = 0
    foreach ($entry in $expectedList) {
        $jobId = $entry.job_id
        if (-not $jobId) { continue }
        $resultZip = Join-Path $resultsDir ("result_{0}.zip" -f $jobId)
        $explainPath = Join-Path $intelDir ("explain_{0}.json" -f $jobId)
        if (Test-Path $resultZip) {
            if (-not (Test-Path $explainPath)) {
                Invoke-IntelIngest -ResultZipPath $resultZip -Distro $WslDistro -RepoRootWsl $wslRepoRoot | Out-Null
            }
        }
        if ((Test-Path $resultZip) -and (Test-Path $explainPath)) {
            $completed++
        }
    }

    Invoke-Headline -ResultsDir $resultsDir -ReportsDir $reportsDir -IntelDir $intelDir -Limit $limitValue -GraceSec $pendingGraceValue -Distro $WslDistro -RepoRootWsl $wslRepoRoot | Out-Null

    if ($completed -ge $expectedList.Count) {
        Write-Host "deck_complete=true"
        break
    }

    $elapsed = (Get-Date) - $startUtc
    if ($elapsed.TotalMinutes -ge $maxMinutesValue) {
        Write-Host "deck_complete=false reason=max_minutes"
        break
    }

    Start-Sleep -Seconds $pollSecValue
}
