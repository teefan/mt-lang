# POC 022 — SoA and atomic: SoA[T,N] construction and indexed access,
# atomic[T] store, load, add.

struct Point:
    x: float
    y: float

function main() -> int:
    # SoA construction and access
    var soa: SoA[Point, 4]
    soa[0].x = 1.0
    soa[0].y = 2.0
    soa[1].x = 3.0
    soa[1].y = 4.0
    let v = soa[0].x
    let _v = v

    # atomic[T] store, load, add
    var atom: atomic[int]
    atom.store(42)
    let l = atom.load()
    let _l = l
    atom.add(1)

    # atomic[bool]
    var atom_b: atomic[bool]
    atom_b.store(true)
    let lb = atom_b.load()
    let _lb = lb

    return 0
