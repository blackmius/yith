## Speculative rendering: render a model state into a detached DOM tree and
## inspect/measure it without touching the live UI.
##
## This is the foundation for model-driven dragging and layout animation:
## target states can be rendered offscreen, measured, then disposed.

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
  let root = createElement("div")
  let sc = beginRoot(root)
  discard render(state)
  endRoot()
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

proc find*[S](v: SpecView[S]; selector: string): Node =
  result = find(v.root, selector)

proc measure*[S](v: SpecView[S]; selector: string;
                 f: proc (n: Node; s: S): Point {.closure.}): Point =
  let n = find(v.root, selector)
  if n == nil:
    result = Point(x: 0.0, y: 0.0)
  else:
    result = f(n, v.state)
