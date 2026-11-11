{.feature: "assumeSync".}

import std/syncio
import yith/dom/api
import yith/core
import yith/dsl
import yith/async
import yith/fetch

var root: Node
var text: State[string]
var flag: State[bool]

proc start() {.exportc: "start".} =
  root = createElement("div")
  let sc = beginRoot(root)
  text = newState("loading")
  flag = newState(false)
  effect:
    let s = awaitText("data:text/plain,hello")
    text.set s
  uiBlock(proc () {.closure.} =
    Text(text.get() & " f=" & $flag.get()))
  flushFile(stdout)

proc toggle() {.exportc: "toggle".} =
  flag.set not flag.get()

proc dump() {.exportc: "dump".} =
  echo jsStringify(root)
  flushFile(stdout)

echo "init"
flushFile(stdout)
