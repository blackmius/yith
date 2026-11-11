{.feature: "assumeSync".}

import std/syncio
import yith/ui
import yith/dom/api

proc View(items {.state.}: seq[int]): E {.ui.} =
  c.Button.b:
    onClick(e):
      items.add(5)
    "add"
  c.Span.n:
    $items.len

let root = createElement("div")
let sc = beginRoot(root)
var items {.state.}: seq[int] = @[1, 2]
discard View(items)
echo toHtml(root)
echo "fired=", fire(find(root, ".b"), "click")
echo toHtml(root)
echo "len=", items.len
endRoot()
dispose(sc)
