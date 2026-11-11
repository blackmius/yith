import std/syncio
import yith/ui
import yith/uipragma
import yith/dom/api

proc ListView(items: State[seq[int]];
              renders: State[int]): E {.ui.} =
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
let view = ListView(items, renders)
echo toHtml(root)
echo "r=", renders.get()
items.set(@[3, 1])
echo toHtml(root)
echo "r=", renders.get()
items.set(@[2, 3, 1])
echo toHtml(root)
echo "r=", renders.get()
endRoot()
dispose(sc)

proc LocalView(renders: State[int]): E {.ui.} =
  let items = state(@[10, 20, 30])
  c.Div.local:
    for item in items:
      key item
      renders.set(stateValue(renders) + 1)
      c.Span.local_item:
        item

let root2 = createElement("div")
let sc2 = beginRoot(root2)
let renders2 = state(0)
let view2 = LocalView(renders2)
echo toHtml(root2)
echo "lr=", renders2.get()
renders2.set(0)
endRoot()
dispose(sc2)

proc LocalTypedView(): E {.ui.} =
  let items: State[seq[string]] = state(@["u", "v"])
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
