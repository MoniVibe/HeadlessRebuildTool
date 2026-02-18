[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [long]$RunId,
    [ValidateSet('space4x', 'godgame')]
    [string]$Title,
    [string]$Repo = "MoniVibe/HeadlessRebuildTool",
    [string]$OutputRoot = "C:\polish\queue\reports\_diag_downloads"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Require-Gh {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw "GitHub CLI (gh) not found. Install gh and run 'gh auth login'."
    }
}

Require-Gh

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..")).Path
$diagTool = Join-Path $repoRoot "Polish\Ops\diag_summarize.ps1"
if (-not (Test-Path $diagTool)) {
    throw "diag_summarize.ps1 not found: $diagTool"
}

$artifactPrefix = if ($Title) { "buildbox_diag_$Title" } else { "buildbox_diag" }

$artifactsJson = & gh api "/repos/$Repo/actions/runs/$RunId/artifacts"
$artifacts = (ConvertFrom-Json $artifactsJson).artifacts
if (-not $artifacts -or $artifacts.Count -eq 0) {
    throw "No artifacts found for run $RunId in $Repo."
}

$artifact = $artifacts | Where-Object { $_.name -like "$artifactPrefix*" } | Sort-Object created_at -Descending | Select-Object -First 1
if (-not $artifact) {
    $names = ($artifacts | Select-Object -ExpandProperty name) -join ", "
    throw "No artifact matched '$artifactPrefix*'. Available: $names"
}

$destDir = Join-Path $OutputRoot $RunId
New-Item -ItemType Directory -Path $destDir -Force | Out-Null

$zipPath = Join-Path $destDir ("{0}.zip" -f $artifact.name)
& gh api -X GET $artifact.archive_download_url > $zipPath

$diagRoot = Join-Path $destDir $artifact.name
if (Test-Path $diagRoot) {
    Remove-Item -Recurse -Force $diagRoot
}
Expand-Archive -Path $zipPath -DestinationPath $diagRoot -Force

$resultsRoot = Join-Path $diagRoot "results"
$resultDir = $null
if (Test-Path $resultsRoot) {
    $resultDir = Get-ChildItem -Path $resultsRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}

$summaryPath = ""
if ($resultDir) {
    $summaryPath = Join-Path $resultDir ("diag_{0}.md" -f (Split-Path -Leaf $resultDir))
    & pwsh -NoProfile -File $diagTool -ResultDir $resultDir -OutPath $summaryPath
}

Write-Host ("artifact_name={0}" -f $artifact.name)
Write-Host ("zip_path={0}" -f $zipPath)
Write-Host ("diag_root={0}" -f $diagRoot)
Write-Host ("result_dir={0}" -f $(if ($resultDir) { $resultDir } else { "(none)" }))
Write-Host ("summary_path={0}" -f $(if ($summaryPath) { $summaryPath } else { "(none)" }))
