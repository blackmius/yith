## `Resource[T]` — a sum of loading/ready/error.
##
## Two slices live here:
## * synchronous `resource(fetcher)` runs the fetcher immediately;
## * passive `resource(fetcher {.passive.})` starts an effect that parks on
##   `await` and is restarted whenever a signal it read changes or
##   `refetch` is called. A generation counter drops late responses.
##
## `mutate` updates the Ready data in place; the reactive `case user:` lives
## by the `{.ui.}` syntax pass (it rewrites to `uiCaseBlock`).
##
## `ResourceValue` carries only the kind. The payloads (`data`, `error`) are
## separate states on the handle: on the JS backend a generic `State[T]`
## inside a variant object loses its value when a passive effect re-runs
## (`docs/nimony-issues.md` #24). Keeping them outside the variant preserves
## the public transition semantics and keeps the Ready branch stable.

{.feature: "lenientnils".}

import ./core
import ./async

type
  ResourceState* = enum
    resLoading, resReady, resError

  ErrorInfo* = object
    message*: string

  ResourceValue*[T] = object
    kind*: ResourceState

  Resource*[T] = ref object
    value*: State[ResourceValue[T]]
    ## Payload states; created on the first transition to the matching kind.
    data*: State[T]
    error*: State[ErrorInfo]
    fetcher*: proc (): T {.closure.}
    ## Passive resources use this trigger to restart the effect on `refetch`.
    refresh*: State[int]
    scope*: Scope
    generation*: int

proc setReady[T](r: Resource[T]; v: T) =
  if r.data == nil:
    r.data = newState(v)
  else:
    r.data.set(v)
  r.value.set(ResourceValue[T](kind: resReady))

proc setError[T](r: Resource[T]; msg: string) =
  if r.error == nil:
    r.error = newState(ErrorInfo(message: msg))
  else:
    r.error.set(ErrorInfo(message: msg))
  r.value.set(ResourceValue[T](kind: resError))

proc load[T](r: Resource[T]) =
  try:
    let v = r.fetcher()
    if r.data != nil and r.value.get().kind == resReady:
      r.data.set(v)
    else:
      setReady(r, v)
  except:
    if r.error != nil and r.value.get().kind == resError:
      r.error.set(ErrorInfo(message: "fetch failed"))
    else:
      setError(r, "fetch failed")

proc resource*[T](fetcher: proc (): T {.closure.}): Resource[T] =
  result = Resource[T](
    value: newState(ResourceValue[T](kind: resLoading)),
    fetcher: fetcher)
  load(result)

proc resource*[T](fetcher: proc (): T {.passive.}): Resource[T] =
  ## Async resource. The fetcher runs in a passive effect in the current
  ## scope: signals read before the first `await` subscribe it, and the same
  ## effect restarts (with a new generation) on source changes/`refetch`.
  result = Resource[T](
    value: newState(ResourceValue[T](kind: resLoading)),
    refresh: newState(0))
  let r = result
  r.scope = effectPassive(proc () {.passive, closure.} =
    discard r.refresh.get()
    inc r.generation
    let myGeneration = r.generation
    r.value.set(ResourceValue[T](kind: resLoading))
    try:
      let v = fetcher()
      if r.generation == myGeneration:
        setReady(r, v)
    except:
      if r.generation == myGeneration:
        setError(r, "fetch failed"))

proc refetch*[T](r: Resource[T]) =
  if r.refresh != nil:
    r.refresh.set(stateValue(r.refresh) + 1)
  else:
    load(r)

proc mutate*[T](r: Resource[T]; v: T) =
  setReady(r, v)

proc mutate*[T](r: Resource[T]; f: proc (v: var T) {.closure.}) =
  if r.value.get().kind == resReady and r.data != nil:
    r.data.update(f)

proc isLoading*[T](r: Resource[T]): bool =
  r.value.get().kind == resLoading

proc isError*[T](r: Resource[T]): bool =
  r.value.get().kind == resError

# ---------------------------------------------------------------------------
# Resource with an argument (`refetch(arg)`).

type
  ArgResource*[T, A] = ref object
    value*: State[ResourceValue[T]]
    ## Payload states; created on the first transition to the matching kind.
    data*: State[T]
    error*: State[ErrorInfo]
    arg*: State[A]
    fetcher*: proc (a: A): T {.closure.}
    refresh*: State[int]
    scope*: Scope
    generation*: int

proc setReady[T, A](r: ArgResource[T, A]; v: T) =
  if r.data == nil:
    r.data = newState(v)
  else:
    r.data.set(v)
  r.value.set(ResourceValue[T](kind: resReady))

proc setError[T, A](r: ArgResource[T, A]; msg: string) =
  if r.error == nil:
    r.error = newState(ErrorInfo(message: msg))
  else:
    r.error.set(ErrorInfo(message: msg))
  r.value.set(ResourceValue[T](kind: resError))

proc resource*[T, A](fetcher: proc (a: A): T {.closure.};
                     arg: A): ArgResource[T, A] =
  result = ArgResource[T, A](
    value: newState(ResourceValue[T](kind: resLoading)),
    arg: newState(arg),
    fetcher: fetcher)
  try:
    setReady(result, result.fetcher(arg))
  except:
    setError(result, "fetch failed")

proc resource*[T, A](fetcher: proc (a: A): T {.passive.};
                     arg: A): ArgResource[T, A] =
  result = ArgResource[T, A](
    value: newState(ResourceValue[T](kind: resLoading)),
    arg: newState(arg),
    refresh: newState(0))
  let r = result
  r.scope = effectPassive(proc () {.passive, closure.} =
    discard r.refresh.get()
    let a = r.arg.get()
    inc r.generation
    let myGeneration = r.generation
    r.value.set(ResourceValue[T](kind: resLoading))
    try:
      let v = fetcher(a)
      if r.generation == myGeneration:
        setReady(r, v)
    except:
      if r.generation == myGeneration:
        setError(r, "fetch failed"))

proc loadArg[T, A](r: ArgResource[T, A]) =
  try:
    setReady(r, r.fetcher(stateValue(r.arg)))
  except:
    setError(r, "fetch failed")

proc refetch*[T, A](r: ArgResource[T, A]) =
  if r.refresh != nil:
    r.refresh.set(stateValue(r.refresh) + 1)
  else:
    loadArg(r)

proc refetch*[T, A](r: ArgResource[T, A]; arg: A) =
  r.arg.set(arg)
  if r.refresh != nil:
    r.refresh.set(stateValue(r.refresh) + 1)
  else:
    loadArg(r)

proc mutate*[T, A](r: ArgResource[T, A]; v: T) =
  setReady(r, v)

proc mutate*[T, A](r: ArgResource[T, A];
                   f: proc (v: var T) {.closure.}) =
  if r.value.get().kind == resReady and r.data != nil:
    r.data.update(f)

proc isLoading*[T, A](r: ArgResource[T, A]): bool =
  r.value.get().kind == resLoading

proc isError*[T, A](r: ArgResource[T, A]): bool =
  r.value.get().kind == resError
