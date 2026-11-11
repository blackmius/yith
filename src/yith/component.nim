## Component handle and fragment primitives.

{.feature: "lenientnils".}
{.feature: "assumeSync".}

import ./core
import ./internal
import ./dom/api

type
  ClassPartKind* = enum
    cpStatic, cpState, cpCond

  ClassPart* = object
    case kind*: ClassPartKind
    of cpStatic:
      text*: string
    of cpState:
      state*: State[string]
    of cpCond:
      name*: string
      cond*: State[bool]

  StylePartKind* = enum
    spStatic, spState, spProp

  StylePart* = object
    case kind*: StylePartKind
    of spStatic:
      text*: string
    of spState:
      state*: State[string]
    of spProp:
      prop*: string
      value*: State[string]

  E* = ref object
    ## A rendered fragment: its owner scope plus the two comment anchors that
    ## delimit the nodes it created. A single-node component sets `startNode`
    ## to that node and leaves `endNode` nil.
    scope*: Scope
    startNode*: Node
    endNode*: Node
    classParts*: seq[ClassPart]
    styleParts*: seq[StylePart]

proc finish*(e: E): E {.yithInternal, discardable.} =
  ## The tail of every generated `c.Tag` block: makes the last expression a
  ## discardable call, so an element is valid as a statement and as an
  ## expression without any pragma on user code.
  result = e

proc uiFragment*(body: proc () {.closure.}): E {.yithInternal, discardable.} =
  ## Run `body` between two anchors in the current parent and return the
  ## fragment. This is what the type plugin wraps a `proc ...: E` body in.
  let outer = current
  let parent = outer.domParent
  let before = outer.domBefore

  let startNode = createComment("yith")
  appendNode(startNode)
  let endNode = createComment("/yith")
  appendNode(endNode)

  let sc = newScope(nil)
  sc.domParent = parent
  sc.domBefore = endNode
  sc.buildOnce = true
  sc.run = body
  runScope(sc)

  result = E(scope: sc, startNode: startNode, endNode: endNode)

template fragment*(body: untyped): E =
  uiFragment(proc () {.closure.} = body)

proc nextSibling*(n: Node): Node
proc parentNode*(n: Node): Node

proc moveRange*(e: E; parent: Node) =
  ## Move every node between the anchors (inclusive) to `parent`.
  if e.startNode == nil: return
  var n = e.startNode
  while n != nil:
    let nxt = nextSibling(n)
    appendChild(parent, n)
    if n == e.endNode: break
    n = nxt

proc moveRangeBefore*(e: E; parent, before: Node) =
  ## Move every node of `e` before `before`, preserving order.
  if e.startNode == nil: return
  if e.endNode == nil:
    insertBefore(parent, e.startNode, before)
    return
  var n = e.startNode
  while n != nil:
    let nxt = nextSibling(n)
    insertBefore(parent, n, before)
    if n == e.endNode: break
    n = nxt

proc mount*(e: E) =
  ## Put a detached fragment back into the current scope's parent.
  if current != nil and current.domParent != nil:
    moveRange(e, current.domParent)

proc replace*(oldE: E; newE: E) =
  ## Mount `newE` where `oldE` was, then dispose the old one.
  if oldE.startNode != nil and parentNode(oldE.startNode) != nil:
    let parent = parentNode(oldE.startNode)
    moveRange(newE, parent)
    dispose(oldE.scope)
