## Browser wrapper for the kanban declarative-drag example.
##
## Browser wrapper for the same model-driven drag, built with the low-level
## runtime primitives. Build with:
##   examples/ui/build_kanban_js.sh

{.feature: "assumeSync".}

import std/syncio
import yith/dom/api
import yith/core
import yith/dsl
import yith/drag
import yith/spec
import ./kanban_model

var board: State[Board] = newState(initialBoard())
var dragCtl: DragController[Board] = newDragController[Board]()
var dragTask: State[int] = newState(0)
var dragTitle: State[string] = newState("")

proc startCardDrag(dragCtl: DragController[Board]; board: State[Board];
                   dragTask: State[int]; dragTitle: State[string];
                   taskId: int; title: string; p: Point)
proc startColumnDrag(dragCtl: DragController[Board]; board: State[Board];
                     dragTask: State[int]; dragTitle: State[string];
                     ci: int; p: Point)

proc cardView(board: State[Board]; dragCtl: DragController[Board];
              dragTask: State[int]; dragTitle: State[string];
              taskId: int; title: string): E =
  result = ElE("div"):
    Text(title)
  addClass(result, "card")
  setAttr(result, "id", "task-" & $taskId)
  on(result, "pointerdown", proc (e: Event) {.closure.} =
    dragTask.set(taskId)
    dragTitle.set(title)
    startCardDrag(dragCtl, board, dragTask, dragTitle, taskId, title,
                  Point(x: e.clientX, y: e.clientY)))

proc columnView(board: State[Board]; dragCtl: DragController[Board];
                dragTask: State[int]; dragTitle: State[string];
                ci: int; title: string): E =
  result = ElE("div"):
    let head = ElE("div"):
      Text(title)
    addClass(head, "col-head")
    setAttr(head, "id", "col-" & board.get().columns[ci].id)
    on(head, "pointerdown", proc (e: Event) {.closure.} =
      dragTask.set(0)
      dragTitle.set(title)
      startColumnDrag(dragCtl, board, dragTask, dragTitle, ci,
                      Point(x: e.clientX, y: e.clientY)))
    var ti = 0
    while ti < board.get().columns[ci].tasks.len:
      discard cardView(board, dragCtl, dragTask, dragTitle,
        board.get().columns[ci].tasks[ti].id,
        board.get().columns[ci].tasks[ti].title)
      inc ti
  addClass(result, "col")
  if isDropColumn(dragCtl, dragTask, ci):
    addClass(result, "drop")

proc boardView(board: State[Board]; dragCtl: DragController[Board];
               dragTask: State[int]; dragTitle: State[string]): E =
  result = ElE("div"):
    uiBlock(proc () {.closure.} =
      var ci = 0
      while ci < board.get().columns.len:
        discard columnView(board, dragCtl, dragTask, dragTitle, ci,
                           board.get().columns[ci].title)
        inc ci
      if dragCtl.active.get():
        let ghost = ElE("div"):
          Text(dragTitle.get())
        addClass(ghost, "ghost")
        addStyle(ghost, "position", "fixed")
        addStyle(ghost, "left", $dragCtl.pointer.get().x & "px")
        addStyle(ghost, "top", $dragCtl.pointer.get().y & "px"))
  addClass(result, "board")
  on(result, "pointermove", proc (e: Event) {.closure.} =
    if dragCtl.active.get():
      discard dragCtl.move(Point(x: e.clientX, y: e.clientY)))
  on(result, "pointerup", proc (e: Event) {.closure.} =
    if dragCtl.active.get():
      discard dragCtl.finish()
      if dragCtl.hasDrop():
        board.set(dragCtl.chosen().state)
      dragTask.set(0)
      dragTitle.set(""))


proc renderBoard(s: Board; model: State[Board];
                 dragCtl: DragController[Board];
                 dragTask: State[int]; dragTitle: State[string]): E =
  model.set(s)
  result = boardView(model, dragCtl, dragTask, dragTitle)

proc boardTargets(states: seq[Board]; selector: string): seq[DragTarget[Board]] =
  let tmp = newState(initialBoard())
  let rc = newDragController[Board]()
  let t = newState(0)
  let ti = newState("")
  result = speculativeTargets(states,
    proc (s: Board): E {.closure.} =
      renderBoard(s, tmp, rc, t, ti),
    selector)

proc startCardDrag(dragCtl: DragController[Board]; board: State[Board];
                   dragTask: State[int]; dragTitle: State[string];
                   taskId: int; title: string; p: Point) =
  let drag = buildDrag(board.get(), taskId)
  let targets = boardTargets(drag.states, "#task-" & $taskId)
  dragCtl.start(closest(targets).withFloating(), p)

proc startColumnDrag(dragCtl: DragController[Board]; board: State[Board];
                     dragTask: State[int]; dragTitle: State[string];
                     ci: int; p: Point) =
  let states = buildColumnDrag(board.get(), ci)
  let col = board.get().columns[ci]
  let targets = boardTargets(states, "#col-" & col.id)
  dragCtl.start(closest(targets).withFloating(), p)

proc debugState() {.exportc: "debugState".} =
  echo "active=", dragCtl.active.get(), " target=", dragCtl.target.get(),
       " far=", dragCtl.far.get(), " targets=", dragCtl.targets.len
  flushFile(stdout)

proc start(parent: Node) {.exportc: "start".} =
  board = newState(initialBoard())
  dragCtl = newDragController[Board]()
  dragTask = newState(0)
  dragTitle = newState("")
  discard beginRoot(parent)
  discard boardView(board, dragCtl, dragTask, dragTitle)
  flushFile(stdout)

echo "init"
flushFile(stdout)
