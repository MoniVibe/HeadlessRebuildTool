Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Describe "resolve_context.ps1" {
    BeforeAll {
        $script:resolveScript = (Resolve-Path ".agents/skills/_shared/scripts/resolve_context.ps1").Path
    }

    It "returns required context fields as JSON" {
        $json = & $script:resolveScript -Title space4x -AsJson
        $ctx = $json | ConvertFrom-Json
        $ctx.repo_root | Should -Not -BeNullOrEmpty
        $ctx.host.os | Should -Not -BeNullOrEmpty
        $ctx.host.pwsh_version | Should -Not -BeNullOrEmpty
    }

    It "throws when QueueRoot is required and missing" {
        { & $script:resolveScript -RequireQueueRoot *> $null } | Should -Throw
    }
}

Describe "write_skill_receipt.ps1" {
    BeforeAll {
        $script:receiptScript = (Resolve-Path ".agents/skills/_shared/scripts/write_skill_receipt.ps1").Path
        $script:repoRoot = (Resolve-Path ".").Path
    }

    It "writes per-run and latest receipt files with valid manifest JSON" {
        $slug = "pester-receipt-smoke"
        & $script:receiptScript `
            -SkillSlug $slug `
            -Status pass `
            -Reason "pester smoke" `
            -InputsJson '{"title":"space4x"}' `
            -CommandsJson '["echo smoke"]' `
            -PathsConsumedJson '["Polish/Docs/NIGHTLY_PROTOCOL.md"]' `
            -PathsProducedJson '[".agents/skills/artifacts/pester-receipt-smoke/latest_manifest.json",".agents/skills/artifacts/pester-receipt-smoke/latest_log.md"]' `
            -LinksJson '{"run_url":"https://example.invalid/run/1"}' | Out-Null

        $artifactDir = Join-Path $script:repoRoot ".agents\skills\artifacts\$slug"
        $latestManifest = Join-Path $artifactDir "latest_manifest.json"
        $latestLog = Join-Path $artifactDir "latest_log.md"

        (Test-Path $latestManifest) | Should -BeTrue
        (Test-Path $latestLog) | Should -BeTrue
        (Get-ChildItem -Path $artifactDir -File -Filter "run_manifest_*.json").Count | Should -BeGreaterThan 0
        (Get-ChildItem -Path $artifactDir -File -Filter "run_log_*.md").Count | Should -BeGreaterThan 0

        $manifest = Get-Content -Raw $latestManifest | ConvertFrom-Json
        $manifest.skill | Should -Be $slug
        $manifest.timing.started_at | Should -Not -BeNullOrEmpty
        $manifest.timing.ended_at | Should -Not -BeNullOrEmpty
        $manifest.receipt_paths.latest_manifest | Should -Not -BeNullOrEmpty
    }
}

Describe "lint_skills.ps1" {
    BeforeAll {
        $script:lintScript = (Resolve-Path ".agents/skills/_shared/scripts/lint_skills.ps1").Path
    }

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
            & $pwsh -NoProfile -File $script:lintScript -SkillsRoot $fixtureRoot *> $null
            $LASTEXITCODE | Should -Not -Be 0
        }
        finally {
            if (Test-Path $fixtureRoot) {
                Remove-Item -Path $fixtureRoot -Recurse -Force
            }
        }
    }
}
