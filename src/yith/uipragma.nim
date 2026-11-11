## `{.ui.}` macro pragma for `proc ...: E`.
##
## The macro receives the untyped routine definition before sem, rewrites
## `c.Tag.class:` chains and component calls, and returns the transformed
## definition. It emits calls to the eager runtime (`ElE`, `attr`, `addClass`,
## `addStyle`, `setProp`, `on`, `Text`, `finish`), so the normal sem pass
## resolves types and overloads afterwards.
##
## Nimony limits worked around here:
## * the macro-plugin host cannot see module-level helper routines, so every
##   helper is nested inside `ui`;
## * a `for` loop variable is captured by reference (issue #2), so all
##   `NimNode` children are walked with `while`;
## * a nested forward declaration makes the recursive call ambiguous, so the
##   whole tree transform is one self-recursive routine.

{.feature: "assumeSync".}
{.feature: "lenientnils".}

import std/macros

macro ui*(def: untyped): untyped =
  proc toLower(s: string): string =
    result = ""
    var i = 0
    while i < s.len:
      let c = s[i]
      if c >= 'A' and c <= 'Z':
        result.add char(ord(c) - ord('A') + ord('a'))
      else:
        result.add c
      inc i

  proc attrName(name: string): string =
    ## `data_id` -> `data-id`, `aria_label` -> `aria-label`;
    ## `type_`/`for_`/`method_` -> keyword spelling; everything else as is.
    result = name
    if name.len > 1 and name[name.high] == '_':
      var stripped = ""
      var i = 0
      while i < name.high:
        stripped.add name[i]
        inc i
      if stripped in ["type", "for", "method", "defer", "block"]:
        result = stripped
        return
    if name.len > 5 and name[0 .. 4] == "data_":
      result = "data-"
      var i = 5
      while i < name.len:
        if name[i] == '_': result.add '-'
        else: result.add name[i]
        inc i
    elif name.len > 5 and name[0 .. 4] == "aria_":
      result = "aria-"
      var i = 5
      while i < name.len:
        if name[i] == '_': result.add '-'
        else: result.add name[i]
        inc i

  proc isAtomKind(k: NimNodeKind): bool =
    result = k in {nnkNone, nnkEmpty, nnkIdent, nnkSym, nnkIntLit, nnkInt8Lit,
      nnkInt16Lit, nnkInt32Lit, nnkInt64Lit, nnkUIntLit, nnkUInt8Lit,
      nnkUInt16Lit, nnkUInt32Lit, nnkUInt64Lit, nnkFloatLit, nnkFloat32Lit,
      nnkFloat64Lit, nnkStrLit, nnkRStrLit, nnkTripleStrLit, nnkCharLit,
      nnkNilLit}

  proc isTextChild(k: NimNodeKind): bool =
    ## Expressions that are values become `Text(...)`; calls (components,
    ## `Text`, `children`) and control-flow statements append themselves.
    result = k in {nnkStrLit, nnkRStrLit, nnkTripleStrLit, nnkCharLit,
      nnkIntLit, nnkInt8Lit, nnkInt16Lit, nnkInt32Lit, nnkInt64Lit,
      nnkUIntLit, nnkUInt8Lit, nnkUInt16Lit, nnkUInt32Lit, nnkUInt64Lit,
      nnkFloatLit, nnkFloat32Lit, nnkFloat64Lit, nnkIdent, nnkDotExpr,
      nnkInfix, nnkPrefix, nnkPar}

  proc hasSignal(signals: seq[string]; name: string): bool =
    result = false
    var i = 0
    while i < signals.len:
      if signals[i] == name:
        return true
      inc i

  proc markSignalDef(d: NimNode; signals: var seq[string]) =
    if d.len >= 3 and d[0].kind == nnkIdent:
      var mark = false
      if d.len >= 4 and d[3].kind == nnkBracketExpr and
         d[3].len >= 1 and d[3][0].kind == nnkIdent:
        let t = d[3][0].strVal
        if t == "State" or t == "Signal" or t == "Computed":
          mark = true
      if d.len >= 5 and d[4].kind == nnkCall and d[4].len >= 1 and
         d[4][0].kind == nnkIdent:
        let c = d[4][0].strVal
        if c == "state" or c == "signal" or c == "cell" or
           c == "computed" or c == "computedExpr":
          mark = true
      if mark:
        signals.add d[0].strVal

  proc scanSignals(n: NimNode; signals: var seq[string]) =
    if n.kind == nnkLetSection or n.kind == nnkVarSection:
      # Nimony's macro AST keeps the definition directly in the section
      # (`nnkLetSection name . . . init`) rather than under `nnkIdentDefs`.
      markSignalDef(n, signals)
      var i = 0
      while i < n.len:
        if n[i].kind == nnkIdentDefs:
          markSignalDef(n[i], signals)
        inc i
    var i = 0
    while i < n.len:
      scanSignals(n[i], signals)
      inc i

  proc collectSignals(procDef: NimNode): seq[string] =
    result = @[]
    let params = procDef[4]
    var i = 0
    while i < params.len:
      let p = params[i]
      if p.kind == nnkIdentDefs and p.len >= 4 and p[0].kind == nnkIdent and
         p[3].kind == nnkBracketExpr and p[3].len >= 1 and
         p[3][0].kind == nnkIdent:
        let t = p[3][0].strVal
        if t == "State" or t == "Signal" or t == "Computed":
          result.add p[0].strVal
      inc i
    scanSignals(procDef[8], result)

  proc markResourceDef(d: NimNode; resources: var seq[string]) =
    if d.len >= 3 and d[0].kind == nnkIdent:
      var mark = false
      if d.len >= 4 and d[3].kind == nnkBracketExpr and
         d[3].len >= 1 and d[3][0].kind == nnkIdent and
         (d[3][0].strVal == "Resource" or
          d[3][0].strVal == "ArgResource"):
        mark = true
      if d.len >= 5 and d[4].kind == nnkCall and d[4].len >= 1 and
         d[4][0].kind == nnkIdent and
         (d[4][0].strVal == "resource" or d[4][0].strVal == "resourceAsync"):
        mark = true
      if mark:
        resources.add d[0].strVal

  proc scanResources(n: NimNode; resources: var seq[string]) =
    if n.kind == nnkLetSection or n.kind == nnkVarSection:
      markResourceDef(n, resources)
      var i = 0
      while i < n.len:
        if n[i].kind == nnkIdentDefs:
          markResourceDef(n[i], resources)
        inc i
    var i = 0
    while i < n.len:
      scanResources(n[i], resources)
      inc i

  proc collectResources(procDef: NimNode): seq[string] =
    result = @[]
    let params = procDef[4]
    var i = 0
    while i < params.len:
      let p = params[i]
      if p.kind == nnkIdentDefs and p.len >= 4 and p[0].kind == nnkIdent and
         p[3].kind == nnkBracketExpr and p[3].len >= 1 and
         p[3][0].kind == nnkIdent and
         (p[3][0].strVal == "Resource" or
          p[3][0].strVal == "ArgResource"):
        result.add p[0].strVal
      inc i
    scanResources(procDef[8], result)

  proc isSignalApi(name: string): bool =
    result = name == "get" or name == "set" or name == "update" or
      name == "peek" or name == "stateValue"

  proc liftMutation(sig: NimNode; v: NimNode; mutation: NimNode): NimNode =
    var stmts = newStmtList()
    stmts.add newVarStmt(v, newCall(newDotExpr(sig, newIdentNode("get"))))
    stmts.add mutation
    stmts.add newCall(newDotExpr(sig, newIdentNode("set")), [v])
    result = newBlockStmt(stmts)

  proc containsSignalRead(n: NimNode; signals: seq[string]): bool =
    if n.kind == nnkIdent and hasSignal(signals, n.strVal):
      return true
    var i = 0
    while i < n.len:
      if containsSignalRead(n[i], signals):
        return true
      inc i
    result = false

  proc isReadExpr(n: NimNode; signals: seq[string]): bool =
    if n.kind == nnkIdent:
      return hasSignal(signals, n.strVal)
    if n.kind == nnkDotExpr and n.len == 2 and n[1].kind == nnkIdent and
       n[1].strVal notin ["value", "sig", "scope"]:
      return isReadExpr(n[0], signals)
    if (n.kind == nnkCall or n.kind == nnkCommand) and n.len >= 1 and
       n[0].kind == nnkDotExpr and n[0].len == 2 and n[0][1].kind == nnkIdent:
      let m = n[0][1].strVal
      # In a value/read position any method call on a signal is treated as a
      # read. Mutating methods are only lifted when the call is a statement.
      if m == "get" or (not isSignalApi(m) and
                        m notin ["value", "sig", "scope"]):
        return isReadExpr(n[0][0], signals)
    result = false

  proc rewriteReads(n: NimNode; signals: seq[string];
                    resources: seq[string]): NimNode =
    if n.kind == nnkIdent and hasSignal(signals, n.strVal):
      result = newCall(newDotExpr(n, newIdentNode("get")))
    elif isAtomKind(n.kind):
      result = n
    elif n.kind == nnkDotExpr and n.len == 2 and n[1].kind == nnkIdent and
         n[1].strVal notin ["value", "sig", "scope"] and
         isReadExpr(n[0], signals):
      result = newDotExpr(rewriteReads(n[0], signals, resources), n[1])
    elif (n.kind == nnkCall or n.kind == nnkCommand) and n.len >= 1 and
         n[0].kind == nnkDotExpr and n[0].len == 2 and n[0][1].kind == nnkIdent:
      let m = n[0][1].strVal
      if m == "get":
        result = n
      elif not isSignalApi(m) and m notin ["value", "sig", "scope"]:
        var call = newCall(newDotExpr(
          rewriteReads(n[0][0], signals, resources), n[0][1]))
        var ai = 1
        while ai < n.len:
          call.add rewriteReads(n[ai], signals, resources)
          inc ai
        result = call
      else:
        result = newNimNode(n.kind)
        var i = 0
        while i < n.len:
          result.add rewriteReads(n[i], signals, resources)
          inc i
    else:
      result = newNimNode(n.kind)
      var i = 0
      while i < n.len:
        result.add rewriteReads(n[i], signals, resources)
        inc i

  proc isConstructorCall(n: NimNode): bool =
    result = false
    if (n.kind == nnkCall or n.kind == nnkCommand) and n.len >= 1 and
       n[0].kind == nnkIdent:
      let c = n[0].strVal
      if c == "state" or c == "signal" or c == "cell" or
         c == "computed" or c == "computedExpr":
        result = true

  proc isUiOrComponentCall(n: NimNode): bool =
    result = false
    if (n.kind == nnkCall or n.kind == nnkCommand) and n.len >= 1:
      if n[0].kind == nnkIdent:
        let c = n[0].strVal
        if c.len > 0 and c[0] >= 'A' and c[0] <= 'Z':
          result = true
      else:
        var callee = n[0]
        while callee.kind == nnkDotExpr and callee.len == 2:
          callee = callee[0]
        if callee.kind == nnkIdent and callee.strVal == "c":
          result = true

  proc scanDerived(n: NimNode; all: seq[string]; derived: var seq[string];
                   changed: var bool) =
    if n.kind == nnkLetSection or n.kind == nnkVarSection:
      if n.len >= 3 and n[0].kind == nnkIdent:
        let name = n[0].strVal
        if not hasSignal(all, name) and not hasSignal(derived, name):
          var init = newEmptyNode()
          if n.len >= 5: init = n[4]
          elif n.len >= 3: init = n[2]
          if init.kind != nnkEmpty and not isConstructorCall(init) and
             not isUiOrComponentCall(init) and containsSignalRead(init, all):
            derived.add name
            changed = true
    var i = 0
    while i < n.len:
      scanDerived(n[i], all, derived, changed)
      inc i

  proc collectDerived(procDef: NimNode; base: seq[string]): seq[string] =
    result = @[]
    var changed = true
    while changed:
      changed = false
      var all = base
      var i = 0
      while i < result.len:
        all.add result[i]
        inc i
      scanDerived(procDef[8], all, result, changed)

  proc ensureClosure(n: NimNode): NimNode =
    result = n
    if n.kind == nnkProcDef and n.len >= 9:
      let pragmas = n[6]
      if pragmas.kind == nnkPragma:
        var i = 0
        var has = false
        while i < pragmas.len:
          if pragmas[i].kind == nnkIdent and pragmas[i].strVal == "closure":
            has = true
          inc i
        if not has:
          pragmas.add newIdentNode("closure")
      elif pragmas.kind == nnkEmpty:
        n[6] = newTree(nnkPragma, [newIdentNode("closure")])

  proc collectSeqParams(procDef: NimNode; names: var seq[string];
                        types: var seq[NimNode]) =
    let params = procDef[4]
    var i = 0
    while i < params.len:
      let p = params[i]
      if p.kind == nnkIdentDefs and p.len >= 4 and p[0].kind == nnkIdent and
         p[3].kind == nnkBracketExpr and p[3].len >= 2 and
         p[3][0].kind == nnkIdent and
         (p[3][0].strVal == "State" or p[3][0].strVal == "Signal" or
          p[3][0].strVal == "Computed"):
        let vt = p[3][1]
        if vt.kind == nnkBracketExpr and vt.len >= 2 and
           vt[0].kind == nnkIdent and vt[0].strVal == "seq":
          names.add p[0].strVal
          types.add vt[1]
      inc i

  proc itemTypeFromLiteral(e: NimNode): NimNode =
    ## Best-effort item type for `@[a, b]` / `[a, b]`; Nimony macro AST has
    ## no sem types, so only unambiguous literals/constructors are inferred.
    result = newEmptyNode()
    var xs: NimNode = nil
    if e.kind == nnkPrefix and e.len == 2 and e[0].kind == nnkIdent and
       e[0].strVal == "@" and e[1].kind == nnkBracket:
      xs = e[1]
    elif e.kind == nnkBracket:
      xs = e
    if xs == nil or xs.len == 0:
      return
    let first = xs[0]
    if first.kind == nnkPrefix or first.kind == nnkBracket:
      let inner = itemTypeFromLiteral(first)
      if inner.kind != nnkEmpty:
        result = newTree(nnkBracketExpr, [newIdentNode("seq"), inner])
      return
    case first.kind
    of nnkIntLit, nnkInt8Lit, nnkInt16Lit, nnkInt32Lit, nnkInt64Lit,
       nnkUIntLit, nnkUInt8Lit, nnkUInt16Lit, nnkUInt32Lit, nnkUInt64Lit:
      result = newIdentNode("int")
    of nnkFloatLit, nnkFloat32Lit, nnkFloat64Lit:
      result = newIdentNode("float")
    of nnkStrLit, nnkRStrLit, nnkTripleStrLit:
      result = newIdentNode("string")
    of nnkCharLit:
      result = newIdentNode("char")
    of nnkIdent:
      if first.strVal == "true" or first.strVal == "false":
        result = newIdentNode("bool")
    of nnkCall, nnkCommand:
      if first.len >= 1 and first[0].kind == nnkIdent:
        result = newIdentNode(first[0].strVal)
    else:
      discard

  proc seqItemFromStateType(t: NimNode): NimNode =
    result = newEmptyNode()
    if t.kind == nnkBracketExpr and t.len >= 2 and t[0].kind == nnkIdent and
       t[0].strVal in ["State", "Signal", "Computed", "Cell"]:
      let vt = t[1]
      if vt.kind == nnkBracketExpr and vt.len >= 2 and
         vt[0].kind == nnkIdent and vt[0].strVal == "seq":
        result = vt[1]

  proc seqItemFromInit(init: NimNode): NimNode =
    result = newEmptyNode()
    if (init.kind == nnkCall or init.kind == nnkCommand) and init.len >= 2 and
       init[0].kind == nnkIdent and
       init[0].strVal in ["state", "signal", "cell", "computedExpr"]:
      result = itemTypeFromLiteral(init[1])

  proc addSeqLocal(name: string; itemType: NimNode;
                   names: var seq[string]; types: var seq[NimNode]) =
    if itemType.kind == nnkEmpty:
      return
    var exists = false
    var i = 0
    while i < names.len:
      if names[i] == name:
        exists = true
        break
      inc i
    if not exists:
      names.add name
      types.add itemType

  proc scanSeqLocals(n: NimNode; names: var seq[string];
                     types: var seq[NimNode]) =
    if n.kind == nnkProcDef:
      return
    if n.kind == nnkLetSection or n.kind == nnkVarSection:
      # Nimony stores `name ... type init` directly in the section.
      var def: NimNode = nil
      if n.len >= 3 and n[0].kind == nnkIdent:
        def = n
      else:
        var i = 0
        while i < n.len:
          if n[i].kind == nnkIdentDefs:
            def = n[i]
            break
          inc i
      if def != nil and def.len >= 3 and def[0].kind == nnkIdent:
        var itemType = newEmptyNode()
        if def.len >= 4:
          itemType = seqItemFromStateType(def[3])
        if itemType.kind == nnkEmpty and def.len >= 5:
          itemType = seqItemFromInit(def[4])
        addSeqLocal(def[0].strVal, itemType, names, types)
    var i = 0
    while i < n.len:
      scanSeqLocals(n[i], names, types)
      inc i

  proc seqItemType(names: seq[string]; types: seq[NimNode];
                   name: string): NimNode =
    result = newEmptyNode()
    var i = 0
    while i < names.len:
      if names[i] == name:
        return types[i]
      inc i

  proc makeLambda(name: string; paramType, retType, body: NimNode): NimNode =
    result = newNimNode(nnkProcDef)
    result.add newEmptyNode()
    result.add newEmptyNode()
    result.add newEmptyNode()
    result.add newEmptyNode()
    var params = newNimNode(nnkFormalParams)
    var defs = newNimNode(nnkIdentDefs)
    defs.add newIdentNode(name)
    defs.add newEmptyNode()
    defs.add newEmptyNode()
    defs.add paramType
    defs.add newEmptyNode()
    params.add defs
    result.add params
    result.add retType
    var pragmas = newNimNode(nnkPragma)
    pragmas.add newIdentNode("closure")
    result.add pragmas
    result.add newEmptyNode()
    if body.kind == nnkStmtList:
      result.add body
    else:
      result.add newStmtList([body])

  proc makeSameLambda(paramType, body: NimNode): NimNode =
    result = newNimNode(nnkProcDef)
    result.add newEmptyNode()
    result.add newEmptyNode()
    result.add newEmptyNode()
    result.add newEmptyNode()
    var params = newNimNode(nnkFormalParams)
    var a = newNimNode(nnkIdentDefs)
    a.add newIdentNode("a")
    a.add newEmptyNode()
    a.add newEmptyNode()
    a.add paramType
    a.add newEmptyNode()
    params.add a
    var b = newNimNode(nnkIdentDefs)
    b.add newIdentNode("b")
    b.add newEmptyNode()
    b.add newEmptyNode()
    b.add paramType
    b.add newEmptyNode()
    params.add b
    result.add params
    result.add newIdentNode("bool")
    var pragmas = newNimNode(nnkPragma)
    pragmas.add newIdentNode("closure")
    result.add pragmas
    result.add newEmptyNode()
    if body.kind == nnkStmtList:
      result.add body
    else:
      result.add newStmtList([body])

  proc collectDotParts(n: NimNode; root: string;
                       parts: var seq[string]): bool =
    ## `c.Div.cls1.cls2` -> ["Div", "cls1", "cls2"]; root must be `c`.
    if n.kind == nnkIdent:
      return n.strVal == root
    if n.kind == nnkDotExpr and n.len == 2 and n[1].kind == nnkIdent:
      if collectDotParts(n[0], root, parts):
        parts.add n[1].strVal
        return true
    result = false

  proc collectOpChain(n: NimNode; root: string; names: var seq[string];
                      args: var seq[NimNode]): bool =
    ## Flatten `attr.x.y(0)` / `css.a("x").b("y")` into names + arg lists.
    if n.kind == nnkIdent:
      return n.strVal == root
    if n.kind == nnkDotExpr and n.len == 2 and n[1].kind == nnkIdent:
      if collectOpChain(n[0], root, names, args):
        names.add n[1].strVal
        args.add newStmtList()
        return true
    elif n.kind == nnkCall and n.len >= 1:
      if collectOpChain(n[0], root, names, args) and names.len > 0:
        var a = newStmtList()
        var i = 1
        while i < n.len:
          a.add n[i]
          inc i
        args[args.high] = a
        return true
    result = false

  proc dashName(s: string): string =
    ## `MyElement` -> `my-element`, `background_color` -> `background-color`.
    result = ""
    var i = 0
    while i < s.len:
      let c = s[i]
      if c == '_':
        if result.len > 0 and result[result.high] != '-':
          result.add '-'
      elif c >= 'A' and c <= 'Z':
        if result.len > 0 and result[result.high] != '-':
          result.add '-'
        result.add char(ord(c) - ord('A') + ord('a'))
      else:
        result.add c
      inc i

  proc cAttrName(name: string): string =
    var n = attrName(name)
    result = ""
    var i = 0
    while i < n.len:
      if n[i] == '_': result.add '-'
      else: result.add n[i]
      inc i

  proc makeNoArgLambda(retType, body: NimNode): NimNode =
    result = newNimNode(nnkProcDef)
    result.add newEmptyNode()
    result.add newEmptyNode()
    result.add newEmptyNode()
    result.add newEmptyNode()
    result.add newNimNode(nnkFormalParams)
    result.add retType
    var pragmas = newNimNode(nnkPragma)
    pragmas.add newIdentNode("closure")
    result.add pragmas
    result.add newEmptyNode()
    if body.kind == nnkStmtList:
      result.add body
    else:
      result.add newStmtList([body])

  proc callHeadName(n: NimNode): string =
    if n.kind == nnkIdent:
      return n.strVal
    if n.kind == nnkObjConstr and n.len > 0 and n[0].kind == nnkIdent:
      return n[0].strVal
    result = ""

  proc isOnName(name: string): bool =
    result = name.len > 2 and name[0] == 'o' and name[1] == 'n' and
      name[2] >= 'A' and name[2] <= 'Z'

  proc handlerParam(head, stmt: NimNode; defaultType: NimNode;
                    pname: var string; ptype: var NimNode) =
    pname = "yithArg"
    ptype = defaultType
    var p: NimNode = nil
    if head.kind == nnkObjConstr and head.len > 1:
      var i = 1
      while i < head.len:
        if head[i].kind == nnkExprColonExpr and head[i].len == 2 and
           head[i][0].kind == nnkIdent:
          pname = head[i][0].strVal
          ptype = head[i][1]
          return
        inc i
    elif stmt.len >= 2 and stmt[1].kind != nnkStmtList:
      p = stmt[1]
      if p.kind == nnkIdent:
        pname = p.strVal
      elif p.kind == nnkObjConstr:
        var i = 1
        while i < p.len:
          if p[i].kind == nnkExprColonExpr and p[i].len == 2 and
             p[i][0].kind == nnkIdent:
            pname = p[i][0].strVal
            ptype = p[i][1]
            return
          inc i
      elif p.kind == nnkExprColonExpr and p.len == 2 and
           p[0].kind == nnkIdent:
        pname = p[0].strVal
        ptype = p[1]

  proc normalizeElemType(t: NimNode): NimNode =
    if t.kind == nnkIdent and (t.strVal == "El" or t.strVal == "Element"):
      result = newIdentNode("E")
    else:
      result = t

  proc isCChain(n: NimNode): bool =
    var parts: seq[string] = @[]
    result = collectDotParts(n, "c", parts)

  proc transformTree(n: NimNode; signals: seq[string];
                     resources: seq[string]; derived: seq[string];
                     seqNames: seq[string]; seqTypes: seq[NimNode];
                     uiCtx: bool = true): NimNode =
    if n.isNilNode:
      result = newEmptyNode()
    elif isAtomKind(n.kind):
      result = n
    elif n.kind == nnkAsgn and n.len == 2 and n[0].kind == nnkIdent and
         hasSignal(signals, n[0].strVal):
      result = newCall(newDotExpr(n[0], newIdentNode("set")),
                       [transformTree(n[1], signals, resources, derived, seqNames, seqTypes)])
    elif n.kind == nnkInfix and n.len == 3 and n[0].kind == nnkIdent and
         (n[0].strVal == "+=" or n[0].strVal == "-=" or
          n[0].strVal == "*=" or n[0].strVal == "/=" or
          n[0].strVal == "&=") and n[1].kind == nnkIdent and
         hasSignal(signals, n[1].strVal):
      let v = newIdentNode("yithV")
      let mutation = newTree(nnkInfix, [n[0], v,
        transformTree(n[2], signals, resources, derived, seqNames, seqTypes)])
      result = liftMutation(n[1], v, mutation)
    elif n.kind == nnkCaseStmt and n.len >= 2 and n[0].kind == nnkIdent and
         hasSignal(resources, n[0].strVal):
      let resVar = newIdentNode("yithRes")
      var stmts = newStmtList()
      stmts.add newLetStmt(resVar,
        newCall(newDotExpr(newDotExpr(n[0], newIdentNode("value")),
                           newIdentNode("get"))))
      var ifStmt = newNimNode(nnkIfStmt)
      var bi = 1
      while bi < n.len:
        let b = n[bi]
        if b.kind == nnkOfBranch and b.len >= 2:
          var pat = b[0]
          # The parser's `ranges` wrapper reaches the macro bridge as nnkNone.
          if pat.kind == nnkNone and pat.len == 1:
            pat = pat[0]
          var kindName = ""
          var payload = ""
          if pat.kind == nnkIdent:
            if pat.strVal == "Loading": kindName = "resLoading"
            elif pat.strVal == "Ready": kindName = "resReady"
            elif pat.strVal == "Error": kindName = "resError"
          elif pat.kind == nnkCall and pat.len >= 2 and pat[0].kind == nnkIdent:
            if pat[0].strVal == "Ready":
              kindName = "resReady"
              if pat[1].kind == nnkIdent: payload = pat[1].strVal
            elif pat[0].strVal == "Error":
              kindName = "resError"
              if pat[1].kind == nnkIdent: payload = pat[1].strVal
          if kindName.len > 0:
            var newBody = newStmtList()
            if payload.len > 0:
              let field = if kindName == "resReady": "data" else: "error"
              newBody.add newLetStmt(newIdentNode(payload),
                newDotExpr(n[0], newIdentNode(field)))
            let body = b[1]
            if body.kind == nnkStmtList:
              var bj = 0
              while bj < body.len:
                newBody.add transformTree(body[bj], signals, resources, derived, seqNames, seqTypes)
                inc bj
            else:
              newBody.add transformTree(body, signals, resources, derived, seqNames, seqTypes)
            let cond = newTree(nnkInfix, [newIdentNode("=="),
              newDotExpr(resVar, newIdentNode("kind")),
              newIdentNode(kindName)])
            ifStmt.add newTree(nnkElifBranch, [cond, newBody])
        elif b.kind == nnkElse and b.len >= 1:
          var newBody = newStmtList()
          let body = b[0]
          if body.kind == nnkStmtList:
            var bj = 0
            while bj < body.len:
              newBody.add transformTree(body[bj], signals, resources, derived, seqNames, seqTypes)
              inc bj
          else:
            newBody.add transformTree(body, signals, resources, derived, seqNames, seqTypes)
          ifStmt.add newTree(nnkElse, [newBody])
        inc bi
      stmts.add ifStmt
      result = newCall("uiCaseBlock", [stmts])
    elif (n.kind == nnkCall or n.kind == nnkCommand) and n.len >= 1 and
         n[0].kind == nnkDotExpr and n[0][0].kind == nnkIdent and
         hasSignal(signals, n[0][0].strVal) and n[0][1].kind == nnkIdent and
         not isSignalApi(n[0][1].strVal):
      let v = newIdentNode("yithV")
      var mutation = newCall(newDotExpr(v, n[0][1]))
      var ai = 1
      while ai < n.len:
        mutation.add transformTree(n[ai], signals, resources, derived, seqNames, seqTypes)
        inc ai
      result = liftMutation(n[0][0], v, mutation)
    elif n.kind == nnkProcDef and n.len >= 9:
      result = newNimNode(nnkProcDef)
      var i = 0
      while i < n.len:
        if i == 8:
          result.add transformTree(n[i], signals, resources, derived, seqNames, seqTypes, false)
        else:
          result.add transformTree(n[i], signals, resources, derived,
                                   seqNames, seqTypes, uiCtx)
        inc i
    elif uiCtx and n.kind == nnkIfStmt and n.len >= 1:
      var elseBody = newStmtList()
      var i = 0
      while i < n.len:
        if n[i].kind == nnkElse and n[i].len >= 1:
          elseBody = transformTree(n[i][0], signals, resources, derived, seqNames, seqTypes, true)
        inc i
      var nested: NimNode = elseBody
      i = n.len - 1
      while i >= 0:
        let b = n[i]
        if b.kind == nnkElifBranch and b.len >= 2:
          let cond = rewriteReads(b[0], signals, resources)
          let body = transformTree(b[1], signals, resources, derived, seqNames, seqTypes, true)
          nested = newCall("uiIf", [cond, body, nested])
        dec i
      result = nested
    elif uiCtx and n.kind == nnkForStmt and n.len >= 3:
      # Nimony's macro AST is [iterable, varTuple, body].
      let bodyNode = n[2]
      var keyExpr = newEmptyNode()
      var hasKey = false
      if bodyNode.kind == nnkStmtList and bodyNode.len > 0:
        let first = bodyNode[0]
        if (first.kind == nnkCommand or first.kind == nnkCall) and
           first.len == 2 and first[0].kind == nnkIdent and
           first[0].strVal == "key":
          keyExpr = first[1]
          hasKey = true

      let iterName = if n[0].kind == nnkIdent: n[0].strVal else: ""
      let itemType = if iterName.len > 0:
          seqItemType(seqNames, seqTypes, iterName)
        else:
          newEmptyNode()

      var loopName = ""
      let vt = n[1]
      var vi = 0
      while vi < vt.len:
        let sec = vt[vi]
        if sec.kind == nnkLetSection and sec.len > 0 and
           sec[0].kind == nnkIdent:
          loopName = sec[0].strVal
          break
        inc vi

      if hasKey and itemType.kind != nnkEmpty and loopName.len > 0 and
         bodyNode.len > 1:
        var rest = newStmtList()
        var bi = 1
        while bi < bodyNode.len:
          rest.add transformTree(bodyNode[bi], signals, resources, derived,
                                 seqNames, seqTypes, true)
          inc bi
        let keyBody = newTree(nnkPrefix, [newIdentNode("$"), keyExpr])
        let keyLambda = makeLambda(loopName, itemType,
                                   newIdentNode("string"), keyBody)
        let renderLambda = makeLambda(loopName, itemType,
                                      newIdentNode("E"), rest)
        let sameBody = newTree(nnkInfix, [newIdentNode("=="),
                                          newIdentNode("a"),
                                          newIdentNode("b")])
        let sameLambda = makeSameLambda(itemType, sameBody)
        result = newCall("forEachList",
          [n[0], sameLambda, keyLambda, renderLambda])
      else:
        let hasRead = containsSignalRead(n[0], signals)
        var iter = n[0]
        if hasRead:
          iter = rewriteReads(iter, signals, resources)
        var forStmt = newNimNode(nnkForStmt)
        forStmt.add iter
        forStmt.add n[1]
        forStmt.add transformTree(n[2], signals, resources, derived,
                                  seqNames, seqTypes, true)
        if hasRead:
          result = newCall("uiFor", [forStmt])
        else:
          result = forStmt
    elif n.kind == nnkCall and n.len == 2 and n[0].kind == nnkIdent and
         n[0].strVal == "Text" and containsSignalRead(n[1], signals):
      result = newCall("Text", [newCall("computedExpr",
        [rewriteReads(n[1], signals, resources)])])
    elif n.kind == nnkCall and n.len == 2 and n[0].kind == nnkIdent and
         n[0].strVal == "computedExpr" and containsSignalRead(n[1], signals):
      result = newCall("computedExpr",
        [rewriteReads(n[1], signals, resources)])
    elif (n.kind == nnkLetSection or n.kind == nnkVarSection) and
         n.len >= 3 and n[0].kind == nnkIdent and
         hasSignal(derived, n[0].strVal):
      var init = newEmptyNode()
      if n.len >= 5:
        init = n[4]
      elif n.len >= 3:
        init = n[2]
      result = newNimNode(n.kind)
      result.add n[0]
      result.add newEmptyNode()
      result.add newEmptyNode()
      result.add newEmptyNode()
      result.add newCall("computedExpr",
        [rewriteReads(init, signals, resources)])
    elif n.kind == nnkCall and n.len >= 2 and
         n[n.len - 1].kind == nnkStmtList and isCChain(n[0]):
      # `c.Div.cls1.cls2:` — arbitrary tags, frameorc-like chains.
      var cparts: seq[string] = @[]
      discard collectDotParts(n[0], "c", cparts)
      var tag = "div"
      var classes = ""
      var pi = 0
      while pi < cparts.len:
        let part = cparts[pi]
        if part.len > 0 and part[0] >= 'A' and part[0] <= 'Z':
          tag = dashName(part)
        else:
          if classes.len > 0: classes.add ' '
          classes.add dashName(part)
        inc pi

      let body = n[n.len - 1]
      let e = newIdentNode("yithNode")
      var children = newStmtList()
      var ops = newStmtList()

      var bi = 0
      while bi < body.len:
        let stmt = body[bi]
        var handled = false
        var names: seq[string] = @[]
        var vals: seq[NimNode] = @[]

        if stmt.kind == nnkCall:
          if collectOpChain(stmt, "attr", names, vals):
            handled = true
            var ni = 0
            while ni < names.len:
              let name = cAttrName(names[ni])
              let av = vals[ni]
              if av.len == 0:
                ops.add newCall("attr", [e, newStrLitNode(name),
                                         newIdentNode("true")])
              elif av.len == 1:
                let v = transformTree(av[0], signals, resources, derived,
                                      seqNames, seqTypes, false)
                ops.add newCall("attr", [e, newStrLitNode(name), v])
              else:
                var concat: NimNode = nil
                var ai = 0
                while ai < av.len:
                  var item = av[ai]
                  if item.kind != nnkStrLit:
                    item = newCall("$", [transformTree(item, signals,
                      resources, derived, seqNames, seqTypes, false)])
                  else:
                    item = transformTree(item, signals, resources, derived,
                                         seqNames, seqTypes, false)
                  if concat == nil:
                    concat = item
                  else:
                    concat = newTree(nnkInfix,
                      [newIdentNode("&"), concat, item])
                  inc ai
                ops.add newCall("attr", [e, newStrLitNode(name), concat])
              inc ni
          elif collectOpChain(stmt, "css", names, vals):
            handled = true
            var ni = 0
            while ni < names.len:
              let av = vals[ni]
              if av.len == 1:
                ops.add newCall("addStyle",
                  [e, newStrLitNode(dashName(names[ni])),
                   transformTree(av[0], signals, resources, derived,
                                 seqNames, seqTypes, false)])
              elif av.len > 1:
                var concat: NimNode = nil
                var ai = 0
                while ai < av.len:
                  var item = av[ai]
                  if item.kind != nnkStrLit:
                    item = newCall("$", [transformTree(item, signals,
                      resources, derived, seqNames, seqTypes, false)])
                  else:
                    item = transformTree(item, signals, resources, derived,
                                         seqNames, seqTypes, false)
                  if concat == nil:
                    concat = item
                  else:
                    concat = newTree(nnkInfix,
                      [newIdentNode("&"), concat, item])
                  inc ai
                ops.add newCall("addStyle",
                  [e, newStrLitNode(dashName(names[ni])), concat])
              inc ni
          elif collectOpChain(stmt, "prop", names, vals):
            handled = true
            var ni = 0
            while ni < names.len:
              let av = vals[ni]
              if av.len == 0:
                ops.add newCall("setProp",
                  [e, newStrLitNode(names[ni]), newIdentNode("true")])
              elif av.len == 1:
                ops.add newCall("setProp",
                  [e, newStrLitNode(names[ni]),
                   transformTree(av[0], signals, resources, derived,
                                 seqNames, seqTypes, false)])
              inc ni
          elif stmt[0].kind == nnkIdent and stmt[0].strVal == "cls" and
               stmt.len == 2:
            # `cls(value)` — dynamic class string.
            handled = true
            ops.add newCall("addClass", [e,
              transformTree(stmt[1], signals, resources, derived,
                            seqNames, seqTypes, false)])
          elif collectOpChain(stmt, "cls", names, vals):
            handled = true
            var ni = 0
            while ni < names.len:
              let av = vals[ni]
              if av.len == 0:
                ops.add newCall("addClass", [e, newStrLitNode(names[ni])])
              elif av.len == 1:
                ops.add newCall("addClass", [e, newStrLitNode(names[ni]),
                  transformTree(av[0], signals, resources, derived,
                                seqNames, seqTypes, false)])
              else:
                var cond: NimNode = nil
                var ai = 0
                while ai < av.len:
                  let item = transformTree(av[ai], signals, resources,
                    derived, seqNames, seqTypes, false)
                  if cond == nil:
                    cond = item
                  else:
                    cond = newTree(nnkInfix,
                      [newIdentNode("or"), cond, item])
                  inc ai
                ops.add newCall("addClass", [e, newStrLitNode(names[ni]), cond])
              inc ni
          elif collectOpChain(stmt, "on", names, vals):
            handled = true
            var ni = 0
            while ni < names.len:
              let av = vals[ni]
              if av.len >= 1:
                let handler = transformTree(av[0], signals, resources,
                  derived, seqNames, seqTypes, false)
                ops.add newCall("on", [e, newStrLitNode(names[ni]),
                                       ensureClosure(handler)])
              inc ni
          else:
            let head = callHeadName(stmt[0])
            if isOnName(head):
              handled = true
              let eventBody = stmt[stmt.len - 1]
              var pname = "yithArg"
              let defaultType = if head == "onMount" or head == "onCreated":
                  newIdentNode("E")
                else:
                  newIdentNode("Event")
              var ptype = defaultType
              handlerParam(stmt[0], stmt, defaultType, pname, ptype)
              let tb = transformTree(eventBody, signals, resources, derived,
                                     seqNames, seqTypes, false)
              if head == "onMount" or head == "onCreated":
                let et = normalizeElemType(ptype)
                let handler = makeLambda(pname, et, newEmptyNode(), tb)
                ops.add newCall("onCreated", [e, handler])
              elif head == "onCleanup" or head == "onUnmount" or
                   head == "onDestroy":
                let handler = makeNoArgLambda(newEmptyNode(), tb)
                ops.add newCall("onCleanup", [e, handler])
              else:
                let eventName = toLower(head[2 .. head.high])
                let handler = makeLambda(pname, newIdentNode("Event"),
                                         newEmptyNode(), tb)
                ops.add newCall("on", [e, newStrLitNode(eventName), handler])

        if not handled:
          if isReadExpr(stmt, signals):
            children.add newCall("Text", [newCall("computedExpr",
              [rewriteReads(stmt, signals, resources)])])
          else:
            let child = transformTree(stmt, signals, resources, derived,
                                      seqNames, seqTypes)
            if isTextChild(child.kind):
              children.add newCall("Text", [child])
            else:
              children.add child
        inc bi

      var stmts = newStmtList()
      stmts.add newLetStmt(e, newCall("ElE", [newStrLitNode(tag), children]))
      if classes.len > 0:
        stmts.add newCall("addClass", [e, newStrLitNode(classes)])
      var oi = 0
      while oi < ops.len:
        stmts.add ops[oi]
        inc oi
      stmts.add newCall("finish", [e])
      result = newBlockStmt(stmts)
    elif n.kind == nnkCall and n.len >= 2 and n[0].kind == nnkIdent and
         n[0].strVal.len > 0 and
         n[0].strVal[0] >= 'A' and n[0].strVal[0] <= 'Z' and
         n[n.len - 1].kind == nnkStmtList:
      # `Card(): body` -> `Card(children = uiChildren: body)`.
      var call = newNimNode(nnkCall)
      call.add n[0]
      var i = 1
      while i < n.len - 1:
        call.add transformTree(n[i], signals, resources, derived, seqNames, seqTypes)
        inc i

      let bodyBlock = n[n.len - 1]
      var slotArgs: seq[NimNode] = @[]
      var childrenStmts: seq[NimNode] = @[]
      var j = 0
      while j < bodyBlock.len:
        let stmt = bodyBlock[j]
        if stmt.kind == nnkCommand and stmt.len >= 3 and
           stmt[0].kind == nnkIdent and stmt[0].strVal == "slot":
          let slotBody = transformTree(stmt[2], signals, resources, derived, seqNames, seqTypes)
          slotArgs.add newTree(nnkExprEqExpr, [stmt[1],
            newCall("uiChildren", [slotBody])])
        else:
          childrenStmts.add transformTree(stmt, signals, resources, derived, seqNames, seqTypes)
        inc j

      j = 0
      while j < slotArgs.len:
        call.add slotArgs[j]
        inc j
      if childrenStmts.len > 0:
        call.add newTree(nnkExprEqExpr, [newIdentNode("children"),
          newCall("uiChildren", [newStmtList(childrenStmts)])])
      result = call
    else:
      result = newNimNode(n.kind)
      var i = 0
      while i < n.len:
        result.add transformTree(n[i], signals, resources, derived, seqNames, seqTypes)
        inc i

  result = def
  if def.kind != nnkStmtList or def.len == 0:
    return
  let procDef = def[0]
  if procDef.kind != nnkProcDef or procDef.len < 9:
    return
  let pragmas = procDef[6]
  if pragmas.kind == nnkPragma:
    pragmas.add newIdentNode("discardable")
  let signals = collectSignals(procDef)
  let resources = collectResources(procDef)
  let derived = collectDerived(procDef, signals)
  var seqNames: seq[string] = @[]
  var seqTypes: seq[NimNode] = @[]
  collectSeqParams(procDef, seqNames, seqTypes)
  scanSeqLocals(procDef[8], seqNames, seqTypes)
  var allSignals = signals
  var di = 0
  while di < derived.len:
    allSignals.add derived[di]
    inc di
  let body = transformTree(procDef[8], allSignals, resources, derived, seqNames, seqTypes)
  procDef[8] = newStmtList([
    newAssignment(newIdentNode("result"), newCall("fragment", [body]))])
