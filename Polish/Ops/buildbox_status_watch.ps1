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
    $ssh = @("ssh","-i",$SshKey,"-o","IdentitiesOnly=yes","-o","StrictHostKeyChecking=accept-new",("{0}@{1}" -f $SshUser,$SshHost))

    $script = @()
    $script += 'hostname'
    $script += 'whoami'
    $script += 'powershell -NoProfile -Command "Get-PSDrive C | Select Used,Free | Format-List"'
    $script += 'powershell -NoProfile -Command "Get-Service sshd, actions.runner.MoniVibe-HeadlessRebuildTool.buildbox | Select Name,Status,StartType | Format-Table -Auto"'
    $script += 'powershell -NoProfile -Command "Get-ScheduledTask | Where-Object {$_.TaskName -like ''Buildbox.*''} | Select TaskName,State | Sort TaskName | Format-Table -Auto"'

    foreach ($title in $Titles) {
        $jobs = Join-Path $QueueRoot "$title\\queue\\jobs"
        $leases = Join-Path $QueueRoot "$title\\queue\\leases"
        $results = Join-Path $QueueRoot "$title\\queue\\results"
        $artifacts = Join-Path $QueueRoot "$title\\queue\\artifacts"
        $script += ('powershell -NoProfile -Command "{0}"' -f (
            "Write-Host '--- {0} ---'; " +
            "@(\"$jobs\",\"$leases\",\"$results\",\"$artifacts\") | ForEach-Object { if (Test-Path $_) { '{0}=' -f (Split-Path $_ -Leaf); (Get-ChildItem -Path $_ -File | Measure-Object).Count } else { '{0}=MISSING' -f (Split-Path $_ -Leaf) } }" -f $title))
    }

    $remote = $script -join '; '
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
    Show-Runner
    Show-LocalQueue
    Show-SshHealth

    if ($Once) { break }
    if ($Loops -gt 0 -and $iteration -ge $Loops) { break }
    Start-Sleep -Seconds $IntervalSec
}
