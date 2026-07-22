#!/usr/bin/env bash
# files: template/migration/tools/working-tree-hash.sh
# verify: selftest
# expect: hash: file deletion changes hash
set -euo pipefail

sed -i 's/if \[ -e "$p" \] || \[ -n "$(GIT_INDEX_FILE="$tmp_index" git ls-files -- "$p" 2>\/dev\/null)" \]; then/if [ -e "$p" ]; then/' \
  template/migration/tools/working-tree-hash.sh
