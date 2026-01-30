[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Title,
    [Parameter(Mandatory = $true)]
    [string]$UnityExe,
    [string]$ProjectPathOverride,
    [string]$QueueRoot = "C:\\polish\\queue",
    [string]$ScenarioId,
    [string]$ScenarioRel,
    [string]$GoalId,
    [string]$GoalSpec,
    [int]$Seed,
    [int]$TimeoutSec,
    [string[]]$Args,
    [switch]$WaitForResult,
    [int]$Repeat = 1,
    [int]$WaitTimeoutSec = 1800
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

function Get-ScenarioRelFromArgs {
    param([string[]]$ArgsIn)
    if (-not $ArgsIn) { return "" }
    for ($i = 0; $i -lt $ArgsIn.Count; $i++) {
        $token = $ArgsIn[$i]
        if ($token -in @("--scenario", "-scenario")) {
            if ($i + 1 -lt $ArgsIn.Count) {
                return $ArgsIn[$i + 1]
            }
            continue
        }
        if ($token -like "--scenario=*") {
            return $token.Substring(11)
        }
        if ($token -like "-scenario=*") {
            return $token.Substring(10)
        }
    }
    return ""
}

function Strip-ScenarioArgs {
    param([string[]]$ArgsIn)
    if (-not $ArgsIn) { return @() }
    $output = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $ArgsIn.Count; $i++) {
        $token = $ArgsIn[$i]
        if ($token -in @("--scenario", "-scenario")) {
            $i++
            continue
        }
        if ($token -like "--scenario=*") { continue }
        if ($token -like "-scenario=*") { continue }
        $output.Add($token)
    }
    return ,$output.ToArray()
}

function Get-ResultWaitTimeoutSeconds {
    param([int]$DefaultSeconds)
    $envValue = $env:TRI_RESULT_TIMEOUT_SECONDS
    $parsed = 0
    if ([int]::TryParse($envValue, [ref]$parsed) -and $parsed -gt 0) {
        return $parsed
    }
    return $DefaultSeconds
}

function Find-ResultCandidates {
    param(
        [string]$ResultsDir,
        [string]$BaseId
    )
    if (-not (Test-Path $ResultsDir)) { return @() }
    $pattern = "result_{0}*.zip" -f $BaseId
    return Get-ChildItem -Path $ResultsDir -File -Filter $pattern | Sort-Object LastWriteTime -Descending
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

function Get-FirstErrorLine {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    $lines = $Text -split "`r?`n"
    foreach ($line in $lines) {
        if ($line -match '\[Error\]' -or $line -match 'error CS\d+' -or $line -match 'PPtr cast failed') {
            return $line.Trim()
        }
    }
    return ""
}

function Get-ArtifactSummary {
    param([string]$ZipPath)
    if (-not (Test-Path $ZipPath)) { return $null }
    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $summary = [ordered]@{}
        $outcomeText = Read-ZipEntryText -Archive $archive -EntryPath "logs/build_outcome.json"
        if ($outcomeText) {
            try {
                $outcome = $outcomeText | ConvertFrom-Json
                if ($outcome.result) { $summary.result = $outcome.result }
                if ($outcome.message) { $summary.message = $outcome.message }
            }
            catch {
            }
        }
        $reportText = Read-ZipEntryText -Archive $archive -EntryPath "build/Space4X_HeadlessBuildReport.log"
        $firstError = Get-FirstErrorLine -Text $reportText
        if (-not $firstError) {
            $tailText = Read-ZipEntryText -Archive $archive -EntryPath "logs/unity_build_tail.txt"
            $firstError = Get-FirstErrorLine -Text $tailText
        }
        if ($firstError) { $summary.first_error = $firstError }
        return $summary
    }
    finally {
        $archive.Dispose()
    }
}

function Write-PipelineSummary {
    param(
        [string]$ReportsDir,
        [string]$BuildId,
        [string]$Title,
        [string]$ProjectPath,
        [string]$Commit,
        [string]$ArtifactZip,
        [string]$ScenarioId,
        [string]$ScenarioRel,
        [string]$GoalId,
        [string]$GoalSpec,
        [int]$Seed,
        [int]$TimeoutSec,
        [string[]]$Args,
        [string]$Status,
        [string]$Failure,
        [string[]]$JobPaths,
        [string[]]$ResultZips,
        [string[]]$ExtraLines
    )
    if ([string]::IsNullOrWhiteSpace($ReportsDir)) { return }
    Ensure-Directory $ReportsDir

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Pipeline Smoke Summary")
    $lines.Add("")
    $lines.Add("* status: $Status")
    if ($Failure) { $lines.Add("* failure: $Failure") }
    if ($BuildId) { $lines.Add("* build_id: $BuildId") }
    if ($Commit) { $lines.Add("* commit: $Commit") }
    if ($Title) { $lines.Add("* title: $Title") }
    if ($ProjectPath) { $lines.Add("* project_path: $ProjectPath") }
    if ($ArtifactZip) { $lines.Add("* artifact: $ArtifactZip") }
    if ($ScenarioId) { $lines.Add("* scenario_id: $ScenarioId") }
    if ($ScenarioRel) { $lines.Add("* scenario_rel: $ScenarioRel") }
    if ($GoalId) { $lines.Add("* goal_id: $GoalId") }
    if ($GoalSpec) { $lines.Add("* goal_spec: $GoalSpec") }
    if ($Seed) { $lines.Add("* seed: $Seed") }
    if ($TimeoutSec) { $lines.Add("* timeout_sec: $TimeoutSec") }
    if ($Args -and $Args.Count -gt 0) { $lines.Add("* args: " + ([string]::Join(" ", $Args))) }
    if ($ExtraLines -and $ExtraLines.Count -gt 0) {
        foreach ($line in $ExtraLines) { $lines.Add($line) }
    }

    if ($ArtifactZip -and (Test-Path $ArtifactZip)) {
        $artifactSummary = Get-ArtifactSummary -ZipPath $ArtifactZip
        if ($artifactSummary) {
            $resultValue = $artifactSummary["result"]
            $messageValue = $artifactSummary["message"]
            $firstErrorValue = $artifactSummary["first_error"]
            if ($resultValue) { $lines.Add("* build_result: $resultValue") }
            if ($messageValue) { $lines.Add("* build_message: $messageValue") }
            if ($firstErrorValue) { $lines.Add("* build_first_error: $firstErrorValue") }
        }
    }

    if ($JobPaths -and $JobPaths.Count -gt 0) {
        $lines.Add("")
        $lines.Add("## Jobs")
        foreach ($job in $JobPaths) { $lines.Add("- $job") }
    }

    if ($ResultZips -and $ResultZips.Count -gt 0) {
        $lines.Add("")
        $lines.Add("## Results")
        foreach ($zip in $ResultZips) {
            $details = Get-ResultDetails -ZipPath $zip
            $summary = Format-ResultSummary -Index 1 -Total 1 -Details $details
            $lines.Add("- $zip")
            $lines.Add("  $summary")
        }
    }

    $outPath = if ($BuildId) { Join-Path $ReportsDir ("pipeline_smoke_summary_{0}.md" -f $BuildId) } else { Join-Path $ReportsDir "pipeline_smoke_summary_unknown.md" }
    Set-Content -Path $outPath -Value ($lines -join "`r`n") -Encoding ascii
    $latestPath = Join-Path $ReportsDir "pipeline_smoke_summary_latest.md"
    Copy-Item -Path $outPath -Destination $latestPath -Force
}

function Invoke-PPtrFileIdScan {
    param(
        [string]$FirstError,
        [string]$ProjectPath,
        [string]$ReportsDir,
        [string]$TriRoot
    )
    if ([string]::IsNullOrWhiteSpace($FirstError)) { return $null }
    if ($FirstError -notmatch 'FileID\\s+(\\d+)') { return $null }

    $fileId = $matches[1]
    if ([string]::IsNullOrWhiteSpace($fileId)) { return $null }

    $scanScript = $null
    $candidates = @(
        (Join-Path $TriRoot "Tools\\HeadlessRebuildTool\\Polish\\Ops\\find_unity_fileid_reference.ps1"),
        (Join-Path $TriRoot "Tools\\Polish\\Ops\\find_unity_fileid_reference.ps1"),
        (Join-Path $TriRoot "Polish\\Ops\\find_unity_fileid_reference.ps1")
    )
    foreach ($cand in $candidates) {
        if ([string]::IsNullOrWhiteSpace($cand)) { continue }
        if (Test-Path $cand) { $scanScript = $cand; break }
    }
    if (-not $scanScript) { return $null }

    Ensure-Directory $ReportsDir
    $outPath = Join-Path $ReportsDir ("pptr_fileid_{0}.log" -f $fileId)
    try {
        & $scanScript -FileId $fileId -Root $ProjectPath -IncludePackages -OutFile $outPath | Out-Null
    } catch {
    }
    if (Test-Path $outPath) { return $outPath }
    return $null
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$triRoot = $env:TRI_ROOT
if ([string]::IsNullOrWhiteSpace($triRoot) -or -not (Test-Path $triRoot)) {
    $triRoot = (Resolve-Path (Join-Path $scriptRoot "..\\..")).Path
} else {
    $triRoot = (Resolve-Path $triRoot).Path
}

function Resolve-FirstExisting {
    param(
        [string[]]$Candidates,
        [string]$Description
    )
    foreach ($candidate in $Candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if (Test-Path $candidate) { return (Resolve-Path $candidate).Path }
    }
    $attempts = ($Candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`r`n- "
    throw "Missing $Description. Tried:`r`n- $attempts"
}
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
if ($PSBoundParameters.ContainsKey("ProjectPathOverride") -and -not [string]::IsNullOrWhiteSpace($ProjectPathOverride)) {
    $projectPath = $ProjectPathOverride
}
$projectPath = [System.IO.Path]::GetFullPath($projectPath)
if (-not (Test-Path $projectPath)) {
    throw "Project path not found: $projectPath"
}

if (-not (Test-Path $UnityExe)) {
    throw "Unity exe not found: $UnityExe"
}

$syncScript = Resolve-FirstExisting -Candidates @(
    (Join-Path $triRoot "Tools\\sync_headless_manifest.ps1"),
    (Join-Path $triRoot "sync_headless_manifest.ps1")
) -Description "headless manifest sync script"

$swapScript = Resolve-FirstExisting -Candidates @(
    (Join-Path $triRoot "Tools\\Tools\\use_headless_manifest_windows.ps1"),
    (Join-Path $triRoot "Tools\\use_headless_manifest_windows.ps1"),
    (Join-Path $triRoot "use_headless_manifest_windows.ps1")
) -Description "headless manifest swap script"

$scenarioIdValue = if ($PSBoundParameters.ContainsKey("ScenarioId")) { $ScenarioId } else { $titleDefaults.scenario_id }
$scenarioRelValue = if ($PSBoundParameters.ContainsKey("ScenarioRel")) { $ScenarioRel } else { $titleDefaults.scenario_rel }
$goalIdValue = if ($PSBoundParameters.ContainsKey("GoalId")) { $GoalId } else { "" }
$goalSpecValue = if ($PSBoundParameters.ContainsKey("GoalSpec")) { Normalize-GoalSpecPath -GoalSpecPath $GoalSpec -RepoRoot $triRoot } else { "" }
$seedValue = if ($PSBoundParameters.ContainsKey("Seed")) { $Seed } else { [int]$titleDefaults.seed }
$timeoutValue = if ($PSBoundParameters.ContainsKey("TimeoutSec")) { $TimeoutSec } else { [int]$titleDefaults.timeout_sec }
$argsValue = if ($PSBoundParameters.ContainsKey("Args")) { $Args } else { $titleDefaults.args }
if ($null -eq $argsValue) { $argsValue = @() }
if (-not $scenarioRelValue) {
    $scenarioRelValue = Get-ScenarioRelFromArgs $argsValue
}
if ($scenarioRelValue) {
    $scenarioRelValue = Normalize-ScenarioRel $scenarioRelValue
    $argsValue = Strip-ScenarioArgs $argsValue
}
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

$summaryJobPaths = New-Object System.Collections.Generic.List[string]
$summaryResultZips = New-Object System.Collections.Generic.List[string]
$summaryExtraLines = New-Object System.Collections.Generic.List[string]
$summaryStatus = "SUCCESS"
$summaryFailure = ""
$summaryWritten = $false

function Finalize-PipelineSummary {
    param(
        [string]$Status,
        [string]$Failure
    )
    if ($summaryWritten) { return }
    $summaryWritten = $true
    if ($Status) { $script:summaryStatus = $Status }
    if ($Failure) { $script:summaryFailure = $Failure }
    Write-PipelineSummary -ReportsDir $reportsDir `
        -BuildId $buildId `
        -Title $Title `
        -ProjectPath $projectPath `
        -Commit $commitFull `
        -ArtifactZip $artifactZip `
        -ScenarioId $scenarioIdValue `
        -ScenarioRel $scenarioRelValue `
        -GoalId $goalIdValue `
        -GoalSpec $goalSpecValue `
        -Seed $seedValue `
        -TimeoutSec $timeoutValue `
        -Args $argsValue `
        -Status $summaryStatus `
        -Failure $summaryFailure `
        -JobPaths $summaryJobPaths.ToArray() `
        -ResultZips $summaryResultZips.ToArray() `
        -ExtraLines $summaryExtraLines.ToArray()
}

$supervisorProject = Resolve-FirstExisting -Candidates @(
    (Join-Path $triRoot "Tools\\HeadlessBuildSupervisor\\HeadlessBuildSupervisor.csproj"),
    (Join-Path $triRoot "HeadlessBuildSupervisor\\HeadlessBuildSupervisor.csproj")
) -Description "HeadlessBuildSupervisor.csproj"

$supervisorArgs = @(
    "run", "--project", $supervisorProject, "--",
    "--unity-exe", $UnityExe,
    "--project-path", $projectPath,
    "--build-id", $buildId,
    "--commit", $commitFull,
    "--artifact-dir", $artifactsDir
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
$global:LASTEXITCODE = 0

$artifactZip = Join-Path $artifactsDir ("artifact_{0}.zip" -f $buildId)
if (-not (Test-Path $artifactZip)) {
    $summaryFailure = "artifact_missing"
    Finalize-PipelineSummary -Status "FAIL" -Failure "artifact_missing"
    throw "Artifact zip not found: $artifactZip"
}

$preflight = Get-ArtifactPreflight -ZipPath $artifactZip
if (-not $preflight.ok) {
    $artifactSummary = Get-ArtifactSummary -ZipPath $artifactZip
    $firstErrorLine = ""
    if ($artifactSummary -and $artifactSummary.Contains("first_error")) { $firstErrorLine = $artifactSummary["first_error"] }
    if ($firstErrorLine -and $firstErrorLine -match 'PPtr cast failed') {
        $pptrReport = Invoke-PPtrFileIdScan -FirstError $firstErrorLine -ProjectPath $projectPath -ReportsDir $reportsDir -TriRoot $triRoot
        if ($pptrReport) {
            $summaryExtraLines.Add("* pptr_scan_report: $pptrReport") | Out-Null
        }
    }
    $summary = "BUILD_FAIL reason={0}" -f $preflight.reason
    if ($preflight.result) { $summary += " result=$($preflight.result)" }
    if ($preflight.message) { $summary += " message=$($preflight.message)" }
    Write-Host $summary
    $summaryFailure = $summary
    Finalize-PipelineSummary -Status "FAIL" -Failure $summary
    exit 1
}

$artifactUri = Convert-ToWslPath $artifactZip
$repoRootWsl = Convert-ToWslPath $projectPath
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
        repo_root = $repoRootWsl
    }
    if ($scenarioRelValue) {
        $job.scenario_rel = $scenarioRelValue
    }
    if ($goalIdValue) {
        $job.goal_id = $goalIdValue
    }
    if ($goalSpecValue) {
        $job.goal_spec = $goalSpecValue
    }

    $jobJson = $job | ConvertTo-Json -Depth 6
    $jobTempPath = Join-Path $jobsDir (".tmp_{0}.json" -f $jobId)
    $jobPath = Join-Path $jobsDir ("{0}.json" -f $jobId)
    Set-Content -Path $jobTempPath -Value $jobJson -Encoding ascii
    Move-Item -Path $jobTempPath -Destination $jobPath -Force

    Write-Host ("job={0}" -f $jobPath)
    $summaryJobPaths.Add($jobPath) | Out-Null

    if ($WaitForResult) {
        $resultZip = Join-Path $resultsDir ("result_{0}.zip" -f $jobId)
        $resultBaseId = "{0}_{1}_{2}" -f $buildId, $scenarioIdValue, $seedValue
        $waitTimeoutSec = Get-ResultWaitTimeoutSeconds -DefaultSeconds $WaitTimeoutSec
        $baseDeadline = (Get-Date).AddSeconds($waitTimeoutSec)
        $stableSeconds = 5
        $stableDeadline = $null
        $lastSize = -1
        $lastPath = $null
        while ($true) {
            $now = Get-Date
            $candidate = $null
            if (Test-Path $resultZip) {
                $candidate = $resultZip
            }
            else {
                $alternates = Find-ResultCandidates -ResultsDir $resultsDir -BaseId $resultBaseId
                if ($alternates) {
                    $candidate = @($alternates)[0].FullName
                }
            }

            if ($candidate) {
                if ($lastPath -ne $candidate) {
                    $lastPath = $candidate
                    $lastSize = -1
                    $stableDeadline = $now.AddSeconds($stableSeconds)
                }
                $item = Get-Item $candidate -ErrorAction SilentlyContinue
                if ($item) {
                    if ($item.Length -ne $lastSize) {
                        $lastSize = $item.Length
                        $stableDeadline = $now.AddSeconds($stableSeconds)
                    }
                    if ($stableDeadline -and $now -ge $stableDeadline) {
                        $resultZip = $candidate
                        break
                    }
                }
            }
            elseif ($now -ge $baseDeadline) {
                break
            }

            Start-Sleep -Seconds 2
        }

        if (-not (Test-Path $resultZip)) {
            $alternates = Find-ResultCandidates -ResultsDir $resultsDir -BaseId $resultBaseId
            $alternateNames = if ($alternates) { $alternates | Select-Object -ExpandProperty Name } else { @() }
            $alternateList = if (@($alternateNames).Count -gt 0) { [string]::Join(", ", @($alternateNames)) } else { "(none)" }
            Write-Host ("Timed out waiting for {0}; found alternates: {1}" -f $resultZip, $alternateList)
            $summaryFailure = "result_timeout"
            Finalize-PipelineSummary -Status "FAIL" -Failure "Timed out waiting for result: $resultZip"
            throw "Timed out waiting for result: $resultZip"
        }

        $details = Get-ResultDetails -ZipPath $resultZip
        $summary = Format-ResultSummary -Index $i -Total $Repeat -Details $details
        Write-Host $summary
        $summaryResultZips.Add($resultZip) | Out-Null

        if ($details.exit_reason -in @("INFRA_FAIL", "CRASH", "HANG_TIMEOUT")) {
            Write-Host ("stop_reason={0}" -f $details.exit_reason)
            $summaryFailure = "stop_reason=$($details.exit_reason)"
            Finalize-PipelineSummary -Status "FAIL" -Failure $summaryFailure
            exit 2
        }

        if ([string]::IsNullOrWhiteSpace($details.determinism_hash)) {
            Write-Host ("stop_reason=determinism_hash_missing run_index={0}" -f $i)
            $summaryFailure = "determinism_hash_missing"
            Finalize-PipelineSummary -Status "FAIL" -Failure $summaryFailure
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
            $summaryFailure = "determinism_hash_divergence"
            Finalize-PipelineSummary -Status "FAIL" -Failure $summaryFailure
            exit 3
        }
    }
}

Finalize-PipelineSummary -Status "SUCCESS" -Failure ""
$global:LASTEXITCODE = 0
return
