#!/usr/bin/env bash
# files: template/migration/tools/gates.sh
# verify: e2e
# expect: e2e: gate FAILS when locked tooling drifts
set -euo pipefail

sed -i '/bash migration\/tools\/check-locked\.sh >&2 \\/,/|| fail "locked tooling failed integrity check/d' \
  template/migration/tools/gates.sh
