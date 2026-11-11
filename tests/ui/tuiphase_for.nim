
import std/syncio
import yith/ui
import yith/dom/api

proc View(items {.state.}: seq[int]): E {.ui.} =
  c.Div.list:
    for item in items:
      c.Span.item:
        item

let root = createElement("div")
let sc = beginRoot(root)
var items {.state.}: seq[int] = @[1, 2]
discard View(items)
echo toHtml(root)
items = @[3, 4]
echo toHtml(root)
endRoot()
dispose(sc)
