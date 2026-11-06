#Requires -Version 7.2
<#
.SYNOPSIS
    Generates docs/scripts.md: every script in the repo, its parameters and
    switches, where it runs and when, from the scripts' own help.

.DESCRIPTION
    The scripts are the source. For each .ps1 it reads the comment-based help
    (.SYNOPSIS, .DESCRIPTION, .PARAMETER, .EXAMPLE), the #Requires lines and the
    param() block (name, type, default, ValidateSet, mandatory, and the comment
    above a parameter when it has no .PARAMETER entry); for each .sh the header
    comment and its "bash ..." usage lines. Where a script runs comes from its
    folder (orchestration -> the active MGMT, setup/mgmt -> MGMT-00, and so on).

    Run it after changing any script's parameters or help, and commit the result
    with the change. It refuses a .ps1 without a .SYNOPSIS, so every script stays
    documented. Export-LabRelease.ps1 runs it with -Check and refuses to export
    while docs/scripts.md is out of date.

.PARAMETER Check
    Don't write; exit 1 if docs/scripts.md differs from what would be written.

.EXAMPLE
    ./tools/New-LabScriptReference.ps1           # writes docs/scripts.md
.EXAMPLE
    ./tools/New-LabScriptReference.ps1 -Check    # CI / pre-release check
#>
[CmdletBinding()]
param(
    [switch] $Check
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$out  = Join-Path $repo 'docs/scripts.md'

# Where each folder's scripts run, and how they are started. Order = document order.
$groups = @(
    @{ Dir = 'orchestration'; Title = 'Orchestration: the pipeline';      Runs = 'On the active MGMT, in PowerShell 7, from `C:\MidCoastLab\repo`. Every entry point validates the inventory and the live site first, writes a transcript to `C:\ProgramData\MidCoastLab\Logs\Orchestration`, and asks for the vault''s master password when the vault is locked.' }
    @{ Dir = 'setup';         Title = 'Setup: workstation and MGMT-00';    Runs = '`New-LabSiteKit.ps1` on your workstation (PowerShell 7 + powershell-yaml); the `setup/mgmt` scripts on MGMT-00, once each, in the order the runbook gives.' }
    @{ Dir = 'setup/proxmox'; Title = 'Setup: the Proxmox node';           Runs = 'On the lab''s Proxmox node, as root. Run the site kit''s copy of `proxmox-setup.sh` (it carries your values); `proxmox-teardown.sh` runs as it is.' }
    @{ Dir = 'tools';         Title = 'Tools: maintaining the repo';       Runs = 'On the machine where you prepare releases (PowerShell 7 and git).' }
    @{ Dir = 'platform';      Title = 'Platform: inside every guest';      Runs = 'Pushed into each guest by the orchestrator and run by the `MidCoastLab-Bootstrap` task as SYSTEM. Not run by hand, except `validate.ps1` (on a guest, elevated) and `tailscale/Enable-LabTailscaleWatchdog.ps1`.' }
    @{ Dir = 'packer';        Title = 'Packer: inside the template build'; Runs = 'Run by Packer inside the build VM (`Build-LabTemplate.ps1` starts Packer). Not run by hand.' }
)

function Get-HelpSections([string] $Text) {
    # The first block comment that has a .SYNOPSIS, split into its sections.
    $m = [regex]::Match($Text, '(?s)<#(.*?)#>')
    $sections = [ordered]@{}
    if (-not $m.Success -or $m.Groups[1].Value -notmatch '\.SYNOPSIS') { return $sections }
    $body = $m.Groups[1].Value
    foreach ($s in [regex]::Matches($body, '(?ms)^\s*\.(?<name>[A-Z]+)(?:\s+(?<arg>\S+))?\s*$(?<text>.*?)(?=^\s*\.[A-Z]+(?:\s+\S+)?\s*$|\z)')) {
        $key = $s.Groups['name'].Value
        if ($s.Groups['arg'].Success) { $key += ' ' + $s.Groups['arg'].Value }
        # Strip the common indent and trailing blank lines.
        $lines = @($s.Groups['text'].Value -split "`r?`n")
        $indent = @($lines | Where-Object { $_.Trim() } | ForEach-Object { ($_ -replace '\S.*$', '').Length } | Measure-Object -Minimum).Minimum
        $text = (($lines | ForEach-Object { if ($_.Length -ge $indent) { $_.Substring($indent) } else { $_.TrimStart() } }) -join "`n").Trim()
        if ($sections.Contains($key)) { $sections[$key] += "`n`n" + $text } else { $sections[$key] = $text }
    }
    $sections
}

function Get-ParamRows([string] $Path, [string] $Text, $Help) {
    # Parameters from the script's param() block, via the PowerShell parser.
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref] $tokens, [ref] $errors)
    if ($errors.Count -gt 0) { throw "$Path doesn't parse: $($errors[0].Message)" }
    if (-not $ast.ParamBlock) { return @() }
    $lines = $Text -split "`r?`n"
    $prevEnd = $ast.ParamBlock.Extent.StartLineNumber
    foreach ($p in $ast.ParamBlock.Parameters) {
        $name = $p.Name.VariablePath.UserPath
        $type = 'object'; $default = ''; $mandatory = $false; $set = $null
        foreach ($a in $p.Attributes) {
            if ($a -is [System.Management.Automation.Language.TypeConstraintAst]) { $type = $a.TypeName.Name }
            elseif ($a.TypeName.Name -eq 'Parameter' -and ($a.NamedArguments | Where-Object { $_.ArgumentName -eq 'Mandatory' })) { $mandatory = $true }
            elseif ($a.TypeName.Name -eq 'ValidateSet') { $set = @($a.PositionalArguments | ForEach-Object { $_.Value }) }
        }
        if ($p.DefaultValue) { $default = $p.DefaultValue.Extent.Text }
        if ($type -eq 'switch') { $default = '' }
        # Description: .PARAMETER help, else the comment lines just above the parameter.
        $desc = ''
        if ($Help.Contains("PARAMETER $name")) { $desc = $Help["PARAMETER $name"] }
        else {
            $above = @()
            for ($i = $p.Extent.StartLineNumber - 2; $i -ge $prevEnd - 1; $i--) {
                $l = $lines[$i].Trim()
                if ($l -match '^#\s?(.*)$') { $above = @($Matches[1]) + $above } elseif ($l -eq '' -or $l -eq ',') { continue } else { break }
            }
            $desc = ($above -join ' ').Trim()
        }
        $prevEnd = $p.Extent.EndLineNumber
        $usage = if ($type -eq 'switch') { "-$name" } elseif ($set) { "-$name <$($set -join ' | ')>" } else { "-$name <$type>" }
        [pscustomobject]@{
            Usage     = $usage
            Required  = $mandatory
            Default   = $default
            Text      = ($desc -replace '\s+', ' ')
        }
    }
}

function Get-ShellUsage([string] $Text) {
    # The header comment (up to the first blank or code line) and its "bash ..." lines.
    $header = @(); $usage = @()
    foreach ($l in ($Text -split "`r?`n") | Select-Object -Skip 1) {
        if ($l -notmatch '^#') { break }
        $c = $l -replace '^#\s?', ''
        if ($c -match '^\s*bash ') { $usage += $c.Trim() } else { $header += $c }
    }
    # The synopsis: the first paragraph, up to its first full stop.
    $para = @(); foreach ($l in $header) { if ($l.Trim()) { $para += $l.Trim() } elseif ($para.Count -gt 0) { break } }
    $first = ($para -join ' ') -replace '^[\w.-]+\.sh:\s*', ''
    $synopsis = ($first -split '(?<=\.)\s', 2)[0]
    [pscustomobject]@{ Header = ((($header -join "`n") -replace "`n{3,}", "`n`n").Trim()); Usage = $usage; Synopsis = $synopsis }
}

function Format-Cell([string] $s) { ($s -replace '\|', '\|' -replace "`r?`n", ' ').Trim() }
$bt = [char] 96   # a backtick, for markdown code spans inside double-quoted strings

$md = [System.Text.StringBuilder]::new()
$null = $md.AppendLine('# Scripts: every script, its switches and where it runs')
$null = $md.AppendLine()
$null = $md.AppendLine('<!-- GENERATED by tools/New-LabScriptReference.ps1 from the scripts'' own help. Edit the script, then regenerate. -->')
$null = $md.AppendLine()
$null = $md.AppendLine('The scripts'' comment-based help is the source of this page; `./tools/New-LabScriptReference.ps1` regenerates it, and `-Check` tells you when it is stale. `Get-Help ./path/to/script.ps1 -Full` shows the same text on MGMT.')
$null = $md.AppendLine()
$null = $md.AppendLine('| Script | What it does | Where |')
$null = $md.AppendLine('|---|---|---|')
$index = [System.Text.StringBuilder]::new()
$body  = [System.Text.StringBuilder]::new()

$seen = @{}
foreach ($g in $groups) {
    $dir = Join-Path $repo $g.Dir
    $files = @(Get-ChildItem -Path $dir -Recurse -File -Include '*.ps1', '*.sh' | Where-Object { -not $seen.ContainsKey($_.FullName) } | Sort-Object { $_.FullName.Replace('\', '/').Substring($dir.Length).Split('/').Count }, FullName)
    # setup/ contains setup/proxmox: that group is listed on its own.
    if ($g.Dir -eq 'setup') { $files = @($files | Where-Object { $_.FullName -notmatch '[\\/]proxmox[\\/]' }) }
    if ($files.Count -eq 0) { continue }
    $null = $body.AppendLine("## $($g.Title)")
    $null = $body.AppendLine()
    $null = $body.AppendLine($g.Runs)
    $null = $body.AppendLine()
    foreach ($f in $files) {
        $seen[$f.FullName] = $true
        $rel  = $f.FullName.Substring($repo.Length + 1).Replace('\', '/')
        $text = Get-Content -Raw -Path $f.FullName
        $null = $body.AppendLine("### $bt$rel$bt")
        $null = $body.AppendLine()
        if ($f.Extension -eq '.sh') {
            $u = Get-ShellUsage $text
            $null = $index.AppendLine("| $bt$rel$bt | $(Format-Cell $u.Synopsis) | node, root |")
            $null = $body.AppendLine($u.Header)
            if ($u.Usage.Count -gt 0) {
                $null = $body.AppendLine(); $null = $body.AppendLine('```bash')
                $u.Usage | ForEach-Object { $null = $body.AppendLine($_) }
                $null = $body.AppendLine('```')
            }
            $null = $body.AppendLine()
            continue
        }
        $help = Get-HelpSections $text
        if (-not $help.Contains('SYNOPSIS')) { throw "$rel has no comment-based help (.SYNOPSIS). Add it; every script is documented from its own help." }
        $requires = @([regex]::Matches($text, '(?m)^#Requires\s+(.+)$') | ForEach-Object { $_.Groups[1].Value.Trim() })
        $where = @()
        if ($requires -contains '-RunAsAdministrator') { $where += 'elevated' }
        $v = @($requires | Where-Object { $_ -like '-Version*' })[0]
        if ($v) { $where += $(if ($v -match '7') { 'PowerShell 7' } else { 'Windows PowerShell 5.1 or 7' }) }
        $null = $index.AppendLine("| $bt$rel$bt | $(Format-Cell ($help['SYNOPSIS'] -replace '\s+', ' ')) | $(Format-Cell ($where -join ', ')) |")
        $null = $body.AppendLine(($help['SYNOPSIS'] -replace '\s+', ' '))
        if ($where.Count -gt 0) { $null = $body.AppendLine(); $null = $body.AppendLine("Runs: $($where -join ', ').") }
        if ($help.Contains('DESCRIPTION')) { $null = $body.AppendLine(); $null = $body.AppendLine($help['DESCRIPTION']) }
        $rows = @(Get-ParamRows -Path $f.FullName -Text $text -Help $help)
        if ($rows.Count -gt 0) {
            $null = $body.AppendLine(); $null = $body.AppendLine('| Parameter | Required | Default | Meaning |'); $null = $body.AppendLine('|---|---|---|---|')
            foreach ($r in $rows) {
                $null = $body.AppendLine("| $bt$($r.Usage)$bt | $(if ($r.Required) { 'yes' } else { '' }) | $(if ($r.Default) { "$bt$(Format-Cell $r.Default)$bt" } else { '' }) | $(Format-Cell $r.Text) |")
            }
        }
        $examples = @($help.Keys | Where-Object { $_ -eq 'EXAMPLE' } | ForEach-Object { $help[$_] })
        if ($examples.Count -gt 0) {
            $null = $body.AppendLine(); $null = $body.AppendLine('```powershell')
            ($examples -join "`n`n") -split "`n`n" | ForEach-Object { $null = $body.AppendLine($_) }
            $null = $body.AppendLine('```')
        }
        $null = $body.AppendLine()
    }
}
$null = $md.Append($index.ToString())
$null = $md.AppendLine()
$null = $md.Append($body.ToString())
$content = ($md.ToString() -replace "`r`n", "`n").TrimEnd() + "`n"

if ($Check) {
    $current = if (Test-Path $out) { (Get-Content -Raw -Path $out) -replace "`r`n", "`n" } else { '' }
    if ($current -ne $content) { Write-Host "docs/scripts.md is out of date; run ./tools/New-LabScriptReference.ps1 and commit it." -ForegroundColor Red; exit 1 }
    Write-Host 'docs/scripts.md is up to date.' -ForegroundColor Green
    exit 0   # a clear exit code for callers (Export-LabRelease) and CI
}
[System.IO.File]::WriteAllText($out, $content, [System.Text.UTF8Encoding]::new($false))
Write-Host "Wrote $out ($($seen.Count) scripts)." -ForegroundColor Green
