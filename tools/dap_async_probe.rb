#!/usr/bin/env ruby
# frozen_string_literal: true

# dap_async_probe — drive the real lldb-dap bridge with VS Code's launch
# ordering: send `launch`, then `configurationDone` without waiting for the
# launch response (VS Code does this as soon as the adapter's `initialized`
# event arrives).  lldb-dap answers `launch` only after the target starts, so a
# bridge that gates `configurationDone` on that response deadlocks until the
# adapter deadline and the client tears the session down.
#
# Usage:
#   ruby tools/dap_async_probe.rb [--bin PATH] [-q]
#
# `--bin` defaults to build/stage2/mtc.  The probe builds a small program
# through the DAP server's build-on-launch, sets a breakpoint on the print
# line, and asserts: launch success, entry stop, breakpoint stop, frame name
# `main`, local `x=3`, and evaluate `x` -> `3`.
#
# Exit status: 0 on success, 1 otherwise.  Requires a real lldb-dap on PATH.

require "json"
require "open3"
require "optparse"
require "timeout"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)

options = { bin: File.join(ROOT, "build/stage2/mtc"), quiet: false }
OptionParser.new do |opts|
  opts.on("--bin PATH", "Milk Tea compiler (default build/stage2/mtc)") { |v| options[:bin] = File.expand_path(v, ROOT) }
  opts.on("-q", "--quiet", "print only failures and the summary") { options[:quiet] = true }
  opts.on("-h", "--help") { puts opts; exit 0 }
end.parse!

abort "compiler not found: #{options[:bin]}" unless File.executable?(options[:bin])

PROGRAM = <<~MT
  import std.stdio as stdio

  function add(a: int, b: int) -> int:
      let total = a + b
      return total

  function main() -> int:
      let x = add(1, 2)
      stdio.print_line(f"{x}")
      return 0
MT

## A synchronous DAP client with one unblocked send: `write` does not wait for
## its response, and `read_until` routes responses/events by command.
class Client
  attr_reader :stderr_lines

  def initialize(command, chdir)
    @stdin, @stdout, stderr, @wait = Open3.popen3(*command, chdir: chdir)
    @stderr_lines = []
    Thread.new { stderr.each_line { |line| @stderr_lines << line } }
    @seq = 0
    @buffer = +""
    @events = []
  end

  def write(command, arguments = {})
    @seq += 1
    message = { "seq" => @seq, "type" => "request", "command" => command, "arguments" => arguments }
    body = JSON.dump(message)
    @stdin.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
    @stdin.flush
    @seq
  end

  ## Return the first response with `command` (answering reverse requests),
  ## or nil on timeout/EOF.
  def read_response(command, timeout_s: 10)
    deadline = Time.now + timeout_s
    while Time.now < deadline
      message = read_message([deadline - Time.now, 0.1].max)
      next if message.nil?
      return message if message["type"] == "response" && message["command"] == command

      @events << message if message["type"] == "event"
      answer_reverse(message) if message["type"] == "request"
    end
    nil
  end

  ## Return the first event named `name`, or nil on timeout/EOF.
  def read_event(name, timeout_s: 20)
    index = @events.index { |message| message["event"] == name }
    return @events.delete_at(index) if index

    deadline = Time.now + timeout_s
    while Time.now < deadline
      message = read_message([deadline - Time.now, 0.1].max)
      next if message.nil?
      return message if message["type"] == "event" && message["event"] == name

      @events << message if message["type"] == "event"
      answer_reverse(message) if message["type"] == "request"
    end
    nil
  end

  def close
    @stdin.close rescue nil
    Timeout.timeout(5) { @wait.join }
  rescue Timeout::Error, StandardError
    Process.kill("KILL", @wait.pid) rescue nil
  end

  private

  def answer_reverse(message)
    body = {}
    body = { "processId" => 0, "shellProcessId" => 0 } if message["command"] == "runInTerminal"
    @seq += 1
    reply = { "seq" => @seq, "type" => "response", "request_seq" => message["seq"],
              "command" => message["command"], "success" => true, "body" => body }
    payload = JSON.dump(reply)
    @stdin.write("Content-Length: #{payload.bytesize}\r\n\r\n#{payload}")
    @stdin.flush
  end

  def read_message(timeout_s)
    Timeout.timeout(timeout_s) do
      loop do
        if (idx = @buffer.index("\r\n\r\n"))
          length = @buffer[/Content-Length:\s*(\d+)/i, 1].to_i
          if @buffer.bytesize >= idx + 4 + length
            json = @buffer[(idx + 4), length]
            @buffer = @buffer[(idx + 4 + length)..] || +""
            return JSON.parse(json)
          end
        end
        @buffer << @stdout.readpartial(65536)
      end
    end
  rescue EOFError, Timeout::Error
    nil
  end
end

def field(hash, *keys)
  keys.reduce(hash) { |value, key| value.is_a?(Hash) ? value[key] : nil }
end

failures = []
check = lambda do |name, actual, expected|
  ok = actual == expected
  failures << "#{name}: expected #{expected.inspect}, got #{actual.inspect}" unless ok
  puts "#{ok ? 'ok  ' : 'FAIL'} #{name}: #{actual.inspect}" unless options[:quiet] && ok
end

Dir.mktmpdir("dap-async-probe-") do |dir|
  program = File.join(dir, "main.mt")
  File.write(program, PROGRAM)
  breakpoint_line = PROGRAM.lines.index { |line| line.include?("print_line") } + 1

  client = Client.new([options[:bin], "dap", "--backend=lldb-dap"], dir)
  begin
    client.write("initialize", { "adapterID" => "milk-tea", "clientID" => "dap_async_probe" })
    init = client.read_response("initialize")
    check.call("initialize", field(init, "success"), true)

    client.write("launch", { "type" => "milk-tea", "request" => "launch", "name" => "probe",
                             "program" => program, "backend" => "lldb-dap", "stopOnEntry" => true, "cwd" => dir })
    client.write("setBreakpoints", { "source" => { "path" => program }, "breakpoints" => [{ "line" => breakpoint_line }] })
    client.write("configurationDone", {})

    discr = client.read_response("launch", timeout_s: 20)
    check.call("launch success", field(discr, "success"), true)
    entry = client.read_event("stopped", timeout_s: 20)
    check.call("entry stop", field(entry, "body", "reason"), "entry")
    thread_id = field(entry, "body", "threadId")

    client.write("continue", { "threadId" => thread_id })
    stopped = client.read_event("stopped", timeout_s: 20)
    check.call("breakpoint stop", field(stopped, "body", "reason"), "breakpoint")

    client.write("stackTrace", { "threadId" => field(stopped, "body", "threadId") })
    stack = client.read_response("stackTrace")
    frame = field(stack, "body", "stackFrames")&.first
    check.call("frame name", field(frame, "name"), "main")
    check.call("frame line", field(frame, "line"), breakpoint_line)

    client.write("scopes", { "frameId" => field(frame, "id") })
    scopes = client.read_response("scopes")
    scope_ref = field(scopes, "body", "scopes")&.first&.fetch("variablesReference", nil)

    client.write("variables", { "variablesReference" => scope_ref })
    variables = client.read_response("variables")
    x = field(variables, "body", "variables")&.find { |v| v["name"] == "x" }
    check.call("local x", field(x, "value"), "3")

    client.write("evaluate", { "expression" => "x", "frameId" => field(frame, "id") })
    evaluated = client.read_response("evaluate")
    check.call("evaluate x", field(evaluated, "body", "result"), "3")

    client.write("disconnect", {})
    client.read_response("disconnect", timeout_s: 5)
  ensure
    client.close
  end

  puts "dap async probe: #{failures.empty? ? 'ok' : 'FAILED'}"
  failures.each { |failure| puts "  #{failure}" }
  exit(failures.empty? ? 0 : 1)
end
