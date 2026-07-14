<#
.SYNOPSIS
  Windows supervisor for the unattended driver (kick-loop.sh --drive).

.DESCRIPTION
  A LAUNCHER, NOT A GATE. It has no authority and cannot weaken anything: gates.sh,
  the Stop hook and the content-addressed proof all live under HARNESS_LOCKED paths
  and run exactly as before. This only decides WHEN to re-invoke the driver, and
  cleans up after it.

  ⚠️ It lives OUTSIDE migration/tools/, so an agent CAN edit it. Do not treat it as a
  trust boundary. If you want it to be as trustworthy as the gates, move it into
  migration/tools/ (which HARNESS_LOCKED makes read-only to the agent) yourself.

  It exists because three things bite on Windows, and PowerShell can fix all three
  where bash cannot. Each was learned the hard way on a real migration:

  1. ORPHANED TICKS -- the expensive one.
     kick-loop.sh runs the tick as `out="$(claude -p ...)"`, which forks a subshell
     whose pid the driver never learns. Kill the driver (Ctrl-C, a timeout, a crashed
     terminal) and the `claude -p` child is ORPHANED: it keeps writing the working
     tree with nobody supervising it. On the migration this harness was hardened
     against, orphans ran for ~40 minutes unattended, raced the next tick, raced a
     live session, and forced the loop to halt.
     A bash reaper (background the child, record $!, trap EXIT/INT/TERM) was tried
     and REVERTED: under MinGW, backgrounding a Windows .exe and wait-ing on it makes
     the child die with SIGTERM (143) on every start. PowerShell CAN track a Windows
     process tree, so orphans are reaped here -- before the run, after every batch,
     and in a finally block so Ctrl-C cannot leak one.

  2. `bash` ON WINDOWS IS USUALLY WSL.
     `bash` on a Windows PATH resolves to C:\Windows\system32\bash.exe, not Git Bash.
     WSL cannot see `claude.exe` (no extension), so the driver dies with "the 'claude'
     CLI must be on PATH" -- which looks like a PATH problem and is not. WSL is the
     wrong shell anyway (the toolchain is Windows-side). We resolve Git Bash
     explicitly and REFUSE anything else, rather than failing misleadingly.

  3. A DIRTY TREE AT START.
     Any uncommitted change under a scoped path is indistinguishable from a rogue
     writer: the tick's concurrent-writer check aborts on it and the gate proof will
     not cover the tree. Refuse to start; say what to do.

  RETRY POLICY -- retry only what is safe to retry:
     75  usage limit          -> a PAUSE, not a failure: wait, then resume (bounded).
     crash on a CLEAN tree    -> transient: retry with exponential backoff (bounded).
     crash on a DIRTY tree    -> STOP. Re-running compounds it, and reverting
                                 uncommitted work blind orphans fixtures.
     10 BLOCKED / 20 FAILED   -> terminal by design: a human must decide. Never retry.
     64 stuck / 65 inspect    -> the loop's own stall/inspection signals. Never retry.
     70 review required       -> you asked for review (--review). Stop and review.
     2  cannot run            -> configuration error. Never retry.

.PARAMETER MaxSlices     Total slices to attempt across the whole run.
.PARAMETER Batch         Slices per kick-loop invocation (its --max).
.PARAMETER MaxRetries    Consecutive transient failures tolerated.
.PARAMETER LimitWaitMin  Minutes to wait after a usage-limit stop.
.PARAMETER MaxLimitWaits How many usage-limit waits to sit through.
.PARAMETER Review        Pass --review to the driver (stop after audited-fail/split).
.PARAMETER Force         Start even on a dirty tree. Rarely correct.

.EXAMPLE
  .\migration\run-loop.ps1
  .\migration\run-loop.ps1 -MaxSlices 5 -Batch 5
  .\migration\run-loop.ps1 -LimitWaitMin 45 -Review
#>
[CmdletBinding()]
param(
    [int]    $MaxSlices     = 30,
    [int]    $Batch         = 10,
    [int]    $MaxRetries    = 3,
    [int]    $LimitWaitMin  = 30,
    [int]    $MaxLimitWaits = 8,
    [switch] $Review,
    [switch] $Force,
    # Only headless `claude -p` processes whose command line matches this AND this
    # repo's run-loop prompt marker are reaped. Deliberately NARROW: a bare `-p`
    # match would kill ANY headless claude you happen to be running, which is the
    # same class of error as an instrument pointed at the wrong target.
    [string] $TickMarker    = 'Single-Tick'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = (& git rev-parse --show-toplevel 2>$null)
if (-not $repo) { Write-Error 'not a git repository'; exit 2 }
Set-Location $repo
$log = Join-Path $repo '.harness\run-loop.log'
New-Item -ItemType Directory -Force -Path (Split-Path $log) | Out-Null
$script:PromptMarker = 'HARNESS-RUN-LOOP-REPO ' + $repo
$script:TickPromptPath = Join-Path $repo '.harness\run-loop-prompt.md'

function Say([string]$m, [string]$c = 'Gray') {
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m
    Write-Host $line -ForegroundColor $c
    Add-Content -Path $log -Value $line
}

function Test-TreeClean { return -not (& git status --porcelain) }

function Write-TickPrompt {
    $source = 'migration\SINGLE-TICK-PROMPT.md'
    if (-not (Test-Path $source)) {
        Say 'harness prompt not found (no migration/SINGLE-TICK-PROMPT.md)' 'Red'
        exit 2
    }
    $body = Get-Content -Path $source -Raw
    Set-Content -Path $script:TickPromptPath -Value ("<!-- {0} -->`n{1}" -f $script:PromptMarker, $body)
}

function Exit-ExistingHandoff {
    Say 'migration/HANDOFF.md is present -- validating terminal state.' 'Yellow'
    $ccout = @(& $bash --login -c 'exec "$@"' harness 'migration/tools/check-complete.sh' 2>&1)
    $ccrc = $LASTEXITCODE
    foreach ($line in $ccout) { Say "    $line" 'Gray' }
    if ($ccrc -ne 0) {
        Say 'HANDOFF.md is not a valid terminal record -- inspect before trusting it.' 'Red'
        exit 65
    }
    $statusLine = @($ccout | Where-Object { $_ -match '^STATUS: ' } | Select-Object -First 1)
    if ($statusLine.Count -eq 0) {
        Say 'check-complete.sh returned success without a STATUS line -- inspect.' 'Red'
        exit 65
    }
    switch -Regex ($statusLine[0]) {
        '^STATUS: COMPLETE$' { exit 0 }
        '^STATUS: BLOCKED$'  { exit 10 }
        '^STATUS: FAILED$'   { exit 20 }
        default {
            Say "unrecognized terminal status: $($statusLine[0])" 'Red'
            exit 65
        }
    }
}

# --- orphan reaping: the reason this script exists --------------------------------
function Get-HeadlessTicks {
    # The driver's tick is `claude.exe -p "<repo marker>...# Single-Tick Prompt ..."`.
    # Match -p, the tick marker, AND this repo's marker, so we can never kill:
    #   * the human's interactive session (`claude.exe --session-id ...`), nor
    #   * an unrelated headless `claude -p` the human is running for something else,
    #   * another checkout running the same harness prompt.
    # A bare `-p` match would do the first two. The generic prompt heading alone
    # would do the third.
    $pFlag = '(^|\s)-p(\s|$)'
    $tick = [Regex]::Escape($script:TickMarker)
    $repoMarker = [Regex]::Escape($script:PromptMarker)
    Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -and
            $_.CommandLine -match $pFlag -and
            $_.CommandLine -match $tick -and
            $_.CommandLine -match $repoMarker
        }
}

function Stop-Orphans([string]$why) {
    $orphans = @(Get-HeadlessTicks)
    if ($orphans.Count -eq 0) { return 0 }
    Say ("reaping {0} headless tick(s) [{1}]: {2}" -f $orphans.Count, $why,
         (($orphans | ForEach-Object { $_.ProcessId }) -join ', ')) 'Yellow'
    foreach ($o in $orphans) {
        try { Stop-Process -Id $o.ProcessId -Force -ErrorAction Stop } catch { }
    }
    Start-Sleep -Seconds 3
    $left = @(Get-HeadlessTicks).Count
    if ($left -gt 0) { Say "WARNING: $left headless tick(s) survived the kill" 'Red' }
    return $orphans.Count
}

# --- preflight --------------------------------------------------------------------
Say '--- preflight ---------------------------------------------------------' 'Cyan'

# `bash` on Windows is usually WSL. Resolve GIT BASH explicitly and refuse anything
# else -- a silent WSL fallback reports "claude not on PATH", which misdiagnoses it.
$bash = @(
    (Join-Path (Split-Path (Split-Path (Get-Command git).Source)) 'bin\bash.exe'),
    'C:\Program Files\Git\bin\bash.exe',
    'C:\Program Files (x86)\Git\bin\bash.exe'
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

if (-not $bash) {
    Say 'Git Bash not found (looked next to git.exe and in Program Files).' 'Red'
    Say 'The harness needs Git Bash (MINGW64); WSL cannot see claude.exe.' 'Red'
    exit 2
}
$uname = (& $bash --login -c 'exec uname -s') 2>$null
if ($uname -notmatch 'MINGW|MSYS') {
    Say "resolved bash is not Git Bash (uname='$uname') -- refusing." 'Red'
    exit 2
}
Say "bash: $bash ($uname)" 'Gray'

# claude must be visible to GIT BASH, not merely to PowerShell: kick-loop.sh is what
# invokes it. Checking only PowerShell's view passes, then the driver dies one line
# later -- checking the wrong thing and passing is worse than not checking.
$claudeInBash = (& $bash --login -c 'p=$(command -v claude) || exit; printf "%s\n" "$p"; exec true') 2>$null
if (-not $claudeInBash) {
    Say 'the `claude` CLI is not on Git Bash''s PATH (kick-loop.sh cannot invoke it)' 'Red'
    exit 2
}
Say "claude: $claudeInBash" 'Gray'

if (-not (Test-Path 'migration\tools\kick-loop.sh')) {
    Say 'harness not found (no migration/tools/kick-loop.sh)' 'Red'; exit 2
}
Write-TickPrompt

# A tick left running by an earlier, killed driver will race this one.
Stop-Orphans 'pre-existing, from an earlier run' | Out-Null

$lock = '.harness\kick-loop.lock'
if (Test-Path $lock) {
    Say "a driver already holds $lock -- refusing to start a second one" 'Red'
    Say '  if you are certain none is running: Remove-Item -Recurse .harness\kick-loop.lock' 'Gray'
    exit 2
}

if (Test-Path 'migration\HANDOFF.md') {
    Exit-ExistingHandoff
}

if (-not (Test-TreeClean)) {
    Say 'WORKING TREE IS DIRTY. Refusing to start.' 'Red'
    & git status --short | ForEach-Object { Say "    $_" 'Gray' }
    Say 'An uncommitted change under a scoped path is indistinguishable from a rogue' 'Yellow'
    Say 'writer: the tick aborts on it and the gate proof will not cover the tree.' 'Yellow'
    Say 'Fix it first:  bash migration/tools/gates.sh && git add -A && git commit' 'Yellow'
    if (-not $Force) { exit 2 }
    Say '-Force given: starting anyway (you were warned)' 'Red'
}

$startHead = (& git rev-parse HEAD).Trim()
Say ("start HEAD {0}; budget {1} slice(s), {2} per batch" -f `
     $startHead.Substring(0, 10), $MaxSlices, $Batch) 'Cyan'

# --- supervision loop -------------------------------------------------------------
$landed = 0; $retries = 0; $limitWaits = 0; $exitCode = 0

try {
    # ⚠️ LABELLED. In PowerShell, `break` inside a `switch` exits the SWITCH, not the
    # enclosing `while` -- so an unlabelled break on a fatal path would fall through
    # and loop again, retrying forever exactly where it must stop for a human.
    :driver while ($landed -lt $MaxSlices) {

        $before    = (& git rev-parse HEAD).Trim()
        $thisBatch = [Math]::Min($Batch, $MaxSlices - $landed)

        Say ("--- driver: --drive --max {0}  (landed {1}/{2})" -f `
             $thisBatch, $landed, $MaxSlices) 'Cyan'

        $driverArgs = @('--login', '-c', 'exec "$@"', 'harness', 'migration/tools/kick-loop.sh', '--drive', '--max', $thisBatch, '--prompt', '.harness/run-loop-prompt.md')
        if ($Review) { $driverArgs += '--review' }

        & $bash @driverArgs 2>&1 | Tee-Object -FilePath $log -Append
        $rc = $LASTEXITCODE

        # Whatever happened, never leave a tick running unsupervised.
        Stop-Orphans "driver returned rc=$rc" | Out-Null

        $after = (& git rev-parse HEAD).Trim()
        $new   = @(& git log --oneline "$before..$after")
        if ($new.Count -gt 0) {
            $landed += $new.Count
            $retries = 0                      # progress resets the transient budget
            foreach ($c in $new) { Say "  LANDED: $c" 'Green' }
        }

        switch ($rc) {

            0 {
                if (Test-Path 'migration\HANDOFF.md') {
                    Say 'HANDOFF.md written -- the loop terminated on purpose. Read it.' 'Yellow'
                    break driver
                }
                if ($new.Count -eq 0) {
                    Say 'driver exited 0 but landed nothing and wrote no HANDOFF -- stopping.' 'Yellow'
                    break driver
                }
                Say ("batch complete ({0} landed)" -f $new.Count) 'Green'
            }

            75 {
                $limitWaits++
                if ($limitWaits -gt $MaxLimitWaits) {
                    Say "usage limit hit $limitWaits times -- giving up for now." 'Red'
                    $exitCode = 75; break driver
                }
                Say ("usage limit -- waiting {0} min, then resuming (wait {1}/{2})" -f `
                     $LimitWaitMin, $limitWaits, $MaxLimitWaits) 'Yellow'
                Start-Sleep -Seconds ($LimitWaitMin * 60)
            }

            10 { Say 'TERMINATED BLOCKED (rc=10): human decisions remain. Read HANDOFF.md / the boards.' 'Yellow'
                 $exitCode = 10; break driver }

            20 { Say 'TERMINATED FAILED (rc=20): audited-fail rows remain. A human must look.' 'Red'
                 $exitCode = 20; break driver }

            64 { Say 'STUCK (rc=64): two consecutive ticks changed nothing and wrote no HANDOFF.' 'Red'
                 Say 'Do not just re-run -- the loop is not making progress. Inspect.' 'Red'
                 $exitCode = 64; break driver }

            65 { Say 'NEEDS INSPECTION (rc=65): the tree is not gate-covered, or HANDOFF is not a' 'Red'
                 Say 'valid termination record, or the lock is stale while its owner looks alive.' 'Red'
                 if (-not (Test-TreeClean)) {
                     & git status --short | ForEach-Object { Say "    $_" 'Gray' }
                     Say 'READ the uncommitted work before reverting ANY of it: reverting a fixture' 'Red'
                     Say 'generator orphans the fixtures it produced, which are then unreproducible.' 'Red'
                 }
                 $exitCode = 65; break driver }

            70 { Say 'REVIEW REQUIRED (rc=70): an audited-fail or row-split commit landed.' 'Yellow'
                 Say 'State is checkpointed. Review it, then re-run to continue.' 'Yellow'
                 $exitCode = 70; break driver }

            2  { Say 'CANNOT RUN (rc=2): bad args / not a harness / no claude. Not retrying.' 'Red'
                 $exitCode = 2; break driver }

            default {
                if (-not (Test-TreeClean)) {
                    Say "driver exited $rc AND left the tree dirty -- stopping for a human." 'Red'
                    & git status --short | ForEach-Object { Say "    $_" 'Gray' }
                    $exitCode = $rc; break driver
                }
                $retries++
                if ($retries -gt $MaxRetries) {
                    Say "driver failed $retries times in a row (rc=$rc) -- giving up." 'Red'
                    $exitCode = $rc; break driver
                }
                $backoff = 30 * [Math]::Pow(2, $retries - 1)     # 30s, 60s, 120s
                Say ("driver exited {0} on a clean tree -- retry {1}/{2} in {3}s" -f `
                     $rc, $retries, $MaxRetries, $backoff) 'Yellow'
                Start-Sleep -Seconds $backoff
            }
        }
    }
}
finally {
    # Ctrl-C lands here too. The whole point: never leave a tick orphaned.
    Stop-Orphans 'shutting down' | Out-Null
    if (Test-Path $lock) {
        Say 'releasing a stale driver lock' 'Yellow'
        Remove-Item -Recurse -Force $lock -ErrorAction SilentlyContinue
    }

    $endHead = (& git rev-parse HEAD).Trim()
    $all     = @(& git log --oneline "$startHead..$endHead")
    Say '--- summary -----------------------------------------------------------' 'Cyan'
    Say ("slices landed: {0}" -f $all.Count) $(if ($all.Count) { 'Green' } else { 'Yellow' })
    foreach ($c in $all) { Say "  $c" 'Green' }
    if (-not (Test-TreeClean)) {
        Say 'WARNING: the working tree is DIRTY. Read it before reverting anything.' 'Red'
        & git status --short | ForEach-Object { Say "    $_" 'Gray' }
    }
    Say ("log: {0}" -f $log) 'Gray'
}

exit $exitCode
