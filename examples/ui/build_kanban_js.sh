#!/usr/bin/env bash
# Build the browser kanban demo. The app itself is runtime-DSL because the
# `{.ui.}` macro cannot target JS yet (std/macros issue #25).
# Known: the initial board renders; drop currently hits issue #27 (JS
# scope teardown/DataView crash).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NIMONY="${NIMONY:-$ROOT/../nimony/bin/nimony}"
export PATH="${JOROGUMO_DIR:-/tmp/nifjs}:$PATH"

rm -rf "$ROOT/nimcache/j"
"$NIMONY" j --browser -p:"$ROOT/src" "$ROOT/examples/ui/kanban_js.nim"
f="$(find "$ROOT/nimcache/j" -name kanban_js.js | head -1)"
if [ -z "$f" ]; then
  echo "no generated kanban_js.js" >&2
  exit 1
fi
cp "$f" "$ROOT/examples/ui/kanban.js"
echo "built examples/ui/kanban.js"
echo "serve the repo and open:"
echo "  python3 -m http.server 8000"
echo "  http://localhost:8000/examples/ui/kanban.html"
