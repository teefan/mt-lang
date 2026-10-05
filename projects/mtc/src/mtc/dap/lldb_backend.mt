## lldb-dap bridge — adapter transport and request bookkeeping.  The adapter is
## a child process; `server.mt`'s libuv loop fills its framer through a poll
## handle and `lldb_policy.mt` drives the DAP handshake.  A single-threaded
## port of `lib/milk_tea/dap/lldb_dap_backend.rb` plus the transport half of
## `lib/milk_tea/dap/server/lldb_backend.rb`.

import std.json as json
import std.mem.heap as heap
import std.process as process
import std.str
import std.string as string
import std.vec as vec

import mtc.dap.protocol as proto


## How a pending adapter request resolves when its response arrives.
public const KIND_FORWARD:        int = 0
public const KIND_INTERNAL:       int = 1
public const KIND_CLIENT_INIT:    int = 2
public const KIND_START_INIT:     int = 3
public const KIND_START:          int = 4
public const KIND_CONFIG_DONE:    int = 5
public const KIND_AUTO_CONTINUE:  int = 6
public const KIND_TERMINATE:      int = 7
public const KIND_DISCONNECT:     int = 8
public const KIND_SYNC_BREAKPOINTS: int = 9
public const KIND_SYNC_FUNCTIONS: int = 10
public const KIND_SYNC_EXCEPTIONS: int = 11


## A request sent to lldb-dap, awaiting its response.
public struct PendingRequest:
    adapter_seq: ptr_uint
    client_seq: ptr_uint
    command: string.String
    deadline: ptr_uint
    kind: int


## An adapter request forwarded to the client, awaiting the client's response.
public struct PendingClientRequest:
    client_seq: ptr_uint
    adapter_seq: ptr_uint
    command: string.String
    deadline: ptr_uint


public struct Backend:
    running: bool
    child: process.ChildProcess
    framer: ptr[proto.Framer]?
    next_seq: ptr_uint
    initialized: bool
    capabilities_text: string.String
    config_ready: bool
    start_pending: bool
    auto_continue_after_config: bool
    stop_on_entry: bool
    pause_requested: bool
    stopped_thread_id: ptr_uint
    has_stopped_thread: bool
    has_continued_signature: bool
    last_continued_thread: ptr_uint
    last_continued_all: bool
    has_pending_start: bool
    pending_start_client_seq: ptr_uint
    pending_start_command: string.String
    pending_start_arguments: string.String
    has_deferred_config: bool
    deferred_config_client_seq: ptr_uint
    pending: vec.Vec[PendingRequest]
    pending_client: vec.Vec[PendingClientRequest]


public function create() -> Backend:
    return Backend(
        running = false,
        child = zero[process.ChildProcess],
        framer = null,
        next_seq = 1,
        initialized = false,
        capabilities_text = string.String.create(),
        config_ready = false,
        start_pending = false,
        auto_continue_after_config = false,
        stop_on_entry = true,
        pause_requested = false,
        stopped_thread_id = 0,
        has_stopped_thread = false,
        has_continued_signature = false,
        last_continued_thread = 0,
        last_continued_all = false,
        has_pending_start = false,
        pending_start_client_seq = 0,
        pending_start_command = string.String.create(),
        pending_start_arguments = string.String.create(),
        has_deferred_config = false,
        deferred_config_client_seq = 0,
        pending = vec.Vec[PendingRequest].create(),
        pending_client = vec.Vec[PendingClientRequest].create(),
    )


## Stop the adapter (if running) and release the backend's storage.
public function release(backend: ref[Backend]) -> void:
    stop(backend)
    release_pending(ref_of(backend.pending))
    release_pending_client(ref_of(backend.pending_client))
    backend.capabilities_text.release()
    backend.pending_start_command.release()
    backend.pending_start_arguments.release()


function release_pending(entries: ref[vec.Vec[PendingRequest]]) -> void:
    var i: ptr_uint = 0
    while i < entries.len():
        unsafe:
            let entry = entries.get(i)
            if entry != null:
                read(entry).command.release()
        i += 1
    entries.release()


function release_pending_client(entries: ref[vec.Vec[PendingClientRequest]]) -> void:
    var i: ptr_uint = 0
    while i < entries.len():
        unsafe:
            let entry = entries.get(i)
            if entry != null:
                read(entry).command.release()
        i += 1
    entries.release()


## Spawn the adapter (`command` is the full argv, e.g. ["lldb-dap"]).
public function start(backend: ref[Backend], command: span[str]) -> bool:
    if backend.running:
        return true

    match process.spawn_inheriting_env(command, Option[str].none, span[process.EnvironmentEntry]()):
        Result.success as spawned:
            backend.child = spawned.value
            backend.running = true
            let framer = heap.must_alloc[proto.Framer](1)
            unsafe:
                read(framer) = proto.framer_create(backend.child.stdout_fd)
            backend.framer = framer
            backend.next_seq = 1
            return true
        Result.failure as failure:
            var error = failure.error
            error.release()
            return false


## Terminate the adapter and drop its state.
public function stop(backend: ref[Backend]) -> void:
    if not backend.running:
        return
    backend.running = false
    let _ = backend.child.kill(15)
    backend.child.release()
    let framer = backend.framer
    if framer != null:
        unsafe:
            proto.framer_release(ref_of(read(framer)))
            heap.release(framer)
    backend.framer = null
    backend.initialized = false
    backend.capabilities_text.clear()
    backend.config_ready = false
    backend.start_pending = false
    backend.auto_continue_after_config = false
    backend.pause_requested = false
    backend.has_stopped_thread = false
    backend.has_continued_signature = false
    backend.has_pending_start = false
    backend.pending_start_command.clear()
    backend.pending_start_arguments.clear()
    backend.has_deferred_config = false


## Send one request to the adapter and record it as pending.
public function send(
    backend: ref[Backend],
    command: str,
    arguments_json: str,
    client_seq: ptr_uint,
    kind: int,
    deadline: ptr_uint,
) -> ptr_uint:
    let seq = backend.next_seq
    backend.next_seq = seq + 1

    var frame = string.String.create()
    defer: frame.release()
    frame.append("{\"seq\":")
    frame.append_format(f"#{seq}")
    frame.append(",\"type\":\"request\",\"command\":\"")
    proto.append_escaped(ref_of(frame), command)
    frame.append("\",\"arguments\":")
    if arguments_json.len > 0:
        frame.append(arguments_json)
    else:
        frame.append("{}")
    frame.append("}")

    let _sent = write_frame_to_child(ref_of(backend.child), frame.as_str())
    backend.pending.push(PendingRequest(
        adapter_seq = seq,
        client_seq = client_seq,
        command = string.String.from_str(command),
        deadline = deadline,
        kind = kind,
    ))
    return seq


## Send one response back to the adapter (answer to a reverse request).
public function send_response_to_adapter(
    backend: ref[Backend],
    adapter_seq: ptr_uint,
    command: str,
    success: bool,
    body_json: str,
    message: str,
) -> void:
    var frame = string.String.create()
    defer: frame.release()
    frame.append("{\"seq\":")
    frame.append_format(f"#{backend.next_seq}")
    backend.next_seq = backend.next_seq + 1
    frame.append(",\"type\":\"response\",\"request_seq\":")
    frame.append_format(f"#{adapter_seq}")
    frame.append(",\"success\":")
    if success:
        frame.append("true")
    else:
        frame.append("false")
    frame.append(",\"command\":\"")
    proto.append_escaped(ref_of(frame), command)
    frame.append("\"")
    if body_json.len > 0:
        frame.append(",\"body\":")
        frame.append(body_json)
    if message.len > 0:
        frame.append(",\"message\":\"")
        proto.append_escaped(ref_of(frame), message)
        frame.append("\"")
    frame.append("}")
    let _sent = write_frame_to_child(ref_of(backend.child), frame.as_str())


## Write a Content-Length framed message to the adapter's stdin.
function write_frame_to_child(child: ref[process.ChildProcess], json_text: str) -> bool:
    var frame = string.String.create()
    defer: frame.release()
    frame.append("Content-Length: ")
    frame.append_format(f"#{json_text.len}")
    frame.append("\r\n\r\n")
    frame.append(json_text)

    var sent: ptr_uint = 0
    let total = frame.len()
    while sent < total:
        match child.write_stdin(frame.as_str().slice(sent, total - sent)):
            Result.success as payload:
                let written = payload.value
                if written == 0:
                    return false
                sent += written
            Result.failure as failure:
                var error = failure.error
                error.release()
                return false
    return true


## Take the pending request for an adapter sequence (none when unknown).
public function take_pending(backend: ref[Backend], adapter_seq: ptr_uint) -> Option[PendingRequest]:
    var index: ptr_uint = 0
    while index < backend.pending.len():
        unsafe:
            let entry = backend.pending.get(index)
            if entry != null and read(entry).adapter_seq == adapter_seq:
                let taken = read(entry)
                swap_remove_pending(ref_of(backend.pending), index)
                return Option[PendingRequest].some(value = taken)
        index += 1
    return Option[PendingRequest].none


## Take the pending client request for a client sequence.
public function take_pending_client(backend: ref[Backend], client_seq: ptr_uint) -> Option[PendingClientRequest]:
    var index: ptr_uint = 0
    while index < backend.pending_client.len():
        unsafe:
            let entry = backend.pending_client.get(index)
            if entry != null and read(entry).client_seq == client_seq:
                let taken = read(entry)
                swap_remove_pending_client(ref_of(backend.pending_client), index)
                return Option[PendingClientRequest].some(value = taken)
        index += 1
    return Option[PendingClientRequest].none


function swap_remove_pending(entries: ref[vec.Vec[PendingRequest]], index: ptr_uint) -> void:
    let last_index = entries.len() - 1
    if index != last_index:
        unsafe:
            let slot = entries.get(index)
            let last = entries.get(last_index)
            if slot != null and last != null:
                read(slot) = read(last)
    let _ = entries.pop()


function swap_remove_pending_client(entries: ref[vec.Vec[PendingClientRequest]], index: ptr_uint) -> void:
    let last_index = entries.len() - 1
    if index != last_index:
        unsafe:
            let slot = entries.get(index)
            let last = entries.get(last_index)
            if slot != null and last != null:
                read(slot) = read(last)
    let _ = entries.pop()
