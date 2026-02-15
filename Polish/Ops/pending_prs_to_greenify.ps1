[CmdletBinding()]
param(
    [string[]]$Repos = @("MoniVibe/Space4x", "MoniVibe/Godgame"),
    [string]$RequiredLabel = "needs-validate",
    [string]$ExcludeLabel = "needs-intent-card",
    [int]$LimitPerRepo = 100,
    [switch]$IncludeDraft,
    [string]$OutputPath = "C:\polish\queue\reports\pending_prs_to_greenify.md",
    [string]$GitHubToken = "",
    [switch]$WriteOnDesktop,
    [string]$DesktopOutputPath = "C:\polish\queue\reports\pending_prs_to_greenify.md",
    [string]$SshHost = "25.30.14.37",
    [string]$SshUser = "Moni",
    [string]$SshKey = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Resolve-SshExe {
    $cmd = Get-Command ssh -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $fallback = Join-Path $env:WINDIR "System32\OpenSSH\ssh.exe"
    if (Test-Path $fallback) { return $fallback }
    return $null
}

function Get-SshClientInfo {
    $sshExe = Resolve-SshExe
    if ([string]::IsNullOrWhiteSpace($sshExe) -or -not (Test-Path $sshExe)) {
        throw "ssh.exe not found."
    }

    $keyPath = $SshKey
    if ([string]::IsNullOrWhiteSpace($keyPath)) {
        $keyPath = Join-Path $env:USERPROFILE ".ssh\buildbox_laptop_ed25519"
    }
    if (-not (Test-Path $keyPath)) {
        throw "ssh key not found: $keyPath"
    }

    return [pscustomobject]@{
        exe = $sshExe
        key = $keyPath
    }
}

function Invoke-SshJson {
    param(
        [Parameter(Mandatory = $true)][string]$RemoteScript
    )

    $info = Get-SshClientInfo
    $sshArgs = @(
        "-i", $info.key,
        "-o", "IdentitiesOnly=yes",
        "-o", "StrictHostKeyChecking=accept-new",
        ("{0}@{1}" -f $SshUser, $SshHost)
    )

    $bytes = [System.Text.Encoding]::Unicode.GetBytes($RemoteScript)
    $encoded = [Convert]::ToBase64String($bytes)
    $remote = "powershell -NoProfile -EncodedCommand $encoded"
    $output = & $info.exe @sshArgs $remote
    if (-not $output) {
        throw "Empty SSH response from $SshUser@$SshHost"
    }
    return ($output | ConvertFrom-Json)
}

function Escape-MarkdownCell {
    param([string]$Value)
    if ($null -eq $Value) { return "" }
    $text = [string]$Value
    $text = $text -replace '\|', '\|'
    $text = $text -replace '[\r\n]+', ' '
    return $text.Trim()
}

function Write-RemoteTextFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $remotePath = $Path.Replace("'", "''")
    $remoteDir = (Split-Path -Parent $Path).Replace("'", "''")
    $payload = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Content))

    $remoteScript = @"
`$ErrorActionPreference='Stop'
[System.IO.Directory]::CreateDirectory('$remoteDir') | Out-Null
`$bytes = [Convert]::FromBase64String('$payload')
`$text = [System.Text.Encoding]::UTF8.GetString(`$bytes)
[System.IO.File]::WriteAllText('$remotePath', `$text, [System.Text.Encoding]::UTF8)
[ordered]@{ path='$remotePath'; length=`$text.Length } | ConvertTo-Json -Depth 2
"@

    return (Invoke-SshJson -RemoteScript $remoteScript)
}

function Resolve-GitHubToken {
    if (-not [string]::IsNullOrWhiteSpace($GitHubToken)) {
        return $GitHubToken
    }
    if (-not [string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
        return $env:GH_TOKEN
    }
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw "gh CLI not found locally; provide -GitHubToken or set GH_TOKEN."
    }
    $token = (& gh auth token 2>$null)
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "Unable to resolve GitHub token locally. Provide -GitHubToken or run 'gh auth login'."
    }
    return $token.Trim()
}

$reposJson = $Repos | ConvertTo-Json -Compress
$required = $RequiredLabel.Replace("'", "''")
$exclude = $ExcludeLabel.Replace("'", "''")
$tokenEscaped = (Resolve-GitHubToken).Replace("'", "''")

$remoteScript = @"
`$ErrorActionPreference='Stop'
`$ProgressPreference='SilentlyContinue'
`$repos = ConvertFrom-Json '$reposJson'
`$requiredLabel = '$required'
`$excludeLabel = '$exclude'
`$limitPerRepo = $LimitPerRepo
`$includeDraft = $(if ($IncludeDraft.IsPresent) { '$true' } else { '$false' })
`$env:GH_TOKEN = '$tokenEscaped'

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'gh CLI not found on remote host.'
}

`$result = [ordered]@{
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    host = `$env:COMPUTERNAME
    repos = @()
}

foreach (`$repo in `$repos) {
    `$search = "state:open label:`$requiredLabel"
    if (-not [string]::IsNullOrWhiteSpace(`$excludeLabel)) {
        `$search += " -label:`$excludeLabel"
    }
    if (-not `$includeDraft) {
        `$search += " draft:false"
    }

    `$json = gh pr list -R `$repo --state open --search `$search --limit `$limitPerRepo --json number,title,url,createdAt,updatedAt,headRefName,isDraft,author,labels 2>`$null
    if ([string]::IsNullOrWhiteSpace(`$json)) {
        `$prs = @()
    } else {
        `$prs = `$json | ConvertFrom-Json
    }

    `$items = @()
    foreach (`$pr in `$prs) {
        `$labelNames = @()
        if (`$pr.labels) {
            foreach (`$lbl in `$pr.labels) {
                if (`$lbl -and `$lbl.name) { `$labelNames += [string]`$lbl.name }
            }
        }
        `$items += [ordered]@{
            number = [int]`$pr.number
            title = [string]`$pr.title
            url = [string]`$pr.url
            createdAt = [string]`$pr.createdAt
            updatedAt = [string]`$pr.updatedAt
            headRefName = [string]`$pr.headRefName
            isDraft = [bool]`$pr.isDraft
            author = if (`$pr.author) { [string]`$pr.author.login } else { "" }
            labels = `$labelNames
        }
    }

    `$result.repos += [ordered]@{
        repo = `$repo
        count = `$items.Count
        items = `$items
    }
}

`$result | ConvertTo-Json -Depth 8
"@

$data = Invoke-SshJson -RemoteScript $remoteScript

$all = @()
foreach ($repoBlock in @($data.repos)) {
    foreach ($item in @($repoBlock.items)) {
        $created = [datetime]::MinValue
        $updated = [datetime]::MinValue
        try {
            if (-not [string]::IsNullOrWhiteSpace([string]$item.createdAt)) {
                $created = [datetime]$item.createdAt
            }
        } catch { }
        try {
            if (-not [string]::IsNullOrWhiteSpace([string]$item.updatedAt)) {
                $updated = [datetime]$item.updatedAt
            }
        } catch { }

        $labels = ""
        if ($item.labels) {
            $labels = (($item.labels | ForEach-Object { [string]$_ }) -join ", ")
        }

        $all += [pscustomobject]@{
            Repo = [string]$repoBlock.repo
            Number = [int]$item.number
            Title = [string]$item.title
            Url = [string]$item.url
            Branch = [string]$item.headRefName
            CreatedAt = $created
            UpdatedAt = $updated
            Author = [string]$item.author
            IsDraft = [bool]$item.isDraft
            Labels = $labels
        }
    }
}

$ordered = @($all | Sort-Object CreatedAt, UpdatedAt, Repo, Number)
$nowUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss 'UTC'")

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("# Pending PRs To Greenify")
$lines.Add("")
$lines.Add("- Generated: $nowUtc")
$lines.Add("- Source: SSH $SshUser@$SshHost ($($data.host))")
$lines.Add("- Filter: state:open label:$RequiredLabel -label:$ExcludeLabel")
$lines.Add("- Total Pending: $($ordered.Count)")
$lines.Add("")

if ($ordered.Count -eq 0) {
    $lines.Add("No PRs currently pending validation.")
} else {
    $lines.Add("| Queue | Repo | PR | Title | Branch | Updated (UTC) | Author | Labels |")
    $lines.Add("|---:|---|---:|---|---|---|---|---|")

    $i = 1
    foreach ($pr in $ordered) {
        $prNum = "[#$($pr.Number)]($($pr.Url))"
        $updatedText = if ($pr.UpdatedAt -gt [datetime]::MinValue) { $pr.UpdatedAt.ToUniversalTime().ToString("yyyy-MM-dd HH:mm") } else { "" }
        $row = "| $i | $(Escape-MarkdownCell $pr.Repo) | $prNum | $(Escape-MarkdownCell $pr.Title) | $(Escape-MarkdownCell $pr.Branch) | $updatedText | $(Escape-MarkdownCell $pr.Author) | $(Escape-MarkdownCell $pr.Labels) |"
        $lines.Add($row)
        $i++
    }
}

$outDir = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($outDir) -and -not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

$lines -join "`r`n" | Set-Content -Path $OutputPath -Encoding ascii
Write-Host ("Wrote {0} pending PRs to {1}" -f $ordered.Count, $OutputPath)

if ($WriteOnDesktop) {
    $markdown = Get-Content -Raw -Path $OutputPath
    $remote = Write-RemoteTextFile -Path $DesktopOutputPath -Content $markdown
    Write-Host ("Mirrored pending PR markdown to desktop: {0} (chars={1})" -f $remote.path, $remote.length)
}
