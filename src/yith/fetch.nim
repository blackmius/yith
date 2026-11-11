## Promise/Fetch bridge.
##
## `awaitText` parks the coroutine, hands the continuation to a JS promise
## callback, and resumes under the caller's UI scope so a `.get()` after the
## await subscribes the right scope.

{.feature: "assumeSync".}
{.feature: "lenientnils".}

import std/syncio
import ./core
import ./async

when defined(wasm32) and defined(standalone):
  type JsPromise* = ref object

  proc jsFetch(url: string): JsPromise {.importjs: "fetch(#)".}
  proc jsThenText(p: JsPromise; cb: proc (s: string; id: int) {.nimcall.};
                  id: int) {.importjs: "#.then(r => r.text()).then(t => #(t, #))".}
  proc jsCatch(p: JsPromise; cb: proc (id: int) {.nimcall.};
               id: int) {.importjs: "#.catch(e => #(#))".}

  type Waiter = ref object
    cont: Continuation
    scope: Scope
    text: string
    done: bool

  var waiters: seq[Waiter]

  proc resumeWaiter(id: int) =
    let w = waiters[id]
    if w.scope == nil or w.scope.dead:
      w.done = true
      return
    var c = w.cont
    withScope(w.scope, proc () {.closure.} =
      while not stopping(c):
        c = advance(c))
    w.done = true

  proc onText(s: string; id: int) {.nimcall.} =
    if id >= 0 and id < waiters.len:
      waiters[id].text = s
      resumeWaiter(id)

  proc onError(id: int) {.nimcall.} =
    if id >= 0 and id < waiters.len:
      waiters[id].text = ""
      resumeWaiter(id)

  proc register(c: Continuation; sc: Scope): int =
    result = waiters.len
    waiters.add Waiter(cont: c, scope: sc, text: "", done: false)

  proc awaitText*(url: string): string {.passive.} =
    ## `fetch(url).then(r => r.text())`, awaited by the coroutine.
    let p = jsFetch(url)
    let c = delay()
    let sc = currentScope()
    let id = register(c, sc)
    jsThenText(p, onText, id)
    jsCatch(p, onError, id)
    suspend()
    result = waiters[id].text
else:
  proc awaitText*(url: string): string =
    ## Non-JS builds have no fetch; the async tests use the passive runner
    ## directly.
    result = ""
