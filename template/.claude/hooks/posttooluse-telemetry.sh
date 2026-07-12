#!/usr/bin/env bash
# PostToolUse hook: observability, budget enforcement, and loop detection.
#
# Fires after EVERY tool call. Three functions, all "inject, don't kill" —
# the hook never blocks a tool result. The model self-corrects when given
# the right nudge, not when force-stopped.
#
# 1. Observability — logs every tool call as structured JSON to
#    .harness/state/telemetry.ndjson (latency via timestamps, tool name,
#    argument fingerprint). The analogue of the article's
#    ObservabilityMiddleware: every call is bookended, ready to ship to
#    any observability platform.
#
# 2. Budget — counts tool calls per session; when HARNESS_MAX_CALLS_PER_TICK
#    is exceeded, injects a wrap-up warning. The analogue of
#    CallBudgetMiddleware: a soft guard that tells the model to stop, not a
#    hard kill.
#
# 3. Loop detection — fingerprints recent tool calls in a sliding window;
#    when the same call repeats HARNESS_LOOP_THRESHOLD times, injects a
#    reconsideration prompt. The analogue of LoopDetectionMiddleware:
#    detect cycling and nudge the model to change approach, not abort it.
#
# Per-session stats live in .harness/state/tool-stats/. kick-loop.sh clears
# that directory at the start of each fresh-context tick so the budget and
# loop window reset per session. In LOOP-PROMPT (single-session) mode the
# stats persist for the whole session, which is the intended scope.
#
# Fail-open: never wedge a session — all file I/O is best-effort, and a
# missing git repo / harness config means there is nothing to instrument.
set -uo pipefail

input=$(cat)

# Best-effort: need a git repo + harness config to do anything useful.
root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -f "$root/migration/harness.env" ] || exit 0
cd "$root" || exit 0
# shellcheck source=/dev/null
source migration/harness.env

mkdir -p .harness/state/tool-stats 2>/dev/null || true

# --- parse tool name from the hook JSON (no jq dependency) ---
# Claude Code PostToolUse input: {"session_id":"...","tool_name":"Bash","tool_input":{...},"tool_response":{...}}
tool_name=$(printf '%s' "$input" | tr '\n\r' '  ' \
  | sed -n 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
[ -z "$tool_name" ] && exit 0

# Extract a representative arg for fingerprinting. Different tools use
# different input keys; try the common ones in order of specificity.
arg=""
for key in command file_path pattern query description prompt filePath; do
  arg=$(printf '%s' "$input" | tr '\n\r' '  ' \
    | sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\(\(\\.\|[^"\\]\)*\)".*/\1/p')
  [ -n "$arg" ] && break
done

# Content-bearing edit tools would otherwise fingerprint as just
# "Edit::<file_path>": a series of DIFFERENT edits to one file (a doc-heavy
# phase) then reads as a loop and sprays false nudges (observed in the
# field). Fold in a slice of the change content so only genuinely identical
# edits count as repeats.
sig=""
case "$tool_name" in
  Edit|Write|NotebookEdit|MultiEdit)
    for key in old_string new_string content new_source; do
      v=$(printf '%s' "$input" | tr '\n\r' '  ' \
        | sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\(\(\\.\|[^"\\]\)*\)".*/\1/p')
      [ -n "$v" ] && sig="${sig}${v:0:40}"
    done ;;
esac
fingerprint="${tool_name}::${arg:0:80}::${sig:0:80}"

# --- 1. Observability: structured JSON log ---
# Rotate at ~5 MB (one .1 generation): nothing else ever truncates this file,
# and a long --drive run appends to it across every tick.
tlog=.harness/state/telemetry.ndjson
# NB: the redirection failure on a missing log comes from the SHELL, before
# wc's 2>/dev/null applies — guard with -f so the first call of a session
# doesn't leak "No such file or directory" into the hook's stderr.
tsize=0
[ -f "$tlog" ] && tsize=$(wc -c < "$tlog" 2>/dev/null | tr -d '[:space:]')
case "$tsize" in ''|*[!0-9]*) tsize=0 ;; esac
if [ "$tsize" -gt 5242880 ]; then mv -f "$tlog" "$tlog.1" 2>/dev/null || true; fi

ts=$(date -u +%FT%TZ 2>/dev/null || echo now)
# Basic JSON string escaping for the fingerprint (strip is already done by
# the \n\r -> space replacement above; escape backslash and double-quote).
fp_esc=$(printf '%s' "$fingerprint" | sed 's/\\/\\\\/g; s/"/\\"/g')
tn_esc=$(printf '%s' "$tool_name" | sed 's/\\/\\\\/g; s/"/\\"/g')
printf '{"event":"tool.complete","ts":"%s","tool":"%s","fingerprint":"%s"}\n' \
  "$ts" "$tn_esc" "$fp_esc" \
  >> "$tlog" 2>/dev/null || true

# --- 2. Budget: per-session tool-call counter ---
count_file=.harness/state/tool-stats/call_count
count=$(cat "$count_file" 2>/dev/null || echo 0)
case "$count" in ''|*[!0-9]*) count=0 ;; esac   # garbage in the file must not wedge the hook
count=$((count + 1))
printf '%s\n' "$count" > "$count_file" 2>/dev/null || true

# harness.env documents "leave empty ... to disable": an empty or non-numeric
# value must disable cleanly, not spray "integer expression expected" on every
# tool call.
max_calls="${HARNESS_MAX_CALLS_PER_TICK:-0}"
case "$max_calls" in ''|*[!0-9]*) max_calls=0 ;; esac
if [ "$max_calls" -gt 0 ] && [ "$count" -gt "$max_calls" ]; then
  msg="[HARNESS] Tool-call budget exceeded: ${count} calls this session (limit: ${max_calls}). Wrap up the current slice, checkpoint state to disk (update migration/parity-matrix.md, write to .harness/state/slice-state/ if needed), and end the tick. Do not start new work. (If you are a subagent, finish and return your report now - the budget covers the whole tick, subagent calls included.)"
  printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' "$msg"
  exit 0
fi

# --- 3. Loop detection: sliding-window fingerprinting ---
window="${HARNESS_LOOP_WINDOW:-6}"
threshold="${HARNESS_LOOP_THRESHOLD:-3}"
[ "$threshold" -gt 0 ] 2>/dev/null || exit 0
[ "$window" -gt 0 ] 2>/dev/null || exit 0

fp_file=.harness/state/tool-stats/fingerprints
# Append current fingerprint, keep only the last $window lines.
printf '%s\n' "$fingerprint" >> "$fp_file" 2>/dev/null || true
lines=$(wc -l < "$fp_file" 2>/dev/null | tr -d '[:space:]')
case "$lines" in ''|*[!0-9]*) lines=0 ;; esac
if [ "$lines" -gt "$window" ]; then
  tail -n "$window" "$fp_file" > "$fp_file.tmp" 2>/dev/null \
    && mv "$fp_file.tmp" "$fp_file" 2>/dev/null || true
fi

# Count occurrences of the current fingerprint in the window. NB: grep -c
# prints its 0 itself on no match (while exiting 1), so an `|| echo 0` here
# would yield "0\n0" — normalize instead of double-emitting.
repeat=$(grep -cxF "$fingerprint" "$fp_file" 2>/dev/null || true)
case "$repeat" in ''|*[!0-9]*) repeat=0 ;; esac
if [ "$repeat" -ge "$threshold" ]; then
  msg="[HARNESS] Loop detected: '${tool_name}' called ${repeat} times with similar arguments in the last ${window} tool calls. Stop and reconsider your approach. Re-read your todo list, choose a different action, or persist state to .harness/state/slice-state/ (bash migration/tools/persist-state.sh) and end the tick if stuck."
  printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' "$msg"
  exit 0
fi

# Second tier, edit tools only: the content slice in the fingerprint stops
# DIFFERENT edits to one file (a doc-heavy phase) reading as a loop — but an
# agent spinning on a failing change varies its old/new strings slightly each
# try, so exact repeats alone would never flag it. When same-tool-same-file
# edits fill the ENTIRE window (a much stronger signal than the threshold),
# nudge anyway.
if [ -n "$sig" ]; then
  prefix="${tool_name}::${arg:0:80}::"
  prefix_repeat=$(awk -v p="$prefix" 'index($0, p) == 1 { n++ } END { print n+0 }' "$fp_file" 2>/dev/null)
  case "$prefix_repeat" in ''|*[!0-9]*) prefix_repeat=0 ;; esac
  if [ "$prefix_repeat" -ge "$window" ]; then
    msg="[HARNESS] Possible loop: the last ${prefix_repeat} tool calls were ALL '${tool_name}' edits to the same file with differing content. If these edits are retries of one failing change, stop and reconsider the approach; if the file genuinely needs this many edits, carry on."
    printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' "$msg"
    exit 0
  fi
fi

exit 0
