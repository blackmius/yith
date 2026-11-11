## Pure drag-controller tests: closest, whenFar, withFloating.
import std/syncio
import yith/drag

let targets = @[
  DragTarget[int](state: 1, pos: Point(x: 0.0, y: 0.0)),
  DragTarget[int](state: 2, pos: Point(x: 100.0, y: 0.0))]

let d = newDragController[int]()
let behavior = closest(targets).whenFar(9, 10.0).withFloating()

d.start(behavior, Point(x: 1.0, y: 0.0))
echo "near=", d.target.get(), " far=", d.far.get(), " floating=", d.floating

discard d.move(Point(x: 99.0, y: 0.0))
echo "second=", d.target.get(), " far=", d.far.get()

discard d.move(Point(x: 100.0, y: 100.0))
echo "away=", d.target.get(), " far=", d.far.get(), " drop=", d.hasDrop(),
     " state=", d.chosen().state

discard d.finish()
if d.chosen().state != 9:
  panic("whenFar fallback failed")
if d.floating != true:
  panic("withFloating flag failed")
