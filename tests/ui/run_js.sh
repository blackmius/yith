#!/usr/bin/env bash
# yith JS tests: compile with `nimony j` and run the generated module under
# Node with the matching DOM/fetch harness.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NIMONY="${NIMONY:-$ROOT/../nimony/bin/nimony}"
export PATH="${JOROGUMO_DIR:-/tmp/nifjs}:$PATH"

run() {
  local t="$1" harness="$2"
  rm -rf "$ROOT/nimcache/j"
  "$NIMONY" j --browser -p:"$ROOT/src" "$ROOT/tests/ui/$t.nim"
  local f
  f="$(find "$ROOT/nimcache/j" -name "$t.js" | head -1)"
  if [ -z "$f" ]; then
    echo "no generated JS for $t" >&2
    return 1
  fi
  node "$ROOT/tests/ui/$harness" "$f"
}

run js_smoke js_harness.js
run js_async js_async_harness.js
run js_aresource js_aresource_harness.js
run js_uiblock js_uiblock_harness.js
run js_uiphase js_uiblock_harness.js
