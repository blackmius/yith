## The DSL: eager node primitives, explicit scopes, and events.
##
## A primitive used as a statement is `void`; this is not a style choice.
## This Nimony build asserts in `finalir` when a `for` body discards a
## `discardable` call that returns a `ref`, so `Text(...)`/`ElE(...)` inside a
## loop must not produce a value. The `*E` variants exist for expression use
## (mount, router, `seq[E]`), outside loop bodies.
##
## Values are evaluated eagerly by the caller. A `.get()` in `Text`/attribute
## arguments runs in the current scope, subscribes it, and that scope re-runs
## to rebuild the subtree. Scopes are created explicitly by `effect`,
## `uiBlock`, `uiLoop`, `uiWhen`, and component fragments.

{.feature: "lenientnils".}
{.feature: "assumeSync".}

import ./core
import ./component
import ./dom/api
import ./internal

export core, component, internal

# ------------------------------------------------------------------ primitives

proc textNode*(s: string): Node {.yithInternal.} =
  result = createTextNode(s)
  appendNode(result)

proc Text*(value: string) =
  ## Append a text node to the current parent.
  discard textNode(value)

proc Text*(value: State[string]) =
  ## Text bound to a signal: the node is owned by the current scope and the
  ## value is refreshed by a child effect.
  let n = createTextNode("")
  appendNode(n)
  discard effect(proc () {.closure.} =
    setText(n, value.get()))

proc Text*(value: State[int]) =
  let n = createTextNode("")
  appendNode(n)
  discard effect(proc () {.closure.} =
    setText(n, $value.get()))

proc Text*(value: State[bool]) =
  let n = createTextNode("")
  appendNode(n)
  discard effect(proc () {.closure.} =
    setText(n, $value.get()))

proc Text*(value: State[float]) =
  let n = createTextNode("")
  appendNode(n)
  discard effect(proc () {.closure.} =
    setText(n, $value.get()))

proc Text*(value: int) =
  discard textNode($value)

proc Text*(value: float) =
  discard textNode($value)

proc Text*(value: bool) =
  discard textNode($value)

proc Text*(value: Computed[string]) =
  Text(value.state)

proc Text*(value: Computed[int]) =
  Text(value.state)

proc Text*(value: Computed[bool]) =
  Text(value.state)

proc Text*(value: Computed[float]) =
  Text(value.state)

proc TextE*(value: string): E {.yithInternal, discardable.} =
  result = E(scope: current, startNode: textNode(value), endNode: nil)

proc setAttrValue*(e: E; name, value: string) {.yithInternal.} =
  if value.len == 0:
    removeAttribute(e.startNode, name)
  else:
    setAttribute(e.startNode, name, value)

proc setBoolAttrValue*(e: E; name: string; value: bool) {.yithInternal.} =
  if value:
    setAttribute(e.startNode, name, "true")
  else:
    removeAttribute(e.startNode, name)

proc setAttr*(e: E; name, value: string) =
  setAttrValue(e, name, value)

proc setAttr*(e: E; name: string; value: int) =
  setAttrValue(e, name, $value)

proc setAttr*(e: E; name: string; value: bool) =
  ## Bool-valued attributes use HTML presence semantics: `true` sets the
  ## attribute, `false` removes it. There is no name whitelist.
  setBoolAttrValue(e, name, value)

proc setAttr*(e: E; name: string; value: State[string]) =
  discard effect(proc () {.closure.} =
    setAttrValue(e, name, value.get()))

proc setAttr*(e: E; name: string; value: State[int]) =
  discard effect(proc () {.closure.} =
    setAttrValue(e, name, $value.get()))

proc setAttr*(e: E; name: string; value: State[bool]) =
  discard effect(proc () {.closure.} =
    setBoolAttrValue(e, name, value.get()))

proc setAttr*(e: E; name: string; value: Computed[string]) =
  setAttr(e, name, value.state)

proc setAttr*(e: E; name: string; value: Computed[int]) =
  setAttr(e, name, value.state)

proc setAttr*(e: E; name: string; value: Computed[bool]) =
  setAttr(e, name, value.state)

proc setBoolAttr*(e: E; name: string; value: bool) =
  setBoolAttrValue(e, name, value)

proc setBoolAttr*(e: E; name: string; value: State[bool]) =
  discard effect(proc () {.closure.} =
    setBoolAttrValue(e, name, value.get()))

proc setBoolAttr*(e: E; name: string; value: Computed[bool]) =
  setBoolAttr(e, name, value.state)

template attr*(e: E; name: string; value: untyped) =
  setAttr(e, name, value)

template boolAttr*(e: E; name: string; value: untyped) =
  setBoolAttr(e, name, value)

proc setProp*(e: E; name, value: string) =
  setProp(e.startNode, name, value)

proc setProp*(e: E; name: string; value: int) =
  setProp(e.startNode, name, value)

proc setProp*(e: E; name: string; value: bool) =
  setProp(e.startNode, name, value)

proc setProp*(e: E; name: string; value: State[string]) =
  discard effect(proc () {.closure.} =
    setProp(e, name, value.get()))

proc setProp*(e: E; name: string; value: State[bool]) =
  discard effect(proc () {.closure.} =
    setProp(e, name, value.get()))

proc setProp*(e: E; name: string; value: State[int]) =
  discard effect(proc () {.closure.} =
    setProp(e, name, value.get()))

proc setProp*(e: E; name: string; value: Computed[string]) =
  setProp(e, name, value.state)

proc setProp*(e: E; name: string; value: Computed[int]) =
  setProp(e, name, value.state)

proc setProp*(e: E; name: string; value: Computed[bool]) =
  setProp(e, name, value.state)

template prop*(e: E; name: string; value: untyped) =
  setProp(e, name, value)

proc onCreated*(e: E; cb: proc (e: E) {.closure.}) =
  ## The eager runtime appends the node immediately, so "created" is now.
  cb(e)

proc onCleanup*(e: E; cb: proc () {.closure.}) =
  ## Element-scoped cleanup. In the eager runtime the element's scope is the
  ## scope that created it; disposing that scope runs the callback.
  if e.scope != nil:
    e.scope.cleanups.add cb
  else:
    onCleanup(cb)

proc refreshClass*(e: E) =
  var s = ""
  var i = 0
  while i < e.classParts.len:
    let part = e.classParts[i]
    var v = ""
    if part.kind == cpStatic:
      v = part.text
    elif part.kind == cpState:
      v = stateValue(part.state)
    else:
      if stateValue(part.cond):
        v = part.name
    if v.len > 0:
      if s.len > 0: s.add ' '
      s.add v
    inc i
  setAttrValue(e, "class", s)

proc addClass*(e: E; value: string) =
  if value.len == 0: return
  e.classParts.add ClassPart(kind: cpStatic, text: value)
  refreshClass(e)

proc addClass*(e: E; value: State[string]) =
  e.classParts.add ClassPart(kind: cpState, state: value)
  discard effect(proc () {.closure.} =
    discard value.get()
    refreshClass(e))
  refreshClass(e)

proc addClass*(e: E; value: Computed[string]) =
  addClass(e, value.state)

proc addClass*(e: E; name: string; cond: bool) =
  if cond:
    addClass(e, name)

proc addClass*(e: E; name: string; cond: State[bool]) =
  e.classParts.add ClassPart(kind: cpCond, name: name, cond: cond)
  discard effect(proc () {.closure.} =
    discard cond.get()
    refreshClass(e))
  refreshClass(e)

proc refreshStyle*(e: E) =
  var s = ""
  var i = 0
  while i < e.styleParts.len:
    let part = e.styleParts[i]
    var v = ""
    if part.kind == spStatic:
      v = part.text
    elif part.kind == spState:
      v = stateValue(part.state)
    else:
      v = part.prop & ": " & stateValue(part.value)
    if v.len > 0:
      if s.len > 0: s.add "; "
      s.add v
    inc i
  setAttrValue(e, "style", s)

proc addStyle*(e: E; value: string) =
  if value.len == 0: return
  e.styleParts.add StylePart(kind: spStatic, text: value)
  refreshStyle(e)

proc addStyle*(e: E; value: State[string]) =
  e.styleParts.add StylePart(kind: spState, state: value)
  discard effect(proc () {.closure.} =
    discard value.get()
    refreshStyle(e))
  refreshStyle(e)

proc addStyle*(e: E; prop: string; value: string) =
  if value.len > 0:
    addStyle(e, prop & ": " & value)

proc addStyle*(e: E; prop: string; value: State[string]) =
  e.styleParts.add StylePart(kind: spProp, prop: prop, value: value)
  discard effect(proc () {.closure.} =
    discard value.get()
    refreshStyle(e))
  refreshStyle(e)

proc addStyle*(e: E; value: Computed[string]) =
  addStyle(e, value.state)

proc addStyle*(e: E; prop: string; value: Computed[string]) =
  addStyle(e, prop, value.state)

template uiChildren*(body: untyped): proc () {.closure.} =
  ## Wrap a component call's colon block into the `children` slot.
  proc () {.closure.} = body

proc openNode*(tag: string): Node {.yithInternal.} =
  result = createElement(tag)
  appendNode(result)

proc elementVoid*(tag: string; body: proc () {.closure.}) {.yithInternal.} =
  ## Create an element, run the body with it as the current parent, and leave
  ## the element owned by the caller's scope. No child scope: re-running the
  ## caller re-creates the element and its children.
  let n = openNode(tag)
  let prevParent = current.domParent
  let prevBefore = current.domBefore
  current.domParent = n
  current.domBefore = nil
  body()
  current.domParent = prevParent
  current.domBefore = prevBefore

proc elementE*(tag: string; body: proc () {.closure.}): E {.yithInternal, discardable.} =
  let n = openNode(tag)
  let prevParent = current.domParent
  let prevBefore = current.domBefore
  current.domParent = n
  current.domBefore = nil
  body()
  current.domParent = prevParent
  current.domBefore = prevBefore
  result = E(scope: current, startNode: n, endNode: nil)

# ------------------------------------------------------------- explicit scopes

proc uiBlock*(body: proc () {.closure.}): E {.yithInternal, discardable.} =
  ## A re-runnable block. The closure captures the component's environment;
  ## anything it reads via `get()` subscribes this scope. An anchor comment
  ## keeps the block's position stable across re-runs.
  let anchor = createComment("yith.block")
  appendNode(anchor)
  let sc = newScope(nil)
  sc.domBefore = anchor
  sc.run = body
  runScope(sc)
  result = E(scope: sc)

proc uiBlock*(tag: string; attrs: proc (e: E) {.closure.};
              children: proc () {.closure.}): E {.yithInternal, discardable.} =
  ## The form emitted by the `{.ui.}` syntax pass for `c.Tag.class:`:
  ## create the element, run the attribute/event closure against it, then run
  ## the children closure with the element as the current parent.
  let n = openNode(tag)
  let outer = current
  let prevParent = outer.domParent
  let prevBefore = outer.domBefore
  let e = E(scope: outer, startNode: n, endNode: nil)
  outer.domParent = n
  outer.domBefore = nil
  if attrs != nil:
    attrs(e)
  children()
  outer.domParent = prevParent
  outer.domBefore = prevBefore
  result = e

proc uiKey*[T](value: T) {.discardable.} =
  ## Marker emitted by the `for ...: key expr` syntax pass. The state plugin
  ## consumes it when it turns the loop into `forEachList`.
  discard value


proc uiLoop*(body: proc () {.closure.}): E {.yithInternal, discardable.} =
  result = uiBlock(body)

template uiCaseBlock*(body: untyped): E =
  ## Re-runnable block for `case resource:`. The block subscribes to the
  ## resource's `value` state; a kind change rebuilds the branch.
  uiBlock(proc () {.closure.} = body)

template uiIf*(cond: untyped; thenBody, elseBody: untyped): E =
  uiWhen(proc (): bool {.closure.} = cond,
         proc () {.closure.} = thenBody,
         proc () {.closure.} = elseBody)

template uiFor*(body: untyped): E =
  uiLoop(proc () {.closure.} = body)

type
  ForEachRow*[T] = ref object
    key*: string
    item*: T
    e*: E

  RowBox = ref object
    e: E

proc forEachList*[T](items: State[seq[T]];
                     same: proc (a, b: T): bool {.closure.};
                     key: proc (item: T): string {.closure.};
                     render: proc (item: T): E {.closure.}): E {.discardable.} =
  ## Keyed list over a plain `State[seq[T]]`. Rows with the same key survive
  ## reorder; changed content is re-rendered, removed keys are disposed.
  let outer = current
  let parent = outer.domParent
  let anchor = createComment("yith.foreach")
  appendNode(anchor)

  let sc = newScope(nil)
  sc.domParent = parent
  sc.domBefore = anchor
  sc.keepChildren = true
  var rows: seq[ForEachRow[T]] = @[]

  sc.run = proc () {.closure.} =
    let xs = items.get()
    var nextRows: seq[ForEachRow[T]] = @[]
    var i = 0
    while i < xs.len:
      let item = xs[i]
      let k = key(item)
      var found: ForEachRow[T] = nil
      var j = 0
      while j < rows.len:
        if rows[j].key == k:
          found = rows[j]
          break
        inc j
      if found != nil and same(found.item, item):
        nextRows.add found
      else:
        if found != nil:
          dispose(found.e.scope)
        let box = RowBox()
        let rowScope = newScope(nil)
        rowScope.domParent = parent
        rowScope.domBefore = anchor
        rowScope.run = proc () {.closure.} =
          box.e = render(item)
        runScope(rowScope)
        nextRows.add ForEachRow[T](key: k, item: item, e: box.e)
      inc i

    i = 0
    while i < rows.len:
      var keep = false
      var j = 0
      while j < nextRows.len:
        if rows[i].key == nextRows[j].key:
          keep = true
          break
        inc j
      if not keep:
        dispose(rows[i].e.scope)
      inc i

    i = 0
    while i < nextRows.len:
      moveRangeBefore(nextRows[i].e, parent, anchor)
      inc i
    rows = nextRows

  runScope(sc)
  result = E(scope: sc, startNode: anchor, endNode: nil)

type
  WhenState = ref object
    last: int
    branch: Scope

proc uiWhen*(cond: proc (): bool {.closure.};
             thenBody, elseBody: proc () {.closure.}): E {.yithInternal, discardable.} =
  let outer = current
  let parent = outer.domParent
  let before = outer.domBefore
  let st = WhenState(last: -1)
  let anchor = createComment("yith.when")
  appendNode(anchor)

  let sc = newScope(nil)
  sc.keepChildren = true
  sc.domParent = parent
  sc.domBefore = anchor
  sc.run = proc () {.closure.} =
    let c = cond()
    let k = if c: 1 else: 0
    if k != st.last:
      if st.branch != nil:
        dispose(st.branch)
        st.branch = nil
      st.last = k
      let branch = newScope(nil)
      branch.domParent = parent
      branch.domBefore = anchor
      branch.run = (if c: thenBody else: elseBody)
      st.branch = branch
      runScope(branch)
  runScope(sc)
  result = E(scope: sc)

# ------------------------------------------------------------------ components

template El*(tag: string; body: untyped) =
  elementVoid(tag, proc () {.closure.} = body)

template ElE*(tag: string; body: untyped): E =
  elementE(tag, proc () {.closure.} = body)

template Box*(body: untyped) =
  elementVoid("div", proc () {.closure.} = body)

template BoxE*(body: untyped): E =
  elementE("div", proc () {.closure.} = body)

template Box*(className: string; body: untyped) =
  block:
    let e = elementE("div", proc () {.closure.} = body)
    attr(e, "class", className)

template BoxE*(className: string; body: untyped): E =
  block:
    let e = elementE("div", proc () {.closure.} = body)
    attr(e, "class", className)
    finish(e)

template Button*(body: untyped) =
  elementVoid("button", proc () {.closure.} = body)

template ButtonE*(body: untyped): E =
  elementE("button", proc () {.closure.} = body)

template Button*(variant, className: string; disabled: bool; body: untyped) =
  block:
    let e = elementE("button", proc () {.closure.} = body)
    attr(e, "data-variant", variant)
    attr(e, "class", className)
    boolAttr(e, "disabled", disabled)

template ButtonE*(variant, className: string; disabled: bool;
                  body: untyped): E =
  block:
    let e = elementE("button", proc () {.closure.} = body)
    attr(e, "data-variant", variant)
    attr(e, "class", className)
    boolAttr(e, "disabled", disabled)
    finish(e)

template When*(cond: untyped; thenBody: untyped; elseBody: untyped): E =
  uiWhen(proc (): bool {.closure.} =
           result = cond,
         proc () {.closure.} = thenBody,
         proc () {.closure.} = elseBody)

# --------------------------------------------------------------------- events

proc on*(e: E; event: string; cb: proc (ev: Event) {.closure.}) =
  addEventListener(e.startNode, event, cb)
  onCleanup(proc () {.closure.} =
    removeEventListener(e.startNode, event))

template OnClick*(e: E; body: untyped) =
  on(e, "click", proc (ev: Event) {.closure.} = body)
