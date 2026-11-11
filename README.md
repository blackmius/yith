# yith — reactive UI for Nimony

`yith` is an SPA library without a virtual DOM. The tree is built once; when
`State` changes, the nearest `Scope` re-runs, not the whole application. The
intended model of signals, DSL, slots and the drag-and-drop example is in
[`DESIGN.md`](DESIGN.md).

## Requirements

- Nimony with plugin support: a template plugin (the `{.ui.}` syntax pass) and
  a post-sem module/type plugin (the state pass).
- `jorogumo` from `nativenif` for `nimony j` (JS tests and examples). Build it
  once in a `nativenif` checkout whose sibling is `../nimony`:

  ```sh
  cd ../nativenif
  nim c src/jorogumo/jorogumo.nim       # -> bin/jorogumo
  ```

  Then put `nativenif/bin` on `PATH`, or point the test runner at it with
  `JOROGUMO_DIR=../nativenif/bin tests/ui/run_js.sh`.
- The C tests need only the Nimony toolchain; they use the built-in test DOM.

## Layers

| module | what it does |
|---|---|
| `core.nim` | `State[T]`, `Scope`, subscriptions, batching, dispose |
| `dom/test.nim` | DOM tree in pure Nim: `toHtml`, `fire`, lookup |
| `dom/js.nim` | browser `importjs` bindings |
| `dsl.nim` | low-level `Text`, `uiBlock`, `uiWhen`, `uiLoop`, events |
| `uiblock.nim` | the `{.ui.}` / `ui:` plugin template entry point |
| `uiblock_plugin.nim` | pass 1: `c.Tag.class:` → `uiBlock`/`uiWhen`/`uiLoop` |
| `state_plugin.nim` | pass 2: `{.state.}` → `State[T]` + `get`/`set` |
| `component.nim` | `E`, `fragment`, `mount`, `replace` |
| `context.nim` | `context[T]`, `provide`, `use` |
| `async.nim` | passive effects without blocking the thread |
| `fetch.nim` | `awaitText` on top of `fetch`/Promise |
| `drag.nim` | model-driven drag controller: targets, closest, pointer, drop |
| `spec.nim` | hidden DOM render/measure of target states (`speculativeTargets`) |
| `motion.nim` | tween/spring interpolation + style binding |

Public facade: `import yith/ui`.

## Model

```nim
var count {.state.}: int = 0

uiBlock(proc () {.closure.} =
  Text("count=" & $count))
```

- `{.state.}` marks a declaration (or parameter) as reactive. Pass 1 leaves it
  as a plain value, so ordinary Nim code type-checks; pass 2 rewrites the
  declaration to `State[T]` and reads/writes to `get`/`set`.
- `newState(v)` is the explicit constructor for a `State[T]` handle.
- `.get()` during scope execution subscribes that scope.
- `.set(v)` marks subscribers dirty and schedules a microtask flush.
- `uiBlock`, `uiWhen`, `uiLoop`, `fragment`, `effect` create a scope.
- Disposing a scope recursively disposes child scopes and DOM nodes and calls
  `onCleanup`; unsubscribing from a signal is O(1) via a doubly linked list.

`get()` outside scope execution (an event handler, imperative code) **does not
subscribe** to anything: for an explicit read without subscription use
`stateValue`. State handles are passed explicitly; a `{.state.}` parameter is
the plain-value API and accepts `.state.` values (or literals, which pass 2
wraps with `newState`).

## Components

A component is an ordinary `proc ...: E` with the `{.ui.}` pragma. Importing
`yith/ui` brings the pragma, both plugin passes and the runtime. The syntax pass
wraps the body in a build-once fragment itself; `return`/`result` are not
needed.

```nim
import yith/ui

proc Counter(): E {.ui.} =
  var count {.state.}: int = 0
  c.Div.counter:
    c.Span.n:
      count
    c.Button.inc:
      onClick(e):
        count += 1
      "inc"
```

## The `c` syntax

The only syntax for native tags: a single `c`, dots and indentation. The tag is
arbitrary; `Props` records are not needed.

```nim
proc View(count: State[int]): E {.ui.} =
  c.Div.cls1.cls2:
    c.Button.btn_default:
      attr.disabled(true).aria_label("Click")
      css.background_color("#eee").padding("4px").font_size(10, "px")
      prop.title("hello").tabIndex(3)
      onClick(e):
        count += 1
      onMount(e):
        echo "mounted"
      onCleanup():
        echo "cleanup"
      "Click me"
    c.MyElement:
      "custom"
```

- `Div`/`MyElement`/`H1` are tags, `MyElement` → `<my-element>`;
- `cls1`, `btn_default` are classes (`btn_default` → `btn-default`);
- `cls(name)` is a dynamic class, `cls.active(cond)` a conditional one;
- `attr.*` are attributes, `data_*`/`aria_*`/underscores → dashes;
  they can be chained: `attr.disabled(true).aria_label("Click")`;
  a `bool` value means presence: `true` sets the attribute, `false`
  removes it; there is no list of "boolean attributes" — the overload
  `setAttr(e, name, bool)` does the job;
- `css.*` are inline styles, names → kebab-case, several arguments
  are concatenated (`font_size(10, "px")` → `10px`);
- `prop.*` are DOM properties; also chainable:
  `prop.title("hello").tabIndex(3)`;
- `onClick(e):`/`onInput(e):` are events, `onMount(e: El)`/`onCreated` and
  `onCleanup()` are lifecycle; `on.click(handler)` is supported too;
- bare strings/values are text, a nested `c.Tag` is a child.

Additionally supported: slots `Card(): body` and `slot title: body`
(the component receives `children`/`title: proc () {.closure.}`),
auto-fragment (multi-root), `Computed`, `s += v`/`s.foo()` and `s = v` for
`.state.` values, arbitrary methods in `Text`/children
(`s.total`, `s.hasTwo()`) and `s.len`, automatic `computedExpr` for local
`let z = <expr with state>`, reactive `if`/`for`, keyed `for` with
`key expr`, auto-`.closure.` on event lambdas, `Resource[T]`/
`ArgResource[T, A]` with `case user:`. The keyed path also works for local
`var items {.state.}: seq[T] = @[...]`.

Tests: `tests/ui/tfeatures.nim`, `tsugar.nim`, `tcomputed.nim`,
`tresource.nim`, `taresource.nim`, `targresource.nim`,
`tcontrol.nim`, `tkeyed.nim`, `tcombinator.nim`, `tmotion.nim`,
`tspec.nim`.

## Declarative dragging

`drag.nim` implements declarative dragging: the application lists **target
model states**, the library renders each one into a hidden DOM host, measures
the dragged element with the browser's CSS layout, and the controller picks
the nearest target under the pointer.

```nim
let dragCtl = newDragController[Board]()
```

- `DragTarget[S]` — `state: S` + `pos: Point` (usually measured by
  `speculativeTargets`);
- `closest(targets)` — "nearest target" behaviour;
- `between(targets)` — a combinator for a set of targets (in this slice it
  picks the nearest one; visual interpolation comes later);
- `.whenFar(fallback, radius)` — if the nearest target is farther than the
  radius, use the fallback state (for example, a state without the element);
- `.withFloating()` — mark the preview as floating;
- `start(drag, behavior, p)` / `start(drag, targets, p)`;
- `move(drag, p)`, `finish(drag)`, `cancel(drag)`;
- `hasDrop(drag)`, `chosen(drag)`;
- `previewState(start)` — the state to render live during the drag.

### Layout is CSS, not arithmetic

Drag plans never compute `x`/`y` for items. The model stores only logical
state (identity, order, parent); the view declares layout with CSS
(`display:flex`, `gap`, `padding`, widths, grids). The browser computes every
box. To know where a drop would put the dragged element, yith renders the
candidate state into the hidden host and measures the real box.

While dragging, the application can assign `dragCtl.previewState(start)` to its
model state. CSS reflows the actual elements to the preview arrangement, and a
floating ghost is just a `position:fixed` element following the pointer. On
drop, the chosen state stays; on cancel, the start state is restored.

Example `examples/ui/kanban.nim`:

- on `pointerdown` a card builds all states "task inserted into each
  column/position" (`buildDrag`), renders them hidden, and measures the
  dragged card (`closest(...).withFloating()`);
- the column header reorders columns the same way (`buildColumnDrag`);
- the component's normal CSS (flex columns/rows, padding, gaps) determines
  the positions; there are no `targetPoint`/`rowPoint` tables;
- `pointermove` picks the nearest point;
- `pointerup` applies the `state` of the chosen target to `State[Board]`;
- the ghost follows the pointer via `drag.pointer.get()`;
- the target column is highlighted via `cls.drop(...)`.

`examples/ui/rows.nim` is a direct counterpart of the example from the article:
rows and tiles. Dragging a row/tile builds the states
`closest(targets).whenFar(stateWithout).withFloating()`; when the pointer moves
farther than the radius the fallback is chosen, and the ghost stays floating.

Running:

```sh
tests/ui/run.sh
# or
nimony c -d:yithDomTest -p:src examples/ui/kanban.nim -o:bin/kanban && ./bin/kanban
```

Limit: `between` still selects the nearest measured target instead of
interpolating between DOM renders, and `lerpViews`/Delaunay from Dragology are
not implemented yet. That is the next layer. `dropTarget`, `switchToStateAndFollow`, `vary` and
`withSnapRadius` are missing too for now.

### Browser

`examples/ui/kanban.nim` + `kanban.html` — the same plugin-based example is
also built for JS:

```sh
examples/ui/build_kanban_js.sh
python3 -m http.server 8000
# http://localhost:8000/examples/ui/kanban.html
```

For signal/scope lifecycle debugging use the debug bundle:

```sh
YITH_DEBUG=1 examples/ui/build_kanban_js.sh
```

It starts with a `yith kanban cyclefix-4` console marker and keeps the last
5000 `[yith] link/unlink/set/set visit` events. Before reproducing a problem,
clear the buffer so the crash window is not overwritten:

```js
NIF.clearLog()      // start a fresh capture
// ... click/drag until it fails ...
NIF.dumpLog()       // print the ring buffer
NIF.debugSignals()  // live subscriber counts per state
```

The browser backend declares DOM values as opaque `ptr` handles, so scope
teardown never reference-counts a host object (`docs/nimony-issues.md` #27).
The C/test DOM path (`tests/ui/run.sh`) stays deterministic and is the one the
drag tests drive.

## Speculative rendering

`spec.nim` renders a model state into a **hidden, laid-out DOM host** without
touching the live UI. In the browser the host is attached with
`visibility:hidden`, so normal CSS layout is real and `bounds`/`rect` read
`getBoundingClientRect`; the C test DOM has a small layout pass for
block/flex flow, padding, gap, absolute positioning and translate:

```nim
let views = speculate(@[state1, state2],
  proc (s: MyState): E =
    let e = ElE("div"):
      Text(s.label)
    setAttr(e, "data-id", s.id)
    result = e)

for v in views:
  echo toHtml(v.root)
  let r = rect(v, "#item-1")
  echo r.x, ",", r.y, " ", r.w, "x", r.h
  dispose(v)
```

To build drag targets directly:

```nim
let targets = speculativeTargets(states, render, "#item-1", liveRoot)
```

The component's normal CSS decides where each item lands; the drag code only
reads the measured boxes. Pass the live root as `origin`: the hidden host sits
off-screen in the browser, so raw `getBoundingClientRect` values are shifted by
that offset. `origin` moves the targets into the same client coordinate frame
as pointer events. The C/test DOM backend re-roots every measurement at `0,0`,
so its targets already share a frame.

## Motion core

`motion.nim` is the first layer of declarative animations:

```nim
let e = ElE("div"):
  Text("card")
let m = bindMotion(e, motionValues(0.0, 20.0, 0.9, 0.0))

m.animateTo(motionValues(0.0, 0.0, 1.0, 1.0), tween(0.25))
# or spring(100.0, 15.0)
discard m.tick(1.0 / 60.0)
```

- `tween(duration, easing)` and `spring(stiffness, damping)`;
- `MotionProps`: `x`, `y`, `scale`, `opacity`;
- `bindMotion` attaches the animated style to an `E`;
- `tick(dt)` applies a frame; `stagger(index, each)` — a base delay;
- `easeLinear`/`easeOut`/`easeInOut`.

There are no variants, AnimatePresence/exit, layout projection, keyframes or
`whileInView` yet; those are the next layers on top of `spec` + `motion`.

## Two-pass UI compilation

`yith` does not use `std/macros`. Importing `yith/ui` brings in the `{.ui.}`
template plugin and the runtime. A component is written as usual; two plugin
passes turn it into ordinary typed Nimony.

### Pass 1 — syntax (`uiblock_plugin.nim`)

`proc View(): E {.ui.} = ...` invokes the template plugin with the untyped
routine definition. It rewrites only syntax that is not valid Nim:

```nim
c.Div.card:
  attr.id("root")
  "hello"
```

becomes

```nim
uiBlock("div",
  proc (e: E) {.closure.} =
    addClass(e, "card")
    attr(e, "id", "root"),
  proc () {.closure.} =
    Text("hello"))
```

It also lowers `if`/`elif`/`else` to `uiWhen`, `for` to `uiLoop` (with a
`uiKey` marker for keyed loops), `case user:` over a resource to
`uiCaseBlock`, component calls with `children`/`slot` arguments, and all
attributes, styles, properties and event handlers.

`{.state.}` is deliberately left untouched. The result is valid Nimony in
which a state variable is still a plain value, so the normal semantic pass can
type-check the component.

The syntax pass also emits a unique `var yithHook…: PluginHook` per routine.
`PluginHook` is a nominal type in `yith/internal.nim` carrying
`{.plugin: "state_plugin".}`; Nimony deduplicates type plugins per module, so
the second pass runs exactly once per module regardless of how many components
it contains.

### Pass 2 — state (`state_plugin.nim`)

The module/type plugin receives the semchecked module and rewrites
`{.state.}` declarations and every use that resolved to them:

```nim
var name {.state.}: string = state("light")
name = name & "!"
```

becomes

```nim
var name: State[string] = newState("light")
name.set(name.get() & "!")
```

The plugin emits source-level NIF (`State`, `get`, `set`, `newState`) and lets
Nimony re-run sem, so the result is fully typed. It handles:

- declarations and parameters: `T` → `State[T]`, initializer → `newState(v)`;
- reads, assignments and compound assignments (`+=`, `-=`, `*=`, `/=`, `&=`);
- mutating method calls (`items.add(5)`) through a temporary;
- derived locals in UI routines (`let z = <expr with state>`) via
  `computedExpr`;
- keyed `for` loops via `forEachList`;
- `Text`/attribute values: a bare State is passed to the State overload, an
  expression is wrapped in `computedExpr`, so it stays reactive;
- explicit `State[T]` parameters and imported handles are recognized by their
  type and only their uses are rewritten.

`state(v)` is an identity proc; it exists so `var x {.state.}: T = state(v)`
type-checks before pass 2. Nimony identifiers cannot start with `_`, so the
real constructor is `newState(v)` (not `_state`).

### Cross-module state

A module that only declares state (no components) must enable the state pass
explicitly; importing `yith/core` is not enough:

```nim
import yith/core
import yith/internal

stateModule()                       # run the post-sem state pass once

var theme* {.state.}: string = "light"
```

A module that imports it sees a normal `State[string]`. Use an explicit
`State[string]` parameter (and `.get()`/`.set()`) across module boundaries; a
`{.state.}` parameter is the plain-value API for values declared in the same
module. There is no `{.signal.}` alias. The state pass only knows the state
parameters of the module it is compiling; when calling an imported helper that
takes an explicit `State[T]`, pass the handle through (or unwrap with `.get()`
if the helper takes the value).

### Block form

The same template can be used as a block when a routine pragma is not
convenient:

```nim
import yith/ui

ui:
  proc View(): E =
    c.Div.card:
      "hello"
```

### Checks

- `tests/ui/tuiphase*.nim` — syntax, state, `if`/`for`, keyed loops, sugar,
  methods, cross-module handles;
- `tests/ui/tfeatures.nim` — slots, attributes, events, `Computed`,
  `Resource`;
- `tests/ui/js_plugin.nim` — both `ui:` and `{.ui.}` forms on JS.

## Context (useContext)

```nim
type ChartData = object
  rows: seq[Row]

let ChartCtx = context[ChartData]()

# low-level template: `El` is a runtime primitive, not part of the `c` DSL
template RadarChart(data: untyped; body: untyped) =
  El("svg"):
    provide(ChartCtx, data):
      body

template PolarGrid(stroke = "#e5e7eb") =
  let chart = use(ChartCtx)
  El("g"): discard
  # ... chart.rows / scale ...

RadarChart(data = radar360):
  PolarGrid(stroke = "#e5e7eb")
  Radar(name = "Peer review", dataKey = "Peer review")
```

The provider is a dynamic extent for the duration of rendering. Every scope
created inside remembers the context chain, so `uiBlock`/`uiWhen`/`fragment`
still see their own value after re-running. `use` without a provider is a
`panic`.

## Asynchrony

```nim
effect:
  let s = awaitText("/api/radar")
  data.set s
```

`effect:` starts a `.passive` block via `delay`/`advance` without blocking the
thread. `awaitText` parks the coroutine and resumes it under the same scope, so
a `.get()` after `await` subscribes the right scope.

**Important:** `delay()` must be a separate statement, not an argument of
another call (`register(delay(), sc)` compiles incorrectly).

## Asynchronous Resource

```nim
var userId {.state.}: int = 0
let user = resource(proc (): User {.passive.} =
  fetchJson("/api/users/" & $userId))

case user:
of Loading: Spinner()
of Ready(data): UserCard(data)
of Error(error): ErrorView(error)

user.mutate(User(name: "Optimistic"))
user.refetch()
```

A passive `resource` starts a single `effectPassive` in the current scope:
signals read before the first `await` subscribe it. Changing the source or
calling `refetch()` re-runs the effect, each run gets a generation, and a late
response from an old run is discarded. `mutate` updates Ready data without
changing the kind, so the branch is not recreated.

The `data`/`error` payloads are `State`s on the resource handle. This is a
workaround for a JS backend bug: `State[T]` inside a variant object loses its
value after a passive effect re-runs (`docs/nimony-issues.md` #24).

Resource with an argument:

```nim
var userId {.state.}: int = 0
let user = resource(proc (id: int): User {.passive.} =
  fetchJson("/api/users/" & $id), userId.get())

refetch(user, 42)
```

The type is called `ArgResource[T, A]`: Nimony does not compile `Resource[T]`
and `Resource[T, A]` in the same module (two generic types with different
arity, `docs/nimony-issues.md` #26). Both the synchronous and the passive
overloads of `resource(fetcher, arg)` exist; `refetch(user, arg)` switches the
argument.

## Events

```nim
let b = ButtonE(...):
  Text("click")

OnClick(b):
  inc hits
```

The test backend stores handlers directly in the node: `fire(node, "click")`.
The browser one uses an `id → closure` table and a capture-free dispatcher.

## Tests

```sh
# core and DSL on C, without Node
../nimony/bin/nimony c -d:yithDomTest -p:src tests/ui/tdsl.nim -o:/tmp/tdsl && /tmp/tdsl

# JS smoke/async/resource (requires jorogumo in PATH)
tests/ui/run_js.sh
```

`run_js.sh` compiles `js_smoke`, `js_async`, `js_aresource` and `js_plugin`
with `nimony j` and runs them with the matching Node harnesses.
`js_aresource` checks `Loading → Ready`, re-running on source change and
discarding a late response from a previous generation.

`tuiphase` and `js_plugin` cover the two-pass `{.ui.}` path on C and JS.
There is no macro path and no `std/macros` dependency.

## Limitations of this version of Nimony

1. **A closure in `for` sees the last value of the loop variable.** Therefore
   DSL primitives in statement position do not create closures: `Text`/
   attributes are evaluated immediately, and the scope re-renders.
2. **`for` + a discardable call returning `ref`** crashed `finalir` before
   `2c5b3dca`; now fixed, `TextE` works in a loop. `Text`/`Box`/
   `Button` remain void for statement position as an API decision.
3. **The JS backend** (`nimony j`) requires `jorogumo` from `nativenif`; the
   target is `--os:standalone --cpu:wasm32`, `defined(js)` is not set.
4. The application starts through an exported procedure (`{.exportc.}`),
   otherwise the generated code calls `nim_exit` at the end of `main`.
