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

function Invoke-InstallRollback {
    param(
        [string] $TargetRoot,
        [string] $BackupFiles,
        [Collections.Generic.List[string]] $NewOutputs,
        [Collections.Generic.List[string]] $ExistingOutputs,
        [Collections.Generic.HashSet[string]] $NewDirectories,
        [Collections.Generic.List[string]] $RollbackFailures
    )

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        foreach ($relative in $NewOutputs) {
            $path = Join-Path $TargetRoot $relative
            if (Test-Path -LiteralPath $path) {
                try { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
                catch { $RollbackFailures.Add("remove ${relative}: $($_.Exception.Message)") }
            }
        }
        foreach ($relative in $ExistingOutputs) {
            $destination = Join-Path $TargetRoot $relative
            $parent = Split-Path -Parent $destination
            try {
                if (-not (Test-Path -LiteralPath $parent)) {
                    New-Item -ItemType Directory -Force -Path $parent -ErrorAction Stop | Out-Null
                }
                Copy-Item -LiteralPath (Join-Path $BackupFiles $relative) -Destination $destination -Force -ErrorAction Stop
            }
            catch { $RollbackFailures.Add("restore ${relative}: $($_.Exception.Message)") }
        }
        foreach ($directory in @($NewDirectories) | Sort-Object Length -Descending) {
            if (Test-Path -LiteralPath $directory) {
                try { Remove-Item -LiteralPath $directory -Force -ErrorAction Stop }
                catch { $RollbackFailures.Add("remove directory ${directory}: $($_.Exception.Message)") }
            }
        }
    }
    finally {
        $ErrorActionPreference = $previousPreference
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

# Snapshot every output this invocation can touch before the first write. A
# failed -Force install must not leave a mixture of old and new harness files.
$outputRelatives = @($entries.Relative) + @('.gitignore', '.gitattributes') |
    Sort-Object -Unique
$backupRoot = Join-Path ([IO.Path]::GetTempPath()) ('harness-install-' + [guid]::NewGuid().ToString('N'))
$backupFiles = Join-Path $backupRoot 'files'
New-Item -ItemType Directory -Force -Path $backupFiles | Out-Null
$existingOutputs = [Collections.Generic.List[string]]::new()
$newOutputs = [Collections.Generic.List[string]]::new()
$newDirectories = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

$script:installWriteCount = 0
$script:installFailAfter = 0
if ($env:HARNESS_INSTALL_FAIL_AFTER) {
    $parsedFailAfter = 0
    if ([int]::TryParse($env:HARNESS_INSTALL_FAIL_AFTER, [ref]$parsedFailAfter) -and $parsedFailAfter -gt 0) {
        $script:installFailAfter = $parsedFailAfter
    }
}
function Complete-InstallWrite {
    $script:installWriteCount++
    if ($script:installFailAfter -gt 0 -and $script:installWriteCount -eq $script:installFailAfter) {
        throw "injected failure after write $($script:installWriteCount)"
    }
}

$installFailure = $null
$rollbackFailures = [Collections.Generic.List[string]]::new()
$transactionActive = $false
$rollbackAttempted = $false
$completed = $false
try {
    $checkedParents = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($relative in $outputRelatives) {
        $destination = Join-Path $target $relative
        $destinationItem = Get-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
        if ($null -ne $destinationItem -and
            ($destinationItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "install: output path traverses a symlink or reparse point, refusing: $relative"
        }
        if ($null -ne $destinationItem -and $destinationItem.PSIsContainer) {
            throw "install: output path is a directory, expected a file: $relative"
        }
        if ($null -ne $destinationItem) {
            $backup = Join-Path $backupFiles $relative
            $backupParent = Split-Path -Parent $backup
            if (-not (Test-Path -LiteralPath $backupParent)) {
                New-Item -ItemType Directory -Force -Path $backupParent | Out-Null
            }
            Copy-Item -LiteralPath $destination -Destination $backup -Force
            $existingOutputs.Add($relative)
        }
        else {
            $newOutputs.Add($relative)
        }

        $parent = Split-Path -Parent $destination
        while ($parent.Length -gt $target.Length -and $parent.StartsWith($target, [StringComparison]::OrdinalIgnoreCase)) {
            if ($checkedParents.Add($parent)) {
                $parentItem = Get-Item -LiteralPath $parent -Force -ErrorAction SilentlyContinue
                if ($null -ne $parentItem -and
                    ($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "install: output path traverses a symlink or reparse point, refusing: $relative"
                }
                if ($null -eq $parentItem) { [void]$newDirectories.Add($parent) }
            }
            $parent = Split-Path -Parent $parent
        }
    }

    $transactionActive = $true
    foreach ($entry in $entries) {
        $destination = Join-Path $target $entry.Relative
        $parent = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
        }
        Copy-Item -LiteralPath $entry.Source -Destination $destination -Force
        Complete-InstallWrite
    }

    $gitignore = Join-Path $target '.gitignore'
    $gitignoreLines = if (Test-Path -LiteralPath $gitignore) { @(Get-Content -LiteralPath $gitignore) } else { @() }
    if ($gitignoreLines -notcontains '.harness/') {
        Add-Utf8Line -Path $gitignore -Line '.harness/'
        Complete-InstallWrite
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
            Complete-InstallWrite
            Write-Host "  + added '$rule' to .gitattributes"
        }
    }
    $completed = $true
}
catch {
    $installFailure = $_
    if ($transactionActive) {
        $rollbackAttempted = $true
        Invoke-InstallRollback -TargetRoot $target -BackupFiles $backupFiles `
            -NewOutputs $newOutputs -ExistingOutputs $existingOutputs `
            -NewDirectories $newDirectories -RollbackFailures $rollbackFailures
    }
}
finally {
    # Ctrl-C stops the pipeline without entering catch, but PowerShell still runs
    # finally. Roll back here when the copy phase began but never completed.
    if (-not $completed -and $transactionActive -and -not $rollbackAttempted) {
        $rollbackAttempted = $true
        Invoke-InstallRollback -TargetRoot $target -BackupFiles $backupFiles `
            -NewOutputs $newOutputs -ExistingOutputs $existingOutputs `
            -NewDirectories $newDirectories -RollbackFailures $rollbackFailures
    }
    if ($rollbackFailures.Count -eq 0) {
        Remove-Item -LiteralPath $backupRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    else {
        [Console]::Error.WriteLine("install: recovery backup retained at: $backupRoot")
    }
}

if ($installFailure) {
    if (-not $transactionActive) {
        $message = "install: failed before modifying the target ($($installFailure.Exception.Message))"
    }
    elseif ($rollbackFailures.Count -eq 0) {
        $message = "install: failed; restored the target to its pre-install state ($($installFailure.Exception.Message))"
    }
    else {
        $message = "install: failed; ROLLBACK INCOMPLETE ($($installFailure.Exception.Message)); rollback failures: $($rollbackFailures -join '; ')"
    }
    [Console]::Error.WriteLine($message)
    exit 1
}

Write-Host ''
Write-Host '== status =='
try {
    . (Join-Path $target 'migration\tools\_git-bash.ps1')
    $bash = Get-HarnessBash
    Push-Location $target
    try { Invoke-HarnessBash -Bash $bash -Command @('migration/tools/doctor.sh') } finally { Pop-Location }
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
