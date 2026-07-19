## DAP wire helpers — write DAP responses and events to the client via
## the protocol framing.

import std.fmt
import std.string as string

import mtc.dap.protocol as proto


## Write a DAP response message with a body.
public function write_response(session_seq: ptr_uint, request_seq: ptr_uint, body_json: str) -> void:
    var r = string.String.create()
    defer r.release()
    r.append("{\"seq\":")
    r.append_format(f"#{session_seq}")
    r.append(",\"type\":\"response\",\"request_seq\":")
    r.append_format(f"#{request_seq}")
    r.append(",\"success\":true,\"command\":\"\"")
    if body_json.len > 0:
        r.append(",\"body\":")
        r.append(body_json)
    r.append("}")
    proto.write_framed_json(r.as_str())


## Write a DAP error response.
public function write_error(session_seq: ptr_uint, request_seq: ptr_uint, error_message: str) -> void:
    var r = string.String.create()
    defer r.release()
    r.append("{\"seq\":")
    r.append_format(f"#{session_seq}")
    r.append(",\"type\":\"response\",\"request_seq\":")
    r.append_format(f"#{request_seq}")
    r.append(",\"success\":false,\"command\":\"\",\"message\":\"")
    proto.append_escaped(ref_of(r), error_message)
    r.append("\"}")
    proto.write_framed_json(r.as_str())


## Write a DAP response with raw text (for pre-serialized bodies).
public function write_response_raw(session_seq: ptr_uint, request_seq: ptr_uint, raw_json: str) -> void:
    proto.write_framed_json(raw_json)


## Write a DAP event.
public function write_event(session_seq: ptr_uint, evt: str, body_json: str) -> void:
    var r = string.String.create()
    defer r.release()
    r.append("{\"seq\":")
    r.append_format(f"#{session_seq}")
    r.append(",\"type\":\"event\",\"event\":\"")
    proto.append_escaped(ref_of(r), evt)
    r.append("\"")
    if body_json.len > 0:
        r.append(",\"body\":")
        r.append(body_json)
    r.append("}")
    proto.write_framed_json(r.as_str())
