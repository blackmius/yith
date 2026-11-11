
import std/syncio
import yith/ui
import yith/dom/api

proc ListView(items {.state.}: seq[int]; renders: State[int]): E {.ui.} =
  c.Div.list:
    for item in items:
      key item
      renders.set(stateValue(renders) + 1)
      c.Span.item:
        item

let root = createElement("div")
let sc = beginRoot(root)
var items {.state.}: seq[int] = @[1, 2, 3]
let renders = newState(0)
discard ListView(items, renders)
echo toHtml(root)
echo "r=", renders.get()
items = @[3, 1]
echo toHtml(root)
echo "r=", renders.get()
endRoot()
dispose(sc)
