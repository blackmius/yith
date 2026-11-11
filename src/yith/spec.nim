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
import ./overlay
import ./layout
import ./dom/api

type
  SpecView*[S] = object
    state*: S
    root*: Node
    scope*: Scope

proc speculateOne*[S](state: S;
                      render: proc (s: S): E {.closure.};
                      frame: Rect = Rect()): SpecView[S] =
  ## Render one state into a hidden, laid-out host. In the browser the host
  ## is attached with `visibility:hidden`, so CSS layout (flex, absolute
  ## positioning, transforms) is real and `bounds` can measure it. `frame`
  ## copies the live container's width/height when known.
  let root = createHiddenHost(frame.w, frame.h)
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

type
  DragZone*[S] = ref object
    ## A live container plus the rules for what it can become. The zone owns
    ## speculative measurement (using the container's frame) and starts the
    ## controller; the application still owns the view and the state rules.
    model*: State[S]
    container*: Node
    render*: proc (s: S): E {.closure.}
    statesOf*: proc (s: S): seq[S] {.closure.}
    selector*: proc (s: S): string {.closure.}
    grabbedSelector*: string
    ghostSelector*: string
    controller*: DragController[S]
    snap*: float
    startState*: S
    animSelector*: string
    hideDropContent*: bool
    token*: string
    duration*: int

proc newDragZone*[S](model: State[S]; container: Node;
                     render: proc (s: S): E {.closure.};
                     statesOf: proc (s: S): seq[S] {.closure.};
                     selector: proc (s: S): string {.closure.};
                     grabbedSelector: string;
                     controller: DragController[S];
                     snap: float = 0.0;
                     animSelector = ".card, .col";
                     duration = 160;
                     ghostSelector = "";
                     hideDropContent = false): DragZone[S] =
  result = DragZone[S](model: model, container: container, render: render,
                       statesOf: statesOf, selector: selector,
                       grabbedSelector: grabbedSelector,
                       ghostSelector: ghostSelector, controller: controller,
                       snap: snap, animSelector: animSelector,
                       hideDropContent: hideDropContent,
                       token: "yith-drag", duration: duration)

proc start*[S](z: DragZone[S]; p: Point) =
  ## Render every state returned by `statesOf` in a host framed like the live
  ## container, measure `selector(state)`, and start the controller.
  let s = z.model.get()
  let states = z.statesOf(s)
  let targets = speculativeTargets(states, z.render, z.selector(s),
                                   z.container)
  z.controller.start(closest(targets).withSnap(z.snap).withFloating(), p)
  z.startState = s
  disarmLayout()
  armLayout(z.container, z.animSelector, z.token, z.duration)
  if dragOverlayEnabled:
    showOverlay(targets)

proc move*[S](z: DragZone[S]; p: Point): bool =
  ## Update the pointer/target. Re-render and FLIP-animate only when the
  ## chosen target actually changes.
  if not z.controller.active.get():
    return false
  let prevTarget = z.controller.target.get()
  let prevFar = z.controller.far.get()
  discard z.controller.move(p)
  result = z.controller.target.get() != prevTarget or
           z.controller.far.get() != prevFar
  if result:
    z.model.set(z.controller.previewState(z.startState))
    flush()

proc drop*[S](z: DragZone[S]): S =
  ## Finish the drag and animate the grabbed element from the pointer to its
  ## new box; all other id'd elements FLIP from their old boxes.
  let pointer = z.controller.pointer.get()
  var ghostW = 0.0
  var ghostH = 0.0
  if z.ghostSelector.len > 0 and z.container != nil:
    let ghost = find(z.container, z.ghostSelector)
    if ghost != nil:
      let gr = bounds(ghost)
      ghostW = gr.w
      ghostH = gr.h
  var next = z.startState
  if z.controller.hasDrop():
    next = z.controller.chosen().state
  armDrop(z.grabbedSelector, pointer.x, pointer.y, ghostW, ghostH,
          z.hideDropContent)
  discard z.controller.finish()
  z.model.set(next)
  flush()
  result = next

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
  var frame = Rect()
  if origin != nil:
    frame = bounds(origin)
    ox = frame.x
    oy = frame.y
  var i = 0
  while i < states.len:
    let v = speculateOne(states[i], render, frame)
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
  var frame = Rect()
  if origin != nil:
    frame = bounds(origin)
    ox = frame.x
    oy = frame.y
  var i = 0
  while i < states.len:
    let v = speculateOne(states[i], render, frame)
    let r = rect(v, selector(states[i]))
    var p = centerOf(r)
    if origin != nil:
      let h = bounds(v.root)
      p.x = p.x - h.x + ox
      p.y = p.y - h.y + oy
    result.add DragTarget[S](state: states[i], pos: p)
    dispose(v)
    inc i
