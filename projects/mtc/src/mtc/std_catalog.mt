## Standard-library catalog data: module name -> category and one-line
## description.  Generated from lib/milk_tea/tooling/std_catalog.rb
## (REGISTRY / CATEGORY_ORDER) so `mtc std list` matches the Ruby CLI.

public struct StdEntryInfo:
    category: str
    description: str


public function std_category_order_count() -> ptr_uint:
    return 12


public function std_category_order_at(index: ptr_uint) -> str:
    if index == 0:
        return "Core & Patterns"
    if index == 1:
        return "Collections"
    if index == 2:
        return "Memory"
    if index == 3:
        return "Text & Formatting"
    if index == 4:
        return "Math & Simulation"
    if index == 5:
        return "Data & Serialization"
    if index == 6:
        return "Concurrency & Time"
    if index == 7:
        return "Files & System"
    if index == 8:
        return "Network"
    if index == 9:
        return "Security"
    if index == 10:
        return "AI & Behavior"
    if index == 11:
        return "Game & Graphics"
    return ""


## Category + description for a std module name, or none when the module
## is not in the hand-maintained registry.
public function std_registry_lookup(name: str) -> Option[StdEntryInfo]:
    if name == "asset_pack": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Game & Graphics", description = "MTAP asset pack reader and writer for bundled runtime assets."))
    if name == "async": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Concurrency & Time", description = "Async/await runtime facade over a pluggable event-loop backend."))
    if name == "async.libuv_runtime": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Concurrency & Time", description = "libuv-backed async runtime implementation."))
    if name == "async.mailbox": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Concurrency & Time", description = "Typed mailboxes for message passing between async tasks."))
    if name == "async.runtime": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Concurrency & Time", description = "Async backend selection and event-loop plumbing shared by async code."))
    if name == "base64": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Text & Formatting", description = "Base64 encode and decode."))
    if name == "behavior_tree": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "AI & Behavior", description = "Behavior trees with sequence, selector, decorator, and leaf nodes."))
    if name == "binary": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Data & Serialization", description = "Binary reader/writer with explicit endianness and error reporting."))
    if name == "binary_heap": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Collections", description = "Binary heap over a flat array with sift-up/sift-down operations."))
    if name == "bitset": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Collections", description = "Fixed-capacity bit array with set, clear, test, and population count."))
    if name == "blackboard": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "AI & Behavior", description = "Typed key-value shared state for AI agents."))
    if name == "box": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Core & Patterns", description = "Explicit single-value heap storage for owned boxed values."))
    if name == "bytes": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Data & Serialization", description = "Byte buffer type with slicing, comparison, and stream I/O."))
    if name == "cli": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Files & System", description = "Command-line parsing helpers for flags, options, and positionals."))
    if name == "cmd": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Core & Patterns", description = "Command pattern with paired do/undo callbacks for undo/redo stacks."))
    if name == "color": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Game & Graphics", description = "RGBA color conversion, blending, and named presets."))
    if name == "cookie": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Data & Serialization", description = "HTTP cookie parsing and serialization."))
    if name == "counter": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Collections", description = "Occurrence counter keyed by value, a counting multiset."))
    if name == "crypto": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Security", description = "Digests, HMAC, and secure random via the platform crypto bindings."))
    if name == "cstring": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Text & Formatting", description = "Null-terminated C string helpers backed by libc memory routines."))
    if name == "ctype": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Text & Formatting", description = "Character classification: alnum, digit, space, and case tests."))
    if name == "curl.runtime": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Network", description = "libcurl runtime glue for handle setup and error reporting."))
    if name == "deque": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Collections", description = "Double-ended queue with amortized O(1) operations at both ends."))
    if name == "encoding": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Text & Formatting", description = "UTF-8 validation, codepoint iteration, and encoding helpers."))
    if name == "env": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Files & System", description = "Environment variable access returning Option values."))
    if name == "errno": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Files & System", description = "errno code constants and error message lookup."))
    if name == "fmt": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Text & Formatting", description = "Value formatting helpers for integers, floats, and fixed buffers."))
    if name == "fs": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Files & System", description = "File and directory operations with platform-specific variants."))
    if name == "fsm": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "AI & Behavior", description = "Finite state machines with table-driven transitions and dispatch."))
    if name == "goap": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "AI & Behavior", description = "Goal-oriented action planning (GOAP) with forward search."))
    if name == "graph": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Game & Graphics", description = "Weighted graph algorithms such as shortest paths and reachability."))
    if name == "gzip": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Data & Serialization", description = "Gzip and zlib compression and decompression."))
    if name == "hash": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Core & Patterns", description = "Canonical hash, equality, and ordering for common primitive types."))
    if name == "htn": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "AI & Behavior", description = "Hierarchical Task Network (HTN) planner."))
    if name == "http": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Network", description = "HTTP client for requests, responses, and chunked bodies."))
    if name == "http.server": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Network", description = "Small HTTP server with routing, static files, and JSON responses."))
    if name == "input": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Game & Graphics", description = "Input action mapping that decouples logical actions from physical devices."))
    if name == "intern": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Text & Formatting", description = "String interning table producing unique identifier handles."))
    if name == "iter": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Core & Patterns", description = "Composable lazy iteration adaptors over sequences."))
    if name == "jobs": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Concurrency & Time", description = "Job scheduler for fan-out parallel work with completion tracking."))
    if name == "json": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Data & Serialization", description = "JSON parsing and serialization over cjson with arena-backed values."))
    if name == "libc": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Files & System", description = "Curated libc facade for memory, string, process, and math functions."))
    if name == "linear_algebra": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Math & Simulation", description = "Vectors and matrices for 2D/3D graphics and physics."))
    if name == "linked_map": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Collections", description = "Hash map with a doubly-linked order list for O(1) reordering."))
    if name == "linked_map_view": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Collections", description = "Read-only snapshot views over linked_map instances."))
    if name == "linked_set": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Collections", description = "Insertion-ordered hash set backed by a linked list."))
    if name == "log": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Files & System", description = "Leveled logging with configurable output sinks."))
    if name == "lru_cache": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Collections", description = "Least-recently-used cache with bounded capacity."))
    if name == "map": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Collections", description = "Chained hash map with pluggable hashing for generic keys and values."))
    if name == "math": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Math & Simulation", description = "Mathematical constants and functions beyond the language builtins."))
    if name == "mem.arena": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Memory", description = "Region allocator: bump allocation with O(1) mark/reset."))
    if name == "mem.endian": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Memory", description = "Byte-swap and endian conversion helpers."))
    if name == "mem.heap": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Memory", description = "General-purpose heap allocator wrapper with alignment control."))
    if name == "mem.pool": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Memory", description = "Fixed-slot pool allocator for uniform-size objects."))
    if name == "mem.ptr": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Memory", description = "Safe pointer load/store wrappers around raw memory access."))
    if name == "mem.stack": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Memory", description = "Stack allocator with mark/release layered on the arena."))
    if name == "mem.tracking": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Memory", description = "Allocation tracker for leak detection and usage diagnostics."))
    if name == "multiset": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Collections", description = "Hash multiset that counts duplicate values."))
    if name == "net": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Network", description = "UDP and TCP sockets, address resolution, and packet I/O."))
    if name == "net.channel": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Network", description = "Multiplexed message channels over a single connection."))
    if name == "net.clock": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Network", description = "Synchronized network clock with ping and offset estimation."))
    if name == "net.discovery": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Network", description = "LAN service discovery via UDP broadcast."))
    if name == "net.lobby": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Network", description = "Lobby listing and joining built on discovery."))
    if name == "net.manager": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Network", description = "Connection and session manager for multiplayer topologies."))
    if name == "net.mux": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Network", description = "Stream multiplexer with reliable and unordered delivery flags."))
    if name == "net.nat": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Network", description = "NAT type detection and address binding via STUN."))
    if name == "net.packet": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Network", description = "Framed packet reading and writing over byte streams."))
    if name == "net.punch": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Network", description = "UDP hole punching for peer-to-peer connections."))
    if name == "net.rpc": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Network", description = "Request/response RPC framing over net channels."))
    if name == "net.session": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Network", description = "Client session state machine with heartbeats and timeouts."))
    if name == "net.stun": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Network", description = "STUN client for public address and port discovery."))
    if name == "net.sync": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Network", description = "State synchronization primitives for replicated values."))
    if name == "net.turn": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Network", description = "TURN relay client for NAT-restricted peers."))
    if name == "noise": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Math & Simulation", description = "Coherent Perlin noise and fractal variants."))
    if name == "oauth2": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Data & Serialization", description = "OAuth2 token requests and refresh flows."))
    if name == "option": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Core & Patterns", description = "Option[T] optional values, some(value) or none, with combinators."))
    if name == "ordered_map": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Collections", description = "Hash map that preserves insertion order."))
    if name == "ordered_set": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Collections", description = "Hash set that preserves insertion order."))
    if name == "parse": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Text & Formatting", description = "Numeric string parsing for integers and floats."))
    if name == "path": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Files & System", description = "Path join, split, and normalization utilities."))
    if name == "pcre2.runtime": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Text & Formatting", description = "Compiled regex matching runtime over the pcre2 bindings."))
    if name == "pool": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Collections", description = "Fixed-capacity reusable object storage."))
    if name == "priority_queue": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Collections", description = "Priority queue backed by a binary heap."))
    if name == "process": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Files & System", description = "Child process spawning with pipes and exit status."))
    if name == "queue": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Collections", description = "First-in first-out queue."))
    if name == "random": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Math & Simulation", description = "PCG pseudo-random number generation with seeding and ranges."))
    if name == "raylib.debug_console": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Game & Graphics", description = "In-game debug console overlay with command history."))
    if name == "raylib.easing": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Game & Graphics", description = "Easing curves for animation interpolation."))
    if name == "raylib.packed_assets": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Game & Graphics", description = "Load images, textures, and audio from assets.mtpack packs."))
    if name == "raylib.runtime": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Game & Graphics", description = "raylib app lifecycle helpers: window loop, asset directory, fatal errors."))
    if name == "raylib.tracy_gpu": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Game & Graphics", description = "Tracy profiler GPU zone calibration for raylib."))
    if name == "result": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Core & Patterns", description = "Result[T, E] success/failure type for recoverable errors."))
    if name == "ring_buffer": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Collections", description = "Fixed-capacity circular buffer with overwrite behavior."))
    if name == "sdl3.runtime": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Game & Graphics", description = "SDL3 app lifecycle helpers and main-loop wrappers."))
    if name == "serialize": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Data & Serialization", description = "Struct field serialization helpers layered on std.binary."))
    if name == "set": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Collections", description = "Hash set of unique values."))
    if name == "signal": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Concurrency & Time", description = "Fixed-capacity observer and publish-subscribe signals."))
    if name == "simd": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Math & Simulation", description = "SIMD load, store, and reduction helpers."))
    if name == "sparse_set": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Collections", description = "Sparse set with dense iteration for integer-keyed data."))
    if name == "spatial": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Math & Simulation", description = "Uniform spatial hash grid for broad-phase queries."))
    if name == "stack": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Collections", description = "Last-in first-out stack."))
    if name == "steering": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "AI & Behavior", description = "Craig Reynolds steering behaviors for autonomous motion."))
    if name == "stdio": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Files & System", description = "Stdin, stdout, and stderr FILE wrappers and console I/O."))
    if name == "str": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Text & Formatting", description = "Borrowed string slice helpers: length, compare, search, split."))
    if name == "string": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Text & Formatting", description = "Heap-owned growable string type with builder operations."))
    if name == "sync": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Concurrency & Time", description = "Mutex, condition variable, and once primitives over libuv."))
    if name == "tar": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Data & Serialization", description = "TAR archive reading and writing with 512-byte blocks."))
    if name == "terminal": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Files & System", description = "Terminal size, color, and raw-mode helpers."))
    if name == "thread": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Concurrency & Time", description = "Threads via libuv with join and handle management."))
    if name == "time": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Concurrency & Time", description = "Wall-clock timestamps and monotonic time helpers."))
    if name == "timer": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Concurrency & Time", description = "Countdown and repeating timers."))
    if name == "tls": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Security", description = "TLS client and server streams over libuv handles."))
    if name == "toml": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Data & Serialization", description = "TOML parser for configuration files."))
    if name == "tween": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Game & Graphics", description = "Tweening and easing for smooth value interpolation."))
    if name == "uri": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Data & Serialization", description = "URI parsing and construction, including file and web schemes."))
    if name == "url": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Data & Serialization", description = "URL parsing: scheme, host, path, query, and percent-encoding."))
    if name == "utility": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "AI & Behavior", description = "Utility AI with score-based action selection."))
    if name == "vec": return Option[StdEntryInfo].some(value = StdEntryInfo(category = "Collections", description = "Growable contiguous array Vec[T], the default dynamic sequence."))
    return Option[StdEntryInfo].none
