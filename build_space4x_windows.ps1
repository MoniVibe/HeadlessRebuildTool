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

function Stop-StrayUnityProcesses {
    param(
        [string]$ProjectPath,
        [string]$LogPath
    )
    $killStrays = $true
    if (-not [string]::IsNullOrWhiteSpace($env:TRI_KILL_UNITY_STRAYS)) {
        $killStrays = ($env:TRI_KILL_UNITY_STRAYS -eq "1")
    }
    if (-not $killStrays) {
        return
    }
    $projLower = $ProjectPath.ToLowerInvariant()
    $projSlash = $ProjectPath.Replace("\", "/").ToLowerInvariant()
    $killed = 0
    $failed = 0
    $procs = Get-CimInstance Win32_Process | Where-Object { $_.Name -ieq "Unity.exe" }
    foreach ($proc in $procs) {
        $cmd = $proc.CommandLine
        if ([string]::IsNullOrWhiteSpace($cmd)) {
            continue
        }
        $cmdLower = $cmd.ToLowerInvariant()
        if ($cmdLower -like "*$projLower*" -or $cmdLower -like "*$projSlash*") {
            try {
                Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
                $killed++
            } catch {
                $failed++
            }
        }
    }
    if ($killed -gt 0 -or $failed -gt 0) {
        $msg = "UNITY_STRAY_KILL project=$ProjectPath killed=$killed failed=$failed"
        Write-Output $msg
        if ($LogPath) {
            Add-Content -Path $LogPath -Value $msg -Encoding ASCII
        }
    }
    if ($killed -gt 0) {
        Start-Sleep -Seconds 5
    }
}

function Invoke-UnityWithWatchdog {
    param(
        [string]$UnityExe,
        [string]$ProjectPath,
        [string]$ExecuteMethod,
        [string]$LogFile
    )

    $staleMinutes = if ($env:TRI_UNITY_WATCHDOG_MINUTES) { [int]$env:TRI_UNITY_WATCHDOG_MINUTES } else { 10 }
    $pollSeconds = if ($env:TRI_UNITY_WATCHDOG_POLL_SECONDS) { [int]$env:TRI_UNITY_WATCHDOG_POLL_SECONDS } else { 20 }

    $args = @(
        "-batchmode", "-nographics", "-quit",
        "-projectPath", $ProjectPath,
        "-executeMethod", $ExecuteMethod,
        "-logFile", $LogFile
    )

    $proc = Start-Process -FilePath $UnityExe -ArgumentList $args -PassThru -NoNewWindow
    $lastWriteUtc = (Get-Date).ToUniversalTime()
    if (Test-Path $LogFile) {
        $lastWriteUtc = (Get-Item $LogFile).LastWriteTimeUtc
    }

    while (-not $proc.HasExited) {
        Start-Sleep -Seconds $pollSeconds
        $proc.Refresh()

        if (Test-Path $LogFile) {
            $currentWriteUtc = (Get-Item $LogFile).LastWriteTimeUtc
            if ($currentWriteUtc -gt $lastWriteUtc) {
                $lastWriteUtc = $currentWriteUtc
                continue
            }
        }

        $idleSeconds = ([DateTime]::UtcNow - $lastWriteUtc).TotalSeconds
        if ($idleSeconds -ge ($staleMinutes * 60)) {
            $msg = "UNITY_WATCHDOG_STALE minutes=$staleMinutes idleSeconds=$([int]$idleSeconds) pid=$($proc.Id) log=$LogFile"
            Add-Content -Path $LogFile -Value $msg -Encoding ASCII

            try { & taskkill /PID $proc.Id /T /F | Out-Null } catch { }
            Start-Sleep -Seconds 3
            try { Get-Process -Name bee_backend -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch { }

            return 124
        }
    }

    $proc.WaitForExit()
    return $proc.ExitCode
}

function Clear-UnityBeeCaches {
    param(
        [string]$ProjectPath,
        [string]$LogPath
    )
    $targets = @(
        (Join-Path $ProjectPath "Library\\Bee"),
        (Join-Path $ProjectPath "Library\\BeeBackend"),
        (Join-Path $ProjectPath "Library\\BuildCache"),
        (Join-Path $ProjectPath "Temp")
    )
    foreach ($t in $targets) {
        try {
            if (Test-Path $t) {
                Add-Content -Path $LogPath -Value ("CLEAN_DELETE " + $t) -Encoding ASCII
                Remove-Item -Path $t -Recurse -Force -ErrorAction SilentlyContinue
            }
        } catch { }
    }
}

$actualLogPath = $LogPath
if ($LogPath -like '\\wsl$\*') {
    $tempDir = Join-Path $env:TEMP "tri_build_logs"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    $tempName = [System.IO.Path]::GetFileName($LogPath)
    if ([string]::IsNullOrWhiteSpace($tempName)) {
        $tempName = "space4x_unity.log"
    }
    $actualLogPath = Join-Path $tempDir $tempName
}

$projectPath = Join-Path $TriRoot "space4x"
if (-not (Test-Path $projectPath)) {
    Write-Error "Space4X project not found: $projectPath"
    exit 2
}
if (-not (Test-Path $UnityExe)) {
    Write-Error "Unity editor not found: $UnityExe"
    exit 2
}

try {
    $logDir = Split-Path -Parent $actualLogPath
    if ($logDir) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    $logHeader = "UNITY_LOG_PLACEHOLDER utc=$([DateTime]::UtcNow.ToString('o')) path=$actualLogPath"
    Set-Content -Path $actualLogPath -Value $logHeader -Encoding ASCII
} catch {
    Write-Output ("LOG_PRECREATE_FAILED: " + $_.Exception.Message)
    exit 6
}

Stop-StrayUnityProcesses -ProjectPath $projectPath -LogPath $actualLogPath

$scriptDir = Split-Path -Parent $PSCommandPath
$swapScript = Join-Path $scriptDir "Tools\\use_headless_manifest_windows.ps1"
if (-not (Test-Path $swapScript)) {
    Add-Content -Path $actualLogPath -Value ("HEADLESS_SWAP_SCRIPT_MISSING: " + $swapScript) -Encoding ASCII
    exit 7
}

$swapApplied = $false
$exitCode = 1
try {
    & $swapScript -ProjectPath $projectPath | Out-Null
    $swapApplied = $true

    try { Get-Process -Name bee_backend -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch { }

    $exitCode = Invoke-UnityWithWatchdog `
        -UnityExe $UnityExe `
        -ProjectPath $projectPath `
        -ExecuteMethod "Space4X.Headless.Editor.Space4XHeadlessBuilder.BuildLinuxHeadless" `
        -LogFile $actualLogPath

    $allowRetry = ($env:TRI_UNITY_WATCHDOG_RETRY_CLEAN -ne "0")
    if ($exitCode -eq 124 -and $allowRetry) {
        Add-Content -Path $actualLogPath -Value "UNITY_WATCHDOG_RETRY_CLEAN=1" -Encoding ASCII
        Clear-UnityBeeCaches -ProjectPath $projectPath -LogPath $actualLogPath
        $exitCode = Invoke-UnityWithWatchdog `
            -UnityExe $UnityExe `
            -ProjectPath $projectPath `
            -ExecuteMethod "Space4X.Headless.Editor.Space4XHeadlessBuilder.BuildLinuxHeadless" `
            -LogFile $actualLogPath
    }
} catch {
    Add-Content -Path $actualLogPath -Value ("BUILD_PREP_EXCEPTION: " + $_.Exception.Message) -Encoding ASCII
    exit 8
} finally {
    if ($swapApplied) {
        try { & $swapScript -ProjectPath $projectPath -Restore | Out-Null } catch { }
    }
}

if (-not (Test-Path $actualLogPath)) {
    Write-Output ("UNITY_LOG_MISSING: " + $actualLogPath)
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
    $enforceLicense = ($env:TRI_ENFORCE_LICENSE_ERROR -eq "1")
    if ($enforceLicense) {
        Write-Error "UNITY_LICENSE_ERROR"
        exit 3
    }
    Write-Warning "UNITY_LICENSE_WARNING: token update failed; continuing."
}

if ($exitCode -eq 0) {
    $buildDir = Join-Path $TriRoot "space4x\\Builds\\Space4X_headless\\Linux"
    $exePath = Join-Path $buildDir "Space4X_Headless.x86_64"
    if (-not (Test-Path $buildDir) -or -not (Test-Path $exePath)) {
        Write-Error ("BUILD_ARTIFACTS_MISSING: {0}" -f $exePath)
        exit 4
    }
    exit 0
}

exit $exitCode
