<# Windows-side regression tests for the PowerShell installer and launchers. #>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$passed = 0
$failed = 0

function Pass([string] $Message) { Write-Host "PASS: $Message"; $script:passed++ }
function Fail([string] $Message) { Write-Host "FAIL: $Message"; $script:failed++ }
function Check([string] $Message, [bool] $Condition) {
    if ($Condition) { Pass $Message } else { Fail $Message }
}

# Windows PowerShell 5.1 turns a REDIRECTED native stderr line into a
# terminating error under this script's $ErrorActionPreference = 'Stop'.
# Every native call that captures or silences output runs through this guard,
# so one diagnostic line from a child cannot abort the suite mid-run.
function Invoke-Guarded([scriptblock] $Native) {
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Native } finally { $ErrorActionPreference = $previousPreference }
}

# Forward slashes throughout: a backslash literal in a path works only on
# Windows, and this suite also runs under pwsh on Linux (run-all.sh stage 2c).
function Find-HarnessRoot([string] $Start) {
    $directory = Get-Item -LiteralPath $Start
    while ($directory) {
        if ((Test-Path -LiteralPath (Join-Path $directory.FullName '.claude/hooks/stop-require-gates.sh')) -and
            (Test-Path -LiteralPath (Join-Path $directory.FullName 'migration/tools/working-tree-hash.sh'))) {
            return $directory.FullName
        }
        $directory = $directory.Parent
    }
    throw 'harness root not found'
}

function Find-DistributionRoot([string] $Start) {
    $directory = Get-Item -LiteralPath $Start
    while ($directory) {
        if ((Test-Path -LiteralPath (Join-Path $directory.FullName 'install.ps1')) -and
            (Test-Path -LiteralPath (Join-Path $directory.FullName 'template/.claude/hooks/stop-require-gates.sh'))) {
            return $directory.FullName
        }
        $directory = $directory.Parent
    }
    return $null
}

$harness = Find-HarnessRoot -Start $PSScriptRoot
$distribution = Find-DistributionRoot -Start $PSScriptRoot
$parseFiles = @(Get-ChildItem -LiteralPath $harness -Recurse -Force -Filter '*.ps1' -File)
if ($distribution) { $parseFiles += Get-Item -LiteralPath (Join-Path $distribution 'install.ps1') }
foreach ($file in $parseFiles) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    Check "PowerShell parses ($($file.Name))" ($errors.Count -eq 0)
}

. (Join-Path $harness 'migration/tools/_git-bash.ps1')
$bash = Get-HarnessBash
Check 'PowerShell bridge resolves Bash' (Test-Path -LiteralPath $bash -PathType Leaf)
Invoke-Guarded { & $bash --login -c 'exec dirname --version' *> $null }
Check 'resolved Bash has Unix utilities' ($LASTEXITCODE -eq 0)

# The argument bridge must forward faithfully on THIS PowerShell version:
# spaces must not word-split, globs must not expand, single quotes and empty
# arguments must survive. (Exactly what the old `-c 'exec "$@"'` bridge got
# wrong on PS 5.1, where the payload degraded to an unquoted `exec $@`.)
$echoed = @(Invoke-Guarded {
    Invoke-HarnessBash -Bash $bash -Command @('printf', '<%s>', 'a b', '*.sh', "it's", '') })
Check 'argument bridge forwards spaces/globs/quotes/empty intact' (
    ($echoed -join '') -eq "<a b><*.sh><it's><>")

foreach ($relative in @(
    'migration/tools/doctor.ps1',
    'migration/tools/gates.ps1',
    'migration/tools/kick-loop.ps1',
    'migration/run-loop.ps1',
    'test/run-all.ps1'
)) {
    Check "PowerShell entry point exists ($relative)" (Test-Path -LiteralPath (Join-Path $harness $relative))
}

$engine = (Get-Process -Id $PID).Path
$engineArgs = @('-NoProfile')
if ($PSVersionTable.PSEdition -eq 'Desktop') { $engineArgs += @('-ExecutionPolicy', 'Bypass') }
$testRoot = Join-Path $harness ('.harness/powershell-selftest-' + [guid]::NewGuid().ToString('N'))

try {
    $installed = Join-Path $testRoot 'installed'
    New-Item -ItemType Directory -Force -Path $installed | Out-Null
    Get-ChildItem -LiteralPath $harness -Force |
        Where-Object { $_.Name -notin @('.git', '.harness') } |
        Copy-Item -Destination $installed -Recurse -Force
    & git -C $installed init -q
    & git -C $installed config user.email powershell-selftest@local
    & git -C $installed config user.name powershell-selftest

    $doctorOutput = @(Invoke-Guarded { & $engine @engineArgs -File (Join-Path $installed 'migration/tools/doctor.ps1') 2>&1 })
    Check 'doctor.ps1 preserves successful exit code' ($LASTEXITCODE -eq 0)
    Check 'doctor.ps1 emits the harness report' (($doctorOutput -join "`n") -match 'harness config')

    $checkOutput = @(Invoke-Guarded { & $engine @engineArgs -File (Join-Path $installed 'migration/tools/kick-loop.ps1') '--check' 2>&1 })
    Check 'kick-loop.ps1 passes raw --arguments and exit code' ($LASTEXITCODE -eq 0)
    Check 'kick-loop.ps1 --check reports resumable state' (($checkOutput -join "`n") -match 'STATE: resume')

    # End-to-end forwarding regression: an argument containing a space must
    # arrive at the .sh as ONE argument (kick-loop.sh then reports the missing
    # prompt file by its full, unsplit name and exits 2).
    $spacedOutput = @(Invoke-Guarded { & $engine @engineArgs -File (Join-Path $installed 'migration/tools/kick-loop.ps1') '--prompt' 'no such file.md' 2>&1 })
    Check 'kick-loop.ps1 forwards an argument containing spaces intact' (
        $LASTEXITCODE -eq 2 -and (($spacedOutput -join "`n") -match 'no such file\.md'))

    $gateOutput = @(Invoke-Guarded { & $engine @engineArgs -File (Join-Path $installed 'migration/tools/gates.ps1') 2>&1 })
    Check 'gates.ps1 preserves a failing gate exit code' ($LASTEXITCODE -eq 1)
    Check 'gates.ps1 preserves gate diagnostics' (($gateOutput -join "`n").Trim().Length -gt 0)

    if ($distribution) {
        $target = Join-Path $testRoot 'native-install'
        New-Item -ItemType Directory -Force -Path $target | Out-Null
        & git -C $target init -q
        & git -C $target config user.email powershell-selftest@local
        & git -C $target config user.name powershell-selftest
        Invoke-Guarded { & $engine @engineArgs -File (Join-Path $distribution 'install.ps1') -TargetDir $target *> $null }
        Check 'install.ps1 installs into a fresh repository' ($LASTEXITCODE -eq 0)
        Check 'install.ps1 includes Windows launchers' (Test-Path -LiteralPath (Join-Path $target 'migration/tools/kick-loop.ps1'))

        Invoke-Guarded { & $engine @engineArgs -File (Join-Path $distribution 'install.ps1') -TargetDir $target *> $null }
        Check 'install.ps1 refuses to clobber without -Force' ($LASTEXITCODE -eq 1)
        Invoke-Guarded { & $engine @engineArgs -File (Join-Path $distribution 'install.ps1') -TargetDir $target -Force *> $null }
        Check 'install.ps1 -Force overwrites successfully' ($LASTEXITCODE -eq 0)
    }
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host '----------------------------------------'
Write-Host "PowerShell self-test: $passed passed, $failed failed"
if ($failed -gt 0) { exit 1 }
exit 0
