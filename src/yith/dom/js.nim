## Browser DOM backend. Every value that must cross the JS boundary is an
## opaque handle (a `ref object` used only through `importjs`).

{.feature: "assumeSync".}

type
  Node* = ref object
  Event* = ref object

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

proc jsEnsure() {.importjs: "(globalThis.__yithOn = globalThis.__yithOn || function(n, ev, cb, id) { var f = function(e) { cb(id, e); }; n.__yith = n.__yith || {}; n.__yith[ev] = n.__yith[ev] || []; n.__yith[ev].push(f); n.addEventListener(ev, f); }, globalThis.__yithOff = globalThis.__yithOff || function(n, ev) { var a = n.__yith && n.__yith[ev]; if (!a) return; for (var i = 0; i < a.length; i++) n.removeEventListener(ev, a[i]); delete n.__yith[ev]; })".}

proc jsOn(n: Node; event: string; cb: proc (id: int; e: Event) {.nimcall.};
          id: int) {.importjs: "globalThis.__yithOn(#, #, #, #)".}

proc jsOff(n: Node; event: string) {.importjs: "globalThis.__yithOff(#, #)".}

proc dispatch(id: int; e: Event) {.nimcall.} =
  if id >= 0 and id < handlers.len and handlers[id] != nil:
    handlers[id].cb(e)

proc addEventListener*(n: Node; event: string;
                       cb: proc (e: Event) {.closure.}) =
  if not ensured:
    ensured = true
    jsEnsure()
  let id = handlers.len
  handlers.add Handler(cb: cb)
  jsOn(n, event, dispatch, id)

proc removeEventListener*(n: Node; event: string) =
  if ensured:
    jsOff(n, event)

proc nextSibling*(n: Node): Node {.importjs: "#.nextSibling".}
proc parentNode*(n: Node): Node {.importjs: "#.parentNode".}

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
