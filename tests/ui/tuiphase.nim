{.rewriteModule("../../src/yith/uiblock_plugin").}

import std/syncio
import yith/ui
import yith/dom/api

proc View(): E {.ui.} =
  c.Div.cls:
    attr.id("root")
    c.Span.title:
      "hello"
    c.Button.btn:
      onClick(e):
        echo "clicked"
      "click"

let root = createElement("div")
let sc = beginRoot(root)
discard View()
echo toHtml(root)
echo "fired=", fire(find(root, ".btn"), "click")
endRoot()
dispose(sc)
