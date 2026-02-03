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
    [string]$SshKey = "/home/shonh/.ssh/buildbox_laptop_ed25519",
    [string]$SshExe = "",
    [string]$QueueRoot = "C:\\polish\\anviloop",
    [switch]$ShowRunner
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Section([string]$title) {
    Write-Host ""; Write-Host ("== {0} ==" -f $title)
}

function Show-GhRuns {
    Write-Section "Buildbox Runs"
    try {
        gh run list -R $Repo --workflow $Workflow --limit 8
    } catch {
        Write-Host ("gh run list failed: {0}" -f $_.Exception.Message)
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
    foreach ($title in $Titles) {
        $summaryPath = Join-Path $QueueRoot "$title\\queue\\reports\\pipeline_smoke_summary_latest.md"
        if (-not (Test-Path $summaryPath)) {
            Write-Host ("{0}: summary_missing" -f $title)
            continue
        }
        $lines = Get-Content -Path $summaryPath
        $pipelineState = Read-SummaryField -Lines $lines -Name "pipeline_state"
        if (-not $pipelineState) {
            $status = Read-SummaryField -Lines $lines -Name "status"
            if ($status) {
                $pipelineState = ($status -eq "SUCCESS") ? "finished" : "failed"
            }
        }
        $buildState = Read-SummaryField -Lines $lines -Name "build_state"
        $runState = Read-SummaryField -Lines $lines -Name "run_state"
        $scenarioId = Read-SummaryField -Lines $lines -Name "scenario_id"
        $buildId = Read-SummaryField -Lines $lines -Name "build_id"
        $workflowState = Read-SummaryField -Lines $lines -Name "workflow_state"
        Write-Host ("{0}: pipeline={1} build={2} run={3} workflow={4} scenario={5} build_id={6}" -f $title, $pipelineState, $buildState, $runState, $workflowState, $scenarioId, $buildId)
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

function Show-SshHealth {
    if (-not $UseSsh) { return }
    Write-Section "Buildbox SSH Health"
    $sshExe = $SshExe
    if ([string]::IsNullOrWhiteSpace($sshExe)) {
        $cmd = Get-Command ssh -ErrorAction SilentlyContinue
        if ($cmd) { $sshExe = $cmd.Source }
        else {
            $fallback = Join-Path $env:WINDIR "System32\\OpenSSH\\ssh.exe"
            if (Test-Path $fallback) { $sshExe = $fallback }
        }
    }
    if ([string]::IsNullOrWhiteSpace($sshExe) -or -not (Test-Path $sshExe)) {
        Write-Host "ssh health failed: ssh.exe not found (set -SshExe or ensure OpenSSH is installed)."
        return
    }

    $ssh = @($sshExe,"-i",$SshKey,"-o","IdentitiesOnly=yes","-o","StrictHostKeyChecking=accept-new",("{0}@{1}" -f $SshUser,$SshHost))

    $scriptLines = @()
    $scriptLines += 'hostname'
    $scriptLines += 'whoami'
    $scriptLines += 'Get-PSDrive C | Select Used,Free | Format-List'
    $scriptLines += 'Get-Service sshd, actions.runner.MoniVibe-HeadlessRebuildTool.buildbox | Select Name,Status,StartType | Format-Table -Auto'
    $scriptLines += 'Get-ScheduledTask | Where-Object {$_.TaskName -like ''Buildbox.*''} | Select TaskName,State | Sort TaskName | Format-Table -Auto'

    foreach ($title in $Titles) {
        $jobs = Join-Path $QueueRoot "$title\\queue\\jobs"
        $leases = Join-Path $QueueRoot "$title\\queue\\leases"
        $results = Join-Path $QueueRoot "$title\\queue\\results"
        $artifacts = Join-Path $QueueRoot "$title\\queue\\artifacts"
        $summary = Join-Path $QueueRoot "$title\\queue\\reports\\pipeline_smoke_summary_latest.md"
        $scriptLines += ("Write-Host '--- {0} ---'" -f $title)
        $scriptLines += ('$dirs = @(' + ("'{0}','{1}','{2}','{3}'" -f $jobs,$leases,$results,$artifacts) + ')')
        $scriptLines += 'foreach ($d in $dirs) { if (Test-Path $d) { $count=(Get-ChildItem -Path $d -File | Measure-Object).Count; Write-Host (\"{0}={1}\" -f (Split-Path $d -Leaf), $count) } else { Write-Host (\"{0}=MISSING\" -f (Split-Path $d -Leaf)) } }'
        $scriptLines += ('$summaryPath = "{0}"' -f $summary)
        $scriptLines += '$pipeline=""; $build=""; $run=""; $workflow=""; $scenario=""; $buildId="";'
        $scriptLines += 'if (Test-Path $summaryPath) {'
        $scriptLines += '  $lines = Get-Content -Path $summaryPath'
        $scriptLines += '  foreach ($line in $lines) {'
        $scriptLines += '    if ($line -match "^\\*\\s+pipeline_state:\\s*(.+)$") { $pipeline = $matches[1].Trim() }'
        $scriptLines += '    elseif ($line -match "^\\*\\s+build_state:\\s*(.+)$") { $build = $matches[1].Trim() }'
        $scriptLines += '    elseif ($line -match "^\\*\\s+run_state:\\s*(.+)$") { $run = $matches[1].Trim() }'
        $scriptLines += '    elseif ($line -match "^\\*\\s+workflow_state:\\s*(.+)$") { $workflow = $matches[1].Trim() }'
        $scriptLines += '    elseif ($line -match "^\\*\\s+scenario_id:\\s*(.+)$") { $scenario = $matches[1].Trim() }'
        $scriptLines += '    elseif ($line -match "^\\*\\s+build_id:\\s*(.+)$") { $buildId = $matches[1].Trim() }'
        $scriptLines += '  }'
        $scriptLines += '  if (-not $pipeline) {'
        $scriptLines += '    foreach ($line in $lines) { if ($line -match "^\\*\\s+status:\\s*(.+)$") { $pipeline = ($matches[1].Trim() -eq "SUCCESS") ? "finished" : "failed"; break } }'
        $scriptLines += '  }'
        $scriptLines += '  Write-Host ("pipeline_state={0} build_state={1} run_state={2} workflow_state={3} scenario_id={4} build_id={5}" -f $pipeline,$build,$run,$workflow,$scenario,$buildId)'
        $scriptLines += '} else { Write-Host "pipeline_state=missing" }'
    }

    $remoteScript = $scriptLines -join "`n"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($remoteScript))
    $remote = "powershell -NoProfile -EncodedCommand $encoded"
    try {
        & $ssh $remote
    } catch {
        Write-Host ("ssh health failed: {0}" -f $_.Exception.Message)
    }
}

function Show-LocalQueue {
    Write-Section "Local Queue (if any)"
    foreach ($title in $Titles) {
        $root = Join-Path $QueueRoot "$title\\queue"
        if (-not (Test-Path $root)) {
            Write-Host ("{0}: queue root missing" -f $title)
            continue
        }
        $jobs = Join-Path $root "jobs"
        $leases = Join-Path $root "leases"
        $results = Join-Path $root "results"
        $artifacts = Join-Path $root "artifacts"
        Write-Host ("--- {0} ---" -f $title)
        foreach ($dir in @($jobs,$leases,$results,$artifacts)) {
            if (Test-Path $dir) {
                Write-Host ("{0}={1}" -f (Split-Path $dir -Leaf), (Get-ChildItem -Path $dir -File | Measure-Object).Count)
            } else {
                Write-Host ("{0}=MISSING" -f (Split-Path $dir -Leaf))
            }
        }
    }
}

$iteration = 0
while ($true) {
    $iteration++
    Write-Host ("\n[{0}] buildbox_status_watch" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    Show-GhRuns
    Show-PipelineStatus
    Show-Runner
    Show-LocalQueue
    Show-SshHealth

    if ($Once) { break }
    if ($Loops -gt 0 -and $iteration -ge $Loops) { break }
    Start-Sleep -Seconds $IntervalSec
}
