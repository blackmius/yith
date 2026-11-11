## `Resource[T, A]`-style handle: the fetcher receives an argument, and
## `refetch(r, arg)` switches it. Both sync and passive slices are covered.
{.feature: "assumeSync".}

import std/syncio
import yith/ui
import yith/dom/api

proc Card(data: State[string]): E {.ui.} =
  c.Span.data:
    data

proc View(user: ArgResource[string, int]): E {.ui.} =
  case user:
  of Loading:
    c.Span.loading:
      "loading"
  of Ready(data):
    Card(data)
  of Error(error):
    c.Span.error:
      "error"

let root = createElement("div")
let sc = beginRoot(root)

let syncUser = resource(proc (id: int): string = "s" & $id, 1)
echo syncUser.data.get()
refetch(syncUser, 7)
echo syncUser.data.get()

let passiveUser = resource(
  proc (id: int): string {.passive.} = "p" & $id, 2)
let view = View(passiveUser)
echo toHtml(root)
refetch(passiveUser, 5)
echo toHtml(root)
passiveUser.mutate("m")
echo toHtml(root)

endRoot()
dispose(sc)
