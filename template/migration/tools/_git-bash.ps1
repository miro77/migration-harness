# Shared PowerShell bridge to the harness's Bash implementation. The Bash tools
# remain the single enforcement path; these functions only resolve the correct
# shell and harness root on Windows.
Set-StrictMode -Version Latest

function Get-HarnessBash {
    [CmdletBinding()]
    param()

    $candidates = [Collections.Generic.List[string]]::new()
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git -and $git.Source) {
        $gitRoot = Split-Path -Parent (Split-Path -Parent $git.Source)
        $candidates.Add((Join-Path $gitRoot 'bin\bash.exe'))
        $candidates.Add((Join-Path $gitRoot 'usr\bin\bash.exe'))
    }
    if (${env:ProgramFiles}) {
        $candidates.Add((Join-Path ${env:ProgramFiles} 'Git\bin\bash.exe'))
    }
    if (${env:ProgramFiles(x86)}) {
        $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe'))
    }
    $isWindowsHost = ${env:OS} -eq 'Windows_NT'
    if (-not $isWindowsHost -and (Test-Path -LiteralPath '/bin/bash')) {
        $candidates.Add('/bin/bash')
    }

    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $resolved = (Resolve-Path -LiteralPath $candidate).Path
        $uname = (& $resolved --login -c 'exec uname -s' 2>$null)
        if ($LASTEXITCODE -eq 0 -and $uname -match 'MINGW|MSYS|Linux|Darwin') {
            return $resolved
        }
    }

    throw 'Git Bash was not found. Install Git for Windows; the WSL bash.exe launcher is not supported for Windows-side Claude/Codex CLIs.'
}

function Get-HarnessRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $StartPath)

    $item = Get-Item -LiteralPath $StartPath
    $directory = if ($item.PSIsContainer) { $item } else { $item.Directory }
    while ($directory) {
        $stopHook = Join-Path $directory.FullName '.claude\hooks\stop-require-gates.sh'
        $hashTool = Join-Path $directory.FullName 'migration\tools\working-tree-hash.sh'
        if ((Test-Path -LiteralPath $stopHook) -and (Test-Path -LiteralPath $hashTool)) {
            return $directory.FullName
        }
        $directory = $directory.Parent
    }
    throw "Harness root not found above $StartPath"
}
