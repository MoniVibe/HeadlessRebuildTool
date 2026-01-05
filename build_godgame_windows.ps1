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

$actualLogPath = $LogPath
if ($LogPath -like '\\wsl$\*') {
    $tempDir = Join-Path $env:TEMP "tri_build_logs"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    $tempName = [System.IO.Path]::GetFileName($LogPath)
    if ([string]::IsNullOrWhiteSpace($tempName)) {
        $tempName = "godgame_unity.log"
    }
    $actualLogPath = Join-Path $tempDir $tempName
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

$logDir = Split-Path -Parent $actualLogPath
if ($logDir) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
$logHeader = "UNITY_LOG_PLACEHOLDER utc=$([DateTime]::UtcNow.ToString('o')) path=$actualLogPath"
Set-Content -Path $actualLogPath -Value $logHeader -Encoding ASCII

try {
    & $UnityExe -batchmode -nographics -quit `
        -projectPath $projectPath `
        -executeMethod Godgame.Headless.Editor.GodgameHeadlessBuilder.BuildLinuxHeadless `
        -logFile $actualLogPath
} catch {
    Add-Content -Path $actualLogPath -Value ("UNITY_INVOKE_EXCEPTION: " + $_.Exception.Message) -Encoding ASCII
    exit 5
}

$exitCode = $LASTEXITCODE

if (-not (Test-Path $actualLogPath)) {
    Set-Content -Path $actualLogPath -Value ("UNITY_LOG_MISSING exit_code=" + $exitCode) -Encoding ASCII
} else {
    $len = (Get-Item -Path $actualLogPath).Length
    if ($len -lt 64) {
        Add-Content -Path $actualLogPath -Value ("UNITY_LOG_EMPTY exit_code=" + $exitCode) -Encoding ASCII
    }
}

if ($actualLogPath -ne $LogPath) {
    try {
        $destDir = Split-Path -Parent $LogPath
        if ($destDir) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        if (Test-Path $actualLogPath) {
            Copy-Item -Path $actualLogPath -Destination $LogPath -Force
        }
    } catch {
        Write-Warning ("LOG_COPY_FAILED: {0}" -f $_.Exception.Message)
    }
}

$licenseToken = "[Licensing::Module] Error: Access token is unavailable; failed to update"
$licenseError = $false
$licensePath = if (Test-Path $actualLogPath) { $actualLogPath } else { $LogPath }
if (Test-Path $licensePath) {
    $licenseError = Select-String -Path $licensePath -SimpleMatch -Pattern $licenseToken -Quiet
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
