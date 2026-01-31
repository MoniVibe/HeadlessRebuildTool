param(
    [string]$CmdDir = "C:\\polish\\anviloop\\bin",
    [string]$ExpectedToolPathWsl = "/mnt/c/dev/Tri/Tools/HeadlessRebuildTool",
    [string]$ExpectedTelemetryFlag = "--telemetry-max-bytes"
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$errors = @()
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
