[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$LedgerPath,
    [string]$Headline = "",
    [string]$Signature = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path $LedgerPath)) {
    $result = [ordered]@{
        found = $false
        reason = "ledger_missing"
        id = ""
        match = ""
        line = ""
    }
    $result | ConvertTo-Json -Depth 4
    exit 0
}

$needles = @()
if (-not [string]::IsNullOrWhiteSpace($Signature)) { $needles += $Signature }
if (-not [string]::IsNullOrWhiteSpace($Headline)) { $needles += $Headline }

$lines = Get-Content -Path $LedgerPath
$entries = @()
$current = $null

foreach ($line in $lines) {
    if ($line -match '^ERR-') {
        if ($current) { $entries += $current }
        $current = [ordered]@{
            id = $line.Trim()
            lines = New-Object System.Collections.Generic.List[string]
        }
    }
    if ($current) {
        $current.lines.Add($line)
    }
}
if ($current) { $entries += $current }

$matchResult = $null
foreach ($entry in $entries) {
    foreach ($needle in $needles) {
        foreach ($line in $entry.lines) {
            if ($line.IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $matchResult = [ordered]@{
                    found = $true
                    id = $entry.id
                    match = $needle
                    line = $line.Trim()
                }
                break
            }
        }
        if ($matchResult) { break }
    }
    if ($matchResult) { break }
}

if (-not $matchResult) {
    $matchResult = [ordered]@{
        found = $false
        reason = "not_found"
        id = ""
        match = ""
        line = ""
    }
}

$matchResult | ConvertTo-Json -Depth 4
