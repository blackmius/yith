# yith — design

Target reactivity model and DSL. Current implementation status is in
[`README.md`](README.md); this file describes where we are heading and which
rules must not change along the way.

## 1. Principles

1. **Build once.** The DOM is created once; after that reactivity changes a
   specific text node, attribute, branch, or list element. There is no virtual
   DOM.
2. **Everything is signals.** `State[T]`, `Computed[T]`, `effect` are the only
   source of changes. DOM, context, async and lists are consumers of the graph.
3. **Standard Nim.** Components are ordinary procedures, bodies are ordinary
   code. Sugar (`if`, `for`, attrs, slots) is stripped by a compile-time layer;
   every piece of sugar has a runtime equivalent when the plugin is off.
4. **Explicit ownership.** `Scope` owns effects, DOM nodes, subscriptions,
   signals, context and coroutines. Deleting a scope deletes the whole subtree,
   without traversing signals.
5. **Precision.** Subscription and update happen at the leaf level: text,
   attribute, condition, list element. Reading a signal "somewhere in the body"
   subscribes the nearest scope and re-renders it entirely — this is a
   deliberate fallback.

## 2. Execution model

```
State[T] ──► Computed[U] ──► Binding (text/attr/if/for) ──► DOM
    ▲               ▲
    └──── effect ───┘            onCleanup, async, context
```

- **Source** — `State[T]`: a value and a list of subscribers.
- **Derived** — `Computed[T]`: a lazy/memoized computation depending on other
  nodes; notifies only when the value changes.
- **Effect** — a block of code with dependencies, restart, and cleanup.
- **Binding** — a special case of effect with a single DOM target (node,
  attribute, branch, list element).
- **Scope** — an ownership node. The scope tree mirrors the structure of
  components, branches, and list elements.

### 2.1 Phases

1. **Build** — the component/element creates DOM and scope and runs its body.
2. **Bind** — expressions in reactive positions become `Computed`/
   binding; subscriptions are recorded.
3. **Update** — `set` marks dependencies, flush recomputes computed and
   restarts effects; the DOM changes pointwise.
4. **Dispose** — subscriptions are removed, cleanups are called, nodes are
   deleted, coroutines are cancelled, signals are released.

### 2.2 Tracking

`.get()` subscribes the **current computation** (effect/computed/binding) if
one is running. Outside a computation (event handler, imperative code)
`.get()` subscribes nothing. For an explicit read without subscription — `.peek()`.

The rule is the same for sync and async code: when a coroutine resumes, the
runtime restores its scope/computation, so a `.get()` after `await`
subscribes exactly the effect in which the `await` occurred.

## 3. Signals

Terminology: `State[T]` is the general term for a reactive handle; the
concrete types are chosen by `newState(v)`:

- `Cell[T]` — a primitive/explicit cell;
- `ObjState[T]` — an object with `FieldRef` fields;
- `SeqState[T]` — a sequence with `FieldRef` elements;
- `TableState[K,V]`, `SetState[T]` — collections.

`cell(v)` is always `Cell[T]`. In the current code the source is called
`State[T]`/`state`; renaming with aliases will happen as implementation
proceeds.

### 3.1 `State[T]`

`newState(v)` is deep by default for composite values: an object/seq/
Table/Set gets a store and proxy types (§3.7). For a primitive it is
`Cell[T]`. `cell(v)` is an explicit low-level cell for any `T`.

```nim
let count = newState(0)       # Cell[int]
count.get()                 # reads and subscribes the current computation
count.set(1)                # no-op if the value is equal (==)
count.setAlways(1)          # forced notification
count.update proc (v: var int) =
  v += 1                    # copy → mutate → set (comparison inside)
count.peek()                # without subscription
```

- `set` compares values (`==` by default) and notifies only on change. For
  types without `==` — `newState(v, eq = ...)` or `setAlways`.
- A signal is a `let`: the reference does not change, the value does. `var s:
  State[T]` is not needed.
- `s.set(...)`/`s.update(...)` is the canonical form. `s = v` is rewritten by
  the `{.ui.}` state pass into `s.set(v)` for local state and parameters;
  `s += v`/`-=`/`*=`/`/=`/`&=` and `s.foo(args)` are lifted by the pass into
  `var yithV = s.get(); yithV op ...; s.set(yithV)`, so any `proc mut(x: var T)`
  works. This is sugar, not reassigning the reference.
  For global state the syntax pass cannot see the type: `s = v` is an explicit
  `.set`, `+=`/`-=` are concrete overloads on `State[int/float/string]`.
- `update` is an operation over a `Cell`/`Store` snapshot: it copies, applies
  the `var` procedure, then calls `set`. For a deep `signal`, the ordinary
  operations are available (`push`, `s.field = v`) — see §3.7.
- `get()` returns a snapshot (Nim value semantics); for large structures —
  `List`/an explicit store or proxy access (§3.6–§3.7).
- This describes `Cell[T]`. `newState(obj/seq)` uses the deep model: each
  field/element has its own signal, and bindings of different fields do not
  recompute each other (§3.7).

### 3.2 Objects and nested data

`newState(obj)` is deep: each field/element has its own signal, and the code
is written as ordinary object manipulation.

```nim
type
  Todo = object
    id: int
    title: string
    done: bool
  Board = object
    todos: seq[Todo]
    counter: int

let board = newState(Board(todos: @[], counter: 0))

board.counter += 1                  # -> update of the counter field
board.todos.push(Todo(id: 1, title: "design", done: false))
board.todos[0].done = true          # -> update of the element
Text(board.counter)                 # binding on the field
Text(board.todos[0].title)          # binding on the element's field
```

- `board.get()` — a `Board` snapshot; `board.set(v)`/`board = v` — a diff.
- Changing `counter` does not recompute the bindings of `todos[...]`;
  per-field/per-item signals give pointwise edges.
- `board.todos` — `SeqState[Todo]`; `board.todos[0]` — `TodoRef`;
  `TodoRef.done` — `FieldRef[bool]`; all of it looks like ordinary fields.
- `update` remains for snapshots and batch changes:
  `board.update proc (v: var Board) = v.counter += 1`.

For types where proxies are not generated (generic/imported/recursive) —
`cell` or an explicit `Store`/`List` (§3.6, §3.7).

### 3.3 `Computed[T]`

```nim
let doneCount = computed(proc (): int =
  var n = 0
  for t in board.get().todos:
    if t.done: inc n
  n)

let visible = computed(proc (): seq[Todo] =
  board.get().todos.filter(proc (t: Todo): bool = not t.done))
```

- `Computed` recomputes on read after invalidation; if bindings/effects are
  subscribed to it, the runtime recomputes it during flush and notifies
  subscribers only when the value changes (`eq`).
- Dependencies are rebuilt on every recomputation (dynamic tracking): if a
  branch stops reading a signal, the edge disappears.
- `computed:` is sugar for `computed(proc(): T = body)`.
- A single computation can be reused in several places: one subscriber, as
  many DOM updates as there are bindings.
- Common cases are shorter:
  ```nim
  todos.len                       # Computed[int] for State[seq[T]]/List[T]
  let done = todos.derive(proc (xs: seq[Todo]): int =
    xs.filter(proc (t: Todo): bool = t.done).len)
  ```
  `derive` is `computed` with a value argument; on `State[T]`:
  `board.derive(proc (b: Board): int = b.counter)`.

### 3.4 `effect` and `onCleanup`

```nim
effect:
  let id = board.get().counter
  Text("counter " & $id)
  onCleanup:
    echo "restart or dispose"
```

- The body runs immediately; then on any dependency change.
- Before a restart and on dispose all `onCleanup` handlers run (LIFO).
- `effect` creates a scope; scopes/DOM/subscriptions created inside it die
  with it.
- Nested effects are children of the current scope.

### 3.5 Lifecycle: build once

The component body runs **once** per instance. During execution tracking is
off: a `.get()` in the body reads the value and does **not** subscribe the
component. Reactive reads live in bindings (`Text`, attributes),
`if`/`for` (their conditions/sources are computed) and explicit
`effect`/`computed`.

```nim
proc Row(card: State[Card]): E {.ui.} =
  Text(card.get().title)       # binding: only the text is updated

proc Counter(): E {.ui.} =
  let n = newState(0)            # created once
  let doubled = computed(proc (): int = n.get() * 2)
  c.Button:
    onClick(e):
      n.update(proc (v: var int) = v += 1)
    Text($doubled.get())
```

- `signal`/`computed` in the body are created once and live with the instance.
- `set` does not restart the component body; only the binding/computed
  that read the signal is recomputed.
- The instance dies when its owner **structurally** replaces it: an
  `if` branch change, a key change in `for`, `Dynamic(page)`, parent dispose.
  Its signals, effects and DOM go with it.
- State that must survive a branch/page change is lifted higher (parent,
  context, module) or lives in a keep-alive container.
- Props: a plain value is a snapshot; for a reactive prop, `State[T]`/
  `Computed[T]` is passed and read in a binding. The plugin may wrap the
  expression at the call site in `computed`.

```nim
# this won't work: x is a snapshot, it won't update
proc Bad(): E =
  let card = getCard()
  let x = card.get().title
  Text(x)
```

The auto-wrapper `proc ...: E` is a boundary: it disables tracking for the
duration of the body, so a read in the body will not subscribe even an outer
`effect`. Bindings inside enable tracking for themselves.

### 3.6 Collections: `List`, `Set`, `Table`

`State[seq[T]]` is the simple case: any `set` notifies the whole thing. For
collections with keys there are three stores with a common contract:

- **structure** (the set of keys/order) and **content** (the value by key)
  are notified separately;
- `for` rebuilds the DOM only on structural changes; a value is
  updated via a per-key `Signal`;
- common operations: `len: Computed[int]`, `has(key): bool`, `clear`;
- keys are stable and unique; changing a key = delete + create.

#### 3.6.1 `List[T]` — order and keys

```nim
let todos = list(@[
  Todo(id: 1, title: "design", done: false),
  Todo(id: 2, title: "build", done: true),
], key = proc (t: Todo): int = t.id)

todos.len                 # Computed[int]
todos.get(1)              # State[Todo] (by key)
todos.has(2)              # bool, reads the structure
todos.add(Todo(id: 3, ...))
todos.remove(2)
todos.move(0, 2)
todos.updateAt(1, proc (t: var Todo) = t.done = true)
```

- Order is insertion order; `move` changes only that.
- `get(key)` requires an existing key; for an optional one —
  `tryGet(key) -> Option[State[T]]`.
- `add/remove/move` change the structure: `for` creates/moves/deletes DOM.
- `updateAt` changes only `State[Todo]`: the row updates, the structure does not.
- `newState(seq[T])` returns `SeqState[T]` (the same keyed store).
  `cell(seq[T])`/raw `State[seq]` work too: `ForEach` maintains the
  table of keys and item signals itself. `List`/`SeqState` are needed when
  structural operations are performed imperatively.

#### 3.6.2 `Set[T]` — membership

```nim
let tags = setOf(@[
  Tag(id: 1, name: "ui"),
  Tag(id: 2, name: "perf"),
], key = proc (t: Tag): int = t.id)

tags.len
tags.has(1)               # bool
tags.get(1)               # State[Tag]
tags.add(Tag(id: 3, name: "docs"))
tags.remove(2)
tags.updateAt(1, proc (t: var Tag) = t.name = "ui-kit")

for t in tags:
  Text(t.get().name)
```

- A set with a key; for primitives the key is the value itself
  (`setOf(@[1, 2, 3])`).
- Order is insertion order so that rendering is deterministic.
  Even if order is not needed, we still keep it in `Set`.
- `add` with an existing key is an upsert: the structure does not change,
  `State[T]` is updated; `remove` is a structural operation.
- `for t in tags` yields `t: State[T]`; the key is internal, `key` is not written.
- `has` reads the structural signal and is reactive inside a binding.

#### 3.6.3 `Table[K, V]` — key → value

```nim
let config = table[string, int](@[("retries", 3), ("timeout", 30)])

config.len
config.has("retries")     # bool
config.get("retries")     # State[int]
config.tryGet("missing")  # Option[State[int]]
config.set("backoff", 5)  # new key — structural change
config.updateAt("retries", proc (v: var int) = v += 1)
config.delete("timeout")
config.keys               # seq[K] in insertion order
config.values             # seq[V]

for k, v in config:
  Text(k & " = " & $v.get())
```

- `K` is hashable/equatable; `V` is any value with `==`.
- `set` with an existing key updates `State[V]`, the structure does not change;
  a new key is an insertion.
- `delete` is a structural operation; `updateAt` is value-only.
- `for k, v in config` yields `k: K` (a static key) and `v: State[V]`;
  `key` is not written — the table key is the identity.
- Iteration order is insertion order.

#### 3.6.4 Common

- Constructors: `list(items, key)`, `setOf(items, key = identity)`,
  `table[K, V](pairs)`. `Set`/`Table` may conflict with
  `system.set`/`std/tables.Table`; when importing — qualify or
  use aliases (`YSet`, `YTable`).
- `len` is `Computed[int]`; `has` is a `bool` reading the structure; `keys` is
  a snapshot in insertion order.
- All mutations can be grouped in `batch:` — one flush, one structural
  diff.
- `cell(seq[T])`/`cell(Table)` — snapshots and simple cases; `newState(seq)`/
  `newState(Table)` — deep stores.

### 3.7 Deep `signal`: proxies and rewriting

For a composite `T`, `newState(v)` is turned by the compiler into a store + proxy
types; the syntax remains ordinary Nim.

```nim
let todos = newState(@[
  Todo(id: 1, title: "Buy milk", done: false),
], key = proc (t: Todo): int = t.id)

todos.push(Todo(id: 2, title: "Walk dog", done: false))
todos[0].done = true
Text(todos[0].title)
Text("total " & $todos.len)
```

#### How it works

- `newState(seq[T])` → `SeqState[T]` (keyed store, §3.6) + `TRef` for the element.
  Without `key` the key is the index (stable for append/remove at the end); for
  reorder/insertions set `key = proc (t: T): K = ...`.
- `TRef` is a ref object; each field is a `FieldRef[F]` (`get/set` via the
  item signal and `updateAt`); nested objects/seqs get nested
  `ObjState`/`SeqState`.
- `newState(obj)` → `ObjState[T]` with a `FieldRef` per field; `newState(Table)` →
  `TableState`; `newState(Set)` → `SetState`.
- `newState(primitive)` → `Cell[T]`: deepness is not needed.
- `cell(v)` is an explicit `Cell[T]` for generic/imported/recursive types where
  a proxy cannot be generated.

#### Access rules

| code | meaning |
|---|---|
| `todos[0].done` in a value | `get()` of the field |
| `todos[0].done = true` | `set(true)` of the field |
| `todos[0] = newTodo` | `updateAt(0, ...)` |
| `todos.push/add/remove/move` | structural operation of the store |
| `todos.len/has` | store API + `get()` |
| `todos.get()` / `todos.set(v)` | snapshot / diff |
| `for t in todos` | proxies/signals (§5.3) |

- `let t = todos[0]` is a proxy, not a copy; `t.done = true` changes the store.
  `let d = todos[0].done` is a `bool` snapshot; for a reactive field keep the
  proxy (`let t = todos[0]`) or a `computed`.
- Passing to `proc (t: Todo)` — `toValue` (snapshot); mutations of the parameter
  do not affect the store (Nim value semantics).
- Dynamic access by runtime name/key — store API only; there is no runtime
  Proxy/reflection in Nimony.
- `todos = newSeq` is sugar for `set(newSeq)`; field/element — for
  `update`.

#### Boundaries

- Proxy types are generated for a specific `T`; generic/imported/
  recursive/cyclic types — via `cell`/`Store`.
- Depth — fields, elements, nested seq/Table/Set; very deep graphs are
  better folded into a store.
- Cost: N `FieldRef`/item signals and a diff on `set`; for small objects
  `Cell` is cheaper and more predictable.
- Compiler layer: the state pass generates the store/proxy; `get/set`
  sugar is split between the syntax pass and the post-sem state pass (§6.9). If a proxy field is not a `FieldRef`, a type plugin
  can intercept access.

### 3.8 Depth, recursion, and generator limits

Syntax depth is unlimited: `a.q.x`, `a[0][0][0].q.x`,
`node.children[0].x` are just chains of store/`FieldRef`. The limit is the
type generator, not the runtime.

#### Type mapping

| `T` | `Proxy[T]` |
|---|---|
| primitive | `FieldRef[T]` / `Cell[T]` |
| object | `TRef` (fields — `FieldRef` or nested stores) |
| `seq[U]` | `SeqState[U]`; `[]` returns `Proxy[U]` |
| `Table[K,V]` | `TableState[K,V]` |
| `Set[U]` | `SetState[U]` |
| `Option[U]` | `FieldRef[Option[U]]` — leaf, we do not go inside `Some` |
| `ref`/`ptr` | `RefField[T]`; deep tracing stops |
| tuple/array/variant/distinct | according to support, or fallback |

`Proxy[T]` is memoized: one generated type per `T`. Recursive
types via `seq`/`ref` produce finite ref types:
`NodeRef.children: SeqState[Node]` and `SeqState[Node][]: NodeRef`.
Runtime cycles from `ref` are not expanded infinitely: the boundary is a `ref`
field (identity/snapshot).

Verified manually (`tests/ui/tdeep.nim`): `object→object→field`, three
levels of `seq`, and a recursive `Node (Node → seq[Node] → Node)` —
compile and update. Compiler sugar (`a.q.x = 10`) is work for the
generator, not the runtime.

#### Generator policy

- Budget: a maximum of generated proxy types and a maximum depth (for example,
  64 types / 16 levels; configurable). On exceeding it — a compile-time
  error suggesting `cell`/an explicit `Store`.
- Generic `T`: only monomorphized instances; otherwise `cell`.
- Imported types: if the fields are visible to the generator; otherwise `cell`/`Store`.
- Variant objects: fields of all branches, or a fallback.
- `ref`/`ptr`: deep tracking does not go through a reference; the field is a `RefField`
  (get/set of a snapshot/reference).
- Compile time, binary size and memory — measure; choose the cap by
  benchmark.

#### Snapshot consistency

- Field stores are the source of truth; `get()` is a computed snapshot reading
  nested stores. Updating a leaf invalidates the parent snapshot but
  does not recompute bindings that do not read it.
- `set(T)` diffs nested stores (or replaces their values).

#### Verification matrix

| case | expectation |
|---|---|
| `A.q.x` | works |
| `seq[seq[seq[A]]][0][0][0].q.x` | works |
| object → seq → object → seq → … | works as long as the type is finite |
| recursive `Node` with `children: seq[Node]` | works via recursive ref types |
| `ref` cycle | stops at `ref`/identity |
| generic `T` | fallback if not monomorphized |
| imported fields | if visible to the generator |

#### Depth benchmark

Generate types `A0…A16`, nested `seq` of depth 1…8, a recursive
`Node`; measure compile time, binary size, leaf update latency
and memory; pick the default cap by the knee.

### 3.9 `Option[T]`

We use `std/options`: `Option[T]` — `Some(T)`/`None`, structural
equality; `none[T]()` requires `HasDefault` (works for value objects;
for ref/non-default — a value object or `cell`).

```nim
let user: State[Option[User]] = newState(none[User]())
user.set(some(User(name: "Ann")))

if user.get().isSome:
  Text(user.get().get().name)
```

- A signal can hold an Option; `set` compares structurally, `some/none`
  notify as usual.
- `Option` is a **leaf** for a deep signal: a field/element is `FieldRef[
  Option[T]]`; inside `Some` deep tracing does not go (None may be
  absent). For fields — `get()`/`map`/`orElse`.
- There is no optional chaining. Instead of `user.data.name`:
  ```nim
  data.get().get().name
  # or
  data.map(proc (u: User): string = u.name).get("")
  ```
- `Option` branches: `if data.get().isSome:` → `uiWhen`; or `Match`
  (planned: `Some(u): ... / None: ...`).
- Helpers: `map/flatMap/filter/get(default)/orElse`; in a binding they yield
  a `Computed`, and `Option` equality cuts off redundant writes.

### 3.10 `Resource[T]` — sum of states

`Resource` is not three fields `data/state/error`, but a single sum value:

```nim
type
  ResourceState* = enum resLoading, resReady, resError

  ResourceValue*[T] = object
    case kind*: ResourceState
    of resLoading:
      discard
    of resReady:
      data*: State[T]
    of resError:
      error*: State[ErrorInfo]

  Resource*[T] = ref object
    value*: State[ResourceValue[T]]
    # private: fetcher, generation, refresh, arg
```

- `Loading` carries no data; `Ready` — data; `Error` — an error.
- `data`/`error` are signals **inside** the branches. `mutate` updates Ready data
  without changing `kind`, so the branch is not recreated; changing `kind`
  recreates the branch.
- `case user:` expands into `uiCase` (see §5.2.1); payloads
  arrive as `Computed`/`Signal`.
- `Option` is no longer needed for the Resource state; Option remains for
  arbitrary optional data (§3.9).

API:

```nim
proc resource*[T](fetcher: proc (): T {.passive.}): Resource[T]
proc resource*[T, A](fetcher: proc (a: A): T {.passive.};
                     arg: A): Resource[T, A]
proc refetch*[T](r: Resource[T])
proc refetch*[T, A](r: Resource[T, A]; arg: A)
proc mutate*[T](r: Resource[T]; v: T)
proc mutate*[T](r: Resource[T]; f: proc (v: var T))
```

The implementation with an argument is called `ArgResource[T, A]`: Nimony does
not support two generic types with the same name and different arity (issue
#26), so `Resource[T]` and `Resource[T, A]` do not compile in one module. The
constructor syntax is preserved:

```nim
let user = resource(proc (id: int): User {.passive.} =
  fetch("/api/users/" & $id), userId)
refetch(user, nextId)
```

Example:

```nim
let userId = newState(0)

let user = resource(proc (): User {.passive.} =
  fetch("/api/users/" & $userId.get()).awaitJson(User))

case user:
of Loading:
  Spinner()
of Error(error):
  ErrorComponent(error)      # error: Computed[ErrorInfo]
of Ready(data):
  UserCard(data)             # data: Computed[User]

user.mutate(User(name: "Optimistic"))
user.refetch()
```

Semantics:

- `resource` starts a passive effect in the current scope. The sources are
  everything the fetcher read via `.get()` (`userId`), plus `refresh`/`arg`.
- Transitions: `Loading → Ready/Error`; `refetch` → `Loading` (the Ready branch
  is deleted) → Ready/Error; `mutate` → Ready.
- On start — a generation; a late response is applied only if it is
  current (source change/refetch/dispose). Races are cut off.
- `mutate(v)`: if Ready — update the data signal; otherwise assemble Ready with
  a new data signal. `mutate(f)` — Ready only; otherwise a no-op.
- `refetch(arg)` for `Resource[T, A]`: arg is a signal; the fetcher receives it;
  source signals are tracked anyway.
- fetch/parse errors are caught as `ErrorCode` and put into the `Error` branch
  (`State[ErrorInfo]`).
- The owner is the creating scope; dispose cancels the effect and ignores late
  responses. Passing `Resource` to children is a handle; `mutate/refetch` are available.
- `isLoading`/`isError` are optional derived helpers; the main
  way is `case`.

**Current implementation.** `ResourceValue[T]` contains only `kind`, while
`data: State[T]` and `error: State[ErrorInfo]` live on `Resource[T]` and are
created on the first transition into the corresponding kind. The reason is
that the JS backend loses `State[T]` placed inside a variant object
after a passive effect restart (issue #24). The external semantics are the
same: `mutate` updates `data` without changing `kind`, `Loading → Ready/Error`
recreates the branch, late responses are cut off by generation.
## 4. DOM and elements

### 4.1 `E`, `Node`, fragments, and levels

- `E` is a handle to a rendered fragment: nodes + scope.
- A fragment is bounded by anchors (comments); a keyed list moves the range
  as a whole.
- `Text(s)` creates a text node.
- The auto-wrapper for `proc ...: E` creates the component's build-once scope,
  fragment anchors, and returns `E`.

Levels:

```
E / Node
 └─ ElE(tag, children)             runtime: node + children, low level
    └─ c.Tag.class: children       the only user-facing syntax
       └─ proc …: E {.ui.}         components
```

- User tags are written only through `c.Tag.class:`; tag and class names are
  arbitrary, the tag list is not fixed.
- `c` is not a runtime object and not a `Props` record: the `{.ui.}` syntax pass
  pragma parses the untyped AST and emits `ElE`/`addClass`/`attr`/`addStyle`/
  `setProp`/`on`.
- `ElE`/`El`/`Text` are low-level runtime primitives for the library,
  templates, and JS tests; application code uses `c`.
- User components are ordinary `proc …: E {.ui.}` with typed parameters; a
  component is called as `Card(...)`.

### 4.2 Attributes, classes, styles, and properties

Inside a `c` block, operators go on separate lines and combine freely:

| form | semantics |
|---|---|
| `c.Div.cls1.cls2:` | classes `cls1 cls2` |
| `cls(name)` | dynamic class from `State[string]`/`string` |
| `cls.active(cond)` | class `active` when `cond` is true |
| `attr.data_id("x")` | attribute `data-id="x"` |
| `attr.disabled(true)` | bool attribute: `true` presence, `false` remove |
| `css.background_color("#eee")` | inline style |
| `css.font_size(10, "px")` | `font-size: 10px` |
| `prop.value(name)` | DOM property |
| `onClick(e): body` | event |
| `onMount(e: El): body` | hook after creation |
| `onCleanup(): body` | hook on dispose |

Names:

| written | result |
|---|---|
| `cls1`, `btn_default` | `cls1`, `btn-default` |
| `MyElement` (tag) | `my-element` |
| `data_id`, `aria_label` | `data-id`, `aria-label` |
| `background_color`, `backgroundColor` | `background-color` |

- Chains: `attr.disabled(true).aria_label("Click")`,
  `css.display("flex").gap("8px")`, `prop.title("x").tabIndex(3)`.
- Values are dispatched by `setAttr`/`addStyle`/`setProp` overloads:
  `string`, numbers, `bool`, `State[T]`, `Computed[T]`.
- An expression with `.get()` is evaluated once; a binding appears when a
  signal/computed sits in the value position.

Children — only via block/indentation:

```nim
c.Div.card:
  attr.data_id("c1")
  css.display("flex").gap("8px")
  c.Span.title:
    item.title
  c.Span.muted:
    item.subtitle
  c.Button.btn:
    onClick(e):
      open.set(true)
    "Open"
```

- `(...)` — only operator arguments; the element is opened with `:`.
- children — by indentation; a single text/expression — after `:`.
- no `Div(..., Span(..., Text(...))))`.

### 4.3 Text

`Text(expr)` creates a text node and a binding. In a `c` block a bare
string/numeric literal or expression becomes text automatically:

```nim
c.Span.title:
  item.title
c.Div.empty:
  "Nothing here"
```

`Text(...)` remains the explicit runtime form.

### 4.4 Events and lifecycle

- `Event`: `stopPropagation`, `preventDefault`, `target`, `currentTarget`,
  `clientX/clientY`, `pointerId`, `key`, ...
- `onClick(e): ...`, `onInput(e): ...`; several handlers are
  composed.
- `onMount(e: El)`/`onCreated(e)` — after the node is attached; once per
  build; post-order (children before the parent).
- `onCleanup()` — on scope dispose, not when a node is moved.
- `.get()` inside handlers does not subscribe the computation.
- `onCreated` is the only imperative hook. `also`/`Mod`/`modify` are not
  part of the API.
- After-the-fact mutation of `E` (`e.attr`, `e.addClass`) is static and not
  reactive; for reactivity use `Signal`/`Computed` in the value.

### 4.5 Handles and DOM operations

`E` (and `Node`) expose a minimal set:

```nim
E:
  node: Node
  attr(name, value)
  addClass(name)
  setStyle(prop, value)
  on(event, handler)
  onCreated(handler)
  onCleanup(handler)
  appendChild(child)
  rect(): Rect
  capture(pointerId)
  release(pointerId)
  focus()
  scrollIntoView()
```

`onCreated` receives `E`; `e.currentTarget` in an event is the `E` of the
element the handler is attached to. After-the-fact calls are static; reactive
updates go through bindings.

## 5. DSL

### 5.1 Component

```nim
proc Card(title: string; children: proc (): E): E {.ui.} =
  c.Div.card:
    Text(title)
    children()
```

- Any `proc ...: E` is a component. The compiler **itself** wraps the body:
  creates a fragment (two anchors), a build-once scope, makes the fragment the
  current parent, and executes the body. All top-level `c`/`Text`/components
  are appended to the fragment immediately; the fragment's `E` is returned
  outward.
- Neither `component:` nor `fragment:` is written in the source.
- `signal/computed` inside are created once; the body is not restarted on
  updates (see §3.5).
- `children` is a reserved name for the direct contents of a call
  (`Card(): c.Div: ...; c.Div: ...`), see §5.5.
- `onCreated`/`onCleanup` at the component level belong to its scope.
- A component returns `E`; it can be mounted, put into `seq[E]`,
  used as a dynamic page, or called as `proc(): E`.
- `return`/`result` are not used in a component body: the result is always
  the fragment. Early exit — via `if`/`slot`.
- All `proc ...: E` are considered components. If you need a function that
  returns an already-built `E` without creating a fragment, make it a
  `template` or a separate wrapper type.

### 5.1.1 The `c` combinator (frameorc-style)

The only syntax for native tags is a single identifier `c`, a chain
through the dot and an indentation block. The tag does not have to be in the
list of known ones:

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

Rules:

- a segment starting with an uppercase letter is a tag (`Div` → `div`,
  `MyElement` → `my-element`); the last such segment wins;
- a segment starting with a lowercase letter is a class (`cls1`, `btn_default`
  → `btn-default`); several classes are joined with a space;
- `attr.name(value)`/`attr.name.value(value)` — attributes; `data_*`/
  `aria_*` and underscores turn into dashes; the chain
  `attr.disabled(true).aria_label("Click")` sets both attributes;
- `css.name(value)` — inline style; names are converted to kebab-case,
  several arguments are joined (`font_size(10, "px")` → `10px`);
- `prop.name(value)` — DOM property, the name is unchanged; the chain
  `prop.title("hello").tabIndex(3)` sets both properties;
- `onClick(e): body`, `onInput(e): body` — event; the parameter gets the type
  `Event`; `onMount(e: El)`/`onCreated` → `onCreated`, `onCleanup()` →
  element cleanup;
- `on.click(handler)` — the frameorc form of an event;
- bare strings/values — `Text(...)`, a nested `c.Tag` — a child.

The named-attrs syntax `Div(class = "x"):` is removed: `c` is the only
user-facing syntax, the tag list is not fixed, `Props` records are not
needed.

### 5.2 `if`

```nim
if board.get().todos.len == 0:
  Text("empty")
elif loading.get():
  Spinner()
else:
  List()
```

In a component/element body, an `if` with a reactive condition compiles to
`uiWhen`:

```nim
uiWhen(computed(proc (): bool = board.get().todos.len == 0),
       proc () = Text("empty"),
       proc () =
         uiWhen(computed(proc (): bool = loading.get()),
                proc () = Spinner(),
                proc () = List()))
```

- The condition is `Computed[bool]`; the branches are scopes.
- A branch is built once per activation; inside it only bindings are
  updated. Changing the condition = dispose the old branch (cleanup + DOM) and
  build the new one.
- State declared in a branch lives with the branch; to preserve it, hoist it
  into the component or use `Show` (hide, not remove).
- A static condition (no signals) remains an ordinary `if` without a scope.

### 5.2.1 Reactive `case` and sum types

A `case` over a `Resource`/variant signal is `uiCase`/`uiSwitch`, not an
ordinary Nim `case`:

```nim
case user:
of Loading:
  Spinner()
of Error(error):
  ErrorComponent(error)
of Ready(data):
  UserCard(data)
```

- The `Loading/Ready/Error` branches are sugar for `resLoading/resReady/resError`.
- The selector is `kind`/enum; when the branch changes, the old branch is
  disposed and the new one built.
- The payload is bound as `Computed[T]`/`State[T]`; inside Ready,
  `data.get()`.
- Inside a single branch (`Ready`), updating `data` does not recreate the
  branch: only bindings that read `data` are updated.
- `else` — fallback; a static `case` over an ordinary value remains a
  Nim `case`.
- A `case` expression (a value) is not transformed; statement only.
- `break`/`continue`/`return` inside a branch are forbidden (a branch is a
  closure/scope), as for `if`/`for`.

Generic variant:

```nim
type Shape = object
  case kind: ShapeKind
  of circle: r: float
  of rect: w, h: float

let shape = newState(Shape(kind: circle, r: 2))

case shape:
of circle(r):
  Text("r=" & $r)
of rect(w, h):
  Text("w=" & $w & " h=" & $h)
```

Lowering:

```nim
uiCase(computed(proc (): ResourceState = user.value.get().kind),
  of Loading: proc () = Spinner(),
  of Error:   proc (error: Computed[ErrorInfo]) = ErrorComponent(error),
  of Ready:   proc (data: Computed[User]) = UserCard(data))
```

A branch is a build-once scope; payloads are computed slices of the source
signal; a `kind` change is dispose/build, a payload change is bindings only.

`case` sugar is handled by the **syntax pass**: `case user:`/`case shape:`
over a handle/state otherwise does not type-check (case requires an ordinal
selector). The same pass lowers it to `uiCaseBlock`; the canonical form is `case
user.value.get().kind:` with payloads via `get()`.

### 5.3 `for`, `key`, and collections

`for` is sugar; the form depends on the source.

**Deep store (`SeqState`/`List`)** — the key is already in the store:

```nim
let todos = newState(@[
  Todo(id: 1, title: "Buy milk", done: false),
], key = proc (t: Todo): int = t.id)

for t in todos:
  Text(t.title)            # t: TodoRef, t.title: FieldRef[string]
```

- `t` is a `TRef` proxy; fields are `FieldRef`; `Text`/attr sugar reads them.
- `key` is not written: the store holds the key; duplicates/key change is a
  dev error/row recreation.
- `for i, t in todos` — `i: State[int]`.
- For a `seq` of primitives the element is a `FieldRef`/`Signal` of the
  corresponding type.

**Raw `seq` / `State[seq]` / `Computed[seq]`** — the key is mandatory:

```nim
let todos: State[seq[Todo]] = ...

for i, t in todos:
  key t.get().id
  Text(t.get().title)
```

- `t: State[Todo]`; `key` — as the first line of the body.
- For a static `seq`, `key` is optional (identity by index).

**Set:**

```nim
for tag in tags:
  Text(tag.name)           # tag: TagRef/FieldRef
```

- `tag` is a proxy/`State[T]`; `key` is not written — identity is set by the
  set key.

**Table:**

```nim
for k, v in config:
  Text(k & " = " & $v)     # v: FieldRef/ValueRef
```

- `k: K` is a static key, `v` is `FieldRef[V]`/`State[V]`; `key` is not
  written.

General rules:

- The body is a render closure that is called **per element**, not a Nim loop.
  The closures capture the parameter (`t`/`tag`/`v`), not the loop variable.
- `break`/`continue`/`return` inside such a `for` are forbidden: the body is a
  closure.
- Render runs once per key; content updates go through
  per-key/field signals, not through a repeated render call.

Update semantics:

1. Key/order/length changed — `ForEach` creates, moves, and deletes DOM
   ranges; existing rows are not recreated.
2. Content changed with the same key — the per-key/field signal is updated;
   only what reads it is redrawn.
3. A row reads `todos.get()` (the whole store) — a subscription to everything,
   knowingly more expensive; `t.title`/`t.get()` — only to the field/element.

Runtime forms (low level):

```nim
forEachList(todos,
  same = proc (a, b: Todo): bool = a.id == b.id,
  key = proc (t: Todo): string = $t.id,
  render = proc (t: Todo): E = Row(t))

forEachSet(tags, render = proc (t: State[Tag]): E = Text(t.get().name))

forEachTable(config, render = proc (k: string; v: State[int]): E =
  Text(k & " = " & $v.get()))
```

The deep store gives a render proxy (`TRef`); the low-level forms use
`Signal`.

### 5.4 Expressions and computed lifting

- In a value position (text, attr, `if`, `for key`) an expression is wrapped
  in `Computed`; the binding subscribes to it and updates only its own
  target.
- Canonical code uses `.get()` explicitly:
  `Text("todo: " & $todo.get().title)`, `if todos.get()[0].done:`.
  Writing `todos[0].done` without `.get()` is possible only as compiler
  sugar; we do not use it in portable code.
- The compiler may insert `.get()` for a "bare" signal/`FieldRef` in a
  value position (`variant = state1` → `state1.get()`,
  `todos[0].done` → `get()`) and `.set()`/`.update()` for assignment
  (`open = false`, `todos[0].done = true`, `count += 1`); this is sugar, not
  a mandatory rule. For deep `signal` see §3.7.
- Ordinary code between DSL calls (`var x = 10 * a`) runs at
  build time; if it contains `.get()`, the nearest scope subscribes and is
  redrawn as a whole. For precision — `computed`/`effect`.

### 5.5 Components with slots

Slots are ordinary proc parameters. The reserved name **`children`**
receives all call contents that are not written as `slot name:`.

```nim
type
  Slot0 = proc (): E
  Slot1 = proc (arg: int): E

proc Card(header: Slot0; action: Slot1; children: Slot0): E {.ui.} =
  onCreated(e):
    e.classes = "hello"
  header()
  action(10)
  children()
```

A call without `slot`:

```nim
Card():
  c.Div:
  c.Div:
```

lowers to:

```nim
Card(children = proc (): E =
  c.Div:
  c.Div:)
```

A mixed call:

```nim
Card():
  slot header:
    Text("header")
  slot action(n):
    Text("action " & $n)
  Text("main")
  Text("main 2")
```

→

```nim
Card(
  header = proc (): E = Text("header"),
  action = proc (n: int): E = Text("action " & $n),
  children = proc (): E =
    Text("main")
    Text("main 2"))
```

Rules:

- `children` is a reserved name; the component parameter is
  `children: proc (): E` (no arguments).
- Everything at the top level of the block that is not `slot name:` goes into
  `children` in the original order.
- `slot name:` is collected into a named argument; the name must match a
  component parameter.
- `slot children:` is allowed and merges with the direct contents in the
  original order (equivalent to the direct contents).
- If a component does not declare `children` but the call has direct
  contents — compile-time error.
- If a component declares `children` but there are no contents, an
  empty `proc (): E` is passed, so the component signature does not require
  a mandatory argument.
- Two `slot`s with the same name — error.
- Each slot is an ordinary `proc(): E`/`proc(arg): E`, so it is also a
  component: the body is wrapped into a fragment; a slot call creates a new
  scope/DOM.
- DOM order is determined by slot calls in the component body, not by the
  order in the call.
- Native elements are written via `c`; components use `children`
  by default if the signature declares it.

### 5.6 Context

```nim
type ChartData = object
  rows: seq[Row]

let ChartCtx = context[ChartData]()

# low-level template: El is a runtime primitive, not the user-facing DSL
template Chart(data: ChartData; body: untyped) =
  El("svg"):
    provide(ChartCtx, data):
      body

template Grid() =
  let chart = use(ChartCtx)
  El("g"): discard

Chart(radar360):
  Grid()
  Line("peer", ...)
```

- `provide` is a dynamic extent for the duration of rendering.
- Every scope created inside remembers the context chain; restarting a
  scope/branch/list restores it.
- `use` without a provider is an error (`panic`).
- Async resumption restores the context together with the scope.

### 5.7 Dynamic components

```nim
let page = newState(proc (): E = Page1)

c.Div:
  Dynamic(page)
  c.Button:
    onClick(e):
      page.set(Page2)
    Text("next")
```

- `Dynamic(page)` creates a child scope, subscribes to `page.get()`,
  calls the component; on change — dispose the old one, render the new one.
- `page` is `State[proc (): E]`; parameters are passed via a closure:
  `proc (): E = Page2(id)`.
- The sugar `page()` (a signal call) can be done by a plugin; canonically —
  `Dynamic(page)`.

### 5.8 State lifting and props

A signal is passed into a component as an ordinary parameter. This is not a
copy: the child receives the same handle and can read and change the owner's
state.

```nim
proc Dialog(open: State[bool]): E {.ui.} =
  if open:                     # -> open.get()
    Card():
      c.Button:
        onClick(e):
          open = false         # -> open.set(false)
        Text("Close")

proc App(): E {.ui.} =
  let open = newState(false)
  Dialog(open)
  c.Button:
    onClick(e):
      open = true              # -> open.set(true)
    Text("Open")
```

Without sugar, the same component:

```nim
proc Dialog(open: State[bool]): E {.ui.} =
  if open.get():
    Card():
      c.Button:
        onClick(e):
          open.set(false)
        Text("Close")
```

Rules:

- The signal **owner** is whoever created it (`App`). The child does not own
  the signal, does not dispose it and does not recreate it; `.set/.update`
  changes the value for all subscribers.
- In the child's body, reading `open` in `if`/attr/text is `open.get()` inside
  a binding/computed; the component body is not restarted.
- Writing `open = false`/`open += 1` is sugar for `set`/`update`; it also works
  for a `let` signal (the reference does not change). The sugar is applied
  **before sem**: `let open` + `open = ...` is otherwise a type/let error that
  the post-sem state pass rewrites it; explicit `.set` also works.
- `Computed[T]` is a read-only prop: `.get()` is allowed, `.set`/assignment is
  a compile-time error. A read-only view of a signal is `readonly(s): Computed[T]`.
- A composite prop can be passed as `State[T]`/`SeqState[T]`: the child
  writes `todos.push(...)`, `todos[0].done = true`; this is the same store, not
  a copy.
- `Resource[T]` is a handle sum (`Loading/Ready/Error`): the child does
  `case user:` and reads the payloads; `mutate/refetch` are available; the owner
  and scope belong to the creator.
- Native tags (`Div`, `Img`, `Input`, `Video`, …) do not take
  `Props` records: their attributes are typed by value (`string`,
  `int`, `bool`, `State[T]`), and `data-*`/`aria-*` are open. `Props`
  are justified only for user components.
- A user component with arbitrary attributes takes
  `attrs: AttrList`; typed props remain ordinary `proc` parameters.
- After-the-fact `Component().cls3` is not supported: `E` is a fragment, not
  necessarily a single element. A component takes `class`/`attrs`/`children`
  explicitly.
- An ordinary `T` is a snapshot: changes will not arrive until the parent
  recreates the component or passes a signal.
- `List`/`Set`/`Table` are handles too: the child can `add/remove/updateAt`,
  the structure is updated in all `for`s.
- Callbacks (`onClose: proc()`) are a one-way alternative; a signal is two-way.
  For controlled components (Dialog) a signal is more convenient; for "event
  outward" — a callback.
- **State lifting:** if several components need the state, create a
  signal in their common ancestor and pass it down. For a deep tree — the same
  signal in `provide`/`use` (§5.6), so you do not thread it through every
  layer.
- Forms: `c.Input: prop.value(name); onInput(e): name = e.value` —
  manual wiring; `bind(name)` — sugar that sets value/checked and
  updates the signal on input.
- If the state must survive closing the dialog, `if open:` is done
  **inside** `Dialog` (as above): the Dialog body is build-once, the Card
  branch is removed/created. With `if open: Dialog()` outside, the Dialog is
  destroyed/created anew and its local state is reset.
- Passing into `Dynamic`/a portal: the signal must belong to a common owner
  (hoist it up), otherwise after the owner is disposed a dangling handle
  remains.

Props table:

| parameter type | read | write | reactivity |
|---|---|---|---|
| `T` | value | no | snapshot, only on recreation |
| `Cell[T]`/`State[T]` | `.get()` | `.set/.update` | bindings on both sides |
| `State[T]` (deep) | `.field`/`.get()` | `.field = v`/`.set` | per-field |
| `Computed[T]` | `.get()` | no | computed |
| `Resource[T]` | `case`/`.kind` | `.mutate/.refetch` | branches |
| `List/Set/Table` | store API | structure/value | keyed |
| `proc(...)` | call | — | event/callback |

A write to a signal from an event is batched: several `open = ...` produce one
flush. A write from an `effect` goes through `set/update`, with the usual
restart rules.

### 5.9 Ordinary Nim

Inside the body `let/var`, `if/for/while`, `try`, `defer`, local
procedures, generics are available. Restrictions:

- `return` in a component/DSL closure body does not cross the component
  boundary: do early exit via `if`/`Else`.
- `break/continue` in a DSL `for` are forbidden (§5.3).
- `var` changes of ordinary variables are not reactive; only
  signals are reactive.

### 5.10 Declarative dragging

`drag.nim` implements the model-driven part of D2: the application enumerates
the reachable model states and their positions, the controller picks the nearest
target by pointer, and drop applies its state.

```nim
type
  DragTarget*[S] = object
    state*: S
    pos*: Point

  DragBehavior*[S] = object
    targets*: seq[DragTarget[S]]
    farTargets*: seq[DragTarget[S]]
    farRadius*: float
    floating*: bool

  DragController*[S] = ref object
    pointer*: State[Point]
    active*: State[bool]
    target*: State[int]
    far*: State[bool]
    targets*: seq[DragTarget[S]]
```

- `closest(targets).whenFar(fallback, radius).withFloating()` assembles the
  behavior; `start(drag, behavior, p)`, `move(drag, p)`,
  `finish(drag)`, `cancel(drag)`, `hasDrop(drag)`, `chosen(drag)`.
- Target positions come from speculative rendering: candidate states are
  rendered in a hidden DOM host, the dragged element is measured with
  `getBoundingClientRect` (browser) or the small CSS layout pass (C tests),
  and the measured centers become `DragTarget` positions. Plans no longer
  hard-code row/column coordinates.
- The `closest`/`between`/`whenFar`/`withFloating` operators are implemented as
  `DragBehavior`; `between` currently picks the nearest target, visual
  interpolation is the next layer. `vary`, `dropTarget`,
  `switchToStateAndFollow` are not done yet.
- During a drag the app can assign `previewState(start)` to the model state;
  CSS reflows the live elements into the candidate arrangement and a
  fixed-position ghost follows the pointer. Drop keeps the chosen state;
  cancel restores the start state. No positions are interpolated in
  application code.
- Example `examples/ui/kanban.nim`: a card builds target states
  "task inserted into each column/position", measurements come from hidden
  renders, drop applies the chosen state, ghost and `cls.drop(...)` give a
  preview; columns are reordered the same way.
- Example `examples/ui/rows.nim` repeats the rows/tiles from Dragology:
  `closest(...).whenFar(stateWithout).withFloating()`.
- Handlers in a loop must be moved into a per-element component
  (`CardView`): Nimony captures the loop variable by reference (issue #2).

### 5.11 Speculative rendering

`spec.nim`:

```nim
SpecView[S] = object
  state: S
  root: Node
  scope: Scope

speculateOne(state, render, frame) -> SpecView
speculate(states, render) -> seq[SpecView]
rect(view, selector) -> Rect
speculativeTargets(states, render, selector, origin) -> seq[DragTarget[S]]
newDragZone(model, container, render, statesOf, selector, controller, snap)
dispose(view)
```

- `render` runs in a hidden host via `beginRoot`, so the live UI/scope is
  not touched;
- the browser host is attached to `document.body` with `visibility:hidden`,
  which keeps CSS layout active; `bounds` reads `getBoundingClientRect`;
- the C test DOM runs a small CSS layout pass (block/flex, padding, gap,
  absolute/fixed, translate);
- `rect(view, selector)` returns the measured border box;
- `speculativeTargets(states, render, selector, origin)` renders each
  candidate, measures the selected element, and returns `DragTarget`s whose
  `pos` is its center. `origin` is the live render root; its rect is added to
  the host-relative measurement, so browser targets and pointer events share
  the client coordinate frame. The same rect sizes the hidden host
  (`createHiddenHost(frame.w, frame.h)`), which is essential when a sibling
  panel or a scrollbar constrains the live flex layout: the candidate host
  must have the same frame, not shrink-wrap.
- `DragZone[S]` packages the live model, container, view renderer, `statesOf`
  and `selector` callbacks, controller and snap radius. `start(zone, p)` is the
  only place that builds and measures candidate targets; `move(zone, p)`
  updates the target and FLIPs only when it changes; `drop(zone)` finishes and
  starts the grabbed element at the pointer/ghost center. Applications no longer
  hand-roll `speculativeTargets`, capture/`flush`/play calls for every drag
  kind.

### Layout animation and overlay

`layout.nim` is the FLIP layer:

```nim
# inside flush, while a DragZone is armed:
beginLayout()   # captureLayout(root, ".card, .col", token)
drain()         # mutate the model / re-render
endLayout()     # playLayout(root, ".card, .col", token, 160)
```

It records the old border boxes (position and size) of elements with ids, then
animates `transform` and `width`/`height` linearly to the new boxes, so columns
grow/shrink smoothly when cards enter or leave. The hook lives in `flush`:
while a `DragZone` is armed, `beginLayout` captures before the drain and
`endLayout` plays after it, so any `state.set()` is animated without explicit
calls at the mutation site. Animation cleanup saves and restores each element's
original inline width/height/box-sizing, so view styles are never erased on
reused nodes. `playDropLayout` additionally
starts the grabbed element at the pointer with the ghost's size and scales it
into its final box; `hideDropContent` hides its children during that stretch.
Each `DragZone` chooses `animSelector`: card drags use `.card, .col`, column
drags use `.col` plus `hideDropContent = true`, so a column reorder animates
only the column box and never the cards inside it. It is a no-op on the C/test
backend. `overlay.nim` renders
the measured targets and the line graph between
them as an SVG overlay (`setDragOverlay(true)`); it is debug-only and never
affects layout.

`withSnap(radius)` gives the behavior a sticky current target: the controller
does not switch until the pointer leaves the radius around the current target.
`between` still selects the nearest target; FLIP animates the transition
between two preview layouts, while true multi-state interpolation remains the
next layer.

### 5.12 Motion core

`motion.nim` is the basis of declarative animations:

```nim
bindMotion(e, motionValues(x, y, scale, opacity)) -> Motion
m.animateTo(target, tween(0.25) | spring(100, 15))
m.tick(dt) -> bool
stagger(index, each) -> float
```

- tween and spring interpolation over four properties;
- `Motion` writes style via `State[string]`, so the update goes through a
  standard binding;
- `easeLinear`/`easeOut`/`easeInOut`;
- so far no variants/exit/AnimatePresence, shared layout (`layoutId`),
  keyframes, and scroll hooks; these are layers on top of `spec`/`motion`.
## 6. Asynchrony

```nim
effect:
  let data = awaitJson(fetch("/api/todos"))
  todos.replace(data.todos)
  onCleanup:
    cancelRequests()
```

- `effect` may call `.passive` procedures; when the runtime stops, it remembers the scope/computation and restores them on resume.
- `.get()` after `await` subscribes the same effect.
- If a signal changed while the effect was waiting, the effect restarts; the old coroutine is cancelled (its continuation is ignored).
- `dispose`/cleanup remove the coroutine; a promise after dispose does nothing.
- `delay()` inside library `await` helpers — as a separate statement (compiler limitation, see `docs/nimony-issues.md`).

### 6.9 Plugin-native compilation

The implementation uses two Nimony plugin passes; `std/macros` is not involved.

**Pass 1 — `{.ui.}` syntax.** `yith/uiblock` declares a template plugin:

```nim
template ui*(def: untyped) {.plugin: "uiblock_plugin".}
```

`proc View(): E {.ui.} = ...` and `ui: ...` both invoke it with the untyped
definition. It emits ordinary source-level runtime calls:

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

`if`/`elif`/`else` become nested `uiWhen` calls, `for` becomes `uiLoop`,
`key expr` becomes a `uiKey` marker, `case user:` over a resource becomes
`uiCaseBlock`, component calls gain `children`/`slot` arguments. The body is
wrapped in a build-once `uiFragment`.

Pass 1 deliberately leaves `{.state.}` untouched, so the output is valid Nimony
where a state variable is still a plain value. Each routine also emits
`var yithHook…: PluginHook`; `PluginHook` is a nominal type carrying the
state-plugin annotation, and Nimony deduplicates type plugins per module.

**Pass 2 — state.** The state plugin receives the semchecked module and rewrites
state declarations and their uses:

```nim
var name {.state.}: string = state("light")
name = name & "!"
```

becomes

```nim
var name: State[string] = newState("light")
name.set(name.get() & "!")
```

It rewrites reads, assignments, compound assignments and mutating methods,
creates `computedExpr` for derived locals in UI routines, converts keyed loops
to `forEachList`, and keeps `Text`/attribute values reactive via the runtime
State overloads or `computedExpr`. Explicit `State[T]` handles and imported
state are recognized by their type.

`state(v)` is an identity placeholder so `var x {.state.}: T = state(v)` is
valid before pass 2. Nimony identifiers cannot begin with `_`, so the real
constructor is `newState(v)`.

A module with state but no component must enable pass 2 itself:

```nim
import yith/core
import yith/internal

stateModule()

var theme* {.state.}: string = "light"
```

There is exactly one state pragma; `{.signal.}` no longer exists.

## 8. Exact rules

### 8.1 Dependencies

- `.get()` adds an edge `computation → signal` if the computation
  is running.
- Before a computation restarts, all its old edges are removed; new ones
  are collected anew.
- Subscribe/unsubscribe is O(1); removing a scope does not scan signals.

### 8.2 Notifications

- `Signal.set`: compare (`eq`), on equality — exit; otherwise mark
  subscribers.
- `Computed`: recompute, compare; on equality do not wake downstream.
- `Effect/Binding`: runs once per flush, even if several
  dependencies changed.
- `set` inside a flush adds work to the current pass; cycle protection —
  a limit and a dev error.

### 8.3 Scheduling

- `set` from an event/imperative code → microtask flush.
- `batch:` defers the flush until the end of the block; nested batches — one flush.
- `flushSync()` — for tests and imperative code.
- Order: computeds before the effects that depend on them; effects — by
  scope depth (parent before child), so that a parent restart does not
  leave work to the child.

### 8.4 Ownership and dispose

- A parent scope owns child scopes; structural replacement (branch, key,
  `Dynamic`) removes children together with their state. The component body is
  not restarted on updates, so its state is not lost.
- Cleanup is LIFO, before DOM removal.
- Keyed list: removing a key → dispose item-scope; moving —
  the DOM range moves, the scope lives on.
- `if` branch: condition change → dispose the old branch, build a new one.
- Async: dispose cancels the coroutine; resuming into a dead scope
  is ignored.

### 8.5 Keyed diff

1. Compute the keys of the new list; a duplicate — dev error.
2. For existing keys: update the `index` signal, the `item` signal (if
   `eq` is false), move the range.
3. New keys: create item signals, a scope, call render, insert.
4. Disappeared: dispose the scope, remove the range.
5. If the keys did not change — not a single structural DOM change.
6. `Set`/`Table` use the same diff by keys: the structure is the set of
   keys (insertion order), the content is a per-key `Signal`. For `Table`
   the table key is the identity, so `key` is not written in `for`.

### 8.6 One signal — one target

If different bindings read one `Signal`, all of them are recomputed on
every change. For drag this means: the cursor position and `overIndex` must
be different signals, otherwise every row recomputes `shift` on every
pixel (string equality saves from a DOM write, but not from recomputation).

## 9. Performance

- One scope per component/branch/list item; subscriptions are an intrusive
  list, O(1).
- A binding changes one DOM node/attribute; no tree traversal.
- Keyed collections: O(n) for a structural diff, O(1) for a content change
  by key (hash lookup + per-key signal).
- `Computed` with equality cuts off cascades.
- `batch`/microtask/rAF: a series of `set` in pointermove gives one flush.
- `Resource`: one passive effect per resource; generation cuts off late
  responses; `mutate` does not make a request.
- Memory: signals, bindings and scopes are freed on dispose; list key
  tables — on removal.
- Benchmark targets: 10k rows, single cell update < 1 ms, reorder of 10k
  without recreating the DOM, ghost drag without re-rendering the list.

## 10. Example: drag & drop with a ghost

Dragging cards: the ghost follows the cursor, the other cards
move apart, the list changes order only on drop.

The example shows the **target** syntax: `List`, keyed `for`,
attribute bindings and `Dynamic` are not implemented yet (see §11); the body of the example
can be used as a checklist for the implementation.

### 10.1 Data and drag state

```nim
type
  Card = object
    id: int
    title: string
    color: string

  Drag = object
    active: bool
    id: int
    fromIndex: int
    overIndex: int
    x, y: float
    offsetX, offsetY: float
    width, height: float

const RowH = 72.0
const RowPitch = 80.0

let cards = list(@[
  Card(id: 1, title: "Design", color: "#eef2ff"),
  Card(id: 2, title: "Build",  color: "#ecfdf5"),
  Card(id: 3, title: "Ship",   color: "#fef2f2"),
], key = proc (c: Card): int = c.id)

let drag = newState(Drag())
var listTop = 0.0

proc overIndexAt(y: float): int =
  clamp(int((y - listTop + RowPitch / 2) / RowPitch), 0, cards.len.get() - 1)

proc shift(index: State[int]; d: Drag): float =
  if not d.active:
    0.0
  elif index.get() == d.fromIndex:
    0.0
  elif d.fromIndex < d.overIndex and index.get() > d.fromIndex and
       index.get() <= d.overIndex:
    -RowPitch
  elif d.fromIndex > d.overIndex and index.get() >= d.overIndex and
       index.get() < d.fromIndex:
    RowPitch
  else:
    0.0
```

`shift` reads `index.get()`; when called from a style-binding this is a subscription to
`index` and `drag`, not to the whole list.

### 10.2 List row

```nim
proc CardRow(index: State[int]; card: State[Card];
             drag: State[Drag]): E =
  let dragging = computed(proc (): bool =
    drag.get().id == card.get().id)
  let transform = computed(proc (): string =
    "translateY(" & $shift(index, drag.get()) & "px)")
  c.Div.row:
    cls.dragging(dragging)
    css.transform(transform).transition("transform 120ms ease")
    onPointerDown(e):
      let r = e.currentTarget.rect()
      drag.set(Drag(
        active: true,
        id: card.get().id,
        fromIndex: index.get(),
        overIndex: index.get(),
        x: e.clientX, y: e.clientY,
        offsetX: e.clientX - r.left,
        offsetY: e.clientY - r.top,
        width: r.width, height: r.height))
      e.currentTarget.capture(e.pointerId)

    onPointerMove(e):
      if drag.get().active:
        let oi = overIndexAt(e.clientY)
        drag.update proc (v: var Drag) =
          v.x = e.clientX
          v.y = e.clientY
          v.overIndex = oi

    onPointerUp(e):
      let d = drag.get()
      if d.active:
        batch:
          if d.overIndex != d.fromIndex:
            cards.move(d.fromIndex, d.overIndex)
          drag.set(Drag())
        e.currentTarget.release(e.pointerId)

    onPointerCancel(e):
      drag.set(Drag())
      e.currentTarget.release(e.pointerId)

    Text(card.get().title)
```

Why this is fine-grained:

- `class`/`style` are separate bindings; pointermove changes only `drag`,
  only those two attributes are recomputed. The row body is not executed.
- `Text(card.get().title)` is a separate binding; updating the card does not
  re-render the row.
- `onPointerDown/Move/Up` are events, outside tracking; `.get()` in them subscribes
  to nothing.
- `capture(pointerId)` keeps move/up on the row even when the cursor is over
  other elements.

### 10.3 Ghost

```nim
proc Ghost(drag: State[Drag]; cards: List[Card]): E =
  if drag.get().active:
    # id/offset/size are stable for one drag; the position is read in a binding,
    # otherwise it would freeze at the moment the branch was created.
    let d = drag.get()
    let card = cards.get(d.id)
    let left = computed(proc (): string =
      $(drag.get().x - d.offsetX) & "px")
    let top = computed(proc (): string =
      $(drag.get().y - d.offsetY) & "px")
    c.Div.ghost:
      css.position("fixed").left(left).top(top)
      css.width($d.width & "px").height($d.height & "px")
      css.pointer_events("none").z_index("50")
      Text(card.get().title)
```

- `if drag.get().active` — `uiWhen`: until something is dragged, the ghost is not in the DOM at all.
- The ghost is a separate component outside the list; `position: fixed` and
  `pointer-events: none`, so it does not affect layout and does not intercept
  events.
- `card.get()` — item signal; if the card changes during a drag, the ghost
  updates.

### 10.4 Application

```nim
proc App(): E {.ui.} =
  c.Div.board:
    onMount(e):
      listTop = e.rect().top
    for i, card in cards:
      key card.get().id
      CardRow(i, card, drag)

  Ghost(drag, cards)

  onCleanup:
    drag.set(Drag())
```

- `onCreated` remembers `listTop` for computing `overIndex`.
- `for` is keyed; on `cards.move` the DOM range of the row moves, the scope and
  handlers are preserved.
- `onCleanup` resets drag if the application is unmounted.

### 10.5 CSS

```css
.board { position: relative; width: 360px; }
.row {
  height: 72px;
  margin: 4px 0;
  border-radius: 10px;
  background: #fff;
  box-shadow: 0 1px 2px rgb(0 0 0 / 0.08);
  touch-action: none;              /* pointermove instead of scrolling */
  user-select: none;
}
.row.dragging { opacity: 0.25; }
.ghost {
  border-radius: 10px;
  background: #fff;
  box-shadow: 0 12px 30px rgb(0 0 0 / 0.18);
  transform: rotate(1deg);
}
```

### 10.6 What happens step by step

1. `pointerdown`: read the row rect, enable `drag`, capture the
   pointer. A ghost appears (`uiWhen`), the row gets `dragging`.
2. `pointermove`: `drag.update` changes `x/y/overIndex`. Only the ghost's
   `style` and the rows' `style` are recomputed; `shift` moves the neighbors apart
   via `translateY`. The list is not re-rendered.
3. `pointerup`: in `batch` we do `cards.move(from, over)` and reset
   `drag`. `ForEach` moves the row's DOM range; the ghost disappears,
   the transformations are reset. One flush, no flicker.
4. `pointercancel`/unmount: reset and `release`.

## 11. Status and open questions

**Implemented now:** `Signal`/`State`/`Scope`/`effect`/dispose,
`Computed`, synchronous and passive `Resource[T]`/`ArgResource[T, A]` with
generation and `case user:`, context, the async bridge
(`effectPassive`/`awaitText`/JS fetch),
the test DOM (`toHtml`/`fire`), the `{.ui.}` syntax pass: `c.Tag.class:`,
attr/css/prop chains, `cls`, events, `onMount`/`onCleanup`, slots,
auto-fragment, reactive `if`/`for`, keyed `forEachList` (including
local `State[seq[T]]` with type inference), `s = v`, the `s += v` overloads,
the JS backend (smoke/async/resource).

**Target, not yet in code:** deep `signal` with generation of
`ObjState`/`SeqState`/`TRef`/`FieldRef`, imperative
`List`/`Set`/`Table`, `Dynamic`, `Option` integration,
`if open:` sugar, an automatic type-plugin, JS tests of the `{.ui.}` DSL
(the implementation has no `std/macros` dependency).

**Open questions:**

1. `onCreated(e).classes` with several root nodes of a component: apply
   to the first element or to all? Decide before implementing `onCreated`.
2. `case`/`while`: do a branch-swap like with `if`, or rebuild the block
   (`uiBlock`)? By default — `uiBlock`, later `uiSwitch`.
3. `List.items` on `updateAt`: update the snapshot without a structural
   notification, or notify and rely on the keyed diff? The decision affects
   O(n) when typing in a field.
4. Slots and context: is a slot executed in the caller's context or in the
   component's? In the design — in the context of the component's `provide`; confirm on
   Chart/Plot.
5. `for` over `Computed[seq[T]]` (filter): keys and stability; a test for
   removing/restoring an element.
6. Compiler dependencies: capture of the `for` variable (issue #2),
   a verbatim copy of `for` in the type-plugin (#5), `defined(js)`/`nim_exit`.
7. Nimony: the implementation is two plugin passes — the `{.ui.}` template
   plugin for syntax and the type/module state plugin for `{.state.}`. No
   `std/macros`, no `{.rewriteModule.}` and no `{.signal.}` alias.
8. `onCreated` or `onMount`: keep the current name or rename it according to
   the semantics "after attaching to the document"?
