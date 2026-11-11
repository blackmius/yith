import std/syncio
import yith/ui
import yith/dom/api

let root = createElement("div")
let sc = beginRoot(root)
let n = state(0)
uiBlock(proc () {.closure.} =
  Box(className = "x"):
    Text("n=" & $n.get()))
n.set 3
echo toHtml(root)
endRoot()
dispose(sc)
