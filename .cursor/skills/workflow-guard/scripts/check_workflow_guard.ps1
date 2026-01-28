[CmdletBinding()]
param(
    [string]$RepoRoot = "C:\Dev\unity_clean\headlessrebuildtool",
    [string]$BuildboxWorkflow = ".github\workflows\buildbox_on_demand.yml",
    [string]$NightlyWorkflow = ".github\workflows\nightly-evals.yml",
    [string]$ExpectedRunnerLabel = "buildbox",
    [string]$ExpectedNightlyLabel = "headless-e2e"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$failed = $false

function Check-File {
    param([string]$Path, [string]$Name)
    if (-not (Test-Path $Path)) {
        Write-Host "FAIL: missing $Name at $Path"
        $script:failed = $true
        return $false
    }
    Write-Host "OK: found $Name"
    return $true
}

function Check-Contains {
    param([string]$Content, [string]$Pattern, [string]$Label, [switch]$Critical)
    if ($Content -match $Pattern) {
        Write-Host "OK: $Label"
        return
    }
    Write-Host "WARN: $Label not found"
    if ($Critical) { $script:failed = $true }
}

$buildboxPath = Join-Path $RepoRoot $BuildboxWorkflow
$nightlyPath = Join-Path $RepoRoot $NightlyWorkflow

if (Check-File -Path $buildboxPath -Name "buildbox_on_demand.yml") {
    $content = Get-Content -Raw -Path $buildboxPath
    Check-Contains -Content $content -Pattern "runs-on:\s*\[.*${ExpectedRunnerLabel}.*\]" -Label "buildbox runner label = $ExpectedRunnerLabel" -Critical
    Check-Contains -Content $content -Pattern "GIT_COMMIT" -Label "GIT_COMMIT export present"
    Check-Contains -Content $content -Pattern "GIT_BRANCH" -Label "GIT_BRANCH export present"
}

if (Check-File -Path $nightlyPath -Name "nightly-evals.yml") {
    $content = Get-Content -Raw -Path $nightlyPath
    Check-Contains -Content $content -Pattern "runs-on:\s*\[.*${ExpectedNightlyLabel}.*\]" -Label "nightly runner label = $ExpectedNightlyLabel"
}

if ($failed) { exit 2 }
