import std.multiplayer.protocol as protocol
import std.multiplayer.spatial as spatial

public enum PolicyKind: ubyte
    all = 0
    owner = 1
    callback = 2
    grid = 3
    owner_or_grid = 4

public struct CellCoord:
    x: int
    y: int

public struct Policy:
    kind: PolicyKind
    filter: fn(connection: protocol.ConnectionId, entity: protocol.EntityId) -> bool
    connection_cell: fn(connection: protocol.ConnectionId) -> CellCoord
    entity_cell: fn(entity: protocol.EntityId) -> CellCoord
    cell_radius: uint


public function all() -> Policy:
    return Policy(
        kind = PolicyKind.all,
        filter = allow_everything,
        connection_cell = zero_connection_cell,
        entity_cell = zero_entity_cell,
        cell_radius = 0
    )


public function owner() -> Policy:
    return Policy(
        kind = PolicyKind.owner,
        filter = allow_everything,
        connection_cell = zero_connection_cell,
        entity_cell = zero_entity_cell,
        cell_radius = 0
    )


public function callback(filter: fn(connection: protocol.ConnectionId, entity: protocol.EntityId) -> bool) -> Policy:
    return Policy(
        kind = PolicyKind.callback,
        filter = filter,
        connection_cell = zero_connection_cell,
        entity_cell = zero_entity_cell,
        cell_radius = 0
    )


public function grid(
    connection_cell: fn(connection: protocol.ConnectionId) -> CellCoord,
    entity_cell: fn(entity: protocol.EntityId) -> CellCoord,
    cell_radius: uint,
) -> Policy:
    return Policy(
        kind = PolicyKind.grid,
        filter = allow_everything,
        connection_cell = connection_cell,
        entity_cell = entity_cell,
        cell_radius = cell_radius
    )


public function owner_or_grid(
    connection_cell: fn(connection: protocol.ConnectionId) -> CellCoord,
    entity_cell: fn(entity: protocol.EntityId) -> CellCoord,
    cell_radius: uint,
) -> Policy:
    return Policy(
        kind = PolicyKind.owner_or_grid,
        filter = allow_everything,
        connection_cell = connection_cell,
        entity_cell = entity_cell,
        cell_radius = cell_radius
    )


public function allows(
    policy: Policy,
    connection: protocol.ConnectionId,
    entity: protocol.EntityId,
    owner: Option[protocol.ConnectionId],
) -> bool:
    match policy.kind:
        PolicyKind.all:
            return true
        PolicyKind.owner:
            match owner:
                Option.some as payload:
                    return payload.value == connection
                Option.none:
                    return false
        PolicyKind.callback:
            return policy.filter(connection, entity)
        PolicyKind.grid:
            return within_cell_radius(policy, connection, entity)
        PolicyKind.owner_or_grid:
            match owner:
                Option.some as payload:
                    if payload.value == connection:
                        return true
                Option.none:
                    pass
            return within_cell_radius(policy, connection, entity)


public function owner_or_grid_index(
    index: spatial.GridIndex,
    connection: protocol.ConnectionId,
    entity: protocol.EntityId,
    owner: Option[protocol.ConnectionId],
    cell_radius: uint,
) -> bool:
    match owner:
        Option.some as payload:
            if payload.value == connection:
                return true
        Option.none:
            pass
    return spatial.allows_by_grid(index, connection, entity, cell_radius)


function allow_everything(connection: protocol.ConnectionId, entity: protocol.EntityId) -> bool:
    if connection == 0 and entity == 0:
        pass
    return true


function zero_connection_cell(connection: protocol.ConnectionId) -> CellCoord:
    if connection == 0:
        pass
    return CellCoord(x = 0, y = 0)


function zero_entity_cell(entity: protocol.EntityId) -> CellCoord:
    if entity == 0:
        pass
    return CellCoord(x = 0, y = 0)


function within_cell_radius(
    policy: Policy,
    connection: protocol.ConnectionId,
    entity: protocol.EntityId,
) -> bool:
    let connection_cell = policy.connection_cell(connection)
    let entity_cell = policy.entity_cell(entity)
    return spatial.within_cell_radius_coords(
        connection_cell.x,
        connection_cell.y,
        entity_cell.x,
        entity_cell.y,
        policy.cell_radius
    )
