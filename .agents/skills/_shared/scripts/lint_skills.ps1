[CmdletBinding()]
param(
    [string]$SkillsRoot = ".agents/skills"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Add-Issue {
    param(
        [System.Collections.Generic.List[object]]$List,
        [string]$Code,
        [string]$Path,
        [string]$Message
    )
    $List.Add([pscustomobject]@{
        code = $Code
        path = $Path
        message = $Message
    }) | Out-Null
}

function Parse-Frontmatter {
    param([string]$Text)
    if ($Text -notmatch '(?s)^---\r?\n(.*?)\r?\n---\r?\n') { return $null }
    return $Matches[1]
}

$root = [System.IO.Path]::GetFullPath($SkillsRoot)
if (-not (Test-Path $root)) {
    throw "Skills root not found: $root"
}

$issues = New-Object System.Collections.Generic.List[object]
$hardcodedPathPattern = '(?i)C:\\\\Dev|C:\\\\dev|unity_clean|/home/oni/headless'

# Skill markdown checks
$skillFiles = Get-ChildItem -Path $root -Recurse -File -Filter "SKILL.md" | Where-Object {
    $_.FullName -notmatch '\\_shared\\'
}
foreach ($file in $skillFiles) {
    $rel = $file.FullName.Replace($root + '\', '')
    $skillSlug = Split-Path -Parent $rel | Split-Path -Leaf
    $raw = Get-Content -Raw -Path $file.FullName
    $fm = Parse-Frontmatter -Text $raw
    if ($null -eq $fm) {
        Add-Issue -List $issues -Code "frontmatter_missing" -Path $rel -Message "Missing YAML frontmatter."
        continue
    }
    $keys = New-Object System.Collections.Generic.HashSet[string]
    foreach ($line in ($fm -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^([a-zA-Z0-9_-]+):\s*(.*)$') {
            [void]$keys.Add($Matches[1])
            continue
        }
        Add-Issue -List $issues -Code "frontmatter_line_invalid" -Path $rel -Message ("Invalid frontmatter line: {0}" -f $line)
    }
    foreach ($k in $keys) {
        if ($k -notin @("name", "description")) {
            Add-Issue -List $issues -Code "frontmatter_key_invalid" -Path $rel -Message ("Invalid key: {0}" -f $k)
        }
    }
    if (-not $keys.Contains("name")) {
        Add-Issue -List $issues -Code "frontmatter_name_missing" -Path $rel -Message "Missing name."
    }
    if (-not $keys.Contains("description")) {
        Add-Issue -List $issues -Code "frontmatter_description_missing" -Path $rel -Message "Missing description."
    }

    if ($raw -notmatch '^## Receipt \(Required\)' -and $raw -notmatch '(?m)^## Receipt \(Required\)') {
        Add-Issue -List $issues -Code "receipt_section_missing" -Path $rel -Message "Missing '## Receipt (Required)' section."
    }
    if ($raw -notmatch 'write_skill_receipt\.ps1') {
        Add-Issue -List $issues -Code "receipt_invocation_missing" -Path $rel -Message "Missing receipt writer invocation."
    }

    $queueTouching = $skillSlug -match '(?i)queue|enqueue|watch-daemon|local-fallback|nightly-runner-orchestrator'
    if ($queueTouching) {
        if ($raw -notmatch 'QueueRoot' -and $raw -notmatch '(?i)queue root') {
            Add-Issue -List $issues -Code "queue_root_not_explicit" -Path $rel -Message "Queue-touching skill must explicitly mention QueueRoot."
        }
    }

    $mentionsCleanupQueue = $raw -match '(?i)cleanup_queue\.ps1'
    if ($mentionsCleanupQueue) {
        if ($raw -notmatch '(?i)dry-run|dry run') {
            Add-Issue -List $issues -Code "cleanup_requires_dry_run" -Path $rel -Message "cleanup_queue usage must document dry-run before apply."
        }
        if ($raw -notmatch '(?i)-Apply') {
            Add-Issue -List $issues -Code "cleanup_requires_apply_doc" -Path $rel -Message "cleanup_queue usage must document explicit -Apply gate."
        }
    }

    $mentionsDeckRun = $raw -match '(?i)run_deck\.ps1'
    if ($mentionsDeckRun) {
        if ($raw -notmatch '(?i)-AllowLocalBuild') {
            Add-Issue -List $issues -Code "deck_requires_allow_local_build" -Path $rel -Message "run_deck usage must include -AllowLocalBuild."
        }
        if ($raw -notmatch '(?i)emergency') {
            Add-Issue -List $issues -Code "deck_requires_emergency_label" -Path $rel -Message "run_deck usage must be explicitly labeled emergency-only."
        }
    }

    $mentionsBuildboxDispatch = $raw -match '(?i)trigger_buildbox\.ps1|dispatch\s+buildbox_on_demand|buildbox_on_demand workflow runs'
    if ($mentionsBuildboxDispatch) {
        if ($raw -notmatch '(?i)nightly-preflight-guard|preflight_guard\.ps1') {
            Add-Issue -List $issues -Code "dispatch_requires_preflight" -Path $rel -Message "buildbox dispatch skills must reference preflight guard first."
        }
    }
}

# Path hygiene scan
$textFiles = Get-ChildItem -Path $root -Recurse -File | Where-Object {
    $_.FullName -notmatch '\\artifacts\\' -and $_.Extension -in @(".md", ".ps1", ".json", ".yaml", ".yml") -and $_.Name -ne "lint_skills.ps1"
}
foreach ($file in $textFiles) {
    $rel = $file.FullName.Replace($root + '\', '')
    $hits = Select-String -Path $file.FullName -Pattern $hardcodedPathPattern -ErrorAction SilentlyContinue
    foreach ($hit in $hits) {
        Add-Issue -List $issues -Code "hardcoded_path" -Path $rel -Message ("Hardcoded path pattern at line {0}" -f $hit.LineNumber)
    }
}

# PowerShell parse check
$psFiles = Get-ChildItem -Path $root -Recurse -File -Filter "*.ps1"
foreach ($file in $psFiles) {
    $rel = $file.FullName.Replace($root + '\', '')
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        foreach ($err in $parseErrors) {
            Add-Issue -List $issues -Code "ps_parse_error" -Path $rel -Message $err.Message
        }
    }
}

if ($issues.Count -gt 0) {
    Write-Host "skill_lint=FAIL"
    foreach ($i in $issues) {
        Write-Host ("[{0}] {1} :: {2}" -f $i.code, $i.path, $i.message)
    }
    exit 2
}

Write-Host "skill_lint=PASS"
Write-Host ("skills_checked={0}" -f $skillFiles.Count)
Write-Host ("ps_files_checked={0}" -f $psFiles.Count)
