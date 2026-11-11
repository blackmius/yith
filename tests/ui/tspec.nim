import std/syncio
import yith/ui
import yith/dom/api

type Row = object
  id: int
  y: float

proc renderRow(s: Row): E =
  result = ElE("div"):
    Text("row " & $s.id)
  setAttr(result, "id", "row-" & $s.id)
  setAttr(result, "data-id", $s.id)
  addStyle(result, "transform", "translate(0px, " & $s.y & "px)")

let views = speculate(@[Row(id: 1, y: 10.0), Row(id: 2, y: 20.0)], renderRow)
var i = 0
while i < views.len:
  echo "view ", i, ": ", toHtml(views[i].root)
  let n = find(views[i], "#row-" & $views[i].state.id)
  if n != nil:
    echo "  id=", getAttribute(n, "data-id")
  inc i

proc measureY(n: Node; s: Row): Point =
  result = Point(x: 0.0, y: s.y)

echo "measured=", measure(views[0], "#row-1", measureY).y
let r0 = rect(views[0], "#row-1")
echo "rect=", r0.x, ",", r0.y, " ", r0.w, "x", r0.h

let targets = speculativeTargets(@[Row(id: 1, y: 10.0), Row(id: 1, y: 20.0)],
                                  renderRow, "#row-1")
echo "targets=", targets[0].pos.y, ",", targets[1].pos.y

if r0.y != 10.0 or r0.h != 16.0:
  panic("speculative rect mismatch")
if targets[0].pos.y != 18.0 or targets[1].pos.y != 28.0:
  panic("speculative target measurement mismatch")

i = 0
while i < views.len:
  dispose(views[i])
  inc i
