#!/usr/bin/env bash
# files: template/.claude/settings.json
# verify: consistency
# expect: hook present but NOT referenced in settings.json (.claude/hooks/stop-require-gates.sh)
set -euo pipefail

sed -i '/stop-require-gates\.sh/d' template/.claude/settings.json
