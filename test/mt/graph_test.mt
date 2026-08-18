## Graph pathfinding tests — Dijkstra and A*.
## Run via `mtc test test/mt/`.

import std.graph as gmod


# ── helpers ──

function build_triangle() -> gmod.Graph[str]:
    var g = gmod.Graph[str].create()
    let _a = g.add_node("A")
    let _b = g.add_node("B")
    let _c = g.add_node("C")
    g.add_weighted_edge(0, 1, 2.0)
    g.add_weighted_edge(1, 2, 3.0)
    g.add_weighted_edge(0, 2, 10.0)
    return g


function build_grid() -> gmod.Graph[str]:
    var g = gmod.Graph[str].create()
    var i: ptr_uint = 0
    while i < 9:
        let _x = g.add_node("node")
        i += 1
    g.add_weighted_edge(0, 1, 1.0)
    g.add_weighted_edge(1, 0, 1.0)
    g.add_weighted_edge(1, 2, 1.0)
    g.add_weighted_edge(2, 1, 1.0)
    g.add_weighted_edge(3, 4, 1.0)
    g.add_weighted_edge(4, 3, 1.0)
    g.add_weighted_edge(4, 5, 1.0)
    g.add_weighted_edge(5, 4, 1.0)
    g.add_weighted_edge(6, 7, 1.0)
    g.add_weighted_edge(7, 6, 1.0)
    g.add_weighted_edge(7, 8, 1.0)
    g.add_weighted_edge(8, 7, 1.0)
    g.add_weighted_edge(0, 3, 1.0)
    g.add_weighted_edge(3, 0, 1.0)
    g.add_weighted_edge(3, 6, 1.0)
    g.add_weighted_edge(6, 3, 1.0)
    g.add_weighted_edge(1, 4, 1.0)
    g.add_weighted_edge(4, 1, 1.0)
    g.add_weighted_edge(4, 7, 1.0)
    g.add_weighted_edge(7, 4, 1.0)
    g.add_weighted_edge(2, 5, 1.0)
    g.add_weighted_edge(5, 2, 1.0)
    g.add_weighted_edge(5, 8, 1.0)
    g.add_weighted_edge(8, 5, 1.0)
    return g


function dist(n: ptr_uint) -> float:
    # Manhattan distance from node n to node 8 (bottom-right, 2,2).
    let col = float<-(n % 3)
    let row = float<-(n / 3)
    let dx = 2.0 - col
    let dy = 2.0 - row
    let adx = if dx < 0.0: -dx else: dx
    let ady = if dy < 0.0: -dy else: dy
    return adx + ady


# ── Dijkstra tests ──

@[test]
function test_dijkstra_source_dist_zero() -> void:
    var g = build_triangle()
    defer: g.release()

    var dg = g.compile()
    defer: dg.release()

    var paths = dg.dijkstra(0)
    defer: paths.release()

    let d = paths.distance_to(0)
    expect(d >= -0.001 and d <= 0.001, "source distance is 0")



@[test]
function test_dijkstra_correct_distances() -> void:
    var g = build_triangle()
    defer: g.release()

    var dg = g.compile()
    defer: dg.release()

    var paths = dg.dijkstra(0)
    defer: paths.release()

    let d1 = paths.distance_to(1)
    expect(d1 >= 1.999 and d1 <= 2.001, "A->B dist is 2")

    let d2 = paths.distance_to(2)
    expect(d2 >= 4.999 and d2 <= 5.001, "A->C dist is 5 via B")



@[test]
function test_dijkstra_has_path() -> void:
    var g = build_triangle()
    defer: g.release()

    var dg = g.compile()
    defer: dg.release()

    var paths = dg.dijkstra(0)
    defer: paths.release()

    expect(paths.has_path_to(0))
    expect(paths.has_path_to(2))
    expect(not paths.has_path_to(999))



@[test]
function test_dijkstra_path_reconstruction() -> void:
    var g = build_triangle()
    defer: g.release()

    var dg = g.compile()
    defer: dg.release()

    var paths = dg.dijkstra(0)
    defer: paths.release()

    var p = paths.path_to(2)
    defer: p.release()

    expect(p.len() == 3, "path 0->1->2 has 3 nodes")


@[test]
function test_dijkstra_empty_graph() -> void:
    var g = gmod.Graph[str].create()
    defer: g.release()

    var dg = g.compile()
    defer: dg.release()

    var paths = dg.dijkstra(0)
    defer: paths.release()

    expect(not paths.has_path_to(0))



@[test]
function test_dijkstra_source_oob() -> void:
    var g = build_triangle()
    defer: g.release()

    var dg = g.compile()
    defer: dg.release()

    var paths = dg.dijkstra(999)
    defer: paths.release()

    expect(not paths.has_path_to(0))



# ── A* tests ──

@[test]
function test_astar_basic_path() -> void:
    var g = build_grid()
    defer: g.release()

    var dg = g.compile()
    defer: dg.release()

    var path = dg.astar(0, 8, dist)
    defer: path.release()

    expect(path.len() >= 4, "path from corner to corner >= 4 steps")



@[test]
function test_astar_source_equals_target() -> void:
    var g = build_grid()
    defer: g.release()

    var dg = g.compile()
    defer: dg.release()

    var path = dg.astar(4, 4, dist)
    defer: path.release()

    expect(path.len() == 1, "path from node to itself has 1 node")



@[test]
function test_astar_unreachable() -> void:
    var g = gmod.Graph[str].create_directed()
    let _a = g.add_node("A")
    let _b = g.add_node("B")
    g.add_weighted_edge(0, 1, 1.0)

    defer: g.release()
    var dg = g.compile()
    defer: dg.release()

    var path = dg.astar(1, 0, dist)
    defer: path.release()

    expect(path.len() == 0, "no path against directed edge")



@[test]
function test_astar_empty_graph() -> void:
    var g = gmod.Graph[str].create()
    defer: g.release()

    var dg = g.compile()
    defer: dg.release()

    var path = dg.astar(0, 0, dist)
    defer: path.release()

    expect(path.len() == 0, "empty graph returns empty path")

