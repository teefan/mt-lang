import std.multiplayer.protocol as protocol
import std.vec as vec

public struct GridCell:
    x: int
    y: int

public struct ConnectionCellEntry:
    connection: protocol.ConnectionId
    cell: GridCell

public struct EntityCellEntry:
    entity: protocol.EntityId
    cell: GridCell

public struct GridIndex:
    connection_cells: vec.Vec[ConnectionCellEntry]
    entity_cells: vec.Vec[EntityCellEntry]


extending GridIndex:
    public static function create() -> GridIndex:
        return GridIndex(
            connection_cells = vec.Vec[ConnectionCellEntry].create(),
            entity_cells = vec.Vec[EntityCellEntry].create()
        )


    public mutable function release() -> void:
        this.connection_cells.release()
        this.entity_cells.release()


    public mutable function set_connection_cell(connection: protocol.ConnectionId, cell: GridCell) -> void:
        match this.connection_cells.find_index(proc(entry: ptr[ConnectionCellEntry]) -> bool:
            unsafe: read(entry).connection == connection
        ):
            Option.some as payload:
                let slot = this.connection_cells.get(payload.value) else:
                    fatal(c"spatial.GridIndex.set_connection_cell missing connection slot")
                unsafe:
                    read(slot) = ConnectionCellEntry(connection = connection, cell = cell)
            Option.none:
                this.connection_cells.push(ConnectionCellEntry(connection = connection, cell = cell))


    public mutable function set_entity_cell(entity: protocol.EntityId, cell: GridCell) -> void:
        match this.entity_cells.find_index(proc(entry: ptr[EntityCellEntry]) -> bool:
            unsafe: read(entry).entity == entity
        ):
            Option.some as payload:
                let slot = this.entity_cells.get(payload.value) else:
                    fatal(c"spatial.GridIndex.set_entity_cell missing entity slot")
                unsafe:
                    read(slot) = EntityCellEntry(entity = entity, cell = cell)
            Option.none:
                this.entity_cells.push(EntityCellEntry(entity = entity, cell = cell))


    public function connection_cell(connection: protocol.ConnectionId) -> Option[GridCell]:
        let found = this.connection_cells.find(proc(entry: ptr[ConnectionCellEntry]) -> bool:
            unsafe: read(entry).connection == connection
        ) else:
            return Option[GridCell].none
        unsafe:
            return Option[GridCell].some(value = read(found).cell)


    public function entity_cell(entity: protocol.EntityId) -> Option[GridCell]:
        let found = this.entity_cells.find(proc(entry: ptr[EntityCellEntry]) -> bool:
            unsafe: read(entry).entity == entity
        ) else:
            return Option[GridCell].none
        unsafe:
            return Option[GridCell].some(value = read(found).cell)


public function allows_by_grid(
    index: GridIndex,
    connection: protocol.ConnectionId,
    entity: protocol.EntityId,
    cell_radius: uint
) -> bool:
    let connection_cell = index.connection_cell(connection) else:
        return false
    let entity_cell = index.entity_cell(entity) else:
        return false
    return within_cell_radius_coords(connection_cell.x, connection_cell.y, entity_cell.x, entity_cell.y, cell_radius)


public function within_cell_radius_coords(
    connection_x: int,
    connection_y: int,
    entity_x: int,
    entity_y: int,
    cell_radius: uint,
) -> bool:
    let dx = abs_diff(connection_x, entity_x)
    let dy = abs_diff(connection_y, entity_y)
    return dx <= cell_radius and dy <= cell_radius


public function world_to_cell(position_x: int, position_y: int, cell_size: uint) -> GridCell:
    if cell_size == 0:
        return GridCell(x = 0, y = 0)

    let size = int<-cell_size
    return GridCell(
        x = floor_div(position_x, size),
        y = floor_div(position_y, size)
    )


function floor_div(value: int, divisor: int) -> int:
    if divisor <= 0:
        return 0

    if value >= 0:
        return value / divisor

    let quotient = value / divisor
    if quotient * divisor == value:
        return quotient
    return quotient - 1


function abs_diff(left: int, right: int) -> uint:
    if left >= right:
        return uint<-(left - right)
    return uint<-(right - left)
