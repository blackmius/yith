{.rewriteModule("../../src/yith/uiblock_plugin").}

import std/syncio
import yith/ui
import yith/dom/api

proc View(items: State[seq[int]]): E {.ui.} =
  c.Button.b:
    onClick(e):
      items.add(5)
    "add"
  c.Span.n:
    $items.get().len

let root = createElement("div")
let sc = beginRoot(root)
let items = state(@[1, 2])
discard View(items)
echo toHtml(root)
echo "fired=", fire(find(root, ".b"), "click")
echo toHtml(root)
echo "len=", items.get().len
endRoot()
dispose(sc)
