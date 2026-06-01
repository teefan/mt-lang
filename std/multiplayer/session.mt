import std.multiplayer.protocol as protocol
import std.vec as vec

public type ConnectionId = protocol.ConnectionId
public type Error = protocol.Error
public type ErrorCode = protocol.ErrorCode

public struct SlotEntry:
    connection: Option[ConnectionId]
    ready: bool

public struct SlotRoster:
    slots: vec.Vec[SlotEntry]


extending SlotRoster:
    public static function create(slot_count: ptr_uint) -> SlotRoster:
        var slots = vec.Vec[SlotEntry].with_capacity(slot_count)
        var index: ptr_uint = 0
        while index < slot_count:
            slots.push(empty_slot())
            index += 1

        return SlotRoster(slots = slots)


    public function slot_count() -> ptr_uint:
        return this.slots.len()


    public function occupied_count() -> ptr_uint:
        return occupied_slot_count(this.slots.as_span())


    public function ready_count() -> ptr_uint:
        return ready_slot_count(this.slots.as_span())


    public function open_slot_count() -> ptr_uint:
        return this.slot_count() - this.occupied_count()


    public function slot(index: ptr_uint) -> Option[SlotEntry]:
        let slot = this.slots.get(index)
        if slot == null:
            return Option[SlotEntry].none

        unsafe:
            return Option[SlotEntry].some(value = read(ptr[SlotEntry]<-slot))


    public function slot_for_connection(connection: ConnectionId) -> Option[ptr_uint]:
        return slot_index_for_connection(this.slots.as_span(), connection)


    public function has_connection(connection: ConnectionId) -> bool:
        match slot_index_for_connection(this.slots.as_span(), connection):
            Option.some:
                return true
            Option.none:
                return false


    public function all_occupied_ready() -> bool:
        return all_occupied_ready_in_slots(this.slots.as_span())


    public function can_start_transition(min_players: ptr_uint) -> Result[bool, Error]:
        return transition_ready_status(this.slots.as_span(), this.slot_count(), min_players)


    public mutable function begin_transition(min_players: ptr_uint) -> Result[Option[ptr_uint], Error]:
        let can_start = transition_ready_status(this.slots.as_span(), this.slots.len(), min_players) else as transition_error:
            return Result[Option[ptr_uint], Error].failure(error = transition_error)

        if not can_start:
            return Result[Option[ptr_uint], Error].success(value = Option[ptr_uint].none)

        let participant_count = occupied_slot_count(this.slots.as_span())
        let _ = this.clear_ready()
        return Result[Option[ptr_uint], Error].success(value = Option[ptr_uint].some(value = participant_count))


    public mutable function claim_slot(connection: ConnectionId, slot_index: ptr_uint) -> Result[bool, Error]:
        if slot_index >= this.slots.len():
            return Result[bool, Error].failure(error = protocol.error(
                ErrorCode.invalid_argument,
                "slot index is out of range"
            ))

        match slot_index_for_connection(this.slots.as_span(), connection):
            Option.some as payload:
                if payload.value == slot_index:
                    return Result[bool, Error].success(value = false)

                return Result[bool, Error].failure(error = protocol.error(
                    ErrorCode.already_registered,
                    "connection already occupies a slot"
                ))
            Option.none:
                pass

        let slot = this.slots.get(slot_index) else:
            return Result[bool, Error].failure(error = protocol.error(
                ErrorCode.invalid_argument,
                "slot index is out of range"
            ))

        unsafe:
            let entry = ptr[SlotEntry]<-slot
            match read(entry).connection:
                Option.some:
                    return Result[bool, Error].failure(error = protocol.error(
                        ErrorCode.already_registered,
                        "slot is already occupied"
                    ))
                Option.none:
                    read(entry) = SlotEntry(
                        connection = Option[ConnectionId].some(value = connection),
                        ready = false
                    )

        return Result[bool, Error].success(value = true)


    public mutable function claim_first_open(connection: ConnectionId) -> Result[Option[ptr_uint], Error]:
        match slot_index_for_connection(this.slots.as_span(), connection):
            Option.some:
                return Result[Option[ptr_uint], Error].failure(error = protocol.error(
                    ErrorCode.already_registered,
                    "connection already occupies a slot"
                ))
            Option.none:
                pass

        var index: ptr_uint = 0
        while index < this.slots.len():
            let slot = this.slots.get(index)
            if slot == null:
                break

            unsafe:
                let entry = ptr[SlotEntry]<-slot
                match read(entry).connection:
                    Option.some:
                        pass
                    Option.none:
                        read(entry) = SlotEntry(
                            connection = Option[ConnectionId].some(value = connection),
                            ready = false
                        )
                        return Result[Option[ptr_uint], Error].success(value = Option[ptr_uint].some(value = index))

            index += 1

        return Result[Option[ptr_uint], Error].success(value = Option[ptr_uint].none)


    public mutable function release_connection(connection: ConnectionId) -> bool:
        match slot_index_for_connection(this.slots.as_span(), connection):
            Option.some as payload:
                let slot = this.slots.get(payload.value) else:
                    fatal(c"multiplayer.session.release_connection missing occupied slot")
                unsafe:
                    read(ptr[SlotEntry]<-slot) = empty_slot()
                return true
            Option.none:
                return false


    public mutable function set_ready(connection: ConnectionId, ready: bool) -> Result[bool, Error]:
        match slot_index_for_connection(this.slots.as_span(), connection):
            Option.some as payload:
                let slot = this.slots.get(payload.value) else:
                    fatal(c"multiplayer.session.set_ready missing occupied slot")
                unsafe:
                    let entry = ptr[SlotEntry]<-slot
                    if read(entry).ready == ready:
                        return Result[bool, Error].success(value = false)
                    read(entry).ready = ready
                return Result[bool, Error].success(value = true)
            Option.none:
                return Result[bool, Error].failure(error = protocol.error(
                    ErrorCode.not_found,
                    "connection does not occupy a slot"
                ))


    public mutable function clear_ready() -> ptr_uint:
        var cleared: ptr_uint = 0
        var index: ptr_uint = 0
        while index < this.slots.len():
            let slot = this.slots.get(index)
            if slot == null:
                break

            unsafe:
                let entry = ptr[SlotEntry]<-slot
                match read(entry).connection:
                    Option.some:
                        if read(entry).ready:
                            read(entry).ready = false
                            cleared += 1
                    Option.none:
                        pass

            index += 1

        return cleared


    public mutable function clear() -> void:
        var index: ptr_uint = 0
        while index < this.slots.len():
            let slot = this.slots.get(index)
            if slot == null:
                break

            unsafe:
                read(ptr[SlotEntry]<-slot) = empty_slot()

            index += 1


    public mutable function release() -> void:
        this.slots.release()


function empty_slot() -> SlotEntry:
    return SlotEntry(connection = Option[ConnectionId].none, ready = false)


function occupied_slot_count(slots: span[SlotEntry]) -> ptr_uint:
    var occupied: ptr_uint = 0
    var index: ptr_uint = 0
    while index < slots.len:
        unsafe:
            match read(slots.data + index).connection:
                Option.some:
                    occupied += 1
                Option.none:
                    pass

        index += 1

    return occupied


function ready_slot_count(slots: span[SlotEntry]) -> ptr_uint:
    var ready_total: ptr_uint = 0
    var index: ptr_uint = 0
    while index < slots.len:
        unsafe:
            let entry = read(slots.data + index)
            match entry.connection:
                Option.some:
                    if entry.ready:
                        ready_total += 1
                Option.none:
                    pass

        index += 1

    return ready_total


function all_occupied_ready_in_slots(slots: span[SlotEntry]) -> bool:
    var occupied: ptr_uint = 0
    var index: ptr_uint = 0
    while index < slots.len:
        unsafe:
            let entry = read(slots.data + index)
            match entry.connection:
                Option.some:
                    occupied += 1
                    if not entry.ready:
                        return false
                Option.none:
                    pass

        index += 1

    return occupied != 0


function transition_ready_status(slots: span[SlotEntry], slot_count: ptr_uint, min_players: ptr_uint) -> Result[bool, Error]:
    if min_players == 0:
        return Result[bool, Error].failure(error = protocol.error(
            ErrorCode.invalid_argument,
            "session transition requires min_players > 0"
        ))

    if min_players > slot_count:
        return Result[bool, Error].failure(error = protocol.error(
            ErrorCode.invalid_argument,
            "session transition min_players exceeds slot count"
        ))

    if occupied_slot_count(slots) < min_players:
        return Result[bool, Error].success(value = false)

    return Result[bool, Error].success(value = all_occupied_ready_in_slots(slots))


function slot_index_for_connection(slots: span[SlotEntry], connection: ConnectionId) -> Option[ptr_uint]:
    var index: ptr_uint = 0
    while index < slots.len:
        unsafe:
            match read(slots.data + index).connection:
                Option.some as payload:
                    if payload.value == connection:
                        return Option[ptr_uint].some(value = index)
                Option.none:
                    pass

        index += 1

    return Option[ptr_uint].none
