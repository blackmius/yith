import std/syncio
import yith/ui
import yith/uipragma
import yith/dom/api

proc Counter(): E {.ui.} =
  let count = state(0)
  c.Div.counter:
    c.Span.n:
      count
    c.Button.inc:
      onClick(e):
        count += 1
      "inc"

proc Toggle(open: State[bool]): E {.ui.} =
  c.Button.toggle:
    onClick(e):
      open = false
    "toggle"

proc bump(x: var int) =
  x += 10

proc hasTwo(xs: seq[int]): bool =
  var i = 0
  while i < xs.len:
    if xs[i] == 2:
      return true
    inc i
  result = false

proc total(xs: seq[int]): int =
  var total = 0
  var i = 0
  while i < xs.len:
    total += xs[i]
    inc i
  result = total

proc ListView(list: State[seq[int]]): E {.ui.} =
  c.Span.len:
    Text(list.len)
  c.Span.len2:
    list.len
  c.Span.total:
    list.total
  c.Span.has:
    list.hasTwo()
  c.Button.ladd:
    onClick(e):
      list.add(3)
    "add"

proc MutView(): E {.ui.} =
  let m = state(0)
  c.Span.m:
    m
  c.Button.mbtn:
    onClick(e):
      m.bump()
    "m"

let globalCount = state(0)

proc GlobalView(): E {.ui.} =
  c.Span.global:
    globalCount
  c.Button.ginc:
    onClick(e):
      globalCount += 1
    "g"

let root = createElement("div")
let sc = beginRoot(root)
let counter = Counter()
let open = state(true)
let toggle = Toggle(open)
let mutv = MutView()
let xs = state(@[1, 2])
let lv = ListView(xs)
let gv = GlobalView()
echo toHtml(root)
echo fire(find(root, ".inc"), "click")
echo toHtml(root)
echo fire(find(root, ".toggle"), "click")
echo "open=", open.get()
echo fire(find(root, ".ginc"), "click")
echo fire(find(root, ".mbtn"), "click")
echo fire(find(root, ".ladd"), "click")
echo "len=", xs.get().len
echo toHtml(root)
endRoot()
dispose(sc)
