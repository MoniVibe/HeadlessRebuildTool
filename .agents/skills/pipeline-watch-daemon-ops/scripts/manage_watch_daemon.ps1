[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("status", "start", "stop", "ensure")]
    [string]$Action,
    [Parameter(Mandatory = $true)]
    [ValidateSet("space4x", "godgame")]
    [string]$Title,
    [Parameter(Mandatory = $true)]
    [string]$QueueRoot,
    [int]$PollSeconds = 15,
    [int]$Repeat = 1,
    [string]$StatePath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-RepoRoot {
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $resolved = Resolve-Path (Join-Path $scriptDir "..\..\..\..")
    if ($resolved -is [string]) { return $resolved }
    return @($resolved)[0].Path
}

function Get-ProcessCreatedUtc {
    param([string]$CreationDate)
    if ([string]::IsNullOrWhiteSpace($CreationDate)) { return [DateTime]::MinValue }
    try {
        return [Management.ManagementDateTimeConverter]::ToDateTime($CreationDate).ToUniversalTime()
    }
    catch {
        return [DateTime]::MinValue
    }
}

function Get-WatchDaemonProcesses {
    param(
        [string]$TitleValue,
        [string]$QueueRootValue
    )
    $queueLower = $QueueRootValue.ToLowerInvariant()
    $candidates = Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -ErrorAction SilentlyContinue
    if (-not $candidates) { return @() }

    return @(
        $candidates | Where-Object {
            if (-not $_.CommandLine) { return $false }
            $cmd = $_.CommandLine
            $cmdLower = $cmd.ToLowerInvariant()
            if ($cmdLower -notmatch 'pipeline_watch_daemon\.ps1') { return $false }
            if ($cmdLower -notmatch ("-title\s+[`"']?{0}([`"'\s]|$)" -f [regex]::Escape($TitleValue.ToLowerInvariant()))) { return $false }
            if (-not $cmdLower.Contains($queueLower)) { return $false }
            return $true
        }
    )
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

$repoRoot = Resolve-RepoRoot
$daemonScript = Join-Path $repoRoot "Polish\pipeline_watch_daemon.ps1"
if (-not (Test-Path $daemonScript)) {
    throw "Missing daemon script: $daemonScript"
}

$artifactDir = Join-Path $repoRoot ".agents\skills\artifacts\pipeline-watch-daemon-ops"
Ensure-Directory -Path $artifactDir

$matched = Get-WatchDaemonProcesses -TitleValue $Title -QueueRootValue $QueueRoot
$matched = @($matched | Sort-Object { Get-ProcessCreatedUtc -CreationDate $_.CreationDate } -Descending)

if ($Action -eq "status") {
    Write-Host ("title={0}" -f $Title)
    Write-Host ("queue_root={0}" -f $QueueRoot)
    Write-Host ("running_count={0}" -f $matched.Count)
    foreach ($proc in $matched) {
        $created = Get-ProcessCreatedUtc -CreationDate $proc.CreationDate
        Write-Host ("pid={0} started_utc={1}" -f $proc.ProcessId, $created.ToString("yyyy-MM-ddTHH:mm:ssZ"))
    }
    return
}

if ($Action -eq "stop") {
    $stopped = 0
    foreach ($proc in $matched) {
        try {
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
            $stopped += 1
            Write-Host ("stopped_pid={0}" -f $proc.ProcessId)
        }
        catch {
            Write-Warning ("failed_stop_pid={0} error={1}" -f $proc.ProcessId, $_.Exception.Message)
        }
    }
    Start-Sleep -Seconds 1
    $remaining = Get-WatchDaemonProcesses -TitleValue $Title -QueueRootValue $QueueRoot
    Write-Host ("stopped_count={0}" -f $stopped)
    Write-Host ("running_count={0}" -f $remaining.Count)
    return
}

if ($Action -eq "ensure" -and $matched.Count -gt 1) {
    $keep = $matched[0]
    $extras = @($matched | Select-Object -Skip 1)
    foreach ($proc in $extras) {
        try {
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
            Write-Host ("stopped_extra_pid={0}" -f $proc.ProcessId)
        }
        catch {
            Write-Warning ("failed_stop_extra_pid={0} error={1}" -f $proc.ProcessId, $_.Exception.Message)
        }
    }
    Start-Sleep -Seconds 1
    $matched = Get-WatchDaemonProcesses -TitleValue $Title -QueueRootValue $QueueRoot
}

if ($matched.Count -gt 0) {
    $running = $matched | Sort-Object { Get-ProcessCreatedUtc -CreationDate $_.CreationDate } -Descending | Select-Object -First 1
    Write-Host ("already_running_pid={0}" -f $running.ProcessId)
    Write-Host ("running_count={0}" -f $matched.Count)
    return
}

$stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmss")
$stdoutPath = Join-Path $artifactDir ("watch_{0}_{1}_stdout.log" -f $Title, $stamp)
$stderrPath = Join-Path $artifactDir ("watch_{0}_{1}_stderr.log" -f $Title, $stamp)

$args = @(
    "-NoProfile",
    "-File", $daemonScript,
    "-Title", $Title,
    "-QueueRoot", $QueueRoot,
    "-PollSeconds", $PollSeconds,
    "-Repeat", $Repeat
)
if (-not [string]::IsNullOrWhiteSpace($StatePath)) {
    $args += @("-StatePath", $StatePath)
}

$proc = Start-Process -FilePath "pwsh" -ArgumentList $args -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
Write-Host ("started_pid={0}" -f $proc.Id)
Write-Host ("stdout_log={0}" -f $stdoutPath)
Write-Host ("stderr_log={0}" -f $stderrPath)
