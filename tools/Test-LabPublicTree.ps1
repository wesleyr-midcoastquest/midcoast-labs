#Requires -Version 7.2
<#
.SYNOPSIS
    Checks that a commit (or the commits about to be pushed) holds nothing that
    belongs to one site: no site files, no secrets, no private patterns.

.DESCRIPTION
    The product repo is public and shared by every site; each site's own files
    live in its site folder (site/, its own repo), never in the product. This
    refuses, listing every hit:
      - a forbidden path: site/, inventory/site.yaml, *.kdbx, *.tfstate*,
        passwords*, and inventory/instances.yaml unless it is the empty ledger
        (instances: [] and templates: [] only);
      - a line shaped like a secret: a Tailscale or GitHub key, a private key,
        a Proxmox token with its secret;
      - with -DenyPath or -UseSiteDenyList, a line matching a pattern from a
        site's private deny list (one regular expression per line, # comments).
    Without -Head it checks the whole tree of -Ref (default HEAD). With -Head it
    checks every commit being pushed: each path they add or change, and each
    line they add, from -Base (the remote's commit) to -Head, or, without
    -Base, every commit of -Head that no remote-tracking branch has yet. The
    tree of -Head gets the path check too.
    Then it runs New-LabScriptReference.ps1 -Check: docs/scripts.md must be
    current. Exits 1 on any hit.

    The pre-push hook from Install-LabGitHooks.ps1 runs it with -Head, -Base
    and -UseSiteDenyList before every push: once a branch reaches GitHub it is
    public, so that hook is the only check that runs before a leak, and the
    only one that knows your private patterns.

.PARAMETER Ref
    The commit whose whole tree is checked when -Head isn't given.

.PARAMETER Base
    With -Head: the commit the remote already has; only what comes after it
    is checked.

.PARAMETER Head
    The commit being pushed. Checks the commits from -Base to it.

.PARAMETER DenyPath
    A private deny list to scan with as well.

.PARAMETER UseSiteDenyList
    Also scan with the site's deny list, when there is one: deny.txt in the
    folder named by $env:MIDCOAST_LAB_SITE, or else site/deny.txt.

.EXAMPLE
    ./tools/Test-LabPublicTree.ps1                      # the tree of HEAD: paths and secrets
.EXAMPLE
    ./tools/Test-LabPublicTree.ps1 -DenyPath site/deny.txt -Base origin/master -Head HEAD
#>
[CmdletBinding()]
param(
    [string] $Ref = 'HEAD',
    [string] $Base,
    [string] $Head,
    [string] $DenyPath,
    [switch] $UseSiteDenyList
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent

function Invoke-Git {
    $out = & git -C $repo @args
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed (exit $LASTEXITCODE)." }
    $out
}

# ── What to scan with ──────────────────────────────────────────────────────
$secret = @(
    'tskey-(auth|api|client)-[A-Za-z0-9]+'
    'gh[pousr]_[A-Za-z0-9]{30,}'
    'github_pat_[A-Za-z0-9_]{30,}'
    '-----BEGIN [A-Z ]*PRIVATE KEY-----'
    'PVEAPIToken=[^\s"''$<]+=[0-9a-f]{8}-[0-9a-f]{4}-'
)
$denyFiles = @()
if ($DenyPath) {
    if (-not (Test-Path $DenyPath)) { throw "Deny list not found: $DenyPath" }
    $denyFiles += $DenyPath
}
if ($UseSiteDenyList) {
    $siteDeny = if ($env:MIDCOAST_LAB_SITE) { Join-Path $env:MIDCOAST_LAB_SITE 'deny.txt' } else { Join-Path $repo 'site/deny.txt' }
    if (Test-Path $siteDeny) { $denyFiles += $siteDeny } else { Write-Host "No site deny list ($siteDeny); checking paths and secrets only." }
}
$deny = @(foreach ($f in $denyFiles) { Get-Content $f | Where-Object { $_ -and $_ -notmatch '^\s*#' } })

# ── Forbidden paths ────────────────────────────────────────────────────────
function Test-LabEmptyLedger([string] $Text) {
    # The ledger a new site starts with, as the export writes it: comments,
    # 'instances: []' and 'templates: []', nothing else.
    $lines = @($Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
    $lines.Count -eq 2 -and $lines -contains 'instances: []' -and $lines -contains 'templates: []'
}
function Get-LabPathHit([string] $Path, [string] $Commit) {
    $leaf = ($Path -split '/')[-1]
    if ($Path -like 'site/*' -or $Path -eq 'site') { return "${Path}: a site folder file (site/ belongs to the site's own repo)" }
    if ($Path -eq 'inventory/site.yaml')            { return "${Path}: a site's site.yaml" }
    if ($leaf -like '*.kdbx')                       { return "${Path}: a KeePass vault" }
    if ($leaf -like '*.tfstate*')                   { return "${Path}: Terraform state" }
    if ($leaf -like 'passwords*')                   { return "${Path}: a passwords file" }
    if ($Path -eq 'inventory/instances.yaml') {
        $text = (& git -C $repo show "${Commit}:$Path" 2>$null) -join "`n"
        if ($LASTEXITCODE -eq 0 -and -not (Test-LabEmptyLedger $text)) { return "${Path}: a site's ledger (only the empty ledger may be in the product)" }
    }
}

$hits = [System.Collections.Generic.List[string]]::new()
function Test-LabLine([string] $Where, [string] $Line) {
    foreach ($p in $secret) { if ($Line -match $p) { $hits.Add("$Where  matches a secret pattern") } }
    foreach ($p in $deny)   { if ($Line -match $p) { $hits.Add("$Where  matches a deny-list pattern") } }
}

if ($Head) {
    # ── The commits being pushed ───────────────────────────────────────────
    $headSha = (Invoke-Git rev-parse --verify "$Head^{commit}").Trim()
    $range = @($headSha)
    if ($Base) {
        & git -C $repo cat-file -e "$Base^{commit}" 2>$null
        if ($LASTEXITCODE -eq 0) { $range = @("$Base..$headSha") }
        else { Write-Warning "$Base isn't known here (fetch first?); checking every commit no remote-tracking branch has."; $Base = $null }
    }
    if (-not $Base) { $range += @('--not', '--remotes') }
    $commits = @(Invoke-Git rev-list @range)
    Write-Host "Checking $($commits.Count) commit(s) up to $($headSha.Substring(0, 12))"
    foreach ($c in $commits) {
        foreach ($p in @(Invoke-Git diff-tree --root --no-commit-id --name-only -r --no-renames --diff-filter=d $c)) {
            $h = Get-LabPathHit -Path $p -Commit $c
            if ($h) { $hits.Add("$($c.Substring(0, 12)) $h") }
        }
        # Added lines only, with their file and line number in the commit.
        $file = $null; $n = 0
        foreach ($l in @(Invoke-Git diff-tree --root --no-commit-id -p --unified=0 --no-color --no-renames --no-ext-diff $c)) {
            if ($l -match '^\+\+\+ (?:b/(.*)|/dev/null)$') { $file = $Matches[1]; continue }
            if ($l -match '^@@ -\S+ \+(\d+)') { $n = [int] $Matches[1]; continue }
            if ($file -and $l.StartsWith('+')) { Test-LabLine "$($c.Substring(0, 12)) ${file}:$n" $l.Substring(1); $n++ }
        }
    }
    $treeRef = $headSha
} else {
    $treeRef = (Invoke-Git rev-parse --verify "$Ref^{commit}").Trim()
    Write-Host "Checking the tree of $Ref ($($treeRef.Substring(0, 12)))"
    # Every file's content, from git (not the working tree), as the export did.
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "midcoast-tree-$([guid]::NewGuid())"
    $zip = "$tmp.zip"
    try {
        Invoke-Git archive --format=zip -o $zip $treeRef | Out-Null
        Expand-Archive -Path $zip -DestinationPath $tmp -Force
        foreach ($f in Get-ChildItem -Path $tmp -Recurse -File -Force) {
            $rel = [IO.Path]::GetRelativePath($tmp, $f.FullName).Replace('\', '/')
            foreach ($p in @($deny) + $secret) {
                foreach ($m in @(Select-String -Path $f.FullName -Pattern $p -AllMatches -ErrorAction SilentlyContinue)) {
                    $hits.Add("${rel}:$($m.LineNumber)  matches $(if ($secret -contains $p) { 'a secret pattern' } else { 'a deny-list pattern' })")
                }
            }
        }
    } finally {
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
foreach ($p in @(Invoke-Git ls-tree -r --name-only $treeRef)) {
    $h = Get-LabPathHit -Path $p -Commit $treeRef
    if ($h) { $hits.Add("tree: $h") }
}

# ── docs/scripts.md is generated from the scripts' help; it must be current ──
& (Join-Path $PSScriptRoot 'New-LabScriptReference.ps1') -Check
if ($LASTEXITCODE -ne 0) { $hits.Add('docs/scripts.md is out of date: run ./tools/New-LabScriptReference.ps1 and commit it.') }

if ($hits.Count) {
    $hits | Select-Object -Unique | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    Write-Host "Not clean: $(@($hits | Select-Object -Unique).Count) hit(s) above. Remove them from the commits (amend or rebase before pushing) and try again. Nothing was pushed by this check." -ForegroundColor Red
    exit 1
}
Write-Host 'Clean: no site files, secrets or deny-list matches.' -ForegroundColor Green
