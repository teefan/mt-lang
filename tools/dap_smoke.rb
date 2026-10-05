#!/usr/bin/env ruby
# frozen_string_literal: true
#
# DAP audit: drives `mtc dap` (host and self-host) through a session and reports
# what each answers, so the gap between them is measured rather than asserted.
#
#   ruby tools/dap_smoke.rb [--server host|self|both] [--json OUT] [--verbose]
#                           [--self-bin PATH]
#
# `--self-bin` points the `self` server at an iteration build (e.g.
# `tmp/mtc-dev`); the default is the gated `build/stage2/mtc`.
#
# The self-host adapter has one backend (`process`); the host also has the
# `lldb-dap` bridge, which is where stepping, evaluate, setVariable, attach,
# breakpoint verification, real variables and pause diagnostics come from.  Run
# both to see the difference.
#
# Each run: initialize, launch a program, wait for its output and terminated
# event, then probe the debugging surface (threads, stackTrace, scopes,
# variables, next/stepIn/stepOut, evaluate, setVariable, attach, restart,
# dataBreakpointInfo, cancel, loadedSources, disconnect).

require "json"
require "timeout"
require "open3"
require "fileutils"
require "tmpdir"
require "optparse"

ROOT = File.expand_path("..", __dir__)
SELF_SERVER = File.join(ROOT, "build", "stage2", "mtc")
$self_bin = SELF_SERVER

PROGRAM = <<~MT
  import std.stdio as io

  function add(a: int, b: int) -> int:
      let total = a + b
      return total

  function main() -> int:
      let value = add(2, 3)
      io.print_format("value=%d\\n", value)
      return 0
MT

FAKE_LLDB_ADAPTER = <<~'RUBY'
  # frozen_string_literal: true
  require "json"

  seq = 1
  read_message = lambda do
    headers = {}
    loop do
      line = STDIN.gets
      break nil if line.nil?

      stripped = line.chomp.sub(/\r\z/, "")
      break :headers_done if stripped.empty?

      key, value = stripped.split(":", 2)
      headers[key.strip] = value.strip
    end
    next nil if headers.empty?

    length = headers["Content-Length"]&.to_i
    next nil if length.nil? || length <= 0

    JSON.parse(STDIN.read(length))
  end
  write_message = lambda do |message|
    json = JSON.dump(message)
    STDOUT.write("Content-Length: #{json.bytesize}\r\n\r\n#{json}")
    STDOUT.flush
  end
  write_response = lambda do |request, body = {}, success = true, error_message = nil|
    response = { seq: seq, type: "response", request_seq: request["seq"], command: request["command"], success: success }
    response[:body] = body if success
    response[:message] = error_message if !success && error_message
    write_message.call(response)
    seq += 1
  end
  write_event = lambda do |event, body = nil|
    payload = { seq: seq, type: "event", event: event }
    payload[:body] = body if body
    write_message.call(payload)
    seq += 1
  end

  loop do
    request = read_message.call
    break if request.nil?
    next unless request["type"] == "request"

    args = request["arguments"] || {}
    case request["command"]
    when "initialize"
      write_response.call(request, { supportsConfigurationDoneRequest: true })
    when "launch", "attach"
      write_response.call(request, {})
    when "setBreakpoints"
      requested = args["breakpoints"] || []
      breakpoints = requested.map.with_index { |bp, idx| { id: 100 + idx, verified: true, line: bp["line"].to_i } }
      write_response.call(request, { breakpoints: breakpoints })
    when "configurationDone"
      # Exercise the reverse direction: ask the client for a terminal, wait for
      # its response, then finish configuration (the host's fake test pattern).
      reverse = {
        seq: seq, type: "request", command: "runInTerminal",
        arguments: { kind: "integrated", title: "Milk Tea Debuggee", cwd: "/tmp", args: ["/usr/bin/true"] }
      }
      write_message.call(reverse)
      seq += 1
      loop do
        message = read_message.call
        break if message.nil?
        break if message["type"] == "response" && message["request_seq"] == reverse[:seq]
      end
      write_response.call(request, {})
      write_event.call("stopped", { reason: "entry", threadId: 99, allThreadsStopped: true })
    when "threads"
      write_response.call(request, { threads: [{ id: 99, name: "lldb-main" }] })
    when "stackTrace"
      write_response.call(request, {
        stackFrames: [{ id: 1, name: "lldb_main", line: 1, column: 1, source: { name: "demo", path: "/tmp/demo.mt" } }],
        totalFrames: 1
      })
    when "scopes"
      write_response.call(request, { scopes: [{ name: "Locals", variablesReference: 11, expensive: false }] })
    when "variables"
      write_response.call(request, { variables: [{ name: "a", value: "1", type: "int", variablesReference: 0 }] })
    when "setExceptionBreakpoints"
      write_response.call(request, {})
    when "evaluate"
      write_response.call(request, { result: "not_impl", variablesReference: 0 })
    when "source"
      write_response.call(request, { content: "# not available" })
    when "loadedSources"
      write_response.call(request, { sources: [] })
    when "continue"
      write_response.call(request, { allThreadsContinued: true })
      write_event.call("continued", { threadId: 99, allThreadsContinued: true })
    when "next", "stepIn", "stepOut"
      write_response.call(request, {})
      write_event.call("stopped", { reason: "step", threadId: 99, allThreadsStopped: true })
    when "pause"
      write_response.call(request, {})
      write_event.call("stopped", { reason: "pause", threadId: 99, allThreadsStopped: true })
    when "disconnect"
      write_response.call(request, {})
      write_event.call("terminated")
      write_event.call("exited", { exitCode: 0 })
      break
    else
      write_response.call(request, {}, false, "unsupported command")
    end
  end
RUBY

class DapClient
  attr_reader :events, :stderr_lines, :reverse_requests

  def initialize(cmd, cwd)
    @stdin, @stdout, @stderr, @wait = Open3.popen3(*cmd, chdir: cwd)
    @stderr_thread = Thread.new { @stderr.read }
    @seq = 0
    @events = []
    @stderr_lines = []
    @reverse_requests = 0
  end

  def request(command, arguments = {}, timeout: 20)
    @seq += 1
    seq = @seq
    write({ "seq" => seq, "type" => "request", "command" => command, "arguments" => arguments })
    read_until_response(seq, timeout)
  end

  def notify(command, arguments = {})
    @seq += 1
    write({ "seq" => @seq, "type" => "request", "command" => command, "arguments" => arguments })
  end

  ## Read messages until the response to `seq` arrives, collecting events.
  def read_until_response(seq, timeout)
    Timeout.timeout(timeout) do
      loop do
        message = read_message
        return { "kind" => "closed" } if message.nil?
        case message["type"]
        when "event"
          @events << [message["event"], message["body"]]
        when "request"
          answer_server_request(message)
        when "response"
          return message if message["request_seq"] == seq
        end
      end
    end
  rescue Timeout::Error
    { "kind" => "timeout" }
  end

  ## Drain events for `seconds` (for program output / terminated, which arrive
  ## while no request is outstanding).
  def drain(seconds)
    deadline = Time.now + seconds
    loop do
      remaining = deadline - Time.now
      break if remaining <= 0
      message = read_message(remaining)
      break if message.nil?
      if message["type"] == "request"
        answer_server_request(message)
      elsif message["type"] == "event"
        @events << [message["event"], message["body"]]
      end
    end
  end

  ## Wait for a `stopped` event with the given reason, collecting everything
  ## else (used with real lldb-dap, where stops arrive unsolicited).
  def wait_for_stopped_reason(reason, timeout: 20)
    Timeout.timeout(timeout) do
      loop do
        message = read_message
        return nil if message.nil?
        if message["type"] == "request"
          answer_server_request(message)
        elsif message["type"] == "event"
          @events << [message["event"], message["body"]]
          next unless message["event"] == "stopped"
          return message if message.dig("body", "reason") == reason
        end
      end
    end
  rescue Timeout::Error
    nil
  end

  ## Wait for a named event, collecting everything else.
  def wait_for_event(event_name, timeout: 20)
    Timeout.timeout(timeout) do
      loop do
        message = read_message
        return nil if message.nil?
        if message["type"] == "request"
          answer_server_request(message)
        elsif message["type"] == "event"
          @events << [message["event"], message["body"]]
          return message if message["event"] == event_name
        end
      end
    end
  rescue Timeout::Error
    nil
  end

  def close
    @stdin.close rescue nil
    sleep 0.2
    Process.kill("KILL", @wait.pid) rescue nil
    @stderr_lines = @stderr_thread.value.to_s.lines
  end

  private

  ## Answer a server->client request the way a real client does.
  def answer_server_request(message)
    @reverse_requests += 1
    body = {}
    if message["command"] == "runInTerminal"
      args = message.dig("arguments", "args") || []
      cwd = message.dig("arguments", "cwd")
      begin
        pid = Process.spawn(*args, chdir: (cwd && !cwd.empty? ? cwd : nil), out: File::NULL, err: File::NULL)
        body = { "processId" => pid, "shellProcessId" => pid }
      rescue StandardError
        body = { "processId" => 0 }
      end
    end
    @seq += 1
    write({
      "seq" => @seq,
      "type" => "response",
      "request_seq" => message["seq"],
      "command" => message["command"],
      "success" => true,
      "body" => body,
    })
  end

  def write(message)
    payload = JSON.dump(message)
    @stdin.write("Content-Length: #{payload.bytesize}\r\n\r\n#{payload}")
    @stdin.flush
  end

  def read_message(timeout = 20)
    Timeout.timeout(timeout) do
      length = nil
      while (line = @stdout.gets)
        break if line.strip.empty?
        length = line.split(":").last.strip.to_i if line.start_with?("Content-Length")
      end
      return nil unless length
      JSON.parse(@stdout.read(length))
    end
  rescue Timeout::Error
    nil
  end
end

## Summarize a response for the report: ok + a one-line gist of the body.
def summarize(response)
  return "closed" if response.nil?
  return response["kind"] if response["kind"]

  if response["success"] == false
    return "error: #{(response['message'] || '').to_s[0, 60]}"
  end

  body = response["body"] || {}
  case body
  when Hash
    keys = body.keys
    if body["allThreadsContinued"] || body["threads"] || body["stackFrames"] || body["scopes"] || body["variables"] || body["breakpoints"]
      counts = %w[threads stackFrames scopes variables breakpoints].filter_map do |k|
        "#{k}=#{body[k].size}" if body[k].is_a?(Array)
      end
      return "ok #{counts.join(' ')}"
    end
    return "ok #{keys.first(4).join(',')}"
  else
    return "ok"
  end
end

def server_command(server, backend: "process", adapter_path: nil)
  args = ["dap", "--backend=#{backend}"]
  args << "--adapter-path=#{adapter_path}" if adapter_path
  if server == "self"
    [$self_bin, *args]
  else
    ["ruby", "-I#{File.join(ROOT, 'lib')}", File.join(ROOT, "bin", "mtc"), *args]
  end
end

## One lldb-dap session against the fake adapter: the whole bridge surface the
## real adapter will exercise, without a debuggee.
def run_fake_backend_session(server, workdir, program_binary, adapter_path, into)
  client = DapClient.new(server_command(server, backend: "lldb-dap", adapter_path: adapter_path), workdir)
  begin
    r = client.request("initialize", { "adapterID" => "milk-tea", "clientID" => "dap_smoke" })
    into["lldb initialize"] = summarize(r)
    into["lldb capabilities"] = (r.dig("body") || {}).keys.sort.join(",")
    into["lldb launch"] = summarize(client.request("launch", { "program" => program_binary, "backend" => "lldb-dap", "stopOnEntry" => false }))
    into["lldb setBreakpoints"] = summarize(client.request("setBreakpoints", { "source" => { "path" => "src/main.mt" }, "breakpoints" => [{ "line" => 4 }] }))
    into["lldb configurationDone"] = summarize(client.request("configurationDone", {}))
    client.drain(0.4)
    into["lldb stopped events"] = client.events.count { |e, _| e == "stopped" }
    into["lldb capabilities events"] = client.events.count { |e, _| e == "capabilities" }
    into["lldb threads"] = summarize(client.request("threads", {}))
    into["lldb stackTrace"] = summarize(client.request("stackTrace", { "threadId" => 99 }))
    into["lldb scopes"] = summarize(client.request("scopes", { "frameId" => 1 }))
    into["lldb variables"] = summarize(client.request("variables", { "variablesReference" => 11 }))
    into["lldb evaluate"] = summarize(client.request("evaluate", { "expression" => "a", "frameId" => 1 }))
    into["lldb next"] = summarize(client.request("next", { "threadId" => 99 }))
    into["lldb stepIn"] = summarize(client.request("stepIn", { "threadId" => 99 }))
    into["lldb stepOut"] = summarize(client.request("stepOut", { "threadId" => 99 }))
    into["lldb pause"] = summarize(client.request("pause", { "threadId" => 99 }))
    into["lldb continue"] = summarize(client.request("continue", { "threadId" => 99 }))
    client.drain(0.3)
    into["lldb events"] = client.events.map { |e, _| e }.tally.map { |k, v| "#{k}x#{v}" }.join(" ")
    into["lldb reverse requests"] = client.reverse_requests
    into["lldb disconnect"] = summarize(client.request("disconnect", {}))
  rescue StandardError => e
    into["lldb exception"] = "exception: #{e.message[0, 80]}"
  ensure
    client.close
    into["lldb stderr"] = client.stderr_lines.first(3).map(&:strip)
  end
end

## One session, one launch: a second launch in the same session is an adapter
## error on both sides and would mask everything after it.
def run_launch_session(server, workdir, program, label, into)
  client = DapClient.new(server_command(server), workdir)
  begin
    client.request("initialize", { "adapterID" => "milk-tea", "clientID" => "dap_smoke" })
    response = client.request("launch", { "program" => program, "stopOnEntry" => false })
    into[label] = summarize(response)
    if response["success"]
      # Idle window: no request outstanding, so a server that only polls while
      # dispatching leaves the program's output unread here.
      client.drain(2.0)
      events_while_idle = client.events.count { |e, _| e == "output" }
      client.request("configurationDone", {})
      client.drain(2.5)
      into["#{label} output while idle"] = events_while_idle
      into["#{label} output events"] = client.events.count { |e, _| e == "output" }
      into["#{label} terminated"] = client.events.any? { |e, _| e == "terminated" }
    end
  rescue StandardError => e
    into[label] = "exception: #{e.message[0, 50]}"
  ensure
    client.close
  end
end

def run_session(server, workdir, program_binary)
  client = DapClient.new(server_command(server), workdir)
  out = {}
  begin
    r = client.request("initialize", { "adapterID" => "milk-tea", "clientID" => "dap_smoke" })
    out["initialize"] = summarize(r)
    out["capabilities"] = (r.dig("body") || {}).keys.sort.join(",")

    # Launch the prebuilt binary (the .mt path is measured in its own session).
    out["launch(binary)"] = summarize(client.request("launch", { "program" => program_binary, "stopOnEntry" => false }))
    # Idle window before configurationDone: the self-host process backend starts
    # the program on launch, the host's starts it on configurationDone, so this
    # is where the two differ.
    client.drain(2.0)
    out["output before configurationDone"] = client.events.count { |e, _| e == "output" }
    client.request("configurationDone", {})
    client.drain(2.0)
    out["output events"] = client.events.count { |e, _| e == "output" }
    out["terminated"] = client.events.any? { |e, _| e == "terminated" }
    out["events"] = client.events.map { |e, _| e }.tally.map { |k, v| "#{k}x#{v}" }.join(" ")

    # 3. the debugging surface.
    out["threads"] = summarize(client.request("threads", {}))
    out["stackTrace"] = summarize(client.request("stackTrace", { "threadId" => 1 }))
    out["scopes"] = summarize(client.request("scopes", { "frameId" => 1 }))
    out["variables"] = summarize(client.request("variables", { "variablesReference" => 1 }))
    out["next"] = summarize(client.request("next", { "threadId" => 1 }))
    out["stepIn"] = summarize(client.request("stepIn", { "threadId" => 1 }))
    out["stepOut"] = summarize(client.request("stepOut", { "threadId" => 1 }))
    out["evaluate"] = summarize(client.request("evaluate", { "expression" => "value", "frameId" => 1 }))
    out["setVariable"] = summarize(client.request("setVariable", { "variablesReference" => 1, "name" => "a", "value" => "7" }))
    out["attach"] = summarize(client.request("attach", { "program" => program_binary }))
    out["restart"] = summarize(client.request("restart", {}))
    out["dataBreakpointInfo"] = summarize(client.request("dataBreakpointInfo", { "name" => "a" }))
    out["cancel"] = summarize(client.request("cancel", { "requestId" => 1 }))
    out["loadedSources"] = summarize(client.request("loadedSources", {}))
    out["setBreakpoints"] = summarize(client.request("setBreakpoints", { "source" => { "path" => "src/main.mt" }, "breakpoints" => [{ "line" => 9 }] }))
    out["disconnect"] = summarize(client.request("disconnect", {}))
  rescue StandardError => e
    out["exception"] = e.message
  ensure
    client.close
    out["stderr"] = client.stderr_lines.first(3).map(&:strip)
  end
  out
end

## Real lldb-dap end-to-end: each server builds the `.mt` source itself (so
## its own debug map is in play) and drives a breakpoint session.  Skipped with
## a loud row when lldb-dap is not on PATH.
def run_real_lldb_session(server, workdir, source, into)
  adapter = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |d| File.join(d, "lldb-dap") }
               .find { |p| File.executable?(p) }
  unless adapter
    into["lldb-real skipped"] = "lldb-dap not found on PATH"
    return
  end

  client = DapClient.new(server_command(server, backend: "lldb-dap"), workdir)
  begin
    r = client.request("initialize", { "adapterID" => "milk-tea", "clientID" => "dap_smoke" })
    into["lldb-real initialize"] = summarize(r)
    into["lldb-real launch(.mt)"] = summarize(client.request("launch", { "program" => source, "backend" => "lldb-dap", "stopOnEntry" => false }))
    into["lldb-real setBreakpoints"] = summarize(client.request("setBreakpoints", { "source" => { "path" => source }, "breakpoints" => [{ "line" => 4 }] }))
    into["lldb-real configurationDone"] = summarize(client.request("configurationDone", {}))
    stop = client.wait_for_stopped_reason("breakpoint", timeout: 25)
    into["lldb-real breakpoint stop"] = stop ? "breakpoint" : "none"
    thread_id = stop&.dig("body", "threadId") || 1
    stack = client.request("stackTrace", { "threadId" => thread_id })
    frame = (stack.dig("body", "stackFrames") || []).first || {}
    into["lldb-real frame0 name"] = frame["name"]
    into["lldb-real frame0 source"] = File.basename(frame.dig("source", "path").to_s)
    frame_id = frame["id"] || 1
    scopes = client.request("scopes", { "frameId" => frame_id })
    locals_ref = (scopes.dig("body", "scopes") || []).first&.dig("variablesReference")
    variables = locals_ref ? client.request("variables", { "variablesReference" => locals_ref }) : nil
    names = Array(variables&.dig("body", "variables")).map { |v| v["name"] }.sort.join(",")
    into["lldb-real variable names"] = names
    into["lldb-real evaluate"] = summarize(client.request("evaluate", { "expression" => "a", "frameId" => frame_id }))
    into["lldb-real next"] = summarize(client.request("next", { "threadId" => thread_id }))
    client.wait_for_stopped_reason("step", timeout: 10)
    into["lldb-real continue"] = summarize(client.request("continue", { "threadId" => thread_id }))
    client.wait_for_event("terminated", timeout: 15)
    client.drain(0.5)
    into["lldb-real terminated"] = client.events.any? { |e, _| e == "terminated" }
    into["lldb-real exited"] = client.events.any? { |e, _| e == "exited" }
    into["lldb-real disconnect"] = summarize(client.request("disconnect", {}))
  rescue StandardError => e
    into["lldb-real exception"] = "exception: #{e.message[0, 80]}"
  ensure
    client.close
    into["lldb-real stderr"] = client.stderr_lines.first(3).map(&:strip).reject(&:empty?)
  end
end

options = { server: "both", json: nil, verbose: false, self_bin: SELF_SERVER }
OptionParser.new do |opts|
  opts.on("--server SERVER", %w[host self both]) { |v| options[:server] = v }
  opts.on("--json PATH") { |v| options[:json] = v }
  opts.on("--verbose") { options[:verbose] = true }
  opts.on("--self-bin PATH", "Self server binary (default build/stage2/mtc)") { |v| options[:self_bin] = v }
end.parse!
$self_bin = options[:self_bin]

results = {}
Dir.mktmpdir("dap-smoke") do |dir|
  workdir = File.join(dir, "proj")
  FileUtils.mkdir_p(File.join(workdir, "src"))
  File.write(File.join(workdir, "src", "main.mt"), PROGRAM)
  binary = File.join(dir, "main")
  build = system(File.join(ROOT, "bin", "mtc"), "build", File.join(workdir, "src", "main.mt"),
                 "-o", binary, chdir: workdir, out: File::NULL, err: File::NULL)
  abort "could not build the smoke program" unless build

  servers = options[:server] == "both" ? %w[host self] : [options[:server]]
  fake_path = File.join(dir, "fake_lldb_dap.rb")
  File.write(fake_path, FAKE_LLDB_ADAPTER)
  servers.each do |server|
    results[server] = run_session(server, workdir, binary)
    run_launch_session(server, workdir, File.join("src", "main.mt"), "launch(.mt)", results[server])
    run_fake_backend_session(server, workdir, binary, fake_path, results[server])
    run_real_lldb_session(server, workdir, File.join(workdir, "src", "main.mt"), results[server])
  end
end

keys = results.values.flat_map(&:keys).uniq
width = keys.map(&:length).max
puts format("%-#{width}s  %-34s  %s", "request", "host", "self")
keys.each do |key|
  next if key == "stderr"
  host = results.dig("host", key) || "-"
  self_ = results.dig("self", key) || "-"
  flag = host == self_ ? " " : "*"
  puts format("%s%-#{width}s  %-34s  %s", flag, key, host.to_s[0, 34], self_.to_s[0, 60])
end
puts
servers_error = results.values.any? { |r| (r["stderr"] || []).any? { |l| l =~ /error|malformed/i } }
puts "stderr: #{results.transform_values { |r| (r['stderr'] || []).size }.inspect}#{servers_error ? ' (check lines)' : ''}"
results.each do |server, out|
  next unless options[:verbose]
  puts "== #{server} stderr =="
  (out["stderr"] || []).each { |line| puts "  #{line}" }
end
File.write(options[:json], JSON.pretty_generate(results)) if options[:json]
