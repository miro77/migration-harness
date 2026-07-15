# Shared PowerShell bridge to the harness's Bash implementation. The Bash tools
# remain the single enforcement path; these functions only resolve the correct
# shell and harness root, and encode arguments so they reach that path intact.
Set-StrictMode -Version Latest

function Get-HarnessBash {
    [CmdletBinding()]
    param()

    $candidates = [Collections.Generic.List[string]]::new()
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git -and $git.Source) {
        $gitRoot = Split-Path -Parent (Split-Path -Parent $git.Source)
        $candidates.Add((Join-Path $gitRoot 'bin/bash.exe'))
        $candidates.Add((Join-Path $gitRoot 'usr/bin/bash.exe'))
    }
    if (${env:ProgramFiles}) {
        $candidates.Add((Join-Path ${env:ProgramFiles} 'Git/bin/bash.exe'))
    }
    if (${env:ProgramFiles(x86)}) {
        $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Git/bin/bash.exe'))
    }
    $isWindowsHost = ${env:OS} -eq 'Windows_NT'
    if (-not $isWindowsHost -and (Test-Path -LiteralPath '/bin/bash')) {
        $candidates.Add('/bin/bash')
    }

    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $resolved = (Resolve-Path -LiteralPath $candidate).Path
        # Probe under EAP=Continue with a catch: Windows PowerShell 5.1 turns a
        # REDIRECTED native stderr line into a TERMINATING error while the
        # caller's $ErrorActionPreference is 'Stop' (every wrapper's default),
        # so a candidate bash that merely wrote a profile warning to stderr
        # would otherwise abort the whole search. A noisy or broken candidate
        # must be SKIPPED — a later candidate may be perfectly fine.
        $uname = ''
        $probeOk = $false
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $uname = (& $resolved --login -c 'exec uname -s' 2>$null)
            $probeOk = ($LASTEXITCODE -eq 0)
        }
        catch { $probeOk = $false }
        finally { $ErrorActionPreference = $previousPreference }
        if ($probeOk -and $uname -match 'MINGW|MSYS|Linux|Darwin') {
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
        # Forward slashes on purpose: Windows accepts them everywhere, while
        # pwsh on Linux (which Get-HarnessBash deliberately supports via
        # /bin/bash) treats a backslash as a literal filename character, not a
        # separator — a backslash literal here made this probe Windows-only.
        $stopHook = Join-Path $directory.FullName '.claude/hooks/stop-require-gates.sh'
        $hashTool = Join-Path $directory.FullName 'migration/tools/working-tree-hash.sh'
        if ((Test-Path -LiteralPath $stopHook) -and (Test-Path -LiteralPath $hashTool)) {
            return $directory.FullName
        }
        $directory = $directory.Parent
    }
    throw "Harness root not found above $StartPath"
}

# --- argument bridge ---------------------------------------------------------
# Windows PowerShell 5.1 (and pwsh <= 7.2) re-encode native-command arguments
# naively: an argument containing whitespace is wrapped in double quotes
# WITHOUT escaping any double quotes it contains. The previous bridge
# (`-c 'exec "$@"' harness <script> @args`) therefore reached bash.exe as
# `exec $@` — the payload's inner quotes were eaten — so forwarded arguments
# were word-split, glob-expanded against the repo root, and empty arguments
# were dropped. The fix: build ONE -c payload in which every word is
# single-quoted for bash (an embedded single quote becomes the standard '\''
# splice). Such a payload contains no double-quote character, so the naive
# re-quoting is a byte-for-byte round trip and MSVCRT argv rules deliver it to
# bash verbatim on every PowerShell version.
#
# KNOWN LIMIT: on PS <= 7.2 (or 7.3+ with $PSNativeCommandArgumentPassing set
# to 'Legacy') an argument that itself CONTAINS a double-quote character cannot
# be forwarded faithfully — the mangling happens inside PowerShell's own
# re-quoting, before bash ever runs. Invoke-HarnessBash refuses such an
# argument loudly instead of forwarding it silently corrupted.

function ConvertTo-BashWords {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]] $Words)

    (@($Words) | ForEach-Object { "'" + ($_ -replace "'", "'\''") + "'" }) -join ' '
}

function Invoke-HarnessBash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Bash,
        # First element is the script/program (repo-relative is fine: the .sh
        # tools re-cd to the repo toplevel themselves), the rest its arguments.
        # Empty-string arguments are legal and must forward as empty words.
        [Parameter(Mandatory)][AllowEmptyString()][string[]] $Command,
        # Merge or discard stderr INSIDE bash. Never redirect a native stream
        # in PowerShell here: on 5.1 a redirected stderr line becomes a
        # terminating error under the caller's $ErrorActionPreference = 'Stop'.
        [switch] $MergeStderr,
        [switch] $DiscardStderr
    )

    if ($MergeStderr -and $DiscardStderr) {
        throw 'Invoke-HarnessBash: -MergeStderr and -DiscardStderr are mutually exclusive'
    }
    if (${env:OS} -eq 'Windows_NT') {
        $risky = @($Command -match '"')
        if ($risky.Count -gt 0) {
            $passing = Get-Variable -Name PSNativeCommandArgumentPassing -ValueOnly -ErrorAction SilentlyContinue
            if ($PSVersionTable.PSVersion -lt [Version]'7.3' -or "$passing" -eq 'Legacy') {
                throw ('Invoke-HarnessBash: this PowerShell version cannot forward an argument containing a double-quote character to bash.exe faithfully (use pwsh 7.3+): ' + ($risky -join ' '))
            }
        }
    }

    $payload = 'exec ' + (ConvertTo-BashWords -Words $Command)
    if ($MergeStderr) { $payload += ' 2>&1' }
    if ($DiscardStderr) { $payload += ' 2>/dev/null' }

    # EAP=Continue around the child for the same 5.1 reason as above: the
    # CALLER may capture or redirect our output stream. $LASTEXITCODE is left
    # untouched for the caller to inspect.
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Bash --login -c $payload }
    finally { $ErrorActionPreference = $previousPreference }
}
