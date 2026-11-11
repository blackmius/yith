## frameorc-like `c.Tag.class:` syntax: arbitrary tags, chained attrs/css/props,
## events, mount/cleanup and indentation children.
import std/syncio
import yith/ui
import yith/uipragma
import yith/dom/api

proc View(count, mounted, cleaned: State[int]): E {.ui.} =
  c.Div.cls1.cls2:
    c.Button.btn_default:
      attr.disabled(true).aria_label("Click")
      css.background_color("#eee").padding("4px").font_size(10, "px")
      prop.title("hello").tabIndex(3)
      onClick(e):
        count += 1
      onMount(e: El):
        mounted.set(stateValue(mounted) + 1)
      onCleanup():
        cleaned.set(stateValue(cleaned) + 1)
      "Click me"
    c.MyElement:
      "custom"

let root = createElement("div")
let sc = beginRoot(root)
let count = state(0)
let mounted = state(0)
let cleaned = state(0)
let view = View(count, mounted, cleaned)
echo toHtml(root)
let btn = find(root, ".btn-default")
echo "disabled=", getAttribute(btn, "disabled")
echo "aria=", getAttribute(btn, "aria-label")
echo "style=", getAttribute(btn, "style")
echo "title=", getProp(btn, "title")
echo "tab=", getProp(btn, "tabIndex")
echo "mounted=", mounted.get()
echo "fired=", fire(btn, "click")
echo "count=", count.get()
endRoot()
dispose(sc)
echo "cleaned=", cleaned.get()
