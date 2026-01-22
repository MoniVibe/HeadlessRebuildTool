[CmdletBinding()]
param(
    [string]$Root = "C:\\Dev\\unity_clean",
    [string]$QueueRoot = "C:\\polish\\queue",
    [string]$UnityExe,
    [string]$BaseRef,
    [bool]$FactoryHost = $true,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Directory {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function Ensure-PureDotsLink {
    param(
        [string]$RepoName,
        [string]$WorktreePath,
        [string]$Root
    )
    if ($RepoName -ne "space4x" -and $RepoName -ne "godgame") { return $null }
    $target = Join-Path $Root "puredots"
    if (-not (Test-Path $target)) {
        throw "PureDOTS repo missing: $target"
    }
    $worktreeParent = Split-Path $WorktreePath -Parent
    $linkPath = Join-Path $worktreeParent "puredots"
    if (-not (Test-Path $linkPath)) {
        New-Item -ItemType Junction -Path $linkPath -Target $target | Out-Null
    }
    $packageJson = Join-Path $linkPath "Packages\\com.moni.puredots\\package.json"
    if (-not (Test-Path $packageJson)) {
        throw "PureDOTS package.json missing at $packageJson"
    }
    return $packageJson
}

function Reset-HeadlessManifests {
    param([string]$RepoPath)
    $paths = @(
        "Packages\\manifest.headless.json",
        "Packages\\packages-lock.headless.json"
    )
    foreach ($relPath in $paths) {
        $fullPath = Join-Path $RepoPath $relPath
        if (Test-Path $fullPath) {
            & git -C $RepoPath checkout -- $relPath 2>$null
        }
    }
}

function Remove-UnityLockfile {
    param([string]$RepoPath)
    $lockPaths = @(
        (Join-Path $RepoPath "Temp\\UnityLockfile"),
        (Join-Path $RepoPath "Library\\UnityLockfile")
    )
    foreach ($lockPath in $lockPaths) {
        if (Test-Path $lockPath) {
            Remove-Item -Force $lockPath
        }
    }
}

function Clear-WorktreeBuildCache {
    param([string]$RepoPath)
    $deleted = New-Object System.Collections.Generic.List[string]
    $folders = @(
        "Library\\Bee",
        "Library\\ScriptAssemblies",
        "Temp\\BeeArtifacts"
    )
    foreach ($relPath in $folders) {
        $fullPath = Join-Path $RepoPath $relPath
        if (Test-Path $fullPath) {
            Remove-Item -Recurse -Force $fullPath
            $deleted.Add($relPath)
        }
    }
    $lockPaths = @(
        "Temp\\UnityLockfile",
        "Library\\UnityLockfile"
    )
    foreach ($relPath in $lockPaths) {
        $fullPath = Join-Path $RepoPath $relPath
        if (Test-Path $fullPath) {
            Remove-Item -Force $fullPath
            $deleted.Add($relPath)
        }
    }
    return $deleted
}

function Stop-UnityEditorsForFactory {
    param([int]$MinAgeMinutes = 2)
    $cutoff = (Get-Date).AddMinutes(-$MinAgeMinutes)
    $killed = New-Object System.Collections.Generic.List[int]
    $procs = Get-CimInstance Win32_Process -Filter "Name='Unity.exe' OR Name='Unity'"
    foreach ($proc in $procs) {
        $shouldKill = $true
        if ($proc.CreationDate) {
            try {
                $started = [Management.ManagementDateTimeConverter]::ToDateTime($proc.CreationDate)
                if ($started -gt $cutoff) {
                    $shouldKill = $false
                }
            }
            catch {
            }
        }
        if ($shouldKill) {
            try {
                Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
                $killed.Add([int]$proc.ProcessId)
            }
            catch {
            }
        }
    }
    if ($killed.Count -gt 0) {
        Start-Sleep -Seconds 2
    }
    return $killed
}

function Stop-UnityForProject {
    param([string]$ProjectPath)
    if ([string]::IsNullOrWhiteSpace($ProjectPath)) { return @() }
    $full = [System.IO.Path]::GetFullPath($ProjectPath)
    $normalized = $full.ToLowerInvariant().Replace('\\', '/')
    $alt = $normalized.Replace('/', '\\')
    $killed = New-Object System.Collections.Generic.List[int]
    $procs = Get-CimInstance Win32_Process -Filter "Name='Unity.exe' OR Name='Unity'"
    foreach ($proc in $procs) {
        $cmd = $proc.CommandLine
        if ([string]::IsNullOrWhiteSpace($cmd)) { continue }
        $cmdLower = $cmd.ToLowerInvariant()
        if (-not ($cmdLower.Contains("-projectpath"))) { continue }
        if (-not ($cmdLower.Contains($normalized) -or $cmdLower.Contains($alt))) { continue }
        try {
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
            $killed.Add([int]$proc.ProcessId)
        }
        catch {
        }
    }
    if ($killed.Count -gt 0) {
        Start-Sleep -Seconds 2
    }
    return $killed
}

function Get-UnityProcessForProject {
    param([string]$ProjectPath)
    if ([string]::IsNullOrWhiteSpace($ProjectPath)) { return $null }
    $full = [System.IO.Path]::GetFullPath($ProjectPath)
    $normalized = $full.ToLowerInvariant().Replace('\\', '/')
    $alt = $normalized.Replace('/', '\\')
    $procs = Get-CimInstance Win32_Process -Filter "Name='Unity.exe' OR Name='Unity'"
    foreach ($proc in $procs) {
        $cmd = $proc.CommandLine
        if ([string]::IsNullOrWhiteSpace($cmd)) { continue }
        $cmdLower = $cmd.ToLowerInvariant()
        if (-not ($cmdLower.Contains("-projectpath"))) { continue }
        if ($cmdLower.Contains($normalized) -or $cmdLower.Contains($alt)) {
            return $proc
        }
    }
    return $null
}

function Get-LogDirSnapshot {
    param([string]$LogsDir)
    $snapshot = @{}
    if (-not (Test-Path $LogsDir)) { return $snapshot }
    Get-ChildItem -Path $LogsDir -File | ForEach-Object {
        $snapshot[$_.Name] = [ordered]@{
            length = $_.Length
            mtime_utc = $_.LastWriteTimeUtc
        }
    }
    return $snapshot
}

function Test-LogDirChanged {
    param(
        [hashtable]$Previous,
        [hashtable]$Current
    )
    if (-not $Previous -or $Previous.Count -eq 0) { return $true }
    foreach ($key in $Current.Keys) {
        if (-not $Previous.ContainsKey($key)) { return $true }
        $prev = $Previous[$key]
        $cur = $Current[$key]
        if ($prev.length -ne $cur.length -or $prev.mtime_utc -ne $cur.mtime_utc) {
            return $true
        }
    }
    foreach ($key in $Previous.Keys) {
        if (-not $Current.ContainsKey($key)) { return $true }
    }
    return $false
}

function Find-RecentStagingDir {
    param(
        [string]$ArtifactsDir,
        [DateTime]$StartUtc
    )
    if (-not (Test-Path $ArtifactsDir)) { return $null }
    return Get-ChildItem -Path $ArtifactsDir -Directory -Filter "staging_*" |
        Where-Object { $_.LastWriteTimeUtc -ge $StartUtc } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
}

function Test-BeeTundraActivity {
    $procs = Get-CimInstance Win32_Process
    foreach ($proc in $procs) {
        $name = [string]$proc.Name
        $cmd = [string]$proc.CommandLine
        if ($name -match '(?i)bee_backend|tundra' -or $cmd -match '(?i)bee_backend|tundra') {
            return $true
        }
    }
    return $false
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

function Read-JsonFileSafe {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try {
        return (Get-Content -Raw -Path $Path | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Payload
    )
    $json = $Payload | ConvertTo-Json -Depth 8
    Set-Content -Path $Path -Value $json -Encoding ascii
}

function Resolve-UnityExe {
    param([string]$Preferred)
    if (-not [string]::IsNullOrWhiteSpace($Preferred) -and (Test-Path $Preferred)) {
        return $Preferred
    }
    $envPath = $env:UNITY_EXE
    if (-not [string]::IsNullOrWhiteSpace($envPath) -and (Test-Path $envPath)) {
        return $envPath
    }
    $default = "C:\\Program Files\\Unity\\Hub\\Editor\\6000.3.1f1\\Editor\\Unity.exe"
    if (Test-Path $default) {
        return $default
    }
    throw "Unity exe not found. Pass -UnityExe or set UNITY_EXE."
}

function Normalize-GoalSpecForJob {
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

function Read-LogTail {
    param(
        [string]$Path,
        [int]$TailLines = 200
    )
    if (-not (Test-Path $Path)) { return @() }
    try {
        return Get-Content -Path $Path -Tail $TailLines
    }
    catch {
        return @()
    }
}

function Find-PrimaryErrorLine {
    param([string[]]$Lines)
    if (-not $Lines) { return $null }
    $patterns = @(
        'error CS\d+',
        'Unhandled Exception',
        'Exception',
        'Build failed',
        'error:'
    )
    foreach ($line in $Lines) {
        foreach ($pattern in $patterns) {
            if ($line -match $pattern) {
                return $line
            }
        }
    }
    return $null
}

function Find-LatestArtifactAfter {
    param(
        [string]$ArtifactsDir,
        [DateTime]$StartUtc
    )
    if (-not (Test-Path $ArtifactsDir)) { return $null }
    return Get-ChildItem -Path $ArtifactsDir -Filter "artifact_*.zip" -File |
        Where-Object { $_.LastWriteTimeUtc -ge $StartUtc } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
}

function Read-JsonFileFromPath {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try {
        return (Get-Content -Raw -Path $Path | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Find-LatestGoodArtifact {
    param(
        [string]$ArtifactsDir,
        [string]$RepoName
    )
    if (-not (Test-Path $ArtifactsDir)) { return $null }
    $needle = if ($RepoName -eq "godgame") { "Godgame_Headless" } else { "Space4X_Headless" }
    $candidates = Get-ChildItem -Path $ArtifactsDir -Filter "artifact_*.zip" -File |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 40
    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
    foreach ($candidate in $candidates) {
        $archive = $null
        try {
            $archive = [System.IO.Compression.ZipFile]::OpenRead($candidate.FullName)
            $manifestEntry = $archive.GetEntry("build_manifest.json")
            if (-not $manifestEntry) { continue }
            $reader = New-Object System.IO.StreamReader($manifestEntry.Open())
            $manifestText = $reader.ReadToEnd()
            $reader.Dispose()
            $manifest = $manifestText | ConvertFrom-Json
            if ($manifest.entrypoint -notlike "*$needle*") { continue }
            $outcomeEntry = $archive.GetEntry("logs/build_outcome.json")
            if ($outcomeEntry) {
                $reader = New-Object System.IO.StreamReader($outcomeEntry.Open())
                $outcomeText = $reader.ReadToEnd()
                $reader.Dispose()
                $outcome = $outcomeText | ConvertFrom-Json
                if ($outcome.result -ne "Succeeded") { continue }
            }
            return [ordered]@{
                path = $candidate.FullName
                build_id = $manifest.build_id
                commit = $manifest.commit
            }
        }
        catch {
        }
        finally {
            if ($archive) { $archive.Dispose() }
        }
    }
    return $null
}

function Enqueue-FallbackValidation {
    param(
        [string]$ArtifactsDir,
        [string]$RepoName,
        [string]$ScenarioId,
        [string]$ScenarioRel,
        [string]$GoalId,
        [string]$GoalSpec,
        [string]$QueueRoot,
        [int]$Seed
    )
    $artifact = Find-LatestGoodArtifact -ArtifactsDir $ArtifactsDir -RepoName $RepoName
    if (-not $artifact) { return $null }
    $jobsDir = Join-Path $QueueRoot "jobs"
    Ensure-Directory $jobsDir
    $jobId = "{0}_{1}_{2}" -f $artifact.build_id, $ScenarioId, $Seed
    $job = [ordered]@{
        job_id = $jobId
        commit = $artifact.commit
        build_id = $artifact.build_id
        scenario_id = $ScenarioId
        scenario_rel = $ScenarioRel
        seed = [int]$Seed
        timeout_sec = 90
        args = @("--telemetryEnabled", "1")
        param_overrides = [ordered]@{}
        feature_flags = [ordered]@{}
        artifact_uri = (Convert-ToWslPath $artifact.path)
        created_utc = (Get-Date).ToUniversalTime().ToString("o")
        repo_root = (Convert-ToWslPath (Join-Path $Root $RepoName))
        validation_mode = "fallback_latest_good_artifact"
    }
    if ($GoalId) { $job.goal_id = $GoalId }
    if ($GoalSpec) { $job.goal_spec = $GoalSpec }
    $jobJson = $job | ConvertTo-Json -Depth 6
    $tmp = Join-Path $jobsDir (".tmp_{0}.json" -f $jobId)
    $path = Join-Path $jobsDir ("{0}.json" -f $jobId)
    Set-Content -Path $tmp -Value $jobJson -Encoding ascii
    Move-Item -Path $tmp -Destination $path -Force
    return $path
}

function Insert-AfterPattern {
    param(
        [string]$Path,
        [string]$Pattern,
        [string]$InsertText
    )
    $lines = Get-Content -Path $Path
    $inserted = $false
    $output = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $output.Add($line)
        if (-not $inserted -and $line -match $Pattern) {
            $indent = $line -replace '^(\\s*).*$', '$1'
            $insertLine = $indent + $InsertText
            if (-not ($lines -contains $insertLine)) {
                $output.Add($insertLine)
                $inserted = $true
            }
        }
    }
    if (-not $inserted) {
        return $false
    }
    Set-Content -Path $Path -Value $output -Encoding ascii
    return $true
}

function Apply-GoalPatch {
    param(
        [string]$Task,
        [string]$RepoPath
    )
    $shortTag = ""
    $logToken = ""
    switch ($Task) {
        "ftl_spool_stub" {
            $shortTag = "ftl_spool_stub"
            $logToken = "FTL_JUMP_STUB"
        }
        "arc_orientation_convergence_stub" {
            $shortTag = "arc_orientation_stub"
            $logToken = "ARC_START_STUB"
        }
        Default {
            $shortTag = "telemetry_stub"
            $logToken = "ANVILOOP_STUB"
        }
    }

    $target = Join-Path $RepoPath "Assets\\Scripts\\Space4x\\Headless\\Space4XHeadlessDiagnosticsSystem.cs"
    if (-not (Test-Path $target)) {
        throw "Patch target not found: $target"
    }
    $pattern = 'UpdateProgress\("run", "start", tick\)'
    $insertText = 'UnityEngine.Debug.Log("[Anviloop] ' + $logToken + '");'
    $applied = Insert-AfterPattern -Path $target -Pattern $pattern -InsertText $insertText
    if (-not $applied) {
        $fallbackText = 'UnityEngine.Debug.Log("[Anviloop] ' + $logToken + '_REASSERT");'
        $applied = Insert-AfterPattern -Path $target -Pattern $pattern -InsertText $fallbackText
    }
    if (-not $applied) {
        throw "Failed to apply goal patch for $Task"
    }
    return $shortTag
}

function Find-FirstCompileError {
    param([string]$LogPath)
    if (-not (Test-Path $LogPath)) { return $null }
    $match = Select-String -Path $LogPath -Pattern "error CS\\d+|Compilation failed|Exception:|Unhandled Exception" | Select-Object -First 1
    if ($match) { return $match.Line }
    return $null
}

function Invoke-UnityProbe {
    param(
        [string]$UnityExePath,
        [string]$ProjectPath,
        [string]$ReportsDir,
        [string]$Timestamp
    )
    $logPath = Join-Path $ReportsDir ("engineer_tick_v1_probe_{0}.log" -f $Timestamp)
    $testResults = Join-Path $ReportsDir ("engineer_tick_v1_tests_{0}.xml" -f $Timestamp)
    $manifestPath = Join-Path $ProjectPath "Packages\\manifest.json"
    $hasTestFramework = $false
    if (Test-Path $manifestPath) {
        $hasTestFramework = Select-String -Path $manifestPath -Pattern "com.unity.test-framework" -SimpleMatch -Quiet
    }
    $hasTestFolder = (Test-Path (Join-Path $ProjectPath "Assets\\Tests")) -or (Test-Path (Join-Path $ProjectPath "Assets\\Editor\\Tests"))
    $useTests = $hasTestFramework -and $hasTestFolder

    $args = @("-batchmode", "-nographics", "-projectPath", $ProjectPath, "-logFile", $logPath, "-quit")
    if ($useTests) {
        $args = @("-batchmode", "-nographics", "-projectPath", $ProjectPath, "-runTests", "-testPlatform", "EditMode", "-testResults", $testResults, "-logFile", $logPath, "-quit")
    }

    & $UnityExePath @args
    $exitCode = $LASTEXITCODE
    $firstError = Find-FirstCompileError -LogPath $logPath
    $success = ($exitCode -eq 0 -and -not $firstError)
    return [ordered]@{
        success = $success
        exit_code = $exitCode
        log_path = $logPath
        test_results = if ($useTests) { $testResults } else { "" }
        error_line = $firstError
    }
}

function Write-Report {
    param(
        [string]$Path,
        [string[]]$Lines
    )
    Set-Content -Path $Path -Value $Lines -Encoding ascii
}

$reportsDir = Join-Path $QueueRoot "reports"
Ensure-Directory $reportsDir

$goalDeckPath = Join-Path $reportsDir "nightly_goals.json"
$cursorPath = Join-Path $reportsDir "nightly_goal_cursor.json"

if (-not (Test-Path $goalDeckPath)) {
    $defaultDeck = @{
        goals = @(
            @{
                goal_id = "space4x.ftl.01"
                goal_spec = "C:\\Dev\\unity_clean\\headlessrebuildtool\\Polish\\Goals\\specs\\space4x_ftl_01.json"
                repo = "space4x"
                scenario_id = "space4x_collision_micro"
                scenario_rel = "Assets/Scenarios/space4x_collision_micro.json"
                task = "ftl_spool_stub"
            },
            @{
                goal_id = "space4x.arc.01"
                goal_spec = "C:\\Dev\\unity_clean\\headlessrebuildtool\\Polish\\Goals\\specs\\space4x_arc_01.json"
                repo = "space4x"
                scenario_id = "space4x_collision_micro"
                scenario_rel = "Assets/Scenarios/space4x_collision_micro.json"
                task = "arc_orientation_convergence_stub"
            }
        )
    }
    Write-JsonFile -Path $goalDeckPath -Payload $defaultDeck
}

$deck = Read-JsonFileSafe -Path $goalDeckPath
if (-not $deck -or -not $deck.goals) {
    throw "Goal deck missing or invalid: $goalDeckPath"
}
$goals = @($deck.goals)
if ($goals.Count -eq 0) {
    throw "Goal deck empty: $goalDeckPath"
}

$cursor = Read-JsonFileSafe -Path $cursorPath
$index = 0
if ($cursor -and $cursor.index -ne $null) {
    $index = [int]$cursor.index
}
$goal = $goals[$index % $goals.Count]
$nextIndex = ($index + 1) % $goals.Count

$timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmss")
$reportPath = Join-Path $reportsDir ("engineer_tick_v1_{0}.md" -f $timestamp)

$repoName = [string]$goal.repo
if ([string]::IsNullOrWhiteSpace($repoName)) {
    throw "Goal missing repo field."
}
$todayStamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd")
$effectiveBaseRef = ""
if ($PSBoundParameters.ContainsKey("BaseRef") -and -not [string]::IsNullOrWhiteSpace($BaseRef)) {
    $effectiveBaseRef = $BaseRef
}
elseif ($repoName -eq "space4x") {
    $effectiveBaseRef = "nightly/base_space4x_$todayStamp"
}

$repoPath = Join-Path $Root $repoName
if (-not (Test-Path $repoPath)) {
    throw "Repo path missing: $repoPath"
}

$worktreeRoot = Join-Path "C:\\polish\\worktrees" $repoName
Ensure-Directory $worktreeRoot

$goalId = [string]$goal.goal_id
$goalIdSafe = ($goalId -replace '[^a-zA-Z0-9]+', '_').Trim('_')
if ([string]::IsNullOrWhiteSpace($goalIdSafe)) {
    $goalIdSafe = "goal"
}
$branchName = "wild/engv1_{0}_{1}" -f $timestamp, $goalIdSafe
$worktreePath = Join-Path $worktreeRoot $timestamp
$killedPids = @()
$factoryKilledPids = @()
$worktreeCleanup = @()
$cleanupLine = "* worktree_cleanup: skipped"

if ($effectiveBaseRef) {
    & git -C $repoPath worktree add -b $branchName $worktreePath $effectiveBaseRef
}
else {
    & git -C $repoPath worktree add -b $branchName $worktreePath
}
if ($LASTEXITCODE -ne 0) {
    throw "git worktree add failed for $worktreePath"
}

try {
    $puredotsPackage = Ensure-PureDotsLink -RepoName $repoName -WorktreePath $worktreePath -Root $Root
    Reset-HeadlessManifests -RepoPath $worktreePath
    $worktreeCleanup = Clear-WorktreeBuildCache -RepoPath $worktreePath
    $cleanupItems = @($worktreeCleanup)
    if ($cleanupItems.Count -gt 0) {
        $cleanupLine = "* worktree_cleanup: " + ($cleanupItems -join ", ")
    }
    else {
        $cleanupLine = "* worktree_cleanup: none"
    }
    if ($FactoryHost) {
        $factoryKilledPids += Stop-UnityEditorsForFactory
        Remove-UnityLockfile -RepoPath $worktreePath
    }
    $killedPids += Stop-UnityForProject -ProjectPath $worktreePath
}
catch {
    $lines = @(
        "# EngineerTick v1",
        "",
        "* goal_id: $goalId",
        "* repo: $repoName",
        "* task: $($goal.task)",
        "* base_ref: $effectiveBaseRef",
        $cleanupLine,
        "* branch: $branchName (not pushed)",
        "* bootstrap: FAIL",
        "* bootstrap_error: $($_.Exception.Message)",
        ""
    )
    Write-Report -Path $reportPath -Lines $lines
    exit 1
}

$preProbeStatus = & git -C $worktreePath status --porcelain
if ($preProbeStatus) {
    $lines = @(
        "# EngineerTick v1",
        "",
        "* goal_id: $goalId",
        "* repo: $repoName",
        "* task: $($goal.task)",
        "* base_ref: $effectiveBaseRef",
        $cleanupLine,
        "* branch: $branchName (not pushed)",
        "* bootstrap: FAIL",
        "* bootstrap_error: worktree dirty before probe",
        "* pre_probe_status:",
        $preProbeStatus,
        ""
    )
    Write-Report -Path $reportPath -Lines $lines
    exit 1
}

$shortTag = Apply-GoalPatch -Task $goal.task -RepoPath $worktreePath

$unityPath = Resolve-UnityExe -Preferred $UnityExe
if ($FactoryHost) {
    $factoryKilledPids += Stop-UnityEditorsForFactory
    Remove-UnityLockfile -RepoPath $worktreePath
}
$killedPids += Stop-UnityForProject -ProjectPath $worktreePath
$probe = Invoke-UnityProbe -UnityExePath $unityPath -ProjectPath $worktreePath -ReportsDir $reportsDir -Timestamp $timestamp
if (-not $probe.success) {
    $lines = @(
        "# EngineerTick v1",
        "",
        "* goal_id: $goalId",
        "* repo: $repoName",
        "* task: $($goal.task)",
        "* base_ref: $effectiveBaseRef",
        $cleanupLine,
        "* branch: $branchName (not pushed)",
        "* probe: FAIL",
        "* probe_log: $($probe.log_path)",
        "* probe_error: $($probe.error_line)",
        ""
    )
    Write-Report -Path $reportPath -Lines $lines
    exit 1
}

$gitStatus = & git -C $worktreePath status --porcelain
if (-not $gitStatus) {
    $lines = @(
        "# EngineerTick v1",
        "",
        "* goal_id: $goalId",
        "* repo: $repoName",
        "* task: $($goal.task)",
        "* base_ref: $effectiveBaseRef",
        $cleanupLine,
        "* branch: $branchName (not pushed)",
        "* probe: PASS",
        "* note: no changes detected",
        ""
    )
    Write-Report -Path $reportPath -Lines $lines
    exit 1
}

& git -C $worktreePath add -A
$commitMsg = "nightly: $shortTag"
& git -C $worktreePath commit -m $commitMsg
$commitSha = (& git -C $worktreePath rev-parse HEAD).Trim()

if (-not $DryRun) {
    & git -C $worktreePath push -u origin $branchName
}

$goalSpecRepoRoot = Join-Path $Root "headlessrebuildtool"
$goalSpecJob = Normalize-GoalSpecForJob -GoalSpecPath $goal.goal_spec -RepoRoot $goalSpecRepoRoot
if ([string]::IsNullOrWhiteSpace($goalSpecJob) -and -not [string]::IsNullOrWhiteSpace($goalId)) {
    $goalSpecJob = "Polish/Goals/specs/$goalId.json"
}

$pipelineSmoke = Join-Path $Root "Tools\\Polish\\pipeline_smoke.ps1"
if (-not (Test-Path $pipelineSmoke)) {
    throw "pipeline_smoke.ps1 not found: $pipelineSmoke"
}

$seedA = if ($repoName -eq "godgame") { 42 } else { 7 }
$seedB = if ($repoName -eq "godgame") { 43 } else { 11 }

$buildStartUtc = (Get-Date).ToUniversalTime()
if ($FactoryHost) {
    $factoryKilledPids += Stop-UnityEditorsForFactory
    Remove-UnityLockfile -RepoPath $worktreePath
}
$killedPids += Stop-UnityForProject -ProjectPath $worktreePath
$hangKillLine = "* hang_kill: none"
$smokeLog = Join-Path $reportsDir ("engineer_tick_v1_smoke_{0}.log" -f $timestamp)
$smokeArgs = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $pipelineSmoke,
    "-Title", $repoName,
    "-UnityExe", $unityPath,
    "-ProjectPathOverride", $worktreePath,
    "-QueueRoot", $QueueRoot,
    "-ScenarioId", $goal.scenario_id,
    "-ScenarioRel", $goal.scenario_rel,
    "-Seed", $seedA,
    "-GoalId", $goalId,
    "-GoalSpec", $goalSpecJob
)
$smokeProc = Start-Process -FilePath "powershell" -ArgumentList $smokeArgs -RedirectStandardOutput $smokeLog -RedirectStandardError $smokeLog -PassThru
$monitorStart = Get-Date
$lastActive = $monitorStart
$hardTimeoutMinutes = 45
$checkIntervalSeconds = 60
$stagingDir = $null
$logsDir = $null
$prevLogSnapshot = $null
$prevCpu = $null
while (-not $smokeProc.HasExited) {
    if (-not $stagingDir) {
        $stagingDir = Find-RecentStagingDir -ArtifactsDir (Join-Path $QueueRoot "artifacts") -StartUtc $buildStartUtc
        if ($stagingDir) {
            $logsDir = Join-Path $stagingDir.FullName "logs"
        }
    }

    $unityProc = Get-UnityProcessForProject -ProjectPath $worktreePath
    $unityPid = $null
    $cpuIncreased = $false
    if ($unityProc) {
        $unityPid = [int]$unityProc.ProcessId
        $procInfo = Get-Process -Id $unityPid -ErrorAction SilentlyContinue
        if ($procInfo) {
            $cpuNow = $procInfo.CPU
            if ($prevCpu -ne $null -and $cpuNow -ne $null -and $cpuNow -gt $prevCpu) {
                $cpuIncreased = $true
            }
            if ($cpuNow -ne $null) {
                $prevCpu = $cpuNow
            }
        }
    }

    $logsChanged = $false
    if ($logsDir -and (Test-Path $logsDir)) {
        $snapshot = Get-LogDirSnapshot -LogsDir $logsDir
        $logsChanged = Test-LogDirChanged -Previous $prevLogSnapshot -Current $snapshot
        $prevLogSnapshot = $snapshot
    }
    else {
        $logsChanged = $true
    }

    $beeActive = Test-BeeTundraActivity
    $activityDetected = $logsChanged -or $cpuIncreased -or $beeActive -or (-not $unityPid)
    if ($activityDetected) {
        $lastActive = Get-Date
    }

    $idleMinutes = (New-TimeSpan -Start $lastActive -End (Get-Date)).TotalMinutes
    $idleExceeded = $idleMinutes -ge 8
    if ($unityPid -and $idleExceeded -and -not $cpuIncreased -and -not $logsChanged -and -not $beeActive) {
        Stop-Process -Id $unityPid -Force -ErrorAction SilentlyContinue
        $hangKillLine = "* hang_kill: killed Unity PID $unityPid after {0:N1}m idle (no CPU/log/bee activity)" -f $idleMinutes
        break
    }

    if ((Get-Date) -gt $monitorStart.AddMinutes($hardTimeoutMinutes)) {
        if ($unityPid) {
            Stop-Process -Id $unityPid -Force -ErrorAction SilentlyContinue
            $hangKillLine = "* hang_kill: killed Unity PID $unityPid after hard timeout ({0}m)" -f $hardTimeoutMinutes
        }
        else {
            $hangKillLine = "* hang_kill: hard timeout reached (Unity not running)"
        }
        break
    }

    Start-Sleep -Seconds $checkIntervalSeconds
    $smokeProc.Refresh()
}

if (-not $smokeProc.HasExited) {
    Wait-Process -Id $smokeProc.Id -Timeout 600 -ErrorAction SilentlyContinue | Out-Null
    $smokeProc.Refresh()
}

if (-not $smokeProc.HasExited) {
    Stop-Process -Id $smokeProc.Id -Force -ErrorAction SilentlyContinue
}

$smokeExit = $smokeProc.ExitCode
$smokeOutput = if (Test-Path $smokeLog) { Get-Content -Path $smokeLog } else { @() }
$buildFailLine = $smokeOutput | Where-Object { $_ -like "BUILD_FAIL*" } | Select-Object -First 1
$artifactPath = ""
$artifactLine = $smokeOutput | Where-Object { $_ -like "artifact=*" } | Select-Object -Last 1
if ($artifactLine) { $artifactPath = ($artifactLine -replace '^artifact=', '').Trim() }
if (-not $artifactPath) {
    $artifactCandidate = Find-LatestArtifactAfter -ArtifactsDir (Join-Path $QueueRoot "artifacts") -StartUtc $buildStartUtc
    if ($artifactCandidate) { $artifactPath = $artifactCandidate.FullName }
}

if ($smokeExit -ne 0 -or $buildFailLine) {
    $inspectRoot = Join-Path $reportsDir "_inspect"
    Ensure-Directory $inspectRoot
    $inspectDir = Join-Path $inspectRoot ("buildfail_{0}" -f $timestamp)
    Ensure-Directory $inspectDir

    $primaryErrorPath = Join-Path $reportsDir ("primary_error_{0}.txt" -f $timestamp)
    $headline = if ($buildFailLine) { $buildFailLine } else { "BUILD_FAIL" }
    $logPath = ""
    $outcomeSummary = ""

    if ($artifactPath -and (Test-Path $artifactPath)) {
        Expand-Archive -Path $artifactPath -DestinationPath $inspectDir -Force
        $outcomeFile = Get-ChildItem -Path $inspectDir -Recurse -Filter "build_outcome.json" | Select-Object -First 1
        if ($outcomeFile) {
            $outcome = Read-JsonFileFromPath -Path $outcomeFile.FullName
            if ($outcome) {
                $outcomeSummary = "result=$($outcome.result) message=$($outcome.message)"
                if ($outcome.message) { $headline = $outcome.message }
            }
        }
        $logCandidate = Get-ChildItem -Path $inspectDir -Recurse -Filter "unity_build_tail.txt" | Select-Object -First 1
        if (-not $logCandidate) {
            $logCandidate = Get-ChildItem -Path $inspectDir -Recurse -Filter "Editor.log" | Select-Object -First 1
        }
        if (-not $logCandidate) {
            $logCandidate = Get-ChildItem -Path $inspectDir -Recurse -Filter "*Editor.log" | Select-Object -First 1
        }
        if ($logCandidate) {
            $logPath = $logCandidate.FullName
            $tailLines = Read-LogTail -Path $logPath -TailLines 240
            $primaryLine = Find-PrimaryErrorLine -Lines $tailLines
            if ($primaryLine) { $headline = $primaryLine }
        }
    }
    $primaryLines = @(
        "headline=$headline",
        "artifact_path=$artifactPath",
        "inspect_dir=$inspectDir",
        "log_path=$logPath",
        "build_outcome=$outcomeSummary"
    )
    Set-Content -Path $primaryErrorPath -Value $primaryLines -Encoding ascii

    $fallbackJob = $null
    if (-not $DryRun) {
        $fallbackJob = Enqueue-FallbackValidation `
            -ArtifactsDir (Join-Path $QueueRoot "artifacts") `
            -RepoName $repoName `
            -ScenarioId $goal.scenario_id `
            -ScenarioRel $goal.scenario_rel `
            -GoalId $goalId `
            -GoalSpec $goalSpecJob `
            -QueueRoot $QueueRoot `
            -Seed $seedA
    }

    $lines = @(
        "# EngineerTick v1",
        "",
        "* goal_id: $goalId",
        "* repo: $repoName",
        "* task: $($goal.task)",
        "* base_ref: $effectiveBaseRef",
        $cleanupLine,
        $hangKillLine,
        "* branch: $branchName",
        "* commit: $commitSha",
        "* probe: PASS",
        "* probe_log: $($probe.log_path)",
        "* build: FAIL",
        "* build_fail_headline: $headline",
        "* build_fail_artifact: $artifactPath",
        "* build_fail_inspect_dir: $inspectDir",
        "* primary_error_file: $primaryErrorPath",
        "* fallback_job: $fallbackJob",
        ""
    )
    Write-Report -Path $reportPath -Lines $lines
    exit 1
}

$jobPath = ""
$buildId = ""
$jobLine = $smokeOutput | Where-Object { $_ -like "job=*" } | Select-Object -Last 1
if ($jobLine) { $jobPath = ($jobLine -replace '^job=', '').Trim() }
$buildLine = $smokeOutput | Where-Object { $_ -like "build_id=*" } | Select-Object -Last 1
if ($buildLine -and $buildLine -match 'build_id=([^\s]+)') { $buildId = $Matches[1] }

$queuedJobs = @()
if (-not [string]::IsNullOrWhiteSpace($jobPath) -and (Test-Path $jobPath)) {
    $queuedJobs += (Split-Path -Leaf $jobPath)
    $job = Get-Content -Raw -Path $jobPath | ConvertFrom-Json
    $job.seed = [int]$seedB
    $job.job_id = "{0}_{1}_{2}" -f $job.build_id, $job.scenario_id, $seedB
    $job.created_utc = (Get-Date).ToUniversalTime().ToString("o")
    $jobsDir = Join-Path $QueueRoot "jobs"
    Ensure-Directory $jobsDir
    $jobTempPath = Join-Path $jobsDir (".tmp_{0}.json" -f $job.job_id)
    $jobPathB = Join-Path $jobsDir ("{0}.json" -f $job.job_id)
    ($job | ConvertTo-Json -Depth 6) | Set-Content -Path $jobTempPath -Encoding ascii
    Move-Item -Path $jobTempPath -Destination $jobPathB -Force
    $queuedJobs += (Split-Path -Leaf $jobPathB)
}

$cursorPayload = @{
    index = $nextIndex
    last_goal_id = $goalId
    updated_utc = (Get-Date).ToUniversalTime().ToString("o")
}
Write-JsonFile -Path $cursorPath -Payload $cursorPayload

$lines = @(
    "# EngineerTick v1",
    "",
    "* goal_id: $goalId",
    "* repo: $repoName",
    "* task: $($goal.task)",
    "* base_ref: $effectiveBaseRef",
    $cleanupLine,
    $hangKillLine,
    "* branch: $branchName",
    "* commit: $commitSha",
    "* probe: PASS",
        "* probe_log: $($probe.log_path)",
        "* build_id: $buildId",
        "* queued_jobs: $([string]::Join(', ', $queuedJobs))",
    ""
)
Write-Report -Path $reportPath -Lines $lines
