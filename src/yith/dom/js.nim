## Browser DOM backend. Every value that must cross the JS boundary is an
## opaque handle (a `ptr` used only through `importjs`).

{.feature: "assumeSync".}

type
  NodeObj = object
  EventObj = object
  Node* = ptr NodeObj
    ## An opaque host handle. A JS object crosses `importjs` as an int32
    ## index into the host table (`ewrap`/`eunwrap`), so it must be a
    ## `ptr`/handle type: a `ref object` would also be reference counted by
    ## ARC, which decrements memory at the handle's *value* and eventually
    ## deallocates an arbitrary address.
  Event* = ptr EventObj

  Handler* = ref object
    cb*: proc (e: Event) {.closure.}

var handlers: seq[Handler]
var ensured = false

proc createElement*(tag: string): Node {.importjs: "document.createElement(#)".}
proc documentBody(): Node {.importjs: "document.body".}
proc createTextNode*(text: string): Node {.importjs: "document.createTextNode(#)".}
proc createComment*(text: string): Node {.importjs: "document.createComment(#)".}
proc appendChild*(parent, child: Node) {.importjs: "#.appendChild(#)".}
proc insertBefore*(parent, child, before: Node) {.importjs: "#.insertBefore(#, #)".}
proc remove*(n: Node) {.importjs: "#.remove()".}
proc setAttribute*(n: Node; name, value: string) {.importjs: "#.setAttribute(#, #)".}
proc removeAttribute*(n: Node; name: string) {.importjs: "#.removeAttribute(#)".}
proc setText*(n: Node; text: string) {.importjs: "#.nodeValue = #".}
proc setProp*(n: Node; name, value: string) {.importjs: "#[#] = #".}
proc setProp*(n: Node; name: string; value: bool) {.importjs: "#[#] = #".}
proc setProp*(n: Node; name: string; value: int) {.importjs: "#[#] = #".}
proc textContent*(n: Node): string {.importjs: "#.textContent".}
proc preventDefault*(e: Event) {.importjs: "#.preventDefault()".}
proc target*(e: Event): Node {.importjs: "#.target".}
proc clientX*(e: Event): float {.importjs: "#.clientX".}
proc clientY*(e: Event): float {.importjs: "#.clientY".}

proc scheduleMicrotask*(cb: proc () {.nimcall.}) {.importjs: "queueMicrotask(#)".}

proc captureStackBase*() {.importjs: "globalThis.__yithStackBase = (_SPF.length ? _SPF[_SPF.length-1] : SP); globalThis.__yithStackDepth = (_SPF.length ? _SPF.length-1 : 0);".}
  ## Remember the shadow-stack position between events. The JS backend can
  ## leave a frame behind when a callback throws; resetting at the event
  ## boundary keeps a long-lived page from exhausting the 1 MB shadow stack.

proc jsEnsure() {.importjs: "(globalThis.__yithOn = globalThis.__yithOn || function(n, ev, cb, id) { var f = function(e) { globalThis.__yithEvDepth = (globalThis.__yithEvDepth || 0) + 1; try { cb(id, e); } finally { globalThis.__yithEvDepth--; if (globalThis.__yithEvDepth === 0 && typeof globalThis.__yithStackBase === 'number') { SP = globalThis.__yithStackBase; _SPF.length = globalThis.__yithStackDepth || 0; } } }; n.__yith = n.__yith || {}; n.__yith[ev] = n.__yith[ev] || []; n.__yith[ev].push(f); n.addEventListener(ev, f); }, globalThis.__yithOff = globalThis.__yithOff || function(n, ev) { var a = n.__yith && n.__yith[ev]; if (!a) return; for (var i = 0; i < a.length; i++) n.removeEventListener(ev, a[i]); delete n.__yith[ev]; })".}

proc jsOn(n: Node; event: string; cb: proc (id: int; e: Event) {.nimcall.};
          id: int) {.importjs: "globalThis.__yithOn(#, #, #, #)".}

proc jsOff(n: Node; event: string) {.importjs: "globalThis.__yithOff(#, #)".}

proc dispatch(id: int; e: Event) {.nimcall.} =
  if id >= 0 and id < handlers.len and handlers[id] != nil:
    handlers[id].cb(e)

proc addEventListener*(n: Node; event: string;
                       cb: proc (e: Event) {.closure.}): int =
  if not ensured:
    ensured = true
    jsEnsure()
  var id = -1
  var i = 0
  while i < handlers.len:
    if handlers[i] == nil:
      id = i
      break
    inc i
  if id < 0:
    id = handlers.len
    handlers.add Handler(cb: cb)
  else:
    handlers[id] = Handler(cb: cb)
  jsOn(n, event, dispatch, id)
  result = id

proc removeEventListener*(n: Node; event: string; id: int) =
  if id >= 0 and id < handlers.len:
    # Drop the closure (and everything it captured) immediately. The array
    # slot is reused by the next registration.
    handlers[id] = nil
  if ensured:
    jsOff(n, event)

proc removeEventListener*(n: Node; event: string) =
  removeEventListener(n, event, -1)

proc nextSibling*(n: Node): Node {.importjs: "#.nextSibling".}
proc parentNode*(n: Node): Node {.importjs: "#.parentNode".}

proc debugLog*(s: string) {.importjs: "console.log(#)".}
proc memoryInfo*(): string {.importjs: "(function(){var m=0;try{m=JMEM.byteLength/1048576}catch(e){}return 'mem='+m.toFixed(1)+'MB pages='+memorySize()+' sp='+((SP||0)/1048576).toFixed(1)})()".}
proc stackInfo*(): string {.importjs: "'sp=' + SP + ' depth=' + _SPF.length".}
proc startMemWatch*(ms: int) {.importjs: "globalThis.__yithMemTimer = setInterval(function(){ if (globalThis.NIF && globalThis.NIF.logMem) globalThis.NIF.logMem(); }, #)".}
proc stopMemWatch*() {.importjs: "if (globalThis.__yithMemTimer) { clearInterval(globalThis.__yithMemTimer); globalThis.__yithMemTimer = 0; }".}
proc jsStringify*(n: Node): string {.importjs: "JSON.stringify(#)".}
proc find*(n: Node; sel: string): Node {.importjs: "#.querySelector(#)".}

proc rectLeft(n: Node): float {.importjs: "#.getBoundingClientRect().left".}
proc rectTop(n: Node): float {.importjs: "#.getBoundingClientRect().top".}
proc rectWidth(n: Node): float {.importjs: "#.getBoundingClientRect().width".}
proc rectHeight(n: Node): float {.importjs: "#.getBoundingClientRect().height".}

proc bounds*(n: Node): Rect =
  result = Rect(x: rectLeft(n), y: rectTop(n),
                w: rectWidth(n), h: rectHeight(n))

proc createHiddenHost*(): Node =
  ## A hidden, laid-out container. `visibility: hidden` (not
  ## `display: none`) keeps CSS layout active so `getBoundingClientRect`
  ## reports real geometry.
  result = createElement("div")
  setAttribute(result, "style",
    "position:absolute;left:-100000px;top:0;visibility:hidden;" &
    "pointer-events:none;")
  appendChild(documentBody(), result)
