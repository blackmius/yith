## Hierarchical component context, in the spirit of React's `useContext`.
##
## A provider is a dynamic extent while rendering, and every scope created
## inside it remembers the chain, so a scope that re-runs later still sees the
## value its component was rendered under.

{.feature: "assumeSync".}
{.feature: "lenientnils".}

import ./core
import ./internal

type
  CtxBox[T] = ref object of RootObj
    value: T

  Context*[T] = ref object
    id: int

var nextCtxId = 0

proc context*[T](): Context[T] =
  ## Create a typed context key. A single instance per context.
  result = Context[T](id: nextCtxId)
  inc nextCtxId

proc beginProvide*[T](c: Context[T]; v: T): CtxLink {.yithInternal.} =
  let box = CtxBox[T](value: v)
  currentCtx = CtxLink(key: c.id, prev: currentCtx,
                       val: cast[ref RootObj](box))
  result = currentCtx

proc endProvide*(prev: CtxLink) {.yithInternal.} =
  currentCtx = prev

template provide*(c, v, body: untyped) =
  block:
    let previousContext = beginProvide(c, v)
    try:
      body
      discard
    finally:
      endProvide(previousContext)
    discard

proc use*[T](c: Context[T]): T =
  var it = currentCtx
  while it != nil:
    if it.key == c.id:
      return cast[CtxBox[T]](it.val).value
    it = it.prev
  panic "yith: use() called outside its provider"
