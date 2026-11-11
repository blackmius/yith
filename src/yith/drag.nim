## Declarative dragging, first composable slice.
##
## Model-driven part: an app enumerates target model states. Their positions
## come from speculative rendering (`spec.speculativeTargets`), which measures
## real DOM/CSS layout in a hidden host. The controller tracks the pointer and
## the closest target. `closest(...).whenFar(fallback).withFloating()` mirrors
## the Dragology operators from the paper.

import ./core

type
  Point* = object
    x*, y*: float

  DragTarget*[S] = object
    state*: S
    pos*: Point

  DragBehavior*[S] = object
    targets*: seq[DragTarget[S]]
    farTargets*: seq[DragTarget[S]]
    farRadius*: float
    floating*: bool

  DragController*[S] = ref object
    pointer*: State[Point]
    active*: State[bool]
    target*: State[int]
    far*: State[bool]
    targets*: seq[DragTarget[S]]
    farTargets*: seq[DragTarget[S]]
    farRadius*: float
    floating*: bool

proc newDragController*[S](): DragController[S] =
  result = DragController[S](
    pointer: newState(Point(x: 0.0, y: 0.0)),
    active: newState(false),
    target: newState(-1),
    far: newState(false))

proc dist2(a, b: Point): float =
  let dx = a.x - b.x
  let dy = a.y - b.y
  result = dx * dx + dy * dy

proc nearest*[S](targets: seq[DragTarget[S]]; p: Point;
                 bestDist: var float): int =
  result = -1
  bestDist = 0.0
  var i = 0
  while i < targets.len:
    let d = dist2(targets[i].pos, p)
    if result < 0 or d < bestDist:
      result = i
      bestDist = d
    inc i

proc closestIndex*[S](targets: seq[DragTarget[S]]; p: Point): int =
  var d = 0.0
  result = nearest(targets, p, d)

proc closest*[S](targets: seq[DragTarget[S]]): DragBehavior[S] =
  result = DragBehavior[S](targets: targets, farRadius: 0.0)

proc between*[S](targets: seq[DragTarget[S]]): DragBehavior[S] =
  ## Composable `between`: this slice picks the closest target; visual
  ## interpolation between previews is a later layer.
  result = DragBehavior[S](targets: targets, farRadius: 0.0)

proc whenFar*[S](b: DragBehavior[S]; fallback: S;
                 radius: float = 120.0): DragBehavior[S] =
  result = b
  result.farTargets = @[DragTarget[S](
    state: fallback,
    pos: Point(x: 0.0, y: 0.0))]
  result.farRadius = radius * radius

proc withFloating*[S](b: DragBehavior[S]): DragBehavior[S] =
  result = b
  result.floating = true

proc applyPointer[S](d: DragController[S]; p: Point; initial: bool) =
  var bestDist = 0.0
  let idx = nearest(d.targets, p, bestDist)
  var isFar = false
  if idx >= 0 and d.farTargets.len > 0 and d.farRadius > 0.0 and
     bestDist > d.farRadius:
    isFar = true
  if initial:
    batch(proc () {.closure.} =
      d.pointer.set(p)
      if isFar:
        d.target.set(-1)
        d.far.set(true)
      else:
        d.target.set(idx)
        d.far.set(false)
      d.active.set(true))
  else:
    batch(proc () {.closure.} =
      d.pointer.set(p)
      if isFar:
        d.target.set(-1)
        d.far.set(true)
      else:
        d.target.set(idx)
        d.far.set(false))

proc start*[S](d: DragController[S]; b: DragBehavior[S]; p: Point) =
  d.targets = b.targets
  d.farTargets = b.farTargets
  d.farRadius = b.farRadius
  d.floating = b.floating
  d.applyPointer(p, true)

proc start*[S](d: DragController[S]; targets: seq[DragTarget[S]];
               p: Point) =
  d.targets = targets
  d.farTargets = @[]
  d.farRadius = 0.0
  d.floating = false
  d.applyPointer(p, true)

proc move*[S](d: DragController[S]; p: Point): int =
  if not d.active.get():
    return -1
  d.applyPointer(p, false)
  result = d.target.get()

proc finish*[S](d: DragController[S]): int =
  if not d.active.get():
    return -1
  result = d.target.get()
  batch(proc () {.closure.} =
    d.active.set(false))

proc cancel*[S](d: DragController[S]) =
  batch(proc () {.closure.} =
    d.active.set(false)
    d.target.set(-1)
    d.far.set(false))

proc hasDrop*[S](d: DragController[S]): bool =
  result = d.target.get() >= 0 or d.far.get()

proc chosen*[S](d: DragController[S]): DragTarget[S] =
  let i = d.target.get()
  if i >= 0 and i < d.targets.len:
    result = d.targets[i]
  elif d.far.get() and d.farTargets.len > 0:
    result = d.farTargets[0]
  else:
    result = DragTarget[S]()
