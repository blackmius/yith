> **Historical note.** References to `uipragma.nim`, `std/macros` and the
> `{.ui.}` macro in this file describe the pre-two-pass implementation. yith
> now uses two Nimony plugins (`uiblock_plugin.nim`, `state_plugin.nim`) and
> has no `std/macros` dependency.
>
# Nimony compiler issues

> yith now lives in its own repository at `/home/daniil/projects/yith`.
> Paths `src/yith`, `tests/ui`, `examples/ui` in this file are historical.

Tested compiler: `nimony 0.6.3 [linux; arm64]`, git HEAD
`2c5b3dca` (2026-11-09). Re-checked on 2026-11-09 after the plugin/lambda
fixes. Earlier results were on `e766460c` (2026-11-01). Reproducers were
compiled with:

```sh
../nimony/bin/nimony c -f <file>.nim -o:<file>
```

Note for this environment: `/usr/local/bin/timeout` returns 1 and swallows
the output; use `perl -e 'alarm shift; exec @ARGV' N <cmd>` when a run may
hang.

Each section below is written to be filed as one GitHub issue.

| # | Issue | Kind | Severity | Status on `2c5b3dca` |
|---|---|---|---|---|
| 1 | `for` + discarded ref-returning call crashes `finalir` | crash | high | **fixed** |
| 2 | `for` variable captured by reference | semantics | high | open |
| 3 | `initSkipTable(result.field)` yields a zero table; `find` hangs | codegen | high | **fixed** |
| 4 | `var` parameter accepts an rvalue | semantics | high | **fixed** |
| 5 | Type-plugin output re-sems a copied `for` and hits `[Bug]` | plugins | high | **partial** (rebuild works, raw copy fails) |
| 6 | `discardable` on a template is ignored | pragmas | low | open |
| 7 | Expression-bodied closure in a template is rejected | templates | medium | **fixed** |
| 8 | `defined(js)` is not set by `nimony j` | js-backend | high | open |
| 9 | `nimony j --browser` throws `nim_exit` when `main` returns | js-backend | medium | open |
| 10 | Stale `nimcache` after object field changes | incremental | high | not re-checked |
| 11 | `put(string,int)` vs `put(string,int64)` ambiguous | overloads | medium | open |
| 12 | Arithmetic on a generic parameter fails | generics | medium | open |
| 13 | `ord`/`high` on a generic enum parameter fails | generics | medium | open |
| 14 | `s.post(s.data)` rejected as aliasing | borrow-checker | low | open |
| 15 | `ptr T = nil` default rejected | design | low | design |
| 16 | Iterating a `seq` field through `ref` rejected | design | low | design |
| 17 | `varargs[untyped]` macro parameters fail to compile | macros | high | open |
| 18 | Named args rejected for varargs/template-plugin calls | macros | high | open |
| 19 | Macro child indexing crashes with `symId on Ident` | macros | high | open |
| 20 | Macro plugin host cannot see module-level helper procs | macros | high | open |
| 21 | Tuple constructor arrives as `nnkNone` in macros | macros | medium | open |
| 22 | `ranges` case-pattern wrapper arrives as `nnkNone` in macros | macros | medium | open |
| 23 | Macro-generated `var` lambda does not match generic `proc (x: var T)` | macros | medium | open |
| 24 | JS: `State[T]` inside a variant object loses its value after passive rerun | js-backend | high | open |
| 25 | JS: importing `std/macros` fails on `errorcodes_posix` globals | js-backend, macros | high | open |
| 26 | Two generic types with one name and different arity crash sem | generics | medium | open |
| 27 | JS: scope teardown after a DOM re-render crashes in DataView/dealloc | js-backend | high | open |

---

## 1. `for` body + discarded call returning `ref` crashes `finalir`

**Labels:** bug, compiler, crash, finalir
**Severity:** high (compiler abort)
**Status:** fixed in `2c5b3dca`; regression test `ba9a1d3a`. The repro now
compiles and exits 0.

### Summary
A `for` loop whose body discards a `{.discardable.}` call that returns a
`ref` object aborts the compiler with an internal assertion. A call that
returns `void` in the same position works.

### Repro
```nim
type Obj = ref object
  v: int

proc make(v: int): Obj {.discardable.} =
  result = Obj(v: v)

proc view() =
  for i in 0 ..< 2:
    make(i)

view()
```

```sh
nimony c -f repro.nim -o:repro
```

### Actual
```
assertions.nim(38)  raiseAssert
Error: unhandled exception: finalir.nim(668, 3)
  `n.stmtKind in {StmtsS, ScopeS}` TagLit [AssertionDefect]
```

### Expected
The loop body is an expression statement whose value is discarded, exactly
like `discard make(i)`; compilation should succeed.

### Workaround
Make the callee `void` (append to a container instead of returning a value).
Adding an explicit `discard` does not help:
`discard make(i)` gives `Error: statement expected, but got: ...`.

---

## 2. `for`-loop variable is captured by reference, not per iteration

**Labels:** bug, semantics, closures
**Severity:** high (silent wrong results)

### Summary
A closure created inside a `for` body sees the **final** value of the loop
variable, not the value of the iteration it was created in. The same happens
with a `let` local declared inside the loop and captured by a closure.

### Repro
```nim
import std/syncio

type F = proc (): string {.closure.}

var fs: seq[F] = @[]
for i in 0 ..< 2:
  fs.add(proc (): string {.closure.} =
    result = "x" & $i)

for k in 0 ..< fs.len:
  echo fs[k]()
```

### Actual
```
x2
x2
```
(the loop ends with `i == 2`; both closures read that location).

### Expected
```
x0
x1
```
Nim captures the loop variable per iteration. The same test with
`let j = i` inside the loop still prints `x1, x1`.

### Workaround
Do not create closures over loop variables; pass the value into a component
call that copies it into its own environment, or evaluate eagerly.

---

## 3. `initSkipTable(result.table, ...)` compiles but produces a zero table; `find` loops forever

**Labels:** bug, codegen, var-parameter
**Severity:** high (hang / memory corruption)
**Status:** fixed in `2c5b3dca`; regression test `ad2bf92c`. The repro now
prints `2` and exits.

### Summary
Calling the `var`-parameter overload of `initSkipTable` on a field of
`result` compiles, but the table is not initialized. A subsequent `find`
using it loops forever. The same call on a local variable works.

### Repro
```nim
import std/syncio
import std/strutils

type M = object
  needle: string
  table: SkipTable

func initM(sub: string): M =
  result = M()
  initSkipTable(result.table, sub)
  result.needle = sub

let m = initM("abc")
echo find(m.table, "xxabc", m.needle)
```

### Actual
Builds; the program never returns (alarm after 5 s).

### Expected
`2` (the index of `"abc"` in `"xxabc"`), as with:
```nim
var a: SkipTable
initSkipTable(a, "abc")
```

### Workaround
Use the returning overload: `table: initSkipTable(needle)`.

### Related
The same class of bug is visible when a `var` parameter receives an rvalue
(issue 4): `result.table` is a field access that is not a stable lvalue for
the lowered code.

---

## 4. `var` parameter accepts an rvalue and writes to a temporary

**Labels:** bug, semantics, var-parameter
**Severity:** high (silent miscompilation; can crash in C)
**Status:** fixed in `2c5b3dca` (related commit `4b7e4a9a`).
`bump(1 + 2)` is now rejected with
`cannot pass 1 + 2 to var/out T parameter`.

### Summary
A `var` parameter accepts expressions that are not lvalues. The compiler
generates a temporary and the callee writes into it; the write is lost, or
(in the `getU32(data, base + k*4)` case from the storage code) the generated C
crashes because it takes the address of a temporary.

### Repro
```nim
import std/syncio

proc bump(x: var int) =
  x = x + 1

var a = 1
let b = 2

bump(a)
bump(1 + 2)   # accepted
# bump(b)     # correctly rejected: cannot pass b to var/out T parameter
echo a
```

### Actual
Compiles and runs. `bump(1 + 2)` is accepted; there is no place for the
result to go.

### Expected
`Error: cannot pass an rvalue to a var/out parameter` for `bump(1 + 2)`,
matching the diagnostic already produced for the immutable `let b`.

### Notes
The storage code hit the same issue with
`getU32(data, base + k*4)`: it compiled, and the C backend then crashed or
read garbage because the temporary's address was passed as `var pos`.

---

## 5. Type-plugin output is re-semchecked and `for` is desugared twice

**Labels:** bug, plugins, type-plugin, for-loop
**Severity:** high (type plugins cannot move/rewrite loops)
**Status:** partially fixed in `2c5b3dca`. The raw-copy repro below still
aborts with `[Bug] (stmts) expected, but got (for ...)`. A plugin that
**rebuilds** the loop with fresh loop-variable symbols (as a practical
component wrapper does) now works: `for`/`if`/`case` transforms compile and
update. The remaining bug is the re-check of a verbatim-copied `for`.

### Summary
A type plugin that wraps a `proc` body (or a `for` node) in a closure causes
the compiler to run `semFor` again on the already-semchecked loop. The
iterator child is already `(call items xs)`, so it is wrapped a second time
and the module fails with `items(items(xs))` or
`yield only allowed within an iterator`.

A pass-through type plugin (copy every node unchanged) does **not** break
the module, so the problem is the re-check of a moved/rebuilt `for`, not a
general plugin failure.

### Repro
Layout:
```
repro/
  main.nim
  dep.nim
  mtype.nim
  nimony.paths
```

`nimony.paths` points at the plugin API:
```
<path-to-nimony>/src/nimony/lib
```

`dep.nim` — the type that triggers the plugin, and the procedure the plugin
calls (it must be imported, so the generated call resolves):
```nim
type Node* {.plugin: "mtype".} = object
  x*: int

proc runBlock*(body: proc () {.closure.}) =
  body()
```

`main.nim` — only a `for` loop; the plugin will move it into a closure:
```nim
import std/syncio
import dep

proc view() =
  let xs = @[1, 2, 3]
  for x in xs:
    echo x

var n: Node
view()
echo n.x
```

`mtype.nim` — the type plugin. It replaces every `for` with
`runBlock(proc () = <for>)`:
```nim
{.feature: "assumeSync".}
import plugins

proc addClosure(dest: var NifBuilder; body: NifBuilder; info: LineInfo) =
  let sym = genSym()
  dest.openTree("expr", info)
  dest.openTree("stmts", info)
  dest.openTree("proc", info)
  dest.addSymDef(sym, info)
  dest.addEmptyNode(info)   # export
  dest.addEmptyNode(info)   # pattern
  dest.addEmptyNode(info)   # type vars
  dest.withTree(ParamsU, info):
    discard
  dest.addEmptyNode(info)   # return type
  dest.withTree(PragmasU, info):
    dest.withTree(ClosureP, info):
      discard
  dest.addEmptyNode(info)   # effects
  dest.addTree(body)
  dest.closeTree()          # proc
  dest.addSymUse(sym, info) # a proc literal is `(stmts (proc ...) sym)`
  dest.closeTree()
  dest.closeTree()

proc tr(n: var NifCursor): NifBuilder =
  result = createTree()
  if n.kind != TagLit:
    result.takeTree n
  elif n.stmtKind == ForS:
    let info = n.info
    var body = createTree()
    body.takeTree(n)
    var cl = createTree()
    addClosure(cl, body, info)
    result.openTree("stmts", info)
    result.openTree("call", info)
    result.addIdent "runBlock"
    result.addTree(cl)
    result.closeTree()
    result.closeTree()
  else:
    result.copyInto(n):
      while n.hasMore:
        result.addTree(tr(n))

proc run(): NifBuilder =
  var inp = loadPluginInput()
  result = createTree()
  result.copyInto(inp):
    while inp.hasMore:
      result.addTree(tr(inp))

saveTree run()
```

Build:
```sh
nimony c -f main.nim -o:main
```

### Actual
```
No stack traceback available
[Bug] main.nim(6, 7) (stmts) expected, but got (for
 (call items.2... (hcall toOpenArray... xs))
 (unpackflat
  (let :x.0 . . (mut (i 64)).))
 (stmts ...))
```

The same root cause produces `items(items(xs))` /
`yield only allowed within an iterator` when the plugin rebuilds the loop
instead of copying it verbatim.

### Expected
The plugin output compiles and prints `1 2 3` (then `0`). A `for` node that
was already semantically checked must not be desugared a second time when
it is moved into a closure.

### Workaround
Do not move `for` nodes in a type plugin. Generate a `while` loop or leave
the loop in place.

---

## 6. `{.discardable.}` on a template is accepted but ignored

**Labels:** bug, pragmas, templates
**Severity:** low

### Repro
```nim
template T(): int {.discardable.} =
  1

T()
```

### Actual
```
Error: expression of type `int64` must be discarded
```

### Expected
Either `discardable` is honored (the call is a valid statement), or the
pragma is rejected with a diagnostic. Silently accepting it and then
rejecting the call is confusing.

### Workaround
Use a `{.discardable.}` proc as the template's last expression:
```nim
proc tImpl(): int {.discardable.} = 1
template T(): int = tImpl()
T()
```

---

## 7. Expression-bodied closure inside a template is rejected

**Labels:** bug, templates, closures
**Severity:** medium
**Status:** fixed in `2c5b3dca` (commit `d06a2580`); the repro prints `a`.

### Repro
```nim
type F = proc (): string {.closure.}

template T(v: untyped) =
  let f: F = proc (): string {.closure.} = $v
  echo f()

T("a")
```

### Actual
```
Error: expression of type `string` must be discarded
```

### Expected
Works like the same code outside a template:
```nim
let a = "a"
let f: F = proc (): string {.closure.} = $a & "!"
```
compiles and returns `a!`.

### Workaround
Use a statement body in generated closures:
```nim
proc (): string {.closure.} =
  result = $v
```

---

## 8. `defined(js)` is not set by the JS backend

**Labels:** bug, js-backend, defines
**Severity:** high (stdlib branches on it)

### Repro
```nim
import std/syncio

proc echoDefs() {.exportc: "echoDefs".} =
  when defined(js): echo "js=yes" else: echo "js=no"
  when defined(wasm32): echo "wasm32=yes" else: echo "wasm32=no"
  when defined(standalone): echo "standalone=yes" else: echo "standalone=no"
  flushFile(stdout)
```

```sh
nimony j --browser defs.nim
node <generated>.js   # call NIF.echoDefs()
```

### Actual
```
js=no
wasm32=yes
standalone=yes
```

### Expected
`js=yes`. The JS backend targets `--os:standalone --cpu:wasm32`, but
`defined(js)` is the conventional switch used by `std/monotimes`,
`std/cmdline`, `std/envvars`, `std/strtabs` and others to select the JS arm.
Without it those modules compile the POSIX arms for a JS program.

---

## 9. `nimony j --browser` throws `nim_exit` when `main` returns

**Labels:** bug, js-backend, browser, runtime
**Severity:** medium

### Repro
```nim
import std/syncio
echo "hello"
```

```sh
nimony j --browser app.nim
node app.js
```

### Actual
```
hello
Error: nim_exit(0)
    at nim_exit (...)
```

### Expected
A browser program whose `main` returns should keep the event loop alive (or
exit quietly); `nim_exit` should not throw at the end of a normal main.
The renderer comment says `nim_exit` throws "instead of killing the tab";
the throw is currently uncaught at top level.

### Workaround
Compile with at least one `{.exportc.}` proc (the host-driven library
mode): jorogumo then omits `nim_exit` and exports the surface on
`globalThis.NIF`; the page calls `NIF.start()`.

---

## 10. Stale `nimcache` after changing object fields (layout not invalidated)

**Labels:** bug, incremental-compilation, cache, codegen
**Severity:** high (silent data corruption seen during development)

### Summary
After adding fields to an object type, an incremental rebuild can reuse a
`nimcache` artifact produced with the old layout: the writer stores the old
size and the reader reads the new field layout (or vice versa). This showed
up as "the Bloom filter is empty in every chunk but one" after changing
`TextChunkData`/`TextChunk`; clearing `nimcache` fixed it.

### Expected
The cache key includes the structural layout of every type that crosses a
module boundary, or any layout change invalidates the dependent artifacts.

### Workaround
`rm -rf nimcache` after changing the fields of an object that is serialized
or shared across modules.

### Status
Observed repeatedly during development; a two-build minimal reproducer is
not yet extracted.

---

## 11. Overload resolution: `put(string, int)` vs `put(string, int64)` is ambiguous

**Labels:** bug, overload-resolution
**Severity:** medium

### Repro
```nim
proc put(name: string; v: int) = discard
proc put(name: string; v: int64) = discard

put("a", 1)
```

### Actual
```
Error: ambiguous call: 'put'
```

### Expected
`1` is an `int` literal; the `int` overload is the exact match and should win.
(This forced the storage code to expose only the `int64` overload and cast
at the call sites.)

---

## 12. Arithmetic on a generic parameter fails

**Labels:** bug, generics, arithmetic
**Severity:** medium

### Repro
```nim
type Box[T] = ref object
  total: T

proc add[T](b: Box[T]; x: T) =
  b.total = b.total + x

var b = Box[int](total: 0)
b.add 1
```

### Actual
```
Type mismatch at [position]
  b.total + x
[1] expected: int64 but got: T   (declared in std/system/arithmetics.nim)
...
[1] T does not match constraint T
```

### Expected
`+` should be resolved for the instantiated `T` (or a `T: SomeNumber`
constraint). The workaround is to declare concrete instantiations:
```nim
proc add(b: Box[int64]; x: int64)
proc add(b: Box[float64]; x: float64)
```

---

## 13. `ord` / `high` on a generic enum parameter fails

**Labels:** bug, generics, enums
**Severity:** medium

### Repro
```nim
type Color = enum red, green

proc lastValue[S](s: S): S =
  result = high(S)

echo lastValue(green)
```

### Actual
```
Type mismatch at [position]
  high(S)
[1] S does not match constraint T
```

### Expected
`high(S)`/`ord(s)` work for an enum `S`; `cast[int](s)` works as a
workaround (used by `Timeline`).

---

## 14. Over-strict alias check: `s.post(s.data)` is rejected

**Labels:** bug, borrow-checker, aliasing
**Severity:** low

### Repro
```nim
type Buf = object
  data: string

proc post(s: var Buf; d: string) = discard

proc run(s: var Buf) =
  s.post(s.data)
```

### Actual
```
Error: mutable argument aliases with immutable parameter
```

### Expected
`d` is passed by value (`string`), so the callee cannot observe a mutation
of `s` through `d` unless it stores a reference. Nim accepts this. The
workaround is to copy first: `let data = s.data; s.post(data)`.

---

## 15. (Design) `ptr T = nil` as a default parameter is rejected

**Labels:** limitation, non-nil, pointers
**Severity:** low

```nim
type R = object
proc f(p: ptr R = nil) = discard
```
```
Error: expected non-nil value
```
Nimony pointers are non-nil by default (`{.feature: "lenientnils".}` opts
out). This is likely intentional; filed for documentation rather than as a
bug.

---

## 16. (Design) Iterating a `seq` field reached through a `ref` is rejected

**Labels:** limitation, borrow-checker
**Severity:** low

```nim
type R = ref object
  items: seq[int]

let r = R(items: @[1, 2])
for x in r.items:
  echo x
```
```
Error: cannot iterate over a location reached through a `ref`:
an alias of the `ref` could mutate it during the loop;
iterate by index, or over `uncheckedBorrow(...)`
```
The diagnostic names an escape (`uncheckedBorrow`), so this appears
intentional; filed for documentation.

---

## 17. `varargs[untyped]` macro parameters fail to compile

**Labels:** bug, macros, varargs
**Severity:** high (blocks the `El(tag, named args…)` DSL)

### Repro
```nim
import std/[syncio, macros]

macro m(args: varargs[untyped]): untyped =
  result = newCall("echo", [newStrLitNode($args.len)])

m(1, 2, 3)
```

### Actual
```
Error compiling macro plugin for 'm':
[Error] type expected but got: (untyped@M,3,repro.nim)
```

### Expected
`varargs[untyped]` is a metaprogramming slot; the macro receives the call
arguments as `NimNode`s, as in Nim. It works for plugin templates
(`std/rex`), so the macro-plugin host compile is the missing piece.

### Workaround
Only fixed arity is usable: `macro m(a, b: untyped)`. For an arbitrary
number of attributes, use a plugin template with positional arguments
(`varargs[untyped]` on the template, not the macro), e.g.
`Div({class = "x", data_id = id}):` or a block DSL.

---

## 18. Named arguments are rejected for varargs and plugin-template calls

**Labels:** bug, macros, templates, named arguments
**Severity:** high (blocks `Div(class = "x")` and `El(tag, class = "x")`)

### Repro
```nim
import std/syncio

template m(args: varargs[untyped]): untyped {.plugin: "plugin".} =
  discard

m(class = "x", 42)
```

### Actual
```
Error: named argument not found (declared in repro.nim(...))
```

The same error occurs for an ordinary `template t(args: varargs[untyped])`
and for `macro m(args: varargs[untyped])` (which fails earlier, see #17).
Positional arguments (`m(1, 42)`) and a trailing colon block work for
plugin templates.

### Expected
Named arguments are routed to the varargs slot as `nnkExprEqExpr` / NIF
`(vv name value)`, so a plugin can interpret arbitrary attribute names.
A `{...}` table/curly constructor currently survives as a single
positional argument, but that is not the desired surface syntax.

---

## 19. Macro child indexing crashes with `symId on Ident`

**Labels:** bug, macros, crash
**Severity:** high (blocks AST inspection in macros)

### Repro
```nim
import std/[syncio, macros]

macro m(e: untyped; body: untyped): untyped =
  var desc = $e.kind
  for i in 0 ..< e.len:
    desc.add " " & $e[i].kind
  result = newStmtList()
  result.add newCall("echo", [newStrLitNode(desc)])
  result.add body

m(el(class = "x", data_id = 42)):
  echo "body"
```

### Actual
```
assertions.nim(38)  raiseAssert
Error: unhandled exception: symId on Ident [AssertionDefect]
```

The same happens with `for a in e`, and with table/curly constructors
(`m({class: "x", data_id: 42})`). `e.kind` and `e.len` are fine; access to
`e[i]` is not.

### Expected
`e[i]` returns the child `NimNode`; a macro can inspect a nested call or
table constructor without the compiler aborting. This is what a
macro-based `El` would need for attribute lowering.

---

## 20. Macro plugin host cannot see module-level helper procs

**Labels:** bug, macros, plugins
**Severity:** high (forces all macro helpers to be nested)

### Repro
```nim
import std/[syncio, macros]

proc helper(x: int): int =
  result = x + 1

macro m(): untyped =
  result = newCall("echo", [newIntLitNode(helper(1))])

m()
```

### Actual
```
Error compiling macro plugin for 'm':
repro.nim(7, 43) Error: undeclared identifier: 'helper'
```

### Expected
The macro plugin host compiles the macro's module scope (or at least
everything the macro body references), so a module-level `helper` is
visible exactly as it is in a normal Nim macro.

### Workaround
Declare all helpers **inside** the macro body:

```nim
macro m(): untyped =
  proc helper(x: int): int =
    result = x + 1
  result = newCall("echo", [newIntLitNode(helper(1))])
```

This is what `ui_macro.nim` does. A second consequence of issue #2 is that
`NimNode` children must be walked with `while`, not `for`: a `for` loop
variable is captured by reference and the `NimNode[]` index ends up wrong
(`symId on Ident` / out-of-bounds).

---

## 21. Tuple constructor arrives as `nnkNone` in macros

**Labels:** bug, macros, AST
**Severity:** medium (tuple patterns need a shape check)

### Repro
```nim
import std/[syncio, macros]

macro m(x: untyped): untyped =
  result = newCall("echo",
    [newStrLitNode($x.kind & " len=" & $x.len)])

m(("a", 1))
```

### Actual
```
nnkNone len=2
```

### Expected
`nnkTupleConstr len=2` (the parser's `(tup ...)` tag should map to
`nnkTupleConstr`, as `macros_nif` already does for `tupconstr`).

### Workaround
Detect the two-element tuple by shape:

```nim
if x.len == 2 and x[0].kind == nnkStrLit and
   (x.kind == nnkTupleConstr or x.kind == nnkPar or x.kind == nnkNone):
  ...
```

`uipragma.nim` uses this for conditional classes
`class = ("active", cond)`.

---

## 22. `ranges` case-pattern wrapper arrives as `nnkNone` in macros

**Labels:** bug, macros, AST, case
**Severity:** medium (case patterns need a shape workaround)

### Repro
```nim
import std/[syncio, macros]

macro dbg(def: untyped): untyped =
  try:
    writeFile("/tmp/dbg.txt", treeRepr(def))
  except:
    discard
  result = def

proc f(): int {.dbg.} =
  case user:
  of Loading:
    discard
  of Ready(data):
    discard
  result = 1
```

### Actual
The branch pattern is wrapped as `nnkNone`:

```
nnkOfBranch
  nnkNone
    nnkIdent "Loading"
  nnkStmtList ...
```

`nnkNone` serializes back as a dot token, so a generated
`nnkOfBranch` with an `nnkNone` pattern is ill-formed; a generated
`case` cannot be built reliably.

### Expected
The wrapper should be `nnkRange`/a dedicated ranges node, or the pattern
should be exposed directly.

### Workaround
Unwrap a one-child `nnkNone` to inspect the pattern, and rewrite the
resource dispatch as an **if/elif chain** (`if yithRes.kind == resReady`)
instead of a generated `case`. `uipragma.nim` does this for
`case user:`.

---

## 23. Macro-generated `var` lambda does not match generic `proc (x: var T)`

**Labels:** bug, macros, generics, var parameters
**Severity:** medium (macro cannot emit `s.update(proc (x: var T) = ...)`)

### Repro
A macro builds a `proc (x: var int) {.closure.}` lambda (with
`nnkVarTy`) and passes it to a generic:

```nim
proc update[T](s: State[T]; f: proc (x: var T) {.closure.}) = ...

let n = state(1)
let lambda = <macro-generated proc (x: var int)>
n.update(lambda)
```

### Actual
```
expected: var T but got: int64
```

The same generated lambda passed to a **non-generic**
`proc take(f: proc (x: var int))` works. The `var` modifier is lost only
when matching the generated proc type against a generic `var T` formal.

### Workaround
Inline `update` in the macro instead of emitting a lambda:

```nim
block:
  var yithV = s.get()
  yithV += v
  s.set(yithV)
```

This is what `uipragma.nim` does for `s += v` and `s.foo(args)`.

---

## 24. JS: `State[T]` inside a variant object loses its value after passive rerun

**Labels:** bug, js-backend, passive, generics
**Severity:** high (async `Resource` payload becomes empty)
**Status:** open on `2c5b3dca`.

### Summary
A variant object that stores a generic `State[T]` works on the first passive
effect run, but after the effect is restarted the nested state reads as the
empty value. The same code works on the C backend and works on JS when the
state is stored on the outer `ref` object instead of in the variant.

### Repro
```nim
type
  K = enum kLoading, kReady
  V[T] = object
    case kind: K
    of kLoading: discard
    of kReady: data: State[T]
  Box[T] = ref object
    value: State[V[T]]
    gen: int

proc boxed[T](f: proc (): T {.passive.}; init: T): Box[T] =
  result = Box[T](value: state(V[T](kind: kReady, data: state(init))))
  let r = result
  discard effectPassive(proc () {.passive, closure.} =
    inc r.gen
    let my = r.gen
    r.value.set(V[T](kind: kLoading))
    let v = f()
    if r.gen == my:
      r.value.set(V[T](kind: kReady, data: state(v))))
```

Run `boxed(proc (): string {.passive.} = awaitText("/user/" & who.get()), "init")`
twice on JS (start with `who = "a"`, then `who.set("b")`). First run renders
`A`; second run renders `""`.

### Workaround
Keep payload states on the outer handle, not inside the variant:

```nim
ResourceValue[T] = object
  kind: ResourceState
Resource[T] = ref object
  value: State[ResourceValue[T]]
  data: State[T]
  error: State[ErrorInfo]
```

`src/yith/resource.nim` uses this shape; `tests/ui/js_aresource.nim`
verifies `Loading -> Ready` and late-response generation.

---

## 25. JS: importing `std/macros` fails on `errorcodes_posix` globals

**Labels:** bug, js-backend, macros, stdlib
**Severity:** high (the `{.ui.}` DSL cannot be built for JS)
**Status:** open on `2c5b3dca`.

### Repro
```sh
PATH=/tmp/nifjs:$PATH ../nimony/bin/nimony j --browser -p:src /tmp/ni/js_macro.nim
```

with `/tmp/ni/js_macro.nim`:
```nim
{.feature: "assumeSync".}
import std/[syncio, macros]

macro id(x: untyped): untyped = x
proc start() {.exportc: "start".} =
  echo id("ok")
  flushFile(stdout)
echo "init"
flushFile(stdout)
```

### Actual
```text
.../lib/std/errorcodes/errorcodes_posix.nim(681, 32) Error:
unsynchronized access to global variable 'ENOLCK'; pass it to a `.sync`
routine or use `{.cast(assumeSync).}`
...
nifmake: command failed ... --cpu:wasm32 --os:standalone
```

The same build without `std/macros` works. `{.feature: "assumeSync".}` at
the test module, `uipragma.nim`, and `resource.nim` does not propagate to
the cached `errorcodes_posix` module.

### Impact
`tests/ui/js_aresource.nim` and other JS tests intentionally avoid
`yith/uipragma`; the `{.ui.}` DSL is covered only on C. A fix is needed
before the browser build can use component syntax.

---

## 26. Two generic types with one name and different arity crash sem

**Labels:** bug, generics, type-system
**Severity:** medium (`Resource[T]` / `Resource[T, A]` need different names)
**Status:** open on `2c5b3dca`.

### Repro
```nim
type
  Foo[T] = object
    x: T
  Foo[T, A] = object
    x: T
    y: A

let a = Foo[int](x: 1)
let b = Foo[int, string](x: 1, y: "s")
echo a.x
echo b.x
echo b.y
```

### Actual
```text
Error: unhandled exception: nifcore.nim(1281, 3)
`c.rem == 0` into: body did not consume all 62 children (left 5)
[AssertionDefect]
```

### Workaround
Use distinct type names. yith exposes `Resource[T]` and
`ArgResource[T, A]`; constructors keep the same spelling:
`resource(fetcher)` and `resource(fetcher, arg)`.
`tests/ui/targresource.nim` covers sync/passive argument resources.

---

## 27. JS: scope teardown after a DOM re-render crashes in DataView/dealloc

**Labels:** bug, js-backend, runtime, memory
**Severity:** high (browser kanban crashes on drop)
**Status:** open on `2c5b3dca`.

### Summary
A reactive subtree built with `uiBlock` renders initially, but after a state
change that replaces its children (`board.set(...)`) the queued flush enters
`killScope` / `drain`; JS crashes with:

```text
RangeError: Offset is outside the bounds of the DataView
at DataView.prototype.getUint32
at n_addToSharedFreeList_...
at n_rawDealloc_...
at n_deallocFixed_...
at n_setLen_... (core.nim)
at n_killScope_... (core.nim)
at n_drain_...
at n_flush_...
```

### Repro
Build `examples/ui/kanban_js.nim` into JS:

```sh
examples/ui/build_kanban_js.sh
node /tmp/ni/kanban_browser_events_async.js examples/ui/kanban.js
```

The initial board renders. After a simulated card drop the first flush crashes
while disposing the old `uiBlock` subtree. The same example works on the C/test
DOM backend (`examples/ui/kanban.nim`).

### Impact
The experimental browser wrapper can show the initial board but cannot complete
a drag/drop state transition until the JS scope teardown path is fixed (or a
non-tearing render path is introduced). C/test DOM remains the supported target
for the declarative-drag examples.

---

# Findings that are **not** compiler bugs (for triage)

## Stdlib

- `hash(uint64)` is identity (`hash(1024'u64) == 1024`), so `Table[uint64,
  ...]` clusters with high-cardinality keys (measured 165 buckets for 200k
  keys; a 76 s query that drops to 0.8 s after `mixPacked`). `hash` for
  unsigned integers should mix.
- `join(seq[string], char)` is not found (expects `openArray[string]`).
- `newException(IOError, "...")` is missing; only `ErrorCode` values.
- `getEnv`, `leadingZeros`/`bitops`, `strutils.parseFloat` are missing in
  this stdlib snapshot.
- `Table[]` is annotated `.raises`, so every read needs a `raises` context.
- `stderr` is buffered; diagnostics need `flushFile(stderr)`.
- `initSkipTable`'s var-parameter form is broken by issue 3.

## Fixed in the current HEAD (do not file)

- `newSeq[Table[string, int]](4)` hangs (D104) — now works.
- Generic template parameters (`template mark[S](x: S)`) — now work.
- `var x: Box[int64]` without initialization — now works.
- `seq[seq[seq[int]]]` construction — now works.

## Environment

- `/usr/local/bin/timeout` returns 1 and swallows output; use
  `perl -e 'alarm shift; exec @ARGV' N <cmd>`.
- `nimony j` requires `jorogumo` from `nativenif`; it is not part of the
  Nimony checkout and must be built from the pinned `nativenif` commit.
