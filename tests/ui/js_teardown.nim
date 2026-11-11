## JS regression: nested `{.ui.}` fragments inside a re-runnable `uiBlock`.
##
## When the block re-renders, `killScope` tears down the old fragment scopes.
## Those scopes own DOM nodes, which the JS backend represents as opaque host
## handles; treating a handle as an ARC-managed `ref` used to deallocate the
## handle's numeric value and crash with a DataView out-of-bounds error.
{.feature: "assumeSync".}

import std/syncio
import yith/dom/api
import yith/core
import yith/dsl
import yith/uiblock

proc Leaf(n: int): E {.ui.} =
  c.Span.leaf:
    $n

proc Child(n: int): E {.ui.} =
  c.Div.child:
    Leaf(n)
    Leaf(n + 1)
    Leaf(n + 2)

var
  root: Node
  counter: State[int]

proc start() {.exportc: "start".} =
  root = createElement("div")
  let sc = beginRoot(root)
  counter = newState(0)
  uiBlock(proc () {.closure.} =
    Text("n=" & $counter.get())
    for i in 0 ..< 3:
      Child(counter.get() + i))
  flushFile(stdout)

proc bump() {.exportc: "bump".} =
  counter.set(counter.get() + 1)

proc dump() {.exportc: "dump".} =
  echo jsStringify(root)
  flushFile(stdout)

echo "init"
flushFile(stdout)
