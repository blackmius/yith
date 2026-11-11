## Plugin-native UI wrapper.
##
## Nimony plugins cannot (yet) occupy a proc-pragma slot like `{.ui.}`, so the
## plugin entry point is a block:
##
##   import yith/uiblock
##   ui:
##     proc View(): E =
##       c.Div.card:
##         "hello"
##
## The plugin receives the block as untyped NIF before sem and emits the same
## runtime calls the old macro emitted. This is the migration path away from
## std/macros.

template ui*(body: untyped) {.plugin: "uiblock_plugin".}
