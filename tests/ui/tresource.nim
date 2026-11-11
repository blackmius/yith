import std/syncio
import yith/ui
import yith/dom/api

proc UserCard(data: State[string]): E {.ui.} =
  c.Span.user:
    data

proc User(user: Resource[string]): E {.ui.} =
  case user:
  of Loading:
    c.Span.loading:
      "loading"
  of Ready(data):
    UserCard(data)
  of Error(error):
    c.Span.error:
      "error"

let root = createElement("div")
let sc = beginRoot(root)
let source = newState("Ann")
let user = resource(proc (): string = source.get())
let view = User(user)
echo toHtml(root)
user.mutate("Bob")
echo toHtml(root)
source.set("Cara")
user.refetch()
echo toHtml(root)
endRoot()
dispose(sc)
