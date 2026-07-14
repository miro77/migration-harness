<#
.SYNOPSIS
  Installs the autonomous work harness into a target repository.

.PARAMETER TargetDir
  Target repository directory. Defaults to the current directory.

.PARAMETER Force
  Overwrite existing harness files. This is a wholesale overwrite, not a merge.

.EXAMPLE
  .\install.ps1 -TargetDir C:\src\my-project
  .\install.ps1 . -Force
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string] $TargetDir = '.',
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Add-Utf8Line {
    param([string] $Path, [string] $Line)

    $newline = [Environment]::NewLine
    if (Test-Path -LiteralPath $Path) {
        $current = [IO.File]::ReadAllText($Path)
        if ($current.Length -gt 0 -and -not $current.EndsWith("`n") -and -not $current.EndsWith("`r")) {
            [IO.File]::AppendAllText($Path, $newline, $script:utf8NoBom)
        }
        [IO.File]::AppendAllText($Path, $Line + $newline, $script:utf8NoBom)
    }
    else {
        [IO.File]::WriteAllText($Path, $Line + $newline, $script:utf8NoBom)
    }
}

$distributionRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$source = Join-Path $distributionRoot 'template'
if (-not (Test-Path -LiteralPath (Join-Path $source '.claude\hooks'))) {
    Write-Error "install: template not found next to install.ps1 ($source)"
    exit 1
}

New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
$target = (Resolve-Path -LiteralPath $TargetDir).Path.TrimEnd('\', '/')
$source = (Resolve-Path -LiteralPath $source).Path.TrimEnd('\', '/')
if ([StringComparer]::OrdinalIgnoreCase.Equals($target, $source)) {
    Write-Error 'install: target must differ from the template directory'
    exit 1
}

Write-Host 'Installing harness'
Write-Host "  from: $source"
Write-Host "  into: $target"

$files = @(Get-ChildItem -LiteralPath $source -Recurse -Force -File)
$entries = foreach ($file in $files) {
    $relative = $file.FullName.Substring($source.Length).TrimStart('\', '/')
    [PSCustomObject]@{ Source = $file.FullName; Relative = $relative }
}
$clashes = @($entries | Where-Object { Test-Path -LiteralPath (Join-Path $target $_.Relative) })
if ($clashes.Count -gt 0 -and -not $Force) {
    [Console]::Error.WriteLine('install: these files already exist in the target (re-run with -Force to overwrite):')
    foreach ($clash in $clashes) { [Console]::Error.WriteLine("  $($clash.Relative)") }
    if ($clashes.Relative -contains 'CLAUDE.md' -or $clashes.Relative -contains '.claude\settings.json') {
        [Console]::Error.WriteLine('install: NOTE - -Force OVERWRITES wholesale; it does not merge. Back up CLAUDE.md / .claude/settings.json and merge your content back by hand.')
    }
    exit 1
}

foreach ($entry in $entries) {
    $destination = Join-Path $target $entry.Relative
    $parent = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    Copy-Item -LiteralPath $entry.Source -Destination $destination -Force
}

$gitignore = Join-Path $target '.gitignore'
$gitignoreLines = if (Test-Path -LiteralPath $gitignore) { @(Get-Content -LiteralPath $gitignore) } else { @() }
if ($gitignoreLines -notcontains '.harness/') {
    Add-Utf8Line -Path $gitignore -Line '.harness/'
    Write-Host "  + added '.harness/' to .gitignore"
}

$attributes = Join-Path $target '.gitattributes'
$rules = @('*.sh text eol=lf', '*.ps1 text eol=lf', 'harness.env text eol=lf')
foreach ($rule in $rules) {
    $normalized = if (Test-Path -LiteralPath $attributes) {
        @(Get-Content -LiteralPath $attributes | ForEach-Object { ($_ -replace '[\t ]+', ' ').Trim() })
    }
    else { @() }
    if ($normalized -notcontains $rule) {
        Add-Utf8Line -Path $attributes -Line $rule
        Write-Host "  + added '$rule' to .gitattributes"
    }
}

Write-Host ''
Write-Host '== status =='
try {
    . (Join-Path $target 'migration\tools\_git-bash.ps1')
    $bash = Get-HarnessBash
    Push-Location $target
    try { & $bash --login -c 'exec "$@"' harness 'migration/tools/doctor.sh' } finally { Pop-Location }
}
catch {
    Write-Warning "status check skipped: $($_.Exception.Message)"
}

Write-Host ''
Write-Host 'Next steps (see GETTING-STARTED.md):'
Write-Host '  1. Edit migration\harness.env     - set HARNESS_SCOPE and HARNESS_FROZEN'
Write-Host '  2. Configure migration\tools\gates.sh for your stack (it ships failing)'
Write-Host '  3. Fill the <...> placeholders in CLAUDE.md / migration\*.md'
Write-Host '  4. Verify:  .\test\run-all.ps1'
exit 0
