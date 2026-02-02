param(
    [string]$Root = (Get-Location).Path,
    [string]$RunId,
    [string]$Repo = "MoniVibe/HeadlessRebuildTool",
    [string]$Workflow = "buildbox_on_demand.yml",
    [string]$Status = "completed",
    [int]$Limit = 20,
    [switch]$Wait,
    [int]$PollSeconds = 10,
    [int]$MaxWaitSeconds = 0,
    [switch]$Refresh,
    [switch]$IncludeWarnings,
    [switch]$IncludeMissing,
    [switch]$ListRuns
)

if ($ListRuns)
{
    if ([string]::IsNullOrWhiteSpace($Status))
    {
        gh run list -R $Repo --workflow $Workflow --limit $Limit
    }
    else
    {
        gh run list -R $Repo --workflow $Workflow --status $Status --limit $Limit
    }
    return
}

if ([string]::IsNullOrWhiteSpace($RunId))
{
    $jsonArgs = @('run','list','-R',$Repo,'--workflow',$Workflow,'--limit',$Limit,'--json','databaseId,status,conclusion,createdAt,displayTitle')
    if (-not $Wait -and -not [string]::IsNullOrWhiteSpace($Status))
    {
        $jsonArgs += @('--status',$Status)
    }

    $raw = & gh @jsonArgs
    $runs = $raw | ConvertFrom-Json
    if (-not $runs -or $runs.Count -eq 0)
    {
        Write-Error "No runs found for $Repo/$Workflow"
        exit 1
    }

    $RunId = $runs[0].databaseId
}

$waited = 0
if ($Wait)
{
    while ($true)
    {
        $view = gh run view $RunId -R $Repo --json status,conclusion | ConvertFrom-Json
        if ($view.status -eq "completed")
        {
            break
        }
        if ($MaxWaitSeconds -gt 0 -and $waited -ge $MaxWaitSeconds)
        {
            Write-Error "Run $RunId did not complete within $MaxWaitSeconds seconds."
            exit 1
        }
        Start-Sleep -Seconds $PollSeconds
        $waited += $PollSeconds
    }
}

$dest = Join-Path $Root "buildbox_$RunId"
if ($Refresh -and (Test-Path $dest))
{
    Remove-Item -Recurse -Force -Path $dest
}

if (Test-Path $dest)
{
    $hasDiag = Get-ChildItem -Path $dest -Directory -Filter 'buildbox_diag_*' -ErrorAction SilentlyContinue | Select-Object -First 1
}
else
{
    $hasDiag = $null
}
if (-not $hasDiag)
{
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Push-Location $dest
      gh run download $RunId -R $Repo | Out-Null
    Pop-Location
}

$collector = Join-Path $PSScriptRoot "collect_compile_errors.ps1"
if (-not (Test-Path $collector))
{
    Write-Error "Missing collector: $collector"
    exit 1
}

$collectorArgs = @{
    Root = $Root
    RunId = $RunId
}
if ($IncludeWarnings) { $collectorArgs.IncludeWarnings = $true }
if ($IncludeMissing) { $collectorArgs.IncludeMissing = $true }

& $collector @collectorArgs
