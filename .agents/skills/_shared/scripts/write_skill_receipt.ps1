[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SkillSlug,
    [Parameter(Mandatory = $true)]
    [ValidateSet("pass", "fail")]
    [string]$Status,
    [string]$Reason = "",
    [string]$InputsJson = "{}",
    [string]$CommandsJson = "[]",
    [string]$PathsConsumedJson = "[]",
    [string]$PathsProducedJson = "[]",
    [string]$LinksJson = "{}",
    [string]$StartedUtc = "",
    [string[]]$LogLines
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Parse-Json {
    param(
        [string]$JsonText,
        [string]$Label
    )
    if ([string]::IsNullOrWhiteSpace($JsonText)) {
        return $null
    }
    try {
        return ($JsonText | ConvertFrom-Json)
    }
    catch {
        throw "Invalid JSON for $Label."
    }
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Get-RepoInfo {
    param([string]$RepoRoot)
    $info = [ordered]@{
        full_name = ""
        remote_url = ""
    }
    $gitInfo = [ordered]@{
        sha = ""
        branch = ""
        dirty = $false
    }
    try {
        $remote = (& git -C $RepoRoot config --get remote.origin.url 2>$null)
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($remote)) {
            $info.remote_url = $remote.Trim()
            if ($info.remote_url -match '[:/]([^/:]+/[^/.]+)(?:\.git)?$') {
                $info.full_name = $Matches[1]
            }
        }
    }
    catch {
    }
    try {
        $sha = (& git -C $RepoRoot rev-parse HEAD 2>$null)
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($sha)) {
            $gitInfo.sha = $sha.Trim()
        }
    }
    catch {
    }
    try {
        $branch = (& git -C $RepoRoot rev-parse --abbrev-ref HEAD 2>$null)
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($branch)) {
            $gitInfo.branch = $branch.Trim()
        }
    }
    catch {
    }
    try {
        $status = (& git -C $RepoRoot status --porcelain 2>$null)
        if ($LASTEXITCODE -eq 0 -and $status) {
            $gitInfo.dirty = $true
        }
    }
    catch {
    }
    return [ordered]@{
        repo = $info
        git = $gitInfo
    }
}

function Get-HostInfo {
    $osDescription = ""
    try {
        $osDescription = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
    }
    catch {
        $osDescription = [Environment]::OSVersion.VersionString
    }
    $pwshVersion = ""
    try {
        $pwshVersion = $PSVersionTable.PSVersion.ToString()
    }
    catch {
    }
    $isWsl = $false
    if ($env:WSL_DISTRO_NAME -or $env:WSL_INTEROP) {
        $isWsl = $true
    }
    return [ordered]@{
        os = $osDescription
        machine = $env:COMPUTERNAME
        pwsh_version = $pwshVersion
        is_wsl = $isWsl
    }
}

function Get-SafeEnv {
    $allowToCanonical = @{
        "TRI_ROOT" = "TRI_ROOT"
        "TRI_STATE_DIR" = "TRI_STATE_DIR"
        "UNITY_EXE" = "UNITY_EXE"
        "UNITY_WIN" = "UNITY_WIN"
        "QUEUE_ROOT" = "QueueRoot"
        "QUEUEROOT" = "QueueRoot"
        "WSL_DISTRO_NAME" = "WSL_DISTRO_NAME"
    }
    $denyPattern = '(?i)(TOKEN|KEY|SECRET|PASS|COOKIE|CONN|CREDENTIAL)'
    $envMap = [ordered]@{}
    foreach ($entry in [Environment]::GetEnvironmentVariables().GetEnumerator()) {
        $name = [string]$entry.Key
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $upper = $name.ToUpperInvariant()
        if (-not $allowToCanonical.ContainsKey($upper)) { continue }
        if ($name -match $denyPattern) { continue }
        $canonical = $allowToCanonical[$upper]
        if ($envMap.Contains($canonical)) { continue }
        $val = [string]$entry.Value
        if (-not [string]::IsNullOrWhiteSpace($val)) {
            $envMap[$canonical] = $val
        }
    }
    return $envMap
}

function Parse-Utc {
    param([string]$Text)
    try {
        if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
        return [DateTimeOffset]::Parse($Text).ToUniversalTime()
    }
    catch {
        return $null
    }
}

function To-List {
    param([object]$Value)
    if ($null -eq $Value) { return @() }
    if ($Value -is [string]) { return @($Value) }
    return @($Value)
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = (Resolve-Path (Join-Path $scriptDir "..\..\..\..")).Path
$artifactsDir = Join-Path $repoRoot (".agents\skills\artifacts\{0}" -f $SkillSlug)
Ensure-Directory -Path $artifactsDir

$inputs = Parse-Json -JsonText $InputsJson -Label "InputsJson"
$commands = Parse-Json -JsonText $CommandsJson -Label "CommandsJson"
$pathsConsumed = Parse-Json -JsonText $PathsConsumedJson -Label "PathsConsumedJson"
$pathsProduced = Parse-Json -JsonText $PathsProducedJson -Label "PathsProducedJson"
$links = Parse-Json -JsonText $LinksJson -Label "LinksJson"
$commandsList = @(To-List -Value $commands)
$pathsConsumedList = @(To-List -Value $pathsConsumed)
$pathsProducedList = @(To-List -Value $pathsProduced)
$logLinesList = @(To-List -Value $LogLines)

$started = $StartedUtc
if ([string]::IsNullOrWhiteSpace($started)) {
    $started = (Get-Date).ToUniversalTime().ToString("o")
}
$finished = (Get-Date).ToUniversalTime().ToString("o")
$runStamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ")
$runId = "{0}-{1}" -f $runStamp, ([Guid]::NewGuid().ToString("N").Substring(0, 6))
$manifestPath = Join-Path $artifactsDir ("run_manifest_{0}.json" -f $runId)
$logPath = Join-Path $artifactsDir ("run_log_{0}.md" -f $runId)
$latestManifestPath = Join-Path $artifactsDir "latest_manifest.json"
$latestLogPath = Join-Path $artifactsDir "latest_log.md"
$legacyManifestPath = Join-Path $artifactsDir "run_manifest.json"
$legacyLogPath = Join-Path $artifactsDir "run_log.md"
$repoAndGit = Get-RepoInfo -RepoRoot $repoRoot
$hostInfo = Get-HostInfo
$safeEnv = Get-SafeEnv
$startDto = Parse-Utc -Text $started
$endDto = Parse-Utc -Text $finished
$durationMs = $null
if ($startDto -and $endDto) {
    $durationMs = [Math]::Round(($endDto - $startDto).TotalMilliseconds, 0)
}

$manifest = [ordered]@{
    schema_version = 1
    skill = $SkillSlug
    run_id = $runId
    receipt_paths = [ordered]@{
        manifest = $manifestPath
        log = $logPath
        latest_manifest = $latestManifestPath
        latest_log = $latestLogPath
    }
    repo = $repoAndGit.repo
    git = $repoAndGit.git
    host = $hostInfo
    env = $safeEnv
    timing = [ordered]@{
        started_at = $started
        ended_at = $finished
        duration_ms = $durationMs
    }
    status = $Status
    reason = $Reason
    inputs = $inputs
    commands = $commandsList
    paths_consumed = $pathsConsumedList
    paths_produced = $pathsProducedList
    links = $links
}

$manifest | ConvertTo-Json -Depth 12 | Set-Content -Path $manifestPath -Encoding ascii
$manifest | ConvertTo-Json -Depth 12 | Set-Content -Path $latestManifestPath -Encoding ascii
$manifest | ConvertTo-Json -Depth 12 | Set-Content -Path $legacyManifestPath -Encoding ascii

$logBlock = New-Object System.Collections.Generic.List[string]
$logBlock.Add("# Skill Run Log: $SkillSlug")
$logBlock.Add("")
$logBlock.Add("- status: $Status")
$logBlock.Add("- finished_utc: $finished")
if (-not [string]::IsNullOrWhiteSpace($Reason)) {
    $logBlock.Add("- reason: $Reason")
}
else {
    $logBlock.Add("- reason: (none)")
}
$logBlock.Add("- run_id: $runId")
$logBlock.Add("- manifest: $manifestPath")
$logBlock.Add("- latest_manifest: $latestManifestPath")
$logBlock.Add("- consumed paths:")
if ($pathsConsumedList.Count -gt 0) {
    foreach ($path in $pathsConsumedList) { $logBlock.Add("  - $path") }
}
else {
    $logBlock.Add("  - (none)")
}
$logBlock.Add("- produced paths:")
if ($pathsProducedList.Count -gt 0) {
    foreach ($path in $pathsProducedList) { $logBlock.Add("  - $path") }
}
else {
    $logBlock.Add("  - (none)")
}
if ($logLinesList.Count -gt 0) {
    $logBlock.Add("- notes:")
    foreach ($line in $logLinesList) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $logBlock.Add("  - $line")
    }
}
$logBlock.Add("")

Set-Content -Path $logPath -Encoding ascii -Value $logBlock
Set-Content -Path $latestLogPath -Encoding ascii -Value $logBlock
Set-Content -Path $legacyLogPath -Encoding ascii -Value $logBlock

Write-Host ("manifest_path={0}" -f $manifestPath)
Write-Host ("latest_manifest_path={0}" -f $latestManifestPath)
Write-Host ("log_path={0}" -f $logPath)
Write-Host ("latest_log_path={0}" -f $latestLogPath)
