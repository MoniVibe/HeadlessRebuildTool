[CmdletBinding()]
param(
    [string]$Repo = 'MoniVibe/HeadlessRebuildTool',
    [string]$Workflow = 'buildbox_on_demand.yml',
    [string]$SshHost = '',
    [string]$SshUser = '',
    [string]$SshKey = '',
    [string]$ToolsRepoPath = 'C:\dev\Tri\Tools\HeadlessRebuildTool'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Require-Gh {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw "GitHub CLI (gh) not found in PATH."
    }
}

function Invoke-GhJson {
    param([string[]]$GhArgs)
    $raw = & gh @GhArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ("gh failed: {0}" -f ($raw -join "`n"))
    }
    if (-not $raw) { return $null }
    $joined = ($raw -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($joined)) { return $null }
    $first = $joined.Substring(0, 1)
    if ($first -ne '{' -and $first -ne '[') {
        throw ("gh returned non-json output: {0}" -f $joined)
    }
    return ($joined | ConvertFrom-Json)
}

function Resolve-SshExe {
    $cmd = Get-Command ssh -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $fallback = Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe'
    if (Test-Path $fallback) { return $fallback }
    return $null
}

Require-Gh

$runnersResponse = Invoke-GhJson @('api', ("repos/{0}/actions/runners" -f $Repo))
$runners = @()
if ($runnersResponse -and $runnersResponse.runners) { $runners = $runnersResponse.runners }
Write-Host ("runner_count={0}" -f $runners.Count)
foreach ($runner in $runners) {
    $labels = @()
    if ($runner.labels) { $labels = $runner.labels | ForEach-Object { $_.name } }
    Write-Host ("runner name={0} status={1} labels={2}" -f $runner.name, $runner.status, ($labels -join ','))
}

$runs = Invoke-GhJson @(
    'run', 'list',
    '-R', $Repo,
    '-w', $Workflow,
    '-L', '3',
    '--json', 'databaseId,status,conclusion,createdAt,updatedAt,headBranch,displayTitle,url'
)
if ($runs) {
    $latest = $runs | Sort-Object createdAt -Descending | Select-Object -First 1
    if ($latest) {
        Write-Host ("latest_run id={0} status={1} conclusion={2} branch={3} updated={4}" -f $latest.databaseId, $latest.status, $latest.conclusion, $latest.headBranch, $latest.updatedAt)
        if ($latest.url) { Write-Host ("latest_run_url={0}" -f $latest.url) }
    }
}

$mainSha = $null
try {
    $mainObj = Invoke-GhJson @('api', ("repos/{0}/commits/main" -f $Repo))
    if ($mainObj -and $mainObj.sha) { $mainSha = $mainObj.sha }
} catch {
}
if ($mainSha) { Write-Host ("repo_main_sha={0}" -f $mainSha) }

if (-not [string]::IsNullOrWhiteSpace($SshHost)) {
    $sshExe = Resolve-SshExe
    if (-not $sshExe) {
        Write-Warning "ssh not found; skipping remote tools repo check."
        return
    }
    $target = if ([string]::IsNullOrWhiteSpace($SshUser)) { $SshHost } else { ("{0}@{1}" -f $SshUser, $SshHost) }
    $escapedPath = $ToolsRepoPath -replace "'", "''"
    $remoteCmd = "powershell -NoProfile -Command `"git -C '$escapedPath' rev-parse HEAD`""
    $sshArgs = @()
    if (-not [string]::IsNullOrWhiteSpace($SshKey)) {
        $sshArgs += @('-i', $SshKey)
    }
    $sshArgs += @('-o', 'IdentitiesOnly=yes', '-o', 'StrictHostKeyChecking=accept-new', $target, $remoteCmd)
    $remoteSha = & $sshExe @sshArgs 2>$null
    if ($LASTEXITCODE -eq 0 -and $remoteSha) {
        $remoteSha = $remoteSha.Trim()
        Write-Host ("tools_repo_sha={0}" -f $remoteSha)
        if ($mainSha -and ($remoteSha -ne $mainSha)) {
            Write-Warning ("tools repo is behind main (remote {0} != main {1})" -f $remoteSha, $mainSha)
        }
    } else {
        Write-Warning "remote tools repo check failed."
    }
}
