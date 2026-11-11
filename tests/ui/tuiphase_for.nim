{.rewriteModule("../../src/yith/uiblock_plugin").}

import std/syncio
import yith/ui
import yith/dom/api

proc View(items: State[seq[int]]): E {.ui.} =
  c.Div.list:
    for item in items:
      c.Span.item:
        item

let root = createElement("div")
let sc = beginRoot(root)
let items = state(@[1, 2])
discard View(items)
echo toHtml(root)
items.set(@[3, 4])
echo toHtml(root)
endRoot()
dispose(sc)
