{.feature: "assumeSync".}

import std/syncio
import yith/ui
import yith/dom/api

var theme {.state.}: string = state("light")

proc View(): E {.ui.} =
  c.Div.root:
    c.Span.t:
      theme
    c.Button.b:
      onClick(e):
        theme = "dark"
      "switch"

let root = createElement("div")
let sc = beginRoot(root)
discard View()
echo toHtml(root)
echo "fired=", fire(find(root, ".b"), "click")
echo toHtml(root)
endRoot()
dispose(sc)

proc Local(): E {.ui.} =
  var n {.state.}: int = 7
  c.Span.local:
    n

let root2 = createElement("div")
let sc2 = beginRoot(root2)
discard Local()
echo toHtml(root2)
endRoot()
dispose(sc2)
