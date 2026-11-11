## Pure kanban model + model-driven drag target builders.
## Shared by the C/test-DOM example and the browser wrapper.

import yith/core
import yith/drag

type
  Task* = object
    id*: int
    title*: string

  Column* = object
    id*: string
    title*: string
    tasks*: seq[Task]

  Board* = object
    columns*: seq[Column]

  Extracted* = object
    board*: Board
    task*: Task
    found*: bool

  KanbanDrag* = object
    task*: Task
    states*: seq[Board]

proc copyTasks(tasks: seq[Task]): seq[Task] =
  result = @[]
  var i = 0
  while i < tasks.len:
    result.add tasks[i]
    inc i

proc cloneBoard(b: Board): Board =
  result = Board(columns: @[])
  var i = 0
  while i < b.columns.len:
    result.columns.add Column(id: b.columns[i].id,
                              title: b.columns[i].title,
                              tasks: copyTasks(b.columns[i].tasks))
    inc i

proc insertTask(tasks: seq[Task]; index: int; task: Task): seq[Task] =
  result = @[]
  var i = 0
  while i < tasks.len:
    if i == index:
      result.add task
    result.add tasks[i]
    inc i
  if index >= tasks.len:
    result.add task

proc withTaskAt(base: Board; ci, pos: int; task: Task): Board =
  result = Board(columns: @[])
  var i = 0
  while i < base.columns.len:
    let tasks = if i == ci:
        insertTask(base.columns[i].tasks, pos, task)
      else:
        copyTasks(base.columns[i].tasks)
    result.columns.add Column(id: base.columns[i].id,
                              title: base.columns[i].title, tasks: tasks)
    inc i

proc extractTask*(b: Board; id: int): Extracted =
  result = Extracted(board: cloneBoard(b), found: false)
  var ci = 0
  while ci < result.board.columns.len:
    var ti = 0
    while ti < result.board.columns[ci].tasks.len:
      if result.board.columns[ci].tasks[ti].id == id:
        result.task = result.board.columns[ci].tasks[ti]
        result.board.columns[ci].tasks.delete ti
        result.found = true
        return
      inc ti
    inc ci

proc buildDrag*(b: Board; id: int): KanbanDrag =
  let ex = extractTask(b, id)
  result = KanbanDrag(task: ex.task, states: @[])
  if not ex.found:
    return
  var ci = 0
  while ci < ex.board.columns.len:
    var pos = 0
    while pos <= ex.board.columns[ci].tasks.len:
      result.states.add withTaskAt(ex.board, ci, pos, ex.task)
      inc pos
    inc ci

proc columnOfTask*(b: Board; id: int): int =
  result = -1
  var ci = 0
  while ci < b.columns.len:
    var ti = 0
    while ti < b.columns[ci].tasks.len:
      if b.columns[ci].tasks[ti].id == id:
        return ci
      inc ti
    inc ci


proc isDropColumn*(dragCtl: DragController[Board]; taskId: int;
                   ci: int): bool =
  if not dragCtl.active.get() or taskId == 0:
    return false
  let idx = dragCtl.target.get()
  if idx < 0 or idx >= dragCtl.targets.len:
    return false
  result = columnOfTask(dragCtl.targets[idx].state, taskId) == ci

proc columnIndex*(b: Board; id: string): int =
  result = -1
  var ci = 0
  while ci < b.columns.len:
    if b.columns[ci].id == id:
      return ci
    inc ci

proc removeColumnState*(b: Board; ci: int): Board =
  result = Board(columns: @[])
  var i = 0
  while i < b.columns.len:
    if i != ci:
      result.columns.add b.columns[i]
    inc i

proc insertColumnState*(b: Board; ci: int; col: Column): Board =
  result = Board(columns: @[])
  var i = 0
  while i < b.columns.len:
    if i == ci:
      result.columns.add col
    result.columns.add b.columns[i]
    inc i
  if ci >= b.columns.len:
    result.columns.add col

proc buildColumnDrag*(b: Board; ci: int): seq[Board] =
  result = @[]
  let base = removeColumnState(b, ci)
  let col = b.columns[ci]
  var i = 0
  while i <= base.columns.len:
    result.add insertColumnState(base, i, col)
    inc i


proc initialBoard*(): Board =
  Board(columns: @[
    Column(id: "todo", title: "Todo", tasks: @[
      Task(id: 1, title: "Write drag spec"),
      Task(id: 2, title: "Test edge cases")]),
    Column(id: "doing", title: "Doing", tasks: @[
      Task(id: 3, title: "Render board")]),
    Column(id: "done", title: "Done", tasks: @[])])

