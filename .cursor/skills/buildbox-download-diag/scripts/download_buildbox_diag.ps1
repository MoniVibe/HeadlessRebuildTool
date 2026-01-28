[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [long]$RunId,
    [ValidateSet('space4x', 'godgame')]
    [string]$Title,
    [string]$ArtifactName,
    [string]$Repo = "MoniVibe/HeadlessRebuildTool",
    [string]$OutputRoot = "C:\polish\queue\reports\_diag_downloads",
    [switch]$Expand
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Require-Gh {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw "GitHub CLI (gh) not found. Install gh and run 'gh auth login'."
    }
}

Require-Gh

if ([string]::IsNullOrWhiteSpace($ArtifactName)) {
    if (-not [string]::IsNullOrWhiteSpace($Title)) {
        $ArtifactName = "buildbox_diag_$Title"
    } else {
        $ArtifactName = "buildbox_diag"
    }
}

$artifactsJson = & gh api "/repos/$Repo/actions/runs/$RunId/artifacts"
$artifacts = (ConvertFrom-Json $artifactsJson).artifacts
if ($null -eq $artifacts -or $artifacts.Count -eq 0) {
    throw "No artifacts found for run $RunId in $Repo."
}

$artifact = $artifacts | Where-Object { $_.name -like "$ArtifactName*" } | Sort-Object created_at -Descending | Select-Object -First 1
if ($null -eq $artifact) {
    $names = ($artifacts | Select-Object -ExpandProperty name) -join ", "
    throw "No artifact matched '$ArtifactName*'. Available: $names"
}

$destDir = Join-Path $OutputRoot $RunId
New-Item -ItemType Directory -Path $destDir -Force | Out-Null

$zipPath = Join-Path $destDir ("{0}.zip" -f $artifact.name)
$archiveUrl = $artifact.archive_download_url
& gh api -X GET $archiveUrl > $zipPath

Write-Host "artifact_name=$($artifact.name)"
Write-Host "zip_path=$zipPath"

if ($Expand) {
    $outDir = Join-Path $destDir $artifact.name
    Expand-Archive -Path $zipPath -DestinationPath $outDir -Force
    Write-Host "expanded_path=$outDir"
}
