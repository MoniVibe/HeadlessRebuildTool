[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Title,
    [string]$BuildId,
    [string]$ArtifactZip,
    [string]$QueueRoot = "C:\\polish\\queue",
    [int]$PollSeconds = 10,
    [int]$TimeoutSeconds = 3600,
    [int]$Repeat = 1,
    [int]$Seed,
    [string]$ScenarioId,
    [string]$ScenarioRel,
    [string]$GoalId,
    [string]$GoalSpec,
    [string[]]$Args,
    [switch]$WaitForResult,
    [int]$WaitTimeoutSec = 1800
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Directory {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function Resolve-ArtifactZip {
    param([string]$Root, [string]$Build, [string]$Zip)
    if (-not [string]::IsNullOrWhiteSpace($Zip)) { return $Zip }
    if ([string]::IsNullOrWhiteSpace($Build)) {
        throw "Provide -BuildId or -ArtifactZip."
    }
    return Join-Path (Join-Path $Root "artifacts") ("artifact_{0}.zip" -f $Build)
}

function Read-BuildOutcome {
    param([string]$ZipPath)
    if (-not (Test-Path $ZipPath)) { return $null }
    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $entry = $archive.GetEntry("logs/build_outcome.json")
        if (-not $entry) { return $null }
        $reader = New-Object System.IO.StreamReader($entry.Open())
        try { return ($reader.ReadToEnd() | ConvertFrom-Json) } finally { $reader.Dispose() }
    }
    finally {
        $archive.Dispose()
    }
}

$queueRootFull = [System.IO.Path]::GetFullPath($QueueRoot)
Ensure-Directory (Join-Path $queueRootFull "artifacts")

$artifactPath = Resolve-ArtifactZip -Root $queueRootFull -Build $BuildId -Zip $ArtifactZip
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)

Write-Host ("watch_start title={0} artifact={1} timeout_sec={2}" -f $Title, $artifactPath, $TimeoutSeconds)

while (-not (Test-Path $artifactPath)) {
    if (Get-Date -ge $deadline) {
        throw "Timeout waiting for artifact: $artifactPath"
    }
    Start-Sleep -Seconds $PollSeconds
}

Write-Host ("artifact_found path={0}" -f $artifactPath)

$outcome = Read-BuildOutcome -ZipPath $artifactPath
if (-not $outcome) {
    throw "build_outcome.json missing in artifact: $artifactPath"
}
if ($outcome.result -ne "Succeeded") {
    throw "Artifact build not succeeded: result=$($outcome.result) message=$($outcome.message)"
}

$enqueueScript = Join-Path $PSScriptRoot "pipeline_enqueue.ps1"
if (-not (Test-Path $enqueueScript)) {
    throw "Missing pipeline_enqueue.ps1: $enqueueScript"
}

$invokeArgs = @(
    "-Title", $Title,
    "-ArtifactZip", $artifactPath,
    "-QueueRoot", $QueueRoot,
    "-Repeat", $Repeat
)

if ($PSBoundParameters.ContainsKey("Seed")) { $invokeArgs += @("-Seed", $Seed) }
if ($PSBoundParameters.ContainsKey("ScenarioId")) { $invokeArgs += @("-ScenarioId", $ScenarioId) }
if ($PSBoundParameters.ContainsKey("ScenarioRel")) { $invokeArgs += @("-ScenarioRel", $ScenarioRel) }
if ($PSBoundParameters.ContainsKey("GoalId")) { $invokeArgs += @("-GoalId", $GoalId) }
if ($PSBoundParameters.ContainsKey("GoalSpec")) { $invokeArgs += @("-GoalSpec", $GoalSpec) }
if ($PSBoundParameters.ContainsKey("Args")) { $invokeArgs += @("-Args", $Args) }
if ($WaitForResult) { $invokeArgs += "-WaitForResult" }
if ($PSBoundParameters.ContainsKey("WaitTimeoutSec")) { $invokeArgs += @("-WaitTimeoutSec", $WaitTimeoutSec) }

Write-Host ("enqueue_start title={0} artifact={1}" -f $Title, $artifactPath)
& $enqueueScript @invokeArgs
