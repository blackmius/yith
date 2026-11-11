import std/syncio
import std/options
import yith/core

type User = object
  name: string

let u: Option[User] = none[User]()
echo u.isSome

let n = newState(none[int]())
echo n.get().isSome
n.set(some(3))
echo n.get().get()
echo n.get().map(proc (x: int): string = $x).get("")
