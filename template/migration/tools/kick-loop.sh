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
#   kick-loop.sh [--drive|--tick] [--max N] [--review|--review-log-only] [--prompt FILE] [--check]
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
#   --max N    with --drive, override HARNESS_MAX_TICKS for this invocation.
#   --review   (with --drive) stop for a human after any tick whose commit
#              subject contains 'audited-fail' or 'split into sub-slices'.
#              On a TTY it waits for Enter; HEADLESS it exits 70 so a
#              scheduler cannot silently sail past the review point.
#   --review-log-only  like --review but headless it only logs and continues
#              (the old behavior, for schedulers that alert on logs).
#   --prompt FILE overrides the mode's default prompt file.
#
# Completion is signalled by migration/HANDOFF.md — but its mere existence is
# NOT trusted: check-complete.sh validates it (tracked, clean, boards
# consistent) and classifies the terminal state. Delete it to force another
# round.
#
# Exit codes:
#   0  = advanced and the tree is gate-covered, or skipped, or terminated
#        COMPLETE (every row audited-pass, ledger wired, no open proposals),
#        or (--drive) the tick budget was spent with state clean on disk
#   10 = terminated BLOCKED — human decisions remain (blocked rows/ledger
#        rows or open PROPOSED-GATE-CHANGES entries)
#   20 = terminated FAILED — audited-fail rows remain; a human must look
#   64 = (--drive) two consecutive ticks changed nothing and no HANDOFF.md was
#        written — the loop is stuck; inspect
#   65 = needs inspection: a run finished but the tree is NOT gate-covered,
#        or HANDOFF.md exists/was written but is not a VALID termination
#        record (untracked, modified, bad STATUS line, boards inconsistent),
#        or the single-instance lock is past its TTL while its owner still
#        looks alive (a stall a scheduler must not read as success)
#   70 = (--drive --review, headless) review required: an audited-fail or
#        row-split commit landed; state is checkpointed — re-run to continue
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

prompt=""; check=0; mode="loop"; review=0; review_log_only=0; max_arg=""
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
    --max)
      [ -n "${2:-}" ] || { echo "kick-loop: --max needs a positive integer argument" >&2; exit 2; }
      case "$2" in ''|*[!0-9]*) echo "kick-loop: --max needs a positive integer argument" >&2; exit 2 ;; esac
      [ "$2" -gt 0 ] || { echo "kick-loop: --max needs a positive integer argument" >&2; exit 2; }
      max_arg="$2"; shift 2 ;;
    --review) review=1; shift ;;
    --review-log-only) review=1; review_log_only=1; shift ;;
    --check)  check=1; shift ;;
    *) echo "kick-loop: unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [ -n "$max_arg" ] && [ "$mode" != "drive" ]; then
  echo "kick-loop: --max only applies with --drive" >&2
  exit 2
fi
if [ -z "$prompt" ]; then
  case "$mode" in
    loop) prompt="migration/LOOP-PROMPT.md" ;;
    *)    prompt="migration/SINGLE-TICK-PROMPT.md" ;;
  esac
fi

done_marker="migration/HANDOFF.md"
# A handoff's mere existence is NOT completion: an accidentally created or
# edited HANDOFF.md must not silently no-op every future scheduled run. The
# claim is validated (tracked, clean, boards consistent) and classified into
# a machine-readable terminal state by check-complete.sh.
term_status=""; ccout=""
if [ -e "$done_marker" ]; then
  if ccout="$(bash migration/tools/check-complete.sh 2>&1)"; then
    term_status="$(printf '%s\n' "$ccout" | sed -n 's/^STATUS: //p' | head -n 1)"
    state="done:$term_status"
  else
    state="invalid-handoff"
  fi
else
  state="resume"
fi

if [ "$check" -eq 1 ]; then
  echo "STATE: $state"
  exit 0
fi
term_exit(){
  case "$1" in
    COMPLETE) echo "kick-loop: terminated COMPLETE — all rows audited-pass, ledger wired, no open proposals. Delete $done_marker to force another round."; exit 0 ;;
    BLOCKED)  echo "kick-loop: terminated BLOCKED — human decisions remain (see $done_marker)."; exit 10 ;;
    FAILED)   echo "kick-loop: terminated FAILED — audited-fail rows remain (see $done_marker)."; exit 20 ;;
    *)        echo "kick-loop: unrecognized terminal state '$1' — inspect $done_marker." >&2; exit 65 ;;
  esac
}
if [ "$state" = "invalid-handoff" ]; then
  echo "kick-loop: $done_marker exists but is NOT a valid termination record:" >&2
  printf '%s\n' "$ccout" >&2
  echo "  Fix or delete $done_marker; refusing to treat this as done." >&2
  exit 65
fi
if [ -n "$term_status" ]; then
  term_exit "$term_status"
fi

# Validate the prompt file before locking or invoking anything, so a bad
# --prompt never reaches the CLI as an empty prompt.
[ -f "$prompt" ] && [ -r "$prompt" ] || { echo "kick-loop: prompt file not found or unreadable: $prompt" >&2; exit 2; }
promptext="$(cat "$prompt")" || { echo "kick-loop: could not read $prompt" >&2; exit 2; }

# Single-instance lock (atomic mkdir). A crashed run (SIGKILL) can leave the lock
# behind, so recover one older than the TTL instead of wedging every future fire.
lock=".harness/kick-loop.lock"
ttl_min="${HARNESS_LOCK_TTL_MIN:-360}"
# Validate: a non-numeric TTL makes `find -mmin +"$ttl_min"` error to the
# discarded stderr and print nothing, so stale-lock recovery can NEVER trigger —
# a crashed run's leftover lock then wedges every future fire (exit 0, skipping)
# forever. Fall back to 360.
case "$ttl_min" in ''|*[!0-9]*) echo "kick-loop: HARNESS_LOCK_TTL_MIN ('$ttl_min') is not a number — using 360." >&2; ttl_min=360 ;; esac
mkdir -p .harness
if ! mkdir "$lock" 2>/dev/null; then
  if [ -n "$(find "$lock" -maxdepth 0 -mmin +"$ttl_min" 2>/dev/null)" ]; then
    # Age alone is not proof of death: a tick can legitimately run longer
    # than the TTL. Only refuse recovery when the recorded owner is alive
    # AND still looks like this driver (a bash process) — after a reboot the
    # pid can be RECYCLED by an unrelated long-lived process of the same
    # user, and a bare kill -0 then blocks recovery forever. And when we do
    # refuse, exit 65 (inspect), not 0: the live-owner heartbeat below keeps
    # the mtime fresh, so reaching this branch at all means the owner is
    # dead, wedged, or its heartbeat broke — a scheduler must not read an
    # indefinite stall as success.
    ownerpid="$(sed -n 's/^pid=\([0-9][0-9]*\).*/\1/p' "$lock/meta" 2>/dev/null | head -n 1)"
    # GNU/procps supports `-o comm=`; Git Bash's MSYS ps does not. Fall back
    # to the final COMMAND column and normalize a possible /usr/bin/ prefix.
    ownercomm="$(ps -p "${ownerpid:-0}" -o comm= 2>/dev/null | tr -d '[:space:]')"
    if [ -z "$ownercomm" ]; then
      ownercomm="$(ps -p "${ownerpid:-0}" 2>/dev/null | awk 'NR == 2 { print $NF }')"
    fi
    ownercomm="${ownercomm##*/}"
    if [ -n "$ownerpid" ] && kill -0 "$ownerpid" 2>/dev/null \
       && { [ "$ownercomm" = "bash" ] || [ "$ownercomm" = "bash.exe" ]; }; then
      echo "kick-loop: lock is older than ${ttl_min}m but owner pid $ownerpid is ALIVE (bash) — not recovering. If no driver is really running, remove $lock." >&2
      exit 65
    fi
    echo "kick-loop: recovering stale lock ($lock older than ${ttl_min}m, owner${ownerpid:+ pid $ownerpid} gone or not a driver process)." >&2
    rm -rf "$lock"
    mkdir "$lock" 2>/dev/null || { echo "kick-loop: could not take lock after recovery — skipping." >&2; exit 0; }
  else
    echo "kick-loop: another run holds $lock — skipping this fire."
    exit 0
  fi
fi
printf 'pid=%s started=%s\n' "$$" "$(date -u +%FT%TZ 2>/dev/null || echo now)" > "$lock/meta" 2>/dev/null || true
# Heartbeat: refresh the lock mtime while THIS process lives — a single tick
# can run longer than the TTL, and the per-tick touch is not enough. Stale
# recovery above requires BOTH an old mtime AND a dead owner pid. The TERM trap
# also kills the current sleep child; without it, MSYS leaves that child alive
# and command hosts can wait up to 60 seconds after every completed tick.
heartbeat(){
  local sleeper=""
  trap '[ -z "$sleeper" ] || { kill "$sleeper" 2>/dev/null; wait "$sleeper" 2>/dev/null; }; exit 0' TERM INT
  while kill -0 "$$" 2>/dev/null; do
    touch "$lock" 2>/dev/null || true
    sleep 60 & sleeper=$!
    wait "$sleeper" 2>/dev/null || true
    sleeper=""
  done
}
heartbeat >/dev/null 2>&1 &
hb_pid=$!
cleanup(){
  kill "$hb_pid" 2>/dev/null || true
  wait "$hb_pid" 2>/dev/null || true
  rm -rf "$lock" 2>/dev/null
}
trap cleanup EXIT

command -v claude >/dev/null 2>&1 || {
  echo "kick-loop: the 'claude' CLI must be on PATH to drive the loop headlessly." >&2
  exit 2
}

# Append-only lifecycle records make a scheduled run inspectable even when its
# console output was not retained. A run.start without a matching run.end is an
# interrupted process; completed attempts carry their classified outcome.
run_log=.harness/state/runs.ndjson
json_escape(){ printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
append_run_event(){
  local size=0
  mkdir -p .harness/state 2>/dev/null || return 0
  [ -f "$run_log" ] && size=$(wc -c < "$run_log" 2>/dev/null | tr -d '[:space:]')
  case "$size" in ''|*[!0-9]*) size=0 ;; esac
  if [ "$size" -gt 5242880 ]; then
    mv -f "$run_log" "$run_log.1" 2>/dev/null || true
  fi
  printf '%s\n' "$1" >> "$run_log" 2>/dev/null || true
}

# One headless claude session with the chosen prompt, outcome classified.
# Prints the transcript; returns 0 = finished gate-covered, 65 = finished but
# NOT gate-covered, 75 = usage limit, else claude's own non-zero exit.
run_seq=0; tick=0
run_once(){
  local out rc verifier final_rc outcome started_ts ended_ts started_epoch ended_epoch
  local duration calls before after run_id run_tick prompt_esc mode_esc before_esc after_esc
  rm -rf .harness/state/tool-stats 2>/dev/null || true   # fresh per-session stats
  run_seq=$((run_seq + 1))
  run_tick="${tick:-0}"
  started_ts=$(date -u +%FT%TZ 2>/dev/null || echo now)
  started_epoch=$(date +%s 2>/dev/null || echo 0)
  run_id="${started_ts}-$$-${run_seq}"
  before="$(tree_sig)"
  prompt_esc=$(json_escape "$prompt")
  mode_esc=$(json_escape "$mode")
  before_esc=$(json_escape "$before")
  export HARNESS_RUN_ID="$run_id"
  append_run_event "{\"event\":\"run.start\",\"ts\":\"$started_ts\",\"run_id\":\"$run_id\",\"mode\":\"$mode_esc\",\"tick\":$run_tick,\"prompt\":\"$prompt_esc\",\"tree\":\"$before_esc\"}"

  # next_model is set by the escalation path below (empty = the session default).
  if [ -n "${next_model:-}" ]; then
    echo "kick-loop: running this tick on model '$next_model' (escalated)."
    out="$(claude --model "$next_model" -p "$promptext" 2>&1)"
  else
    out="$(claude -p "$promptext" 2>&1)"
  fi
  rc=$?
  printf '%s\n' "$out"

  # A usage-limit stop is a PAUSE, not a failure — but it only ever comes with a
  # NON-ZERO exit. Never classify an exit-0 run as rate-limited (its transcript
  # may legitimately mention "rate limit"/"quota" as ordinary content). The
  # phrases are deliberately ANCHORED ("<kind> limit", not bare "limit reached"
  # or "resets at"): a real failure whose transcript happens to say "reset at"
  # (a test log, a stack trace) classified as 75 makes the scheduler retry a
  # broken run forever, silently. A missed limit phrase errs the other way —
  # a noisy cli_error stop a human sees — which is the safer direction.
  final_rc="$rc"; outcome="cli_error"
  if [ "$rc" -ne 0 ]; then
    if printf '%s' "$out" | grep -qiE '(usage|rate|[0-9]+-hour|weekly|session) limit|quota (exceeded|reached)|out of (tokens|credits)'; then
      echo "kick-loop: hit a usage limit — the next scheduled run after reset will continue."
      final_rc=75; outcome="usage_limit"
    else
      echo "kick-loop: claude exited $rc (not a usage limit) — inspect." >&2
    fi
  else
    final_rc=0; outcome="gate_covered"
    # claude exited 0. Do NOT trust that blindly: verify the run left a
    # gate-covered or otherwise legitimate end state by reusing the Stop hook's
    # own verdict (which also honours the audited-fail / row-split
    # committed-checkpoint escape, so a clean recorded checkpoint is not
    # mis-flagged). If the hook is absent, we cannot verify, so pass through.
    verifier=".claude/hooks/stop-require-gates.sh"
    if [ -f "$verifier" ]; then
      if ! printf '{"stop_hook_active":false}' | bash "$verifier" >/dev/null 2>&1; then
        echo "kick-loop: run finished (exit 0) but the tree is NOT covered by a gate proof (Stop verifier blocked) — inspect before trusting it." >&2
        echo "kick-loop: a common cause: the tick launched gates.sh in the BACKGROUND and ended its turn — a headless tick never resumes, so the gate run was orphaned (see AUTONOMY in migration/SINGLE-TICK-PROMPT.md)." >&2
        final_rc=65; outcome="ungated"
      fi
    fi
  fi

  ended_ts=$(date -u +%FT%TZ 2>/dev/null || echo now)
  ended_epoch=$(date +%s 2>/dev/null || echo 0)
  duration=0
  if [ "$started_epoch" -gt 0 ] 2>/dev/null && [ "$ended_epoch" -ge "$started_epoch" ] 2>/dev/null; then
    duration=$((ended_epoch - started_epoch))
  fi
  calls=$(cat .harness/state/tool-stats/call_count 2>/dev/null || echo 0)
  case "$calls" in ''|*[!0-9]*) calls=0 ;; esac
  after="$(tree_sig)"; after_esc=$(json_escape "$after")
  append_run_event "{\"event\":\"run.end\",\"ts\":\"$ended_ts\",\"run_id\":\"$run_id\",\"outcome\":\"$outcome\",\"exit_code\":$final_rc,\"duration_s\":$duration,\"tool_calls\":$calls,\"tree\":\"$after_esc\"}"
  return "$final_rc"
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
max_ticks="${max_arg:-${HARNESS_MAX_TICKS:-50}}"
# Validate like escalate_after does. A non-numeric HARNESS_MAX_TICKS would make
# `[ "$tick" -ge "$max_ticks" ]` error every iteration under `set +e`: the test
# is false, the budget never trips, and the drive runs UNBOUNDED. Fall back to 50.
case "$max_ticks" in ''|*[!0-9]*) echo "kick-loop: HARNESS_MAX_TICKS ('$max_ticks') is not a number — using 50." >&2; max_ticks=50 ;; esac
idle=0; tick=0

# Cross-model escalation (opt-in): after this many consecutive no-progress ticks,
# run the next one on a different model. Off unless HARNESS_ESCALATE_MODEL is set.
escalate_model="${HARNESS_ESCALATE_MODEL:-}"
escalate_after="${HARNESS_ESCALATE_AFTER:-1}"
case "$escalate_after" in ''|*[!0-9]*) escalate_after=1 ;; esac
next_model=""; escalated_ran=0
while :; do
  if [ "$tick" -ge "$max_ticks" ]; then
    echo "kick-loop: tick budget spent ($max_ticks ticks) — state is checkpointed on disk; re-run to continue."
    exit 0
  fi
  tick=$((tick+1))
  touch "$lock" 2>/dev/null || true   # keep the lock's TTL fresh across a long drive
  before="$(tree_sig)"
  head_before="$(git rev-parse HEAD 2>/dev/null || true)"
  # Did THIS tick run on the escalated model? next_model is armed at the end of a
  # previous no-progress iteration and consumed by run_once at the top of this one.
  tick_escalated=0; [ -n "$next_model" ] && tick_escalated=1
  echo "kick-loop: tick $tick (fresh context)"
  run_once; rc=$?
  if [ -e "$done_marker" ]; then
    if [ "$rc" -ne 0 ]; then
      echo "kick-loop: migration terminated ($done_marker written) but the final tick reported $rc — inspect." >&2
      exit "$rc"
    fi
    # The termination claim is validated, not trusted: tracked + clean +
    # boards consistent + a machine-readable STATUS line (check-complete.sh),
    # then mapped to a distinct exit code per terminal state.
    if ! ccout="$(bash migration/tools/check-complete.sh 2>&1)"; then
      echo "kick-loop: $done_marker was written but is NOT a valid termination record:" >&2
      printf '%s\n' "$ccout" >&2
      exit 65
    fi
    term_status="$(printf '%s\n' "$ccout" | sed -n 's/^STATUS: //p' | head -n 1)"
    echo "kick-loop: migration terminated after $tick tick(s)."
    term_exit "$term_status"
  fi
  [ "$rc" -eq 0 ] || exit "$rc"
  # Human-in-the-loop: --review pauses after a tick whose commit is an
  # audited-fail or a row-split — the moments a human should look before
  # the loop advances. On a TTY it waits for input; headless it logs.
  if [ "$review" -eq 1 ]; then
    # Scan EVERY commit the tick landed, not just HEAD: a tick can land the
    # audited-fail / row-split commit and THEN another (the rule-8 rename+content
    # pair, or bookkeeping), which would hide the review trigger behind HEAD and
    # let the loop sail past the exact point a human must look.
    if [ -n "$head_before" ]; then range="$head_before..HEAD"; else range="HEAD"; fi
    subject=$(git log --format=%s "$range" 2>/dev/null | grep -m1 -E 'audited-fail|split into sub-slices' || true)
    case "$subject" in
      *audited-fail*|*"split into sub-slices"*)
        if [ -t 0 ]; then
          echo "kick-loop: [REVIEW] last tick committed '$subject'"
          printf '  Press Enter to continue, s to skip future reviews, Ctrl+C to stop: '
          read -r ans </dev/tty 2>/dev/null || true
          [ "${ans:-}" = "s" ] && review=0
        elif [ "$review_log_only" -eq 1 ]; then
          echo "kick-loop: [REVIEW] last tick committed '$subject' — --review-log-only, continuing"
        else
          echo "kick-loop: [REVIEW] review required: last tick committed '$subject' — no TTY, stopping so a human can look. State is checkpointed; re-run to continue, or use --review-log-only to log without stopping." >&2
          exit 70
        fi
        ;;
    esac
  fi
  if [ "$(tree_sig)" = "$before" ]; then
    idle=$((idle+1))
    [ "$tick_escalated" -eq 1 ] && escalated_ran=1
    # Cross-model escalation. A model that is stuck tends to stay stuck in the
    # same way, and a fresh context of the SAME model is still the same model —
    # the fresh-context tick buys independence from the conversation, not from
    # the blind spot. A different model is the cheapest source of a genuinely
    # different read. (Field evidence from this harness: a different-VENDOR
    # adversarial review found four blockers that the internal fresh-context
    # audit had passed.)
    #
    # Escalation gets exactly one tick before the drive stops. Arm it once idle
    # reaches HARNESS_ESCALATE_AFTER; the NEXT tick runs on $escalate_model.
    if [ -n "$escalate_model" ] && [ "$escalate_after" -gt 0 ] \
       && [ "$idle" -ge "$escalate_after" ] && [ -z "$next_model" ] && [ "$escalated_ran" -eq 0 ]; then
      next_model="$escalate_model"
      echo "kick-loop: $idle consecutive tick(s) changed nothing — escalating the next tick to model '$escalate_model'."
    fi
    # Backstop. WITHOUT escalation: stop after two idle ticks. WITH escalation:
    # do NOT stop on the raw idle count — that would fire before the escalated
    # tick ever ran (the bug that made HARNESS_ESCALATE_AFTER>=2 dead code and
    # printed a false "second on <model>" message). Stop only once the escalated
    # tick has actually had its one shot and still made no progress: two DIFFERENT
    # models failing is not a model problem, and a human should look.
    if [ -z "$escalate_model" ]; then
      if [ "$idle" -ge 2 ]; then
        echo "kick-loop: two consecutive ticks changed nothing and no $done_marker was written — stopping this drive; inspect." >&2
        exit 64
      fi
    elif [ "$escalated_ran" -eq 1 ]; then
      echo "kick-loop: the escalated tick on '$escalate_model' also changed nothing and no $done_marker was written — two different models made no progress, so this is not a model problem. Stopping; inspect." >&2
      exit 64
    fi
  else
    idle=0
    next_model=""     # progress: back to the session default model
    escalated_ran=0   # a later stall re-arms escalation from scratch
  fi
done
