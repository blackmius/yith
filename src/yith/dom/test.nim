## Test DOM: a plain-Nim tree that can be serialized to HTML and fired.
##
## This backend is selected with `-d:yithDomTest` and lets the whole UI stack
## (`core`, `dsl`, `component`) be compiled and tested on the C backend, with
## no Node and no browser.

type
  NodeKind* = enum
    nkElement, nkText, nkComment

  Event* = ref object
    kind*: string
    target*: Node
    prevented*: bool
    x*, y*: float
    pointerId*: int

  Handler* = ref object
    event*: string
    cb*: proc (e: Event) {.closure.}

  Node* = ref object
    kind*: NodeKind
    tag*: string
    text*: string
    attrs*: seq[(string, string)]
    props*: seq[(string, string)]
    children*: seq[Node]
    parent*: Node
    handlers*: seq[Handler]

proc scheduleMicrotask*(cb: proc () {.nimcall.}) =
  ## The test backend has no event loop: run the flush now. Tests are
  ## deterministic and do not have to await anything.
  cb()

proc createElement*(tag: string): Node =
  result = Node(kind: nkElement, tag: tag)

proc createTextNode*(text: string): Node =
  result = Node(kind: nkText, text: text)

proc createComment*(text: string): Node =
  result = Node(kind: nkComment, text: text)

proc detach(n: Node) =
  if n.parent != nil:
    let p = n.parent
    var i = 0
    while i < p.children.len:
      if p.children[i] == n:
        p.children.delete i
        break
      inc i
    n.parent = nil

proc appendChild*(parent, child: Node) =
  child.detach()
  child.parent = parent
  parent.children.add child

proc insertBefore*(parent, child, before: Node) =
  child.detach()
  child.parent = parent
  var i = 0
  while i < parent.children.len:
    if parent.children[i] == before:
      parent.children.setLen(parent.children.len + 1)
      var j = parent.children.len - 1
      while j > i:
        parent.children[j] = parent.children[j - 1]
        dec j
      parent.children[i] = child
      return
    inc i
  parent.children.add child

proc remove*(n: Node) =
  n.detach()

proc setAttribute*(n: Node; name, value: string) =
  var i = 0
  while i < n.attrs.len:
    if n.attrs[i][0] == name:
      n.attrs[i] = (name, value)
      return
    inc i
  n.attrs.add (name, value)

proc setProp*(n: Node; name, value: string) =
  var i = 0
  while i < n.props.len:
    if n.props[i][0] == name:
      n.props[i] = (name, value)
      return
    inc i
  n.props.add (name, value)

proc setProp*(n: Node; name: string; value: bool) =
  setProp(n, name, (if value: "true" else: "false"))

proc setProp*(n: Node; name: string; value: int) =
  setProp(n, name, $value)

proc getProp*(n: Node; name: string): string =
  var i = 0
  while i < n.props.len:
    if n.props[i][0] == name:
      return n.props[i][1]
    inc i
  result = ""

proc removeAttribute*(n: Node; name: string) =
  var i = 0
  while i < n.attrs.len:
    if n.attrs[i][0] == name:
      n.attrs.delete i
      return
    inc i

proc getAttribute*(n: Node; name: string): string =
  for i in 0 ..< n.attrs.len:
    if n.attrs[i][0] == name:
      return n.attrs[i][1]
  result = ""

proc setText*(n: Node; text: string) =
  n.text = text

proc textContent*(n: Node): string =
  case n.kind
  of nkText, nkComment:
    result = n.text
  of nkElement:
    result = ""
    for i in 0 ..< n.children.len:
      result.add textContent(n.children[i])

proc addEventListener*(n: Node; event: string;
                       cb: proc (e: Event) {.closure.}) =
  n.handlers.add Handler(event: event, cb: cb)

proc removeEventListener*(n: Node; event: string) =
  var i = 0
  while i < n.handlers.len:
    if n.handlers[i].event == event:
      n.handlers.delete i
    else:
      inc i

proc fireAt*(n: Node; event: string; x, y: float): int =
  ## Dispatch a pointer-like event with coordinates on `n`.
  let e = Event(kind: event, target: n, x: x, y: y)
  result = 0
  for i in 0 ..< n.handlers.len:
    if n.handlers[i].event == event:
      n.handlers[i].cb(e)
      inc result

proc fire*(n: Node; event: string): int =
  ## Dispatch `event` on `n`. Returns the number of handlers that ran.
  result = fireAt(n, event, 0.0, 0.0)

proc clientX*(e: Event): float =
  e.x

proc clientY*(e: Event): float =
  e.y

proc preventDefault*(e: Event) =
  e.prevented = true

proc target*(e: Event): Node =
  result = e.target

proc escapeHtml(s: string; text: bool): string =
  result = ""
  for i in 0 ..< s.len:
    case s[i]
    of '&': result.add "&amp;"
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    of '"':
      if text: result.add "\"" else: result.add "&quot;"
    else: result.add s[i]

proc isVoid(tag: string): bool =
  case tag
  of "br", "img", "input", "hr", "meta", "link", "area", "base", "col",
     "embed", "source", "track", "wbr":
    result = true
  else:
    result = false

proc toHtmlFull*(n: Node): string =
  result = ""
  case n.kind
  of nkText:
    result = escapeHtml(n.text, true)
  of nkComment:
    result = "<!--" & n.text & "-->"
  of nkElement:
    result = "<" & n.tag
    for i in 0 ..< n.attrs.len:
      result.add " " & n.attrs[i][0] & "=\"" & escapeHtml(n.attrs[i][1], false) & "\""
    result.add ">"
    if isVoid(n.tag):
      return
    for i in 0 ..< n.children.len:
      result.add toHtmlFull(n.children[i])
    result.add "</" & n.tag & ">"

proc toHtml*(n: Node): string =
  ## Serialize without implementation anchors (comment nodes).
  result = ""
  case n.kind
  of nkText:
    result = escapeHtml(n.text, true)
  of nkComment:
    result = ""
  of nkElement:
    result = "<" & n.tag
    for i in 0 ..< n.attrs.len:
      result.add " " & n.attrs[i][0] & "=\"" & escapeHtml(n.attrs[i][1], false) & "\""
    result.add ">"
    if isVoid(n.tag):
      return
    for i in 0 ..< n.children.len:
      result.add toHtml(n.children[i])
    result.add "</" & n.tag & ">"

proc find*(n: Node; sel: string): Node =
  ## Minimal selector: `#id`, `.class`, or a tag name. Depth-first pre-order.
  result = nil
  var wantAttr = ""
  var wantVal = ""
  if sel.len > 0 and sel[0] == '#':
    wantAttr = "id"
    wantVal = sel[1 .. ^1]
  elif sel.len > 0 and sel[0] == '.':
    wantAttr = "class"
    wantVal = sel[1 .. ^1]
  case n.kind
  of nkElement:
    if wantAttr.len > 0:
      let v = getAttribute(n, wantAttr)
      if wantAttr == "class":
        # class is a space-separated list
        var i = 0
        while i <= v.len:
          var j = i
          while j < v.len and v[j] != ' ': inc j
          if v[i ..< j] == wantVal: return n
          i = j + 1
      elif v == wantVal:
        return n
    elif n.tag == sel:
      return n
    for i in 0 ..< n.children.len:
      result = find(n.children[i], sel)
      if result != nil: return
  else:
    discard

proc findAll*(n: Node; sel: string; acc: var seq[Node]) =
  var wantAttr = ""
  var wantVal = ""
  if sel.len > 0 and sel[0] == '#':
    wantAttr = "id"
    wantVal = sel[1 .. ^1]
  elif sel.len > 0 and sel[0] == '.':
    wantAttr = "class"
    wantVal = sel[1 .. ^1]
  if n.kind == nkElement:
    var hit = false
    if wantAttr.len > 0:
      let v = getAttribute(n, wantAttr)
      if wantAttr == "class":
        var i = 0
        while i <= v.len:
          var j = i
          while j < v.len and v[j] != ' ': inc j
          if v[i ..< j] == wantVal: hit = true
          i = j + 1
      elif v == wantVal:
        hit = true
    elif n.tag == sel:
      hit = true
    if hit: acc.add n
    for i in 0 ..< n.children.len:
      findAll(n.children[i], sel, acc)

proc queryAll*(n: Node; sel: string): seq[Node] =
  result = @[]
  findAll(n, sel, result)

proc textOf*(n: Node): string =
  result = textContent(n)

proc nextSibling*(n: Node): Node =
  if n.parent == nil: return nil
  let p = n.parent
  var i = 0
  while i < p.children.len:
    if p.children[i] == n:
      if i + 1 < p.children.len: return p.children[i + 1]
      return nil
    inc i
  result = nil

proc parentNode*(n: Node): Node =
  result = n.parent
