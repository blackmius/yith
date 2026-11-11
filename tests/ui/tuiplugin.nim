import std/syncio
import yith/dom/api
import yith/ui
import yith/uiblock

ui:
  proc View(): E =
    c.Div.cls1:
      attr.id("root")
      c.Span.title:
        "hello"
      c.Button.btn:
        onClick(e):
          echo "clicked"
        "click"

let root = createElement("div")
let sc = beginRoot(root)
let view = View()
echo toHtml(root)
echo "fired=", fire(find(root, ".btn"), "click")
endRoot()
dispose(sc)
