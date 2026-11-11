## Speculative rendering: render a model state into a hidden DOM tree and
## inspect/measure it without touching the live UI.
##
## In the browser the hidden host is attached with `visibility:hidden` (not
## `display:none`), so normal CSS layout runs and `bounds` can read
## `getBoundingClientRect`. The C test DOM has a small layout pass for
## block/flex flow, padding, gap, absolute positioning and translate
## transforms.
##
## This is the foundation for model-driven dragging: candidate states are
## rendered, the dragged element is measured, and the resulting centers become
## `DragTarget` positions. No row/column math is hard-coded in drag plans.

{.feature: "lenientnils".}

import ./core
import ./dsl
import ./drag
import ./dom/api

type
  SpecView*[S] = object
    state*: S
    root*: Node
    scope*: Scope

proc speculateOne*[S](state: S;
                      render: proc (s: S): E {.closure.}): SpecView[S] =
  ## Render one state into a hidden, laid-out host. In the browser the host
  ## is attached with `visibility:hidden`, so CSS layout (flex, absolute
  ## positioning, transforms) is real and `bounds` can measure it.
  let root = createHiddenHost()
  # A speculative view is only measured; registering its event handlers would
  # create live closures for a tree that is immediately disposed.
  let prevSuppressed = eventsSuppressed
  eventsSuppressed = true
  let sc = beginRoot(root)
  discard render(state)
  endRoot()
  eventsSuppressed = prevSuppressed
  result = SpecView[S](state: state, root: root, scope: sc)

proc speculate*[S](states: seq[S];
                   render: proc (s: S): E {.closure.}): seq[SpecView[S]] =
  result = @[]
  var i = 0
  while i < states.len:
    result.add speculateOne(states[i], render)
    inc i

proc dispose*[S](v: SpecView[S]) =
  if v.scope != nil:
    dispose(v.scope)
  if v.root != nil:
    remove(v.root)

proc findNode*[S](v: SpecView[S]; selector: string): Node =
  result = find(v.root, selector)

proc rect*[S](v: SpecView[S]; selector: string): Rect =
  ## Border box of the first match in the speculative render. Empty when the
  ## selector does not match.
  let n = find(v.root, selector)
  if n == nil:
    result = Rect()
  else:
    result = bounds(n)

proc centerOf(r: Rect): Point =
  result = Point(x: r.x + r.w / 2.0, y: r.y + r.h / 2.0)

proc speculativeTargets*[S](states: seq[S];
                            render: proc (s: S): E {.closure.};
                            selector: string;
                            origin: Node = nil): seq[DragTarget[S]] =
  ## Render every candidate state into the hidden host, measure the element
  ## matching `selector`, and use its center as the drop position. This is
  ## how drag plans stop hard-coding row/column coordinates: the component's
  ## own CSS decides where things land.
  ##
  ## The hidden host is placed off-screen in the browser, so `bounds` reports
  ## coordinates shifted by the host's own origin. Pass the live render root
  ## as `origin` to express the targets in the same client coordinate frame
  ## as pointer events; without it the measured coordinates are only useful
  ## when the caller compares them in the hidden host's frame (the C/test DOM
  ## backend re-roots every measurement at 0,0).
  result = @[]
  var ox = 0.0
  var oy = 0.0
  if origin != nil:
    let o = bounds(origin)
    ox = o.x
    oy = o.y
  var i = 0
  while i < states.len:
    let v = speculateOne(states[i], render)
    let r = rect(v, selector)
    var p = centerOf(r)
    if origin != nil:
      let h = bounds(v.root)
      p.x = p.x - h.x + ox
      p.y = p.y - h.y + oy
    result.add DragTarget[S](state: states[i], pos: p)
    dispose(v)
    inc i

proc speculativeTargets*[S](states: seq[S];
                            render: proc (s: S): E {.closure.};
                            selector: proc (s: S): string {.closure.};
                            origin: Node = nil): seq[DragTarget[S]] =
  result = @[]
  var ox = 0.0
  var oy = 0.0
  if origin != nil:
    let o = bounds(origin)
    ox = o.x
    oy = o.y
  var i = 0
  while i < states.len:
    let v = speculateOne(states[i], render)
    let r = rect(v, selector(states[i]))
    var p = centerOf(r)
    if origin != nil:
      let h = bounds(v.root)
      p.x = p.x - h.x + ox
      p.y = p.y - h.y + oy
    result.add DragTarget[S](state: states[i], pos: p)
    dispose(v)
    inc i
