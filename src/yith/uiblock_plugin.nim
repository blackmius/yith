## Pass 1 of 2: the `{.ui.}` syntax plugin.
##
## `yith/uiblock` declares:
##
##   template ui*(def: untyped) {.plugin: "uiblock_plugin".}
##
## so `proc View(): E {.ui.} = ...` and `ui: ...` both invoke this plugin with
## the untyped definition/block. The output is ordinary Nimony source calls:
##
##   c.Div.card:
##     attr.id("root")
##     "hello"
##
## becomes
##
##   uiBlock("div",
##     proc (yithE: E) {.closure.} =
##       addClass(yithE, "card")
##       attr(yithE, "id", "root"),
##     proc () {.closure.} =
##       Text("hello"))
##
## Reactive `if`/`for` become `uiWhen`/`uiLoop`; keyed `for` keeps a `uiKey`
## marker for pass 2; `case user:` over a resource becomes `uiCaseBlock`.
##
## This pass deliberately knows nothing about `{.state.}`. A state variable is
## still a plain value here, so the module type-checks; pass 2
## (`state_plugin.nim`) rewrites the state declarations and uses post-sem.
##
## Every transformed routine/block also emits
##
##   var yithHook…: PluginHook
##
## `PluginHook` is a nominal type carrying the state-plugin annotation, so
## importing `yith/ui` and writing `{.ui.}` installs both passes. The second
## post-sem pass is what lets plain `name = value` / `name` in a component body
## become `set`/`get`.

import plugins

{.feature: "assumeSync".}

var nextNode = 0
var gStmtCtx = true

proc freshName(): string =
  result = "yithNode" & $nextNode
  inc nextNode

# ------------------------------------------------------------------ text utils

proc nameOf(n: NifCursor): string =
  if n.kind == Symbol or n.kind == SymbolDef:
    result = symText(n)
  elif n.kind == Ident:
    result = identText(n)
  else:
    result = ""

proc baseName(s: string): string =
  result = ""
  var i = 0
  while i < s.len and s[i] != '.':
    result.add s[i]
    inc i

proc startsWith(s, prefix: string): bool =
  if s.len < prefix.len: return false
  var i = 0
  while i < prefix.len:
    if s[i] != prefix[i]: return false
    inc i
  result = true

proc isUpper(c: char): bool =
  result = c >= 'A' and c <= 'Z'

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

proc attrName(s: string): string =
  ## `data_id` -> `data-id`, `aria_label` -> `aria-label`, `type_` -> `type`.
  result = s
  if s.len > 1 and s[s.high] == '_':
    var stripped = ""
    var i = 0
    while i < s.high:
      stripped.add s[i]
      inc i
    if stripped == "type" or stripped == "for" or stripped == "method" or
       stripped == "defer" or stripped == "block":
      return stripped
  if startsWith(s, "data_") or startsWith(s, "aria_"):
    result = ""
    var i = 0
    while i < s.len:
      if s[i] == '_': result.add '-'
      else: result.add s[i]
      inc i

# ------------------------------------------------------------------ tree utils

proc firstArg(n: NifCursor): NifCursor =
  result = firstChild(n)
  skip result

proc collectChain(n: NifCursor; root: string; parts: var seq[string]): bool

proc isCCall(n: NifCursor): bool =
  if n.kind != TagLit or (n.tagText != "call" and n.tagText != "cmd"):
    return false
  var parts: seq[string] = @[]
  result = collectChain(firstChild(n), "c", parts) and parts.len > 0

proc collectChain(n: NifCursor; root: string; parts: var seq[string]): bool =
  if n.kind == Ident:
    return identText(n) == root
  if n.exprKind == DotX:
    let d = asDot(n)
    if collectChain(d.obj, root, parts):
      parts.add nameOf(d.field)
      return true
  result = false

proc collectOpChain(n: NifCursor; root: string; names: var seq[string];
                    args: var seq[NifCursor]): bool =
  ## Flatten `attr.x.y(0)` / `css.a("x").b("y")` into names + arg cursors.
  if n.kind == Ident:
    return identText(n) == root
  if n.exprKind == DotX:
    let d = asDot(n)
    if collectOpChain(d.obj, root, names, args):
      names.add nameOf(d.field)
      args.add default(NifCursor)
      return true
  elif n.tagText == "call":
    var fn = firstChild(n)
    if collectOpChain(fn, root, names, args) and names.len > 0:
      var a = firstChild(n)
      skip a
      args[args.high] = a
      return true
  result = false

proc isComponentCall(n: NifCursor): bool =
  result = false
  if n.kind == TagLit and n.tagText == "call":
    let head = nameOf(firstChild(n))
    if head.len > 0 and isUpper(head[0]):
      var a = firstArg(n)
      while a.hasMore:
        if a.kind == TagLit and a.tagText == "stmts":
          result = true
        skip a

proc isStatementCallHead(h: string): bool =
  result = h == "echo" or h == "write" or h == "set" or h == "update" or
    h == "add" or h == "push" or h == "pop" or h == "insert" or
    h == "delete" or h == "remove" or h == "clear" or h == "inc" or
    h == "dec" or h == "refetch" or h == "mutate" or h == "discard" or
    h == "onCleanup" or h == "onCreated" or h == "onMount" or
    h == "onUnmount" or h == "onDestroy" or h == "attr" or h == "setAttr" or
    h == "boolAttr" or h == "setBoolAttr" or h == "addStyle" or
    h == "setProp" or h == "addClass" or h == "on" or h == "uiBlock" or
    h == "uiFragment" or h == "fragment" or h == "uiWhen" or
    h == "uiLoop" or h == "uiIf" or h == "uiCaseBlock" or h == "ElE"

proc isValueCallHead(h: string): bool =
  result = h == "get" or h == "peek" or h == "stateValue" or h == "len" or
    h == "computedExpr" or h == "computed" or h == "newState" or
    h == "state" or h == "default"

proc isPlainText(n: NifCursor): bool =
  if n.kind != TagLit:
    return true
  let t = n.tagText
  if t == "call":
    if isCCall(n) or isComponentCall(n):
      return false
    let fn = firstChild(n)
    var head = ""
    if fn.kind == Ident or fn.kind == Symbol:
      head = baseName(nameOf(fn))
    elif fn.kind == TagLit and fn.tagText == "dot":
      let d = asDot(fn)
      head = nameOf(d.field)
    if head.len > 0 and isUpper(head[0]):
      return false
    if head == "Text":
      return false
    if isStatementCallHead(head):
      return false
    if isValueCallHead(head):
      return true
    if fn.kind == TagLit and fn.tagText == "dot":
      return true
    # An unknown zero-argument call is a component/slot/children invocation
    # inserted as a statement; an unknown call with arguments is an expression.
    var a = firstArg(n)
    if not a.hasMore:
      return false
    return true
  result = t != "let" and t != "var" and t != "asgn" and t != "if" and
    t != "for" and t != "while" and t != "case" and t != "proc" and
    t != "func" and t != "block" and t != "stmts" and t != "infix" and
    t != "return" and t != "discard" and t != "call" and t != "cmd" and
    t != "elif" and t != "else" and t != "of" and t != "type"

# ------------------------------------------------------------------- builders

proc makeTypedLambda(info: LineInfo; pname, ptype, retType: string;
                     body: sink NifBuilder): NifBuilder =
  var b = ensureMove(body)
  result = createTree()
  result.withTree ProcS, info:
    result.addEmptyNode4(info)
    result.withTree ParamsU, info:
      if pname.len > 0:
        result.withTree ParamU, info:
          result.addIdent pname
          result.addEmptyNode2(info)
          result.addIdent ptype
          result.addEmptyNode()
    if retType.len > 0:
      result.addIdent retType
    else:
      result.addEmptyNode()
    result.withTree PragmasU, info:
      result.addIdent "closure"
    result.addEmptyNode()
    result.withTree StmtsS, info:
      result.addTree b
      result.withTree DiscardS, info:
        result.addEmptyNode()

proc makeLambda(info: LineInfo; pname, ptype: string;
                body: sink NifBuilder): NifBuilder =
  result = makeTypedLambda(info, pname, ptype, "", body)

proc emptyStmts(info: LineInfo): NifBuilder =
  result = createTree()
  result.withTree StmtsS, info:
    discard

proc addTextChild(n: var NifCursor; b: var NifBuilder) =
  b.withTree CallX, n.info:
    b.addIdent "Text"
    b.takeTree n

proc addConcatItemAux(n: var NifCursor; b: var NifBuilder) =
  if n.kind == StrLit:
    b.takeTree n
  else:
    b.withTree PrefixX, n.info:
      b.addIdent "$"
      b.takeTree n

proc addConcat(args: NifCursor; b: var NifBuilder) =
  ## `10, "px"` -> `$10 & "px"`, left associative.
  var a = args
  var acc = createTree()
  var have = false
  while a.hasMore:
    var item = createTree()
    addConcatItemAux(a, item)
    if not have:
      acc = ensureMove item
      have = true
    else:
      var nxt = createTree()
      nxt.withTree InfixX, a.info:
        nxt.addIdent "&"
        var lb = snapshot(acc)
        nxt.takeTree lb
        nxt.addTree item
      acc = ensureMove nxt
  if have:
    b.addTree acc

# ------------------------------------------------------------------- lowering

proc transformNode(n: var NifCursor; b: var NifBuilder; uiCtx: bool)
proc transformComponent(n: var NifCursor; b: var NifBuilder; uiCtx: bool)

proc transformBody(n: NifCursor; info: LineInfo; uiCtx: bool): NifBuilder =
  let oldStmt = gStmtCtx
  gStmtCtx = uiCtx
  result = createTree()
  result.withTree StmtsS, info:
    var c = n
    if c.kind == TagLit and c.tagText == "stmts":
      var child = firstChild(c)
      while child.hasMore:
        if uiCtx and isPlainText(child):
          addTextChild(child, result)
        else:
          transformNode(child, result, uiCtx)
    else:
      if uiCtx and isPlainText(c):
        addTextChild(c, result)
      else:
        transformNode(c, result, uiCtx)
  gStmtCtx = oldStmt

proc transformIf(n: var NifCursor; b: var NifBuilder) =
  ## `if/elif/else` -> nested `uiWhen(condProc, thenProc, elseProc)`.
  let info = n.info
  var elseBody = emptyStmts(info)
  var c = n
  c.into:
    while c.hasMore:
      if c.otherKind == ElseU:
        var e = c
        e.into:
          if e.hasMore:
            elseBody = transformBody(e, e.info, true)
          while e.hasMore:
            skip e
      skip c
  var elifs: seq[NifCursor] = @[]
  c = n
  c.into:
    while c.hasMore:
      if c.otherKind == ElifU:
        elifs.add c
      skip c

  var elseProc = makeTypedLambda(info, "", "", "", elseBody)
  var outCall = createTree()
  var idx = elifs.len - 1
  while idx >= 0:
    var e = elifs[idx]
    var cond = e
    var branchBody = e
    e.into:
      if e.hasMore:
        cond = e
        skip e
      if e.hasMore:
        branchBody = e
        skip e
      while e.hasMore:
        skip e
    var condBody = createTree()
    condBody.withTree StmtsS, cond.info:
      condBody.withTree RetS, cond.info:
        var cc = cond
        condBody.takeTree cc
    let condProc = makeTypedLambda(cond.info, "", "", "bool", condBody)
    let thenBody = transformBody(branchBody, branchBody.info, true)
    let thenProc = makeLambda(branchBody.info, "", "", thenBody)
    var call = createTree()
    call.withTree CallX, info:
      call.addIdent "uiWhen"
      call.addTree condProc
      call.addTree thenProc
      var ep = snapshot(elseProc)
      call.takeTree ep
    if idx == 0:
      outCall = ensureMove call
    else:
      var eb = createTree()
      eb.withTree StmtsS, info:
        eb.addTree call
      elseProc = makeTypedLambda(info, "", "", "", eb)
    dec idx
  b.addTree outCall
  skip n

proc transformFor(n: var NifCursor; b: var NifBuilder) =
  ## `for x in xs:` -> `uiLoop(proc () = (for x in xs: ...))`. A leading
  ## `key expr` becomes a `uiKey(expr)` marker that pass 2 turns into a keyed
  ## `forEachList`.
  let info = n.info
  var iterable = firstChild(n)
  var vars = iterable
  skip vars
  var body = vars
  skip body

  var hasKey = false
  var keyExpr = body
  if body.kind == TagLit and body.tagText == "stmts":
    let firstStmt = firstChild(body)
    if firstStmt.kind == TagLit and
       (firstStmt.tagText == "call" or firstStmt.tagText == "cmd") and
       nameOf(firstChild(firstStmt)) == "key":
      keyExpr = firstArg(firstStmt)
      hasKey = keyExpr.hasMore

  var loopBody = createTree()
  loopBody.withTree StmtsS, info:
    loopBody.withTree ForS, info:
      var it = iterable
      loopBody.takeTree it
      var vs = vars
      loopBody.takeTree vs
      loopBody.withTree StmtsS, body.info:
        let oldStmt = gStmtCtx
        gStmtCtx = true
        if hasKey:
          loopBody.withTree CallX, keyExpr.info:
            loopBody.addIdent "uiKey"
            var ke = keyExpr
            loopBody.takeTree ke
        if body.kind == TagLit and body.tagText == "stmts":
          var child = firstChild(body)
          if hasKey:
            skip child
          while child.hasMore:
            if isPlainText(child):
              addTextChild(child, loopBody)
            else:
              transformNode(child, loopBody, true)
        else:
          if isPlainText(body):
            addTextChild(body, loopBody)
          else:
            transformNode(body, loopBody, true)
        gStmtCtx = oldStmt
  let lam = makeLambda(info, "", "", loopBody)
  b.withTree CallX, info:
    b.addIdent "uiLoop"
    b.addTree lam
  skip n

proc isResourceCase(n: NifCursor): bool =
  result = false
  if n.kind != TagLit or n.stmtKind != CaseS:
    return
  var c = n
  c.into:
    if c.hasMore:
      skip c # selector
    while c.hasMore:
      if c.otherKind == OfU:
        var o = c
        o.into:
          if o.hasMore:
            var pat = o
            if pat.tagText == "ranges":
              pat = firstChild(pat)
            if pat.kind == Ident and
               (identText(pat) == "Loading" or identText(pat) == "Ready" or
                identText(pat) == "Error"):
              result = true
            elif pat.kind == TagLit and pat.tagText == "call" and
                 nameOf(firstChild(pat)) == "Ready":
              result = true
          while o.hasMore: skip o
      skip c

proc transformCase(n: var NifCursor; b: var NifBuilder) =
  ## `case user:` over a resource -> a re-runnable `uiCaseBlock` that switches
  ## on `user.value.get().kind`.
  let info = n.info
  let resSym = freshName()
  var subject = firstChild(n)

  var stmts = createTree()
  stmts.withTree StmtsS, info:
    stmts.withTree LetS, info:
      stmts.addIdent resSym
      stmts.addEmptyNode3(info)
      stmts.withTree CallX, info:
        stmts.addIdent "get"
        stmts.withTree DotX, info:
          var s = subject
          stmts.takeTree s
          stmts.addIdent "value"
    stmts.withTree CaseS, info:
      stmts.withTree DotX, info:
        stmts.addIdent resSym
        stmts.addIdent "kind"
      var c = n
      c.into:
        skip c # selector
        while c.hasMore:
          if c.otherKind == OfU:
            var o = c
            var ofB = createTree()
            var bodyB = createTree()
            var kindName = ""
            var payload = ""
            o.into:
              if o.hasMore:
                var pat = o
                if pat.tagText == "ranges":
                  pat = firstChild(pat)
                  if pat.kind == Ident:
                    if identText(pat) == "Loading": kindName = "resLoading"
                    elif identText(pat) == "Ready": kindName = "resReady"
                    elif identText(pat) == "Error": kindName = "resError"
                  elif pat.tagText == "call":
                    let h = nameOf(firstChild(pat))
                    if h == "Ready" or h == "Error":
                      kindName = if h == "Ready": "resReady" else: "resError"
                      var pa = firstArg(pat)
                      if pa.kind == Ident: payload = identText(pa)
                skip o
              if o.hasMore:
                var body = o
                bodyB.withTree StmtsS, body.info:
                  if payload.len > 0:
                    bodyB.withTree LetS, body.info:
                      bodyB.addIdent payload
                      bodyB.addEmptyNode3(info)
                      bodyB.withTree DotX, body.info:
                        var subj = subject
                        bodyB.takeTree subj
                        if kindName == "resReady":
                          bodyB.addIdent "data"
                        else:
                          bodyB.addIdent "error"
                  let oldStmt = gStmtCtx
                  gStmtCtx = true
                  if body.kind == TagLit and body.tagText == "stmts":
                    var child = firstChild(body)
                    while child.hasMore:
                      if isPlainText(child):
                        addTextChild(child, bodyB)
                      else:
                        transformNode(child, bodyB, true)
                  else:
                    transformNode(body, bodyB, true)
                  gStmtCtx = oldStmt
                skip o
              while o.hasMore:
                skip o
            if kindName.len == 0:
              # not a resource pattern; copy the branch shape
              var ob = createTree()
              var oc = c
              ob.takeTree oc
              stmts.addTree ob
            else:
              ofB.withTree OfU, c.info:
                ofB.withTree RangesU, c.info:
                  ofB.addIdent kindName
                ofB.addTree bodyB
              stmts.addTree ofB
            skip c
          elif c.otherKind == ElseU:
            var e = c
            e.into:
              if e.hasMore:
                var body = e
                stmts.withTree ElseU, body.info:
                  let oldStmt = gStmtCtx
                  gStmtCtx = true
                  if body.kind == TagLit and body.tagText == "stmts":
                    var child = firstChild(body)
                    while child.hasMore:
                      if isPlainText(child):
                        addTextChild(child, stmts)
                      else:
                        transformNode(child, stmts, true)
                  else:
                    transformNode(body, stmts, true)
                  gStmtCtx = oldStmt
                skip e
              while e.hasMore:
                skip e
            skip c
          else:
            skip c
  b.withTree CallX, info:
    b.addIdent "uiCaseBlock"
    b.addTree stmts
  skip n

# ------------------------------------------------------------------ c syntax

proc processCElement(n: var NifCursor; b: var NifBuilder)

proc emitAttrChain(item: var NifCursor; eName: string; root: string;
                   attrs: var NifBuilder): bool =
  ## Handles `attr.x(v)`, `css.x(v)`, `prop.x(v)`, `cls.x(v)` and chains.
  var fn = firstChild(item)
  var names: seq[string] = @[]
  var args: seq[NifCursor] = @[]
  var tmp = item
  if not collectOpChain(tmp, root, names, args):
    return false
  result = true
  var i = 0
  while i < names.len:
    let nm = names[i]
    let a = args[i]
    if root == "attr":
      let an = attrName(nm)
      var count = 0
      var ac = a
      while ac.hasMore:
        inc count
        skip ac
      if count == 0:
        attrs.withTree CallX, item.info:
          attrs.addIdent "attr"
          attrs.addIdent eName
          attrs.addStrLit an
          attrs.addIdent "true"
      elif count == 1:
        attrs.withTree CallX, item.info:
          attrs.addIdent "attr"
          attrs.addIdent eName
          attrs.addStrLit an
          var av = a
          attrs.takeTree av
      else:
        attrs.withTree CallX, item.info:
          attrs.addIdent "attr"
          attrs.addIdent eName
          attrs.addStrLit an
          addConcat(a, attrs)
    elif root == "css":
      let cn = dashName(nm)
      var count = 0
      var ac = a
      while ac.hasMore:
        inc count
        skip ac
      if count == 1:
        attrs.withTree CallX, item.info:
          attrs.addIdent "addStyle"
          attrs.addIdent eName
          attrs.addStrLit cn
          var av = a
          attrs.takeTree av
      elif count > 1:
        attrs.withTree CallX, item.info:
          attrs.addIdent "addStyle"
          attrs.addIdent eName
          attrs.addStrLit cn
          addConcat(a, attrs)
    elif root == "prop":
      var count = 0
      var ac = a
      while ac.hasMore:
        inc count
        skip ac
      if count == 0:
        attrs.withTree CallX, item.info:
          attrs.addIdent "setProp"
          attrs.addIdent eName
          attrs.addStrLit nm
          attrs.addIdent "true"
      elif count == 1:
        attrs.withTree CallX, item.info:
          attrs.addIdent "setProp"
          attrs.addIdent eName
          attrs.addStrLit nm
          var av = a
          attrs.takeTree av
    elif root == "cls":
      var count = 0
      var ac = a
      while ac.hasMore:
        inc count
        skip ac
      if count == 0:
        attrs.withTree CallX, item.info:
          attrs.addIdent "addClass"
          attrs.addIdent eName
          attrs.addStrLit dashName(nm)
      elif count == 1:
        attrs.withTree CallX, item.info:
          attrs.addIdent "addClass"
          attrs.addIdent eName
          attrs.addStrLit dashName(nm)
          var av = a
          attrs.takeTree av
    inc i

proc emitDynamicClass(item: var NifCursor; eName: string;
                      attrs: var NifBuilder) =
  ## `cls(value)` — one positional dynamic class string.
  var a = firstArg(item)
  if a.hasMore:
    attrs.withTree CallX, item.info:
      attrs.addIdent "addClass"
      attrs.addIdent eName
      var v = a
      attrs.takeTree v

proc emitEvents(item: var NifCursor; eName: string;
                attrs: var NifBuilder): bool =
  ## `onClick(e):`, `onMount(e):`, `onCleanup():`.
  result = false
  var fn = firstChild(item)
  var head = ""
  if fn.kind == Ident:
    head = identText(fn)
  elif fn.kind == Symbol:
    head = baseName(symText(fn))
  if head.len == 0:
    return
  var a = firstArg(item)
  var pname = "yithArg"
  var body = createTree()
  var hasBody = false
  while a.hasMore:
    if a.kind == TagLit and a.tagText == "stmts":
      body = transformBody(a, a.info, false)
      hasBody = true
    elif a.kind == Ident:
      pname = identText(a)
    skip a
  if not hasBody:
    return
  if head == "onCleanup" or head == "onUnmount" or head == "onDestroy":
    let lam = makeLambda(item.info, "", "", body)
    attrs.withTree CallX, item.info:
      attrs.addIdent "onCleanup"
      attrs.addIdent eName
      attrs.addTree lam
    return true
  if head == "onMount" or head == "onCreated":
    let lam = makeLambda(item.info, pname, "E", body)
    attrs.withTree CallX, item.info:
      attrs.addIdent "onCreated"
      attrs.addIdent eName
      attrs.addTree lam
    return true
  if head.len > 2 and head[0] == 'o' and head[1] == 'n' and isUpper(head[2]):
    var eventName = ""
    var i = 2
    while i < head.len:
      let ch = head[i]
      if isUpper(ch):
        eventName.add char(ord(ch) - ord('A') + ord('a'))
      else:
        eventName.add ch
      inc i
    let lam = makeLambda(item.info, pname, "Event", body)
    attrs.withTree CallX, item.info:
      attrs.addIdent "on"
      attrs.addIdent eName
      attrs.addStrLit eventName
      attrs.addTree lam
    return true

proc emitOnChain(item: var NifCursor; eName: string;
                 attrs: var NifBuilder): bool =
  ## `on.click(handler)`.
  var fn = firstChild(item)
  var names: seq[string] = @[]
  var args: seq[NifCursor] = @[]
  var tmp = item
  if not collectOpChain(tmp, "on", names, args):
    return false
  result = true
  var i = 0
  while i < names.len:
    let a = args[i]
    if a.hasMore:
      var h = a
      attrs.withTree CallX, item.info:
        attrs.addIdent "on"
        attrs.addIdent eName
        attrs.addStrLit names[i]
        attrs.takeTree h
    inc i

proc processElementItem(item: var NifCursor; eName: string;
                        attrs, children: var NifBuilder; uiCtx: bool) =
  if item.kind == TagLit and (item.tagText == "call" or item.tagText == "cmd"):
    let fn = firstChild(item)
    if fn.kind == Ident and identText(fn) == "cls":
      emitDynamicClass(item, eName, attrs)
      skip item
      return
    if emitOnChain(item, eName, attrs):
      skip item
      return
    if emitAttrChain(item, eName, "attr", attrs):
      skip item
      return
    if emitAttrChain(item, eName, "css", attrs):
      skip item
      return
    if emitAttrChain(item, eName, "prop", attrs):
      skip item
      return
    if emitAttrChain(item, eName, "cls", attrs):
      skip item
      return
    if emitEvents(item, eName, attrs):
      skip item
      return
    if isCCall(item):
      var tmp = item
      processCElement(tmp, children)
      skip item
      return
    if isComponentCall(item):
      var tmp = item
      transformComponent(tmp, children, uiCtx)
      skip item
      return
    if nameOf(firstChild(item)) == "Text":
      children.addSubtree(item)
      skip item
      return
    if isPlainText(item):
      addTextChild(item, children)
      skip item
      return
    # A mutating/statement call in child position.
    transformNode(item, children, uiCtx)
    return
  if item.kind == TagLit and (item.stmtKind == IfS or item.stmtKind == ForS or
                              item.stmtKind == WhileS or item.stmtKind == CaseS):
    transformNode(item, children, uiCtx)
    return
  if isPlainText(item):
    addTextChild(item, children)
  else:
    transformNode(item, children, uiCtx)

proc processCElement(n: var NifCursor; b: var NifBuilder) =
  let info = n.info
  var parts: seq[string] = @[]
  discard collectChain(firstChild(n), "c", parts)
  var tag = "div"
  var classes = ""
  var pi = 0
  while pi < parts.len:
    let part = parts[pi]
    if part.len > 0 and isUpper(part[0]):
      tag = dashName(part)
    else:
      if classes.len > 0: classes.add ' '
      classes.add dashName(part)
    inc pi

  let eName = freshName()
  var attrs = createTree()
  attrs.withTree StmtsS, info:
    if classes.len > 0:
      attrs.withTree CallX, info:
        attrs.addIdent "addClass"
        attrs.addIdent eName
        attrs.addStrLit classes
  var children = createTree()
  let oldStmt = gStmtCtx
  gStmtCtx = true
  children.withTree StmtsS, info:
    var args = firstArg(n)
    if args.kind == TagLit and args.tagText == "stmts":
      var c = firstChild(args)
      while c.hasMore:
        processElementItem(c, eName, attrs, children, true)
    else:
      while args.hasMore:
        var a = args
        processElementItem(a, eName, attrs, children, true)
        if a.hasMore:
          skip a
        args = a
  gStmtCtx = oldStmt

  var attrsLamBody = createTree()
  attrsLamBody.withTree StmtsS, info:
    attrsLamBody.addTree attrs
  var attrsLam = makeLambda(info, eName, "E", attrsLamBody)
  var childrenLam = makeLambda(info, "", "", children)

  b.withTree CallX, info:
    b.addIdent "uiBlock"
    b.addStrLit tag
    b.addTree attrsLam
    b.addTree childrenLam
  skip n

proc transformComponent(n: var NifCursor; b: var NifBuilder; uiCtx: bool) =
  let info = n.info
  var fn = firstChild(n)
  var args = firstArg(n)
  var bodyCursor = args
  var hasBody = false
  var a = args
  while a.hasMore:
    if a.kind == TagLit and a.tagText == "stmts":
      bodyCursor = a
      hasBody = true
    skip a

  var slots = createTree()
  var children = createTree()
  if hasBody:
    let oldStmt = gStmtCtx
    gStmtCtx = true
    children.withTree StmtsS, bodyCursor.info:
      var child = firstChild(bodyCursor)
      while child.hasMore:
        if child.kind == TagLit and
           (child.tagText == "cmd" or child.tagText == "call") and
           nameOf(firstChild(child)) == "slot":
          var cch = firstChild(child)
          skip cch
          var slotName = cch
          skip cch
          var slotBody = cch
          if slotName.kind == Ident and slotBody.kind == TagLit:
            var sb = createTree()
            sb.withTree StmtsS, slotBody.info:
              var scc = firstChild(slotBody)
              while scc.hasMore:
                if isPlainText(scc):
                  addTextChild(scc, sb)
                else:
                  transformNode(scc, sb, uiCtx)
            var sb2 = snapshot(sb)
            slots.withTree VvU, child.info:
              slots.addIdent identText(slotName)
              slots.withTree CallX, slotBody.info:
                slots.addIdent "uiChildren"
                slots.takeTree sb2
        else:
          if isPlainText(child):
            addTextChild(child, children)
          else:
            transformNode(child, children, uiCtx)
        skip child
    gStmtCtx = oldStmt

  b.withTree CallX, info:
    var f = fn
    b.takeTree f
    var ai = args
    while ai.hasMore:
      if ai.kind == TagLit and ai.tagText == "stmts":
        skip ai
      else:
        var arg = ai
        transformNode(arg, b, uiCtx)
    var sb: NifCursor = default(NifCursor)
    if not slots.isEmpty:
      sb = snapshot(slots)
    while sb.hasMore:
      var one = createTree()
      one.takeTree sb
      b.addTree one
    if not children.isEmpty:
      b.withTree VvU, info:
        b.addIdent "children"
        b.withTree CallX, info:
          b.addIdent "uiChildren"
          var cb = snapshot(children)
          b.takeTree cb
  skip n

proc transformNode(n: var NifCursor; b: var NifBuilder; uiCtx: bool) =
  if n.kind != TagLit:
    b.takeTree n
    return
  if isCCall(n):
    processCElement(n, b)
  elif uiCtx and gStmtCtx and n.stmtKind == IfS:
    transformIf(n, b)
  elif uiCtx and gStmtCtx and n.stmtKind == ForS:
    transformFor(n, b)
  elif uiCtx and gStmtCtx and n.stmtKind == CaseS and isResourceCase(n):
    transformCase(n, b)
  elif isComponentCall(n):
    transformComponent(n, b, uiCtx)
  elif n.tagText == "call" and nameOf(firstChild(n)) == "Text":
    var c = n
    b.takeTree c
    skip n
  elif n.tagText == "proc" or n.tagText == "func":
    var tag = n.tagId
    var info = n.info
    n.into:
      b.openTree(tag, info)
      var i = 0
      while n.hasMore:
        if i == 8:
          let oldStmt = gStmtCtx
          gStmtCtx = true
          transformNode(n, b, uiCtx)
          gStmtCtx = oldStmt
        else:
          b.takeTree n
        inc i
      b.closeTree()
  elif n.tagText == "call" or n.tagText == "cmd":
    var tag = n.tagId
    var info = n.info
    var c = firstChild(n)
    b.openTree(tag, info)
    while c.hasMore:
      transformNode(c, b, uiCtx)
    b.closeTree()
    skip n
  else:
    var tag = n.tagId
    var info = n.info
    let oldStmt = gStmtCtx
    if n.tagText == "block":
      gStmtCtx = true
    else:
      gStmtCtx = false
    n.into:
      b.openTree(tag, info)
      while n.hasMore:
        transformNode(n, b, uiCtx)
      b.closeTree()
    gStmtCtx = oldStmt

# --------------------------------------------------------------- entry points

proc emitPluginHook(info: LineInfo; b: var NifBuilder) =
  ## Emit a unique top-level value of `PluginHook`. Using the type is what
  ## queues the post-sem state plugin; the compiler deduplicates it.
  let sp = lineCol(info)
  b.withTree VarS, info:
    b.addIdent("yithHook" & $sp.line & "x" & $sp.col)
    b.addEmptyNode2(info)
    b.addIdent "PluginHook"
    b.addEmptyNode()

proc trProc(n: NifCursor; info: LineInfo): NifBuilder =
  result = createTree()
  let r = asRoutine(n)
  let bodyInfo = r.body.info
  var newBody = transformBody(r.body, bodyInfo, true)
  let lam = makeLambda(bodyInfo, "", "", newBody)
  result.withTree ProcS, info:
    var c = firstChild(n)
    var i = 0
    while c.hasMore:
      if i == 8:
        result.withTree StmtsS, bodyInfo:
          result.withTree AsgnS, bodyInfo:
            result.addIdent "result"
            result.withTree CallX, bodyInfo:
              result.addIdent "uiFragment"
              result.addTree lam
        skip c
      elif i == 6:
        result.withTree PragmasU, c.info:
          if c.kind == TagLit and c.tagText == "pragmas":
            var pc = firstChild(c)
            while pc.hasMore:
              result.takeTree pc
          result.addIdent "discardable"
          result.addIdent "yithUi"
        skip c
      else:
        result.takeTree c
      inc i

proc trTemplate(input: NifCursor): NifBuilder =
  var name = firstChild(input)
  var arg = callArgs(input)
  result = createTree()
  result.withTree StmtsS, input.info:
    var infoName = name.info
    emitPluginHook(infoName, result)
    if arg.kind == TagLit and arg.stmtKind == ProcS:
      result.addTree trProc(arg, arg.info)
    elif arg.kind == TagLit and arg.tagText == "stmts":
      var c = firstChild(arg)
      while c.hasMore:
        if c.kind == TagLit and c.stmtKind == ProcS:
          var cc = c
          result.addTree trProc(cc, cc.info)
          skip c
        else:
          transformNode(c, result, true)
    else:
      var ac = arg
      transformNode(ac, result, true)

saveTree trTemplate(loadPluginInput())
