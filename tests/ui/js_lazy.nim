## JS regression: lazy `css`/`Text` inside a re-runnable block.
##
## These values used to be cached with `computedExpr` in the enclosing
## (shared) closure environment. Teardown released the state while the
## compiler's env slot still pointed at it, so the next render arcDec'd a
## dangling pointer. The lazy overloads evaluate their getter from an effect
## and create no derived State at the call site.
{.feature: "assumeSync".}
{.feature: "lenientnils".}

import std/syncio
import yith/ui
import yith/dom/api

type
  Point = object
    x*, y*: float
  Ctl = ref object
    pointer*: State[Point]
    active*: State[bool]
    title*: State[string]

var
  root: Node
  ctl: Ctl

proc GhostView(): E {.ui.} =
  c.Div.wrap:
    uiBlock(proc () {.closure.} =
      if ctl.active.get():
        c.Div.ghost:
          css.position("fixed")
          css.left($ctl.pointer.get().x & "px")
          css.top($ctl.pointer.get().y & "px")
          c.Span.task_title:
            ctl.title.get())

proc start() {.exportc: "start".} =
  root = createElement("div")
  let sc = beginRoot(root)
  ctl = Ctl(pointer: newState(Point(x: 0.0, y: 0.0)),
            active: newState(true),
            title: newState("g0.0"))
  discard GhostView()
  flushFile(stdout)

proc bump() {.exportc: "bump".} =
  ctl.pointer.set(Point(x: ctl.pointer.get().x + 1.0,
                        y: ctl.pointer.get().y + 2.0))
  ctl.title.set("g" & $ctl.pointer.get().x)

proc up() {.exportc: "up".} =
  ctl.active.set(false)

proc down() {.exportc: "down".} =
  ctl.active.set(true)

proc dump() {.exportc: "dump".} =
  echo jsStringify(root)
  flushFile(stdout)

echo "init"
flushFile(stdout)
