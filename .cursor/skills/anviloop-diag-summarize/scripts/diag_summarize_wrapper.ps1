[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$DiagRoot,
    [string]$OutFile,
    [string]$ToolPath = "C:\Dev\unity_clean\headlessrebuildtool\Polish\Ops\diag_summarize.ps1"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path $ToolPath)) {
    throw "diag_summarize.ps1 not found at $ToolPath"
}

if ([string]::IsNullOrWhiteSpace($OutFile)) {
    $safe = (Split-Path -Leaf $DiagRoot) -replace '[^A-Za-z0-9_.-]', '_'
    $OutFile = Join-Path (Split-Path -Parent $DiagRoot) ("diag_{0}.md" -f $safe)
}

& pwsh -NoProfile -ExecutionPolicy Bypass -File $ToolPath -ResultDir $DiagRoot -OutPath $OutFile

Write-Host "summary_path=$OutFile"
