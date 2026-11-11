import std/syncio
import yith/ui
import yith/uipragma
import yith/dom/api

proc View(open: State[bool]; items: State[seq[int]]): E {.ui.} =
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
let open = state(true)
let items = state(@[1, 2])
let view = View(open, items)
echo toHtml(root)
open.set(false)
echo toHtml(root)
items.set(@[3, 4])
echo toHtml(root)
endRoot()
dispose(sc)
