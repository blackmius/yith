{.rewriteModule("../../src/yith/uiblock_plugin").}
{.feature: "assumeSync".}

import std/syncio
import yith/ui
import yith/dom/api
import ./tuiphase_cross_a

# Imported state can be aliased with `{.signal.}`: no wrapping, only reads and
# writes in this module are rewritten. An explicit `State[string]` type works
# the same way.
let theme {.signal.} = tuiphase_cross_a.theme

proc Direct(x {.state.}: string): E {.ui.} =
  c.Span.direct:
    x

proc View(theme {.state.}: string): E {.ui.} =
  c.Div.root:
    c.Span.t:
      theme
    c.Button.b:
      onClick(e):
        theme = "dark"
      "switch"

let root = createElement("div")
let sc = beginRoot(root)
discard View(theme)
echo toHtml(root)
echo "fired=", fire(find(root, ".b"), "click")
echo toHtml(root)
echo "a.theme=", tuiphase_cross_a.theme.get()

let root2 = createElement("div")
let sc2 = beginRoot(root2)
discard Direct(tuiphase_cross_a.theme)
echo toHtml(root2)
endRoot()
dispose(sc2)
endRoot()
dispose(sc)
