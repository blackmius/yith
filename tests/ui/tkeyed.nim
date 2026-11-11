{.feature: "assumeSync".}
import std/syncio
import yith/ui
import yith/dom/api

proc ListView(items {.state.}: seq[int];
              renders: State[int]): E {.ui.} =
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
let view = ListView(items, renders)
echo toHtml(root)
echo "r=", renders.get()
items = @[3, 1]
echo toHtml(root)
echo "r=", renders.get()
items = @[2, 3, 1]
echo toHtml(root)
echo "r=", renders.get()
endRoot()
dispose(sc)

proc LocalView(renders: State[int]): E {.ui.} =
  var items {.state.}: seq[int] = @[10, 20, 30]
  c.Div.local:
    for item in items:
      key item
      renders.set(stateValue(renders) + 1)
      c.Span.local_item:
        item

let root2 = createElement("div")
let sc2 = beginRoot(root2)
let renders2 = newState(0)
let view2 = LocalView(renders2)
echo toHtml(root2)
echo "lr=", renders2.get()
renders2.set(0)
endRoot()
dispose(sc2)

proc LocalTypedView(): E {.ui.} =
  var items {.state.}: seq[string] = @["u", "v"]
  c.Div.typed:
    for item in items:
      key item
      c.Span.typed_item:
        item

let root3 = createElement("div")
let sc3 = beginRoot(root3)
let view3 = LocalTypedView()
echo toHtml(root3)
endRoot()
dispose(sc3)
