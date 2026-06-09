import std.vec as vec

public struct SpatialGrid[T]:
    cells: vec.Vec[vec.Vec[T]]
    cell_size: float
    cols: uint
    rows: uint
    origin_x: float
    origin_y: float


extending SpatialGrid[T]:
    public editable function release() -> void:
        var i: ptr_uint = 0
        while i < this.cells.len():
            let cell_ptr = this.cells.get(i) else:
                break
            unsafe: read(cell_ptr).release()
            i += 1
        this.cells.release()


function cell_index[T](grid: ref[SpatialGrid[T]], x: float, y: float) -> Option[ptr_uint]:
    let cx = int<-(float<-((x - grid.origin_x) / grid.cell_size))
    let cy = int<-(float<-((y - grid.origin_y) / grid.cell_size))
    if cx < 0 or cy < 0 or uint<-cx >= grid.cols or uint<-cy >= grid.rows:
        return Option[ptr_uint].none()
    return Option[ptr_uint].some(value = ptr_uint<-cx + ptr_uint<-cy * ptr_uint<-grid.cols)


public function new[T](cell_size: float, width: float, height: float) -> SpatialGrid[T]:
    var cols: uint = uint<-(float<-width / cell_size)
    var rows: uint = uint<-(float<-height / cell_size)
    if cols == 0:
        cols = 1
    if rows == 0:
        rows = 1

    var cells = vec.Vec[vec.Vec[T]].create()
    var total: ptr_uint = ptr_uint<-cols * ptr_uint<-rows
    var i: ptr_uint = 0
    while i < total:
        cells.push(vec.Vec[T].create())
        i += 1

    return SpatialGrid[T](
        cells = cells,
        cell_size = cell_size,
        cols = cols,
        rows = rows,
        origin_x = 0.0,
        origin_y = 0.0
    )


public function new_with_origin[T](
    cell_size: float,
    width: float,
    height: float,
    origin_x: float,
    origin_y: float
) -> SpatialGrid[T]:
    var grid = new[T](cell_size, width, height)
    grid.origin_x = origin_x
    grid.origin_y = origin_y
    return grid


extending SpatialGrid[T]:
    public editable function insert(entity: T, x: float, y: float) -> void:
        let idx_opt = cell_index(ref_of(this), x, y)
        match idx_opt:
            Option.some as ip:
                let cell_ptr = this.cells.get(ip.value) else:
                    return
                unsafe: read(cell_ptr).push(entity)
            Option.none:
                return


    public editable function insert_many(items: span[T], xs: span[float], ys: span[float]) -> void:
        var i: ptr_uint = 0
        let count = items.len
        while i < count:
            this.insert(items[i], xs[i], ys[i])
            i += 1


    public editable function query_radius(x: float, y: float, radius: float) -> vec.Vec[T]:
        var result = vec.Vec[T].create()
        let min_x = x - radius
        let min_y = y - radius
        let max_x = x + radius
        let max_y = y + radius

        let min_idx = cell_index(ref_of(this), min_x, min_y)
        let max_idx = cell_index(ref_of(this), max_x, max_y)

        var start_col: ptr_uint = 0
        var end_col: ptr_uint = ptr_uint<-this.cols
        var start_row: ptr_uint = 0
        var end_row: ptr_uint = ptr_uint<-this.rows

        match min_idx:
            Option.some as mp:
                start_col = mp.value % ptr_uint<-this.cols
                start_row = mp.value / ptr_uint<-this.cols
            Option.none:
                return result

        match max_idx:
            Option.some as mp:
                let ec = mp.value % ptr_uint<-this.cols
                let er = mp.value / ptr_uint<-this.cols
                if ec + ptr_uint<-1 < end_col:
                    end_col = ec + ptr_uint<-1
                if er + ptr_uint<-1 < end_row:
                    end_row = er + ptr_uint<-1
            Option.none:
                pass

        var cy: ptr_uint = start_row
        while cy < end_row:
            var cx: ptr_uint = start_col
            while cx < end_col:
                let idx = cx + cy * ptr_uint<-this.cols
                let cell_ptr = this.cells.get(idx) else:
                    cx += 1
                    continue
                var cell = unsafe: read(cell_ptr)
                var k: ptr_uint = 0
                while k < cell.len():
                    let item_ptr = cell.get(k) else:
                        break
                    result.push(unsafe: read(item_ptr))
                    k += 1
                cx += 1
            cy += 1

        return result


    public editable function clear() -> void:
        var i: ptr_uint = 0
        while i < this.cells.len():
            let cell_ptr = this.cells.get(i) else:
                break
            unsafe: read(cell_ptr).clear()
            i += 1


    public function cell_count() -> ptr_uint:
        return ptr_uint<-this.cols * ptr_uint<-this.rows


    public function occupied_cells() -> uint:
        var count: ptr_uint = 0
        var i: ptr_uint = 0
        while i < this.cells.len():
            let cell_ptr = this.cells.get(i) else:
                break
            if not unsafe: read(cell_ptr).is_empty():
                count += 1
            i += 1
        return uint<-count


    public function entity_count() -> ptr_uint:
        var total: ptr_uint = 0
        var i: ptr_uint = 0
        while i < this.cells.len():
            let cell_ptr = this.cells.get(i) else:
                break
            total += unsafe: read(cell_ptr).len()
            i += 1
        return total
