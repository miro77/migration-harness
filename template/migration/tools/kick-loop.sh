#!/usr/bin/env bash
# Unattended driver for the migration, meant to be run by a SCHEDULER
# (cron / Windows Task Scheduler / a cloud routine), not by hand in a session.
#
# The harness state lives entirely on disk, so a migration is always resumable:
# each run advances it as far as this run's token budget allows, then returns,
# and the scheduler fires again later. This is what makes the migration survive
# account/usage-limit resets — a run that hits the cap simply no-ops, and the
# next scheduled run (after the limit resets) continues where it stopped.
#
#   kick-loop.sh [--drive|--tick] [--review] [--prompt FILE] [--check]
#
# Modes:
#   (default)  one headless run of migration/LOOP-PROMPT.md — a single session
#              that self-paces through as many slices as its budget allows.
#   --tick     one headless run of migration/SINGLE-TICK-PROMPT.md — exactly
#              one slice in a fresh context, then return.
#   --drive    repeat --tick runs back-to-back — one FRESH context per slice —
#              until HANDOFF.md appears, a usage limit pauses it, the verifier
#              flags an un-gated tree, two consecutive ticks change nothing, or
#              HARNESS_MAX_TICKS (default 50) ticks are spent. Recommended for
#              unattended runs: no session accumulates context, so quality does
#              not degrade over a long migration.
#   --review   (with --drive) pause after any tick whose commit subject contains
#              'audited-fail' or 'split into sub-slices' — the human-in-the-loop
#              gate. Wait for Enter on a TTY, or log and continue headless.
#   --prompt FILE overrides the mode's default prompt file.
#
# Completion is signalled by migration/HANDOFF.md, which the migration writes
# on termination. While it is absent there is work to resume; once present this
# no-ops (delete it to force another round).
#
# Exit codes:
#   0  = advanced and the tree is gate-covered, or already complete, or skipped,
#        or (--drive) the tick budget was spent with state clean on disk
#   64 = (--drive) two consecutive ticks changed nothing and no HANDOFF.md was
#        written — the loop is stuck; inspect
#   65 = a run finished (claude exit 0) but the end state needs inspection:
#        the tree is NOT covered by a gate proof (the Stop verifier blocked),
#        or (--drive) HANDOFF.md was written but never committed — the
#        termination record is not in git
#   75 = stopped on a usage limit; the next scheduled run after reset continues
#   2  = cannot run (not a harness / bad args / no claude CLI)
#   *  = claude's own non-zero exit for a real error
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "kick-loop: not a git repository" >&2; exit 2; }
[ -f migration/LOOP-PROMPT.md ] || { echo "kick-loop: harness not found here (no migration/LOOP-PROMPT.md)" >&2; exit 2; }

# Driver knobs come from harness.env like every other HARNESS_* setting, so a
# value set there actually takes effect. An explicit environment variable on
# the invocation still wins (scheduler entries may override per-run).
_env_max_ticks="${HARNESS_MAX_TICKS:-}"
_env_lock_ttl="${HARNESS_LOCK_TTL_MIN:-}"
# shellcheck source=/dev/null
[ -f migration/harness.env ] && source migration/harness.env
HARNESS_MAX_TICKS="${_env_max_ticks:-${HARNESS_MAX_TICKS:-}}"
HARNESS_LOCK_TTL_MIN="${_env_lock_ttl:-${HARNESS_LOCK_TTL_MIN:-}}"

prompt=""; check=0; mode="loop"; review=0
setmode(){
  [ "$mode" = "loop" ] || { echo "kick-loop: --tick and --drive are mutually exclusive" >&2; exit 2; }
  mode="$1"
}
while [ $# -gt 0 ]; do
  case "$1" in
    --prompt)
      [ -n "${2:-}" ] || { echo "kick-loop: --prompt needs a file argument" >&2; exit 2; }
      prompt="$2"; shift 2 ;;
    --tick)   setmode tick;  shift ;;
    --drive)  setmode drive; shift ;;
    --review) review=1; shift ;;
    --check)  check=1; shift ;;
    *) echo "kick-loop: unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [ -z "$prompt" ]; then
  case "$mode" in
    loop) prompt="migration/LOOP-PROMPT.md" ;;
    *)    prompt="migration/SINGLE-TICK-PROMPT.md" ;;
  esac
fi

done_marker="migration/HANDOFF.md"
[ -e "$done_marker" ] && state="done" || state="resume"

if [ "$check" -eq 1 ]; then
  echo "STATE: $state"
  exit 0
fi
if [ "$state" = "done" ]; then
  echo "kick-loop: migration loop already terminated ($done_marker present) — nothing to resume."
  echo "  Delete $done_marker to force another round."
  exit 0
fi

# Validate the prompt file before locking or invoking anything, so a bad
# --prompt never reaches the CLI as an empty prompt.
[ -f "$prompt" ] && [ -r "$prompt" ] || { echo "kick-loop: prompt file not found or unreadable: $prompt" >&2; exit 2; }
promptext="$(cat "$prompt")" || { echo "kick-loop: could not read $prompt" >&2; exit 2; }

# Single-instance lock (atomic mkdir). A crashed run (SIGKILL) can leave the lock
# behind, so recover one older than the TTL instead of wedging every future fire.
lock=".harness/kick-loop.lock"
ttl_min="${HARNESS_LOCK_TTL_MIN:-360}"
mkdir -p .harness
if ! mkdir "$lock" 2>/dev/null; then
  if [ -n "$(find "$lock" -maxdepth 0 -mmin +"$ttl_min" 2>/dev/null)" ]; then
    echo "kick-loop: recovering stale lock ($lock older than ${ttl_min}m)." >&2
    rm -rf "$lock"
    mkdir "$lock" 2>/dev/null || { echo "kick-loop: could not take lock after recovery — skipping." >&2; exit 0; }
  else
    echo "kick-loop: another run holds $lock — skipping this fire."
    exit 0
  fi
fi
trap 'rm -rf "$lock" 2>/dev/null' EXIT
printf 'pid=%s started=%s\n' "$$" "$(date -u +%FT%TZ 2>/dev/null || echo now)" > "$lock/meta" 2>/dev/null || true

command -v claude >/dev/null 2>&1 || {
  echo "kick-loop: the 'claude' CLI must be on PATH to drive the loop headlessly." >&2
  exit 2
}

# One headless claude session with the chosen prompt, outcome classified.
# Prints the transcript; returns 0 = finished gate-covered, 65 = finished but
# NOT gate-covered, 75 = usage limit, else claude's own non-zero exit.
run_once(){
  local out rc verifier
  rm -rf .harness/state/tool-stats 2>/dev/null || true   # fresh per-session stats
  out="$(claude -p "$promptext" 2>&1)"
  rc=$?
  printf '%s\n' "$out"

  # A usage-limit stop is a PAUSE, not a failure — but it only ever comes with a
  # NON-ZERO exit. Never classify an exit-0 run as rate-limited (its transcript
  # may legitimately mention "rate limit"/"quota" as ordinary content).
  if [ "$rc" -ne 0 ]; then
    if printf '%s' "$out" | grep -qiE 'usage limit|rate limit|quota (exceeded|reached)|limit reached|resets? (at|in)|out of (tokens|credits)'; then
      echo "kick-loop: hit a usage limit — the next scheduled run after reset will continue."
      return 75
    fi
    echo "kick-loop: claude exited $rc (not a usage limit) — inspect." >&2
    return "$rc"
  fi

  # claude exited 0. Do NOT trust that blindly: verify the run left a
  # gate-covered or otherwise legitimate end state by reusing the Stop hook's
  # own verdict (which also honours the audited-fail / row-split
  # committed-checkpoint escape, so a clean recorded checkpoint is not
  # mis-flagged). If the hook is absent, we cannot verify, so pass through.
  verifier=".claude/hooks/stop-require-gates.sh"
  if [ -f "$verifier" ]; then
    if ! printf '{"stop_hook_active":false}' | bash "$verifier" >/dev/null 2>&1; then
      echo "kick-loop: run finished (exit 0) but the tree is NOT covered by a gate proof (Stop verifier blocked) — inspect before trusting it." >&2
      return 65
    fi
  fi
  return 0
}

# Change signature for the --drive no-progress backstop: the scoped CONTENT
# hash only, deliberately ignoring HEAD — an empty or out-of-scope commit
# changes no scoped content and is not migration progress, so commit-spam
# cannot reset the idle counter. .harness/ bookkeeping (idle-ticks, the proof)
# is outside the hash on purpose — a tick that only counted itself idle IS a
# no-progress tick.
tree_sig(){
  bash migration/tools/working-tree-hash.sh 2>/dev/null
}

if [ "$mode" != "drive" ]; then
  run_once
  exit $?
fi

# --drive: fresh-context ticks back-to-back. The work is the clock — the next
# tick starts as soon as the previous one returns, no scheduler interval in
# between. The prompt-side idle counter (.harness/state/idle-ticks) is the
# designed termination path; the signature comparison below is a driver-side
# backstop for a model that fails to keep that bookkeeping.
max_ticks="${HARNESS_MAX_TICKS:-50}"
idle=0; tick=0
while :; do
  if [ "$tick" -ge "$max_ticks" ]; then
    echo "kick-loop: tick budget spent ($max_ticks ticks) — state is checkpointed on disk; re-run to continue."
    exit 0
  fi
  tick=$((tick+1))
  touch "$lock" 2>/dev/null || true   # keep the lock's TTL fresh across a long drive
  before="$(tree_sig)"
  echo "kick-loop: tick $tick (fresh context)"
  run_once; rc=$?
  if [ -e "$done_marker" ]; then
    if [ "$rc" -ne 0 ]; then
      echo "kick-loop: migration terminated ($done_marker written) but the final tick reported $rc — inspect." >&2
      exit "$rc"
    fi
    # The termination record must be IN git (the tick prompt requires the
    # commit): an untracked or modified HANDOFF.md is an end state nobody
    # reviewed and no other machine will see — flag it, don't bless it.
    if [ -n "$(git status --porcelain -- "$done_marker" 2>/dev/null)" ]; then
      echo "kick-loop: $done_marker was written but is NOT committed — the termination record is not in git; inspect and commit it." >&2
      exit 65
    fi
    echo "kick-loop: migration terminated ($done_marker committed) after $tick tick(s)."
    exit 0
  fi
  [ "$rc" -eq 0 ] || exit "$rc"
  # Human-in-the-loop: --review pauses after a tick whose commit is an
  # audited-fail or a row-split — the moments a human should look before
  # the loop advances. On a TTY it waits for input; headless it logs.
  if [ "$review" -eq 1 ]; then
    subject=$(git log -1 --format=%s 2>/dev/null || true)
    case "$subject" in
      *audited-fail*|*"split into sub-slices"*)
        if [ -t 0 ]; then
          echo "kick-loop: [REVIEW] last tick committed '$subject'"
          printf '  Press Enter to continue, s to skip future reviews, Ctrl+C to stop: '
          read -r ans </dev/tty 2>/dev/null || true
          [ "${ans:-}" = "s" ] && review=0
        else
          echo "kick-loop: [REVIEW] last tick committed '$subject' — no TTY, continuing (run --review interactively to pause)"
        fi
        ;;
    esac
  fi
  if [ "$(tree_sig)" = "$before" ]; then
    idle=$((idle+1))
    if [ "$idle" -ge 2 ]; then
      echo "kick-loop: two consecutive ticks changed nothing and no $done_marker was written — stopping this drive; inspect." >&2
      exit 64
    fi
  else
    idle=0
  fi
done
