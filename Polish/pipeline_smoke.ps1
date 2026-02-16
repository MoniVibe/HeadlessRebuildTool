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
    [hashtable]$Env,
    [string]$EnvJson,
    [switch]$PureGreen,
    [switch]$PureGreenPlayMode,
    [switch]$WaitForResult,
    [int]$Repeat = 1,
    [int]$WaitTimeoutSec = 600
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-BuildboxOnly {
    $allowLocal = $env:ALLOW_LOCAL_PIPELINE_SMOKE
    if ($allowLocal -and $allowLocal.Trim() -ne "0") {
        return
    }

    $signals = @(
        $env:BUILD_BOX,
        $env:BUILDBOX,
        $env:BUILD_BOX_RUN,
        $env:GITHUB_ACTIONS,
        $env:CI
    ) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -ne "" }

    $hasBuildboxSignal = $false
    foreach ($signal in $signals) {
        if ($signal -match '^(1|true|yes)$') {
            $hasBuildboxSignal = $true
            break
        }
    }

    if (-not $hasBuildboxSignal) {
        throw "USE BUILDBOX: pipeline_smoke.ps1 is blocked locally. Run this via Buildbox (on-demand workflow) or set ALLOW_LOCAL_PIPELINE_SMOKE=1 for an explicit override."
    }
}

Assert-BuildboxOnly

function Ensure-Directory {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function Normalize-ProjectPathInput {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    $trim = $Path.Trim()
    # If a WSL path is provided, convert to Windows path for Unity.
    $wslMatch = [regex]::Match($trim, '^/mnt/([a-z])/(.*)$')
    if ($wslMatch.Success) {
        $drive = $wslMatch.Groups[1].Value.ToUpperInvariant()
        $rest = $wslMatch.Groups[2].Value -replace '/', '\'
        return ("{0}:\{1}" -f $drive, $rest)
    }
    # If path contains an embedded absolute drive segment, keep the last one.
    $driveMatches = [regex]::Matches($trim, '[A-Za-z]:[\\/]')
    if ($driveMatches.Count -gt 0) {
        $trim = $trim.Substring($driveMatches[$driveMatches.Count - 1].Index)
    }
    return $trim
}

function Ensure-GitSafeDirectory {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $full = [System.IO.Path]::GetFullPath($Path)
    try {
        & git config --global --add safe.directory $full | Out-Null
    }
    catch {
        # Best-effort only; continue if git config fails.
    }
}

function Resolve-GitDir {
    param([string]$RepoPath)
    if ([string]::IsNullOrWhiteSpace($RepoPath)) { return "" }
    $gitPath = Join-Path $RepoPath ".git"
    if (-not (Test-Path $gitPath)) { return "" }
    $gitItem = Get-Item $gitPath -ErrorAction SilentlyContinue
    if ($null -eq $gitItem) { return "" }
    if ($gitItem.Attributes -band [System.IO.FileAttributes]::Directory) {
        return $gitPath
    }
    $line = Get-Content $gitPath -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($line -match '^gitdir:\s*(.+)$') {
        $dir = $Matches[1].Trim()
        if (-not [System.IO.Path]::IsPathRooted($dir)) {
            $dir = Join-Path $RepoPath $dir
        }
        return $dir
    }
    return ""
}

function Convert-ToWslPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    $raw = $Path.Trim()
    if ($raw -match '^/mnt/[a-z]/') {
        return ($raw -replace '\\', '/')
    }
    $driveMatches = [regex]::Matches($raw, '[A-Za-z]:[\\/]')
    if ($driveMatches.Count -gt 0) {
        $raw = $raw.Substring($driveMatches[$driveMatches.Count - 1].Index)
    }
    $full = [System.IO.Path]::GetFullPath($raw)
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

function Get-ScenarioIdFromRel {
    param([string]$ScenarioRel)
    if ([string]::IsNullOrWhiteSpace($ScenarioRel)) { return "" }
    $name = [System.IO.Path]::GetFileNameWithoutExtension($ScenarioRel)
    if ([string]::IsNullOrWhiteSpace($name)) { return "" }
    return $name
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

function ConvertTo-EnvMap {
    param(
        [hashtable]$Env,
        [string]$EnvJson
    )
    $map = @{}
    if (-not [string]::IsNullOrWhiteSpace($EnvJson)) {
        try {
            $parsed = $EnvJson | ConvertFrom-Json
        } catch {
            throw "EnvJson is invalid JSON."
        }
        if ($parsed) {
            foreach ($prop in $parsed.PSObject.Properties) {
                $map[$prop.Name] = $prop.Value
            }
        }
    }
    if ($Env) {
        foreach ($key in $Env.Keys) {
            $map[$key] = $Env[$key]
        }
    }
    return $map
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

function Resolve-BoolEnv {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    $value = [string][Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) { return $false }
    $value = $value.Trim().ToLowerInvariant()
    return ($value -in @("1", "true", "yes", "y", "on"))
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

function Get-NewestResultZip {
    param(
        [string]$ResultsDir
    )
    if (-not (Test-Path $ResultsDir)) { return $null }
    return Get-ChildItem -Path $ResultsDir -File -Filter "result_*.zip" |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
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

function Get-MatchLines {
    param(
        [string]$Text,
        [string[]]$Patterns,
        [int]$Max = 5
    )
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    if (-not $Patterns -or $Patterns.Count -eq 0) { return @() }
    $hits = New-Object System.Collections.Generic.List[string]
    $lines = $Text -split "`r?`n"
    foreach ($line in $lines) {
        foreach ($pattern in $Patterns) {
            if ($line -match $pattern) {
                $trimmed = $line.Trim()
                if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
                    $hits.Add($trimmed) | Out-Null
                }
                break
            }
        }
        if ($hits.Count -ge $Max) { break }
    }
    return ,$hits.ToArray()
}

function Get-ArtifactErrorMatches {
    param(
        [string]$ZipPath,
        [string[]]$Patterns
    )
    if (-not (Test-Path $ZipPath)) { return @() }
    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    $matches = New-Object System.Collections.Generic.List[string]
    try {
        $entries = @(
            "logs/unity_build_tail.txt",
            "build/Space4X_HeadlessBuildReport.log",
            "logs/primary_error_snippet.txt"
        )
        foreach ($entry in $entries) {
            $text = Read-ZipEntryText -Archive $archive -EntryPath $entry
            if (-not $text) { continue }
            $lines = Get-MatchLines -Text $text -Patterns $Patterns -Max 3
            foreach ($line in $lines) { $matches.Add($line) | Out-Null }
            if ($matches.Count -ge 5) { break }
        }
        return ,$matches.ToArray()
    }
    finally {
        $archive.Dispose()
    }
}

function Get-ResultErrorMatches {
    param(
        [string]$ZipPath,
        [string[]]$Patterns
    )
    if (-not (Test-Path $ZipPath)) { return @() }
    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    $matches = New-Object System.Collections.Generic.List[string]
    try {
        $entries = @(
            "out/stderr.log",
            "out/player.log",
            "out/diag_stderr_tail.txt"
        )
        foreach ($entry in $entries) {
            $text = Read-ZipEntryText -Archive $archive -EntryPath $entry
            if (-not $text) { continue }
            $lines = Get-MatchLines -Text $text -Patterns $Patterns -Max 3
            foreach ($line in $lines) { $matches.Add($line) | Out-Null }
            if ($matches.Count -ge 5) { break }
        }
        return ,$matches.ToArray()
    }
    finally {
        $archive.Dispose()
    }
}

function Invoke-PlayModeGate {
    param(
        [string]$UnityExe,
        [string]$ProjectPath,
        [string]$ReportsDir,
        [string]$BuildId
    )
    $logPath = Join-Path $ReportsDir ("pure_green_playmode_{0}.log" -f $BuildId)
    $testResults = Join-Path $ReportsDir ("pure_green_playmode_{0}.xml" -f $BuildId)
    $args = @(
        "-batchmode", "-nographics",
        "-projectPath", $ProjectPath,
        "-runTests", "-testPlatform", "PlayMode",
        "-testResults", $testResults,
        "-logFile", $logPath,
        "-quit"
    )
    & $UnityExe @args
    $exitCode = $LASTEXITCODE

    $failure = $null
    $firstError = $null
    if ($exitCode -ne 0) {
        $failure = "exit_code_$exitCode"
    }

    if (-not $failure -and (Test-Path $testResults)) {
        try {
            [xml]$xml = Get-Content -Path $testResults -Raw
            $failed = $xml.SelectNodes("//test-case[@result='Failed' or @result='Error']")
            if ($failed -and $failed.Count -gt 0) {
                $failure = "tests_failed"
                $firstError = $failed[0].GetAttribute("name")
            }
        } catch {
            $failure = "results_parse_failed"
            $firstError = $_.Exception.Message
        }
    }

    if (-not $failure -and (Test-Path $logPath)) {
        $match = Select-String -Path $logPath -Pattern "Exception|error\\s+CS\\d+|AssertionException|\\bFAIL(?:ED)?\\b" -AllMatches -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($match) {
            $failure = "log_error"
            $firstError = $match.Line.Trim()
        }
    }

    return [ordered]@{
        success = (-not $failure)
        exit_code = $exitCode
        reason = $failure
        log_path = $logPath
        test_results = $testResults
        first_error = $firstError
    }
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

function Get-FirstPPtrErrorFromArtifact {
    param([string]$ZipPath)
    if (-not (Test-Path $ZipPath)) { return "" }
    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $pptrText = Read-ZipEntryText -Archive $archive -EntryPath "logs/primary_error_snippet.txt"
        if (-not $pptrText) {
            $entry = $archive.Entries | Where-Object { $_.Name -ieq "primary_error_snippet.txt" } | Select-Object -First 1
            if ($entry) {
                $reader = New-Object System.IO.StreamReader($entry.Open())
                try { $pptrText = $reader.ReadToEnd() } finally { $reader.Dispose() }
            }
        }
        if (-not $pptrText) {
            $pptrText = Read-ZipEntryText -Archive $archive -EntryPath "logs/unity_build_tail.txt"
            if (-not $pptrText) {
                $entry = $archive.Entries | Where-Object { $_.Name -ieq "unity_build_tail.txt" } | Select-Object -First 1
                if ($entry) {
                    $reader = New-Object System.IO.StreamReader($entry.Open())
                    try { $pptrText = $reader.ReadToEnd() } finally { $reader.Dispose() }
                }
            }
        }
        return Get-FirstErrorLine -Text $pptrText
    }
    finally {
        $archive.Dispose()
    }
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
$projectPath = Normalize-ProjectPathInput $projectPath
$projectPath = [System.IO.Path]::GetFullPath($projectPath)
if (-not (Test-Path $projectPath)) {
    throw "Project path not found: $projectPath"
}

if (-not (Test-Path $UnityExe)) {
    throw "Unity exe not found: $UnityExe"
}

$syncScript = Resolve-FirstExisting -Candidates @(
    (Join-Path $triRoot "Tools\\HeadlessRebuildTool\\sync_headless_manifest.ps1"),
    (Join-Path $triRoot "Tools\\sync_headless_manifest.ps1"),
    (Join-Path $triRoot "sync_headless_manifest.ps1")
) -Description "headless manifest sync script"

$swapScript = Resolve-FirstExisting -Candidates @(
    (Join-Path $triRoot "Tools\\HeadlessRebuildTool\\Tools\\use_headless_manifest_windows.ps1"),
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
if (-not $PSBoundParameters.ContainsKey("ScenarioId") -and $scenarioRelValue) {
    $derivedScenarioId = Get-ScenarioIdFromRel $scenarioRelValue
    if ($derivedScenarioId) {
        $scenarioIdValue = $derivedScenarioId
    }
}
if ($Repeat -lt 1) {
    throw "Repeat must be >= 1."
}

$envMap = ConvertTo-EnvMap -Env $Env -EnvJson $EnvJson
if ($envMap.ContainsKey("PURE_GREEN")) {
    $env:PURE_GREEN = [string]$envMap["PURE_GREEN"]
}
if ($envMap.ContainsKey("PURE_GREEN_PLAYMODE")) {
    $env:PURE_GREEN_PLAYMODE = [string]$envMap["PURE_GREEN_PLAYMODE"]
}
$pureGreenEnabled = $false
if ($PureGreen.IsPresent) {
    $pureGreenEnabled = $true
} elseif (Resolve-BoolEnv -Name "PURE_GREEN") {
    $pureGreenEnabled = $true
}
$pureGreenPlayModeEnabled = $false
if ($PureGreenPlayMode.IsPresent) {
    $pureGreenPlayModeEnabled = $true
} elseif (Resolve-BoolEnv -Name "PURE_GREEN_PLAYMODE") {
    $pureGreenPlayModeEnabled = $true
}
$pureGreenBuildPatterns = @(
    'error CS\d+',
    'PPtr cast failed',
    'Missing package manifest',
    'ScriptCompilationFailed',
    'AssemblyUpdater failed',
    'The type or namespace name .* does not exist',
    'could not be found \(are you missing an assembly reference',
    'NullReferenceException',
    'MissingReferenceException'
)
$pureGreenRuntimePatterns = @(
    'error CS\d+',
    '\bException\b',
    'NullReferenceException',
    'MissingReferenceException',
    'IndexOutOfRangeException',
    'ArgumentException',
    'InvalidOperationException',
    'PPtr cast failed',
    'ScriptCompilationFailed',
    'Stack overflow',
    'Segmentation fault'
)

Ensure-GitSafeDirectory $projectPath
$gitDirPath = Resolve-GitDir $projectPath
if (-not [string]::IsNullOrWhiteSpace($gitDirPath)) {
    Ensure-GitSafeDirectory $gitDirPath
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
$summaryPipelineState = ""
$summaryBuildState = "unknown"
$summaryRunState = "unknown"
if ($pureGreenEnabled) {
    $summaryExtraLines.Add("* pure_green: true") | Out-Null
}
if ($pureGreenPlayModeEnabled) {
    $summaryExtraLines.Add("* pure_green_playmode: true") | Out-Null
}

function Finalize-PipelineSummary {
    param(
        [string]$Status,
        [string]$Failure
    )
    if ($summaryWritten) { return }
    $summaryWritten = $true
    if ($Status) { $script:summaryStatus = $Status }
    if ($Failure) { $script:summaryFailure = $Failure }
    if ([string]::IsNullOrWhiteSpace($script:summaryPipelineState)) {
        $script:summaryPipelineState = if ($script:summaryStatus -eq "SUCCESS") { "finished" } else { "failed" }
    }
    if ([string]::IsNullOrWhiteSpace($script:summaryBuildState)) {
        $script:summaryBuildState = "unknown"
    }
    if ([string]::IsNullOrWhiteSpace($script:summaryRunState)) {
        $script:summaryRunState = "unknown"
    }
    $summaryExtraLines.Add("* pipeline_state: $script:summaryPipelineState") | Out-Null
    $summaryExtraLines.Add("* build_state: $script:summaryBuildState") | Out-Null
    $summaryExtraLines.Add("* run_state: $script:summaryRunState") | Out-Null
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
    $summaryBuildState = "failed"
    $summaryRunState = "skipped"
    Finalize-PipelineSummary -Status "FAIL" -Failure "artifact_missing"
    throw "Artifact zip not found: $artifactZip"
}

$preflight = Get-ArtifactPreflight -ZipPath $artifactZip
if (-not $preflight.ok) {
    $firstErrorLine = Get-FirstPPtrErrorFromArtifact -ZipPath $artifactZip
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
    $summaryBuildState = "failed"
    $summaryRunState = "skipped"
    Finalize-PipelineSummary -Status "FAIL" -Failure $summary
    exit 1
}
else {
    $summaryBuildState = "built"
}

if ($pureGreenEnabled) {
    $buildErrors = Get-ArtifactErrorMatches -ZipPath $artifactZip -Patterns $pureGreenBuildPatterns
    if ($buildErrors -and $buildErrors.Count -gt 0) {
        $first = $buildErrors[0]
        $summaryExtraLines.Add("* pure_green_build_error: $first") | Out-Null
        $summaryFailure = "pure_green_build_error"
        $summaryBuildState = "failed"
        $summaryRunState = "skipped"
        Finalize-PipelineSummary -Status "FAIL" -Failure $summaryFailure
        exit 4
    }
}

if ($pureGreenPlayModeEnabled) {
    $gate = Invoke-PlayModeGate -UnityExe $UnityExe -ProjectPath $projectPath -ReportsDir $reportsDir -BuildId $buildId
    if (-not $gate.success) {
        if ($gate.first_error) {
            $summaryExtraLines.Add("* pure_green_playmode_error: $($gate.first_error)") | Out-Null
        }
        if ($gate.log_path) {
            $summaryExtraLines.Add("* pure_green_playmode_log: $($gate.log_path)") | Out-Null
        }
        if ($gate.test_results) {
            $summaryExtraLines.Add("* pure_green_playmode_results: $($gate.test_results)") | Out-Null
        }
        $summaryFailure = if ($gate.reason) { "pure_green_playmode_$($gate.reason)" } else { "pure_green_playmode_failed" }
        $summaryBuildState = "failed"
        $summaryRunState = "skipped"
        Finalize-PipelineSummary -Status "FAIL" -Failure $summaryFailure
        exit 6
    }
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
    if ($envMap.Count -gt 0) {
        $job.env = $envMap
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
        $waitTimeoutSec = Get-ResultWaitTimeoutSeconds -DefaultSeconds ([Math]::Max($WaitTimeoutSec, $timeoutValue + 600))
        $baseDeadline = (Get-Date).AddSeconds($waitTimeoutSec)
        $stableSeconds = 5
        $stableDeadline = $null
        $lastSize = -1
        $lastPath = $null
        $waitStarted = Get-Date
        $lastHeartbeat = $waitStarted.AddSeconds(-31)
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

            if (($now - $lastHeartbeat).TotalSeconds -ge 30) {
                $elapsedSec = [int]($now - $waitStarted).TotalSeconds
                $remainingSec = [int][Math]::Max(0, ($baseDeadline - $now).TotalSeconds)
                $candidateName = if ($candidate) { Split-Path $candidate -Leaf } else { "none" }
                $newest = Get-NewestResultZip -ResultsDir $resultsDir
                $newestText = "none"
                if ($newest) {
                    $ageSec = [int]($now - $newest.LastWriteTime).TotalSeconds
                    $newestText = ("{0} age_s={1} size={2}" -f $newest.Name, $ageSec, $newest.Length)
                }
                Write-Host ("wait_for_result heartbeat elapsed_s={0} remaining_s={1} candidate={2} lastSize={3} newest={4}" -f $elapsedSec, $remainingSec, $candidateName, $lastSize, $newestText)
                $lastHeartbeat = $now
            }

            Start-Sleep -Seconds 2
        }

        if (-not (Test-Path $resultZip)) {
            $alternates = Find-ResultCandidates -ResultsDir $resultsDir -BaseId $resultBaseId
            $alternateNames = if ($alternates) { $alternates | Select-Object -ExpandProperty Name } else { @() }
            $alternateList = if (@($alternateNames).Count -gt 0) { [string]::Join(", ", @($alternateNames)) } else { "(none)" }
            $recent = if (Test-Path $resultsDir) {
                Get-ChildItem -Path $resultsDir -File -Filter "result_*.zip" |
                    Sort-Object LastWriteTime -Descending |
                    Select-Object -First 5
            }
            else {
                @()
            }
            if (@($recent).Count -gt 0) {
                Write-Host "Newest result zips:"
                foreach ($zip in $recent) {
                    $ageSec = [int]((Get-Date) - $zip.LastWriteTime).TotalSeconds
                    Write-Host ("  {0} last_write={1:o} size={2} age_s={3}" -f $zip.Name, $zip.LastWriteTime, $zip.Length, $ageSec)
                }
            }
            else {
                Write-Host "Newest result zips: (none)"
            }
            Write-Host ("Timed out waiting for {0}; found alternates: {1}" -f $resultZip, $alternateList)
            $summaryFailure = "result_timeout"
            $summaryRunState = "failed"
            Finalize-PipelineSummary -Status "FAIL" -Failure "Timed out waiting for result: $resultZip"
            throw "Timed out waiting for result: $resultZip"
        }

        $details = Get-ResultDetails -ZipPath $resultZip
        $summary = Format-ResultSummary -Index $i -Total $Repeat -Details $details
        Write-Host $summary
        $summaryResultZips.Add($resultZip) | Out-Null
        if ($pureGreenEnabled) {
            $runtimeErrors = Get-ResultErrorMatches -ZipPath $resultZip -Patterns $pureGreenRuntimePatterns
            if ($runtimeErrors -and $runtimeErrors.Count -gt 0) {
                $first = $runtimeErrors[0]
                $summaryExtraLines.Add("* pure_green_runtime_error: $first") | Out-Null
                $summaryFailure = "pure_green_runtime_error"
                $summaryRunState = "failed"
                Finalize-PipelineSummary -Status "FAIL" -Failure $summaryFailure
                exit 5
            }
        }
        if ($details.exit_reason -in @("SUCCESS", "OK_WITH_WARNINGS")) {
            $summaryRunState = "ran"
        } else {
            $summaryRunState = "failed"
        }

        if ($details.exit_reason -in @("INFRA_FAIL", "CRASH", "HANG_TIMEOUT")) {
            Write-Host ("stop_reason={0}" -f $details.exit_reason)
            $summaryFailure = "stop_reason=$($details.exit_reason)"
            $summaryRunState = "failed"
            Finalize-PipelineSummary -Status "FAIL" -Failure $summaryFailure
            exit 2
        }

        if ([string]::IsNullOrWhiteSpace($details.determinism_hash)) {
            Write-Host ("stop_reason=determinism_hash_missing run_index={0}" -f $i)
            $summaryFailure = "determinism_hash_missing"
            $summaryRunState = "failed"
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
            $summaryRunState = "failed"
            Finalize-PipelineSummary -Status "FAIL" -Failure $summaryFailure
            exit 3
        }
    }
    else {
        $summaryRunState = "queued"
    }
}

Finalize-PipelineSummary -Status "SUCCESS" -Failure ""
$global:LASTEXITCODE = 0
return
