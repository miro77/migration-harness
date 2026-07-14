# Windows entry point for the read-only doctor.sh report.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try {
    . (Join-Path $PSScriptRoot '_git-bash.ps1')
    $root = Get-HarnessRoot -StartPath $PSScriptRoot
    $bash = Get-HarnessBash
    Push-Location $root
    try { & $bash --login -c 'exec "$@"' harness 'migration/tools/doctor.sh' @args; $code = $LASTEXITCODE } finally { Pop-Location }
    exit $code
}
catch {
    [Console]::Error.WriteLine("doctor.ps1: $($_.Exception.Message)")
    exit 2
}
