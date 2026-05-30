import std.multiplayer.protocol as protocol


public enum PolicyKind: ubyte
    all = 0
    owner = 1
    callback = 2


public struct Policy:
    kind: PolicyKind
    filter: fn(connection: protocol.ConnectionId, entity: protocol.EntityId) -> bool


public function all() -> Policy:
    return Policy(kind = PolicyKind.all, filter = allow_everything)


public function owner() -> Policy:
    return Policy(kind = PolicyKind.owner, filter = allow_everything)


public function callback(filter: fn(connection: protocol.ConnectionId, entity: protocol.EntityId) -> bool) -> Policy:
    return Policy(kind = PolicyKind.callback, filter = filter)


public function allows(policy: Policy, connection: protocol.ConnectionId, entity: protocol.EntityId, owner: Option[protocol.ConnectionId]) -> bool:
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


function allow_everything(connection: protocol.ConnectionId, entity: protocol.EntityId) -> bool:
    return true
