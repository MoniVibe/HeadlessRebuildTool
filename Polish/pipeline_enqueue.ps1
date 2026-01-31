[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Title,
    [string]$ArtifactZip,
    [string]$BuildId,
    [string]$ProjectPathOverride,
    [string]$QueueRoot = "C:\\polish\\queue",
    [string]$ScenarioId,
    [string]$ScenarioRel,
    [string]$GoalId,
    [string]$GoalSpec,
    [int]$Seed,
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
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
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
        return [ordered]@{
            exit_reason = $exitReason
            exit_code = $exitCode
            failure_signature = $failureSignature
        }
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
    return ($parts -join " ")
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
if ($PSBoundParameters.ContainsKey("ProjectPathOverride") -and -not [string]::IsNullOrWhiteSpace($ProjectPathOverride)) {
    $projectPath = $ProjectPathOverride
}
$projectPath = [System.IO.Path]::GetFullPath($projectPath)
if (-not (Test-Path $projectPath)) {
    throw "Project path not found: $projectPath"
}

if ([string]::IsNullOrWhiteSpace($ArtifactZip)) {
    if ([string]::IsNullOrWhiteSpace($BuildId)) {
        throw "Provide -ArtifactZip or -BuildId."
    }
    $ArtifactZip = Join-Path (Join-Path $QueueRoot "artifacts") ("artifact_{0}.zip" -f $BuildId)
}
if (-not (Test-Path $ArtifactZip)) {
    throw "Artifact zip not found: $ArtifactZip"
}

$outcome = Read-BuildOutcome -ZipPath $ArtifactZip
if (-not $outcome) {
    throw "build_outcome.json missing in artifact: $ArtifactZip"
}
if ($outcome.result -ne "Succeeded") {
    throw "Artifact build is not succeeded: result=$($outcome.result) message=$($outcome.message)"
}

$buildIdValue = $outcome.build_id
$commitValue = $outcome.commit
if ([string]::IsNullOrWhiteSpace($buildIdValue) -or [string]::IsNullOrWhiteSpace($commitValue)) {
    throw "build_outcome.json missing build_id or commit"
}

$scenarioIdValue = if ($PSBoundParameters.ContainsKey("ScenarioId")) { $ScenarioId } else { $titleDefaults.scenario_id }
$scenarioRelValue = if ($PSBoundParameters.ContainsKey("ScenarioRel")) { $ScenarioRel } else { $titleDefaults.scenario_rel }
$goalIdValue = if ($PSBoundParameters.ContainsKey("GoalId")) { $GoalId } else { "" }
$goalSpecValue = if ($PSBoundParameters.ContainsKey("GoalSpec")) { Normalize-GoalSpecPath -GoalSpecPath $GoalSpec -RepoRoot $triRoot } else { "" }
$seedValue = if ($PSBoundParameters.ContainsKey("Seed")) { $Seed } else { [int]$titleDefaults.seed }
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

$queueRootFull = [System.IO.Path]::GetFullPath($QueueRoot)
$jobsDir = Join-Path $queueRootFull "jobs"
$resultsDir = Join-Path $queueRootFull "results"
Ensure-Directory $jobsDir
Ensure-Directory $resultsDir

$artifactUri = Convert-ToWslPath $ArtifactZip
$repoRootWsl = Convert-ToWslPath $projectPath

for ($i = 1; $i -le $Repeat; $i++) {
    $suffix = ""
    if ($Repeat -gt 1) {
        $suffix = "_r{0:D2}" -f $i
    }
    $jobId = "{0}_{1}_{2}{3}" -f $buildIdValue, $scenarioIdValue, $seedValue, $suffix
    $createdUtc = ([DateTime]::UtcNow).ToString("o")

    $job = [ordered]@{
        job_id = $jobId
        commit = $commitValue
        build_id = $buildIdValue
        scenario_id = $scenarioIdValue
        seed = [int]$seedValue
        timeout_sec = [int]$titleDefaults.timeout_sec
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

    if ($WaitForResult) {
        $resultZip = Join-Path $resultsDir ("result_{0}.zip" -f $jobId)
        $resultBaseId = "{0}_{1}_{2}" -f $buildIdValue, $scenarioIdValue, $seedValue
        $deadline = (Get-Date).AddSeconds($WaitTimeoutSec)
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
            elseif ($now -ge $deadline) {
                break
            }

            Start-Sleep -Seconds 2
        }

        if (-not (Test-Path $resultZip)) {
            throw "Timed out waiting for result: $resultZip"
        }

        $details = Get-ResultDetails -ZipPath $resultZip
        $summary = Format-ResultSummary -Index $i -Total $Repeat -Details $details
        Write-Host $summary
    }
}
