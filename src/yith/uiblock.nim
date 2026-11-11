## `{.ui.}` / `ui:` syntax entry point.
##
## Two passes are involved:
##
## 1. `uiblock_plugin` (a template plugin) turns `c.Tag.class:` blocks into
##    ordinary `uiBlock`/`uiWhen`/`uiLoop` calls. It runs before the body is
##    semchecked, but leaves `{.state.}` alone.
## 2. `state_plugin` (a type plugin triggered by the hook emitted in pass 1)
##    rewrites `{.state.}` declarations and uses to `State[T]` + `get`/`set`
##    after sem.
##
## Both passes are enabled by importing this module and writing:
##
##   import yith/ui
##
##   proc View(): E {.ui.} =
##     c.Div.card:
##       "hello"
##
## The same template can be used as a block:
##
##   ui:
##     proc View(): E =
##       c.Div.card:
##         "hello"

import ./internal
export internal

template ui*(def: untyped) {.plugin: "uiblock_plugin".}
