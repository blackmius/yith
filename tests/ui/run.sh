#!/usr/bin/env bash
# yith unit tests on the C backend with the test DOM.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NIMONY="${NIMONY:-$ROOT/../nimony/bin/nimony}"
mkdir -p "$ROOT/bin"
for t in tcore tdsl tui tctx tdeep toption tfeatures tcomputed tsugar tresource taresource targresource tcomplex tcontrol tforeach tkeyed tcombinator tdrag tmotion tspec tuiplugin tuiphase tuiphase_sugar tuiphase_for tuiphase_if tuiphase_method tuiphase_keyed tuiphase_state tuiphase_cross_b; do
  "$NIMONY" c -f -d:yithDomTest -p:"$ROOT/src" \
    "$ROOT/tests/ui/$t.nim" -o:"$ROOT/bin/ui_$t"
  "$ROOT/bin/ui_$t"
done

# Declarative dragging example (model-driven kanban).
"$NIMONY" c -f -d:yithDomTest -p:"$ROOT/src" \
  "$ROOT/examples/ui/kanban.nim" -o:"$ROOT/bin/kanban"
"$ROOT/bin/kanban"

# Declarative dragging: rows/tiles with closest + whenFar + withFloating.
"$NIMONY" c -f -d:yithDomTest -p:"$ROOT/src" \
  "$ROOT/examples/ui/rows.nim" -o:"$ROOT/bin/rows"
"$ROOT/bin/rows"
