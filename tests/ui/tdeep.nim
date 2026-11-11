## Hand-written proxy/store model for the deep-signal design (DESIGN §3.7).
## The compiler sugar (`a.q.x = 10`) is not implemented here; this test
## validates that the runtime composition and recursive proxy types work at
## arbitrary depth.

{.feature: "lenientnils".}
{.feature: "assumeSync".}

import std/syncio
import yith/core

type
  FieldRef[T] = ref object
    value: State[T]

proc field[T](v: T): FieldRef[T] =
  FieldRef[T](value: newState(v))

proc get[T](f: FieldRef[T]): T =
  f.value.get()

proc set[T](f: FieldRef[T]; v: T) =
  f.value.set(v)

type
  B = object
    x: int
  A = object
    q: B

  BRef = ref object
    x: FieldRef[int]
  ARef = ref object
    q: BRef

  SeqA = ref object
    items: seq[ARef]
  SeqSeqA = ref object
    items: seq[SeqA]
  SeqSeqSeqA = ref object
    items: seq[SeqSeqA]

proc get(r: BRef): B = B(x: r.x.get())
proc get(r: ARef): A = A(q: r.q.get())

proc `[]`(s: SeqA; i: int): ARef = s.items[i]
proc `[]`(s: SeqSeqA; i: int): SeqA = s.items[i]
proc `[]`(s: SeqSeqSeqA; i: int): SeqSeqA = s.items[i]

# A recursive type: Node contains seq[Node].
type
  Node = object
    x: int
    children: seq[Node]
  NodeRef = ref object
    x: FieldRef[int]
    children: SeqNode
  SeqNode = ref object
    items: seq[NodeRef]

proc `[]`(s: SeqNode; i: int): NodeRef = s.items[i]

proc main() =
  # 1. object -> object -> field
  let b = BRef(x: field(2))
  let a = ARef(q: b)
  a.q.x.set 10
  echo "a.q.x = ", a.q.x.get()
  echo "snapshot = ", a.get().q.x

  # proxy is a reference, not a copy
  let q = a.q
  q.x.set 20
  echo "via proxy = ", a.q.x.get()

  # 2. seq -> seq -> seq -> object -> object -> field
  let t = SeqSeqSeqA(items: @[
    SeqSeqA(items: @[
      SeqA(items: @[a])
    ])
  ])
  t[0][0][0].q.x.set 7
  echo "nested = ", t[0][0][0].q.x.get()

  # 3. recursive Node: Node -> seq[Node] -> Node -> field
  let child = NodeRef(x: field(5), children: SeqNode(items: @[]))
  let root = NodeRef(x: field(1), children: SeqNode(items: @[child]))
  root.children[0].x.set 6
  echo "recursive = ", root.children[0].x.get()

main()
