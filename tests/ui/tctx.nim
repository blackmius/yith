import std/syncio
import yith/ui
import yith/context
import yith/dom/api

type ChartData = object
  name: string

let ChartCtx = context[ChartData]()

template Chart(body: untyped) =
  El("svg"):
    provide(ChartCtx, ChartData(name: "c")):
      body

template Axis(label: string) =
  let d = use(ChartCtx)
  Text(label & ":" & d.name)

let root = createElement("div")
let sc = beginRoot(root)
let n = newState(0)

Chart():
  Axis("x")
  uiBlock(proc () {.closure.} =
    Axis("y" & $n.get()))

echo "initial: ", toHtml(root)
n.set 1
echo "after: ", toHtml(root)
endRoot()
dispose(sc)
