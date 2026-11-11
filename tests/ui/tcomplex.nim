import std/[syncio, math]
import yith/ui
import yith/dom/api

proc MathView(x: State[float]; y: State[float]): E {.ui.} =
  let z = sqrt(x.get()) / 10.0 + y.get() * 2.0 +
          (if y.get() < 0.0: 4.0 else: 8.0)
  let z2 = z * 2.0
  Text(z)
  Text(z2)
  let w = newState(2)
  c.Span.w:
    w

let root = createElement("div")
let sc = beginRoot(root)
let x = newState(1.0)
let y = newState(2.0)
let view = MathView(x, y)
echo toHtml(root)
x.set(4.0)
echo toHtml(root)
y.set(-1.0)
echo toHtml(root)
endRoot()
dispose(sc)
