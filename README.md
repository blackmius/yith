# yith — reactive UI for Nimony

`yith` is an SPA library without a virtual DOM. The tree is built once; when
`State` changes, the nearest `Scope` re-runs, not the whole application. The
intended model of signals, DSL, slots and the drag-and-drop example is in
[`DESIGN.md`](DESIGN.md).

## Requirements

- Nimony with the `{.rewriteModule("path").}` pre-sem hook (the companion
  Nimony change). The legacy `{.ui.}` macro path works without it.
- `jorogumo` from `nativenif` on `PATH` for `nimony j` (JS tests and examples).
- The C tests need only the Nimony toolchain; they use the built-in test DOM.

## Layers

| module | what it does |
|---|---|
| `core.nim` | `State[T]`, `Scope`, subscriptions, batching, dispose |
| `dom/test.nim` | DOM tree in pure Nim: `toHtml`, `fire`, lookup |
| `dom/js.nim` | browser `importjs` bindings |
| `dsl.nim` | low-level `Text`, `ElE`, `uiBlock`, `uiWhen`, events |
| `uipragma.nim` | macro pragma `{.ui.}` for `proc ...: E`: `c.Tag.class:` |
| `component.nim` | `E`, `fragment`, `mount`, `replace` |
| `context.nim` | `context[T]`, `provide`, `use` |
| `async.nim` | passive effects without blocking the thread |
| `fetch.nim` | `awaitText` on top of `fetch`/Promise |
| `drag.nim` | model-driven drag controller: targets, closest, pointer, drop |
| `spec.nim` | speculative render of target states into a detached DOM |
| `motion.nim` | tween/spring interpolation + style binding |

Public facade: `import yith/ui`.

## Model

```nim
let count = state(0)

uiBlock(proc () {.closure.} =
  Text("count=" & $count.get()))
```

- `state(v)` creates a signal.
- `.get()` during scope execution subscribes that scope.
- `.set(v)` marks subscribers dirty and schedules a microtask flush.
- `uiBlock`, `uiWhen`, `uiLoop`, `fragment`, `effect` create a scope.
- Disposing a scope recursively disposes child scopes and DOM nodes and calls
  `onCleanup`; unsubscribing from a signal is O(1) via a doubly linked list.

`get()` outside scope execution (an event handler, imperative code) **does not
subscribe** to anything: for an explicit read without subscription use
`stateValue`.

## Components

A component is an ordinary `proc ...: E` with the `{.ui.}` pragma. The macro
wraps the body in a build-once fragment itself; `return`/`result` are not
needed.

```nim
import yith/ui
import yith/uipragma

proc Counter(): E {.ui.} =
  let count = state(0)
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
      onMount(e: El):
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
local/parameter signals, arbitrary methods in `Text`/children
(`s.total`, `s.hasTwo()`) and `s.len`, automatic `computedExpr` for local
`let z = <expr with signals>`, reactive `if`/`for`, keyed `for` with
`key expr`, auto-`.closure.` on event lambdas, `Resource[T]`/
`ArgResource[T, A]` with `case user:`. The keyed path also works for local
`let items = state(@[...])`.

Tests: `tests/ui/tuipragma.nim`, `tsugar.nim`, `tcomputed.nim`,
`tresource.nim`, `taresource.nim`, `targresource.nim`,
`tcontrol.nim`, `tkeyed.nim`, `tcombinator.nim`, `tmotion.nim`,
`tspec.nim`.

## Declarative dragging

`drag.nim` is the first slice of declarative dragging: the application lists
**target model states** and their positions, and the drag controller itself
picks the nearest target under the pointer.

```nim
let dragCtl = newDragController[Board]()
```

- `DragTarget[S]` — `state: S` + `pos: Point`;
- `closest(targets)` — "nearest target" behaviour;
- `between(targets)` — a combinator for a set of targets (in this slice it
  picks the nearest one; visual interpolation comes later);
- `.whenFar(fallback, radius)` — if the nearest target is farther than the
  radius, use the fallback state (for example, a state without the element);
- `.withFloating()` — mark the preview as floating;
- `start(drag, behavior, p)` / `start(drag, targets, p)`;
- `move(drag, p)`, `finish(drag)`, `cancel(drag)`;
- `hasDrop(drag)`, `chosen(drag)`.

Example `examples/ui/kanban.nim`:

- on `pointerdown` a card builds all states "task inserted into each
  column/position" (`buildDrag`) and their points
  (`closest(...).withFloating()`);
- the column header reorders columns via
  `between(columnReorderStates).withFloating()`;
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

Limitation: target positions come from the layout model/`rect()`; speculative
rendering and `lerpViews`/Delaunay from Dragology are not implemented yet. That
is the next layer. `dropTarget`, `switchToStateAndFollow`, `vary` and
`withSnapRadius` are missing too for now.

### Browser

`examples/ui/kanban_js.nim` + `kanban.html` — an experimental browser wrapper
on runtime primitives (because `{.ui.}` does not build for JS, issue #25):

```sh
examples/ui/build_kanban_js.sh
python3 -m http.server 8000
# http://localhost:8000/examples/ui/kanban.html
```

For now it renders the initial board, but drop fails in the JS backend during
scope teardown (`DataView`/dealloc, issue #27). The working path for the drag
examples is the C/test DOM (`tests/ui/run.sh`).

## Speculative rendering

`spec.nim` renders a model state into a **separate detached DOM** without
touching the live UI:

```nim
let views = speculate(@[state1, state2],
  proc (s: MyState): E =
    let e = ElE("div"):
      Text(s.label)
    setAttr(e, "data-id", s.id)
    result = e)

for v in views:
  echo toHtml(v.root)
  discard measure(v, "#item-1", proc (n: Node; s: MyState): Point =
    Point(x: 0.0, y: s.y))
  dispose(v)
```

This is the basis for model-driven dragging: target states can be rendered
offscreen and measured instead of hand-written layout functions. For now
measurement is an external callback (`rect()` in the browser, attributes/model
in tests).

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

## Plugin-native UI (migration from std/macros)

### Exact `{.ui.}` via `{.rewriteModule.}`

Nimony provides a single pre-sem hook: a module plugin that sees the raw module
before phase1. It is enabled with one annotation:

```nim
{.rewriteModule("../../src/yith/uiblock_plugin").}

var theme {.state.}: string = "light"

proc View(count {.state.}: int): E {.ui.} =
  c.Div.root:
    attr.id("root")
    c.Span.title:
      "hello"
    c.Button.btn:
      onClick(e):
        count = count + 1
      "click"
```

The plugin:

- rewrites `c.Tag.class:` into runtime calls;
- strips `{.ui.}` from the procedure;
- turns `name {.state.}: T` into `State[T]` and rewrites reads/writes
  (`count` → `count.get()`, `count = v` → `count.set(v)`);
- expands reactive `if`/`for`, keyed lists and derived locals.

There are no phases (`preSem`/`beforeBodies`/`postSem`) and no type queries in
the compiler. The old module-level `{.plugin: "path".}` still works on an
already sem-checked module.

### State between modules

`{.state.}` is sugar for the declaration only. Module A:

```nim
{.rewriteModule("../../src/yith/uiblock_plugin").}

var theme* {.state.}: string = "light"   # becomes State[string]
```

Module B sees a plain `State[string]` and can:

1. pass it to a `{.state.}` parameter — the parameter itself becomes `State[T]`:

   ```nim
   proc View(theme {.state.}: string): E {.ui.} = ...
   discard View(mytheme)          # mytheme: State[string]
   ```

2. create an alias with `{.signal.}` (it does not wrap again, it only marks
   the value for get/set in this module):

   ```nim
   let theme {.signal.} = a.theme
   ```

3. write `.get()`/`.set()` explicitly.

A bare `a.theme` without an alias is not rewritten: the pre-sem plugin only
sees the source of its own module, without imports and types. This is a
deliberate limitation, not an unfinished feature.

Checks:

- `tests/ui/tuiphase.nim` — C/test DOM;
- `tests/ui/tuiphase_sugar.nim`, `tuiphase_if.nim`, `tuiphase_for.nim`,
  `tuiphase_keyed.nim`, `tuiphase_state.nim`;
- `tests/ui/tuiphase_cross_b.nim` — state from another module;
- `tests/ui/js_uiphase.nim` — **JS without std/macros**.

### Block form (`ui:` template plugin)


`std/macros` is legacy. Verified: a Nimony plugin can be a template plugin with
an untyped block that receives NIF **before sem** and can transform the `c`
syntax. It builds under JS too, without `std/macros`.

```nim
import yith/ui
import yith/uiblock

ui:
  proc View(): E =
    c.Div.cls1:
      attr.id("root")
      c.Span.title:
        "hello"
      c.Button.btn:
        onClick(e):
          echo "clicked"
        "click"
```

`uiblock_plugin.nim` already handles:

- `c.Tag.class:`;
- `attr.name(value)`, `css.name(value)`, `prop.name(value)` (one name per call);
- `onClick(e):`, `onCleanup():`;
- nested `c` and text;
- attributes/classes are applied after `let node = ElE(...)`, events through
  generated `proc (...) {.closure.}`.

Checks:

- `tests/ui/tuiplugin.nim` — C/test DOM:
  `<div class="cls1" id="root"><span class="title">hello</span><button class="btn">click</button></div>`;
- `tests/ui/js_uiblock.nim` — **JS** (`nimony j`), without `std/macros`:
  the same DOM in a Node harness.

The `rewriteModule` path already has signal sugar (`s = v`, `s += v`,
auto-`.get()`), `if`/`for` lowering, derived locals and keyed lists. `slots`
and `Resource`/`case` are not ported yet; for those the old `{.ui.}` macro is
still used.

Important: a plugin-template cannot be attached as a proc pragma `{.ui.}`
(y28). Exact `{.ui.}` works through `{.rewriteModule(...).}` (a single pre-sem
module hook), and the `ui:` block works through the template plugin.

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
let userId = signal(0)
let user = resource(proc (): User {.passive.} =
  fetchJson("/api/users/" & $userId.get()))

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
let userId = signal(0)
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

`run_js.sh` compiles `js_smoke`, `js_async` and `js_aresource` with
`nimony j` and runs them with the matching Node harnesses
(`js_harness.js`, `js_async_harness.js`, `js_aresource_harness.js`).
`js_aresource` checks `Loading → Ready`, re-running on source change and
discarding a late response from a previous generation.

`tuiphase`/`js_uiphase` cover the exact `{.ui.}` path through
`rewriteModule` on C and JS. The legacy macro (`uipragma.nim`) remains C-only:
importing `std/macros` in a JS build fails on `errorcodes_posix`
(`docs/nimony-issues.md` #25); `tests/ui/run.sh` covers it.

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
