# Windows entry point for gates.sh. Enforcement remains in the Bash script.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try {
    . (Join-Path $PSScriptRoot '_git-bash.ps1')
    $root = Get-HarnessRoot -StartPath $PSScriptRoot
    $bash = Get-HarnessBash
    Push-Location $root
    try { & $bash --login -c 'exec "$@"' harness 'migration/tools/gates.sh' @args; $code = $LASTEXITCODE } finally { Pop-Location }
    exit $code
}
catch {
    [Console]::Error.WriteLine("gates.ps1: $($_.Exception.Message)")
    exit 2
}
