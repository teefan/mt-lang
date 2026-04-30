# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdLibuvRuntimeTest < Minitest::Test
  def test_host_runtime_executes_libuv_timer_helpers
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_libuv_timer",
      "",
      "import std.libuv as uv",
      "import std.libuv.runtime as rt",
      "",
      "var fired: i32 = 0",
      "",
      "def on_close(handle: ptr[uv.uv_handle_t]) -> void:",
      "    return",
      "",
      "def on_timer(timer: ptr[uv.uv_timer_t]) -> void:",
      "    fired += 1",
      "    uv.timer_stop(timer)",
      "    unsafe:",
      "        uv.close(ptr[uv.uv_handle_t]<-timer, on_close)",
      "    return",
      "",
      "def main() -> i32:",
      "    let loop_result = rt.create_loop()",
      "    if not loop_result.is_ok:",
      "        return 1",
      "    var loop = loop_result.value",
      "",
      "    let timer_result = rt.create_timer(loop)",
      "    if not timer_result.is_ok:",
      "        rt.loop_release(addr(loop))",
      "        return 2",
      "    var timer = timer_result.value",
      "",
      "    if rt.timer_start_once(timer, 1, on_timer) != 0:",
      "        rt.handle_release(addr(timer))",
      "        rt.loop_release(addr(loop))",
      "        return 3",
      "    if rt.loop_run_default(loop) != 0:",
      "        rt.handle_release(addr(timer))",
      "        rt.loop_release(addr(loop))",
      "        return 4",
      "",
      "    rt.handle_release(addr(timer))",
      "    if rt.loop_release(addr(loop)) != 0:",
      "        return 5",
      "    return fired",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 1, result.exit_status
    assert_includes result.link_flags, "-luv"
  end

  def test_host_runtime_executes_libuv_queue_work_helpers
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_libuv_work",
      "",
      "import std.libuv as uv",
      "import std.libuv.runtime as rt",
      "",
      "var work_total: i32 = 0",
      "",
      "def on_work(req: ptr[uv.uv_work_t]) -> void:",
      "    work_total += 10",
      "    return",
      "",
      "def after_work(req: ptr[uv.uv_work_t], status: i32) -> void:",
      "    if status == 0:",
      "        work_total += 1",
      "    else:",
      "        work_total = -100",
      "    return",
      "",
      "def main() -> i32:",
      "    let loop_result = rt.create_loop()",
      "    if not loop_result.is_ok:",
      "        return 1",
      "    var loop = loop_result.value",
      "    var request = rt.create_work_request()",
      "",
      "    if rt.queue_work(loop, request, on_work, after_work) != 0:",
      "        rt.request_release(addr(request))",
      "        rt.loop_release(addr(loop))",
      "        return 2",
      "    if rt.loop_run_default(loop) != 0:",
      "        rt.request_release(addr(request))",
      "        rt.loop_release(addr(loop))",
      "        return 3",
      "",
      "    rt.request_release(addr(request))",
      "    if rt.loop_release(addr(loop)) != 0:",
      "        return 4",
      "    return work_total",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 11, result.exit_status
    assert_includes result.link_flags, "-luv"
  end

  def test_host_runtime_executes_libuv_tcp_helpers
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_libuv_tcp",
      "",
      "import std.libuv as uv",
      "import std.libuv.runtime as rt",
      "import std.mem.arena as arena",
      "",
      "var accepted: i32 = 0",
      "var connected: i32 = 0",
      "var server_handle: ptr[uv.uv_tcp_t]? = null",
      "var accepted_handle: ptr[uv.uv_tcp_t]? = null",
      "var client_handle: ptr[uv.uv_tcp_t]? = null",
      "",
      "def on_close(handle: ptr[uv.uv_handle_t]) -> void:",
      "    return",
      "",
      "def close_tcp(handle: ptr[uv.uv_tcp_t]?) -> void:",
      "    if handle == null:",
      "        return",
      "    unsafe:",
      "        let raw_handle = ptr[uv.uv_handle_t]<-handle",
      "        if uv.is_closing(const_ptr[uv.uv_handle_t]<-raw_handle) == 0:",
      "            uv.close(raw_handle, on_close)",
      "    return",
      "",
      "def on_connect(req: ptr[uv.uv_connect_t], status: i32) -> void:",
      "    if status == 0:",
      "        connected = 1",
      "        close_tcp(accepted_handle)",
      "        close_tcp(client_handle)",
      "        close_tcp(server_handle)",
      "    else:",
      "        connected = -10",
      "        close_tcp(accepted_handle)",
      "        close_tcp(client_handle)",
      "        close_tcp(server_handle)",
      "    return",
      "",
      "def on_connection(server: ptr[uv.uv_stream_t], status: i32) -> void:",
      "    if status != 0:",
      "        accepted = -10",
      "        close_tcp(accepted_handle)",
      "        close_tcp(server_handle)",
      "        close_tcp(client_handle)",
      "        return",
      "    let maybe_accepted = accepted_handle",
      "    if maybe_accepted == null:",
      "        accepted = -20",
      "        close_tcp(accepted_handle)",
      "        close_tcp(server_handle)",
      "        close_tcp(client_handle)",
      "        return",
      "    unsafe:",
      "        let accepted_client = ptr[uv.uv_tcp_t]<-maybe_accepted",
      "        if uv.accept(server, ptr[uv.uv_stream_t]<-accepted_client) != 0:",
      "            accepted = -30",
      "            close_tcp(accepted_handle)",
      "            close_tcp(client_handle)",
      "            close_tcp(server_handle)",
      "            return",
      "    accepted = 1",
      "    return",
      "",
      "def main() -> i32:",
      "    var scratch = arena.create(256)",
      "    defer scratch.release()",
      "",
      "    let loop_result = rt.create_loop()",
      "    if not loop_result.is_ok:",
      "        return 1",
      "    var loop = loop_result.value",
      "",
      "    let server_result = rt.create_tcp(loop)",
      "    if not server_result.is_ok:",
      "        rt.loop_release(addr(loop))",
      "        return 2",
      "    var server = server_result.value",
      "",
      "    let client_result = rt.create_tcp(loop)",
      "    if not client_result.is_ok:",
      "        rt.handle_release(addr(server))",
      "        rt.loop_release(addr(loop))",
      "        return 3",
      "    var client = client_result.value",
      "",
      "    let accepted_result = rt.create_tcp(loop)",
      "    if not accepted_result.is_ok:",
      "        rt.handle_release(addr(client))",
      "        rt.handle_release(addr(server))",
      "        rt.loop_release(addr(loop))",
      "        return 4",
      "    var accepted_client = accepted_result.value",
      "",
      "    unsafe:",
      "        server_handle = ptr[uv.uv_tcp_t]?<-rt.handle_ptr(server)",
      "        accepted_handle = ptr[uv.uv_tcp_t]?<-rt.handle_ptr(accepted_client)",
      "        client_handle = ptr[uv.uv_tcp_t]?<-rt.handle_ptr(client)",
      "",
      "    var connect_request = rt.create_connect_request()",
      "    if rt.tcp_bind_ipv4(server, \"127.0.0.1\", 0, 0, addr(scratch)) != 0:",
      "        rt.request_release(addr(connect_request))",
      "        rt.handle_release(addr(accepted_client))",
      "        rt.handle_release(addr(client))",
      "        rt.handle_release(addr(server))",
      "        rt.loop_release(addr(loop))",
      "        return 5",
      "",
      "    let port_result = rt.tcp_local_port(server)",
      "    if not port_result.is_ok:",
      "        rt.request_release(addr(connect_request))",
      "        rt.handle_release(addr(accepted_client))",
      "        rt.handle_release(addr(client))",
      "        rt.handle_release(addr(server))",
      "        rt.loop_release(addr(loop))",
      "        return 6",
      "",
      "    if rt.tcp_listen(server, 8, on_connection) != 0:",
      "        rt.request_release(addr(connect_request))",
      "        rt.handle_release(addr(accepted_client))",
      "        rt.handle_release(addr(client))",
      "        rt.handle_release(addr(server))",
      "        rt.loop_release(addr(loop))",
      "        return 7",
      "    if rt.tcp_connect_ipv4(connect_request, client, \"127.0.0.1\", port_result.value, on_connect, addr(scratch)) != 0:",
      "        rt.request_release(addr(connect_request))",
      "        rt.handle_release(addr(accepted_client))",
      "        rt.handle_release(addr(client))",
      "        rt.handle_release(addr(server))",
      "        rt.loop_release(addr(loop))",
      "        return 8",
      "    if rt.loop_run_default(loop) != 0:",
      "        rt.request_release(addr(connect_request))",
      "        rt.handle_release(addr(accepted_client))",
      "        rt.handle_release(addr(client))",
      "        rt.handle_release(addr(server))",
      "        rt.loop_release(addr(loop))",
      "        return 9",
      "",
      "    rt.request_release(addr(connect_request))",
      "    rt.handle_release(addr(accepted_client))",
      "    rt.handle_release(addr(client))",
      "    rt.handle_release(addr(server))",
      "    if rt.loop_release(addr(loop)) != 0:",
      "        return 10",
      "    return accepted * 10 + connected",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 11, result.exit_status
    assert_includes result.link_flags, "-luv"
  end

  def test_host_runtime_executes_libuv_fs_helpers
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-std-libuv-fs") do |dir|
      template = File.join(dir, "mt-libuv-XXXXXX")
      source = [
        "module demo.std_libuv_fs",
        "",
        "import std.libuv as uv",
        "import std.libuv.runtime as rt",
        "import std.mem.arena as arena",
        "import std.mem.heap as heap",
        "import std.string as string",
        "",
        "def on_fs(req: ptr[uv.uv_fs_t]) -> void:",
        "    return",
        "",
        "def main() -> i32:",
        "    var scratch = arena.create(512)",
        "    defer scratch.release()",
        "",
        "    let loop_result = rt.create_loop()",
        "    if not loop_result.is_ok:",
        "        return 1",
        "    var loop = loop_result.value",
        "",
        "    var temp_request = rt.create_fs_request()",
        "    var write_request = rt.create_fs_request()",
        "    var read_request = rt.create_fs_request()",
        "    var close_request = rt.create_fs_request()",
        "    var unlink_request = rt.create_fs_request()",
        "",
        "    if rt.fs_mkstemp(loop, temp_request, #{template.inspect}, on_fs, addr(scratch)) != 0:",
        "        return 2",
        "    if rt.loop_run_default(loop) != 0:",
        "        return 3",
        "    let file = i32<-rt.fs_result(temp_request)",
        "    if file < 0:",
        "        return 4",
        "    var temp_path = string.String.from_str(rt.fs_path(temp_request))",
        "    defer temp_path.release()",
        "    rt.fs_cleanup(temp_request)",
        "",
        "    let write_bytes = heap.must_alloc_zeroed_bytes(4, 1)",
        "    let read_bytes = heap.must_alloc_zeroed_bytes(4, 1)",
        "    defer heap.release_bytes(read_bytes)",
        "    defer heap.release_bytes(write_bytes)",
        "",
        "    unsafe:",
        "        let write_ptr = ptr[u8]<-write_bytes",
        "        deref(write_ptr + 0) = 77",
        "        deref(write_ptr + 1) = 84",
        "        deref(write_ptr + 2) = 45",
        "        deref(write_ptr + 3) = 76",
        "",
        "        let write_view = span[u8](data = write_ptr, len = 4)",
        "        if rt.fs_write(loop, write_request, file, write_view, 0, on_fs) != 0:",
        "            return 5",
        "        if rt.loop_run_default(loop) != 0:",
        "            return 6",
        "        if rt.fs_result(write_request) != isize<-4:",
        "            return 7",
        "        rt.fs_cleanup(write_request)",
        "",
        "        let read_ptr = ptr[u8]<-read_bytes",
        "        let read_view = span[u8](data = read_ptr, len = 4)",
        "        if rt.fs_read(loop, read_request, file, read_view, 0, on_fs) != 0:",
        "            return 8",
        "        if rt.loop_run_default(loop) != 0:",
        "            return 9",
        "        if rt.fs_result(read_request) != isize<-4:",
        "            return 10",
        "        rt.fs_cleanup(read_request)",
        "",
        "        if deref(read_ptr + 0) != 77 or deref(read_ptr + 1) != 84 or deref(read_ptr + 2) != 45 or deref(read_ptr + 3) != 76:",
        "            return 11",
        "",
        "    if rt.fs_close(loop, close_request, file, on_fs) != 0:",
        "        return 12",
        "    if rt.loop_run_default(loop) != 0:",
        "        return 13",
        "    if rt.fs_result(close_request) != isize<-0:",
        "        return 14",
        "    rt.fs_cleanup(close_request)",
        "",
        "    if rt.fs_unlink(loop, unlink_request, temp_path.as_str(), on_fs, addr(scratch)) != 0:",
        "        return 15",
        "    if rt.loop_run_default(loop) != 0:",
        "        return 16",
        "    if rt.fs_result(unlink_request) != isize<-0:",
        "        return 17",
        "    rt.fs_cleanup(unlink_request)",
        "",
        "    rt.request_release(addr(unlink_request))",
        "    rt.request_release(addr(close_request))",
        "    rt.request_release(addr(read_request))",
        "    rt.request_release(addr(write_request))",
        "    rt.request_release(addr(temp_request))",
        "    if rt.loop_release(addr(loop)) != 0:",
        "        return 18",
        "    return 4",
        "",
      ].join("\n")

      result = run_program(source, compiler:)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 4, result.exit_status
      assert_includes result.link_flags, "-luv"
      assert_empty Dir.glob(File.join(dir, "mt-libuv-*"))
    end
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-libuv-runtime") do |dir|
      source_path = File.join(dir, "program.mt")
      File.write(source_path, source)
      return MilkTea::Run.run(source_path, cc: compiler)
    end
  end

  def compiler_available?(compiler)
    return File.executable?(compiler) if compiler.include?(File::SEPARATOR)

    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |entry|
      candidate = File.join(entry, compiler)
      File.file?(candidate) && File.executable?(candidate)
    end
  end
end
