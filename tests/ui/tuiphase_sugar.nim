{.rewriteModule("../../src/yith/uiblock_plugin").}

import std/syncio
import yith/ui
import yith/dom/api

proc View(name {.state.}: string; count {.state.}: int): E {.ui.} =
  let greeting = "hi " & name
  c.Div.root:
    c.Span.title:
      greeting
    c.Button.btn:
      onClick(e):
        name = name & "!"
        count += 1
      Text(count)

let root = createElement("div")
let sc = beginRoot(root)
let name = state("Ann")
let count = state(0)
discard View(name, count)
echo toHtml(root)
echo "fired=", fire(find(root, ".btn"), "click")
echo toHtml(root)
echo "count=", count.get()
endRoot()
dispose(sc)
