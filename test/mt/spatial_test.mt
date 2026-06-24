# In-language tests for std.spatial (migrated from
# test/std/std_spatial_test.rb, run by `mtc test`).

import std.testing as t
import std.spatial as sp
import std.vec as vec

@[test]
function test_spatial_grid_dimensions() -> t.Check:
    var grid = sp.new[uint](10.0, 100.0, 50.0)
    defer grid.release()
    t.expect(grid.cell_count() == 50z, "50 cells")?
    t.expect(grid.cols == uint<-10, "10 cols")?
    return t.expect(grid.rows == uint<-5, "5 rows")


@[test]
function test_spatial_insert_and_query() -> t.Check:
    var grid = sp.new[uint](10.0, 100.0, 100.0)
    defer grid.release()

    grid.insert(42, 15.0, 25.0)
    grid.insert(99, 85.0, 85.0)

    var results = grid.query_radius(15.0, 25.0, 5.0)
    defer results.release()

    t.expect(results.len() != 0z, "results non-empty")?
    let entity_ptr = results.get(0) else:
        return t.fail("results.get(0) none")
    var found = 0
    unsafe:
        found = int<-read(entity_ptr)
    return t.expect_equal_int(found, 42)


@[test]
function test_spatial_clear_removes_all_entities() -> t.Check:
    var grid = sp.new[uint](10.0, 100.0, 100.0)
    defer grid.release()

    grid.insert(1, 5.0, 5.0)
    grid.insert(2, 15.0, 25.0)
    grid.insert(3, 55.0, 65.0)

    t.expect(grid.entity_count() == 3z, "3 entities")?
    grid.clear()
    return t.expect(grid.entity_count() == 0z, "0 entities after clear")


@[test]
function test_spatial_query_outside_bounds_is_empty() -> t.Check:
    var grid = sp.new[uint](10.0, 100.0, 100.0)
    defer grid.release()
    grid.insert(42, 5.0, 5.0)
    var results = grid.query_radius(200.0, 200.0, 5.0)
    defer results.release()
    return t.expect(results.len() == 0z, "no results outside bounds")


@[test]
function test_spatial_multiple_entities_in_same_cell() -> t.Check:
    var grid = sp.new[uint](20.0, 100.0, 100.0)
    defer grid.release()
    grid.insert(10, 5.0, 5.0)
    grid.insert(20, 8.0, 8.0)
    grid.insert(30, 12.0, 12.0)
    var results = grid.query_radius(10.0, 10.0, 15.0)
    defer results.release()
    return t.expect(results.len() == 3z, "3 results in radius")


@[test]
function test_spatial_cell_index_with_origin_offset() -> t.Check:
    var grid = sp.new_with_origin[uint](10.0, 100.0, 100.0, 50.0, 30.0)
    defer grid.release()
    grid.insert(42, 55.0, 35.0)
    var results = grid.query_radius(55.0, 35.0, 1.0)
    defer results.release()
    return t.expect(results.len() == 1z, "1 result")
