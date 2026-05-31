import std.multiplayer.protocol as protocol
import std.string as string

public struct Offer:
    session_id: string.String
    protocol_hash: ulong
    sdp: string.String
    trickle_candidates: bool

public struct Answer:
    session_id: string.String
    protocol_hash: ulong
    sdp: string.String
    trickle_candidates: bool

public struct Candidate:
    session_id: string.String
    candidate_sdp: string.String

public struct GatheringDone:
    session_id: string.String

public struct Reject:
    session_id: string.String
    error: protocol.Error


public function offer(
    session_id: str,
    protocol_hash: ulong,
    sdp: str,
    trickle_candidates: bool,
) -> Offer:
    return Offer(
        session_id = string.String.from_str(session_id),
        protocol_hash = protocol_hash,
        sdp = string.String.from_str(sdp),
        trickle_candidates = trickle_candidates
    )


public function answer(
    session_id: str,
    protocol_hash: ulong,
    sdp: str,
    trickle_candidates: bool,
) -> Answer:
    return Answer(
        session_id = string.String.from_str(session_id),
        protocol_hash = protocol_hash,
        sdp = string.String.from_str(sdp),
        trickle_candidates = trickle_candidates
    )


public function candidate(session_id: str, candidate_sdp: str) -> Candidate:
    return Candidate(
        session_id = string.String.from_str(session_id),
        candidate_sdp = string.String.from_str(candidate_sdp)
    )


public function gathering_done(session_id: str) -> GatheringDone:
    return GatheringDone(session_id = string.String.from_str(session_id))


public function reject(session_id: str, code: protocol.ErrorCode, message: str) -> Reject:
    return Reject(
        session_id = string.String.from_str(session_id),
        error = protocol.error(code, message)
    )


public function validate_offer(value: Offer, expected_protocol_hash: ulong) -> Result[bool, protocol.Error]:
    let _ = validate_session_id(value.session_id.as_str()) else as session_error:
        return Result[bool, protocol.Error].failure(error = session_error)

    if value.protocol_hash != expected_protocol_hash:
        return Result[bool, protocol.Error].failure(error = protocol.error(
            protocol.ErrorCode.invalid_argument,
            "signal offer protocol hash mismatch"
        ))

    if value.sdp.len() == 0:
        return Result[bool, protocol.Error].failure(error = protocol.error(
            protocol.ErrorCode.invalid_argument,
            "signal offer SDP must not be empty"
        ))

    return Result[bool, protocol.Error].success(value = true)


public function validate_answer(value: Answer, expected_protocol_hash: ulong) -> Result[bool, protocol.Error]:
    let _ = validate_session_id(value.session_id.as_str()) else as session_error:
        return Result[bool, protocol.Error].failure(error = session_error)

    if value.protocol_hash != expected_protocol_hash:
        return Result[bool, protocol.Error].failure(error = protocol.error(
            protocol.ErrorCode.invalid_argument,
            "signal answer protocol hash mismatch"
        ))

    if value.sdp.len() == 0:
        return Result[bool, protocol.Error].failure(error = protocol.error(
            protocol.ErrorCode.invalid_argument,
            "signal answer SDP must not be empty"
        ))

    return Result[bool, protocol.Error].success(value = true)


public function validate_candidate(value: Candidate) -> Result[bool, protocol.Error]:
    let _ = validate_session_id(value.session_id.as_str()) else as session_error:
        return Result[bool, protocol.Error].failure(error = session_error)

    if value.candidate_sdp.len() == 0:
        return Result[bool, protocol.Error].failure(error = protocol.error(
            protocol.ErrorCode.invalid_argument,
            "signal candidate SDP must not be empty"
        ))

    return Result[bool, protocol.Error].success(value = true)


public function validate_gathering_done(value: GatheringDone) -> Result[bool, protocol.Error]:
    return validate_session_id(value.session_id.as_str())


extending Offer:
    public function session() -> str:
        return this.session_id.as_str()


    public function description() -> str:
        return this.sdp.as_str()


    public mutable function release() -> void:
        this.session_id.release()
        this.sdp.release()


extending Answer:
    public function session() -> str:
        return this.session_id.as_str()


    public function description() -> str:
        return this.sdp.as_str()


    public mutable function release() -> void:
        this.session_id.release()
        this.sdp.release()


extending Candidate:
    public function session() -> str:
        return this.session_id.as_str()


    public function value() -> str:
        return this.candidate_sdp.as_str()


    public mutable function release() -> void:
        this.session_id.release()
        this.candidate_sdp.release()


extending GatheringDone:
    public function session() -> str:
        return this.session_id.as_str()


    public mutable function release() -> void:
        this.session_id.release()


extending Reject:
    public function session() -> str:
        return this.session_id.as_str()


    public mutable function release() -> void:
        this.session_id.release()


function validate_session_id(value: str) -> Result[bool, protocol.Error]:
    if value.len == 0:
        return Result[bool, protocol.Error].failure(error = protocol.error(
            protocol.ErrorCode.invalid_argument,
            "signal session_id must not be empty"
        ))

    return Result[bool, protocol.Error].success(value = true)
