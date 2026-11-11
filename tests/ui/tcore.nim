import std/syncio

import yith/dom/api
import yith/core
import yith/dsl

proc main() =
  let root = createElement("div")
  let sc = beginRoot(root)

  let n = newState(0)
  uiBlock(proc () {.closure.} =
    Text("count=" & $n.get()))

  echo "initial: ", toHtml(root)
  echo "subs: ", subscriberCount(n)

  n.set 1
  echo "after set: ", toHtml(root)
  n.set 2
  echo "after set2: ", toHtml(root)
  echo "subs: ", subscriberCount(n)

  endRoot()
  dispose(sc)
  echo "after dispose: ", toHtml(root)
  echo "subs: ", subscriberCount(n)

main()
