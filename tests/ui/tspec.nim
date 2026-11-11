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

i = 0
while i < views.len:
  dispose(views[i])
  inc i
