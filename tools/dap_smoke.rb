#!/usr/bin/env ruby
# frozen_string_literal: true
#
# DAP audit: drives `mtc dap` (host and self-host) through a session and reports
# what each answers, so the gap between them is measured rather than asserted.
#
#   ruby tools/dap_smoke.rb [--server host|self|both] [--json OUT] [--verbose]
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

class DapClient
  attr_reader :events, :stderr_lines

  def initialize(cmd, cwd)
    @stdin, @stdout, @stderr, @wait = Open3.popen3(*cmd, chdir: cwd)
    @stderr_thread = Thread.new { @stderr.read }
    @seq = 0
    @events = []
    @stderr_lines = []
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
      @events << [message["event"], message["body"]] if message["type"] == "event"
    end
  end

  def close
    @stdin.close rescue nil
    sleep 0.2
    Process.kill("KILL", @wait.pid) rescue nil
    @stderr_lines = @stderr_thread.value.to_s.lines
  end

  private

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

def server_command(server)
  if server == "self"
    [SELF_SERVER, "dap", "--backend=process"]
  else
    ["ruby", "-I#{File.join(ROOT, 'lib')}", File.join(ROOT, "bin", "mtc"), "dap", "--backend=process"]
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

options = { server: "both", json: nil, verbose: false }
OptionParser.new do |opts|
  opts.on("--server SERVER", %w[host self both]) { |v| options[:server] = v }
  opts.on("--json PATH") { |v| options[:json] = v }
  opts.on("--verbose") { options[:verbose] = true }
end.parse!

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
  servers.each do |server|
    results[server] = run_session(server, workdir, binary)
    run_launch_session(server, workdir, File.join("src", "main.mt"), "launch(.mt)", results[server])
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
