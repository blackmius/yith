## Passive-proc integration.
##
## We deliberately never call a passive proc from a regular proc: `complete`
## busy-waits on a park, which cannot work on a browser's single thread. A root
## runner takes `delay(call)`, advances it until it parks, and lets an external
## event (a promise callback) resume it later.

{.feature: "assumeSync".}
{.feature: "lenientnils".}

import ./core

type
  PassiveCb* = proc () {.passive, closure.}

proc rootDone(coro: ptr CoroutineBase): Continuation {.nimcall.} =
  result = Continuation(fn: nil, env: nil)

var rootCont = Continuation(fn: rootDone, env: nil)

proc invoke(cb: PassiveCb) {.passive.} =
  cb()

proc runPassive*(cb: PassiveCb) =
  var c = delay(invoke(cb))
  if c.env != nil:
    c.env.caller = rootCont
  while not stopping(c):
    c = advance(c)

proc effectPassive*(cb: PassiveCb): Scope {.discardable.} =
  ## A re-runnable passive effect. Re-running the scope restarts the coroutine;
  ## disposal drops it (an in-flight promise resumes into a dead scope and is
  ## ignored by the resume helper).
  result = newScope(proc () {.closure.} =
    runPassive(cb))
  runScope(result)

template effect*(body: untyped) =
  ## `effect:` runs a passive block and re-runs it when a state it read changes.
  discard effectPassive(proc () {.passive, closure.} = body)
