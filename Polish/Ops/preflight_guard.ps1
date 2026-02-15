param(
    [string]$CmdDir = "C:\\polish\\anviloop\\bin",
    [string]$ExpectedToolPathWsl = "/mnt/c/dev/Tri/Tools/HeadlessRebuildTool",
    [string]$ExpectedTelemetryFlag = "--telemetry-max-bytes",
    [string]$ExpectedUnityExeLeaf = "Unity.exe"
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$errors = @()

function Test-PathSafe {
    param([string]$PathValue)
    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return $false
    }
    return (Test-Path -LiteralPath $PathValue)
}

$triRoot = $env:TRI_ROOT
$unityExe = $env:UNITY_EXE
$unityLeaf = if ([string]::IsNullOrWhiteSpace($unityExe)) { "" } else { Split-Path -Path $unityExe -Leaf }
$unityExt = if ([string]::IsNullOrWhiteSpace($unityExe)) { "" } else { [System.IO.Path]::GetExtension($unityExe) }
$triRootExists = Test-PathSafe -PathValue $triRoot
$unityExists = Test-PathSafe -PathValue $unityExe

Write-Host ("preflight_guard: tri_root={0}" -f $(if ($triRoot) { $triRoot } else { "<missing>" }))
Write-Host ("preflight_guard: tri_root_exists={0}" -f $triRootExists)
Write-Host ("preflight_guard: unity_exe={0}" -f $(if ($unityExe) { $unityExe } else { "<missing>" }))
Write-Host ("preflight_guard: unity_exe_leaf={0}" -f $(if ($unityLeaf) { $unityLeaf } else { "<missing>" }))
Write-Host ("preflight_guard: unity_exe_exists={0}" -f $unityExists)

if ([string]::IsNullOrWhiteSpace($unityExe)) {
    $errors += "missing_unity_exe_env:UNITY_EXE"
} else {
    if ($unityLeaf -imatch '^wsl(\.exe)?$') {
        $errors += "unity_exe_invalid_wrapper:wsl"
    }
    if ($unityExt -ine '.exe') {
        $errors += "unity_exe_not_exe:$unityExe"
    }
    if ($unityLeaf -ine $ExpectedUnityExeLeaf) {
        $errors += "unity_exe_leaf_mismatch:$unityLeaf"
    }
    if ($unityLeaf -imatch '\.cmd$' -or $unityExe -imatch '\.cmd(\.exe)?$') {
        $errors += "unity_exe_invalid_wrapper:cmd"
    }
    if (-not $unityExists) {
        $errors += "unity_exe_missing:$unityExe"
    }
}

$wslExe = Get-Command wsl.exe -ErrorAction SilentlyContinue
$wslExePath = if ($wslExe) { $wslExe.Source } else { "" }
$wslDistroList = @()
$wslDefaultDistro = ""
if ($wslExe) {
    try {
        $wslDistroList = @(& wsl.exe -l -q 2>$null | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    } catch {
        $wslDistroList = @()
    }

    try {
        $defaultLine = & wsl.exe -l -v 2>$null | Where-Object { $_ -match '^\*' } | Select-Object -First 1
        if ($defaultLine) {
            $parts = ($defaultLine -replace '^\*\s*', '').Trim() -split '\s+'
            if ($parts.Length -gt 0) { $wslDefaultDistro = $parts[0] }
        }
    } catch {
        $wslDefaultDistro = ""
    }
}

Write-Host ("preflight_guard: wsl_exe={0}" -f $(if ($wslExePath) { $wslExePath } else { "<missing>" }))
Write-Host ("preflight_guard: wsl_distro_count={0}" -f $wslDistroList.Count)
Write-Host ("preflight_guard: wsl_default_distro={0}" -f $(if ($wslDefaultDistro) { $wslDefaultDistro } else { "<unknown>" }))

if (-not $wslExe) {
    $errors += "wsl_missing:wsl.exe"
} elseif ($wslDistroList.Count -eq 0) {
    $errors += "wsl_no_distros"
}

if ([string]::IsNullOrWhiteSpace($triRoot)) {
    $errors += "missing_tri_root_env:TRI_ROOT"
} elseif (-not $triRootExists) {
    $errors += "tri_root_missing:$triRoot"
}

$files = @("wsl_runner_space4x.cmd", "wsl_runner_godgame.cmd")
foreach ($file in $files) {
    $path = Join-Path $CmdDir $file
    if (-not (Test-Path $path)) {
        $errors += "missing_cmd:$path"
        continue
    }
    $text = Get-Content -Path $path -Raw
    if ($text -notmatch [regex]::Escape($ExpectedToolPathWsl)) {
        $errors += "bad_tool_path:$file"
    }
    if ($text -notmatch [regex]::Escape($ExpectedTelemetryFlag)) {
        $errors += "missing_telemetry_flag:$file"
    }
}

if ($errors.Count -gt 0) {
    Write-Host "preflight_guard: FAIL"
    foreach ($err in $errors) { Write-Host "preflight_guard: $err" }
    exit 2
}

Write-Host "preflight_guard: PASS"
