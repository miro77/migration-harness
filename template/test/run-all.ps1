# Windows entry point for the harness's complete Bash test surface.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try {
    . (Join-Path $PSScriptRoot '..\migration\tools\_git-bash.ps1')
    $root = Get-HarnessRoot -StartPath $PSScriptRoot
    $bash = Get-HarnessBash
    Push-Location $root
    try { & $bash --login -c 'exec "$@"' harness 'test/run-all.sh' @args; $code = $LASTEXITCODE } finally { Pop-Location }
    exit $code
}
catch {
    [Console]::Error.WriteLine("run-all.ps1: $($_.Exception.Message)")
    exit 2
}
