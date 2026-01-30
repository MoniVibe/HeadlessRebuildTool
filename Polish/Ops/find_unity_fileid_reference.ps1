param(
  [Parameter(Mandatory = $true)]
  [string]$FileId,
  [string]$Root = "C:\Dev\unity_clean\space4x",
  [string]$OutFile = "",
  [switch]$IncludePackages
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path $Root)) {
  throw "Root not found: $Root"
}

$extensions = @("*.prefab", "*.unity", "*.asset", "*.mat", "*.controller", "*.overrideController", "*.anim", "*.inputactions")
$excludeDirs = @("Library", "Temp", "Obj", "Build", "Builds", "Logs", "UserSettings")
if (-not $IncludePackages) { $excludeDirs += "Packages" }

$pattern = "fileID:\s*$FileId"
$matches = @()

$files = Get-ChildItem -Path $Root -Recurse -File -Include $extensions -ErrorAction SilentlyContinue |
  Where-Object {
    foreach ($dir in $excludeDirs) {
      if ($_.FullName -match [regex]::Escape("\\$dir\\")) { return $false }
    }
    return $true
  }

foreach ($file in $files) {
  try {
    $hit = Select-String -Path $file.FullName -Pattern $pattern -SimpleMatch:$false -ErrorAction SilentlyContinue
    if ($hit) {
      foreach ($h in $hit) {
        $matches += ("{0}: {1}" -f $file.FullName, $h.Line.Trim())
      }
    }
  } catch {
  }
}

if ([string]::IsNullOrWhiteSpace($OutFile)) {
  $reports = "C:\polish\queue\reports"
  if (Test-Path $reports) {
    $OutFile = Join-Path $reports ("fileid_scan_{0}.txt" -f $FileId)
  } else {
    $OutFile = Join-Path $Root ("fileid_scan_{0}.txt" -f $FileId)
  }
}

$header = @(
  "file_id=$FileId",
  "root=$Root",
  ("include_packages={0}" -f ($IncludePackages.IsPresent)),
  ("match_count={0}" -f $matches.Count)
)

$header + $matches | Set-Content -Path $OutFile
Write-Host ("match_count={0}" -f $matches.Count)
Write-Host ("out_file={0}" -f $OutFile)
