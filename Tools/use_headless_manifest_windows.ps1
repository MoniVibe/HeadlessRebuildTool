[CmdletBinding()]
param(
    [string]$ProjectPath
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($ProjectPath)) {
    Write-Error "ProjectPath is required."
    exit 2
}

$packagesDir = Join-Path $ProjectPath "Packages"
if (-not (Test-Path $packagesDir)) {
    Write-Error "Packages dir not found: $packagesDir"
    exit 2
}

$manifest = Join-Path $packagesDir "manifest.json"
$lock = Join-Path $packagesDir "packages-lock.json"
$manifestHeadless = Join-Path $packagesDir "manifest.headless.json"
$lockHeadless = Join-Path $packagesDir "packages-lock.headless.json"

if (-not (Test-Path $manifestHeadless)) {
    Write-Error "Missing headless manifest: $manifestHeadless"
    exit 2
}
if (-not (Test-Path $lockHeadless)) {
    Write-Error "Missing headless lock: $lockHeadless"
    exit 2
}

if (Test-Path $manifest) {
    Copy-Item -Path $manifest -Destination ($manifest + ".bak") -Force
}
if (Test-Path $lock) {
    Copy-Item -Path $lock -Destination ($lock + ".bak") -Force
}

Copy-Item -Path $manifestHeadless -Destination $manifest -Force
Copy-Item -Path $lockHeadless -Destination $lock -Force

$coplay = Join-Path $packagesDir "Coplay"
$coplayDisabled = Join-Path $packagesDir "Coplay.disabled"
if (Test-Path $coplay) {
    if (Test-Path $coplayDisabled) {
        Remove-Item -Path $coplayDisabled -Recurse -Force -ErrorAction SilentlyContinue
    }
    Rename-Item -Path $coplay -NewName "Coplay.disabled" -ErrorAction SilentlyContinue
}

exit 0
