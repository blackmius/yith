{.feature: "assumeSync".}
import std/syncio
import yith/ui
import yith/dom/api

proc View(open {.state.}: bool; items {.state.}: seq[int]): E {.ui.} =
  c.Div.v:
    if open:
      c.Span.open:
        "open"
    else:
      c.Span.closed:
        "closed"
    for item in items:
      c.Span.item:
        item

let root = createElement("div")
let sc = beginRoot(root)
var open {.state.}: bool = true
var items {.state.}: seq[int] = @[1, 2]
let view = View(open, items)
echo toHtml(root)
open = false
echo toHtml(root)
items = @[3, 4]
echo toHtml(root)
endRoot()
dispose(sc)
