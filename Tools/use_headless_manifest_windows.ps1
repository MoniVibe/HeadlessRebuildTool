[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectPath,
    [switch]$Restore
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
if (-not (Test-Path $manifest)) {
    Write-Error "Missing manifest.json (cannot backup): $manifest"
    exit 2
}
if (-not (Test-Path $lock)) {
    Write-Error "Missing packages-lock.json (cannot backup): $lock"
    exit 2
}

$projectName = Split-Path -Leaf $ProjectPath
$triRoot = Split-Path -Parent $ProjectPath
$backupDir = Join-Path $triRoot (Join-Path ".tri\\manifest_backups" $projectName)
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

$manifestBackup = Join-Path $backupDir "manifest.json"
$lockBackup = Join-Path $backupDir "packages-lock.json"

function Disable-PackageDir {
    param([string]$DirName)
    $src = Join-Path $packagesDir $DirName
    $dst = Join-Path $packagesDir ($DirName + ".disabled")
    if (Test-Path $src) {
        if (Test-Path $dst) {
            Remove-Item -Path $dst -Recurse -Force -ErrorAction SilentlyContinue
        }
        Rename-Item -Path $src -NewName ($DirName + ".disabled") -ErrorAction Stop
    }
}

function Enable-PackageDir {
    param([string]$DirName)
    $src = Join-Path $packagesDir ($DirName + ".disabled")
    $dst = Join-Path $packagesDir $DirName
    if (Test-Path $src) {
        if (Test-Path $dst) {
            Remove-Item -Path $dst -Recurse -Force -ErrorAction SilentlyContinue
        }
        Rename-Item -Path $src -NewName $DirName -ErrorAction Stop
    }
}

if ($Restore) {
    if (Test-Path $manifestBackup) {
        Copy-Item -Path $manifestBackup -Destination $manifest -Force
    }
    if (Test-Path $lockBackup) {
        Copy-Item -Path $lockBackup -Destination $lock -Force
    }

    Enable-PackageDir "Coplay"
    Enable-PackageDir "com.coplaydev.coplay"

    Write-Output "HEADLESS_MANIFEST_RESTORED project=$projectName"
    exit 0
}

Copy-Item -Path $manifest -Destination $manifestBackup -Force
Copy-Item -Path $lock -Destination $lockBackup -Force

$manifestMatches = $false
$lockMatches = $false
try {
    $manifestMatches = (Get-FileHash -Path $manifest).Hash -eq (Get-FileHash -Path $manifestHeadless).Hash
    $lockMatches = (Get-FileHash -Path $lock).Hash -eq (Get-FileHash -Path $lockHeadless).Hash
} catch {
    $manifestMatches = $false
    $lockMatches = $false
}

$backupMissing = -not (Test-Path $manifestBackup) -or -not (Test-Path $lockBackup)
if ($backupMissing -or (-not $manifestMatches) -or (-not $lockMatches)) {
    Copy-Item -Path $manifest -Destination $manifestBackup -Force
    Copy-Item -Path $lock -Destination $lockBackup -Force
}

if (-not $manifestMatches) {
    Copy-Item -Path $manifestHeadless -Destination $manifest -Force
}
if (-not $lockMatches) {
    Copy-Item -Path $lockHeadless -Destination $lock -Force
}

Disable-PackageDir "Coplay"
Disable-PackageDir "com.coplaydev.coplay"

$manifestObj = Get-Content -Path $manifest -Raw | ConvertFrom-Json
$depNames = @()
if ($manifestObj -and $manifestObj.dependencies) {
    $depNames = @($manifestObj.dependencies.PSObject.Properties.Name)
}
if ($depNames -contains "com.coplaydev.coplay") {
    throw "COPLAY_STILL_IN_MANIFEST: headless manifest swap failed for $projectName"
}

Write-Output "HEADLESS_MANIFEST_APPLIED project=$projectName"
exit 0
