## Marks runtime primitives that the yith type plugin must leave alone.
## A proc carrying `{.yithInternal.}` is part of the runtime, not a component:
## wrapping its own body in `uiFragment` would recurse.

template yithInternal*() {.pragma.}

template yithUi*() {.pragma.}
  ## Marks a routine transformed by the `{.ui.}` syntax pass; the state plugin
  ## only creates derived (`computedExpr`) locals inside these routines.

type
  PluginHook* {.plugin: "state_plugin".} = object
    ## Referencing this type in a module asks Nimony to run the state plugin
    ## for that module. The syntax pass emits one tiny `var` of this type; the
    ## compiler deduplicates type plugins per module, so the state plugin runs
    ## exactly once no matter how many `{.ui.}` routines a module has.

template stateModule*() =
  ## Enables the post-sem state pass in a module that has state but no
  ## `{.ui.}` routine. Call it once at top level.
  var yithStateHook: PluginHook
