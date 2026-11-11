#!/usr/bin/env bash
# Build the browser kanban demo from the same `{.ui.}` component used by the
# C/test DOM example. A full clean avoids stale incremental artifacts from a
# previous Nimony/plugin build. Set YITH_DEBUG=1 to enable signal/scope
# lifecycle logs and the `NIF.dumpLog()` ring buffer.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NIMONY="${NIMONY:-$ROOT/../nimony/bin/nimony}"
export PATH="${JOROGUMO_DIR:-/tmp/nifjs}:$PATH"

rm -rf "$ROOT/nimcache"
rm -f "$ROOT/examples/ui/kanban.js"
defs=()
if [ "${YITH_DEBUG:-0}" != "0" ]; then
  defs+=("-d:yithDebugSignals")
fi
"$NIMONY" j --browser -p:"$ROOT/src" "${defs[@]}" "$ROOT/examples/ui/kanban.nim"
f="$(find "$ROOT/nimcache/j" -name kanban.js | head -1)"
if [ -z "$f" ]; then
  echo "no generated kanban.js" >&2
  exit 1
fi
cp "$f" "$ROOT/examples/ui/kanban.js"
echo "built examples/ui/kanban.js"
echo "  source: $(date -r "$ROOT/examples/ui/kanban.nim" -u +%FT%TZ)"
echo "  bundle: $(wc -c < "$ROOT/examples/ui/kanban.js") bytes"
if [ "${YITH_DEBUG:-0}" != "0" ]; then
  echo "  debug: yithDebugSignals (NIF.dumpLog())"
else
  echo "  debug: off (YITH_DEBUG=1 to enable)"
fi
echo "serve the repo and open:"
echo "  python3 -m http.server 8000"
echo "  http://localhost:8000/examples/ui/kanban.html"
