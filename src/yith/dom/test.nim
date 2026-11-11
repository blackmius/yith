## Test DOM: a plain-Nim tree that can be serialized to HTML and fired.
##
## This backend is selected with `-d:yithDomTest` and lets the whole UI stack
## (`core`, `dsl`, `component`) be compiled and tested on the C backend, with
## no Node and no browser.

proc debugLog*(s: string) =
  discard

proc captureStackBase*() =
  discard

proc memoryInfo*(): string =
  result = ""

proc stackInfo*(): string =
  result = ""

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
    computed*: Rect
    layW*, layH*: float

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


# ---------------------------------------------------------------- CSS layout
# A deliberately small subset of CSS, enough for speculative drag rendering:
# block/flex flow, explicit width/height, padding, gap, absolute/fixed
# positioning and translate transforms. It is not a browser engine; it keeps
# the C tests deterministic while the real DOM backend uses the browser.

proc isSpace(c: char): bool = c == ' ' or c == '\t' or c == '\n' or c == '\r'

proc trim(s: string): string =
  var a = 0
  var b = s.len
  while a < b and isSpace(s[a]): inc a
  while b > a and isSpace(s[b - 1]): dec b
  result = s[a ..< b]

proc parseNumber(s: string; ok: var bool): float =
  result = 0.0
  ok = false
  var i = 0
  while i < s.len and isSpace(s[i]): inc i
  var sign = 1.0
  if i < s.len and (s[i] == '-' or s[i] == '+'):
    if s[i] == '-': sign = -1.0
    inc i
  var any = false
  while i < s.len and s[i] >= '0' and s[i] <= '9':
    result = result * 10.0 + float(ord(s[i]) - ord('0'))
    any = true
    inc i
  if i < s.len and s[i] == '.':
    inc i
    var frac = 0.1
    while i < s.len and s[i] >= '0' and s[i] <= '9':
      result = result + float(ord(s[i]) - ord('0')) * frac
      frac = frac * 0.1
      any = true
      inc i
  if any:
    result = result * sign
    ok = true

proc styleValue(n: Node; name: string): string =
  var i = 0
  while i < n.attrs.len:
    if n.attrs[i][0] == "style":
      let style = n.attrs[i][1]
      var start = 0
      while start <= style.len:
        var stop = start
        while stop < style.len and style[stop] != ';': inc stop
        let part = trim(style[start ..< stop])
        var colon = -1
        var j = 0
        while j < part.len:
          if part[j] == ':': colon = j
          inc j
        if colon >= 0:
          let key = trim(part[0 ..< colon])
          if key == name:
            return trim(part[colon + 1 ..< part.len])
        start = stop + 1
    inc i
  result = ""

proc lengthOf(n: Node; name: string; fallback: float): float =
  let v = styleValue(n, name)
  if v.len == 0 or v == "auto": return fallback
  var ok = false
  let f = parseNumber(v, ok)
  if ok: result = f else: result = fallback

proc firstLengthOf(n: Node; name: string; fallback: float): float =
  let v = styleValue(n, name)
  if v.len == 0: return fallback
  var ok = false
  let f = parseNumber(v, ok)
  if ok: result = f else: result = fallback

proc paddingOf(n: Node): float =
  result = firstLengthOf(n, "padding", 0.0)

proc gapOf(n: Node): float =
  result = firstLengthOf(n, "gap", 0.0)

proc isOutOfFlow(n: Node): bool =
  let p = styleValue(n, "position")
  result = p == "absolute" or p == "fixed"

proc translateOf(n: Node; tx, ty: var float) =
  tx = 0.0
  ty = 0.0
  let t = styleValue(n, "transform")
  if t.len == 0 or t == "none": return
  var open = -1
  var i = 0
  while i < t.len:
    if t[i] == '(':
      open = i
      break
    inc i
  if open < 0: return
  var j = open + 1
  var ok = false
  tx = parseNumber(t[j ..< t.len], ok)
  if not ok: return
  while j < t.len and t[j] != ',': inc j
  if j < t.len:
    ty = parseNumber(t[j + 1 ..< t.len], ok)

proc measureNode(n: Node) =
  case n.kind
  of nkText:
    n.layW = float(n.text.len) * 7.0
    n.layH = 16.0
  of nkComment:
    n.layW = 0.0
    n.layH = 0.0
  of nkElement:
    let pad = paddingOf(n)
    let gap = gapOf(n)
    let display = styleValue(n, "display")
    let direction = styleValue(n, "flex-direction")
    var cw = 0.0
    var ch = 0.0
    var first = true
    var i = 0
    while i < n.children.len:
      let child = n.children[i]
      if child.kind != nkElement or not isOutOfFlow(child):
        measureNode(child)
        if display == "flex" and direction != "column":
          if not first: cw = cw + gap
          cw = cw + child.layW
          if child.layH > ch: ch = child.layH
        elif display == "flex":
          if not first: ch = ch + gap
          ch = ch + child.layH
          if child.layW > cw: cw = child.layW
        else:
          if child.layW > cw: cw = child.layW
          ch = ch + child.layH
        first = false
      inc i
    n.layW = cw + pad * 2.0
    n.layH = ch + pad * 2.0
    let ew = lengthOf(n, "width", -1.0)
    let eh = lengthOf(n, "height", -1.0)
    if ew >= 0.0: n.layW = ew
    if eh >= 0.0: n.layH = eh

proc placeNode(n: Node; x, y: float) =
  var tx = 0.0
  var ty = 0.0
  translateOf(n, tx, ty)
  n.computed = Rect(x: x + tx, y: y + ty, w: n.layW, h: n.layH)
  if n.kind != nkElement: return
  let pad = paddingOf(n)
  let gap = gapOf(n)
  let display = styleValue(n, "display")
  let direction = styleValue(n, "flex-direction")
  var cx = x + tx + pad
  var cy = y + ty + pad
  var first = true
  var i = 0
  while i < n.children.len:
    let child = n.children[i]
    if child.kind != nkElement or not isOutOfFlow(child):
      if display == "flex" and direction != "column":
        if not first: cx = cx + gap
        placeNode(child, cx, cy)
        cx = cx + child.layW
      elif display == "flex":
        if not first: cy = cy + gap
        placeNode(child, cx, cy)
        cy = cy + child.layH
      else:
        placeNode(child, cx, cy)
        cy = cy + child.layH
      first = false
    inc i
  i = 0
  while i < n.children.len:
    let child = n.children[i]
    if child.kind == nkElement and isOutOfFlow(child):
      let left = lengthOf(child, "left", 0.0)
      let top = lengthOf(child, "top", 0.0)
      if styleValue(child, "position") == "fixed":
        placeNode(child, left, top)
      else:
        placeNode(child, x + tx + left, y + ty + top)
    inc i

proc bounds*(n: Node): Rect =
  var root = n
  while root.parent != nil: root = root.parent
  measureNode(root)
  placeNode(root, 0.0, 0.0)
  result = n.computed

proc createHiddenHost*(): Node =
  result = createElement("div")
  setAttribute(result, "style", "position:absolute;left:-100000px;top:0;")
