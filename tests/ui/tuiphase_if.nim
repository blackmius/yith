
import std/syncio
import yith/ui
import yith/dom/api

proc View(name: State[string]): E {.ui.} =
  c.Div.root:
    if name.get() == "Ann":
      c.Span.a:
        "hello Ann"
    elif name.get() == "Bob":
      c.Span.b:
        "hello Bob"
    else:
      "stranger"
    if name.get() != "Ann":
      c.Em.x:
        "not ann"

let root = createElement("div")
let sc = beginRoot(root)
let name = newState("Ann")
discard View(name)
echo toHtml(root)
name.set("Bob")
echo toHtml(root)
name.set("Zoe")
echo toHtml(root)
endRoot()
dispose(sc)
