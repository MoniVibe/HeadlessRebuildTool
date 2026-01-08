[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RepoPath,

    [Parameter(Mandatory = $true)]
    [string]$AgentId,

    [Parameter(Mandatory = $true)]
    [string]$TaskId,

    [string]$SessionId,
    [switch]$CheckUnityBuildLock,
    [switch]$CreateUnityBuildLock,
    [switch]$RemoveUnityBuildLock,
    [string]$UnityBuildLockPath
)

$ErrorActionPreference = "Stop"

function Resolve-RepoRoot {
    param([string]$Path)
    try {
        $root = (& git -C $Path rev-parse --show-toplevel).Trim()
        if ([string]::IsNullOrWhiteSpace($root)) {
            return $null
        }
        return $root
    } catch {
        return $null
    }
}

function Resolve-SessionId {
    param([string]$SessionId)
    if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
        return $SessionId
    }
    if (-not [string]::IsNullOrWhiteSpace($env:SESSION_ID)) {
        return $env:SESSION_ID
    }
    return $null
}

function Resolve-SessionStamp {
    param([string]$SessionId)
    $match = [regex]::Match($SessionId, "session_\d{8}")
    if (-not $match.Success) {
        return $null
    }
    return $match.Value
}

function Normalize-PathSegment {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return "unknown"
    }
    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $escaped = [Regex]::Escape(-join $invalid)
    return ($Value -replace "[$escaped]", "_")
}

function Normalize-BranchSegment {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return "unknown"
    }
    $clean = $Value -replace "[^A-Za-z0-9._-]", "_"
    $clean = $clean.Trim("_")
    if ([string]::IsNullOrWhiteSpace($clean)) {
        return "unknown"
    }
    return $clean.ToLowerInvariant()
}

function Resolve-UnityBuildLockPath {
    param([string]$RepoRoot, [string]$OverridePath)
    if (-not [string]::IsNullOrWhiteSpace($OverridePath)) {
        return $OverridePath
    }
    return (Join-Path $RepoRoot "unity_build.lock")
}

function Test-UnityBuildLock {
    param([string]$LockPath)
    return (Test-Path $LockPath)
}

function New-UnityBuildLock {
    param([string]$LockPath, [string]$AgentId, [string]$TaskId)
    if (Test-Path $LockPath) {
        Write-Error ("UNITY_BUILD_LOCK_EXISTS: " + $LockPath)
        exit 3
    }
    $payload = @(
        "agent=$AgentId",
        "task=$TaskId",
        "utc=$([DateTime]::UtcNow.ToString('o'))"
    )
    Set-Content -Path $LockPath -Value $payload -Encoding ASCII
}

function Remove-UnityBuildLock {
    param([string]$LockPath)
    if (Test-Path $LockPath) {
        Remove-Item -Path $LockPath -Force
    }
}

if ([string]::IsNullOrWhiteSpace($RepoPath)) {
    Write-Error "REPO_PATH_MISSING: pass -RepoPath."
    exit 2
}
if ([string]::IsNullOrWhiteSpace($AgentId)) {
    Write-Error "AGENT_ID_MISSING: pass -AgentId."
    exit 2
}
if ([string]::IsNullOrWhiteSpace($TaskId)) {
    Write-Error "TASK_ID_MISSING: pass -TaskId."
    exit 2
}

$repoRoot = Resolve-RepoRoot -Path $RepoPath
if ([string]::IsNullOrWhiteSpace($repoRoot)) {
    Write-Error ("REPO_NOT_FOUND: " + $RepoPath)
    exit 2
}

$sessionId = Resolve-SessionId -SessionId $SessionId
if ([string]::IsNullOrWhiteSpace($sessionId)) {
    Write-Error "SESSION_ID_MISSING: pass -SessionId or set SESSION_ID."
    exit 2
}

$sessionStamp = Resolve-SessionStamp -SessionId $sessionId
if ([string]::IsNullOrWhiteSpace($sessionStamp)) {
    Write-Error ("SESSION_ID_INVALID: expected session_YYYYMMDD in " + $sessionId)
    exit 2
}

$repoNameRaw = Split-Path -Leaf $repoRoot
$repoSegment = Normalize-PathSegment -Value $repoNameRaw
$agentSegment = Normalize-PathSegment -Value $AgentId
$taskSegment = Normalize-PathSegment -Value $TaskId

$repoBranch = Normalize-BranchSegment -Value $repoNameRaw
$taskBranch = Normalize-BranchSegment -Value $TaskId
$agentBranch = Normalize-BranchSegment -Value $AgentId
$branchName = ("workblock/{0}_{1}_{2}_{3}" -f $sessionStamp, $repoBranch, $taskBranch, $agentBranch)

$worktreeRoot = "C:\\polish\\dev\\worktrees"
$worktreePath = Join-Path $worktreeRoot (Join-Path $repoSegment (Join-Path $sessionId (Join-Path $agentSegment $taskSegment)))

$lockPath = Resolve-UnityBuildLockPath -RepoRoot $repoRoot -OverridePath $UnityBuildLockPath
if ($CheckUnityBuildLock) {
    $present = Test-UnityBuildLock -LockPath $lockPath
    $flag = if ($present) { 1 } else { 0 }
    Write-Output ("UNITY_BUILD_LOCK_PRESENT=" + $flag + " path=" + $lockPath)
}
if ($CreateUnityBuildLock) {
    New-UnityBuildLock -LockPath $lockPath -AgentId $AgentId -TaskId $TaskId
    Write-Output ("UNITY_BUILD_LOCK_CREATED path=" + $lockPath)
}
if ($RemoveUnityBuildLock) {
    Remove-UnityBuildLock -LockPath $lockPath
    Write-Output ("UNITY_BUILD_LOCK_REMOVED path=" + $lockPath)
}

if (Test-Path $worktreePath) {
    Write-Error ("WORKTREE_PATH_EXISTS: " + $worktreePath)
    exit 3
}

$worktreeParent = Split-Path -Parent $worktreePath
New-Item -ItemType Directory -Path $worktreeParent -Force | Out-Null

& git -C $repoRoot show-ref --verify --quiet ("refs/heads/" + $branchName)
if ($LASTEXITCODE -eq 0) {
    Write-Error ("BRANCH_EXISTS: " + $branchName)
    exit 3
}

& git -C $repoRoot worktree add -b $branchName $worktreePath

Write-Output ("WORKTREE_PATH=" + $worktreePath)
Write-Output ("BRANCH=" + $branchName)
