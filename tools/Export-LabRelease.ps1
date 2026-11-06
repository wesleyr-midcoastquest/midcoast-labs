#Requires -Version 7.2
<#
.SYNOPSIS
    Exports a release of the product (no site, no ledger) into a folder, for the public repo.

.DESCRIPTION
    Takes the files of a commit (default HEAD) from git, not the working tree, so only
    committed work is exported. Leaves out everything that describes one lab:
      inventory/site.yaml, inventory/instances.yaml, terraform/.terraform.lock.hcl,
      tools/release-deny.txt
    and writes an empty ledger in its place. Everything in -Destination except .git is
    replaced, so files removed from the product disappear there too.

    Then it scans the result, and refuses (deleting nothing, but listing the hits) if any
    file contains:
      - a pattern from tools/release-deny.txt (this site's names, addresses, accounts), or
      - something shaped like a secret: a Tailscale or GitHub key, a private key, a
        Proxmox token with its secret.

.EXAMPLE
    ./tools/Export-LabRelease.ps1 -Destination ../midcoast-labs
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Destination,
    [string] $Ref = 'HEAD'
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$exclude = @('inventory/site.yaml', 'inventory/instances.yaml', 'terraform/.terraform.lock.hcl', 'tools/release-deny.txt')

$release = (Select-String -Path (Join-Path $repo 'inventory/lab.yaml') -Pattern '^release:\s*"?([A-Za-z0-9-]+)' -List).Matches[0].Groups[1].Value
if (-not $release) { throw 'lab.yaml has no release.' }

# docs/scripts.md is generated from the scripts' help; a release must ship it current.
& (Join-Path $PSScriptRoot 'New-LabScriptReference.ps1') -Check
if ($LASTEXITCODE -ne 0) { throw 'docs/scripts.md is out of date: run ./tools/New-LabScriptReference.ps1, commit, and export again.' }

New-Item -ItemType Directory -Path $Destination -Force | Out-Null
$dest = (Resolve-Path $Destination).Path
Get-ChildItem -Path $dest -Force | Where-Object Name -ne '.git' | Remove-Item -Recurse -Force

# The commit's files, through git archive (binary-safe, honours .gitattributes).
$zip = Join-Path ([IO.Path]::GetTempPath()) "midcoast-release-$([guid]::NewGuid()).zip"
try {
    & git -C $repo archive --format=zip -o $zip $Ref
    if ($LASTEXITCODE -ne 0) { throw "git archive $Ref failed." }
    Expand-Archive -Path $zip -DestinationPath $dest -Force
} finally { Remove-Item $zip -Force -ErrorAction SilentlyContinue }
foreach ($e in $exclude) { Remove-Item -Path (Join-Path $dest $e) -Force -ErrorAction SilentlyContinue }

# An empty ledger: a new site starts with no machines.
$ledger = @'
# Instance ledger. WRITTEN BY THE PIPELINE; do not edit by hand.
# A new site starts empty; commit it after every pipeline run.
instances: []
templates: []
'@
Set-Content -Path (Join-Path $dest 'inventory/instances.yaml') -Value $ledger -Encoding utf8NoBOM

# Scan.
$deny = @(Get-Content (Join-Path $repo 'tools/release-deny.txt') -ErrorAction SilentlyContinue |
    Where-Object { $_ -and $_ -notmatch '^\s*#' })
$secret = @(
    'tskey-(auth|api|client)-[A-Za-z0-9]+'
    'gh[pousr]_[A-Za-z0-9]{30,}'
    'github_pat_[A-Za-z0-9_]{30,}'
    '-----BEGIN [A-Z ]*PRIVATE KEY-----'
    'PVEAPIToken=[^\s"''$<]+=[0-9a-f]{8}-[0-9a-f]{4}-'
)
$hits = foreach ($f in Get-ChildItem -Path $dest -Recurse -File -Force | Where-Object { $_.FullName -notlike "*$([IO.Path]::DirectorySeparatorChar).git$([IO.Path]::DirectorySeparatorChar)*" }) {
    foreach ($p in @($deny) + $secret) {
        foreach ($m in @(Select-String -Path $f.FullName -Pattern $p -AllMatches -ErrorAction SilentlyContinue)) {
            "{0}:{1}  matches {2}" -f ([IO.Path]::GetRelativePath($dest, $f.FullName)), $m.LineNumber, $(if ($secret -contains $p) { 'a secret pattern' } else { 'a release-deny pattern' })
        }
    }
}
if ($hits) {
    $hits | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    throw "Not exported cleanly: $(@($hits).Count) hit(s) above. Fix them in the private repo and export again; don't commit $dest as it is."
}
$sha = (& git -C $repo rev-parse --short $Ref).Trim()
Write-Host "Exported $release ($sha) to $dest; scan clean." -ForegroundColor Green
[pscustomobject]@{ Release = $release; Commit = $sha; Destination = $dest }
