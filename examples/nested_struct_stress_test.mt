## Nested Struct Stress Test
##
## Exercises nested struct declaration, resolution, type-checking,
## lowering, and C code generation across a range of edge cases.
##
## Each function exercises a specific scenario.  The entrypoint
## `main` calls them all and returns a checksum-like total so
## that an end-to-end run confirms correctness.

# ---------------------------------------------------------------------------
# 1  Basic nested struct — fields before and after
# ---------------------------------------------------------------------------

struct Rectangle:
    x: float
    y: float

    struct Edge:
        start: float
        end: float

    top_edge: Edge
    left_edge: Edge
    width: float
    height: float

function basic_nested_demo() -> float:
    var r: Rectangle
    r.x = 1.0
    r.width = 10.0
    r.top_edge.start = 3.0
    return r.x + r.width + r.top_edge.start

# ---------------------------------------------------------------------------
# 2  Multiple sibling nested structs
# ---------------------------------------------------------------------------

struct ShapeGroup:
    struct CircleData:
        radius: float
        segments: int

    struct RectData:
        w: float
        h: float

    kind: int
    circle: CircleData
    rect: RectData

function multi_sibling_demo() -> float:
    var sg: ShapeGroup
    sg.kind = 1
    sg.circle.radius = 5.0
    sg.rect.w = 4.0
    return sg.circle.radius + sg.rect.w

# ---------------------------------------------------------------------------
# 3  Deeply nested structs (3 levels)
# ---------------------------------------------------------------------------

struct Level1:
    data: int

    struct Level2:
        tag: int

        struct Level3:
            value: float

        inner: Level3

    mid: Level2

function deeply_nested_demo() -> float:
    var l1: Level1
    l1.data = 1
    l1.mid.tag = 2
    l1.mid.inner.value = 3.0
    return float<-(l1.data) + float<-(l1.mid.tag) + l1.mid.inner.value

# ---------------------------------------------------------------------------
# 4  Qualified-name access to deeply nested struct
# ---------------------------------------------------------------------------

function qualified_nested_demo() -> float:
    var v: Level1.Level2.Level3
    v.value = 7.5
    return v.value

# ---------------------------------------------------------------------------
# 5  Nested struct with @[packed] attribute
# ---------------------------------------------------------------------------

struct OuterPacked:
    header: int

    @[packed]
    struct InnerPacked:
        a: ubyte
        b: ubyte
        c: ubyte

    body: InnerPacked

function packed_nested_demo() -> float:
    var op: OuterPacked
    op.header = 1
    op.body.a = 10
    op.body.b = 20
    return float<-(op.header) + float<-(op.body.a) + float<-(op.body.b)

# ---------------------------------------------------------------------------
# 6  Nested struct with events
# ---------------------------------------------------------------------------

struct EventContainer:
    name: str

    struct EventPayload:
        code: int
        message: str

    public event updated[4](EventPayload)

function event_nested_demo() -> int:
    var ec: EventContainer
    ec.name = "test"
    return 1

# ---------------------------------------------------------------------------
# 7  Struct with ONLY nested structs (no direct fields)
# ---------------------------------------------------------------------------

struct Group:
    struct A:
        x: int

    struct B:
        y: int

function only_nested_demo() -> int:
    var g: Group
    return 1

# ---------------------------------------------------------------------------
# 8  Nested struct fields referencing sibling nested types
# ---------------------------------------------------------------------------

struct NodeTree:
    value: int

    struct Node:
        key: str
        val: int

    struct Link:
        from_node: Node
        to_node: Node

    root: Node
    connection: Link

function sibling_ref_demo() -> int:
    var nt: NodeTree
    nt.root.key = "root"
    nt.root.val = 1
    nt.connection.from_node.key = "src"
    nt.connection.from_node.val = 2
    nt.connection.to_node.val = 3
    return nt.root.val + nt.connection.from_node.val + nt.connection.to_node.val

# ---------------------------------------------------------------------------
# 9  Function parameter using nested type
# ---------------------------------------------------------------------------

function move_edge(e: ref[Rectangle.Edge], dx: float, dy: float) -> void:
    e.start += dx
    e.end += dy

function param_nested_demo() -> float:
    var edge: Rectangle.Edge
    edge.start = 0.0
    edge.end = 1.0
    move_edge(ref_of(edge), 2.0, 3.0)
    return edge.start + edge.end

# ---------------------------------------------------------------------------
# 10  Mixed inline with block-bodied const containing nested struct
# ---------------------------------------------------------------------------

struct MixContainer:
    label: str

    struct Stats:
        min_val: float
        max_val: float

function mixed_inline_demo() -> float:
    var mc: MixContainer
    mc.label = "mix"
    mc.label = "updated"
    return 1.0

# ---------------------------------------------------------------------------
# 11  Extending a nested struct via its qualified name
# ---------------------------------------------------------------------------

extending Rectangle.Edge:
    function length() -> float:
        return this.end - this.start

function extend_nested_demo() -> float:
    var e: Rectangle.Edge
    e.start = 0.0
    e.end = 10.0
    return e.length()

# ---------------------------------------------------------------------------
# 12  Entrypoint
# ---------------------------------------------------------------------------

function main() -> int:
    var total: int = 0

    total += int<-(basic_nested_demo())
    total += int<-(multi_sibling_demo())
    total += int<-(deeply_nested_demo())
    total += int<-(qualified_nested_demo())
    total += int<-(packed_nested_demo())
    total += int<-(event_nested_demo())
    total += int<-(only_nested_demo())
    total += int<-(sibling_ref_demo())
    total += int<-(param_nested_demo())
    total += int<-(mixed_inline_demo())
    total += int<-(extend_nested_demo())

    return total
