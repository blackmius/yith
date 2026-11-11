## Motion core: first declarative-animation slice.
##
## This is a small, DOM-independent interpolation layer plus a binding to an
## `E` style. Variants/AnimatePresence/layout projection are later layers.

{.feature: "lenientnils".}

import ./core
import ./dsl

type
  Easing* = enum
    easeLinear, easeOut, easeInOut

  TransitionKind* = enum
    tkTween, tkSpring

  Transition* = object
    kind*: TransitionKind
    duration*: float
    easing*: Easing
    stiffness*, damping*: float

  MotionProps* = object
    x*, y*, scale*, opacity*: float

  AnimValue = object
    startVal*, endVal*, cur*, vel*: float
    done*: bool

  Motion* = ref object
    styleState*: State[string]
    current*: MotionProps
    target*: MotionProps
    animX, animY, animScale, animOpacity: AnimValue
    transition*: Transition
    active*: bool

proc tween*(duration: float = 0.2; easing: Easing = easeOut): Transition =
  Transition(kind: tkTween, duration: duration, easing: easing)

proc spring*(stiffness: float = 100.0;
             damping: float = 15.0): Transition =
  Transition(kind: tkSpring, stiffness: stiffness, damping: damping,
             duration: 0.0)

proc motionValues*(x: float = 0.0; y: float = 0.0; scale: float = 1.0;
                  opacity: float = 1.0): MotionProps =
  MotionProps(x: x, y: y, scale: scale, opacity: opacity)

proc easeValue(t: float; kind: Easing): float =
  let x = if t < 0.0: 0.0 elif t > 1.0: 1.0 else: t
  case kind
  of easeLinear:
    result = x
  of easeOut:
    let u = 1.0 - x
    result = 1.0 - u * u * u
  of easeInOut:
    if x < 0.5:
      result = 4.0 * x * x * x
    else:
      let u = -2.0 * x + 2.0
      result = 1.0 - u * u * u / 2.0

proc initAnim(fromValue, toValue: float): AnimValue =
  AnimValue(startVal: fromValue, endVal: toValue, cur: fromValue, vel: 0.0,
            done: abs(toValue - fromValue) < 0.00001)

proc tickTween(a: var AnimValue; transition: Transition; dt: float): bool =
  if a.done:
    return false
  if transition.duration <= 0.0:
    a.cur = a.endVal
    a.done = true
    return true
  a.vel += dt
  let t = a.vel / transition.duration
  let e = easeValue(t, transition.easing)
  a.cur = a.startVal + (a.endVal - a.startVal) * e
  if t >= 1.0:
    a.cur = a.endVal
    a.done = true
  result = true

proc tickSpring(a: var AnimValue; transition: Transition; dt: float): bool =
  if a.done:
    return false
  let force = -transition.stiffness * (a.cur - a.endVal) -
              transition.damping * a.vel
  a.vel += force * dt
  a.cur += a.vel * dt
  if abs(a.cur - a.endVal) < 0.001 and abs(a.vel) < 0.001:
    a.cur = a.endVal
    a.vel = 0.0
    a.done = true
  result = true

proc tickValue(a: var AnimValue; transition: Transition; dt: float): bool =
  case transition.kind
  of tkTween:
    result = tickTween(a, transition, dt)
  of tkSpring:
    result = tickSpring(a, transition, dt)

proc apply*(m: Motion) =
  let s = "transform: translate(" & $m.current.x & "px, " & $m.current.y &
          "px) scale(" & $m.current.scale & "); opacity: " &
          $m.current.opacity
  m.styleState.set(s)

proc bindMotion*(e: E; initial: MotionProps): Motion =
  result = Motion(styleState: state(""), current: initial, target: initial,
                  transition: tween())
  addStyle(e, result.styleState)
  result.apply()

proc animateTo*(m: Motion; target: MotionProps;
                transition: Transition = tween()) =
  m.target = target
  m.transition = transition
  m.animX = initAnim(m.current.x, target.x)
  m.animY = initAnim(m.current.y, target.y)
  m.animScale = initAnim(m.current.scale, target.scale)
  m.animOpacity = initAnim(m.current.opacity, target.opacity)
  m.active = not (m.animX.done and m.animY.done and m.animScale.done and m.animOpacity.done)

proc tick*(m: Motion; dt: float): bool =
  if not m.active:
    return false
  var changed = false
  if tickValue(m.animX, m.transition, dt): changed = true
  if tickValue(m.animY, m.transition, dt): changed = true
  if tickValue(m.animScale, m.transition, dt): changed = true
  if tickValue(m.animOpacity, m.transition, dt): changed = true
  m.current = MotionProps(x: m.animX.cur, y: m.animY.cur, scale: m.animScale.cur,
                          opacity: m.animOpacity.cur)
  if changed:
    m.apply()
  m.active = not (m.animX.done and m.animY.done and m.animScale.done and m.animOpacity.done)
  result = changed

proc stagger*(index: int; each: float): float =
  result = float(index) * each
