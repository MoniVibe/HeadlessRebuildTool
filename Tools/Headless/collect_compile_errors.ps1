param(
    [string]$Root = (Get-Location).Path,
    [string]$RunId,
    [switch]$IncludeWarnings,
    [switch]$IncludeMissing,
    [switch]$ListRuns
)

function Get-RunDirs([string]$base)
{
    Get-ChildItem -Path $base -Directory -Filter 'buildbox_*' -ErrorAction SilentlyContinue
}

if ($ListRuns)
{
    Get-RunDirs $Root | Sort-Object LastWriteTime -Descending | Select-Object Name, LastWriteTime, FullName
    return
}

if ([string]::IsNullOrWhiteSpace($RunId))
{
    $latest = Get-RunDirs $Root | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest)
    {
        Write-Error "No buildbox_* directories under $Root"
        exit 1
    }
    $runDir = $latest.FullName
}
else
{
    $runDir = Join-Path $Root "buildbox_$RunId"
    if (-not (Test-Path $runDir))
    {
        Write-Error "Run directory not found: $runDir"
        exit 1
    }
}

$diagDirs = Get-ChildItem -Path $runDir -Directory -Filter 'buildbox_diag_*' -ErrorAction SilentlyContinue
if (-not $diagDirs)
{
    Write-Error "No buildbox_diag_* folders under $runDir"
    exit 1
}

$logFiles = foreach ($diag in $diagDirs)
{
    Get-ChildItem -Path $diag.FullName -Recurse -File -Include 'primary_error_snippet.txt','unity_build_tail.txt','compiler_errors.txt','build_error_summary.txt','missing_scripts.txt' -ErrorAction SilentlyContinue
}

if (-not $logFiles)
{
    Write-Error "No log files found under $runDir"
    exit 1
}

$pattern = if ($IncludeWarnings) { '(error|warning)\s+CS\d{4,5}:.+' } else { 'error\s+CS\d{4,5}:.+' }
$errors = New-Object System.Collections.Generic.List[string]

foreach ($file in $logFiles)
{
    $lines = Get-Content $file.FullName -ErrorAction SilentlyContinue
    foreach ($line in $lines)
    {
        if ($line -match $pattern)
        {
            $errors.Add($Matches[0])
        }
    }

    if ($IncludeMissing -and $file.Name -eq 'missing_scripts.txt')
    {
        foreach ($line in $lines)
        {
            if (-not [string]::IsNullOrWhiteSpace($line))
            {
                $errors.Add("missing_script: $line")
            }
        }
    }
}

$unique = $errors | Sort-Object -Unique
Write-Host "Run dir: $runDir"
Write-Host "Diagnostics: $($diagDirs.Count)"
Write-Host "Errors: $($unique.Count)"
$unique | ForEach-Object { Write-Host $_ }
