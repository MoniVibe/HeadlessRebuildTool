[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Stage,
    [Parameter(Mandatory = $true)]
    [string]$Symptom,
    [Parameter(Mandatory = $true)]
    [string]$Signature,
    [Parameter(Mandatory = $true)]
    [string]$RootCause,
    [Parameter(Mandatory = $true)]
    [string]$Fix,
    [Parameter(Mandatory = $true)]
    [string]$Prevention,
    [Parameter(Mandatory = $true)]
    [string]$Verification,
    [Parameter(Mandatory = $true)]
    [string[]]$EvidencePaths,
    [string]$Commit = "",
    [string]$LedgerPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-RepoRoot {
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $resolved = Resolve-Path (Join-Path $scriptDir "..\..\..\..")
    if ($resolved -is [string]) { return $resolved }
    return @($resolved)[0].Path
}

$repoRoot = Resolve-RepoRoot
if ([string]::IsNullOrWhiteSpace($LedgerPath)) {
    $LedgerPath = Join-Path $repoRoot "Polish\Docs\ANVILOOP_RECURRING_ERRORS.md"
}

if (-not (Test-Path $LedgerPath)) {
    throw "Ledger not found: $LedgerPath"
}

$existing = Get-Content -Raw -Path $LedgerPath
if ($existing -match [regex]::Escape($Signature)) {
    Write-Warning "Signature already exists in ledger. Appending anyway."
}

$now = (Get-Date).ToUniversalTime()
$id = "ERR-{0}" -f $now.ToString("yyyyMMdd-HHmmss")
$date = $now.ToString("yyyy-MM-dd")

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("")
$lines.Add($id)
$lines.Add(("- FirstSeen: {0}" -f $date))
$lines.Add(("- Stage: {0}" -f $Stage))
$lines.Add(("- Symptom: {0}" -f $Symptom))
$lines.Add(("- Signature: {0}" -f $Signature))
$lines.Add(("- RootCause: {0}" -f $RootCause))
$lines.Add(("- Fix: {0}" -f $Fix))
$lines.Add(("- Prevention: {0}" -f $Prevention))
$lines.Add(("- Verification: {0}" -f $Verification))
foreach ($p in $EvidencePaths) {
    if ([string]::IsNullOrWhiteSpace($p)) { continue }
    $lines.Add(("- Evidence: {0}" -f $p))
}
if (-not [string]::IsNullOrWhiteSpace($Commit)) {
    $lines.Add(("- Commit: {0}" -f $Commit))
}

Add-Content -Path $LedgerPath -Encoding ascii -Value $lines
Write-Host ("ledger_updated={0}" -f $LedgerPath)
Write-Host ("entry_id={0}" -f $id)
