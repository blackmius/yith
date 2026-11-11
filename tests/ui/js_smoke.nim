{.feature: "assumeSync".}

import std/syncio
import yith/dom/api
import yith/core
import yith/dsl

var root: Node
var gN: State[int]
var gOpen: State[bool]
var clicks = 0

proc start() {.exportc: "start".} =
  root = createElement("div")
  let sc = beginRoot(root)
  gN = newState(0)
  gOpen = newState(false)
  uiBlock(proc () {.closure.} =
    Box(className = "box"):
      Text("count=" & $gN.get())
      if gOpen.get():
        Text(" open")
      else:
        Text(" closed"))
  uiBlock(proc () {.closure.} =
    for i in 0 ..< 3:
      Text("i" & $i))
  uiBlock(proc () {.closure.} =
    let b = ButtonE(variant = "outline", className = "b", disabled = false):
      Text("click")
    OnClick(b):
      inc clicks)
  flushFile(stdout)

proc bump() {.exportc: "bump".} =
  gN.set gN.get() + 1

proc toggle() {.exportc: "toggle".} =
  gOpen.set not gOpen.get()

proc getClicks() {.exportc: "getClicks".} =
  echo clicks
  flushFile(stdout)

proc dump() {.exportc: "dump".} =
  echo jsStringify(root)
  flushFile(stdout)

echo "init"
flushFile(stdout)
