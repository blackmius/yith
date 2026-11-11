## Declarative dragging on yith: kanban board.
##
## Each card starts a dragCtl with the set of reachable board states and their
## target positions (model-driven dragging). Pointer moves pick the closest
## target; pointer up applies its state. The ghost uses `withFloating`.
##
## Event handlers inside loops capture the loop variable by reference in
## Nimony (issue #2), so each card is a separate `CardView` component.
##
## Run with the test DOM:
##   nimony c -d:yithDomTest -p:src examples/ui/kanban.nim -o:bin/kanban
##   ./bin/kanban

import std/syncio
import yith/ui
import yith/spec
import yith/dom/api
import ./kanban_model

proc startCardDrag*(dragCtl: DragController[Board]; board: State[Board];
                    dragTask: State[int]; dragTitle: State[string];
                    taskId: int; title: string; p: Point)
proc startColumnDrag*(dragCtl: DragController[Board]; board: State[Board];
                      dragTask: State[int]; dragTitle: State[string];
                      ci: int; p: Point)

proc CardView*(board: State[Board]; dragCtl: DragController[Board];
               dragTask: State[int]; dragTitle: State[string];
               taskId: int; title: string): E {.ui.} =
  c.Div.card:
    attr.id("task-" & $taskId)
    css.height("64px")
    css.display("flex")
    css.align_items("center")
    css.padding("0 8px")
    onPointerDown(e):
      dragTask.set(taskId)
      dragTitle.set(title)
      startCardDrag(dragCtl, board, dragTask, dragTitle, taskId, title,
                    Point(x: e.clientX, y: e.clientY))
    c.Span.task_title:
      title

proc ColumnView*(board: State[Board]; dragCtl: DragController[Board];
                 dragTask: State[int]; dragTitle: State[string];
                 ci: int): E {.ui.} =
  c.Div.col:
    css.width("220px")
    css.display("flex")
    css.flex_direction("column")
    css.gap("8px")
    css.padding("8px")
    cls.drop(isDropColumn(dragCtl, dragTask.get(), ci))
    c.Div.col_head:
      attr.id("col-" & board.get().columns[ci].id)
      css.height("32px")
      css.display("flex")
      css.align_items("center")
      onPointerDown(e):
        dragTask.set(0)
        dragTitle.set(board.get().columns[ci].title)
        startColumnDrag(dragCtl, board, dragTask, dragTitle, ci,
                        Point(x: e.clientX, y: e.clientY))
      c.Span.col_title:
        board.get().columns[ci].title
    var ti = 0
    while ti < board.get().columns[ci].tasks.len:
      CardView(board, dragCtl, dragTask, dragTitle,
        board.get().columns[ci].tasks[ti].id,
        board.get().columns[ci].tasks[ti].title)
      inc ti

proc KanbanView*(board: State[Board]; dragCtl: DragController[Board];
                 dragTask: State[int]; dragTitle: State[string]): E {.ui.} =
  c.Div.board:
    css.display("flex")
    css.align_items("flex-start")
    css.gap("16px")
    css.padding("20px")
    onPointerMove(e):
      if dragCtl.active.get():
        discard dragCtl.move(Point(x: e.clientX, y: e.clientY))
    onPointerUp(e):
      if dragCtl.active.get():
        discard dragCtl.finish()
        if dragCtl.hasDrop():
          board.set(dragCtl.chosen().state)
        dragTask.set(0)
        dragTitle.set("")
    uiBlock(proc () {.closure.} =
      var ci = 0
      while ci < board.get().columns.len:
        ColumnView(board, dragCtl, dragTask, dragTitle, ci)
        inc ci
      if dragCtl.active.get():
        c.Div.ghost:
          css.position("fixed")
          css.left($dragCtl.pointer.get().x & "px")
          css.top($dragCtl.pointer.get().y & "px")
          c.Span.task_title:
            dragTitle.get())


proc renderBoard(s: Board; model: State[Board];
                 dragCtl: DragController[Board];
                 dragTask: State[int]; dragTitle: State[string]): E =
  model.set(s)
  result = KanbanView(model, dragCtl, dragTask, dragTitle)

proc boardTargets(states: seq[Board]; selector: string): seq[DragTarget[Board]] =
  let tmp = newState(initialBoard())
  let rc = newDragController[Board]()
  let t = newState(0)
  let ti = newState("")
  result = speculativeTargets(states,
    proc (s: Board): E {.closure.} =
      renderBoard(s, tmp, rc, t, ti),
    selector)

proc startCardDrag*(dragCtl: DragController[Board]; board: State[Board];
                    dragTask: State[int]; dragTitle: State[string];
                    taskId: int; title: string; p: Point) =
  let drag = buildDrag(board.get(), taskId)
  let targets = boardTargets(drag.states, "#task-" & $taskId)
  dragCtl.start(closest(targets).withFloating(), p)

proc startColumnDrag*(dragCtl: DragController[Board]; board: State[Board];
                      dragTask: State[int]; dragTitle: State[string];
                      ci: int; p: Point) =
  let states = buildColumnDrag(board.get(), ci)
  let col = board.get().columns[ci]
  let targets = boardTargets(states, "#col-" & col.id)
  dragCtl.start(closest(targets).withFloating(), p)

let root1 = createElement("div")
let sc1 = beginRoot(root1)
let board1 = newState(initialBoard())
let drag1 = newDragController[Board]()
let dragTask1 = newState(0)
let dragTitle1 = newState("")
let view1 = KanbanView(board1, drag1, dragTask1, dragTitle1)

let card = find(root1, "#task-1")
let boardNode1 = find(root1, ".board")
discard fireAt(card, "pointerdown", 100.0, 100.0)
let target = drag1.targets[2].pos
discard fireAt(boardNode1, "pointermove", target.x, target.y)
discard fireAt(boardNode1, "pointerup", target.x, target.y)
let cardColumn = columnOfTask(board1.get(), 1)
echo "card column = ", cardColumn
echo toHtml(root1)
endRoot()
dispose(sc1)

# Scenario 2: column Todo moves to index 2.
let root2 = createElement("div")
let sc2 = beginRoot(root2)
let board2 = newState(initialBoard())
let drag2 = newDragController[Board]()
let dragTask2 = newState(0)
let dragTitle2 = newState("")
let view2 = KanbanView(board2, drag2, dragTask2, dragTitle2)

let todoHead = find(root2, "#col-todo")
let boardNode2 = find(root2, ".board")
discard fireAt(todoHead, "pointerdown", 50.0, 20.0)
let colTarget = drag2.targets[2].pos
discard fireAt(boardNode2, "pointermove", colTarget.x, colTarget.y)
discard fireAt(boardNode2, "pointerup", colTarget.x, colTarget.y)
let todoColumn = columnIndex(board2.get(), "todo")
echo "todo column = ", todoColumn
echo toHtml(root2)

if cardColumn != 1 or todoColumn != 2:
  panic("kanban drag failed")

endRoot()
dispose(sc2)
