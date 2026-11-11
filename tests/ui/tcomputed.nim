import std/syncio
import yith/ui

let n = state(1)
let double = computed(proc (): int = n.get() * 2)
echo double.get()
n.set(3)
echo double.get()

let name = state("a")
let greeting = computed(proc (): string = "hi " & name.get())
echo greeting.get()
name.set("b")
echo greeting.get()
