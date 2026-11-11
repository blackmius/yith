{.feature: "assumeSync".}

import std/syncio
import yith/dom/api
import yith/core
import yith/dsl
import yith/uiblock

ui:
  proc View(): E =
    c.Div.root:
      attr.id("root")
      c.Span.title:
        "hello"
      c.Button.btn:
        onClick(e):
          echo "clicked"
        "click"

var root: Node

proc start() {.exportc: "start".} =
  root = createElement("div")
  let sc = beginRoot(root)
  discard View()
  flushFile(stdout)

proc dump() {.exportc: "dump".} =
  echo jsStringify(root)
  flushFile(stdout)

echo "init"
flushFile(stdout)
