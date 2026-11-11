## Declarative dragging on yith: kanban board.
##
## Each card/column builds the set of reachable board states. Their drop
## positions are measured by rendering candidates into the hidden DOM host
## (`speculativeTargets`); nothing here computes card/column coordinates.
## Pointer moves preview the chosen state through normal CSS layout; the ghost
## uses `withFloating`. The board is re-rendered only when the drop target
## changes, not on every pixel of pointer movement.
##
## Event handlers inside loops capture the loop variable by reference in
## Nimony (issue #2), so each card is a separate `CardView` component.
##
## Run with the test DOM:
##   nimony c -d:yithDomTest -p:src examples/ui/kanban.nim -o:bin/kanban
##   ./bin/kanban

{.feature: "assumeSync".}

import std/syncio
import yith/ui
import yith/spec
import yith/dom/api
import ./kanban_model

const kanbanBuild* = "cyclefix-4"

var
  board: State[Board]
  dragCtl: DragController[Board] = newDragController[Board]()
  dragStart: State[Board]
  dragTask: State[int]
  dragTitle: State[string]
  liveRoot: Node

proc startCardDrag*(dragCtl: DragController[Board]; board: State[Board];
                    dragTask: State[int]; dragTitle: State[string];
                    taskId: int; title: string; p: Point)
proc startColumnDrag*(dragCtl: DragController[Board]; board: State[Board];
                      dragTask: State[int]; dragTitle: State[string];
                      columnId: string; p: Point)

proc CardView*(board: State[Board]; dragCtl: DragController[Board];
               dragTask: State[int]; dragTitle: State[string];
               taskId: int; title: string): E {.ui.} =
  c.Div.card:
    attr.id("task-" & $taskId)
    css.height("64px")
    css.display("flex")
    css.align_items("center")
    css.padding("0 8px")
    cls.dragging(dragCtl.active.get() and dragTask.get() == taskId)
    onPointerDown(e):
      if debugLogEnabled:
        debugLog("pointerdown card " & $taskId)
      dragStart.set(board.get())
      dragTask.set(taskId)
      dragTitle.set(title)
      startCardDrag(dragCtl, board, dragTask, dragTitle, taskId, title,
                    Point(x: e.clientX, y: e.clientY))
    c.Span.task_title:
      title

proc ColumnView*(board: State[Board]; column: State[Column];
                 dragCtl: DragController[Board];
                 dragTask: State[int]; dragTitle: State[string]): E {.ui.} =
  c.Div.col:
    css.width("220px")
    css.display("flex")
    css.flex_direction("column")
    css.gap("8px")
    css.padding("8px")
    cls.drop(isDropColumn(dragCtl, dragTask.get(), column.get().id))
    cls.dragging(dragCtl.active.get() and dragTask.get() == 0 and
      dragTitle.get() == column.get().title)
    c.Div.col_head:
      attr.id("col-" & column.get().id)
      css.height("32px")
      css.display("flex")
      css.align_items("center")
      onPointerDown(e):
        if debugLogEnabled:
          debugLog("pointerdown column " & column.get().id)
        dragStart.set(board.get())
        dragTask.set(0)
        dragTitle.set(column.get().title)
        startColumnDrag(dragCtl, board, dragTask, dragTitle,
                        column.get().id, Point(x: e.clientX, y: e.clientY))
      c.Span.col_title:
        column.get().title
    for task in column.get().tasks:
      CardView(board, dragCtl, dragTask, dragTitle, task.id, task.title)

proc KanbanView*(board: State[Board]; dragCtl: DragController[Board];
                 dragTask: State[int]; dragTitle: State[string]): E {.ui.} =
  c.Div.board:
    css.display("flex")
    css.align_items("flex-start")
    css.gap("16px")
    css.padding("20px")
    onPointerMove(e):
      if dragCtl.active.get():
        let prevTarget = dragCtl.target.get()
        let prevFar = dragCtl.far.get()
        discard dragCtl.move(Point(x: e.clientX, y: e.clientY))
        # Re-render the board only when the drop target changes. Rebuilding
        # the whole column tree on every pointer move is both expensive and
        # what made long drags exhaust the JS backend's shadow stack.
        if dragCtl.target.get() != prevTarget or dragCtl.far.get() != prevFar:
          board.set(dragCtl.previewState(dragStart.get()))
    onPointerUp(e):
      if debugLogEnabled:
        debugLog("pointerup")
      if dragCtl.active.get():
        discard dragCtl.finish()
        if dragCtl.hasDrop():
          board.set(dragCtl.chosen().state)
        else:
          board.set(dragStart.get())
        dragTask.set(0)
        dragTitle.set("")
    uiBlock(proc () {.closure.} =
      for column in board.get().columns:
        ColumnView(board, newState(column), dragCtl, dragTask, dragTitle)
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
    selector, liveRoot)

proc startCardDrag*(dragCtl: DragController[Board]; board: State[Board];
                    dragTask: State[int]; dragTitle: State[string];
                    taskId: int; title: string; p: Point) =
  let states = buildDrag(board.get(), taskId)
  let targets = boardTargets(states, "#task-" & $taskId)
  dragCtl.start(closest(targets).withFloating(), p)

proc startColumnDrag*(dragCtl: DragController[Board]; board: State[Board];
                      dragTask: State[int]; dragTitle: State[string];
                      columnId: string; p: Point) =
  let ci = columnIndex(board.get(), columnId)
  if ci < 0:
    return
  let states = buildColumnDrag(board.get(), ci)
  let targets = boardTargets(states, "#col-" & columnId)
  dragCtl.start(closest(targets).withFloating(), p)

proc beginKanban(parent: Node): Scope =
  liveRoot = parent
  board = newState(initialBoard())
  dragCtl = newDragController[Board]()
  dragStart = newState(board.get())
  dragTask = newState(0)
  dragTitle = newState("")
  debugFocusSigs = @[signalId(dragStart), signalId(dragTask),
                     signalId(dragTitle), signalId(board),
                     signalId(dragCtl.active), signalId(dragCtl.target),
                     signalId(dragCtl.pointer)]
  result = beginRoot(parent)
  discard KanbanView(board, dragCtl, dragTask, dragTitle)

proc start(parent: Node) {.exportc: "start".} =
  debugLogEnabled = true
  debugLog("yith kanban " & kanbanBuild)
  discard beginKanban(parent)
  captureStackBase()
  flushFile(stdout)

proc debugState() {.exportc: "debugState".} =
  echo "active=", dragCtl.active.get(), " target=", dragCtl.target.get(),
       " far=", dragCtl.far.get(), " targets=", dragCtl.targets.len
  var i = 0
  while i < dragCtl.targets.len:
    echo "  target ", i, ": ", dragCtl.targets[i].pos.x, ",",
         dragCtl.targets[i].pos.y
    inc i
  flushFile(stdout)

proc debugSignals() {.exportc: "debugSignals".} =
  ## Print the live subscriber counts and pending work. Call from the browser
  ## console as `NIF.debugSignals()`; a crash while walking a list means that
  ## signal's Sub chain is already corrupted.
  debugLog("signals start sig=" & $signalId(dragStart) &
           " subs=" & $subscriberCount(dragStart) &
           " | task sig=" & $signalId(dragTask) &
           " subs=" & $subscriberCount(dragTask) &
           " | title sig=" & $signalId(dragTitle) &
           " subs=" & $subscriberCount(dragTitle) &
           " | board sig=" & $signalId(board) &
           " subs=" & $subscriberCount(board))

proc setDebug(b: bool) {.exportc: "setDebug".} =
  debugLogEnabled = b

proc dumpLog() {.exportc: "dumpLog".} =
  dumpDebugLog()

proc clearLog() {.exportc: "clearLog".} =
  clearDebugLog()

proc debugMemory() {.exportc: "debugMemory".} =
  debugLog(memoryInfo())

proc logMem() {.exportc: "logMem".} =
  ## Print allocator counters, JS buffer/pages and shadow-stack depth.
  debugLog(memStats() & " | " & memoryInfo() & " | " & stackInfo())

proc memWatch(ms: int) {.exportc: "memWatch".} =
  ## `NIF.memWatch(5000)` starts a periodic `logMem` in the browser console.
  startMemWatch(ms)

proc memWatchStop() {.exportc: "memWatchStop".} =
  stopMemWatch()

proc testGet() {.exportc: "testGet".} =
  ## Stack-leak bisect: many tracked reads in one effect.
  debugLog("testGet before " & stackInfo())
  let sc = effect(proc () {.closure.} =
    var i = 0
    while i < 10000:
      discard board.get()
      inc i)
  debugLog("testGet effect " & stackInfo())
  dispose(sc)
  debugLog("testGet dispose " & stackInfo())

proc dumpMemory() {.exportc: "dumpMemory".} =
  debugLog(memoryInfo())

proc dumpStack() {.exportc: "dumpStack".} =
  debugLog(stackInfo())

when defined(yithDomTest):
  let root1 = createElement("div")
  let sc1 = beginKanban(root1)

  let card = find(root1, "#task-1")
  let boardNode1 = find(root1, ".board")
  discard fireAt(card, "pointerdown", 100.0, 100.0)
  let target = dragCtl.targets[2].pos
  discard fireAt(boardNode1, "pointermove", target.x, target.y)
  discard fireAt(boardNode1, "pointerup", target.x, target.y)
  let cardColumn = columnOfTask(board.get(), 1)
  echo "card column = ", cardColumn
  echo toHtml(root1)
  endRoot()
  dispose(sc1)

  # Scenario 2: column Todo moves to index 2.
  let root2 = createElement("div")
  let sc2 = beginKanban(root2)

  let todoHead = find(root2, "#col-todo")
  let boardNode2 = find(root2, ".board")
  discard fireAt(todoHead, "pointerdown", 50.0, 20.0)
  let colTarget = dragCtl.targets[2].pos
  discard fireAt(boardNode2, "pointermove", colTarget.x, colTarget.y)
  discard fireAt(boardNode2, "pointerup", colTarget.x, colTarget.y)
  let todoColumn = columnIndex(board.get(), "todo")
  echo "todo column = ", todoColumn
  echo toHtml(root2)

  if cardColumn != 1 or todoColumn != 2:
    panic("kanban drag failed")

  endRoot()
  dispose(sc2)
else:
  echo "init ", kanbanBuild
  flushFile(stdout)
