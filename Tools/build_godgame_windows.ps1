[CmdletBinding()]
param(
    [string]$TriRoot,
    [string]$LogPath,
    [string]$UnityExe
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($UnityExe)) {
    $UnityExe = $env:TRI_UNITY_EXE
    if ([string]::IsNullOrWhiteSpace($UnityExe)) {
        $UnityExe = $env:UNITY_WIN
    }
}

if ([string]::IsNullOrWhiteSpace($UnityExe)) {
    Write-Error "UNITY_EXE_MISSING: set -UnityExe, TRI_UNITY_EXE, or UNITY_WIN."
    exit 2
}
if ([string]::IsNullOrWhiteSpace($TriRoot)) {
    Write-Error "TRI_ROOT_MISSING: pass -TriRoot."
    exit 2
}
if ([string]::IsNullOrWhiteSpace($LogPath)) {
    Write-Error "LOG_PATH_MISSING: pass -LogPath."
    exit 2
}

$projectPath = Join-Path $TriRoot "godgame"
if (-not (Test-Path $projectPath)) {
    Write-Error "Godgame project not found: $projectPath"
    exit 2
}
if (-not (Test-Path $UnityExe)) {
    Write-Error "Unity editor not found: $UnityExe"
    exit 2
}

& $UnityExe -batchmode -nographics -quit `
    -projectPath $projectPath `
    -executeMethod Godgame.Headless.Editor.GodgameHeadlessBuilder.BuildLinuxHeadless `
    -logFile $LogPath

$exitCode = $LASTEXITCODE

$licenseToken = "[Licensing::Module] Error: Access token is unavailable; failed to update"
$licenseError = $false
if (Test-Path $LogPath) {
    $licenseError = Select-String -Path $LogPath -SimpleMatch -Pattern $licenseToken -Quiet
}
if ($licenseError) {
    Write-Error "UNITY_LICENSE_ERROR"
    exit 3
}

if ($exitCode -eq 0) {
    $buildDir = Join-Path $TriRoot "godgame\\Builds\\Godgame_headless\\Linux"
    $exePath = Join-Path $buildDir "Godgame_Headless.x86_64"
    if (-not (Test-Path $buildDir) -or -not (Test-Path $exePath)) {
        Write-Error ("BUILD_ARTIFACTS_MISSING: {0}" -f $exePath)
        exit 4
    }
    exit 0
}

exit $exitCode
