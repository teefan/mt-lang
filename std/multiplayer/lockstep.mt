import std.bytes as bytes
import std.multiplayer.protocol as protocol
import std.multiplayer.wire as wire
import std.vec as vec

const command_header_bytes: ptr_uint = 16
const checksum_payload_bytes: ptr_uint = 20

public type TurnId = ulong
public type Error = protocol.Error
public type ErrorCode = protocol.ErrorCode
public type ConnectionId = protocol.ConnectionId

public struct CommandPacketHeader:
    turn_id: TurnId
    slot: ptr_uint
    command_count: ptr_uint

public struct CommandEnvelope[T]:
    slot: ptr_uint
    turn_id: TurnId
    payload: T

public struct ChecksumReport:
    slot: ptr_uint
    turn_id: TurnId
    checksum: ulong

public struct IncomingCommandPacket:
    header: CommandPacketHeader
    sender: Option[ConnectionId]
    channel: uint
    payload: bytes.Bytes

public struct IncomingChecksumPacket:
    report: ChecksumReport
    sender: Option[ConnectionId]
    channel: uint

public struct DesyncReport:
    slot: ptr_uint
    turn_id: TurnId
    expected_checksum: ulong
    actual_checksum: ulong

public struct TurnStatus:
    turn_id: TurnId
    required_slots: ptr_uint
    submitted_slots: ptr_uint
    checksum_reports: ptr_uint
    command_count: ptr_uint
    sealed: bool
    applied: bool
    desynced: bool

public struct TurnCollector[T]:
    current_turn: TurnId
    required_slots: ptr_uint
    max_commands_per_turn: ptr_uint
    commands: vec.Vec[CommandEnvelope[T]]
    submitted_slots: vec.Vec[bool]
    checksum_reported: vec.Vec[bool]
    checksum_values: vec.Vec[ulong]
    sealed: bool
    applied: bool
    desync: Option[DesyncReport]


extending TurnCollector[T]:
    public static function create(
        required_slots: ptr_uint,
        max_commands_per_turn: ptr_uint,
        initial_turn: TurnId
    ) -> Result[TurnCollector[T], Error]:
        if required_slots == 0:
            return Result[TurnCollector[T], Error].failure(error = protocol.error(
                ErrorCode.invalid_argument,
                "lockstep turn collection requires at least one slot"
            ))

        if max_commands_per_turn == 0:
            return Result[TurnCollector[T], Error].failure(error = protocol.error(
                ErrorCode.invalid_argument,
                "lockstep turn collection requires max_commands_per_turn > 0"
            ))

        var submitted_slots = vec.Vec[bool].with_capacity(required_slots)
        var checksum_reported = vec.Vec[bool].with_capacity(required_slots)
        var checksum_values = vec.Vec[ulong].with_capacity(required_slots)
        var slot_index: ptr_uint = 0
        while slot_index < required_slots:
            submitted_slots.push(false)
            checksum_reported.push(false)
            checksum_values.push(ulong<-0)
            slot_index += 1

        return Result[TurnCollector[T], Error].success(value = TurnCollector[T](
            current_turn = initial_turn,
            required_slots = required_slots,
            max_commands_per_turn = max_commands_per_turn,
            commands = vec.Vec[CommandEnvelope[T]].with_capacity(max_commands_per_turn),
            submitted_slots = submitted_slots,
            checksum_reported = checksum_reported,
            checksum_values = checksum_values,
            sealed = false,
            applied = false,
            desync = Option[DesyncReport].none,
        ))


    public function turn_id() -> TurnId:
        return this.current_turn


    public function command_count() -> ptr_uint:
        return this.commands.len()


    public function status() -> TurnStatus:
        let submitted = count_true(this.submitted_slots.as_span())
        let checksums = count_true(this.checksum_reported.as_span())
        return TurnStatus(
            turn_id = this.current_turn,
            required_slots = this.required_slots,
            submitted_slots = submitted,
            checksum_reports = checksums,
            command_count = this.commands.len(),
            sealed = this.sealed,
            applied = this.applied,
            desynced = has_desync(this.desync)
        )


    public function all_slots_submitted() -> bool:
        return count_true(this.submitted_slots.as_span()) == this.required_slots


    public function all_checksums_reported() -> bool:
        return count_true(this.checksum_reported.as_span()) == this.required_slots


    public function slot_submitted(slot: ptr_uint) -> Result[bool, Error]:
        return slot_flag(this.submitted_slots.as_span(), slot)


    public function checksum_received(slot: ptr_uint) -> Result[bool, Error]:
        return slot_flag(this.checksum_reported.as_span(), slot)


    public function checksum_for_slot(slot: ptr_uint) -> Result[ulong, Error]:
        let _ = validate_slot(this.required_slots, slot)?

        let entry = this.checksum_values.get(slot) else:
            return Result[ulong, Error].failure(error = protocol.error(
                ErrorCode.invalid_argument,
                "lockstep checksum slot is out of range"
            ))

        unsafe:
            return Result[ulong, Error].success(value = read(ptr[ulong]<-entry))


    public function command_at(index: ptr_uint) -> Option[CommandEnvelope[T]]:
        let command = this.commands.get(index)
        if command == null:
            return Option[CommandEnvelope[T]].none

        unsafe:
            return Option[CommandEnvelope[T]].some(value = read(ptr[CommandEnvelope[T]]<-command))


    public function desync_report() -> Option[DesyncReport]:
        return this.desync


    public mutable function submit_commands(
        slot: ptr_uint,
        turn_id: TurnId,
        commands: span[T]
    ) -> Result[ptr_uint, Error]:
        let _ = validate_turn_submission(ref_of(this), slot, turn_id, commands.len) else as validation_error:
            return Result[ptr_uint, Error].failure(error = validation_error)

        var command_index: ptr_uint = 0
        while command_index < commands.len:
            unsafe:
                this.commands.push(CommandEnvelope[T](
                    slot = slot,
                    turn_id = turn_id,
                    payload = read(commands.data + command_index)
                ))
            command_index += 1

        set_slot_flag(ref_of(this.submitted_slots), slot, true)
        return Result[ptr_uint, Error].success(value = commands.len)


    public mutable function seal_if_ready() -> bool:
        if this.sealed:
            return true
        if count_true(this.submitted_slots.as_span()) != this.required_slots:
            return false

        this.sealed = true
        return true


    public mutable function mark_applied(turn_id: TurnId) -> Result[bool, Error]:
        let _ = validate_turn_identity(this.current_turn, turn_id) else as turn_error:
            return Result[bool, Error].failure(error = turn_error)

        if not this.sealed:
            return Result[bool, Error].failure(error = protocol.error(
                ErrorCode.invalid_argument,
                "lockstep turn must be sealed before it can be applied"
            ))

        if this.applied:
            return Result[bool, Error].success(value = false)

        this.applied = true
        return Result[bool, Error].success(value = true)


    public mutable function report_checksum(
        slot: ptr_uint,
        turn_id: TurnId,
        checksum: ulong
    ) -> Result[bool, Error]:
        let _ = validate_turn_identity(this.current_turn, turn_id) else as turn_error:
            return Result[bool, Error].failure(error = turn_error)
        let _ = validate_slot(this.required_slots, slot)?

        if not this.sealed or not this.applied:
            return Result[bool, Error].failure(error = protocol.error(
                ErrorCode.invalid_argument,
                "lockstep checksums require a sealed and applied turn"
            ))

        let reported = slot_flag(this.checksum_reported.as_span(), slot) else as slot_error:
            return Result[bool, Error].failure(error = slot_error)
        if reported:
            return Result[bool, Error].failure(error = protocol.error(
                ErrorCode.already_registered,
                "slot already reported a checksum for this turn"
            ))

        set_slot_flag(ref_of(this.checksum_reported), slot, true)
        set_checksum_value(ref_of(this.checksum_values), slot, checksum)

        match first_reported_checksum(
                this.checksum_reported.as_span(),
                this.checksum_values.as_span(),
                slot):
            Option.some as payload:
                if payload.value != checksum and not has_desync(this.desync):
                    this.desync = Option[DesyncReport].some(value = DesyncReport(
                        slot = slot,
                        turn_id = turn_id,
                        expected_checksum = payload.value,
                        actual_checksum = checksum
                    ))
            Option.none:
                pass

        return Result[bool, Error].success(value = true)


    public mutable function advance_turn() -> Result[TurnId, Error]:
        if not this.sealed:
            return Result[TurnId, Error].failure(error = protocol.error(
                ErrorCode.invalid_argument,
                "lockstep turn must be sealed before advancing"
            ))

        if not this.applied:
            return Result[TurnId, Error].failure(error = protocol.error(
                ErrorCode.invalid_argument,
                "lockstep turn must be applied before advancing"
            ))

        if count_true(this.checksum_reported.as_span()) != this.required_slots:
            return Result[TurnId, Error].failure(error = protocol.error(
                ErrorCode.invalid_argument,
                "lockstep turn requires checksum reports from every slot before advancing"
            ))

        if has_desync(this.desync):
            return Result[TurnId, Error].failure(error = protocol.error(
                ErrorCode.invalid_argument,
                "lockstep turn cannot advance after a checksum mismatch"
            ))

        reset_flags(ref_of(this.submitted_slots), false)
        reset_flags(ref_of(this.checksum_reported), false)
        reset_checksums(ref_of(this.checksum_values))
        this.commands.clear()
        this.sealed = false
        this.applied = false
        this.desync = Option[DesyncReport].none
        this.current_turn += 1
        return Result[TurnId, Error].success(value = this.current_turn)


    public mutable function release() -> void:
        this.commands.release()
        this.submitted_slots.release()
        this.checksum_reported.release()
        this.checksum_values.release()


public function encode_command_header(header: CommandPacketHeader) -> array[ubyte, 16]:
    let turn_id = wire.encode_u64_be(header.turn_id)
    let slot = wire.encode_u32_be(uint<-header.slot)
    let command_count = wire.encode_u32_be(uint<-header.command_count)
    return array[ubyte, 16](
        turn_id[0], turn_id[1], turn_id[2], turn_id[3],
        turn_id[4], turn_id[5], turn_id[6], turn_id[7],
        slot[0], slot[1], slot[2], slot[3],
        command_count[0], command_count[1], command_count[2], command_count[3]
    )


public function decode_command_header(input: span[ubyte]) -> Result[CommandPacketHeader, Error]:
    if input.len < command_header_bytes:
        return Result[CommandPacketHeader, Error].failure(error = protocol.error(
            ErrorCode.invalid_argument,
            "lockstep command packet is too small"
        ))

    return Result[CommandPacketHeader, Error].success(value = CommandPacketHeader(
        turn_id = wire.decode_u64_be(input, 0),
        slot = ptr_uint<-wire.decode_u32_be(input, 8),
        command_count = ptr_uint<-wire.decode_u32_be(input, 12)
    ))


public function build_command_payload(
    header: CommandPacketHeader,
    payload: span[ubyte]
) -> bytes.Bytes:
    var combined = vec.Vec[ubyte].with_capacity(command_header_bytes + payload.len)
    defer combined.release()

    combined.append_array(encode_command_header(header))
    combined.append_span(payload)
    return bytes.Bytes.copy(combined.as_span())


public function build_checksum_payload(report: ChecksumReport) -> bytes.Bytes:
    var combined = vec.Vec[ubyte].with_capacity(checksum_payload_bytes)
    defer combined.release()

    combined.append_array(wire.encode_u64_be(report.turn_id))
    combined.append_array(wire.encode_u32_be(uint<-report.slot))
    combined.append_array(wire.encode_u64_be(report.checksum))
    return bytes.Bytes.copy(combined.as_span())


public function decode_checksum_payload(input: span[ubyte]) -> Result[ChecksumReport, Error]:
    if input.len < checksum_payload_bytes:
        return Result[ChecksumReport, Error].failure(error = protocol.error(
            ErrorCode.invalid_argument,
            "lockstep checksum packet is too small"
        ))

    return Result[ChecksumReport, Error].success(value = ChecksumReport(
        slot = ptr_uint<-wire.decode_u32_be(input, 8),
        turn_id = wire.decode_u64_be(input, 0),
        checksum = wire.decode_u64_be(input, 12)
    ))


public function enqueue_incoming_command(
    queue: ref[vec.Vec[IncomingCommandPacket]],
    sender: Option[ConnectionId],
    channel: uint,
    payload: span[ubyte]
) -> Result[bool, Error]:
    let header = decode_command_header(payload) else as header_error:
        return Result[bool, Error].failure(error = header_error)

    unsafe:
        let body = span[ubyte](
            data = payload.data + command_header_bytes,
            len = payload.len - command_header_bytes
        )
        queue.push(IncomingCommandPacket(
            header = header,
            sender = sender,
            channel = channel,
            payload = bytes.Bytes.copy(body)
        ))

    return Result[bool, Error].success(value = true)


public function enqueue_incoming_checksum(
    queue: ref[vec.Vec[IncomingChecksumPacket]],
    sender: Option[ConnectionId],
    channel: uint,
    payload: span[ubyte]
) -> Result[bool, Error]:
    let report = decode_checksum_payload(payload) else as report_error:
        return Result[bool, Error].failure(error = report_error)

    queue.push(IncomingChecksumPacket(report = report, sender = sender, channel = channel))
    return Result[bool, Error].success(value = true)


public function dequeue_incoming_command(
    queue: ref[vec.Vec[IncomingCommandPacket]]
) -> Option[IncomingCommandPacket]:
    if queue.len() == 0:
        return Option[IncomingCommandPacket].none

    match queue.remove(0):
        Option.some as payload:
            return Option[IncomingCommandPacket].some(value = payload.value)
        Option.none:
            return Option[IncomingCommandPacket].none


public function dequeue_incoming_checksum(
    queue: ref[vec.Vec[IncomingChecksumPacket]]
) -> Option[IncomingChecksumPacket]:
    if queue.len() == 0:
        return Option[IncomingChecksumPacket].none

    match queue.remove(0):
        Option.some as payload:
            return Option[IncomingChecksumPacket].some(value = payload.value)
        Option.none:
            return Option[IncomingChecksumPacket].none


public function release_command_queue(queue: ref[vec.Vec[IncomingCommandPacket]]) -> void:
    while true:
        match queue.pop():
            Option.some as payload:
                var packet = payload.value
                packet.payload.release()
            Option.none:
                queue.release()
                return


public function release_checksum_queue(queue: ref[vec.Vec[IncomingChecksumPacket]]) -> void:
    queue.release()


extending IncomingCommandPacket:
    public mutable function release() -> void:
        this.payload.release()


function validate_turn_submission[T](
    collector: ref[TurnCollector[T]],
    slot: ptr_uint,
    turn_id: TurnId,
    incoming_commands: ptr_uint
) -> Result[bool, Error]:
    let _ = validate_turn_identity(read(collector).current_turn, turn_id) else as turn_error:
        return Result[bool, Error].failure(error = turn_error)
    let _ = validate_slot(read(collector).required_slots, slot)?

    if read(collector).sealed:
        return Result[bool, Error].failure(error = protocol.error(
            ErrorCode.invalid_argument,
            "lockstep turn is already sealed"
        ))

    let already_submitted = slot_flag(read(collector).submitted_slots.as_span(), slot) else as slot_error:
        return Result[bool, Error].failure(error = slot_error)
    if already_submitted:
        return Result[bool, Error].failure(error = protocol.error(
            ErrorCode.already_registered,
            "slot already submitted commands for this turn"
        ))

    if incoming_commands > read(collector).max_commands_per_turn - read(collector).commands.len():
        return Result[bool, Error].failure(error = protocol.error(
            ErrorCode.invalid_argument,
            "lockstep turn exceeded the configured command budget"
        ))

    return Result[bool, Error].success(value = true)


function validate_turn_identity(expected: TurnId, provided: TurnId) -> Result[bool, Error]:
    if expected != provided:
        return Result[bool, Error].failure(error = protocol.error(
            ErrorCode.invalid_argument,
            "lockstep call used a turn id that does not match the current turn"
        ))

    return Result[bool, Error].success(value = true)


function validate_slot(required_slots: ptr_uint, slot: ptr_uint) -> Result[bool, Error]:
    if slot >= required_slots:
        return Result[bool, Error].failure(error = protocol.error(
            ErrorCode.invalid_argument,
            "lockstep slot index is out of range"
        ))

    return Result[bool, Error].success(value = true)


function slot_flag(values: span[bool], slot: ptr_uint) -> Result[bool, Error]:
    if slot >= values.len:
        return Result[bool, Error].failure(error = protocol.error(
            ErrorCode.invalid_argument,
            "lockstep slot index is out of range"
        ))

    unsafe:
        return Result[bool, Error].success(value = read(values.data + slot))


function set_slot_flag(values: ref[vec.Vec[bool]], slot: ptr_uint, value: bool) -> void:
    let entry = read(values).get(slot) else:
        fatal(c"lockstep missing slot flag entry")

    unsafe:
        read(ptr[bool]<-entry) = value


function set_checksum_value(values: ref[vec.Vec[ulong]], slot: ptr_uint, checksum: ulong) -> void:
    let entry = read(values).get(slot) else:
        fatal(c"lockstep missing checksum entry")

    unsafe:
        read(ptr[ulong]<-entry) = checksum


function count_true(values: span[bool]) -> ptr_uint:
    var total: ptr_uint = 0
    var index: ptr_uint = 0
    while index < values.len:
        unsafe:
            if read(values.data + index):
                total += 1
        index += 1

    return total


function first_reported_checksum(
    reported: span[bool],
    values: span[ulong],
    ignored_slot: ptr_uint
) -> Option[ulong]:
    var index: ptr_uint = 0
    while index < reported.len:
        if index != ignored_slot:
            unsafe:
                if read(reported.data + index):
                    return Option[ulong].some(value = read(values.data + index))
        index += 1

    return Option[ulong].none


function reset_flags(values: ref[vec.Vec[bool]], value: bool) -> void:
    var index: ptr_uint = 0
    while index < read(values).len():
        let entry = read(values).get(index)
        if entry == null:
            break
        unsafe:
            read(ptr[bool]<-entry) = value
        index += 1


function reset_checksums(values: ref[vec.Vec[ulong]]) -> void:
    var index: ptr_uint = 0
    while index < read(values).len():
        let entry = read(values).get(index)
        if entry == null:
            break
        unsafe:
            read(ptr[ulong]<-entry) = ulong<-0
        index += 1


function has_desync(desync: Option[DesyncReport]) -> bool:
    match desync:
        Option.some:
            return true
        Option.none:
            return false
