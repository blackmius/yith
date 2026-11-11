{.feature: "assumeSync".}

import std/syncio
import yith/ui
import yith/dom/api
import ./tuiphase_cross_a

# An imported state is a normal `State[string]`; give it an explicit type so the
# post-sem pass knows to use it as a state inside this module too.
let theme: State[string] = tuiphase_cross_a.theme

proc Direct(x: State[string]): E {.ui.} =
  c.Span.direct:
    x.get()

proc View(theme: State[string]): E {.ui.} =
  c.Div.root:
    c.Span.t:
      theme.get()
    c.Button.b:
      onClick(e):
        theme.set("dark")
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
discard Direct(theme)
echo toHtml(root2)
endRoot()
dispose(sc2)
endRoot()
dispose(sc)
