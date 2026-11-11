## Post-sem plugin: turn `{.state.}` declarations into `State[T]`.
##
## The UI syntax pass (`uiblock_plugin`) leaves `{.state.}` untouched, so the
## module is ordinary Nimony after that pass: a state variable is a plain
## value, `state(v)` is an identity proc and every read/write is a normal
## read/write. This plugin then rewrites the declaration and every use that
## the semantic pass resolved to it:
##
##   var name {.state.}: string = state("light")
##   name = name & "!"
##
## becomes
##
##   var name: State[string] = newState("light")
##   name.set(name.get() & "!")
##
## Because the plugin output is semchecked again, the plugin emits
## source-level NIF (idents for `State`, `get`, `set`, `newState`) and lets
## Nimony resolve the overloads. The final result is a normal, fully typed
## module; reactivity works exactly as with the hand-written State API.
##
## The UI syntax pass references `PluginHook` (declared with
## `{.plugin: "state_plugin".}`), so components enable this pass automatically.
## A state-only module enables it with an explicit `{.plugin. ...}` directive.

import plugins

{.feature: "assumeSync".}

type
  StateKind = enum
    skDecl      ## `{.state.}`; declaration and uses are rewritten
    skValue     ## already `State[T]`; only uses are rewritten
    skDerived   ## local derived from state reads; uses are rewritten

  StateInfo = object
    name: string
    kind: StateKind
    typ: NifCursor

  ProcInfo = object
    name: string
    stateParams: seq[int]

var states: seq[StateInfo] = @[]
var procs: seq[ProcInfo] = @[]
var mainFile = ""
var renameFrom = ""
var renameTo = ""
var renameActive = false
var freshItem = 0

proc endsWith(s, suffix: string): bool =
  if s.len < suffix.len: return false
  var i = 0
  while i < suffix.len:
    if s[s.len - suffix.len + i] != suffix[i]: return false
    inc i
  result = true

proc isForeign(n: NifCursor): bool =
  let f = filePath(n.info)
  result = f.len > 0 and mainFile.len > 0 and
    f != mainFile and not endsWith(f, mainFile) and not endsWith(mainFile, f)

proc isForeignDecl(n: NifCursor): bool =
  ## Instantiated generics and imported declarations are appended to the
  ## semchecked module. Skip those declarations wholesale, but keep walking
  ## ordinary statements: an `echo` can carry the line info of the `syncio`
  ## template body while still using application state.
  result = false
  if n.kind != TagLit:
    return false
  let t = n.tagText
  if t == "proc" or t == "func" or t == "iterator" or t == "template":
    if isForeign(n):
      return true
    let r = asRoutine(n)
    return isForeign(r.body)
  result = isForeign(n) and
    (t == "type" or t == "gvar" or t == "glet" or t == "var" or
     t == "let" or t == "const")

proc nameOf(n: NifCursor): string =
  if n.kind == Symbol or n.kind == SymbolDef:
    result = symText(n)
  elif n.kind == Ident:
    result = identText(n)
  else:
    result = ""

proc firstArg(n: NifCursor): NifCursor =
  result = firstChild(n)
  skip result

proc startsWith(s, prefix: string): bool =
  if s.len < prefix.len: return false
  var i = 0
  while i < prefix.len:
    if s[i] != prefix[i]: return false
    inc i
  result = true

proc stateIndex(name: string): int =
  result = -1
  var i = 0
  while i < states.len:
    if states[i].name == name:
      return i
    inc i

proc addState(name: string; kind: StateKind; typ: NifCursor) =
  if name.len == 0: return
  let i = stateIndex(name)
  if i >= 0:
    if kind == skDecl:
      states[i].kind = skDecl
      states[i].typ = typ
  else:
    states.add StateInfo(name: name, kind: kind, typ: typ)

proc hasState(name: string): bool =
  result = stateIndex(name) >= 0

proc stateKind(name: string): StateKind =
  let i = stateIndex(name)
  if i >= 0: states[i].kind else: skValue

# ------------------------------------------------------------------ pragmas

proc isStatePragmaItem(p: NifCursor): bool =
  result = false
  if p.kind == TagLit and p.tagText == "pragma":
    var q = p
    q.into:
      if q.hasMore and (q.kind == Symbol or q.kind == Ident):
        let t = nameOf(q)
        if t == "state" or startsWith(t, "state."):
          result = true
      while q.hasMore:
        skip q

proc hasStatePragma(p: NifCursor): bool =
  result = false
  if p.kind == TagLit and p.tagText == "pragmas":
    var c = p
    c.into:
      while c.hasMore:
        if isStatePragmaItem(c):
          result = true
        skip c

proc copyPragmasWithoutState(p: NifCursor; b: var NifBuilder) =
  ## Copy `(pragmas …)` minus `state`, or emit `.` when nothing remains.
  if p.kind == TagLit and p.tagText == "pragmas":
    var tmp = createTree()
    var wrote = false
    tmp.openTree(p.tagId, p.info)
    var c = p
    c.into:
      while c.hasMore:
        if isStatePragmaItem(c):
          skip c
        else:
          takeTree tmp, c
          wrote = true
    tmp.closeTree()
    if wrote:
      var r = snapshot(tmp)
      b.takeTree r
    else:
      b.addEmptyNode()
  else:
    var c = p
    takeTree b, c

# ------------------------------------------------------------------- types

proc isStateRefType(t: NifCursor): bool =
  ## A semchecked `State[T]` / `Computed[T]` is `(ref State.Obj… .)`.
  result = false
  if t.kind != TagLit:
    return false
  if t.tagText == "ref" or t.tagText == "ptr":
    var c = firstChild(t)
    if c.kind == Symbol:
      let base = symBasename(c.symId)
      if base == "State.Obj" or base == "Computed.Obj":
        result = true
  elif t.tagText == "at":
    var c = firstChild(t)
    if (c.kind == Symbol or c.kind == Ident) and
       (baseName(nameOf(c)) == "State" or baseName(nameOf(c)) == "Computed"):
      result = true

proc isStateHeadType(t: NifCursor): bool =
  ## `(at State T)` in untyped code or a bare `State` ident.
  result = false
  if t.kind == TagLit and t.tagText == "at":
    var c = firstChild(t)
    if (c.kind == Symbol or c.kind == Ident) and
       (baseName(nameOf(c)) == "State" or baseName(nameOf(c)) == "Computed"):
      result = true

proc isSeqType(t: NifCursor): bool =
  result = false
  if t.kind == TagLit and t.tagText == "at":
    var c = firstChild(t)
    if (c.kind == Symbol or c.kind == Ident):
      let n = nameOf(c)
      if n == "seq" or startsWith(n, "seq."):
        result = true
  elif t.kind == Symbol:
    let n = symText(t)
    if n == "seq" or startsWith(n, "seq."):
      result = true

proc seqItemType(t: NifCursor): NifCursor =
  ## `seq[T]` -> cursor at `T`; exhausted otherwise.
  result = default(NifCursor)
  if t.kind == TagLit and t.tagText == "at":
    var c = firstChild(t)
    skip c
    if c.hasMore:
      result = c

proc isBareSymbol(n: NifCursor): bool =
  result = n.kind == Symbol or n.kind == Ident

# --------------------------------------------------------------- collecting

proc collect(n: NifCursor)

proc collectDecl(n: NifCursor) =
  let loc = asLocal(n)
  let name = nameOf(loc.name)
  if hasStatePragma(loc.pragmas):
    addState(name, skDecl, loc.typ)
  elif isStateRefType(loc.typ):
    addState(name, skValue, loc.typ)

proc collect(n: NifCursor) =
  if n.kind != TagLit: return
  if isForeignDecl(n):
    return
  let t = n.tagText
  if t == "let" or t == "var" or t == "glet" or t == "gvar" or t == "const":
    collectDecl(n)
  elif n.otherKind == ParamU:
    collectDecl(n)
  var c = n
  c.into:
    while c.hasMore:
      collect(c)
      skip c

proc collectProcs(n: NifCursor) =
  if n.kind != TagLit: return
  if isForeignDecl(n):
    return
  let t = n.tagText
  if t == "proc" or t == "func":
    let r = asRoutine(n)
    var p = r.params
    var pos = 0
    var sp: seq[int] = @[]
    p.into:
      while p.hasMore:
        if p.otherKind == ParamU:
          let loc = asLocal(p)
          if hasStatePragma(loc.pragmas) or isStateRefType(loc.typ):
            sp.add pos
          inc pos
        skip p
    if sp.len > 0:
      procs.add ProcInfo(name: symBasenameOrName(r.name), stateParams: sp)
  var c = n
  c.into:
    while c.hasMore:
      collectProcs(c)
      skip c

proc stateParamsOf(name: string): seq[int] =
  result = @[]
  var i = 0
  while i < procs.len:
    if procs[i].name == name:
      return procs[i].stateParams
    inc i

proc baseName(s: string): string =
  result = ""
  var i = 0
  while i < s.len and s[i] != '.':
    result.add s[i]
    inc i

proc symBasenameOrName(n: NifCursor): string =
  if n.kind == Symbol:
    result = baseName(symBasename(n.symId))
  else:
    result = baseName(nameOf(n))

proc containsState(n: NifCursor): bool =
  ## True when the subtree reads a state symbol. Explicit `get`/`set` calls
  ## are transparent: their receiver is not a reactive read for this purpose.
  result = false
  if n.kind != TagLit:
    if (n.kind == Symbol or n.kind == Ident) and hasState(nameOf(n)):
      result = true
    return
  if n.tagText == "call" or n.tagText == "cmd":
    var fn = firstChild(n)
    var api = ""
    if fn.kind == Symbol or fn.kind == Ident:
      api = symBasenameOrName(fn)
    elif fn.kind == TagLit and fn.tagText == "dot":
      let d = asDot(fn)
      api = nameOf(d.field)
    if api == "set" or api == "update":
      return false
    if api == "state" or api == "newState" or api == "computed" or
       api == "computedExpr":
      return false
  if n.tagText == "proc" or n.tagText == "func" or n.tagText == "lambda":
    return
  var c = n
  c.into:
    while c.hasMore:
      if containsState(c): result = true
      skip c

proc hasUiPragma(p: NifCursor): bool =
  result = false
  if p.kind == TagLit and p.tagText == "pragmas":
    var c = p
    c.into:
      while c.hasMore:
        let n = symBasenameOrName(c)
        if n == "yithUi":
          result = true
        skip c

proc collectDerived(n: NifCursor; changed: var bool; inUi: bool) =
  if n.kind != TagLit: return
  if isForeignDecl(n):
    return
  let t = n.tagText
  if t == "proc" or t == "func" or t == "iterator" or t == "template":
    let r = asRoutine(n)
    let childUi = inUi or hasUiPragma(r.pragmas)
    var c = n
    c.into:
      while c.hasMore:
        collectDerived(c, changed, childUi)
        skip c
    return
  if inUi and (t == "let" or t == "var" or t == "glet" or t == "gvar"):
    let loc = asLocal(n)
    let name = nameOf(loc.name)
    var doSkip = false
    if loc.val.kind == TagLit and loc.val.tagText == "call":
      var fn = firstChild(loc.val)
      let h = symBasenameOrName(fn)
      if h.len > 0 and h[0] >= 'A' and h[0] <= 'Z':
        doSkip = true
      if h == "uiBlock" or h == "uiFragment" or h == "fragment" or
         h == "newState" or h == "computed" or h == "computedExpr":
        doSkip = true
    if startsWith(baseName(name), "yith"):
      # A temp emitted by this plugin or the syntax pass; never make it a
      # derived state, or the next plugin round would re-wrap it.
      discard
    elif doSkip:
      discard
    elif not hasState(name) and loc.val.kind != DotToken:
      if containsState(loc.val):
        addState(name, skDerived, loc.typ)
        changed = true
  var c = n
  c.into:
    while c.hasMore:
      collectDerived(c, changed, inUi)
      skip c

# -------------------------------------------------------------- emit helpers

proc tr(n: var NifCursor; b: var NifBuilder)

proc emitGet(n: var NifCursor; b: var NifBuilder) =
  b.openTree(TagId(CallX), n.info)
  b.addIdent "get"
  b.takeTree n
  b.closeTree()

proc emitSet(lhs, rhs: var NifCursor; b: var NifBuilder) =
  b.openTree(TagId(CallX), lhs.info)
  b.addIdent "set"
  b.takeTree lhs
  tr(rhs, b)
  b.closeTree()

proc cleanProcPragmas(n: var NifCursor; b: var NifBuilder) =
  ## The `{.ui.}` pragma is removed by the syntax pass; this also drops a
  ## stray `state` if a user attached it to a routine.
  if n.kind == TagLit and n.tagText == "pragmas":
    var tmp = createTree()
    var wrote = false
    tmp.openTree(n.tagId, n.info)
    n.into:
      while n.hasMore:
        if isStatePragmaItem(n):
          skip n
        else:
          takeTree tmp, n
          wrote = true
    tmp.closeTree()
    if wrote:
      var r = snapshot(tmp)
      b.takeTree r
    else:
      b.addEmptyNode()
  else:
    takeTree b, n

proc emitStateType(t: NifCursor; b: var NifBuilder) =
  if isStateRefType(t) or isStateHeadType(t):
    var c = t
    b.takeTree c
  else:
    b.withTree AtT, t.info:
      b.addIdent "State"
      var c = t
      b.takeTree c

proc emitStateValue(n: NifCursor; b: var NifBuilder; typ: NifCursor) =
  ## `v` -> `newState(v)`, unwrapping the identity `state(v)` placeholder.
  var call = false
  var arg = n
  if n.kind == TagLit and n.tagText == "call":
    var fn = firstChild(n)
    let fname = if fn.kind == Symbol: symBasename(fn.symId) else: nameOf(fn)
    if fname == "state":
      call = true
      arg = firstChild(n)
      skip arg
  b.openTree(TagId(CallX), n.info)
  b.addIdent "newState"
  if call:
    if arg.hasMore:
      tr(arg, b)
    else:
      b.withTree CallX, n.info:
        b.addIdent "default"
        var t = typ
        b.takeTree t
  elif n.kind == DotToken:
    b.withTree CallX, n.info:
      b.addIdent "default"
      var t = typ
      b.takeTree t
  else:
    var v = n
    tr(v, b)
  b.closeTree()

proc emitStateDecl(n: var NifCursor; b: var NifBuilder) =
  let loc = asLocal(n)
  let name = nameOf(loc.name)
  let kind = stateKind(name)
  b.openTree(n.tagId, n.info)
  var nm = loc.name
  b.takeTree nm
  var ex = loc.exported
  b.takeTree ex
  var pr = loc.pragmas
  copyPragmasWithoutState(pr, b)
  if kind == skDecl:
    emitStateType(loc.typ, b)
    var iv = loc.val
    emitStateValue(iv, b, loc.typ)
  elif kind == skDerived:
    emitStateType(loc.typ, b)
    b.openTree(TagId(CallX), n.info)
    b.addIdent "computedExpr"
    var iv = loc.val
    tr(iv, b)
    b.closeTree()
  else:
    var ty = loc.typ
    b.takeTree ty
    var iv = loc.val
    if iv.kind == DotToken:
      b.addEmptyNode()
    else:
      tr(iv, b)
  b.closeTree()

proc emitParam(n: var NifCursor; b: var NifBuilder) =
  let loc = asLocal(n)
  let name = nameOf(loc.name)
  let kind = stateKind(name)
  b.openTree(n.tagId, n.info)
  var nm = loc.name
  b.takeTree nm
  var ex = loc.exported
  b.takeTree ex
  var pr = loc.pragmas
  copyPragmasWithoutState(pr, b)
  if kind == skDecl or (kind == skValue and hasStatePragma(loc.pragmas)):
    emitStateType(loc.typ, b)
  else:
    var ty = loc.typ
    b.takeTree ty
  var dv = loc.val
  if dv.kind == DotToken:
    b.addEmptyNode()
  else:
    tr(dv, b)
  b.closeTree()

proc isStateArg(n: NifCursor): bool =
  ## An argument that already is a `State`: a state symbol, a State field, or
  ## an explicit `newState(...)` call.
  result = false
  if (n.kind == Symbol or n.kind == Ident) and hasState(nameOf(n)):
    result = true
  elif n.kind == TagLit:
    if n.tagText == "dot" or n.tagText == "ddot":
      result = true
    elif n.tagText == "call":
      var fn = firstChild(n)
      if fn.kind == Symbol or fn.kind == Ident:
        let h = symBasenameOrName(fn)
        if h == "newState" or h == "computedExpr" or h == "computed":
          result = true
    elif n.tagText == "newobj" or n.tagText == "newref":
      result = true

proc containsReactive(n: NifCursor): bool =
  ## Like `containsState`, but an explicit `get`/`peek`/`stateValue` of a
  ## State receiver counts: in a value position it must subscribe.
  result = false
  if n.kind != TagLit:
    if (n.kind == Symbol or n.kind == Ident) and hasState(nameOf(n)):
      result = true
    return
  if n.tagText == "call" or n.tagText == "cmd":
    var fn = firstChild(n)
    var api = ""
    if fn.kind == Symbol or fn.kind == Ident:
      api = symBasenameOrName(fn)
    if api == "get" or api == "peek" or api == "stateValue":
      var a = firstChild(n)
      skip a
      if a.hasMore and isStateArg(a):
        return true
    if api == "set" or api == "update":
      return false
  var c = n
  c.into:
    while c.hasMore:
      if containsReactive(c): result = true
      skip c

proc isReactiveValue(n: NifCursor): bool =
  result = isStateArg(n) or containsReactive(n)

proc emitReactiveValue(n: var NifCursor; b: var NifBuilder) =
  ## In a `Text`/attribute value position a bare State is passed as is (the
  ## runtime has State overloads that subscribe); an expression that reads
  ## state is wrapped in `computedExpr` so it becomes a State.
  if isStateArg(n):
    b.takeTree n
  elif containsReactive(n):
    b.withTree CallX, n.info:
      b.addIdent "computedExpr"
      tr(n, b)
  else:
    tr(n, b)

proc isValueCall(name: string): bool =
  result = name == "Text" or name == "setAttr" or name == "setBoolAttr" or
    name == "attr" or name == "boolAttr" or name == "addClass" or
    name == "addStyle" or name == "setProp"

proc findFor(n: NifCursor): NifCursor =
  result = default(NifCursor)
  if n.kind != TagLit:
    return
  if n.stmtKind == ForS:
    result = n
    return
  var c = n
  c.into:
    while c.hasMore:
      let r = findFor(c)
      if r.hasMore:
        result = r
      skip c

proc findStateSym(n: NifCursor): NifCursor =
  result = default(NifCursor)
  if n.kind != TagLit:
    if (n.kind == Symbol or n.kind == Ident) and hasState(nameOf(n)):
      result = n
    return
  var c = n
  c.into:
    while c.hasMore:
      if not result.hasMore:
        let r = findStateSym(c)
        if r.hasMore: result = r
      skip c

proc loopVarType(vars: NifCursor): NifCursor =
  ## `(unpackflat (let item . . (mut T) .))` -> `T`.
  result = default(NifCursor)
  var c = vars
  if c.kind == TagLit and c.tagText == "unpackflat":
    c = firstChild(c)
  if c.kind == TagLit and c.tagText == "let":
    let loc = asLocal(c)
    result = loc.typ
    if result.kind == TagLit and result.tagText == "mut" and firstChild(result).hasMore:
      result = firstChild(result)

proc makeLambdaTyped(info: LineInfo; pnames: seq[string];
                     ptypes: seq[NifCursor]; retType: string;
                     body: NifBuilder): NifBuilder =
  result = createTree()
  result.withTree ProcS, info:
    result.addEmptyNode4(info)
    result.withTree ParamsU, info:
      var i = 0
      while i < pnames.len:
        result.withTree ParamU, info:
          result.addIdent pnames[i]
          result.addEmptyNode2(info)
          var t = ptypes[i]
          result.takeTree t
          result.addEmptyNode()
        inc i
    if retType.len > 0:
      result.addIdent retType
    else:
      result.addEmptyNode()
    result.withTree PragmasU, info:
      result.addIdent "closure"
    result.addEmptyNode()
    result.addTree body

proc tryKeyedLoop(n: var NifCursor; b: var NifBuilder): bool =
  ## `uiLoop(proc() = for x in items: uiKey(x); body)` -> keyed
  ## `forEachList(items, same, key, render)`.
  result = false
  var arg = firstArg(n)
  let forNode: NifCursor = findFor(arg)
  if not forNode.hasMore:
    return
  let iterable = firstChild(forNode)
  var vars = iterable
  skip vars
  var body = vars
  skip body
  let itemType: NifCursor = loopVarType(vars)
  if not itemType.hasMore:
    return
  let stateSym: NifCursor = findStateSym(iterable)
  if not stateSym.hasMore:
    return

  let bodyCursor: NifCursor = body
  var keyExpr = default(NifCursor)
  var hasKey = false
  if bodyCursor.kind == TagLit:
    var c = firstChild(bodyCursor)
    if c.hasMore and c.kind == TagLit and
       (c.tagText == "call" or c.tagText == "cmd") and
       symBasenameOrName(firstChild(c)) == "uiKey":
      var a = firstArg(c)
      if a.hasMore:
        keyExpr = a
        hasKey = true
  if not hasKey:
    return

  var itemName = "yithItem"
  var loopVars = vars
  if loopVars.kind == TagLit and loopVars.tagText == "unpackflat":
    loopVars = firstChild(loopVars)
  if loopVars.kind == TagLit and loopVars.tagText == "let":
    let loc = asLocal(loopVars)
    let nm = nameOf(loc.name)
    if nm.len > 0:
      itemName = nm

  # same(item, item): bool = ==(item, item)
  var sameBody = createTree()
  sameBody.withTree StmtsS, forNode.info:
    sameBody.withTree RetS, forNode.info:
      sameBody.withTree InfixX, forNode.info:
        sameBody.addIdent "=="
        sameBody.addIdent "yithA"
        sameBody.addIdent "yithB"
  var sameParams = @["yithA", "yithB"]
  var sameTypes = @[itemType, itemType]
  let sameLam: NifBuilder = makeLambdaTyped(forNode.info, sameParams, sameTypes, "bool", sameBody)

  let keyParam = "yithKeyItem" & $freshItem
  inc freshItem
  let renderParam = "yithRenderItem" & $freshItem
  inc freshItem

  # key(item): string = $keyExpr
  var keyBody = createTree()
  keyBody.withTree StmtsS, keyExpr.info:
    keyBody.withTree RetS, keyExpr.info:
      keyBody.withTree PrefixX, keyExpr.info:
        keyBody.addIdent "$"
        renameActive = true
        renameFrom = itemName
        renameTo = keyParam
        var k = keyExpr
        tr(k, keyBody)
        renameActive = false
  let keyLam: NifBuilder = makeLambdaTyped(keyExpr.info, @[keyParam], @[itemType], "string", keyBody)

  # render(item): E = rest of the loop body
  var renderBody = createTree()
  renderBody.withTree StmtsS, bodyCursor.info:
    if bodyCursor.kind == TagLit:
      renameActive = true
      renameFrom = itemName
      renameTo = renderParam
      var c = firstChild(bodyCursor)
      if hasKey:
        skip c
      while c.hasMore:
        tr(c, renderBody)
      renameActive = false
  let renderLam: NifBuilder = makeLambdaTyped(bodyCursor.info, @[renderParam], @[itemType], "E", renderBody)

  b.withTree CallX, n.info:
    b.addIdent "forEachList"
    var s = stateSym
    b.takeTree s
    b.addTree sameLam
    b.addTree keyLam
    b.addTree renderLam
  result = true

proc emitLazyValue(n: var NifCursor; b: var NifBuilder; retType: string;
                   stringify = false) =
  ## `watchValue(proc (): RET {.closure.} = expr)`. The named `watchValue`
  ## keeps the derived State in its own frame, so closure conversion cannot
  ## hoist it into the caller's shared environment. `stringify` emits `$expr`
  ## for text/attribute positions.
  var body = createTree()
  body.withTree StmtsS, n.info:
    if stringify:
      body.withTree PrefixX, n.info:
        body.addIdent "$"
        tr(n, body)
    else:
      tr(n, body)
  let lam = makeLambdaTyped(n.info, @[], @[], retType, body)
  b.withTree CallX, n.info:
    b.addIdent "watchValue"
    b.addTree lam

proc emitCall(n: var NifCursor; b: var NifBuilder) =
  var fn = firstChild(n)
  var args = fn
  skip args
  var fnName = ""
  if fn.kind == Symbol or fn.kind == Ident:
    fnName = symBasenameOrName(fn)
  elif fn.kind == TagLit and fn.tagText == "dot":
    let d = asDot(fn)
    fnName = nameOf(d.field)

  # Explicit state API: keep the receiver as is, rewrite the other arguments.
  if fnName == "get" or fnName == "set" or fnName == "update" or
     fnName == "peek" or fnName == "stateValue" or
     fnName == "subscriberCount" or fnName == "signalId":
    b.openTree(n.tagId, n.info)
    b.takeTree fn
    var a = args
    if a.hasMore:
      b.takeTree a
    while a.hasMore:
      tr(a, b)
    b.closeTree()
    return

  # Keyed lists take the State itself, like a state parameter.
  if fnName == "forEachList":
    b.openTree(n.tagId, n.info)
    b.takeTree fn
    var a = args
    if a.hasMore:
      b.takeTree a
    while a.hasMore:
      tr(a, b)
    b.closeTree()
    return

  let paramPositions = stateParamsOf(fnName)
  var nargs = 0
  var lastArg = args
  var scan = args
  while scan.hasMore:
    lastArg = scan
    inc nargs
    skip scan
  var valuePos = -1
  if isValueCall(fnName) and nargs > 0:
    valuePos = nargs - 1
  var reactive = false
  if valuePos >= 0:
    reactive = isReactiveValue(lastArg)

  b.openTree(n.tagId, n.info)
  if reactive:
    b.addIdent fnName
  else:
    b.takeTree fn
  var a = args
  var idx = 0
  while a.hasMore:
    if idx == valuePos and reactive:
      if isStateArg(a):
        b.takeTree a
      elif fnName == "addStyle":
        emitLazyValue(a, b, "string")
      elif fnName == "addClass":
        var retType = "string"
        if nargs == 3:
          retType = "bool"
        emitLazyValue(a, b, retType)
      elif fnName == "Text":
        emitLazyValue(a, b, "string", stringify = true)
      elif fnName == "setAttr" or fnName == "attr":
        emitLazyValue(a, b, "string", stringify = true)
      elif fnName == "setBoolAttr" or fnName == "boolAttr":
        emitLazyValue(a, b, "bool")
      else:
        emitReactiveValue(a, b)
    else:
      var passBare = false
      var k = 0
      while k < paramPositions.len:
        if paramPositions[k] == idx: passBare = true
        inc k
      if passBare:
        if isStateArg(a):
          b.takeTree a
        else:
          b.openTree(TagId(CallX), a.info)
          b.addIdent "newState"
          tr(a, b)
          b.closeTree()
      else:
        tr(a, b)
    inc idx
  b.closeTree()

proc emitInfix(n: var NifCursor; b: var NifBuilder) =
  var op = firstChild(n)
  var lhs = op
  skip lhs
  if (op.kind == Ident or op.kind == Symbol) and
     (lhs.kind == Symbol or lhs.kind == Ident) and hasState(nameOf(lhs)) and
     stateKind(nameOf(lhs)) != skDecl:
    # Explicit `State[T]` handles already define `+=`, `&=`, ... . Keep the
    # operator and the receiver, but still rewrite state reads on the RHS.
    var rhs = lhs
    skip rhs
    b.openTree(TagId(InfixX), n.info)
    var o = op
    b.takeTree o
    var l = lhs
    b.takeTree l
    tr(rhs, b)
    b.closeTree()
    skip n
    return
  if (op.kind == Ident or op.kind == Symbol) and
     (lhs.kind == Symbol or lhs.kind == Ident) and
     stateKind(nameOf(lhs)) == skDecl:
    let o = symBasenameOrName(op)
    var mapped = o
    var compound = true
    if o == "+=" or o == "\\2B=": mapped = "+"
    elif o == "-=" or o == "\\2D=": mapped = "-"
    elif o == "*=" or o == "\\2A=": mapped = "*"
    elif o == "/=" or o == "\\2F=": mapped = "div"
    elif o == "&=" or o == "\\26=": mapped = "&"
    else: compound = false
    if compound:
      var rhs = lhs
      skip rhs
      b.openTree(TagId(CallX), n.info)
      b.addIdent "set"
      b.takeTree lhs
      b.withTree InfixX, n.info:
        b.addIdent mapped
        var l = op
        skip l
        emitGet(l, b)
        tr(rhs, b)
      b.closeTree()
      skip n
      return
  var tag = n.tagId
  var info = n.info
  n.into:
    b.openTree(tag, info)
    while n.hasMore:
      tr(n, b)
    b.closeTree()

proc emitAsgn(n: var NifCursor; b: var NifBuilder) =
  var lhs = firstChild(n)
  if (lhs.kind == Symbol or lhs.kind == Ident) and
     stateKind(nameOf(lhs)) == skDecl:
    var rhs = lhs
    skip rhs
    emitSet(lhs, rhs, b)
    skip n
  else:
    var tag = n.tagId
    var info = n.info
    # Leave a non-state lvalue untouched; only its value may read state.
    n.into:
      b.openTree(tag, info)
      var first = true
      while n.hasMore:
        if first:
          if n.kind == TagLit:
            tr(n, b)
          else:
            b.takeTree n
          first = false
        else:
          tr(n, b)
      b.closeTree()

proc liftMethod(n: var NifCursor; b: var NifBuilder): bool =
  ## `items.add(5)` (semchecked as `add(items, 5)`) -> mutate through a temp:
  ## `var v = items.get(); add(v, 5); items.set(v)`.
  var fn = firstChild(n)
  var args = fn
  skip args
  if not args.hasMore: return false
  var recv = args
  if (recv.kind != Symbol and recv.kind != Ident) or not hasState(nameOf(recv)):
    return false
  let tmp = "yithV"
  b.withTree BlockS, n.info:
    b.addEmptyNode()
    b.withTree StmtsS, n.info:
      b.withTree VarS, n.info:
        b.addIdent tmp
        b.addEmptyNode3()
        emitGet(recv, b)
      b.openTree(TagId(CallX), n.info)
      var f = fn
      b.takeTree f
      b.addIdent tmp
      var a = args
      skip a
      while a.hasMore:
        tr(a, b)
      b.closeTree()
      b.openTree(TagId(CallX), n.info)
      b.addIdent "set"
      var r = args
      b.takeTree r
      b.addIdent tmp
      b.closeTree()
  result = true

proc isMutator(name: string): bool =
  ## Only these method calls are lifted through get/mutate/set. Unknown
  ## methods are reads; their receiver is rewritten to `get`.
  result = name == "add" or name == "push" or name == "pop" or
    name == "insert" or name == "delete" or name == "remove" or
    name == "clear" or name == "inc" or name == "dec" or
    name == "refetch" or name == "mutate"

proc tr(n: var NifCursor; b: var NifBuilder) =
  if n.kind == TagLit and isForeignDecl(n):
    b.takeTree n
    return
  if n.kind != TagLit:
    if renameActive and (n.kind == Symbol or n.kind == Ident) and
       nameOf(n) == renameFrom:
      b.addIdent renameTo
      skip n
      return
    if (n.kind == Symbol or n.kind == Ident) and hasState(nameOf(n)):
      emitGet(n, b)
    else:
      b.takeTree n
    return

  let t = n.tagText
  if t == "let" or t == "var" or t == "glet" or t == "gvar":
    let loc = asLocal(n)
    let name = nameOf(loc.name)
    if hasState(name):
      emitStateDecl(n, b)
      skip n
      return
    var tag = n.tagId
    var info = n.info
    n.into:
      b.openTree(tag, info)
      var first = true
      while n.hasMore:
        if first:
          b.takeTree n
          first = false
        else:
          tr(n, b)
      b.closeTree()
    return
  elif n.otherKind == ParamU:
    emitParam(n, b)
    skip n
    return
  elif n.stmtKind == AsgnS:
    emitAsgn(n, b)
    return
  elif t == "infix":
    emitInfix(n, b)
    return
  elif t == "call" or t == "cmd":
    var fn = firstChild(n)
    var fnName = ""
    if fn.kind == Symbol or fn.kind == Ident:
      fnName = symBasenameOrName(fn)
    if fnName == "uiLoop":
      if tryKeyedLoop(n, b):
        skip n
        return
    if t == "call" and isMutator(fnName):
      var tmp = n
      if liftMethod(tmp, b):
        skip n
        return
    emitCall(n, b)
    skip n
    return
  elif t == "dot" or t == "ddot":
    var obj = firstChild(n)
    if (obj.kind == Symbol or obj.kind == Ident) and hasState(nameOf(obj)):
      var tag = n.tagId
      var info = n.info
      n.into:
        b.openTree(tag, info)
        emitGet(obj, b)
        while n.hasMore:
          b.takeTree n
        b.closeTree()
      return
  elif t == "proc" or t == "func" or t == "template" or t == "iterator":
    let r = asRoutine(n)
    var tag = n.tagId
    var info = n.info
    n.into:
      b.openTree(tag, info)
      var i = 0
      while n.hasMore:
        if i == 4:
          tr(n, b)
        elif i == 6:
          cleanProcPragmas(n, b)
        elif i == 8:
          tr(n, b)
        else:
          b.takeTree n
        inc i
      b.closeTree()
    return
  elif t == "pragmas" or t == "typevars" or t == "type":
    # Types are not expressions; never rewrite a type argument as a read.
    var tag = n.tagId
    var info = n.info
    n.into:
      b.openTree(tag, info)
      while n.hasMore:
        b.takeTree n
      b.closeTree()
    return

  var tag = n.tagId
  var info = n.info
  n.into:
    b.openTree(tag, info)
    while n.hasMore:
      tr(n, b)
    b.closeTree()

# ---------------------------------------------------------------- module IO

proc trModule(n: NifCursor): NifBuilder =
  mainFile = filePath(n.info)
  states.setLen(0)
  procs.setLen(0)
  var c = n
  while c.hasMore:
    collect(c)
    skip c
  c = n
  while c.hasMore:
    collectProcs(c)
    skip c
  var changed = true
  var rounds = 0
  while changed and rounds < 64:
    changed = false
    c = n
    while c.hasMore:
      collectDerived(c, changed, false)
      skip c
    inc rounds
  var roots = 0
  c = n
  while c.hasMore:
    inc roots
    skip c
  result = createTree()
  c = n
  if roots == 1 and c.kind == TagLit and c.tagText == "stmts":
    tr(c, result)
  else:
    result.withTree StmtsS, n.info:
      while c.hasMore:
        tr(c, result)

saveTree trModule(loadPluginInput())
