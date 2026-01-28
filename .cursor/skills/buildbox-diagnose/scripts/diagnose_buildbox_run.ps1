[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [long]$RunId,
    [ValidateSet('space4x', 'godgame')]
    [string]$Title,
    [string]$Repo = "MoniVibe/HeadlessRebuildTool",
    [string]$OutputRoot = "C:\polish\queue\reports\_diag_downloads",
    [string]$DiagTool = "C:\Dev\unity_clean\headlessrebuildtool\Polish\Ops\diag_summarize.ps1"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Require-Gh {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw "GitHub CLI (gh) not found. Install gh and run 'gh auth login'."
    }
}

Require-Gh

$artifactPrefix = if ($Title) { "buildbox_diag_$Title" } else { "buildbox_diag" }

$artifactsJson = & gh api "/repos/$Repo/actions/runs/$RunId/artifacts"
$artifacts = (ConvertFrom-Json $artifactsJson).artifacts
if ($null -eq $artifacts -or $artifacts.Count -eq 0) {
    throw "No artifacts found for run $RunId in $Repo."
}

$artifact = $artifacts | Where-Object { $_.name -like "$artifactPrefix*" } | Sort-Object created_at -Descending | Select-Object -First 1
if ($null -eq $artifact) {
    $names = ($artifacts | Select-Object -ExpandProperty name) -join ", "
    throw "No artifact matched '$artifactPrefix*'. Available: $names"
}

$destDir = Join-Path $OutputRoot $RunId
New-Item -ItemType Directory -Path $destDir -Force | Out-Null

$zipPath = Join-Path $destDir ("{0}.zip" -f $artifact.name)
$archiveUrl = $artifact.archive_download_url
& gh api -X GET $archiveUrl > $zipPath

$diagRoot = Join-Path $destDir $artifact.name
if (Test-Path $diagRoot) { Remove-Item -Recurse -Force $diagRoot }
Expand-Archive -Path $zipPath -DestinationPath $diagRoot -Force

Write-Host "diag_root=$diagRoot"

$resultDir = Get-ChildItem -Path (Join-Path $diagRoot 'results') -Directory -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
if (-not $resultDir) {
    Write-Host "result_dir=(none)"
    exit 0
}

Write-Host "result_dir=$resultDir"

if (Test-Path $DiagTool) {
    $summaryPath = Join-Path $resultDir ("diag_{0}.md" -f (Split-Path -Leaf $resultDir))
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $DiagTool -ResultDir $resultDir -OutPath $summaryPath
    Write-Host "summary_path=$summaryPath"
} else {
    Write-Warning "diag_summarize.ps1 not found at $DiagTool"
}
