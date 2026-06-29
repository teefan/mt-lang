# POC 014 — Interfaces and implements: interface declaration, struct implements,
# generic constraint with multiple interfaces, dyn[I] + adapt[I], default[T].

interface Showable:
    function show() -> str

interface Named:
    function name() -> str

struct Item implements Showable, Named:
    label: str

extending Item:
    function show() -> str:
        return this.label

    function name() -> str:
        return this.label

    static function default() -> Item:
        return Item(label = "")

function do_show[T implements Showable](val: T) -> str:
    return val.show()

function main() -> int:
    var item = Item(label = "test")

    # method calls
    let msg = item.show()
    let _msg = msg
    let nm = item.name()
    let _nm = nm

    # dyn[I] + adapt
    let d: dyn[Showable] = adapt[Showable](ref_of(item))
    let m2 = d.show()
    let _m2 = m2

    # generic function with constraint
    let gs = do_show(item)
    let _gs = gs

    # default[T]
    let def_item = default[Item]
    let _di = def_item

    return 0
