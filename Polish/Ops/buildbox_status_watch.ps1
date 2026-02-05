[CmdletBinding()]
param(
    [string]$Repo = "MoniVibe/HeadlessRebuildTool",
    [string]$Workflow = "buildbox_on_demand.yml",
    [string[]]$Titles = @("space4x","godgame"),
    [int]$IntervalSec = 60,
    [int]$Loops = 0,
    [switch]$Once,
    [switch]$UseSsh,
    [string]$SshHost = "25.30.14.37",
    [string]$SshUser = "Moni",
    [string]$SshKey = "",
    [string]$SshExe = "",
    [string]$QueueRoot = "C:\\polish\\anviloop",
    [string]$LegacyQueueRoot = "C:\\polish\\queue",
    [switch]$ShowRunner,
    [switch]$HideLocalQueue,
    [switch]$NoClear,
    [int]$TableWidth = 220
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Section([string]$title) {
    Write-Host ""
    Write-Host ("== {0} ==" -f $title)
}

function Trim-Text([string]$value, [int]$max) {
    if ([string]::IsNullOrEmpty($value)) { return "" }
    if ($value.Length -le $max) { return $value }
    if ($max -le 3) { return $value.Substring(0, $max) }
    return ($value.Substring(0, $max - 3) + "...")
}

function Write-Table {
    param([object[]]$Rows)
    if (-not $Rows -or $Rows.Count -eq 0) { return }
    $rendered = $Rows | Format-Table -AutoSize -Wrap | Out-String -Width $TableWidth
    Write-Host ($rendered.TrimEnd())
}

function Format-Elapsed([datetime]$start, [datetime]$end) {
    if ($end -lt $start) { return "" }
    $span = $end - $start
    if ($span.TotalSeconds -lt 60) { return ("{0:N0}s" -f $span.TotalSeconds) }
    if ($span.TotalMinutes -lt 60) { return ("{0:N0}m" -f $span.TotalMinutes) }
    if ($span.TotalHours -lt 24) { return ("{0:N0}h" -f $span.TotalHours) }
    return ("{0:N0}d" -f $span.TotalDays)
}

function Format-RunStatus([string]$status, [string]$conclusion) {
    if ($status -eq "completed") {
        if ($conclusion) { return $conclusion.ToUpperInvariant() }
        return "COMPLETED"
    }
    if ($status) { return $status.ToUpperInvariant() }
    return "UNKNOWN"
}

function Show-GhRuns {
    Write-Section "Buildbox Runs"
    try {
        $runs = gh run list -R $Repo --workflow $Workflow --limit 8 --json status,conclusion,displayTitle,headBranch,event,number,createdAt,startedAt,updatedAt | ConvertFrom-Json
        $now = Get-Date
        $rows = foreach ($run in $runs) {
            $created = if ($run.createdAt) { Get-Date $run.createdAt } else { $now }
            $started = if ($run.startedAt) { Get-Date $run.startedAt } else { $created }
            $updated = if ($run.updatedAt) { Get-Date $run.updatedAt } else { $now }
            [pscustomobject]@{
                STATUS  = (Format-RunStatus $run.status $run.conclusion)
                TITLE   = $run.displayTitle
                BRANCH  = $run.headBranch
                EVENT   = $run.event
                ID      = $run.number
                ELAPSED = (Format-Elapsed $started $updated)
                AGE     = (Format-Elapsed $created $now)
            }
        }
        Write-Table -Rows $rows
    } catch {
        Write-Host ("gh run list failed: {0}" -f $_.Exception.Message)
    }
}

function Read-ResultMeta {
    param([string]$ZipPath)
    if (-not $ZipPath -or -not (Test-Path $ZipPath)) { return $null }
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
        $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        try {
            $entry = $archive.GetEntry("meta.json")
            if (-not $entry) { return $null }
            $reader = New-Object System.IO.StreamReader($entry.Open())
            try {
                $text = $reader.ReadToEnd()
                if (-not $text) { return $null }
                return ($text | ConvertFrom-Json)
            } finally {
                $reader.Dispose()
            }
        } finally {
            $archive.Dispose()
        }
    } catch {
        return $null
    }
}

function Write-LatestResultSummary {
    param([string]$ResultsDir)
    if (-not (Test-Path $ResultsDir)) { return }
    $latest = Get-ChildItem -Path $ResultsDir -Filter "result_*.zip" -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) { return }
    Write-Host ("latest_result={0}" -f $latest.Name)
    $meta = Read-ResultMeta -ZipPath $latest.FullName
    if ($meta) {
        $exitReason = if ($meta.exit_reason) { $meta.exit_reason } else { "" }
        $exitCode = if ($meta.exit_code -ne $null) { $meta.exit_code } else { "" }
        $buildId = if ($meta.build_id) { $meta.build_id } else { "" }
        $commit = if ($meta.commit) { $meta.commit } else { "" }
        $scenario = if ($meta.scenario_id) { $meta.scenario_id } else { "" }
        Write-Host ("  exit_reason={0} exit_code={1} build_id={2} commit={3} scenario={4}" -f $exitReason, $exitCode, $buildId, $commit, $scenario)
    }
}

function Read-SummaryField {
    param(
        [string[]]$Lines,
        [string]$Name
    )
    if (-not $Lines) { return "" }
    $pattern = "^\*\s+${Name}:\s*(.+)$"
    foreach ($line in $Lines) {
        $m = [regex]::Match($line, $pattern)
        if ($m.Success) { return $m.Groups[1].Value.Trim() }
    }
    return ""
}

function Show-PipelineStatus {
    Write-Section "Pipeline Status"
    $rows = @()
    foreach ($title in $Titles) {
        $summaryPath = Join-Path $QueueRoot "$title\\queue\\reports\\pipeline_smoke_summary_latest.md"
        $legacyPath = Join-Path $LegacyQueueRoot "reports\\pipeline_smoke_summary_latest.md"
        $lines = @()
        $source = ""
        if (Test-Path $summaryPath) {
            $lines = Get-Content -Path $summaryPath
            $source = $summaryPath
        } elseif (Test-Path $legacyPath) {
            $lines = Get-Content -Path $legacyPath
            $source = $legacyPath
        }
        if (-not $lines -or $lines.Count -eq 0) {
            $rows += [pscustomobject]@{
                TITLE = $title
                PIPELINE = "summary_missing"
                BUILD = ""
                RUN = ""
                WORKFLOW = ""
                SCENARIO = ""
                BUILD_ID = ""
            }
            continue
        }
        $pipelineState = Read-SummaryField -Lines $lines -Name "pipeline_state"
        if (-not $pipelineState) {
            $status = Read-SummaryField -Lines $lines -Name "status"
            if ($status) {
                if ($status -eq "SUCCESS") {
                    $pipelineState = "finished"
                } else {
                    $pipelineState = "failed"
                }
            }
        }
        $buildState = Read-SummaryField -Lines $lines -Name "build_state"
        $runState = Read-SummaryField -Lines $lines -Name "run_state"
        $scenarioId = Read-SummaryField -Lines $lines -Name "scenario_id"
        $buildId = Read-SummaryField -Lines $lines -Name "build_id"
        $workflowState = Read-SummaryField -Lines $lines -Name "workflow_state"
        $rows += [pscustomobject]@{
            TITLE = $title
            PIPELINE = $pipelineState
            BUILD = $buildState
            RUN = $runState
            WORKFLOW = $workflowState
            SCENARIO = $scenarioId
            BUILD_ID = $buildId
        }
    }
    if ($rows.Count -gt 0) {
        Write-Table -Rows $rows
    }
}

function Show-Runner {
    if (-not $ShowRunner) { return }
    Write-Section "Runner Status"
    try {
        gh api repos/$Repo/actions/runners --jq '.runners[] | {name: .name, status: .status, labels: (.labels|map(.name))}'
    } catch {
        Write-Host ("gh api runners failed: {0}" -f $_.Exception.Message)
    }
}

function Get-SshClientInfo {
    $sshExe = $SshExe
    $extraArgs = @()
    if ([string]::IsNullOrWhiteSpace($sshExe)) {
        $cmd = Get-Command ssh -ErrorAction SilentlyContinue
        if ($cmd) { $sshExe = $cmd.Source }
        else {
            $fallback = Join-Path $env:WINDIR "System32\\OpenSSH\\ssh.exe"
            if (Test-Path $fallback) { $sshExe = $fallback }
        }
    } elseif (-not (Test-Path $sshExe)) {
        $parts = $sshExe -split '\s+'
        if ($parts.Length -gt 1 -and (Test-Path $parts[0])) {
            $sshExe = $parts[0]
            $extraArgs = $parts[1..($parts.Length - 1)]
        }
    }
    if ([string]::IsNullOrWhiteSpace($sshExe) -or -not (Test-Path $sshExe)) {
        return [pscustomobject]@{ ok = $false; error = "ssh.exe not found (set -SshExe or install OpenSSH)." }
    }

    $keyPath = $SshKey
    if ([string]::IsNullOrWhiteSpace($keyPath)) {
        $keyPath = Join-Path $env:USERPROFILE ".ssh\\buildbox_laptop_ed25519"
    }
    if (-not (Test-Path $keyPath)) {
        return [pscustomobject]@{ ok = $false; error = ("ssh key not found: {0}" -f $keyPath) }
    }

    return [pscustomobject]@{
        ok = $true
        exe = $sshExe
        extra = $extraArgs
        key = $keyPath
    }
}

function Invoke-SshJson {
    param([string]$RemoteScript)
    $sshInfo = Get-SshClientInfo
    if (-not $sshInfo.ok) { throw $sshInfo.error }

    $sshArgs = @(
        "-i", $sshInfo.key,
        "-o", "IdentitiesOnly=yes",
        "-o", "StrictHostKeyChecking=accept-new",
        ("{0}@{1}" -f $SshUser, $SshHost)
    )
    $remote = "powershell -NoProfile -Command `"$RemoteScript`""
    $output = & $sshInfo.exe @($sshInfo.extra + $sshArgs) $remote
    if (-not $output) { return $null }
    return ($output | ConvertFrom-Json)
}

function Show-SshHealth {
    if (-not $UseSsh) { return }
    Write-Section "Desktop Queue (SSH)"
    $remoteScript = @'
$ErrorActionPreference='Stop';
$drive=Get-PSDrive -Name C -EA SilentlyContinue;
$freeGb=if($drive){[math]::Round($drive.Free/1GB,1)}else{''};
$queueList=@(
    @{name='space4x';path='C:\polish\anviloop\space4x\queue'},
    @{name='godgame';path='C:\polish\anviloop\godgame\queue'}
);
$queues=@();
foreach($q in $queueList){
    if(-not(Test-Path $q.path)){
        $queues += [ordered]@{ name=$q.name; jobs='MISSING'; leases='MISSING'; results='MISSING'; artifacts='MISSING'; latest='MISSING' };
        continue;
    }
    $jobs=Join-Path $q.path 'jobs';
    $leases=Join-Path $q.path 'leases';
    $results=Join-Path $q.path 'results';
    $artifacts=Join-Path $q.path 'artifacts';
    $jobsCount=if(Test-Path $jobs){(Get-ChildItem $jobs -File).Count}else{0};
    $leasesCount=if(Test-Path $leases){(Get-ChildItem $leases -File).Count}else{0};
    $resultsCount=if(Test-Path $results){(Get-ChildItem $results -File).Count}else{0};
    $artifactsCount=if(Test-Path $artifacts){(Get-ChildItem $artifacts -File).Count}else{0};
    $latestItem=$null;
    if(Test-Path $results){
        foreach($item in (Get-ChildItem $results -Filter 'result_*.zip' -File)){
            if(-not $latestItem -or $item.LastWriteTime -gt $latestItem.LastWriteTime){$latestItem=$item}
        }
    }
    $latestName=if($latestItem){$latestItem.Name}else{''};
    $queues += [ordered]@{ name=$q.name; jobs=$jobsCount; leases=$leasesCount; results=$resultsCount; artifacts=$artifactsCount; latest=$latestName };
}
[ordered]@{
    host=$env:COMPUTERNAME;
    user=[Environment]::UserName;
    c_free_gb=$freeGb;
    queues=$queues
} | ConvertTo-Json -Depth 4
'@
    $remoteScript = ($remoteScript -replace "\r?\n", " ")
    try {
        $data = Invoke-SshJson -RemoteScript $remoteScript
        if (-not $data) {
            Write-Host "ssh health failed: empty response"
            return
        }
        Write-Host ("HOST={0} USER={1} C_free_GB={2}" -f $data.host, $data.user, $data.c_free_gb)
        $rows = foreach ($q in $data.queues) {
            [pscustomobject]@{
                TITLE = $q.name
                JOBS = $q.jobs
                LEASES = $q.leases
                RESULTS = $q.results
                ARTIFACTS = $q.artifacts
                LATEST = $q.latest
            }
        }
        Write-Table -Rows $rows
    } catch {
        Write-Host ("ssh health failed: {0}" -f $_.Exception.Message)
    }
}

function Show-LocalQueue {
    Write-Section "Local Queue (if any)"
    $rows = @()
    $localRoots = @($QueueRoot)
    if ($QueueRoot -ne $LegacyQueueRoot) {
        $localRoots += $LegacyQueueRoot
    }
    foreach ($title in $Titles) {
        $resolved = $null
        foreach ($candidate in $localRoots) {
            $titleRoot = Join-Path $candidate "$title\\queue"
            if (Test-Path $titleRoot) { $resolved = $titleRoot; break }
            $directJobs = Join-Path $candidate "jobs"
            if (Test-Path $directJobs) { $resolved = $candidate; break }
        }
        if (-not $resolved) {
            $rows += [pscustomobject]@{
                TITLE = $title
                JOBS = "MISSING"
                LEASES = "MISSING"
                RESULTS = "MISSING"
                ARTIFACTS = "MISSING"
                LATEST = ""
            }
            continue
        }
        $jobs = Join-Path $resolved "jobs"
        $leases = Join-Path $resolved "leases"
        $results = Join-Path $resolved "results"
        $artifacts = Join-Path $resolved "artifacts"
        $jobsCount = if (Test-Path $jobs) { (Get-ChildItem -Path $jobs -File | Measure-Object).Count } else { "MISSING" }
        $leasesCount = if (Test-Path $leases) { (Get-ChildItem -Path $leases -File | Measure-Object).Count } else { "MISSING" }
        $resultsCount = if (Test-Path $results) { (Get-ChildItem -Path $results -File | Measure-Object).Count } else { "MISSING" }
        $artifactsCount = if (Test-Path $artifacts) { (Get-ChildItem -Path $artifacts -File | Measure-Object).Count } else { "MISSING" }
        $latestLabel = ""
        if (Test-Path $results) {
            $latest = Get-ChildItem -Path $results -Filter "result_*.zip" -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($latest) {
                $meta = Read-ResultMeta -ZipPath $latest.FullName
                if ($meta) {
                    $latestLabel = ("{0}/{1} {2}" -f $meta.exit_reason, $meta.exit_code, (Trim-Text $meta.scenario_id 24))
                } else {
                    $latestLabel = $latest.Name
                }
            }
        }
        $rows += [pscustomobject]@{
            TITLE = $title
            JOBS = $jobsCount
            LEASES = $leasesCount
            RESULTS = $resultsCount
            ARTIFACTS = $artifactsCount
            LATEST = $latestLabel
        }
    }
    if ($rows.Count -gt 0) {
        Write-Table -Rows $rows
    }
}

$iteration = 0
while ($true) {
    $iteration++
    if (-not $NoClear) {
        try { Clear-Host } catch { }
    }
    Write-Host ("[{0}] buildbox_status_watch" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    Show-GhRuns
    Show-PipelineStatus
    Show-Runner
    if (-not $HideLocalQueue) { Show-LocalQueue }
    Show-SshHealth

    if ($Once) { break }
    if ($Loops -gt 0 -and $iteration -ge $Loops) { break }
    Start-Sleep -Seconds $IntervalSec
}
