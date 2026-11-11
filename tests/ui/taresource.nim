## Passive `resource`: the fetcher runs in a passive effect, source changes
## restart it and `refetch`/`mutate` keep the Ready branch stable.
{.feature: "assumeSync".}

import std/syncio
import yith/ui
import yith/uipragma
import yith/dom/api

proc Card(data: State[string]): E {.ui.} =
  c.Span.data:
    data

proc View(user: Resource[string]): E {.ui.} =
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
let source = state("Ann")
let user = resource(proc (): string {.passive.} = source.get())
let view = View(user)
echo toHtml(root)
source.set("Bob")
echo toHtml(root)
user.mutate("Cara")
echo toHtml(root)
user.refetch()
echo toHtml(root)
endRoot()
dispose(sc)
