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
    "com.coplaydev.coplay",
    "com.coplaydev.unity-mcp"
)

$removedVisualScripting = $false

foreach ($pkg in $editorOnlyPackages) {
    if ($deps.PSObject.Properties.Name -contains $pkg) {
        $deps.PSObject.Properties.Remove($pkg)
        $overrides.Add("remove $pkg")
        if ($pkg -like "com.unity.visualscripting*") {
            $removedVisualScripting = $true
        }
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

    try {
        $lockObj = Get-Content -Path $lockHeadlessPath -Raw | ConvertFrom-Json
        if ($lockObj -and $lockObj.dependencies) {
            foreach ($pkg in $editorOnlyPackages) {
                if ($lockObj.dependencies.PSObject.Properties.Name -contains $pkg) {
                    $lockObj.dependencies.PSObject.Properties.Remove($pkg)
                }
            }

            $lockJson = $lockObj | ConvertTo-Json -Depth 100
            Set-Content -Path $lockHeadlessPath -Value $lockJson -Encoding ascii
        }
    }
    catch {
        Write-Warning ("Failed to prune headless lock packages: {0}" -f $_.Exception.Message)
    }
}

if ($removedVisualScripting) {
    $vsGeneratedDir = Join-Path $ProjectPath "Assets\\Unity.VisualScripting.Generated"
    $vsGeneratedMeta = $vsGeneratedDir + ".meta"
    if (Test-Path $vsGeneratedDir) {
        Remove-Item -Path $vsGeneratedDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $vsGeneratedMeta) {
        Remove-Item -Path $vsGeneratedMeta -Force -ErrorAction SilentlyContinue
    }
}

$overrideText = if ($overrides.Count -gt 0) { $overrides -join "; " } else { "none" }
Write-Output ("HEADLESS_MANIFEST_SYNCED overrides={0}" -f $overrideText)
exit 0
