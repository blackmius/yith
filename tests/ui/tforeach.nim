import std/syncio
import yith/ui
import yith/dom/api

proc ListView(items: State[seq[int]]): E =
  ElE("div"):
    forEachList(items,
      same = proc (a, b: int): bool =
        a == b,
      key = proc (item: int): string =
        $item,
      render = proc (item: int): E =
        ElE("span"):
          Text($item))

let root = createElement("div")
let sc = beginRoot(root)
let items = newState(@[1, 2, 3])
let view = ListView(items)
echo toHtml(root)
items.set(@[3, 1])
echo toHtml(root)
items.set(@[2, 3, 1])
echo toHtml(root)
endRoot()
dispose(sc)
