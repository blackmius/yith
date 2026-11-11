## JS/passive `Resource`: loading -> ready, source change restarts, and a
## late response from the previous generation is dropped. The DSL macro is
## intentionally not imported: Nimony's JS build currently cannot import
## `std/macros` (FAIL under `docs/nimony-issues.md` #25).
{.feature: "assumeSync".}

import std/syncio
import yith/dom/api
import yith/core
import yith/dsl
import yith/resource
import yith/fetch

var root: Node
var who: State[string]
var user: Resource[string]

proc start() {.exportc: "start".} =
  root = createElement("div")
  let sc = beginRoot(root)
  who = state("a")
  user = resource(proc (): string {.passive.} =
    awaitText("/user/" & who.get()))
  uiBlock(proc () {.closure.} =
    let rv = user.value.get()
    if rv.kind == resReady:
      Text(user.data.get())
    elif rv.kind == resLoading:
      Text("loading")
    else:
      Text("error"))
  flushFile(stdout)

proc swap() {.exportc: "swap".} =
  who.set("b")

proc dump() {.exportc: "dump".} =
  echo jsStringify(root)
  flushFile(stdout)

echo "init"
flushFile(stdout)
