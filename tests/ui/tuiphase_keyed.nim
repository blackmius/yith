{.rewriteModule("../../src/yith/uiblock_plugin").}

import std/syncio
import yith/ui
import yith/dom/api

proc ListView(items {.state.}: seq[int]; renders {.state.}: int): E {.ui.} =
  c.Div.list:
    for item in items:
      key item
      renders.set(stateValue(renders) + 1)
      c.Span.item:
        item

let root = createElement("div")
let sc = beginRoot(root)
let items = state(@[1, 2, 3])
let renders = state(0)
discard ListView(items, renders)
echo toHtml(root)
echo "r=", renders.get()
items.set(@[3, 1])
echo toHtml(root)
echo "r=", renders.get()
endRoot()
dispose(sc)
