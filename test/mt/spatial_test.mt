# In-language tests for std.spatial (migrated from
# test/std/std_spatial_test.rb, run by `mtc test`).

import std.spatial as sp
import std.vec as vec

@[test]
function test_spatial_grid_dimensions() -> void:
    var grid = sp.SpatialGrid[uint].create(10.0, 100.0, 50.0)
    defer: grid.release()
    expect(grid.cell_count() == 50z, "50 cells")
    expect(grid.cols == uint<-10, "10 cols")
    expect(grid.rows == uint<-5, "5 rows")


@[test]
function test_spatial_insert_and_query() -> void:
    var grid = sp.SpatialGrid[uint].create(10.0, 100.0, 100.0)
    defer: grid.release()

    grid.insert(42, 15.0, 25.0)
    grid.insert(99, 85.0, 85.0)

    var results = grid.query_radius(15.0, 25.0, 5.0)
    defer: results.release()

    expect(results.len() != 0z, "results non-empty")
    let entity_ptr = results.get(0) else:
        expect(false, "results.get(0) none")
        return
    var found = 0
    unsafe:
        found = int<-read(entity_ptr)
    expect_eq(found, 42)


@[test]
function test_spatial_clear_removes_all_entities() -> void:
    var grid = sp.SpatialGrid[uint].create(10.0, 100.0, 100.0)
    defer: grid.release()

    grid.insert(1, 5.0, 5.0)
    grid.insert(2, 15.0, 25.0)
    grid.insert(3, 55.0, 65.0)

    expect(grid.entity_count() == 3z, "3 entities")
    grid.clear()
    expect(grid.entity_count() == 0z, "0 entities after clear")


@[test]
function test_spatial_query_outside_bounds_is_empty() -> void:
    var grid = sp.SpatialGrid[uint].create(10.0, 100.0, 100.0)
    defer: grid.release()
    grid.insert(42, 5.0, 5.0)
    var results = grid.query_radius(200.0, 200.0, 5.0)
    defer: results.release()
    expect(results.len() == 0z, "no results outside bounds")


@[test]
function test_spatial_multiple_entities_in_same_cell() -> void:
    var grid = sp.SpatialGrid[uint].create(20.0, 100.0, 100.0)
    defer: grid.release()
    grid.insert(10, 5.0, 5.0)
    grid.insert(20, 8.0, 8.0)
    grid.insert(30, 12.0, 12.0)
    var results = grid.query_radius(10.0, 10.0, 15.0)
    defer: results.release()
    expect(results.len() == 3z, "3 results in radius")


@[test]
function test_spatial_cell_index_with_origin_offset() -> void:
    var grid = sp.SpatialGrid[uint].with_origin(10.0, 100.0, 100.0, 50.0, 30.0)
    defer: grid.release()
    grid.insert(42, 55.0, 35.0)
    var results = grid.query_radius(55.0, 35.0, 1.0)
    defer: results.release()
    expect(results.len() == 1z, "1 result")
