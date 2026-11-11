## JS syntax plugin: both entry forms in one module.
##
## `ui:` uses the plugin-backed template as a block; `{.ui.}` invokes the same
## template as a routine pragma. They share one generated module and harness.
{.feature: "assumeSync".}

import std/syncio
import yith/dom/api
import yith/ui

ui:
  proc BlockView(): E =
    c.Div.block_root:
      attr.id("block-root")
      c.Span.title:
        "block"
      c.Button.block_btn:
        onClick(e):
          echo "clicked"
        "click"

proc PragmaView(): E {.ui.} =
  c.Div.pragma_root:
    attr.id("pragma-root")
    c.Span.title:
      "pragma"
    c.Button.pragma_btn:
      onClick(e):
        echo "clicked"
      "click"

var root: Node

proc start() {.exportc: "start".} =
  root = createElement("div")
  let sc = beginRoot(root)
  discard BlockView()
  discard PragmaView()
  flushFile(stdout)

proc dump() {.exportc: "dump".} =
  echo jsStringify(root)
  flushFile(stdout)

echo "init"
flushFile(stdout)
