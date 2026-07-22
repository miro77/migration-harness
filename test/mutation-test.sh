#!/usr/bin/env bash
# Maintainer-only mutation test for the harness distribution.
#
# Each case weakens one enforcement invariant in a disposable copy of template/
# and names the existing regression assertion that must turn red. The real
# worktree is never mutated. This checks that the tests still have teeth, not
# merely that they are green on today's implementation.
set -euo pipefail

if ! sed --version >/dev/null 2>&1; then
  echo "mutation-test: GNU sed is required (CI runs this on Linux)." >&2
  exit 2
fi

self="$(cd "$(dirname "$0")" && pwd)"
dist="$(cd "$self/.." && pwd)"
cases_dir="$self/mutations"
[ -f "$dist/install.sh" ] && [ -d "$dist/template" ] \
  || { echo "mutation-test: distribution root not found above $self" >&2; exit 1; }

run_sensor(){
  case "$1" in
    selftest)    bash template/test/harness-selftest.sh ;;
    consistency) bash template/test/check-consistency.sh ;;
    e2e)         bash template/test/e2e-smoke.sh ;;
    *) echo "mutation-test: unknown sensor '$1'" >&2; return 2 ;;
  esac
}

copy_pristine_work(){
  destination="$1"
  mkdir -p "$destination"
  cp -R "$dist/template" "$destination/template"
  cp "$dist/install.sh" "$destination/install.sh"
}

tree_digest(){
  tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
    -cf - -C "$1" . | sha256sum | cut -d' ' -f1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

shopt -s nullglob
cases=("$cases_dir"/*.sh)
shopt -u nullglob
[ "${#cases[@]}" -gt 0 ] \
  || { echo "mutation-test: no cases under $cases_dir (empty is not green)" >&2; exit 1; }

pass=0
fail=0
green_sensors=" "
pristine_reference="$tmp/pristine-reference"
copy_pristine_work "$pristine_reference"
for case_file in "${cases[@]}"; do
  name="$(basename "$case_file" .sh)"
  files="$(sed -n 's/^# files: //p' "$case_file")"
  sensor="$(sed -n 's/^# verify: //p' "$case_file")"
  expect="$(sed -n 's/^# expect: //p' "$case_file")"
  if [ -z "$files" ] || [ -z "$sensor" ] || [ -z "$expect" ]; then
    echo "FAIL: $name — missing files/verify/expect metadata" >&2
    fail=$((fail + 1))
    continue
  fi

  work="$tmp/work-$name"
  copy_pristine_work "$work"

  case "$green_sensors" in
    *" $sensor "*) ;;
    *)
      baseline="$tmp/baseline-$sensor.log"
      baseline_sensor_work="$tmp/baseline-work-$sensor"
      copy_pristine_work "$baseline_sensor_work"
      if ! (cd "$baseline_sensor_work" && run_sensor "$sensor") >"$baseline" 2>&1; then
        echo "FAIL: $name — '$sensor' is red before mutation" >&2
        tail -n 12 "$baseline" | sed 's/^/  | /' >&2
        fail=$((fail + 1))
        continue
      fi
      green_sensors="$green_sensors$sensor "
      ;;
  esac

  pristine_digest="$(tree_digest "$work")"
  before="$tmp/before-$name.sums"
  : > "$before"
  backup="$tmp/backup-$name"
  mkdir -p "$backup"
  metadata_bad=0
  for file in $files; do
    if [ ! -f "$work/$file" ]; then
      echo "FAIL: $name — declared target is missing: $file" >&2
      metadata_bad=1
    else
      (cd "$work" && sha256sum "$file") >> "$before"
      mkdir -p "$backup/$(dirname "$file")"
      cp -p "$work/$file" "$backup/$file"
    fi
  done
  if [ "$metadata_bad" -ne 0 ]; then
    fail=$((fail + 1))
    continue
  fi

  mutation_log="$tmp/mutation-$name.log"
  if ! (cd "$work" && bash "$case_file") >"$mutation_log" 2>&1; then
    echo "FAIL: $name — mutation script failed" >&2
    sed 's/^/  | /' "$mutation_log" >&2
    for file in $files; do cp -p "$backup/$file" "$work/$file"; done
    fail=$((fail + 1))
    continue
  fi

  unchanged=""
  for file in $files; do
    if (cd "$work" && grep -F "  $file" "$before" | sha256sum -c -) >/dev/null 2>&1; then
      unchanged="$unchanged $file"
    fi
  done
  if [ -n "$unchanged" ]; then
    echo "FAIL: $name — mutation did not change:$unchanged" >&2
    for file in $files; do cp -p "$backup/$file" "$work/$file"; done
    fail=$((fail + 1))
    continue
  fi

  # Prove the mutation touched only its declared files. Save those mutated
  # bytes, restore the declarations, and compare the complete tree (including
  # paths, modes, symlinks, and content) with the pristine digest before the
  # sensor has a chance to create its own runtime artifacts.
  mutated="$tmp/mutated-$name"
  mkdir -p "$mutated"
  for file in $files; do
    mkdir -p "$mutated/$(dirname "$file")"
    cp -p "$work/$file" "$mutated/$file"
    cp -p "$backup/$file" "$work/$file"
  done
  restored_digest="$(tree_digest "$work")"
  if [ "$restored_digest" != "$pristine_digest" ]; then
    echo "FAIL: $name — mutation changed undeclared paths or metadata" >&2
    diff -qr "$pristine_reference" "$work" >&2 || true
    fail=$((fail + 1))
    continue
  fi
  for file in $files; do cp -p "$mutated/$file" "$work/$file"; done

  verify_log="$tmp/verify-$name.log"
  rc=0
  (cd "$work" && run_sensor "$sensor") >"$verify_log" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "FAIL: $name — '$sensor' stayed green" >&2
    fail=$((fail + 1))
  elif ! grep -F "FAIL: $expect" "$verify_log" >/dev/null 2>&1; then
    echo "FAIL: $name — sensor was red, but not at '$expect'" >&2
    tail -n 12 "$verify_log" | sed 's/^/  | /' >&2
    fail=$((fail + 1))
  else
    echo "PASS: $name -> $expect turned red"
    pass=$((pass + 1))
  fi
done

echo "----------------------------------------"
echo "mutation test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
