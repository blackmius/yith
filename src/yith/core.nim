## yith core: reactive state and scopes.
##
## A `Scope` is the unit of ownership and re-execution. It owns child scopes,
## subscriptions, DOM nodes it created, and cleanup closures. `get()` records a
## dependency on the currently running scope; `set()` marks the dependent
## scopes dirty and schedules a flush. Disposing a scope walks its children, so
## an entire subtree disappears in one chain.

{.feature: "lenientnils".}
{.feature: "assumeSync".}

import ./dom/api

type
  CtxLink* = ref object
    key*: int
    prev*: CtxLink
    val*: ref RootObj

  Signal* = ref object
    head*: Sub
    when defined(yithDebugSignals):
      id*: int

  Sub* = ref object
    sig*: Signal
    prev*, next*: Sub
    scope*: Scope
    dead*: bool
    when defined(yithDebugSignals):
      id*: int

  Scope* = ref object
    parent*: Scope
    children*: seq[Scope]
    subs*: seq[Sub]
    nodes*: seq[Node]
    cleanups*: seq[proc () {.closure.}]
    run*: proc () {.closure.}
    domParent*: Node
    domBefore*: Node
    ctx*: CtxLink
    dead*: bool
    scheduled*: bool
    keepChildren*: bool
    buildOnce*: bool
    when defined(yithDebugSignals):
      id*: int

  State*[T] = ref object
    sig*: Signal
    value*: T

var current*: Scope = nil

when defined(yithDebugSignals):
  var debugLogEnabled* = true
  var debugFocusSigs*: seq[int] = @[]
  var nextScopeId = 0
  var nextSubId = 0
  var nextSignalId = 0
  var debugRing*: seq[string] = @[]

  proc dlog(s: string) =
    if debugLogEnabled:
      debugLog("[yith] " & s)
      debugRing.add s
      if debugRing.len > 800:
        debugRing.delete 0

  proc clearDebugLog*() =
    debugRing.setLen 0

  proc dumpDebugLog*() =
    ## Print the ring buffer. Call `NIF.dumpLog()` from the browser console
    ## after a crash and send the output.
    debugLog("--- yith debug log (" & $debugRing.len & " lines) ---")
    var i = 0
    while i < debugRing.len:
      debugLog(debugRing[i])
      inc i

  proc sigFocused(id: int): bool =
    result = false
    if debugFocusSigs.len == 0:
      return true
    var i = 0
    while i < debugFocusSigs.len:
      if debugFocusSigs[i] == id:
        return true
      inc i
else:
  var debugLogEnabled* = false
  var debugFocusSigs*: seq[int] = @[]

  template dlog(s: string) =
    discard

  proc clearDebugLog*() =
    discard

  proc dumpDebugLog*() =
    discard

  proc signalId*[T](s: State[T]): int =
    result = 0

var currentCtx*: CtxLink = nil
var tracking = false
var pending: seq[Scope]
var flushQueued = false
var flushing = false
var deferFlush = 0

proc unlink(sub: Sub) =
  if sub.dead: return
  when defined(yithDebugSignals):
    if sub.sig != nil and sigFocused(sub.sig.id):
      dlog("unlink sub " & $sub.id & " sig " & $sub.sig.id & " scope " &
           $(if sub.scope != nil: sub.scope.id else: -1))
  sub.dead = true
  if sub.prev != nil:
    sub.prev.next = sub.next
  else:
    sub.sig.head = sub.next
  if sub.next != nil:
    sub.next.prev = sub.prev
  # Sever every strong edge the dead Sub still holds, so destroying it cannot
  # decrement neighbours the signal list no longer owns.
  sub.prev = nil
  sub.next = nil
  sub.scope = nil

proc link(sig: Signal; sub: Sub) =
  when defined(yithDebugSignals):
    if sigFocused(sig.id):
      dlog("link sub " & $sub.id & " sig " & $sig.id & " scope " &
           $(if sub.scope != nil: sub.scope.id else: -1))
  sub.next = sig.head
  if sig.head != nil:
    sig.head.prev = sub
  sig.head = sub

proc subscriberCount*[T](s: State[T]): int =
  result = 0
  var it = s.sig.head
  while it != nil:
    if not it.dead: inc result
    it = it.next

when defined(yithDebugSignals):
  proc signalId*[T](s: State[T]): int =
    result = s.sig.id

template state*() {.pragma.}
  ## Marks a declaration (or parameter) as reactive. A pre-sem pass lowers the
  ## UI syntax, then a module plugin rewrites `{.state.}` to `State[T]` and
  ## every read/write of the name to `get`/`set`.

proc state*[T](v: T): T =
  ## Identity placeholder used while `{.state.}` code is still seen as plain
  ## values by the first semantic pass. The state plugin replaces it with
  ## `newState` when it rewrites the declaration.
  result = v

proc newState*[T](v: T): State[T] =
  ## The real reactive constructor. Runtime modules use this explicitly; the
  ## state plugin emits it for `{.state.}` declarations.
  when defined(yithDebugSignals):
    result = State[T](sig: Signal(id: nextSignalId), value: v)
    inc nextSignalId
    if sigFocused(result.sig.id):
      dlog("state sig " & $result.sig.id)
  else:
    result = State[T](sig: Signal(), value: v)

proc get*[T](s: State[T]): T =
  if tracking and current != nil and not current.dead:
    var sub: Sub
    when defined(yithDebugSignals):
      sub = Sub(sig: s.sig, scope: current, id: nextSubId)
      inc nextSubId
    else:
      sub = Sub(sig: s.sig, scope: current)
    current.subs.add sub
    link(s.sig, sub)
  result = s.value

proc stateValue*[T](s: State[T]): T =
  ## Read without subscribing.
  result = s.value

proc newScope*(run: proc () {.closure.}): Scope =
  when defined(yithDebugSignals):
    result = Scope(run: run, id: nextScopeId)
    inc nextScopeId
    if debugFocusSigs.len == 0:
      dlog("scope new " & $result.id & " parent " &
           $(if current != nil: current.id else: -1))
  else:
    result = Scope(run: run)
  if current != nil:
    result.parent = current
    result.domParent = current.domParent
    result.domBefore = current.domBefore
    result.ctx = currentCtx
    current.children.add result

proc runScope*(sc: Scope) =
  let prev = current
  let prevTracking = tracking
  let prevCtx = currentCtx
  current = sc
  currentCtx = sc.ctx
  tracking = not sc.buildOnce
  if sc.run != nil:
    sc.run()
  tracking = prevTracking
  currentCtx = prevCtx
  current = prev

proc effect*(run: proc () {.closure.}): Scope =
  result = newScope(run)
  # `effect` is usually discarded. Keep a counted owner tied to the parent so
  # discarding the returned Scope can never free a scope that is still stored
  # in `parent.children`. The cleanup is cleared with the parent.
  if current != nil:
    let keepAlive = result
    current.cleanups.add proc () {.closure.} =
      discard keepAlive
  runScope(result)

type
  Computed*[T] = ref object
    ## A cached derived value. The effect owns the dependency edges; `get`
    ## subscribes the caller to the underlying state.
    state*: State[T]
    scope*: Scope

proc computed*[T](f: proc (): T {.closure.}): Computed[T] =
  result = Computed[T](state: newState(f()))
  result.scope = effect(proc () {.closure.} =
    result.state.set(f()))

proc get*[T](c: Computed[T]): T =
  c.state.get()

proc peek*[T](c: Computed[T]): T =
  stateValue(c.state)

template withoutTracking*(body: untyped): untyped =
  block:
    let previousTracking = tracking
    tracking = false
    let produced = body
    tracking = previousTracking
    produced

template withoutTrackingStmt*(body: untyped) =
  ## Statement form of `withoutTracking` for void calls.
  block:
    let previousTracking = tracking
    tracking = false
    body
    tracking = previousTracking

template computedExpr*(expr: untyped): untyped =
  ## Wrap a read expression into a cached state. The initial value must not
  ## subscribe the enclosing (build-once) component; only the effect owns the
  ## dependency edges.
  block:
    let computedState = withoutTracking:
      newState(expr)
    discard effect(proc () {.closure.} =
      computedState.set(expr))
    computedState

proc watchValue*[T](f: proc (): T {.closure.}): State[T] =
  ## Named-proc form used by attribute/text lowering. Keeping the derived
  ## State in this frame (rather than a caller-local `computedExpr`) prevents
  ## closure conversion from hoisting it into the enclosing component env.
  let initial = withoutTracking:
    f()
  result = newState(initial)
  discard effect(proc () {.closure.} =
    result.set(f()))

proc appendNode*(n: Node) =
  ## Register a freshly created node with the current scope and attach it to
  ## the current DOM parent. The scope owns the node: its removal on re-run or
  ## disposal is what makes a subtree vanish without a diff.
  if current != nil:
    current.nodes.add n
    if current.domBefore != nil:
      insertBefore(current.domParent, n, current.domBefore)
    elif current.domParent != nil:
      appendChild(current.domParent, n)

proc onCleanup*(f: proc () {.closure.}) =
  if current != nil:
    current.cleanups.add f

proc resetScope(sc: Scope) =
  ## Release everything a scope owns but keep `run` so the scope can be run
  ## again. Permanent teardown adds `run = nil` in `killScope`.
  for i in 0 ..< sc.cleanups.len:
    sc.cleanups[i]()
  sc.cleanups.setLen 0
  for i in 0 ..< sc.children.len:
    let child = sc.children[i]
    killScope(child)
    # Break the parent/child ref cycle. A dead child may outlive the parent in
    # `pending`; leaving `parent` set makes its later destruction decrement a
    # freed parent (and can recurse through child scopes).
    child.parent = nil
  sc.children.setLen 0
  for i in 0 ..< sc.subs.len:
    unlink(sc.subs[i])
  sc.subs.setLen 0
  for i in 0 ..< sc.nodes.len:
    remove(sc.nodes[i])
  sc.nodes.setLen 0

proc killScope(sc: Scope) =
  if sc.dead: return
  when defined(yithDebugSignals):
    if debugFocusSigs.len == 0:
      dlog("kill scope " & $sc.id & " children " & $sc.children.len &
           " subs " & $sc.subs.len)
  sc.dead = true
  resetScope(sc)
  # The run closure usually captures the element/E it rendered, and E.scope
  # points back at this scope. Dropping the closure breaks that cycle so the
  # scope is not destroyed recursively through its own rendered values.
  sc.run = nil

proc dispose*(sc: Scope) =
  if sc == nil or sc.dead: return
  killScope(sc)
  if sc.parent != nil:
    var i = 0
    while i < sc.parent.children.len:
      if sc.parent.children[i] == sc:
        sc.parent.children.delete i
        break
      inc i
    sc.parent = nil

proc drain() =
  var i = 0
  while i < pending.len:
    let sc = pending[i]
    inc i
    if not sc.dead:
      sc.scheduled = false
      if sc.keepChildren:
        for j in 0 ..< sc.subs.len:
          unlink(sc.subs[j])
        sc.subs.setLen 0
        for j in 0 ..< sc.cleanups.len:
          sc.cleanups[j]()
        sc.cleanups.setLen 0
      else:
        resetScope(sc)
        sc.dead = false
      runScope(sc)
  pending.setLen 0

proc flush*() =
  if flushing: return
  flushing = true
  # A `set` performed while an effect runs queues another flush. In a real
  # event loop the scheduled microtask would pick it up, but the test backend
  # runs microtasks synchronously and would lose it while `flushing` is true.
  # Drain until no work remains.
  while flushQueued or pending.len > 0:
    flushQueued = false
    drain()
  flushing = false

proc scheduleFlush() =
  if deferFlush > 0:
    flushQueued = true
    return
  if not flushQueued:
    flushQueued = true
    scheduleMicrotask(flush)

proc set*[T](s: State[T]; v: T) =
  when defined(yithDebugSignals):
    if sigFocused(s.sig.id):
      dlog("set sig " & $s.sig.id)
  s.value = v
  var it = s.sig.head
  while it != nil:
    let nxt = it.next
    if not it.dead and not it.scope.dead and not it.scope.scheduled:
      it.scope.scheduled = true
      pending.add it.scope
    it = nxt
  scheduleFlush()

proc update*[T](s: State[T]; f: proc (v: var T) {.closure.}) =
  var v = s.value
  f(v)
  s.set v

# Assignment operators on signals are type-driven: `s += v` wraps the
# mutation in `update`. Nimony's generic arithmetic is not available yet
# (issue #12), so the concrete instantiations are listed explicitly.
proc `+=`*(s: State[int]; v: int) =
  s.update(proc (x: var int) {.closure.} = x += v)

proc `-=`*(s: State[int]; v: int) =
  s.update(proc (x: var int) {.closure.} = x -= v)

proc `*=`*(s: State[int]; v: int) =
  s.update(proc (x: var int) {.closure.} = x *= v)

proc `/=`*(s: State[int]; v: int) =
  s.update(proc (x: var int) {.closure.} = x = x div v)

proc `+=`*(s: State[float]; v: float) =
  s.update(proc (x: var float) {.closure.} = x += v)

proc `-=`*(s: State[float]; v: float) =
  s.update(proc (x: var float) {.closure.} = x -= v)

proc `*=`*(s: State[float]; v: float) =
  s.update(proc (x: var float) {.closure.} = x *= v)

proc `/=`*(s: State[float]; v: float) =
  s.update(proc (x: var float) {.closure.} = x /= v)

proc `+=`*(s: State[string]; v: string) =
  s.update(proc (x: var string) {.closure.} = x = x & v)

proc `&=`*(s: State[string]; v: string) =
  s.update(proc (x: var string) {.closure.} = x = x & v)

proc batch*(body: proc () {.closure.}) =
  inc deferFlush
  body()
  dec deferFlush
  if deferFlush == 0 and flushQueued:
    scheduleMicrotask(flush)

var rootStack: seq[Scope]

proc beginRoot*(parent: Node): Scope =
  ## Start a render root attached to `parent`. Tests and the app bootstrap use
  ## this; disposing the returned scope removes everything rendered under it.
  rootStack.add current
  result = newScope(nil)
  result.domParent = parent
  current = result

proc endRoot*() =
  flush()
  if rootStack.len > 0:
    current = rootStack[rootStack.high]
    rootStack.setLen rootStack.len - 1
  else:
    current = nil

proc currentScope*(): Scope =
  result = current

proc hasPending*(): bool =
  result = pending.len > 0

proc withScope*(sc: Scope; body: proc () {.closure.}) =
  ## Run `body` as if it were a step of `sc`: `get()` subscribes `sc`.
  let prevCurrent = current
  let prevTracking = tracking
  current = sc
  tracking = true
  body()
  tracking = prevTracking
  current = prevCurrent
