#!/usr/bin/env ruby
# frozen_string_literal: true

# lsp_cold_start — measure how long a Milk Tea LSP server takes to become able
# to answer a workspace-wide query, for a real project directory.
#
# The instrument drives the minimum a real client sends before its first query:
# `initialize`, `initialized`, one `didOpen` per `.mt` file under the workspace
# (the audit's file set), then a `workspace/symbol` query — the request that
# forces a workspace index build.  It reports the wall time from process spawn
# to each response and the number of symbols returned, so a change to the index
# scope shows up as a smaller file set and a shorter spawn→symbol time.
#
# Usage:
#   ruby tools/lsp_cold_start.rb --workspace DIR [--server host|self|BIN]
#                                [--repeat N] [--json OUT]
#
# The host indexes in a background thread at `initialized`; the self-host builds
# its index on the first index-needing request.  Both are measured the same way:
# spawn → the first `workspace/symbol` response.

require "cgi/escape"
require "json"
require "timeout"

ROOT = File.expand_path("..", __dir__)

def path_to_uri(path)
  "file://#{path.split("/").map { |seg| CGI.escape(seg).gsub("+", "%20") }.join("/")}"
end

class Client
  def initialize(stdin, stdout, stderr_read, timeout_s = 120)
    @stdin = stdin
    @stdout = stdout
    @timeout_s = timeout_s
    @next_id = 0
    Thread.new { stderr_read.each_line { |line| } } if stderr_read
  end

  def write(message)
    body = JSON.dump(message)
    @stdin.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
    @stdin.flush
  rescue Errno::EPIPE, IOError
    nil
  end

  def request(method, params)
    @next_id += 1
    id = @next_id
    write({ "jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params })
    read_until(id)
  end

  def notify(method, params)
    write({ "jsonrpc" => "2.0", "method" => method, "params" => params })
  end

  def read_until(id)
    Timeout.timeout(@timeout_s) do
      loop do
        message = read_message
        return nil if message.nil?

        if message["method"]
          answer_server_request(message)
          next
        end
        return message if message["id"] == id
      end
    end
  rescue Timeout::Error
    nil
  end

  ## The host asks for `workspace/configuration` when the client advertises it
  ## and creates progress tokens; answer everything so it never blocks.  The
  ## configuration params are an array of `{section: ...}` items.
  def answer_server_request(message)
    return unless message["id"]

    result =
      case message["method"]
      when "workspace/configuration"
        params = message["params"]
        items = params.is_a?(Array) ? params : (params.is_a?(Hash) ? params["items"] : nil)
        Array.new(items.is_a?(Array) ? items.size : 0) { nil }
      else
        nil
      end
    write({ "jsonrpc" => "2.0", "id" => message["id"], "result" => result })
  end

  def read_message
    headers = {}
    loop do
      line = @stdout.gets
      return nil if line.nil?

      stripped = line.chomp.sub(/\r\z/, "")
      break if stripped.empty?

      key, value = stripped.split(":", 2)
      headers[key.strip] = value.strip
    end
    length = headers["Content-Length"]&.to_i
    return nil if length.nil? || length <= 0

    JSON.parse(@stdout.read(length))
  end
end

def spawn_server(kind, self_bin)
  stdin_read, stdin_write = IO.pipe
  stdout_read, stdout_write = IO.pipe
  stderr_read, stderr_write = IO.pipe

  cmd = case kind
        when "host"
          [RbConfig.ruby, "-I", File.join(ROOT, "lib"), "-e",
           "require 'milk_tea'; MilkTea::LSP::Server.new.run"]
        when "self"
          [self_bin, "lsp"]
        else
          [kind, "lsp"]
        end
  pid = spawn(*cmd, chdir: ROOT, in: stdin_read, out: stdout_write, err: stderr_write, pgroup: true)
  [stdin_read, stdout_write, stderr_write].each(&:close)
  [pid, stdin_write, stdout_read, stderr_read]
end

workspace = nil
server_kind = "self"
self_bin = File.join(ROOT, "build", "stage2", "mtc")
repeat = 1
json_out = nil
timeout_s = 600

while (arg = ARGV.shift)
  case arg
  when "--workspace" then workspace = ARGV.shift
  when "--server" then server_kind = ARGV.shift
  when "--self" then self_bin = ARGV.shift
  when "--repeat" then repeat = ARGV.shift.to_i
  when "--json" then json_out = ARGV.shift
  when "--timeout" then timeout_s = ARGV.shift.to_i
  else abort "unknown option #{arg}"
  end
end
abort "usage: lsp_cold_start.rb --workspace DIR [--server host|self|BIN]" unless workspace

workspace = File.expand_path(workspace)
files = Dir.glob(File.join(workspace, "**", "*.mt")).sort
root_uri = path_to_uri(workspace)

def monotonic
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

runs = []
repeat.times do
  start = monotonic
  pid, stdin, stdout, stderr_read = spawn_server(server_kind, self_bin)
  client = Client.new(stdin, stdout, stderr_read, timeout_s)

  client.request("initialize", { "processId" => Process.pid, "rootUri" => root_uri, "capabilities" => {} })
  initialize_ms = ((monotonic - start) * 1000).round(1)
  client.notify("initialized", {})

  files.each do |path|
    client.notify("textDocument/didOpen", {
                    "textDocument" => { "uri" => path_to_uri(path), "languageId" => "milk-tea", "version" => 1, "text" => File.read(path) },
                  })
  end

  symbol_start = monotonic
  response = client.request("workspace/symbol", { "query" => "" })
  symbol_ms = ((monotonic - symbol_start) * 1000).round(1)
  total_ms = ((monotonic - start) * 1000).round(1)
  symbols = response&.dig("result")&.length || 0

  runs << {
    "initialize_ms" => initialize_ms,
    "workspace_symbol_ms" => symbol_ms,
    "spawn_to_symbol_ms" => total_ms,
    "symbols" => symbols,
  }

  begin
    stdin.close
    Process.kill("TERM", -Process.getpgid(pid))
  rescue StandardError
    nil
  end
  begin
    Process.waitpid(pid)
  rescue StandardError
    nil
  end
end

puts "workspace: #{workspace}"
puts "files: #{files.size}, server: #{server_kind == "self" ? self_bin : server_kind}"
runs.each_with_index do |run, index|
  printf("run %d: initialize %8.1f ms, workspace/symbol %9.1f ms (spawn→response %9.1f ms), %d symbols\n",
         index + 1, run["initialize_ms"], run["workspace_symbol_ms"], run["spawn_to_symbol_ms"], run["symbols"])
end
best = runs.min_by { |run| run["spawn_to_symbol_ms"] }
printf("best spawn→workspace/symbol response: %.1f ms\n", best["spawn_to_symbol_ms"])
File.write(json_out, JSON.pretty_generate({ "workspace" => workspace, "files" => files.size, "server" => server_kind, "runs" => runs })) if json_out
