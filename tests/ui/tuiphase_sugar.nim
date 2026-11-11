
import std/syncio
import yith/ui
import yith/dom/api

proc View(name {.state.}: string; count {.state.}: int): E {.ui.} =
  let greeting = "hi " & name
  c.Div.root:
    c.Span.title:
      greeting
    c.Button.btn:
      onClick(e):
        name = name & "!"
        count += 1
      Text(count)

let root = createElement("div")
let sc = beginRoot(root)
var name {.state.}: string = "Ann"
var count {.state.}: int = 0
discard View(name, count)
echo toHtml(root)
echo "fired=", fire(find(root, ".btn"), "click")
echo toHtml(root)
echo "count=", count
endRoot()
dispose(sc)
