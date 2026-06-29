# POC 024 — Dyn interface: dyn[Interface] runtime dispatch, adapt[I], method
# call through dyn.

interface Speaker:
    function speak() -> str

struct Person implements Speaker:
    name: str

extending Person:
    function speak() -> str:
        return this.name

function greet(s: dyn[Speaker]):
    let _m = s.speak()

function main() -> int:
    var p = Person(name = "Alice")

    # adapt and dyn dispatch
    let d: dyn[Speaker] = adapt[Speaker](ref_of(p))
    let msg = d.speak()
    let _msg = msg

    # pass dyn to function
    greet(s = d)

    return 0
