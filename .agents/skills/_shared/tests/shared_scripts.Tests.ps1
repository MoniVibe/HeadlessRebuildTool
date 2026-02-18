Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptsDir = (Resolve-Path (Join-Path $PSScriptRoot "..\scripts")).Path
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..")).Path
$resolveScript = Join-Path $scriptsDir "resolve_context.ps1"
$receiptScript = Join-Path $scriptsDir "write_skill_receipt.ps1"
$lintScript = Join-Path $scriptsDir "lint_skills.ps1"

Describe "resolve_context.ps1" {
    It "returns required context fields as JSON" {
        $json = & $resolveScript -Title space4x -AsJson
        $ctx = $json | ConvertFrom-Json
        $ctx.repo_root | Should Not BeNullOrEmpty
        $ctx.host.os | Should Not BeNullOrEmpty
        $ctx.host.pwsh_version | Should Not BeNullOrEmpty
    }

    It "throws when QueueRoot is required and missing" {
        $threw = $false
        try {
            & $resolveScript -RequireQueueRoot *> $null
        }
        catch {
            $threw = $true
        }
        $threw | Should Be $true
    }
}

Describe "write_skill_receipt.ps1" {
    It "writes per-run and latest receipt files with valid manifest JSON" {
        $slug = "pester-receipt-smoke"
        & $receiptScript `
            -SkillSlug $slug `
            -Status pass `
            -Reason "pester smoke" `
            -InputsJson '{"title":"space4x"}' `
            -CommandsJson '["echo smoke"]' `
            -PathsConsumedJson '["Polish/Docs/NIGHTLY_PROTOCOL.md"]' `
            -PathsProducedJson '[".agents/skills/artifacts/pester-receipt-smoke/latest_manifest.json",".agents/skills/artifacts/pester-receipt-smoke/latest_log.md"]' `
            -LinksJson '{"run_url":"https://example.invalid/run/1"}' | Out-Null

        $artifactDir = Join-Path $repoRoot ".agents\skills\artifacts\$slug"
        $latestManifest = Join-Path $artifactDir "latest_manifest.json"
        $latestLog = Join-Path $artifactDir "latest_log.md"

        (Test-Path $latestManifest) | Should Be $true
        (Test-Path $latestLog) | Should Be $true
        (Get-ChildItem -Path $artifactDir -File -Filter "run_manifest_*.json").Count | Should BeGreaterThan 0
        (Get-ChildItem -Path $artifactDir -File -Filter "run_log_*.md").Count | Should BeGreaterThan 0

        $manifest = Get-Content -Raw $latestManifest | ConvertFrom-Json
        $manifest.skill | Should Be $slug
        $manifest.timing.started_at | Should Not BeNullOrEmpty
        $manifest.timing.ended_at | Should Not BeNullOrEmpty
        $manifest.receipt_paths.latest_manifest | Should Not BeNullOrEmpty
    }
}

Describe "lint_skills.ps1" {
    It "returns non-zero on invalid skill fixture" {
        $fixtureRoot = Join-Path $env:TEMP ("skills-lint-fixture-" + [Guid]::NewGuid().ToString("N"))
        $badSkillDir = Join-Path $fixtureRoot "bad-skill"
        New-Item -ItemType Directory -Path $badSkillDir -Force | Out-Null
        Set-Content -Path (Join-Path $badSkillDir "SKILL.md") -Encoding ascii -Value @(
            "name: bad-skill",
            "description: missing frontmatter delimiters"
        )

        try {
            $pwsh = (Get-Command pwsh).Source
            $proc = Start-Process -FilePath $pwsh -ArgumentList @(
                "-NoProfile",
                "-File", $lintScript,
                "-SkillsRoot", $fixtureRoot
            ) -NoNewWindow -PassThru -Wait
            $proc.ExitCode | Should Not Be 0
        }
        finally {
            if (Test-Path $fixtureRoot) {
                Remove-Item -Path $fixtureRoot -Recurse -Force
            }
        }
    }
}
