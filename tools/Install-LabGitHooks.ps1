#Requires -Version 7.2
<#
.SYNOPSIS
    Installs the pre-push hook that runs Test-LabPublicTree.ps1 on every push
    from this clone of the product, with your site's deny list.

.DESCRIPTION
    Run it once in every clone of the product you push from (your workstation,
    a development clone). Once a branch reaches GitHub it is public: this hook
    is the only check that runs before that, and the only one that knows your
    site's private patterns. For each branch being pushed it runs
      Test-LabPublicTree.ps1 -Base <remote commit> -Head <local commit> -UseSiteDenyList
    which refuses site files, secrets and lines matching your deny list
    (deny.txt in $env:MIDCOAST_LAB_SITE, or else site/deny.txt), and stops the
    push on any hit. Needs pwsh on the PATH of the shell git runs hooks in.

    It refuses to replace a pre-push hook it didn't install, unless -Force.
    git push --no-verify skips the hook; don't.

.PARAMETER Force
    Replace an existing pre-push hook that this script didn't install.

.EXAMPLE
    ./tools/Install-LabGitHooks.ps1
#>
[CmdletBinding()]
param(
    [switch] $Force
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git is not on the PATH.' }
$hooks = (& git -C $repo rev-parse --git-path hooks)
if ($LASTEXITCODE -ne 0) { throw "$repo isn't a git repository." }
if (-not [IO.Path]::IsPathRooted($hooks)) { $hooks = Join-Path $repo $hooks }
New-Item -ItemType Directory -Path $hooks -Force | Out-Null
$hook = Join-Path $hooks 'pre-push'
$marker = '# Installed by tools/Install-LabGitHooks.ps1'

if ((Test-Path $hook) -and -not (Select-String -Path $hook -SimpleMatch $marker -Quiet) -and -not $Force) {
    throw "$hook exists and wasn't installed by this script. Merge it by hand, or run again with -Force to replace it."
}

# git passes "<local ref> <local sha> <remote ref> <remote sha>" per ref on stdin.
$body = @"
#!/bin/sh
$marker
# Runs tools/Test-LabPublicTree.ps1 on the commits being pushed, with the
# site's deny list; any hit stops the push. (pwsh gets /dev/null as stdin,
# so it leaves the ref list to this loop.)
z=0000000000000000000000000000000000000000
top=`$(git rev-parse --show-toplevel) || exit 1
command -v pwsh >/dev/null 2>&1 || { echo "pre-push: pwsh is not on the PATH; can't check the push." >&2; exit 1; }
while read lref lsha rref rsha; do
  [ "`$lsha" = "`$z" ] && continue
  if [ "`$rsha" = "`$z" ]; then
    pwsh -NoProfile -File "`$top/tools/Test-LabPublicTree.ps1" -Head "`$lsha" -UseSiteDenyList </dev/null || exit 1
  else
    pwsh -NoProfile -File "`$top/tools/Test-LabPublicTree.ps1" -Head "`$lsha" -Base "`$rsha" -UseSiteDenyList </dev/null || exit 1
  fi
done
exit 0
"@
# LF line endings: Git for Windows runs hooks with its own sh.
[IO.File]::WriteAllText($hook, ($body -replace "`r`n", "`n"))
if (-not $IsWindows) { & chmod +x $hook }
Write-Host "Installed $hook" -ForegroundColor Green
