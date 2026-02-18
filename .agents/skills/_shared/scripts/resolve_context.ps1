[CmdletBinding()]
param(
    [string]$QueueRoot = "",
    [ValidateSet("space4x", "godgame", "both", "")]
    [string]$Title = "",
    [string]$UnityExe = "",
    [switch]$RequireQueueRoot,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-RepoRoot {
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $resolved = Resolve-Path (Join-Path $scriptDir "..\..\..\..")
    if ($resolved -is [string]) { return $resolved }
    return @($resolved)[0].Path
}

function Convert-ToWslPath {
    param([string]$PathValue)
    if ([string]::IsNullOrWhiteSpace($PathValue)) { return "" }
    $full = [System.IO.Path]::GetFullPath($PathValue)
    $match = [regex]::Match($full, '^([A-Za-z]):\\(.*)$')
    if ($match.Success) {
        $drive = $match.Groups[1].Value.ToLowerInvariant()
        $rest = $match.Groups[2].Value -replace '\\', '/'
        return "/mnt/$drive/$rest"
    }
    return ($full -replace '\\', '/')
}

function Resolve-TriRoot {
    if ($env:TRI_ROOT -and (Test-Path $env:TRI_ROOT)) { return (Resolve-Path $env:TRI_ROOT).Path }
    $repoRoot = Resolve-RepoRoot
    $parent = Split-Path -Parent $repoRoot
    if (Test-Path (Join-Path $parent "puredots")) { return $parent }
    return ""
}

$repoRoot = Resolve-RepoRoot
$triRoot = Resolve-TriRoot
$stateDir = if ($env:TRI_STATE_DIR) { $env:TRI_STATE_DIR } elseif ($triRoot) { Join-Path $triRoot ".tri\state" } else { "" }

$resolvedQueue = ""
if (-not [string]::IsNullOrWhiteSpace($QueueRoot)) {
    $resolvedQueue = [System.IO.Path]::GetFullPath($QueueRoot)
}
elseif ($Title -eq "space4x") {
    $resolvedQueue = "C:\polish\anviloop\space4x\queue"
}
elseif ($Title -eq "godgame") {
    $resolvedQueue = "C:\polish\anviloop\godgame\queue"
}

if ($RequireQueueRoot -and [string]::IsNullOrWhiteSpace($resolvedQueue)) {
    throw "QueueRoot is required for this operation."
}

$resolvedUnity = $UnityExe
if ([string]::IsNullOrWhiteSpace($resolvedUnity)) { $resolvedUnity = $env:UNITY_EXE }
if ([string]::IsNullOrWhiteSpace($resolvedUnity)) { $resolvedUnity = $env:UNITY_WIN }

$ctx = [ordered]@{
    repo_root = $repoRoot
    tri_root = $triRoot
    tri_state_dir = $stateDir
    title = $Title
    queue_root = $resolvedQueue
    queue_root_wsl = if ($resolvedQueue) { Convert-ToWslPath -PathValue $resolvedQueue } else { "" }
    unity_exe = $resolvedUnity
    host = [ordered]@{
        os = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
        machine = $env:COMPUTERNAME
        is_wsl = [bool]($env:WSL_DISTRO_NAME -or $env:WSL_INTEROP)
        pwsh_version = $PSVersionTable.PSVersion.ToString()
    }
}

if ($AsJson) {
    $ctx | ConvertTo-Json -Depth 6
}
else {
    $ctx
}
