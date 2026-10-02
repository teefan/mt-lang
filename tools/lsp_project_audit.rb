#!/usr/bin/env ruby
# frozen_string_literal: true

# lsp_project_audit — drive the *same* request matrix through the Ruby host LSP
# and the self-host LSP (`mtc lsp`) for an existing project directory, and diff
# the responses request by request while both servers are live.
#
# `tools/lsp_parity.rb` records a fixed synthetic workspace; this tool audits a
# real project: every `.mt` file under the workspace is opened, the file-level
# endpoints (outline, folding, tokens, hints, lenses, links, pull diagnostics)
# run once per file, and the position endpoints (hover, definition, declaration,
# typeDefinition, implementation, references, documentHighlight) run at every
# identifier position (evenly sampled when a file exceeds `--cap`).
#
# Usage:
#   ruby tools/lsp_project_audit.rb --workspace DIR [--self BIN]
#                                  [--cap N] [--timeout SEC] [--max-diffs N]
#                                  [--json OUT] [--only METHOD]
#
# Exit status: 0 when every recorded response matches.

require "cgi/escape"
require "fileutils"
require "json"
require "timeout"

ROOT = File.expand_path("..", __dir__)

def path_to_uri(path)
  "file://#{path.split("/").map { |seg| CGI.escape(seg).gsub("+", "%20") }.join("/")}"
end

# Replace volatile content so a host/self diff shows behavioural differences
# only: the workspace path and fingerprint-style result ids.
def normalize(value, workspace)
  case value
  when Hash
    value.each_with_object({}) do |(k, v), out|
      next if k == "resultId"

      out[k] = normalize(v, workspace)
    end
  when Array
    value.map { |v| normalize(v, workspace) }
  when String
    value.gsub(workspace, "<WS>")
  else
    value
  end
end

## Raised when a frame's body is not valid JSON: the server emitted a bad frame
## (not a client bug) and the stream is no longer trustworthy.
class MalformedFrame < StandardError
  attr_reader :body

  def initialize(body)
    @body = body.to_s
    super("malformed frame (#{@body.bytesize} bytes)")
  end
end

## Raised when the server's input pipe is gone: the process exited or crashed.
class DeadServer < StandardError
end

## Body of `milkTea`-style server→client requests the client must answer.
class LspClient
  attr_reader :stderr_lines, :malformed_frames, :dead

  def initialize(stdin, stdout, stderr_read, timeout_s)
    @stdin = stdin
    @stdout = stdout
    @stderr_read = stderr_read
    @timeout_s = timeout_s
    @next_id = 1
    @stderr_lines = []
    @stderr_mutex = Mutex.new
    @malformed_frames = []
    @dead = false
    drain_stderr
  end

  ## Consume stderr continuously on its own thread.  A server that logs to
  ## stderr blocks once the pipe's 64 KiB buffer fills, and a client that only
  ## reads stderr at the end of the run would deadlock against it (the audit
  ## drives thousands of requests).
  def drain_stderr
    return unless @stderr_read

    reader = @stderr_read
    @stderr_thread = Thread.new do
      begin
        reader.each_line { |line| @stderr_mutex.synchronize { @stderr_lines << line } }
      rescue IOError, Errno::EIO
        nil
      end
    end
    @stderr_thread.abort_on_exception = false
  end

  def request(method, params)
    return { "desync" => true } if @desync
    return { "dead" => true } if @dead

    id = @next_id
    @next_id += 1
    write({ "jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params })
    read_until(id)
  rescue DeadServer
    @dead = true
    { "dead" => true }
  end

  def notify(method, params)
    write({ "jsonrpc" => "2.0", "method" => method, "params" => params })
  rescue DeadServer
    @dead = true
  end

  def write(message)
    raise DeadServer if @dead

    json = JSON.dump(message)
    @stdin.write("Content-Length: #{json.bytesize}\r\n\r\n#{json}")
    @stdin.flush
  rescue Errno::EPIPE, IOError, Errno::EBADF
    raise DeadServer
  end

  def read_until(id)
    Timeout.timeout(@timeout_s) do
      loop do
        message = read_message
        return { "closed" => true } if message.nil?
        if message["method"]
          answer_server_request(message)
          next
        end
        return message if message["id"] == id

        # A response to a stale id: keep reading.
      end
    end
  rescue Timeout::Error
    { "timeout" => true }
  rescue MalformedFrame => e
    @desync = true
    @malformed_frames << e.body
    { "malformed" => true, "bytes" => e.body.bytesize, "snippet" => e.body[0, 160] }
  end

  def answer_server_request(message)
    return unless message["id"]

    result =
      case message["method"]
      when "workspace/configuration"
        params = message["params"]
        items = params.is_a?(Hash) ? params["items"] : nil
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

    body = @stdout.read(length)
    begin
      JSON.parse(body)
    rescue JSON::ParserError
      raise MalformedFrame, body
    end
  end

  ## Stderr is consumed by the drain thread; give it a moment to catch up.
  def collect_stderr
    return unless @stderr_thread

    @stderr_thread.join(0.5)
  rescue StandardError
    nil
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
          [kind]
        end
  pid = spawn(*cmd, chdir: ROOT, in: stdin_read, out: stdout_write, err: stderr_write, pgroup: true)
  [stdin_read, stdout_write, stderr_write].each(&:close)
  [pid, stdin_write, stdout_read, stderr_read]
end

def shutdown(pid, stdin, stdout, stderr_read)
  begin
    stdin.close
  rescue StandardError
    nil
  end
  begin
    Process.kill("TERM", -Process.getpgid(pid))
  rescue StandardError
    nil
  end
  begin
    Timeout.timeout(5) { Process.wait(pid) }
  rescue Timeout::Error
    Process.kill("KILL", pid) rescue nil
    Process.wait(pid) rescue nil
  rescue Errno::ECHILD
    nil
  end
  [stdout, stderr_read].each { |io| io.close rescue nil }
end

IDENTIFIER = /[A-Za-z_][A-Za-z0-9_]*/

## Every identifier occurrence in `source`, evenly sampled down to `cap`.
def identifier_positions(source, cap)
  positions = []
  source.each_line.with_index do |line, li|
    line.scan(IDENTIFIER) do
      positions << [li, Regexp.last_match.begin(0)]
    end
  end
  return positions if cap.zero? || positions.size <= cap

  step = positions.size.fdiv(cap)
  (0...cap).map { |i| positions[(i * step).floor] }
end

## Every member-access completion position in `source`: the character just
## after a `.` that is followed by an identifier (so `a.b` chains, module
## aliases and `self.x` all count; `..` ranges and float literals do not).
## Evenly sampled down to `cap`.
def member_completion_positions(source, cap)
  positions = []
  source.each_line.with_index do |line, li|
    line.to_enum(:scan, /\.(?=[A-Za-z_])/).each do
      positions << [li, Regexp.last_match.end(0)]
    end
  end
  return positions if cap.zero? || positions.size <= cap

  step = positions.size.fdiv(cap)
  (0...cap).map { |i| positions[(i * step).floor] }
end

def relative(path, workspace)
  path.start_with?(workspace) ? path[workspace.length..].sub(%r{\A/}, "") : path
end

# ── main ─────────────────────────────────────────────────────────────────────

workspace = nil
self_bin = File.join(ROOT, "build", "stage2", "mtc")
cap = 200
timeout_s = 20
max_diffs = 40
json_out = nil
only = nil
until ARGV.empty?
  a = ARGV.shift
  case a
  when "--workspace" then workspace = File.expand_path(ARGV.shift)
  when "--self" then self_bin = ARGV.shift
  when "--cap" then cap = ARGV.shift.to_i
  when "--timeout" then timeout_s = ARGV.shift.to_i
  when "--max-diffs" then max_diffs = ARGV.shift.to_i
  when "--json" then json_out = ARGV.shift
  when "--only" then only = ARGV.shift
  else abort "unknown option: #{a}"
  end
end
abort "audit requires --workspace DIR" unless workspace
abort "workspace not found: #{workspace}" unless Dir.exist?(workspace)

files = Dir.glob(File.join(workspace, "**", "*.mt")).sort
abort "no .mt files under #{workspace}" if files.empty?

servers = {}
%w[host self].each do |kind|
  pid, stdin, stdout, stderr_read = spawn_server(kind, self_bin)
  client = LspClient.new(stdin, stdout, stderr_read, timeout_s)
  servers[kind] = { pid: pid, stdin: stdin, stdout: stdout, stderr: stderr_read, client: client }
end

def both(servers, method, params)
  %w[host self].to_h do |kind|
    s = servers[kind]
    response = s[:client].request(method, params)
    # A server that emitted a malformed frame or died has an untrustworthy
    # stream: bring it back up with the same workspace and retry the request
    # once, so one bad frame or crash cannot hide the rest of the audit.
    if response.is_a?(Hash) && (response["desync"] || response["dead"]) && s[:restart]
      s[:client].collect_stderr
      s[:restart].call(kind)
      response = servers[kind][:client].request(method, params)
    end
    [kind, response]
  end
end

root_uri = path_to_uri(workspace)
init_params = {
  "processId" => Process.pid,
  "rootUri" => root_uri,
  "capabilities" => { "textDocument" => { "publishDiagnostics" => {} } },
  "workspaceFolders" => [{ "uri" => root_uri, "name" => File.basename(workspace) }],
}

results = { "initialize" => both(servers, "initialize", init_params) }
%w[host self].each { |k| servers[k][:client].notify("initialized", {}) }

file_level = %w[
  textDocument/documentSymbol
  textDocument/foldingRange
  textDocument/codeLens
  textDocument/inlayHint
  textDocument/documentLink
  textDocument/semanticTokens/full
  textDocument/diagnostic
]
position_level = %w[
  textDocument/hover
  textDocument/definition
  textDocument/declaration
  textDocument/typeDefinition
  textDocument/implementation
  textDocument/references
  textDocument/documentHighlight
]

sources = {}
files.each do |path|
  source = File.read(path)
  sources[path] = source
  uri = path_to_uri(path)
  %w[host self].each { |k| servers[k][:client].notify("textDocument/didOpen", { "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source } }) }
end

restarts = Hash.new(0)
deaths = Hash.new(0)
malformed_counts = Hash.new(0)
dead_stderr = Hash.new { |h, k| h[k] = [] }
restart = lambda do |kind|
  s = servers[kind]
  malformed_counts[kind] += s[:client].malformed_frames.size
  deaths[kind] += 1 if s[:client].dead
  s[:client].collect_stderr
  dead_stderr[kind].concat(s[:client].stderr_lines.last(5))
  shutdown(s[:pid], s[:stdin], s[:stdout], s[:stderr])
  pid, stdin, stdout, stderr_read = spawn_server(kind, self_bin)
  client = LspClient.new(stdin, stdout, stderr_read, timeout_s)
  servers[kind] = { pid: pid, stdin: stdin, stdout: stdout, stderr: stderr_read, client: client, restart: restart }
  client.request("initialize", init_params)
  client.notify("initialized", {})
  sources.each do |path, text|
    client.notify("textDocument/didOpen",
                  { "textDocument" => { "uri" => path_to_uri(path), "languageId" => "milk-tea",
                                        "version" => 1, "text" => text } })
  end
  restarts[kind] += 1
end
servers.each_value { |s| s[:restart] = restart }

files.each do |path|
  uri = path_to_uri(path)
  rel = relative(path, workspace)
  positions = identifier_positions(sources[path], cap)

  # Warm the server's facts for this document first: the host recomputes them
  # lazily, so its very first answer after `didOpen` can lag behind the content
  # (the self-host computes synchronously).  These requests are discarded.
  both(servers, "textDocument/hover", { "textDocument" => { "uri" => uri }, "position" => { "line" => 0, "character" => 0 } })
  both(servers, "textDocument/documentSymbol", { "textDocument" => { "uri" => uri } })
  sleep 0.3

  file_level.each do |method|
    next if only && !method.include?(only)

    params = { "textDocument" => { "uri" => uri } }
    results["#{rel} #{method}"] = both(servers, method, params)
  end

  positions.each do |line, col|
    positions_params = {
      "textDocument" => { "uri" => uri },
      "position" => { "line" => line, "character" => col },
    }
    position_level.each do |method|
      next if only && !method.include?(only)

      params = positions_params
      if method == "textDocument/references"
        params = positions_params.merge("context" => { "includeDeclaration" => true })
      end
      results["#{rel}@#{line}:#{col} #{method}"] = both(servers, method, params)
    end
  end

  # Member completion at every `.` — the shape the editor drives while typing
  # (`n.` on a struct value, `rl.` on a module alias).  The host's handler
  # ignores the text after the cursor, so a valid buffer's dot position covers
  # the same path as the bare-`n.` mid-edit case.
  member_positions = member_completion_positions(sources[path], cap)
  unless only && !"textDocument/completion".include?(only)
    member_positions.each do |line, col|
      results["#{rel}@#{line}:#{col} textDocument/completion"] = both(
        servers, "textDocument/completion",
        "textDocument" => { "uri" => uri },
        "position" => { "line" => line, "character" => col }
      )
    end
  end
  warn "audited #{rel}: #{positions.size} positions, #{member_positions.size} member dots"
end

# workspace/symbol across the project (one query covers the file walk).
unless only
  results["workspace/symbol"] = both(servers, "workspace/symbol", { "query" => "" })
end

servers.each_value { |s| s[:client].collect_stderr }
stderr = servers.transform_values { |s| s[:client].stderr_lines.last(200) }
servers.each { |_k, s| shutdown(s[:pid], s[:stdin], s[:stdout], s[:stderr]) }

normalized = results.transform_values do |per_server|
  per_server.transform_values { |v| normalize(v, workspace) }
end

by_method = Hash.new { |h, k| h[k] = { total: 0, diffs: [] } }
normalized.each do |label, per_server|
  method = label.split(" ").last
  entry = by_method[method]
  entry[:total] += 1
  host = per_server["host"]
  self_ = per_server["self"]
  next if host == self_

  entry[:diffs] << [label, host, self_]
end

puts "workspace: #{workspace}"
puts "files: #{files.size}, positions/requests: #{normalized.size} entries"
if malformed_counts.values.any? { |n| n.positive? } || restarts.values.any? { |n| n.positive? }
  puts "malformed frames: #{JSON.dump(malformed_counts)}, server restarts: #{JSON.dump(restarts)}, server deaths: #{JSON.dump(deaths)}"
  dead_stderr.each do |kind, lines|
    next if lines.empty?

    puts "  #{kind} stderr before restart: #{lines.inspect[0, 400]}"
  end
end
puts
total_diffs = 0
by_method.sort.each do |method, entry|
  count = entry[:diffs].size
  total_diffs += count
  status = count.zero? ? "ok  " : "DIFF"
  printf("%-4s %-40s %4d entries, %d differ\n", status, method, entry[:total], count)
end
puts
if total_diffs.zero?
  puts "TOTAL differing entries: 0"
else
  puts "TOTAL differing entries: #{total_diffs}"
  shown = 0
  by_method.sort.each do |method, entry|
    entry[:diffs].each do |label, host, self_|
      break if shown >= max_diffs

      shown += 1
      puts "  ── #{label}"
      puts "     host: #{JSON.dump(host)[0, 300]}"
      puts "     self: #{JSON.dump(self_)[0, 300]}"
    end
  end
  puts "  ... #{total_diffs - shown} more differing entries" if total_diffs > shown
end

crash_lines = stderr.transform_values { |lines| lines.grep(/SIGSEGV|abort|free\(\)|panic/i) }
if crash_lines.any? { |_k, v| v.any? }
  puts
  puts "server stderr crash lines: #{JSON.dump(crash_lines)}"
end

if json_out
  File.write(json_out, JSON.pretty_generate({ "workspace" => workspace, "entries" => normalized, "stderr" => stderr }))
  puts "full recording -> #{json_out}"
end

exit(total_diffs.zero? ? 0 : 1)
