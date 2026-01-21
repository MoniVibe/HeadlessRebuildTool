[CmdletBinding()]
param(
    [string]$Root = "C:\\Dev\\unity_clean",
    [string]$QueueRoot = "C:\\polish\\queue",
    [string]$UnityExe,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Directory {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
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

& git -C $repoPath worktree add -b $branchName $worktreePath
if ($LASTEXITCODE -ne 0) {
    throw "git worktree add failed for $worktreePath"
}

$shortTag = Apply-GoalPatch -Task $goal.task -RepoPath $worktreePath

$unityPath = Resolve-UnityExe -Preferred $UnityExe
$probe = Invoke-UnityProbe -UnityExePath $unityPath -ProjectPath $worktreePath -ReportsDir $reportsDir -Timestamp $timestamp
if (-not $probe.success) {
    $lines = @(
        "# EngineerTick v1",
        "",
        "* goal_id: $goalId",
        "* repo: $repoName",
        "* task: $($goal.task)",
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

$smokeOutput = & $pipelineSmoke `
    -Title $repoName `
    -UnityExe $unityPath `
    -ProjectPathOverride $worktreePath `
    -QueueRoot $QueueRoot `
    -ScenarioId $goal.scenario_id `
    -ScenarioRel $goal.scenario_rel `
    -Seed $seedA `
    -GoalId $goalId `
    -GoalSpec $goalSpecJob 2>&1

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
    "* branch: $branchName",
    "* commit: $commitSha",
    "* probe: PASS",
    "* probe_log: $($probe.log_path)",
    "* build_id: $buildId",
    "* queued_jobs: $([string]::Join(', ', $queuedJobs))",
    ""
)
Write-Report -Path $reportPath -Lines $lines
