import std/syncio
import yith/ui
import yith/dom/api

let cleaned = newState(false)

proc Panel(children: proc () {.closure.}): E {.ui.} =
  c.Div.panel:
    children()

proc Styled(s: State[string]): E {.ui.} =
  c.Div.styled:
    css.display("flex").color(s)
    "S"

proc Pair(): E {.ui.} =
  c.Span.a:
    "A"
  c.Span.b:
    "B"

proc Layout(title: proc () {.closure.};
            children: proc () {.closure.}): E {.ui.} =
  c.Div.layout:
    c.Div.head:
      title()
    c.Div.body:
      children()

proc Page(): E {.ui.} =
  Layout():
    slot title:
      c.Span.t:
        "Title"
    c.Span.c:
      "Content"

proc ComputedView(c: Computed[int]): E {.ui.} =
  c.Span.computed:
    c

proc Card(name: State[string]; active: State[bool];
          clicks: State[int]): E {.ui.} =
  Panel():
    c.Div.card.extra:
      cls(name)
      cls.active(active)
      css.display("flex").gap("8px").color("red")
      attr.data_id("c1").aria_label("Card")
      c.Span.title:
        "Hello"
      c.Span.name:
        name
      c.Button.btn:
        attr.disabled(active)
        onMount(e):
          e.attr("data-created", "1")
        onCleanup():
          cleaned.set(true)
        onClick(e):
          clicks.set(clicks.get() + 1)
        clicks
      c.Input.field:
        prop.value(name).checked(active)

let root = createElement("div")
let sc = beginRoot(root)
let name = newState("Bob")
let active = newState(true)
let clicks = newState(0)
let styleState = newState("red")
let card = Card(name, active, clicks)
let styled = Styled(styleState)
let pair = Pair()
let page = Page()
let n = newState(2)
let c = computed(proc (): int = n.get() * 2)
let cv = ComputedView(c)
echo toHtml(root)
dispose(pair.scope)
echo "pair gone: ", toHtml(root)
styleState.set("blue")
echo toHtml(root)
let input = find(root, "input")
echo "value=", getProp(input, "value"), " checked=", getProp(input, "checked")
name.set("Ann")
active.set(false)
echo "value=", getProp(input, "value"), " checked=", getProp(input, "checked")
echo fire(find(root, "button"), "click")
echo toHtml(root)
n.set(4)
echo toHtml(root)
endRoot()
dispose(sc)
echo "cleaned=", cleaned.get()
