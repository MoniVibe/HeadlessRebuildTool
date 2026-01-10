[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectPath,
    [string]$EntitiesGraphicsVersion = "1.4.16",
    [switch]$RemoveEntitiesGraphics
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

$manifestPath = Join-Path $packagesDir "manifest.json"
$manifestHeadlessPath = Join-Path $packagesDir "manifest.headless.json"
$lockPath = Join-Path $packagesDir "packages-lock.json"
$lockHeadlessPath = Join-Path $packagesDir "packages-lock.headless.json"

if (-not (Test-Path $manifestPath)) {
    Write-Error "Missing manifest.json: $manifestPath"
    exit 2
}

$manifestObj = Get-Content -Path $manifestPath -Raw | ConvertFrom-Json
if (-not $manifestObj -or -not $manifestObj.dependencies) {
    Write-Error "manifest.json missing dependencies."
    exit 2
}

$overrides = New-Object System.Collections.Generic.List[string]
$deps = $manifestObj.dependencies

if ($RemoveEntitiesGraphics) {
    if ($deps.PSObject.Properties.Name -contains "com.unity.entities.graphics") {
        $deps.PSObject.Properties.Remove("com.unity.entities.graphics")
        $overrides.Add("remove com.unity.entities.graphics")
    }
}
else {
    if ($deps.PSObject.Properties.Name -contains "com.unity.entities.graphics") {
        $deps."com.unity.entities.graphics" = $EntitiesGraphicsVersion
        $overrides.Add("pin com.unity.entities.graphics=$EntitiesGraphicsVersion")
    }
}

$editorOnlyPackages = @(
    "com.unity.visualscripting",
    "com.unity.visualscripting.entities",
    "com.unity.test-framework",
    "com.unity.ide.visualstudio",
    "com.unity.ide.rider",
    "com.unity.collab-proxy",
    "com.coplaydev.coplay"
)

foreach ($pkg in $editorOnlyPackages) {
    if ($deps.PSObject.Properties.Name -contains $pkg) {
        $deps.PSObject.Properties.Remove($pkg)
        $overrides.Add("remove $pkg")
    }
}

$json = $manifestObj | ConvertTo-Json -Depth 100
Set-Content -Path $manifestHeadlessPath -Value $json -Encoding ascii

if (Test-Path $lockPath) {
    Copy-Item -Path $lockPath -Destination $lockHeadlessPath -Force
    if (-not (Test-Path $lockHeadlessPath)) {
        Write-Error "Failed to write headless lock: $lockHeadlessPath"
        exit 2
    }
}

$overrideText = if ($overrides.Count -gt 0) { $overrides -join "; " } else { "none" }
Write-Output ("HEADLESS_MANIFEST_SYNCED overrides={0}" -f $overrideText)
exit 0
