[CmdletBinding()]
param(
    [string]$ArtifactsRoot = ".agents/skills/artifacts",
    [int]$KeepDays = 14,
    [int]$KeepLastPerSkill = 50,
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($KeepDays -lt 0) { throw "KeepDays must be >= 0" }
if ($KeepLastPerSkill -lt 0) { throw "KeepLastPerSkill must be >= 0" }

function Ensure-List {
    return New-Object System.Collections.Generic.List[object]
}

$root = [System.IO.Path]::GetFullPath($ArtifactsRoot)
if (-not (Test-Path $root)) {
    Write-Host "No artifacts root found: $root"
    exit 0
}

$cutoff = (Get-Date).ToUniversalTime().AddDays(-$KeepDays)
$targets = Ensure-List

$skillDirs = Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue
foreach ($skillDir in $skillDirs) {
    $runFiles = @()
    $runFiles += @(Get-ChildItem -Path $skillDir.FullName -File -Filter "run_manifest_*.json" -ErrorAction SilentlyContinue)
    $runFiles += @(Get-ChildItem -Path $skillDir.FullName -File -Filter "run_log_*.md" -ErrorAction SilentlyContinue)
    $historyDir = Join-Path $skillDir.FullName "history"
    if (Test-Path $historyDir) {
        $runFiles += @(Get-ChildItem -Path $historyDir -File -Filter "run_manifest_*.json" -ErrorAction SilentlyContinue)
    }
    if ($runFiles.Count -eq 0) { continue }

    $manifestKeep = @($runFiles | Where-Object { $_.Name -like "run_manifest_*.json" } | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First $KeepLastPerSkill)
    $logKeep = @($runFiles | Where-Object { $_.Name -like "run_log_*.md" } | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First $KeepLastPerSkill)
    $keepSet = New-Object System.Collections.Generic.HashSet[string]
    foreach ($f in $manifestKeep) { [void]$keepSet.Add($f.FullName) }
    foreach ($f in $logKeep) { [void]$keepSet.Add($f.FullName) }

    foreach ($f in $runFiles) {
        if ($keepSet.Contains($f.FullName)) { continue }
        if ($f.LastWriteTimeUtc -gt $cutoff) { continue }
        $targets.Add([pscustomobject]@{
            path = $f.FullName
            size = $f.Length
            skill = $skillDir.Name
            mtime = $f.LastWriteTimeUtc
        }) | Out-Null
    }
}

$bytes = 0
if ($targets.Count -gt 0) {
    $sum = ($targets | Measure-Object -Property size -Sum).Sum
    if ($sum) { $bytes = [long]$sum }
}

Write-Host ("prune_mode={0}" -f $(if ($Apply) { "APPLY" } else { "DRY_RUN" }))
Write-Host ("artifacts_root={0}" -f $root)
Write-Host ("delete_candidates={0}" -f $targets.Count)
Write-Host ("estimated_reclaim_bytes={0}" -f $bytes)

if (-not $Apply) {
    Write-Host "Dry-run only. Use -Apply to delete."
    exit 0
}

$deleted = 0
foreach ($t in $targets) {
    try {
        Remove-Item -LiteralPath $t.path -Force -ErrorAction Stop
        $deleted += 1
    }
    catch {
        Write-Warning ("failed_delete path={0} error={1}" -f $t.path, $_.Exception.Message)
    }
}

Write-Host ("deleted_count={0}" -f $deleted)
