## Declarative dragging: reorderable rows and tiles.
##
## Mirrors the Dragology "Lists in Lists" example: each row/tile builds its
## reachable states, then uses
##   closest(states).whenFar(stateWithout).withFloating()
## to pick a target or fall back to a free-floating state.
##
## Run:
##   nimony c -d:yithDomTest -p:src examples/ui/rows.nim -o:bin/rows
##   ./bin/rows

import std/syncio
import yith/ui
import yith/dom/api

type
  Tile* = object
    id*: string
    label*: string

  Row* = object
    id*: string
    color*: string
    items*: seq[Tile]

  Sheet* = object
    rows*: seq[Row]

  Plan* = object
    base*: Sheet
    states*: seq[Sheet]

const
  TileSize* = 50.0
  TileGap* = 8.0
  RowPad* = 8.0
  RowGap* = 10.0
  GripW* = 16.0
  GripPad* = 2.0
  RowH* = TileSize + RowPad * 2.0

proc copyTiles(items: seq[Tile]): seq[Tile] =
  result = @[]
  var i = 0
  while i < items.len:
    result.add items[i]
    inc i

proc clone*(s: Sheet): Sheet =
  result = Sheet(rows: @[])
  var i = 0
  while i < s.rows.len:
    result.rows.add Row(id: s.rows[i].id, color: s.rows[i].color,
                        items: copyTiles(s.rows[i].items))
    inc i

proc removeRowState*(s: Sheet; rowIdx: int): Sheet =
  result = Sheet(rows: @[])
  var i = 0
  while i < s.rows.len:
    if i != rowIdx:
      result.rows.add s.rows[i]
    inc i

proc insertRowState*(s: Sheet; rowIdx: int; row: Row): Sheet =
  result = Sheet(rows: @[])
  var i = 0
  while i < s.rows.len:
    if i == rowIdx:
      result.rows.add row
    result.rows.add s.rows[i]
    inc i
  if rowIdx >= s.rows.len:
    result.rows.add row

proc removeTileState*(s: Sheet; rowIdx, tileIdx: int): Sheet =
  result = clone(s)
  result.rows[rowIdx].items.delete tileIdx

proc insertTileState*(s: Sheet; rowIdx, colIdx: int; tile: Tile): Sheet =
  result = clone(s)
  var items: seq[Tile] = @[]
  let row = result.rows[rowIdx]
  var i = 0
  while i < row.items.len:
    if i == colIdx:
      items.add tile
    items.add row.items[i]
    inc i
  if colIdx >= row.items.len:
    items.add tile
  result.rows[rowIdx].items = items

proc rowPlan*(s: Sheet; rowIdx: int): Plan =
  result = Plan(base: removeRowState(s, rowIdx), states: @[])
  let row = s.rows[rowIdx]
  var i = 0
  while i <= result.base.rows.len:
    result.states.add insertRowState(result.base, i, row)
    inc i

proc tilePlan*(s: Sheet; rowIdx, tileIdx: int): Plan =
  let base = removeTileState(s, rowIdx, tileIdx)
  let tile = s.rows[rowIdx].items[tileIdx]
  result = Plan(base: base, states: @[])
  var r = 0
  while r < base.rows.len:
    var c = 0
    while c <= base.rows[r].items.len:
      result.states.add insertTileState(base, r, c, tile)
      inc c
    inc r

proc tileRow*(s: Sheet; id: string): int =
  result = -1
  var r = 0
  while r < s.rows.len:
    var c = 0
    while c < s.rows[r].items.len:
      if s.rows[r].items[c].id == id:
        return r
      inc c
    inc r

proc tileCol*(s: Sheet; id: string): int =
  result = -1
  var r = 0
  while r < s.rows.len:
    var c = 0
    while c < s.rows[r].items.len:
      if s.rows[r].items[c].id == id:
        return c
      inc c
    inc r

proc rowIndex*(s: Sheet; id: string): int =
  result = -1
  var r = 0
  while r < s.rows.len:
    if s.rows[r].id == id:
      return r
    inc r

proc startTileDrag*(dragCtl: DragController[Sheet]; model: State[Sheet];
                    rowIdx, tileIdx: int; p: Point)
proc startRowDrag*(dragCtl: DragController[Sheet]; model: State[Sheet];
                   rowIdx: int; p: Point)

proc TileView*(model: State[Sheet]; dragCtl: DragController[Sheet];
               dragLabel: State[string]; dragColor: State[string];
               rowIdx, tileIdx: int; tile: Tile): E {.ui.} =
  c.Div.tile:
    attr.id("tile-" & tile.id)
    css.width($TileSize & "px")
    css.height($TileSize & "px")
    css.display("flex")
    css.align_items("center")
    css.justify_content("center")
    onPointerDown(e):
      dragLabel.set(tile.label)
      dragColor.set(model.get().rows[rowIdx].color)
      startTileDrag(dragCtl, model, rowIdx, tileIdx,
                    Point(x: e.clientX, y: e.clientY))
    c.Span.tile_label:
      tile.label

proc RowView*(model: State[Sheet]; dragCtl: DragController[Sheet];
              dragLabel: State[string]; dragColor: State[string];
              rowIdx: int): E {.ui.} =
  c.Div.row:
    attr.id("row-" & model.get().rows[rowIdx].id)
    css.display("flex")
    css.align_items("center")
    css.gap($TileGap & "px")
    css.padding($RowPad & "px")
    css.background_color(model.get().rows[rowIdx].color)
    c.Div.grip:
      attr.id("grip-" & model.get().rows[rowIdx].id)
      css.width($GripW & "px")
      css.height($TileSize & "px")
      css.display("flex")
      css.align_items("center")
      css.justify_content("center")
      onPointerDown(e):
        dragLabel.set(model.get().rows[rowIdx].id)
        dragColor.set(model.get().rows[rowIdx].color)
        startRowDrag(dragCtl, model, rowIdx,
                     Point(x: e.clientX, y: e.clientY))
      c.Span.grip_dots:
        "::"
    var c = 0
    while c < model.get().rows[rowIdx].items.len:
      TileView(model, dragCtl, dragLabel, dragColor, rowIdx, c,
               model.get().rows[rowIdx].items[c])
      inc c

proc RowsView*(model: State[Sheet]; dragCtl: DragController[Sheet];
               dragLabel, dragColor: State[string]): E {.ui.} =
  c.Div.rows:
    css.display("flex")
    css.flex_direction("column")
    css.gap($RowGap & "px")
    css.padding("8px")
    onPointerMove(e):
      if dragCtl.active.get():
        discard dragCtl.move(Point(x: e.clientX, y: e.clientY))
    onPointerUp(e):
      if dragCtl.active.get():
        discard dragCtl.finish()
        if dragCtl.hasDrop():
          model.set(dragCtl.chosen().state)
        dragLabel.set("")
        dragColor.set("")
    uiBlock(proc () {.closure.} =
      var r = 0
      while r < model.get().rows.len:
        RowView(model, dragCtl, dragLabel, dragColor, r)
        inc r
      if dragCtl.active.get():
        c.Div.ghost:
          css.position("fixed")
          css.background_color(dragColor.get())
          css.left($dragCtl.pointer.get().x & "px")
          css.top($dragCtl.pointer.get().y & "px")
          c.Span.tile_label:
            dragLabel.get())


proc renderSheet(s: Sheet; model: State[Sheet];
                 dragCtl: DragController[Sheet];
                 dragLabel, dragColor: State[string]): E =
  model.set(s)
  result = RowsView(model, dragCtl, dragLabel, dragColor)

proc planTargets(plan: Plan; model: State[Sheet];
                 dragCtl: DragController[Sheet];
                 dragLabel, dragColor: State[string];
                 selector: string): seq[DragTarget[Sheet]] =
  let tmp = newState(plan.base)
  let rc = newDragController[Sheet]()
  let lbl = newState("")
  let col = newState("")
  result = speculativeTargets(plan.states,
    proc (s: Sheet): E {.closure.} =
      renderSheet(s, tmp, rc, lbl, col),
    selector)

proc startTileDrag*(dragCtl: DragController[Sheet]; model: State[Sheet];
                    rowIdx, tileIdx: int; p: Point) =
  let plan = tilePlan(model.get(), rowIdx, tileIdx)
  let tile = model.get().rows[rowIdx].items[tileIdx]
  let targets = planTargets(plan, model, dragCtl,
                            newState(""), newState(""), "#tile-" & tile.id)
  dragCtl.start(closest(targets).whenFar(plan.base).withFloating(), p)

proc startRowDrag*(dragCtl: DragController[Sheet]; model: State[Sheet];
                   rowIdx: int; p: Point) =
  let plan = rowPlan(model.get(), rowIdx)
  let row = model.get().rows[rowIdx]
  let targets = planTargets(plan, model, dragCtl,
                            newState(""), newState(""), "#row-" & row.id)
  dragCtl.start(closest(targets).whenFar(plan.base).withFloating(), p)

let root = createElement("div")
let sc = beginRoot(root)
let model = newState(Sheet(rows: @[
  Row(id: "row1", color: "#f0f4ff", items: @[
    Tile(id: "A1", label: "A1"), Tile(id: "B1", label: "B1"),
    Tile(id: "C1", label: "C1")]),
  Row(id: "row2", color: "#fff4f0", items: @[
    Tile(id: "A2", label: "A2"), Tile(id: "B2", label: "B2"),
    Tile(id: "C2", label: "C2")]),
  Row(id: "row3", color: "#f0fff4", items: @[
    Tile(id: "A3", label: "A3"), Tile(id: "B3", label: "B3"),
    Tile(id: "C3", label: "C3")])]))
let dragCtl = newDragController[Sheet]()
let dragLabel = newState("")
let dragColor = newState("")
let view = RowsView(model, dragCtl, dragLabel, dragColor)

echo toHtml(root)

# A1 from row1/col0 to row2/col1.
let tile = find(root, "#tile-A1")
let rowsNode = find(root, ".rows")
discard fireAt(tile, "pointerdown", 100.0, 100.0)
let p = dragCtl.targets[4].pos
discard fireAt(rowsNode, "pointermove", p.x, p.y)
discard fireAt(rowsNode, "pointerup", p.x, p.y)
echo "A1 row/col = ", tileRow(model.get(), "A1"), "/",
     tileCol(model.get(), "A1")

# row1 below row2: row order becomes row2, row1, row3.
let grip = find(root, "#grip-row1")
discard fireAt(grip, "pointerdown", 10.0, 10.0)
let rp = dragCtl.targets[1].pos
discard fireAt(rowsNode, "pointermove", rp.x, rp.y)
discard fireAt(rowsNode, "pointerup", rp.x, rp.y)
echo "row1 index = ", rowIndex(model.get(), "row1")
echo toHtml(root)

# After the row move row2 is first, and A1 lives in row2 at index 1.
if tileRow(model.get(), "A1") != 0 or tileCol(model.get(), "A1") != 1 or
   rowIndex(model.get(), "row1") != 1:
  panic("rows drag failed")

endRoot()
dispose(sc)
