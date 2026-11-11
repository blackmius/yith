## Marks runtime primitives that the yith type plugin must leave alone.
## A proc carrying `{.yithInternal.}` is part of the runtime, not a component:
## wrapping its own body in `uiFragment` would recurse.

template yithInternal*() {.pragma.}
