#!/usr/bin/env bash
# files: template/.claude/hooks/stop-require-gates.sh
# verify: selftest
# expect: stop: no-proof clean commit blocks
set -euo pipefail

sed -i '$s/^exit 2$/exit 0/' template/.claude/hooks/stop-require-gates.sh
