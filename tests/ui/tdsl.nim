import std/syncio

import yith/dom/api
import yith/core
import yith/dsl

proc main() =
  let root = createElement("div")
  let sc = beginRoot(root)

  let n = state(0)
  let open = state(false)
  let training = state(7)
  let items = state(@[1, 2, 3])

  var hits = 0

  uiBlock(proc () {.closure.} =
    let button = ButtonE(variant = "outline", className = "gap",
                         disabled = training.get() == -1):
      if training.get() == -1:
        Text("no training")
      else:
        Text("save " & $n.get())
    OnClick(button):
      inc hits

    Box(className = "space"):
      Text("count=" & $n.get())
      if open.get():
        Text("open!")
      else:
        Text("closed"))

  uiLoop(proc () {.closure.} =
    for i in 0 ..< items.get().len:
      Text("item " & $items.get()[i]))

  echo "initial: ", toHtml(root)
  echo "subs n=", subscriberCount(n), " open=", subscriberCount(open),
       " training=", subscriberCount(training),
       " items=", subscriberCount(items)

  n.set 1
  echo "bump: ", toHtml(root)

  open.set true
  echo "open: ", toHtml(root)

  training.set(-1)
  echo "training: ", toHtml(root)

  echo "fire: ", fire(find(root, "button"), "click"), " hits=", hits

  items.set @[4, 5]
  echo "items: ", toHtml(root)

  endRoot()
  dispose(sc)
  echo "disposed: ", toHtml(root)
  echo "subs n=", subscriberCount(n), " open=", subscriberCount(open),
       " training=", subscriberCount(training),
       " items=", subscriberCount(items)

main()
