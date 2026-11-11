## Pre-sem module plugin (`{.rewriteModule("…").}`): rewrite the c DSL into
## yith runtime calls before Nimony's semantic pass.
##
## Coverage: `c.Tag.class:` chains, attr/css/prop, events, text, nested tags,
## `name {.state.}: T` -> `State[T]` with get/set rewriting, derived locals,
## reactive `if`/`elif`/`else`, reactive and keyed `for`, signal method
## mutations. The same file also serves as a template plugin for `ui:` blocks.

import plugins

{.feature: "assumeSync".}

var nextNode = 0
var gSignals: seq[string] = @[]
var gGlobalSignals: seq[string] = @[]
var gUiCtx = true

proc freshName(): string =
  result = "yithNode" & $nextNode
  inc nextNode

type BuilderBox = ref object
  b: NifBuilder

proc argsOf(n: NifCursor): NifCursor =
  ## Arguments of a regular `(call fn arg...)` node (unlike `callArgs`, which
  ## is for the template-plugin input wrapper).
  result = n
  if n.kind == TagLit and n.tagText == "call":
    result = firstChild(n)
    skip result

proc nameOf(n: NifCursor): string =
  case n.kind
  of Ident: result = identText(n)
  of Symbol: result = symText(n)
  else: result = ""

proc hasName(names: seq[string]; name: string): bool =
  var i = 0
  while i < names.len:
    if names[i] == name: return true
    inc i
  result = false

proc addName(names: var seq[string]; name: string) =
  if name.len > 0 and not hasName(names, name):
    names.add name

proc startsWith(s, prefix: string): bool =
  if s.len < prefix.len: return false
  var i = 0
  while i < prefix.len:
    if s[i] != prefix[i]: return false
    inc i
  result = true

proc baseName(s: string): string =
  var i = 0
  while i < s.len and s[i] != '.':
    inc i
  result = ""
  var j = 0
  while j < i:
    result.add s[j]
    inc j

proc isStateHead(name: string): bool =
  let b = baseName(name)
  result = b == "State" or b == "Signal" or b == "Computed" or b == "Cell" or
    b == "Resource" or b == "ArgResource"

proc isStateType(n: NifCursor): bool =
  result = false
  if n.kind == Symbol:
    result = isStateHead(symText(n))
  elif n.kind == TagLit:
    if n.tagText == "at" or n.exprKind == AtX:
      if isStateHead(nameOf(firstChild(n))):
        return true
    var c = n
    c.into:
      while c.hasMore:
        if isStateType(c): result = true
        skip c

type
  NamedItem = object
    name: string
    elem: NifCursor

var gItemByName: seq[NamedItem]

proc addItem(name: string; elem: NifCursor) =
  if name.len == 0:
    return
  var i = 0
  while i < gItemByName.len:
    if gItemByName[i].name == name:
      return
    inc i
  gItemByName.add NamedItem(name: name, elem: elem)

proc itemFor(name: string): int =
  result = -1
  var i = 0
  while i < gItemByName.len:
    if gItemByName[i].name == name:
      return i
    inc i

proc isAt(n: NifCursor): bool =
  result = n.kind == TagLit and (n.tagText == "at" or n.exprKind == AtX)

proc extractItemType(t: NifCursor; outT: var NifCursor): bool =
  ## `State[seq[T]]` (or Signal/Computed/Cell) -> yields the cursor at `T`.
  result = false
  if isAt(t) and isStateHead(nameOf(firstChild(t))):
    var vt = firstChild(t)
    skip vt
    if vt.hasMore and isAt(vt) and baseName(nameOf(firstChild(vt))) == "seq":
      var e = firstChild(vt)
      skip e
      if e.hasMore:
        outT = e
        result = true

proc hasStatePragma(p: NifCursor): bool =
  result = false
  if p.kind == TagLit and p.tagText == "pragmas":
    var c = p
    c.into:
      while c.hasMore:
        if (c.kind == Ident and identText(c) == "state") or
           (c.kind == Symbol and baseName(symText(c)) == "state"):
          result = true
        skip c

proc hasSignalPragma(p: NifCursor): bool =
  result = false
  if p.kind == TagLit and p.tagText == "pragmas":
    var c = p
    c.into:
      while c.hasMore:
        if (c.kind == Ident and identText(c) == "signal") or
           (c.kind == Symbol and baseName(symText(c)) == "signal"):
          result = true
        skip c

proc isPluginPragma(c: NifCursor): bool =
  result = false
  if c.kind == Ident:
    let s = identText(c)
    result = s == "state" or s == "signal"
  elif c.kind == Symbol:
    let s = baseName(symText(c))
    result = s == "state" or s == "signal"

proc collectItemLocals(n: NifCursor) =
  ## Explicitly typed or literal-initialised signal locals in one proc body.
  if n.kind != TagLit:
    return
  if n.stmtKind == ProcS:
    return
  if n.stmtKind == LetS or n.stmtKind == VarS:
    let loc = asLocal(n)
    if hasStatePragma(loc.pragmas) or hasSignalPragma(loc.pragmas):
      addAnnotationItem(nameOf(loc.name), loc.typ)
    else:
      var elem = loc.typ
      if extractItemType(loc.typ, elem):
        addItem(nameOf(loc.name), elem)
  var c = n
  c.into:
    while c.hasMore:
      collectItemLocals(c)
      skip c

proc makeSameLambda(info: LineInfo; elem: NifCursor): NifBuilder =
  result = createTree()
  result.withTree ProcS, info:
    result.addEmptyNode()
    result.addEmptyNode()
    result.addEmptyNode()
    result.addEmptyNode()
    result.withTree ParamsU, info:
      result.withTree ParamU, info:
        result.addIdent "yithA"
        result.addEmptyNode()
        result.addEmptyNode()
        var ea = elem
        result.takeTree ea
        result.addEmptyNode()
      result.withTree ParamU, info:
        result.addIdent "yithB"
        result.addEmptyNode()
        result.addEmptyNode()
        var eb = elem
        result.takeTree eb
        result.addEmptyNode()
    result.addIdent "bool"
    result.withTree PragmasU, info:
      result.addIdent "closure"
    result.addEmptyNode()
    result.withTree StmtsS, info:
      result.withTree RetS, info:
        result.withTree InfixX, info:
          result.addIdent "=="
          result.addIdent "yithA"
          result.addIdent "yithB"

proc makeItemLambda(info: LineInfo; pname, retType: string;
                    elem: NifCursor; body: sink NifBuilder): NifBuilder =
  result = createTree()
  result.withTree ProcS, info:
    result.addEmptyNode()
    result.addEmptyNode()
    result.addEmptyNode()
    result.addEmptyNode()
    result.withTree ParamsU, info:
      result.withTree ParamU, info:
        result.addIdent pname
        result.addEmptyNode()
        result.addEmptyNode()
        var e = elem
        result.takeTree e
        result.addEmptyNode()
    result.addIdent retType
    result.withTree PragmasU, info:
      result.addIdent "closure"
    result.addEmptyNode()
    result.addTree body

proc isSignalCtor(n: NifCursor): bool =
  if n.kind != TagLit or n.tagText != "call": return false
  let head = nameOf(firstChild(n))
  result = head == "state" or head == "signal" or head == "cell" or
    head == "computed" or head == "computedExpr" or head == "resource" or
    head == "resourceAsync"

proc addStateType(t: NifCursor; b: var NifBuilder) =
  ## `T` -> `State[T]`; an explicit `State[T]` is kept.
  if isAt(t) and baseName(nameOf(firstChild(t))) == "State":
    var tt = t
    b.takeTree tt
  else:
    b.openTree(TagId(AtX), t.info)
    b.addIdent "State"
    var tt = t
    b.takeTree tt
    b.closeTree()

proc addCleanPragmas(p: NifCursor; b: var NifBuilder) =
  ## Emits the pragma list with `state` removed, or the empty node.
  if p.kind == TagLit and p.tagText == "pragmas":
    var tmp = createTree()
    var wrote = false
    tmp.openTree(TagId(PragmasU), p.info)
    var c = p
    c.into:
      while c.hasMore:
        if isPluginPragma(c):
          skip c
        else:
          takeTree tmp, c
          wrote = true
    tmp.closeTree()
    if wrote:
      var r = beginRead(tmp)
      b.takeTree r
      endRead r
    else:
      b.addEmptyNode()
  else:
    var pp = p
    takeTree b, pp

proc addAnnotationItem(name: string; t: NifCursor) =
  ## `{.state.}: seq[T]` -> keyed-list item type `T`.
  if isAt(t) and baseName(nameOf(firstChild(t))) == "seq":
    var e = firstChild(t)
    skip e
    if e.hasMore:
      addItem(name, e)

proc transformParam(n: NifCursor; b: var NifBuilder) =
  let loc = asLocal(n)
  if hasStatePragma(loc.pragmas):
    let name = nameOf(loc.name)
    addName(gSignals, name)
    addAnnotationItem(name, loc.typ)
    b.openTree(TagId(ParamU), n.info)
    b.addIdent name
    var ex = loc.exported
    takeTree b, ex
    addCleanPragmas(loc.pragmas, b)
    addStateType(loc.typ, b)
    var dv = loc.val
    takeTree b, dv
    b.closeTree()
  else:
    var c = n
    b.takeTree c

proc transformParams(n: NifCursor; b: var NifBuilder) =
  b.openTree(TagId(ParamsU), n.info)
  var c = n
  c.into:
    while c.hasMore:
      transformParam(c, b)
      skip c
  b.closeTree()

proc collectSignals(n: NifCursor; names: var seq[string]; enterProcs: bool) =
  var c = n
  if c.kind == TagLit:
    if c.stmtKind == ProcS and not enterProcs:
      return
    if c.stmtKind == LetS or c.stmtKind == VarS:
      let loc = asLocal(c)
      if isStateType(loc.typ) or isSignalCtor(loc.val) or
         hasStatePragma(loc.pragmas) or hasSignalPragma(loc.pragmas):
        addName(names, nameOf(loc.name))
    c.into:
      while c.hasMore:
        collectSignals(c, names, enterProcs)
        skip c

proc containsSignal(n: NifCursor): bool =
  result = false
  if n.kind == Ident and hasName(gSignals, identText(n)):
    return true
  if n.kind == TagLit:
    if n.exprKind == DotX:
      let d = asDot(n)
      return containsSignal(d.obj)
    var c = n
    c.into:
      while c.hasMore:
        if containsSignal(c): result = true
        skip c

proc rewriteReads(n: NifCursor; b: var NifBuilder) =
  if n.kind == Ident and hasName(gSignals, identText(n)):
    b.withTree CallX, n.info:
      b.addIdent "get"
      b.addIdent identText(n)
  elif n.kind != TagLit:
    b.addSubtree(n)
  elif n.exprKind == DotX:
    let d = asDot(n)
    b.openTree(TagId(DotX), n.info)
    rewriteReads(d.obj, b)
    var f = d.field
    b.takeTree f
    b.closeTree()
  elif n.tagText == "call" and n.exprKind == CallX:
    # `s.get()`, `s.set(v)`, `s.update(f)`: keep the receiver as is; only the
    # arguments are read-rewritten.
    let callee = firstChild(n)
    var api = ""
    if callee.kind == TagLit and callee.exprKind == DotX:
      let d = asDot(callee)
      let m = nameOf(d.field)
      if m == "get" or m == "set" or m == "update" or m == "peek" or
         m == "stateValue":
        api = m
    if api.len > 0:
      let tag = n.tagId
      let info = n.info
      var c = n
      c.into:
        b.openTree(tag, info)
        if c.hasMore:
          takeTree b, c
        while c.hasMore:
          rewriteReads(c, b)
          skip c
        b.closeTree()
    else:
      let tag = n.tagId
      let info = n.info
      var c = n
      c.into:
        b.openTree(tag, info)
        while c.hasMore:
          rewriteReads(c, b)
          skip c
        b.closeTree()
  else:
    let tag = n.tagId
    let info = n.info
    var c = n
    c.into:
      b.openTree(tag, info)
      while c.hasMore:
        rewriteReads(c, b)
        skip c
      b.closeTree()

proc rewriteReadsTree(n: NifCursor): NifBuilder =
  result = createTree()
  rewriteReads(n, result)

proc collectChain(n: NifCursor; root: string; parts: var seq[string]): bool =
  if n.kind == Ident:
    return eqIdent(n, root)
  if n.exprKind == DotX:
    let d = asDot(n)
    if collectChain(d.obj, root, parts):
      parts.add nameOf(d.field)
      return true
  result = false

proc isUiCall(n: NifCursor): bool =
  result = false
  if n.kind == TagLit and n.tagText == "call":
    let head = nameOf(firstChild(n))
    if head == "Text" or head == "El" or head.len == 0:
      return
    result = head[0] >= 'A' and head[0] <= 'Z'

proc isCCall(n: NifCursor): bool =
  if n.kind != TagLit or n.tagText != "call":
    return false
  var parts: seq[string] = @[]
  result = collectChain(firstChild(n), "c", parts) and parts.len > 0

proc dashName(s: string): string =
  result = ""
  var i = 0
  while i < s.len:
    let ch = s[i]
    if ch == '_':
      if result.len > 0 and result[result.high] != '-':
        result.add '-'
    elif ch >= 'A' and ch <= 'Z':
      if result.len > 0 and result[result.high] != '-':
        result.add '-'
      result.add char(ord(ch) - ord('A') + ord('a'))
    else:
      result.add ch
    inc i

proc makeLambda(info: LineInfo; pname, ptype: string;
                body: sink NifBuilder): NifBuilder =
  result = createTree()
  result.withTree ProcS, info:
    result.addEmptyNode()
    result.addEmptyNode()
    result.addEmptyNode()
    result.addEmptyNode()
    result.withTree ParamsU, info:
      if pname.len > 0:
        result.withTree ParamU, info:
          result.addIdent pname
          result.addEmptyNode()
          result.addEmptyNode()
          result.addIdent ptype
          result.addEmptyNode()
    result.addEmptyNode()
    result.withTree PragmasU, info:
      result.addIdent "closure"
    result.addEmptyNode()
    result.addTree body

proc textCall(n: NifCursor): NifBuilder =
  result = createTree()
  result.withTree CallX, n.info:
    result.addIdent "Text"
    if containsSignal(n):
      result.withTree CallX, n.info:
        result.addIdent "computedExpr"
        rewriteReads(n, result)
    else:
      result.addSubtree(n)

proc processCElement(n: NifCursor): NifBuilder

proc processOne(n: NifCursor; nodeSym: string; opsAllowed: bool;
                children: var NifBuilder; ops: BuilderBox) =
  if opsAllowed:
    if n.kind == TagLit and n.tagText == "call":
      let fn = firstChild(n)
      var parts: seq[string] = @[]
      if collectChain(fn, "attr", parts) and parts.len == 1:
        ops.b.withTree CallX, n.info:
          ops.b.addIdent "attr"
          ops.b.addIdent nodeSym
          ops.b.addStrLit parts[0]
          var a = argsOf(n)
          ops.b.takeTree a
        return
      elif collectChain(fn, "css", parts) and parts.len == 1:
        ops.b.withTree CallX, n.info:
          ops.b.addIdent "addStyle"
          ops.b.addIdent nodeSym
          ops.b.addStrLit dashName(parts[0])
          var a = argsOf(n)
          ops.b.takeTree a
        return
      elif collectChain(fn, "prop", parts) and parts.len == 1:
        ops.b.withTree CallX, n.info:
          ops.b.addIdent "setProp"
          ops.b.addIdent nodeSym
          ops.b.addStrLit parts[0]
          var a = argsOf(n)
          if a.hasMore:
            ops.b.takeTree a
          else:
            ops.b.addIdent "true"
        return

      let head = nameOf(fn)
      var eventBody = createTree()
      var pname = "yithArg"
      var hasBody = false
      var a = argsOf(n)
      while a.hasMore:
        if a.kind == TagLit and a.tagText == "stmts":
          eventBody.addSubtree(a)
          hasBody = true
        elif a.kind == Ident:
          pname = identText(a)
        skip a
      if hasBody:
        var eb = beginRead(eventBody)
        var tb = createTree()
        let savedCtx = gUiCtx
        gUiCtx = false
        transformNode(eb, tb)
        gUiCtx = savedCtx
        endRead eb
        eventBody = ensureMove tb
      if head == "onCleanup" and hasBody:
        let lam = makeLambda(n.info, "", "", eventBody)
        ops.b.withTree CallX, n.info:
          ops.b.addIdent "onCleanup"
          ops.b.addIdent nodeSym
          ops.b.addTree lam
        return
      elif (head == "onMount" or head == "onCreated") and hasBody:
        let lam = makeLambda(n.info, "yithElem", "E", eventBody)
        ops.b.withTree CallX, n.info:
          ops.b.addIdent "onCreated"
          ops.b.addIdent nodeSym
          ops.b.addTree lam
        return
      elif head.len > 2 and head[0] == 'o' and head[1] == 'n' and
           head[2] >= 'A' and head[2] <= 'Z' and hasBody:
        var eventName = ""
        var i = 2
        while i < head.len:
          let ch = head[i]
          eventName.add(if ch >= 'A' and ch <= 'Z':
            char(ord(ch) - ord('A') + ord('a')) else: ch)
          inc i
        let lam = makeLambda(n.info, pname, "Event", eventBody)
        ops.b.withTree CallX, n.info:
          ops.b.addIdent "on"
          ops.b.addIdent nodeSym
          ops.b.addStrLit eventName
          ops.b.addTree lam
        return

  if isCCall(n):
    children.addTree processCElement(n)
  elif n.kind == TagLit and (n.stmtKind == ForS or n.stmtKind == IfS or
                             n.stmtKind == WhileS or n.stmtKind == CaseS):
    var c = n
    transformNode(c, children)
  elif n.kind == TagLit and n.tagText == "call" and
       nameOf(firstChild(n)) == "Text":
    children.addTree textCall(argsOf(n))
  elif n.kind == TagLit and n.tagText == "call":
    children.addSubtree(n)
  else:
    children.addTree textCall(n)

proc bodyStmts(n: NifCursor; nodeSym: string; opsAllowed: bool;
               ops: BuilderBox): NifBuilder =
  result = createTree()
  result.withTree StmtsS, n.info:
    if n.kind == TagLit and n.tagText == "stmts":
      var child = firstChild(n)
      while child.hasMore:
        processOne(child, nodeSym, opsAllowed, result, ops)
        skip child
    else:
      processOne(n, nodeSym, opsAllowed, result, ops)

proc processCElement(n: NifCursor): NifBuilder =
  result = createTree()
  var parts: seq[string] = @[]
  discard collectChain(firstChild(n), "c", parts)
  var tag = "div"
  var classes = ""
  var pi = 0
  while pi < parts.len:
    let part = parts[pi]
    if part.len > 0 and part[0] >= 'A' and part[0] <= 'Z':
      tag = dashName(part)
    else:
      if classes.len > 0: classes.add ' '
      classes.add dashName(part)
    inc pi

  let args = argsOf(n)
  let nodeSym = freshName()
  let ops = BuilderBox(b: createTree())
  let children = bodyStmts(args, nodeSym, true, ops)

  result.withTree BlockS, n.info:
    result.addEmptyNode()
    result.withTree StmtsS, n.info:
      result.withTree LetS, n.info:
        result.addIdent nodeSym
        result.addEmptyNode()
        result.addEmptyNode()
        result.addEmptyNode()
        result.withTree CallX, n.info:
          result.addIdent "ElE"
          result.addStrLit tag
          result.addTree children
      if classes.len > 0:
        result.withTree CallX, n.info:
          result.addIdent "addClass"
          result.addIdent nodeSym
          result.addStrLit classes
      result.addTree ops.b
      result.withTree CallX, n.info:
        result.addIdent "finish"
        result.addIdent nodeSym


proc transformNode(n: var NifCursor; b: var NifBuilder)

proc isPlainText(n: NifCursor): bool =
  ## Branch bodies act like element bodies: a bare literal or read is a text
  ## child, everything statement-shaped is transformed normally.
  if n.kind != TagLit:
    return true
  let t = n.tagText
  result = t != "let" and t != "var" and t != "asgn" and t != "if" and
    t != "for" and t != "while" and t != "case" and t != "proc" and
    t != "block" and t != "stmts" and t != "infix" and t != "return" and
    t != "discard" and t != "call"

proc transformBody(n: NifCursor; info: LineInfo; uiCtx: bool): NifBuilder =
  let oldCtx = gUiCtx
  gUiCtx = uiCtx
  result = createTree()
  var c = n
  result.withTree StmtsS, info:
    if c.kind == TagLit and c.tagText == "stmts":
      var child = firstChild(c)
      while child.hasMore:
        if isPlainText(child):
          result.addTree textCall(child)
          skip child
        else:
          transformNode(child, result)
    else:
      transformNode(c, result)
  gUiCtx = oldCtx

proc transformIf(n: NifCursor; b: var NifBuilder) =
  ## Lower `if`/`elif`/`else` inside UI context to nested `uiIf(cond, then,
  ## else)` calls, so branches re-run when the condition's signals change.
  var elseBody = createTree()
  var hasElse = false
  var c = n
  c.into:
    while c.hasMore:
      if c.otherKind == ElseU:
        var e = c
        e.into:
          if e.hasMore:
            elseBody = transformBody(e, e.info, true)
            hasElse = true
          while e.hasMore:
            skip e
      skip c
  if not hasElse:
    elseBody.withTree StmtsS, n.info:
      discard
  var elifs: seq[NifCursor] = @[]
  c = n
  c.into:
    while c.hasMore:
      if c.otherKind == ElifU:
        elifs.add c
      skip c
  var nested = ensureMove elseBody
  var idx = elifs.len - 1
  while idx >= 0:
    var e = elifs[idx]
    var cond = e
    var body = e
    e.into:
      if e.hasMore:
        cond = e
        skip e
      if e.hasMore:
        body = e
        skip e
      while e.hasMore:
        skip e
    var cb = createTree()
    rewriteReads(cond, cb)
    let thenB = transformBody(body, body.info, true)
    var call = createTree()
    call.withTree CallX, n.info:
      call.addIdent "uiIf"
      call.addTree cb
      call.addTree thenB
      var nb = beginRead(nested)
      call.takeTree nb
      endRead nb
    nested = ensureMove call
    dec idx
  var outb = beginRead(nested)
  b.takeTree outb
  endRead outb

proc cleanProcPragmas(n: var NifCursor; b: var NifBuilder) =
  if n.kind == TagLit and n.otherKind == PragmasU:
    var tmp = createTree()
    var wrote = false
    tmp.openTree(TagId(PragmasU), n.info)
    n.into:
      while n.hasMore:
        if n.kind == Ident and eqIdent(n, "ui"):
          skip n
        else:
          takeTree tmp, n
          wrote = true
    tmp.closeTree()
    if wrote:
      var c = beginRead(tmp)
      b.takeTree c
      endRead c
    else:
      b.addDotToken()
  else:
    takeTree b, n

proc transformProc(n: NifCursor; b: var NifBuilder) =
  let oldSignals = gSignals
  gSignals = gGlobalSignals
  var headerSignals: seq[string] = @[]
  var bodyCursor = n
  var c = n
  c.into:
    if c.hasMore:
      let r = asRoutine(n)
      var p = r.params
      p.into:
        while p.hasMore:
          let loc = asLocal(p)
          if isStateType(loc.typ) or hasStatePragma(loc.pragmas):
            addName(headerSignals, nameOf(loc.name))
          skip p
    while c.hasMore:
      skip c
  for s in headerSignals:
    addName(gSignals, s)
  # find body cursor (index 8)
  var i = 0
  var scan = n
  scan.into:
    while scan.hasMore and i < 9:
      if i == 8:
        bodyCursor = scan
        skip scan
      else:
        skip scan
      inc i
  # collect local signals from body and append
  var locals: seq[string] = @[]
  collectSignals(bodyCursor, locals, true)
  for s in locals:
    addName(gSignals, s)
  # Item types for keyed lists: params first, then typed/literal locals.
  gItemByName.setLen(0)
  var pc = n
  pc.into:
    if pc.hasMore:
      let r = asRoutine(n)
      var pp = r.params
      pp.into:
        while pp.hasMore:
          let loc = asLocal(pp)
          if hasStatePragma(loc.pragmas):
            addAnnotationItem(nameOf(loc.name), loc.typ)
          else:
            var elem = loc.typ
            if extractItemType(loc.typ, elem):
              addItem(nameOf(loc.name), elem)
          skip pp
    while pc.hasMore:
      skip pc
  collectItemLocals(bodyCursor)

  i = 0
  b.openTree(TagId(ProcS), n.info)
  var procCursor = n
  procCursor.into:
    while procCursor.hasMore:
      if i == 4:
        transformParams(procCursor, b)
        skip procCursor
      elif i == 6:
        cleanProcPragmas(procCursor, b)
      elif i == 8:
        transformNode(procCursor, b)
      else:
        takeTree b, procCursor
      inc i
  b.closeTree()
  gSignals = oldSignals

proc transformNode(n: var NifCursor; b: var NifBuilder) =
  if n.kind != TagLit:
    b.addSubtree(n)
    skip n
  elif n.stmtKind == LetS or n.stmtKind == VarS:
    let loc = asLocal(n)
    if hasSignalPragma(loc.pragmas):
      # `let x {.signal.} = importedState`: already a State; only mark it.
      let name = nameOf(loc.name)
      b.openTree(TagId(if n.stmtKind == LetS: LetS else: VarS), n.info)
      b.addIdent name
      var ex = loc.exported
      takeTree b, ex
      addCleanPragmas(loc.pragmas, b)
      var ty = loc.typ
      takeTree b, ty
      var iv = loc.val
      rewriteReads(iv, b)
      b.closeTree()
      addName(gSignals, name)
      addAnnotationItem(name, loc.typ)
      skip n
    elif hasStatePragma(loc.pragmas):
      let name = nameOf(loc.name)
      b.openTree(TagId(if n.stmtKind == LetS: LetS else: VarS), n.info)
      b.addIdent name
      var ex = loc.exported
      takeTree b, ex
      addCleanPragmas(loc.pragmas, b)
      addStateType(loc.typ, b)
      if loc.val.kind != DotToken:
        b.withTree CallX, n.info:
          b.addIdent "state"
          rewriteReads(loc.val, b)
      else:
        b.addEmptyNode()
      b.closeTree()
      addName(gSignals, name)
      addAnnotationItem(name, loc.typ)
      skip n
    elif containsSignal(loc.val) and not isSignalCtor(loc.val) and
       not isCCall(loc.val) and not isUiCall(loc.val) and
       not isStateType(loc.typ):
      let name = nameOf(loc.name)
      b.openTree(TagId(if n.stmtKind == LetS: LetS else: VarS), n.info)
      b.addIdent name
      var c = n
      c.into:
        # name, export, pragmas, type
        if c.hasMore: skip c
        if c.hasMore: takeTree b, c
        if c.hasMore: takeTree b, c
        if c.hasMore: takeTree b, c
        if c.hasMore:
          b.withTree CallX, n.info:
            b.addIdent "computedExpr"
            rewriteReads(c, b)
          skip c
        while c.hasMore: skip c
      b.closeTree()
      addName(gSignals, name)
      skip n
    else:
      let tag = n.tagId
      let info = n.info
      n.into:
        b.openTree(tag, info)
        while n.hasMore:
          transformNode(n, b)
        b.closeTree()
  elif n.tagText == "infix":
    var op = firstChild(n)
    var lhs = op
    skip lhs
    if op.kind == Ident and lhs.kind == Ident and
       hasName(gSignals, identText(lhs)) and
       (identText(op) == "+=" or identText(op) == "-=" or identText(op) == "*=" or
        identText(op) == "/=" or identText(op) == "&="):
      let v = freshName()
      var rhs = lhs
      skip rhs
      b.withTree BlockS, n.info:
        b.addEmptyNode()
        b.withTree StmtsS, n.info:
          b.withTree VarS, n.info:
            b.addIdent v
            b.addEmptyNode()
            b.addEmptyNode()
            b.addEmptyNode()
            b.withTree CallX, n.info:
              b.addIdent "get"
              b.addIdent identText(lhs)
          b.withTree InfixX, n.info:
            b.addIdent identText(op)
            b.addIdent v
            rewriteReads(rhs, b)
          b.withTree CallX, n.info:
            b.addIdent "set"
            b.addIdent identText(lhs)
            b.addIdent v
      skip n
    else:
      let tag = n.tagId
      let info = n.info
      n.into:
        b.openTree(tag, info)
        while n.hasMore:
          transformNode(n, b)
        b.closeTree()
  elif gUiCtx and n.stmtKind == IfS:
    transformIf(n, b)
    skip n
  elif gUiCtx and n.stmtKind == ForS:
    var iterable = firstChild(n)
    if containsSignal(iterable):
      var vars = iterable
      skip vars
      var body = vars
      skip body
      # Optional `key expr` as the first statement: keyed list.
      var keyExpr = body
      var hasKey = false
      if body.kind == TagLit and body.tagText == "stmts":
        let firstStmt = firstChild(body)
        if firstStmt.kind == TagLit and
           (firstStmt.tagText == "call" or firstStmt.tagText == "cmd") and
           nameOf(firstChild(firstStmt)) == "key":
          var ka = firstChild(firstStmt)
          skip ka
          if ka.hasMore:
            keyExpr = ka
            hasKey = true
      if hasKey:
        # `forEachList(items, same, key, render)` with typed closures, exactly
        # like the macro path. The item type comes from the State declaration.
        var loopItem = nameOf(vars)
        if loopItem.len == 0:
          var vnode = vars
          if vnode.kind == TagLit and vnode.tagText == "unpackflat":
            vnode = firstChild(vnode)
          let loc = asLocal(vnode)
          if loc.name.kind == Ident:
            loopItem = identText(loc.name)
        let ii = itemFor(baseName(nameOf(iterable)))
        if ii >= 0 and loopItem.len > 0:
          let elem = gItemByName[ii].elem
          var kstmts = createTree()
          kstmts.withTree StmtsS, keyExpr.info:
            kstmts.withTree RetS, keyExpr.info:
              kstmts.withTree PrefixX, keyExpr.info:
                kstmts.addIdent "$"
                kstmts.addTree rewriteReadsTree(keyExpr)
          var keyLam: NifBuilder = makeItemLambda(keyExpr.info, loopItem, "string", elem, kstmts)
          var rl = createTree()
          rl.withTree StmtsS, body.info:
            var bc = body
            if bc.kind == TagLit and bc.tagText == "stmts":
              var child = firstChild(bc)
              if hasKey:
                skip child
              while child.hasMore:
                if isPlainText(child):
                  rl.addTree textCall(child)
                  skip child
                else:
                  transformNode(child, rl)
            else:
              transformNode(bc, rl)
          var renderLam: NifBuilder = makeItemLambda(body.info, loopItem, "E", elem, rl)
          b.withTree CallX, n.info:
            b.addIdent "forEachList"
            takeTree b, iterable
            b.addTree makeSameLambda(n.info, elem)
            b.addTree keyLam
            b.addTree renderLam
          skip n
        else:
          # Unknown item type: keep the reactive loop without key reuse.
          var lb = createTree()
          lb.withTree StmtsS, n.info:
            lb.withTree ForS, n.info:
              rewriteReads(iterable, lb)
              takeTree lb, vars
              let bb = transformBody(body, body.info, true)
              lb.addTree bb
          var lam = makeLambda(n.info, "", "", lb)
          b.withTree CallX, n.info:
            b.addIdent "uiLoop"
            b.addTree lam
          skip n
      else:
        var lb = createTree()
        lb.withTree StmtsS, n.info:
          lb.withTree ForS, n.info:
            rewriteReads(iterable, lb)
            takeTree lb, vars
            let bb = transformBody(body, body.info, true)
            lb.addTree bb
        var lam = makeLambda(n.info, "", "", lb)
        b.withTree CallX, n.info:
          b.addIdent "uiLoop"
          b.addTree lam
        skip n
    else:
      let tag = n.tagId
      let info = n.info
      n.into:
        b.openTree(tag, info)
        while n.hasMore:
          transformNode(n, b)
        b.closeTree()
  elif n.stmtKind == ProcS:
    transformProc(n, b)
    skip n
  elif n.stmtKind == AsgnS:
    var lhs = firstChild(n)
    if lhs.kind == Ident and hasName(gSignals, identText(lhs)):
      var rhs = lhs
      skip rhs
      b.withTree CallX, n.info:
        b.addIdent "set"
        b.addIdent identText(lhs)
        rewriteReads(rhs, b)
      skip n
    else:
      let tag = n.tagId
      let info = n.info
      n.into:
        b.openTree(tag, info)
        while n.hasMore:
          transformNode(n, b)
        b.closeTree()
  elif n.tagText == "call":
    let callee = firstChild(n)
    var sigName = ""
    var methodName = ""
    if callee.kind == TagLit and callee.exprKind == DotX:
      let d = asDot(callee)
      if d.obj.kind == Ident and hasName(gSignals, identText(d.obj)):
        let m = nameOf(d.field)
        if m.len > 0 and m != "get" and m != "set" and m != "update" and
           m != "peek" and m != "stateValue" and m != "value" and
           m != "sig" and m != "scope":
          sigName = identText(d.obj)
          methodName = m
    if sigName.len > 0:
      let v = freshName()
      var a = callee
      skip a
      b.withTree BlockS, n.info:
        b.addEmptyNode()
        b.withTree StmtsS, n.info:
          b.withTree VarS, n.info:
            b.addIdent v
            b.addEmptyNode()
            b.addEmptyNode()
            b.addEmptyNode()
            b.withTree CallX, n.info:
              b.addIdent "get"
              b.addIdent sigName
          b.withTree CallX, n.info:
            b.withTree DotX, n.info:
              b.addIdent v
              b.addIdent methodName
            while a.hasMore:
              rewriteReads(a, b)
              skip a
          b.withTree CallX, n.info:
            b.addIdent "set"
            b.addIdent sigName
            b.addIdent v
      skip n
    elif isCCall(n):
      b.addTree processCElement(n)
      skip n
    else:
      let tag = n.tagId
      let info = n.info
      n.into:
        b.openTree(tag, info)
        while n.hasMore:
          transformNode(n, b)
        b.closeTree()
  elif isCCall(n):
    b.addTree processCElement(n)
    skip n
  else:
    let tag = n.tagId
    let info = n.info
    into n:
      b.openTree(tag, info)
      while n.hasMore:
        transformNode(n, b)
      b.closeTree()

proc trTemplate(n: NifCursor): NifBuilder =
  var root = n
  collectSignals(root, gGlobalSignals, false)
  gSignals = gGlobalSignals
  result = createTree()
  var args = callArgs(n)
  var bodyBlock = args
  result.withTree StmtsS, n.info:
    if bodyBlock.kind == TagLit and bodyBlock.tagText == "stmts":
      var child = firstChild(bodyBlock)
      while child.hasMore:
        transformNode(child, result)
    else:
      transformNode(bodyBlock, result)

proc trModule(n: NifCursor): NifBuilder =
  collectSignals(n, gGlobalSignals, false)
  gSignals = gGlobalSignals
  result = createTree()
  var bodyBlock = n
  result.withTree StmtsS, n.info:
    if bodyBlock.kind == TagLit and bodyBlock.tagText == "stmts":
      var child = firstChild(bodyBlock)
      while child.hasMore:
        transformNode(child, result)
    else:
      transformNode(bodyBlock, result)

var input = loadPluginInput()
# Template-plugin input starts with the template name (`ui`); module-plugin
# input starts with a pragma/proc/import. Dispatch on that shape.
var first = firstChild(input)
if first.kind == Ident and eqIdent(first, "ui"):
  saveTree trTemplate(input)
else:
  saveTree trModule(input)
