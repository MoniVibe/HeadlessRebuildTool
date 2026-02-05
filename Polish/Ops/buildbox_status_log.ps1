[CmdletBinding()]
param(
    [string]$Repo = "MoniVibe/HeadlessRebuildTool",
    [string]$Workflow = "buildbox_on_demand.yml",
    [int]$IntervalSec = 30,
    [int]$Limit = 12,
    [switch]$Once,
    [switch]$UseSsh,
    [string]$SshHost = "25.30.14.37",
    [string]$SshUser = "Moni",
    [string]$SshKey = "",
    [string]$StatePath = "",
    [switch]$NoGh
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-StatePath {
    if (-not [string]::IsNullOrWhiteSpace($StatePath)) { return $StatePath }
    $base = if ($env:TEMP) { $env:TEMP } else { $env:LOCALAPPDATA }
    if (-not $base) { $base = "." }
    return (Join-Path $base "buildbox_status_log_state.json")
}

function Load-State {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        return [ordered]@{ runs = @{}; artifacts = @{}; results = @{} }
    }
    try {
        return (Get-Content -Raw -Path $Path | ConvertFrom-Json)
    } catch {
        return [ordered]@{ runs = @{}; artifacts = @{}; results = @{} }
    }
}

function Save-State {
    param([string]$Path, [object]$State)
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    ($State | ConvertTo-Json -Depth 6) | Set-Content -Path $Path -Encoding ascii
}

function Log-Line {
    param([string]$Message)
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host ("[{0}] {1}" -f $stamp, $Message)
}

function Require-Gh {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw "GitHub CLI (gh) not found."
    }
}

function Get-GhRuns {
    param([string]$Repo, [string]$Workflow, [int]$Limit)
    $json = & gh run list -R $Repo --workflow $Workflow --limit $Limit --json databaseId,status,conclusion,createdAt,updatedAt,headBranch,headSha,displayTitle 2>$null
    if (-not $json) { return @() }
    return ($json | ConvertFrom-Json)
}

function Get-RunArtifactTitle {
    param([string]$Repo, [long]$RunId)
    $json = & gh api "/repos/$Repo/actions/runs/$RunId/artifacts" 2>$null
    if (-not $json) { return "" }
    try {
        $artifacts = (ConvertFrom-Json $json).artifacts
    } catch {
        return ""
    }
    foreach ($artifact in $artifacts) {
        if ($artifact.name -match '^buildbox_diag_(space4x|godgame)_') {
            return $Matches[1]
        }
    }
    return ""
}

function Get-SshClientInfo {
    $sshExe = Get-Command ssh -ErrorAction SilentlyContinue
    if (-not $sshExe) {
        $fallback = Join-Path $env:WINDIR "System32\\OpenSSH\\ssh.exe"
        if (Test-Path $fallback) { $sshExe = $fallback }
    } else {
        $sshExe = $sshExe.Source
    }
    if (-not $sshExe) { throw "ssh.exe not found." }
    $keyPath = $SshKey
    if ([string]::IsNullOrWhiteSpace($keyPath)) {
        $keyPath = Join-Path $env:USERPROFILE ".ssh\\buildbox_laptop_ed25519"
    }
    if (-not (Test-Path $keyPath)) { throw "ssh key not found: $keyPath" }
    return [pscustomobject]@{ exe = $sshExe; key = $keyPath }
}

function Invoke-SshJson {
    param([string]$RemoteScript)
    $info = Get-SshClientInfo
    $sshArgs = @(
        "-i", $info.key,
        "-o", "IdentitiesOnly=yes",
        "-o", "StrictHostKeyChecking=accept-new",
        ("{0}@{1}" -f $SshUser, $SshHost)
    )
    $remote = "powershell -NoProfile -Command `"$RemoteScript`""
    $output = & $info.exe @sshArgs $remote
    if (-not $output) { return $null }
    return ($output | ConvertFrom-Json)
}

function Read-DesktopQueue {
    if (-not $UseSsh) { return $null }
    $remoteScript = @'
$queues=@(
  @{name='space4x';path='C:\polish\anviloop\space4x\queue'},
  @{name='godgame';path='C:\polish\anviloop\godgame\queue'}
);
$out=@();
foreach($q in $queues){
  $jobs=Join-Path $q.path 'jobs';
  $results=Join-Path $q.path 'results';
  $latest='';
  if(Test-Path $results){
    $item=Get-ChildItem $results -Filter 'result_*.zip' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1;
    if($item){ $latest=$item.Name }
  }
  $out += [ordered]@{ name=$q.name; jobs=(Test-Path $jobs ? (Get-ChildItem $jobs -File).Count : 0); latest=$latest }
}
[ordered]@{ queues=$out } | ConvertTo-Json -Depth 3
'@
    $remoteScript = ($remoteScript -replace "\r?\n", " ")
    return (Invoke-SshJson -RemoteScript $remoteScript)
}

$stateFile = Resolve-StatePath
$state = Load-State -Path $stateFile
if (-not $state.runs) { $state.runs = @{} }
if (-not $state.artifacts) { $state.artifacts = @{} }
if (-not $state.results) { $state.results = @{} }

if (-not $NoGh) { Require-Gh }

while ($true) {
    if (-not $NoGh) {
        $runs = Get-GhRuns -Repo $Repo -Workflow $Workflow -Limit $Limit
        foreach ($run in $runs) {
            $id = [string]$run.databaseId
            $prev = $null
            if ($state.runs.ContainsKey($id)) { $prev = $state.runs[$id] }
            $status = [string]$run.status
            $conclusion = [string]$run.conclusion
            $head = if ($run.headSha) { $run.headSha.Substring(0, [Math]::Min(8, $run.headSha.Length)) } else { "" }
            $branch = [string]$run.headBranch
            $title = ""

            if (-not $prev) {
                if ($status -eq "queued") { Log-Line ("workflow queued id={0} branch={1} head={2}" -f $id, $branch, $head) }
                elseif ($status -eq "in_progress") { Log-Line ("run started id={0} branch={1} head={2}" -f $id, $branch, $head) }
                elseif ($status -eq "completed") { Log-Line ("workflow completed id={0} result={1} branch={2} head={3}" -f $id, $conclusion, $branch, $head) }
            } else {
                if ($prev.status -ne $status) {
                    if ($status -eq "in_progress") { Log-Line ("run started id={0} branch={1} head={2}" -f $id, $branch, $head) }
                    elseif ($status -eq "completed") { Log-Line ("workflow {0} id={1} branch={2} head={3}" -f $conclusion, $id, $branch, $head) }
                }
            }

            if ($status -eq "completed" -and -not $state.artifacts.ContainsKey($id)) {
                $title = Get-RunArtifactTitle -Repo $Repo -RunId $run.databaseId
                if (-not [string]::IsNullOrWhiteSpace($title)) {
                    Log-Line ("workflow {0} title={1} id={2} branch={3} head={4}" -f $conclusion, $title, $id, $branch, $head)
                }
                $state.artifacts[$id] = $true
            }

            $state.runs[$id] = [ordered]@{
                status = $status
                conclusion = $conclusion
                branch = $branch
                head = $head
            }
        }
    }

    if ($UseSsh) {
        try {
            $queue = Read-DesktopQueue
            if ($queue -and $queue.queues) {
                foreach ($q in $queue.queues) {
                    $key = [string]$q.name
                    $latest = [string]$q.latest
                    $prevLatest = if ($state.results.ContainsKey($key)) { [string]$state.results[$key] } else { "" }
                    if ($latest -and ($latest -ne $prevLatest)) {
                        Log-Line ("result ready title={0} zip={1} jobs={2}" -f $key, $latest, $q.jobs)
                        $state.results[$key] = $latest
                    }
                }
            }
        } catch {
            Log-Line ("ssh check failed: {0}" -f $_.Exception.Message)
        }
    }

    Save-State -Path $stateFile -State $state
    if ($Once) { break }
    Start-Sleep -Seconds $IntervalSec
}
