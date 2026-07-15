<#
.SYNOPSIS
  Windows entry point for kick-loop.sh.

.EXAMPLE
  .\migration\tools\kick-loop.ps1 --tick
  .\migration\tools\kick-loop.ps1 --drive --max 5 --review

.NOTES
  For long unattended Windows runs, migration\run-loop.ps1 remains preferred;
  it additionally reaps orphaned Windows CLI processes and applies retry policy.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try {
    . (Join-Path $PSScriptRoot '_git-bash.ps1')
    $root = Get-HarnessRoot -StartPath $PSScriptRoot
    $bash = Get-HarnessBash
    Push-Location $root
    try { Invoke-HarnessBash -Bash $bash -Command (@('migration/tools/kick-loop.sh') + $args); $code = $LASTEXITCODE } finally { Pop-Location }
    exit $code
}
catch {
    [Console]::Error.WriteLine("kick-loop.ps1: $($_.Exception.Message)")
    exit 2
}
