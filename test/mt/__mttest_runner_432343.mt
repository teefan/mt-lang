# In-language tests for std.binary (migrated from
# test/std/std_binary_test.rb, run by `mtc test`).

import std.testing as t
import std.binary as bin
import std.str as str

@[test]
function test_binary_round_trips_unsigned_integers() -> t.Check:
    var w = bin.Writer.create()
    defer w.release()
    w.write_ubyte(0xFF)
    w.write_ushort(0xABCD)
    w.write_uint(0xDEADBEEF)
    w.write_ulong(0x0123456789ABCDEF)

    var reader = bin.reader(w.as_span())

    match reader.read_ubyte():
        Result.failure:
            return t.fail("read_ubyte failed")
        Result.success as payload:
            t.expect(payload.value == 0xFF, "ubyte round-trips")?
    match reader.read_ushort():
        Result.failure:
            return t.fail("read_ushort failed")
        Result.success as payload:
            t.expect(payload.value == 0xABCD, "ushort round-trips")?
    match reader.read_uint():
        Result.failure:
            return t.fail("read_uint failed")
        Result.success as payload:
            t.expect(payload.value == 0xDEADBEEF, "uint round-trips")?
    match reader.read_ulong():
        Result.failure:
            return t.fail("read_ulong failed")
        Result.success as payload:
            t.expect(payload.value == 0x0123456789ABCDEF, "ulong round-trips")?
    return t.ok()


@[test]
function test_binary_round_trips_signed_integers() -> t.Check:
    var w = bin.Writer.create()
    defer w.release()
    w.write_byte(byte<--1)
    w.write_short(short<--30000)
    w.write_int(-2000000000)
    w.write_long(-9000000000000000000)

    var reader = bin.reader(w.as_span())

    match reader.read_byte():
        Result.failure:
            return t.fail("read_byte failed")
        Result.success as payload:
            t.expect(payload.value == byte<--1, "byte round-trips")?
    match reader.read_short():
        Result.failure:
            return t.fail("read_short failed")
        Result.success as payload:
            t.expect(payload.value == short<--30000, "short round-trips")?
    match reader.read_int():
        Result.failure:
            return t.fail("read_int failed")
        Result.success as payload:
            t.expect(payload.value == -2000000000, "int round-trips")?
    match reader.read_long():
        Result.failure:
            return t.fail("read_long failed")
        Result.success as payload:
            t.expect(payload.value == -9000000000000000000, "long round-trips")?
    return t.ok()


@[test]
function test_binary_round_trips_floats() -> t.Check:
    var w = bin.Writer.create()
    defer w.release()
    w.write_float(3.140000104904175)
    w.write_double(2.718281828459045)

    var reader = bin.reader(w.as_span())

    match reader.read_float():
        Result.failure:
            return t.fail("read_float failed")
        Result.success as payload:
            t.expect(payload.value == 3.140000104904175, "float round-trips")?
    match reader.read_double():
        Result.failure:
            return t.fail("read_double failed")
        Result.success as payload:
            t.expect(payload.value == 2.718281828459045, "double round-trips")?
    return t.ok()


@[test]
function test_binary_round_trips_bool() -> t.Check:
    var w = bin.Writer.create()
    defer w.release()
    w.write_bool(true)
    w.write_bool(false)
    w.write_bool(true)

    var reader = bin.reader(w.as_span())

    match reader.read_bool():
        Result.failure:
            return t.fail("read_bool 1 failed")
        Result.success as payload:
            t.expect_true(payload.value)?
    match reader.read_bool():
        Result.failure:
            return t.fail("read_bool 2 failed")
        Result.success as payload:
            t.expect_false(payload.value)?
    match reader.read_bool():
        Result.failure:
            return t.fail("read_bool 3 failed")
        Result.success as payload:
            t.expect_true(payload.value)?
    return t.expect_false(reader.has_more())


@[test]
function test_binary_round_trips_strings() -> t.Check:
    var w = bin.Writer.create()
    defer w.release()
    w.write_str("hello")
    w.write_str("")
    w.write_str("world")

    var reader = bin.reader(w.as_span())

    match reader.read_str():
        Result.failure:
            return t.fail("read_str 1 failed")
        Result.success as payload:
            var s1 = payload.value
            defer s1.release()
            t.expect_true(s1.as_str().equal("hello"))?
    match reader.read_str():
        Result.failure:
            return t.fail("read_str 2 failed")
        Result.success as payload:
            var s2 = payload.value
            defer s2.release()
            t.expect(s2.len() == 0, "empty string len 0")?
    match reader.read_str():
        Result.failure:
            return t.fail("read_str 3 failed")
        Result.success as payload:
            var s3 = payload.value
            defer s3.release()
            t.expect_true(s3.as_str().equal("world"))?
    return t.ok()


@[test]
function test_binary_round_trips_bytes() -> t.Check:
    var w = bin.Writer.create()
    defer w.release()
    let data = str.as_byte_span("abcde")
    w.write_bytes(data)

    var reader = bin.reader(w.as_span())

    match reader.read_bytes(5):
        Result.failure:
            return t.fail("read_bytes failed")
        Result.success as payload:
            var chunk = payload.value
            defer chunk.release()
            match chunk.as_str():
                Option.none:
                    return t.fail("bytes not valid utf-8")
                Option.some as str_payload:
                    t.expect_true(str_payload.value.equal("abcde"))?
    return t.expect_false(reader.has_more())


@[test]
function test_binary_reset_and_finish() -> t.Check:
    var w = bin.Writer.create()
    w.write_uint(42)
    w.reset()
    w.write_uint(99)

    var reader = bin.reader(w.as_span())
    t.expect(w.len() == 4, "len == 4 after reset/rewrite")?

    match reader.read_uint():
        Result.failure:
            return t.fail("read_uint failed")
        Result.success as payload:
            t.expect(payload.value == 99, "reset discarded first value")?

    var result = w.finish()
    defer result.release()
    return t.expect(result.len == 4z, "finished buffer len 4")


@[test]
function test_binary_write_uint_at_positional_patch() -> t.Check:
    var w = bin.Writer.create()
    defer w.release()
    w.write_uint(0)
    w.write_ubyte(1)
    w.write_ubyte(2)
    w.write_ubyte(3)
    w.write_uint_at(0, 9999)

    var reader = bin.reader(w.as_span())

    match reader.read_uint():
        Result.failure:
            return t.fail("read_uint failed")
        Result.success as payload:
            t.expect(payload.value == 9999, "patched uint")?
    match reader.read_ubyte():
        Result.failure:
            return t.fail("read_ubyte failed")
        Result.success as payload:
            t.expect(payload.value == 1, "trailing byte preserved")?
    return t.ok()


@[test]
function test_binary_reader_reports_end_of_buffer() -> t.Check:
    var w = bin.Writer.create()
    defer w.release()
    w.write_ubyte(1)

    var reader = bin.reader(w.as_span())

    match reader.read_ubyte():
        Result.failure:
            return t.fail("first read should succeed")
        Result.success:
            pass

    t.expect_false(reader.has_more())?

    match reader.read_ubyte():
        Result.failure:
            return t.ok()
        Result.success:
            return t.fail("read past end should fail")


@[test]
function test_binary_reader_reports_invalid_bool() -> t.Check:
    var w = bin.Writer.create()
    defer w.release()
    w.write_ubyte(42)
    var reader = bin.reader(w.as_span())

    match reader.read_bool():
        Result.failure:
            return t.ok()
        Result.success:
            return t.fail("invalid bool byte should fail")


@[test]
function test_binary_writer_with_capacity_preallocates() -> t.Check:
    var w = bin.Writer.with_capacity(256)
    defer w.release()
    t.expect(w.buffer.capacity() >= 256, "capacity >= 256")?
    t.expect(w.len() == 0, "len == 0 initially")?
    w.write_uint(1)
    w.write_uint(2)
    return t.ok()


@[test]
function test_binary_reader_remaining_and_has_more() -> t.Check:
    var w = bin.Writer.create()
    defer w.release()
    w.write_uint(100)
    w.write_ushort(200)

    var reader = bin.reader(w.as_span())

    t.expect(reader.remaining() == 6z, "remaining == 6")?
    t.expect_true(reader.has_more())?

    match reader.read_uint():
        Result.failure:
            return t.fail("read_uint failed")
        Result.success:
            pass
    t.expect(reader.remaining() == 2z, "remaining == 2")?

    match reader.read_ushort():
        Result.failure:
            return t.fail("read_ushort failed")
        Result.success:
            pass
    t.expect(reader.remaining() == 0z, "remaining == 0")?
    return t.expect_false(reader.has_more())


@[test]
function test_binary_reader_skip_advances_position() -> t.Check:
    var w = bin.Writer.create()
    defer w.release()
    w.write_uint(100)
    w.write_ubyte(42)
    w.write_ushort(200)

    var reader = bin.reader(w.as_span())

    match reader.skip(4):
        Result.failure:
            return t.fail("skip failed")
        Result.success:
            pass
    match reader.read_ubyte():
        Result.failure:
            return t.fail("read_ubyte failed")
        Result.success as p:
            t.expect(p.value == 42, "byte after skip")?
    match reader.read_ushort():
        Result.failure:
            return t.fail("read_ushort failed")
        Result.success as p:
            t.expect(p.value == 200, "ushort after skip")?
    return t.expect_false(reader.has_more())


@[test]
function test_binary_round_trips_mixed_types() -> t.Check:
    var w = bin.Writer.create()
    defer w.release()
    w.write_bool(true)
    w.write_uint(1234567890)
    w.write_float(1.5)
    w.write_str("mixed")
    w.write_ushort(42)

    var reader = bin.reader(w.as_span())

    match reader.read_bool():
        Result.failure:
            return t.fail("read_bool failed")
        Result.success as p:
            t.expect_true(p.value)?
    match reader.read_uint():
        Result.failure:
            return t.fail("read_uint failed")
        Result.success as p:
            t.expect(p.value == 1234567890, "uint round-trips")?
    match reader.read_float():
        Result.failure:
            return t.fail("read_float failed")
        Result.success as p:
            t.expect(p.value == 1.5, "float round-trips")?
    match reader.read_str():
        Result.failure:
            return t.fail("read_str failed")
        Result.success as p:
            var s = p.value
            defer s.release()
            t.expect_true(s.as_str().equal("mixed"))?
    match reader.read_ushort():
        Result.failure:
            return t.fail("read_ushort failed")
        Result.success as p:
            t.expect(p.value == 42, "ushort round-trips")?
    return t.expect_false(reader.has_more())


function main() -> int:
    var __mt_test_stats = t.Stats.create()
    __mt_test_stats = t.record(__mt_test_stats, "test_binary_round_trips_unsigned_integers", test_binary_round_trips_unsigned_integers())
    __mt_test_stats = t.record(__mt_test_stats, "test_binary_round_trips_signed_integers", test_binary_round_trips_signed_integers())
    __mt_test_stats = t.record(__mt_test_stats, "test_binary_round_trips_floats", test_binary_round_trips_floats())
    __mt_test_stats = t.record(__mt_test_stats, "test_binary_round_trips_bool", test_binary_round_trips_bool())
    __mt_test_stats = t.record(__mt_test_stats, "test_binary_round_trips_strings", test_binary_round_trips_strings())
    __mt_test_stats = t.record(__mt_test_stats, "test_binary_round_trips_bytes", test_binary_round_trips_bytes())
    __mt_test_stats = t.record(__mt_test_stats, "test_binary_reset_and_finish", test_binary_reset_and_finish())
    __mt_test_stats = t.record(__mt_test_stats, "test_binary_write_uint_at_positional_patch", test_binary_write_uint_at_positional_patch())
    __mt_test_stats = t.record(__mt_test_stats, "test_binary_reader_reports_end_of_buffer", test_binary_reader_reports_end_of_buffer())
    __mt_test_stats = t.record(__mt_test_stats, "test_binary_reader_reports_invalid_bool", test_binary_reader_reports_invalid_bool())
    __mt_test_stats = t.record(__mt_test_stats, "test_binary_writer_with_capacity_preallocates", test_binary_writer_with_capacity_preallocates())
    __mt_test_stats = t.record(__mt_test_stats, "test_binary_reader_remaining_and_has_more", test_binary_reader_remaining_and_has_more())
    __mt_test_stats = t.record(__mt_test_stats, "test_binary_reader_skip_advances_position", test_binary_reader_skip_advances_position())
    __mt_test_stats = t.record(__mt_test_stats, "test_binary_round_trips_mixed_types", test_binary_round_trips_mixed_types())
    return t.summarize(__mt_test_stats)
