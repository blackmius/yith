import std/syncio
import yith/ui
import yith/dom/api

let root = createElement("div")
let sc = beginRoot(root)
let e = ElE("div"):
  Text("motion")
let m = bindMotion(e, motionValues(0.0, 0.0, 1.0, 0.0))
echo "initial: ", getAttribute(e.startNode, "style")

m.animateTo(motionValues(100.0, 0.0, 1.0, 1.0), tween(0.1))
discard m.tick(0.05)
echo "mid: ", getAttribute(e.startNode, "style")
discard m.tick(0.06)
echo "end: ", getAttribute(e.startNode, "style")
echo "stagger=", stagger(3, 0.15)

let e2 = ElE("div"):
  Text("spring")
let s = bindMotion(e2, motionValues(0.0))
s.animateTo(motionValues(10.0), spring(100.0, 15.0))
var i = 0
while i < 120:
  discard s.tick(0.016)
  inc i
echo "spring x=", s.current.x

endRoot()
dispose(sc)
