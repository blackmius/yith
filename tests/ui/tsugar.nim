{.feature: "assumeSync".}
import std/syncio
import yith/ui
import yith/dom/api

proc Counter(): E {.ui.} =
  let count = newState(0)
  c.Div.counter:
    c.Span.n:
      count
    c.Button.inc:
      onClick(e):
        count += 1
      "inc"

proc Toggle(open {.state.}: bool): E {.ui.} =
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

proc ListView(list {.state.}: seq[int]): E {.ui.} =
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
  let m = newState(0)
  c.Span.m:
    m
  c.Button.mbtn:
    onClick(e):
      m += 10
    "m"

let globalCount = newState(0)

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
var open {.state.}: bool = true
let toggle = Toggle(open)
let mutv = MutView()
var xs {.state.}: seq[int] = @[1, 2]
let lv = ListView(xs)
let gv = GlobalView()
echo toHtml(root)
echo fire(find(root, ".inc"), "click")
echo toHtml(root)
echo fire(find(root, ".toggle"), "click")
echo "open=", open
echo fire(find(root, ".ginc"), "click")
echo fire(find(root, ".mbtn"), "click")
echo fire(find(root, ".ladd"), "click")
echo "len=", xs.len
echo toHtml(root)
endRoot()
dispose(sc)
