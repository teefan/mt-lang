#!/usr/bin/env ruby
# frozen_string_literal: true

# lsp_recovery_probe — drive the Ruby host LSP and the self-host LSP (`mtc lsp`)
# through a corpus of mid-edit recovery states and compare every diagnostic the
# two servers report (publish notifications and pull responses) byte for byte.
#
# The corpus is a set of complete Milk Tea programs that each receive one or
# more edits that leave the buffer half-typed — a truncated member access
# (`n.`, `a.inner.`), an unterminated string, an unterminated block, a
# half-typed `import`, and a cut-off expression.  Diagnostic parity on that
# state is what a user sees while typing, so it is pinned here rather than in
# the whole-workspace audit (which only opens files that parse).
#
# The fixture corpus is written by this tool under tmp/lsp-recovery/; each case
# gets its own workspace so the servers' indexes do not leak across cases.
#
# Usage:
#   ruby tools/lsp_recovery_probe.rb                # print host vs self per case
#   ruby tools/lsp_recovery_probe.rb --check        # byte-compare, non-zero on diff
#   ruby tools/lsp_recovery_probe.rb --only NAME    # run one case
#   ruby tools/lsp_recovery_probe.rb --self BIN     # override the self binary
#
# Exit status: 0 when every case matches.

require "cgi/escape"
require "fileutils"
require "json"
require "shellwords"
require "timeout"

ROOT = File.expand_path("..", __dir__)
WORKSPACE = File.join(ROOT, "tmp", "lsp-recovery")
SELF_MEM_KB = 20_000_000

def path_to_uri(path)
  "file://#{path.split("/").map { |seg| CGI.escape(seg).gsub("+", "%20") }.join("/")}"
end

def full(text)
  { "changes" => [{ "text" => text }] }
end

def insert(line, character, text)
  { "changes" => [{ "range" => { "start" => { "line" => line, "character" => character },
                                "end" => { "line" => line, "character" => character } },
                    "text" => text }] }
end

## Replace the `from` line with `to` (the edit a user makes while typing).
def replace_line(base, from, to)
  base.split("\n", -1).map { |line| line == from ? to : line }.join("\n")
end

BASE_MEMBER = <<~MT
  struct Sample:
      x: int
      y: int


  function main() -> int:
      var n = Sample(x = 1, y = 2)
      let v = n.x

      return v
MT

BASE_CHAIN = <<~MT
  struct Inner:
      value: int


  struct Outer:
      inner: Inner


  function main() -> int:
      var a = Outer(inner = Inner(value = 1))
      let b = a.inner.value

      return b
MT

BASE_STRING = <<~MT
  function main() -> int:
      let s = "hello"
      let n = s.len

      return int<-n
MT

BASE_BLOCK = <<~MT
  struct Sample:
      x: int


  function main() -> int:
      var n = Sample(x = 1)
      if n.x > 0:
          return 1

      return 0
MT

BASE_IMPORT = <<~MT
  import std.vec as vec


  function main() -> int:
      return 0
MT

BASE_EXPR = <<~MT
  function main() -> int:
      let x = 1
      let y = x + 2

      return y
MT

CASES = [
  {
    name: "truncated-member",
    base: BASE_MEMBER,
    steps: [
      { label: "type `n.` over `let v = n.x`",
        edit: full(replace_line(BASE_MEMBER, "    let v = n.x", "    n.")) },
      { label: "append `.` to the truncated statement",
        edit: insert(7, 6, ".") },
    ],
  },
  {
    name: "truncated-chain",
    base: BASE_CHAIN,
    steps: [
      { label: "type `a.inner.` over `let b = a.inner.value`",
        edit: full(replace_line(BASE_CHAIN, "    let b = a.inner.value", "    a.inner.")) },
    ],
  },
  {
    name: "unterminated-string",
    base: BASE_STRING,
    steps: [
      { label: "delete the closing quote of `\"hello\"`",
        edit: full(replace_line(BASE_STRING, '    let s = "hello"', '    let s = "hello')) },
    ],
  },
  {
    name: "unterminated-block",
    base: BASE_BLOCK,
    steps: [
      { label: "cut the body of `if n.x > 0:`",
        edit: full(replace_line(BASE_BLOCK, "          return 1", "      if n.x > 0:")) },
    ],
  },
  {
    name: "half-typed-import",
    base: BASE_IMPORT,
    steps: [
      { label: "type `import std.`",
        edit: full(replace_line(BASE_IMPORT, "  import std.vec as vec", "  import std.")) },
    ],
  },
  {
    name: "cut-off-expression",
    base: BASE_EXPR,
    steps: [
      { label: "type `let y = x +`",
        edit: full(replace_line(BASE_EXPR, "    let y = x + 2", "    let y = x +")) },
    ],
  },
].freeze

## A stdio LSP client that answers `workspace/configuration` and records
## server->client notifications (the audit tool's client, trimmed).
class Client
  attr_reader :notifications, :stderr_lines, :bad_frames

  def initialize(kind, self_bin)
    @kind = kind
    stdin_r, stdin_w = IO.pipe
    stdout_r, stdout_w = IO.pipe
    stderr_r, stderr_w = IO.pipe
    cmd =
      case kind
      when "host"
        [RbConfig.ruby, "-I", File.join(ROOT, "lib"), "-e",
         "require 'milk_tea'; MilkTea::LSP::Server.new.run"]
      else
        inner = [self_bin, "lsp"].map { |a| Shellwords.escape(a) }.join(" ")
        ["bash", "-c", "ulimit -v #{SELF_MEM_KB}; exec #{inner}"]
      end
    @pid = spawn(*cmd, chdir: ROOT, in: stdin_r, out: stdout_w, err: stderr_w, pgroup: true)
    [stdin_r, stdout_w, stderr_w].each(&:close)
    @stdin = stdin_w
    @stdout = stdout_r
    @next_id = 1
    @notifications = []
    @stderr_lines = []
    @bad_frames = []
    @mutex = Mutex.new
    Thread.new { stderr_r.each_line { |line| @mutex.synchronize { @stderr_lines << line.chomp } } rescue nil }
  end

  def request(method, params)
    id = @next_id
    @next_id += 1
    write({ "jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params })
    Timeout.timeout(30) do
      loop do
        message = read_message
        return { "closed" => true } if message.nil?

        if message["method"]
          note(message)
          write({ "jsonrpc" => "2.0", "id" => message["id"], "result" => nil }) if message["id"]
          next
        end
        return message if message["id"] == id
      end
    end
  rescue Timeout::Error
    { "timeout" => true, "method" => method }
  end

  def notify(method, params)
    write({ "jsonrpc" => "2.0", "method" => method, "params" => params })
  end

  ## Read whatever arrives for `seconds`, recording notifications.
  def drain(seconds)
    deadline = Time.now + seconds
    while (remaining = deadline - Time.now) > 0
      begin
        Timeout.timeout(remaining) { read_message }
      rescue Timeout::Error
        break
      end
    end
  end

  ## The pull items of a `textDocument/diagnostic` response.
  def pull_items(response)
    result = response["result"]
    return [] unless result.is_a?(Hash)

    result["items"] || []
  end

  def note(message)
    @mutex.synchronize { @notifications << message }
  end

  def write(message)
    json = JSON.dump(message)
    @stdin.write("Content-Length: #{json.bytesize}\r\n\r\n#{json}")
    @stdin.flush
  rescue Errno::EPIPE, IOError
    nil
  end

  def read_message
    headers = {}
    loop do
      line = @stdout.gets or return nil
      stripped = line.chomp.sub(/\r\z/, "")
      break if stripped.empty?

      key, value = stripped.split(":", 2)
      headers[key.strip] = value.strip
    end
    body = @stdout.read(headers["Content-Length"].to_i)
    JSON.parse(body)
  rescue JSON::ParserError
    @mutex.synchronize { @bad_frames << body.to_s[0, 120] }
    nil
  end

  def publishes_since(mark)
    @mutex.synchronize do
      @notifications[mark..].to_a
        .select { |m| m["method"] == "textDocument/publishDiagnostics" }
        .last
    end
  end

  def notification_count
    @mutex.synchronize { @notifications.size }
  end

  def stop
    Process.kill("TERM", -Process.getpgid(@pid)) rescue nil
    Timeout.timeout(5) { Process.wait(@pid) } rescue nil
  end
end

## Run one case against both servers; return [host_steps, self_steps] where each
## step is { publish:, pull: } (the last publish since the previous step, and
## the pull items).
def run_case(kase, self_bin)
  dir = File.join(WORKSPACE, kase[:name])
  FileUtils.rm_rf(dir)
  FileUtils.mkdir_p(dir)
  file = File.join(dir, "main.mt")
  uri = path_to_uri(file)
  File.write(file, kase[:base])

  servers = { "host" => Client.new("host", self_bin), "self" => Client.new("self", self_bin) }
  init = {
    "processId" => Process.pid,
    "rootUri" => path_to_uri(dir),
    "capabilities" => { "textDocument" => { "publishDiagnostics" => {} } },
    "workspaceFolders" => [{ "uri" => path_to_uri(dir), "name" => kase[:name] }],
  }
  servers.each_value do |client|
    client.request("initialize", init)
    client.notify("initialized", {})
    client.notify("textDocument/didOpen",
                  { "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => kase[:base] } })
  end

  version = 1
  records = { "host" => [], "self" => [] }
  servers.each do |kind, client|
    # Warm the facts for the opened document (the host computes them lazily, so
    # its first answer after didOpen can lag the content).
    client.request("textDocument/hover", { "textDocument" => { "uri" => uri }, "position" => { "line" => 0, "character" => 0 } })
    client.request("textDocument/documentSymbol", { "textDocument" => { "uri" => uri } })
    client.drain(1.0)
    records[kind] << { "publish" => nil, "pull" => client.pull_items(client.request("textDocument/diagnostic", { "textDocument" => { "uri" => uri } })) }
  end

  kase[:steps].each do |step|
    version += 1
    marks = servers.transform_values(&:notification_count)
    servers.each do |_kind, client|
      client.notify("textDocument/didChange",
                    { "textDocument" => { "uri" => uri, "version" => version },
                      "contentChanges" => step[:edit]["changes"] })
    end
    servers.each do |kind, client|
      client.drain(1.0)
      # One warming request, then the compared pull (the host recomputes facts
      # on demand; the second pull is the settled answer for both servers).
      client.request("textDocument/hover", { "textDocument" => { "uri" => uri }, "position" => { "line" => 0, "character" => 0 } })
      client.drain(0.2)
      publish = client.publishes_since(marks[kind])
      items = client.pull_items(client.request("textDocument/diagnostic", { "textDocument" => { "uri" => uri } }))
      records[kind] << { "publish" => publish && publish.dig("params", "diagnostics"), "pull" => items }
    end
  end

  servers.each_value(&:stop)
  [records["host"], records["self"]]
end

def describe(item)
  range = item["range"] || {}
  start = range["start"] || {}
  "#{item['code']} #{start['line']}:#{start['character']} #{JSON.dump(item['message'])[0, 120]}"
end

## Canonical JSON: JSON objects are unordered, so compare by sorted keys.
def canonical(value)
  case value
  when Hash
    value.keys.sort.to_h { |key| [key, canonical(value[key])] }
  when Array
    value.map { |element| canonical(element) }
  else
    value
  end
end

def same?(a, b)
  canonical(a) == canonical(b)
end

def print_records(label, records, steps)
  puts "  #{label}:"
  records.each_with_index do |record, i|
    tag = i.zero? ? "open " : "step #{i}"
    label_text = i.zero? ? "" : " — #{steps[i - 1][:label]}"
    puts "    #{tag}#{label_text}: pull #{record['pull'].size}, publish #{record['publish'] ? record['publish'].size : 'none'}"
    record["pull"].each { |item| puts "      #{describe(item)}" }
  end
end

## -- main ------------------------------------------------------------------

self_bin = File.join(ROOT, "build", "stage2", "mtc")
check = false
only = nil
until ARGV.empty?
  arg = ARGV.shift
  case arg
  when "--check" then check = true
  when "--only" then only = ARGV.shift
  when "--self" then self_bin = ARGV.shift
  else abort "unknown option: #{arg}"
  end
end
abort "self-host binary not found: #{self_bin}" unless File.executable?(self_bin)

FileUtils.mkdir_p(WORKSPACE)
failures = 0
CASES.each do |kase|
  next if only && kase[:name] != only

  host, self_ = run_case(kase, self_bin)
  puts "case #{kase[:name]}:"
  print_records("host", host, kase[:steps])
  print_records("self", self_, kase[:steps])

  host.each_with_index do |record, i|
    mine = self_[i]
    next if same?(record, mine)

    failures += 1
    tag = i.zero? ? "open" : "step #{i} (#{kase[:steps][i - 1][:label]})"
    puts "  DIFF #{tag}:"
    host_items = record["pull"]
    self_items = mine["pull"]
    ([host_items.size, self_items.size].max).times do |k|
      h = host_items[k]
      s = self_items[k]
      next if same?(h, s)

      puts "    host[#{k}]: #{h ? describe(h) : '(absent)'}"
      puts "    self[#{k}]: #{s ? describe(s) : '(absent)'}"
      puts "      host json: #{JSON.dump(h)[0, 400]}" if h
      puts "      self json: #{JSON.dump(s)[0, 400]}" if s
    end
  end
  puts
end

if check
  if failures.zero?
    puts "recovery parity: OK"
    exit 0
  else
    puts "recovery parity: #{failures} differing step(s)"
    exit 1
  end
end
