## Debug overlay for declarative dragging: dots at the measured targets and
## lines between consecutive candidates. Toggle with `setDragOverlay(true)`.

{.feature: "assumeSync".}

import ./dom/api
import ./drag

when not defined(yithDomTest):
  var overlayNode: Node = nil

  proc hideOverlay*() =
    if overlayNode != nil:
      remove(overlayNode)
      overlayNode = nil

  proc showOverlay*[S](targets: seq[DragTarget[S]]) =
    hideOverlay()
    if targets.len == 0:
      return
    var html = "<svg style=\"position:absolute;left:0;top:0;width:100%;height:100%\">"
    var i = 0
    while i + 1 < targets.len:
      let a = targets[i].pos
      let b = targets[i + 1].pos
      html.add "<line x1=\"" & $a.x & "\" y1=\"" & $a.y &
               "\" x2=\"" & $b.x & "\" y2=\"" & $b.y &
               "\" stroke=\"#2d7ff9\" stroke-opacity=\".35\"/>"
      inc i
    i = 0
    while i < targets.len:
      let p = targets[i].pos
      html.add "<circle cx=\"" & $p.x & "\" cy=\"" & $p.y &
               "\" r=\"4\" fill=\"#2d7ff9\"/>"
      html.add "<text x=\"" & $(p.x + 7.0) & "\" y=\"" & $(p.y - 8.0) &
               "\" font-size=\"11\" fill=\"#2d7ff9\">" & $i & "</text>"
      inc i
    html.add "</svg>"
    overlayNode = createElement("div")
    setAttribute(overlayNode, "style",
      "position:fixed;left:0;top:0;width:100%;height:100%;" &
      "pointer-events:none;z-index:9999;")
    setHtml(overlayNode, html)
    appendToBody(overlayNode)
else:
  proc hideOverlay*() =
    discard

  proc showOverlay*[S](targets: seq[DragTarget[S]]) =
    discard
