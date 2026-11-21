#!/usr/bin/env ruby
# frozen_string_literal: true

# lsp_conformance — drive the native LSP (`mtc lsp`) over stdio and assert
# behavior against the LSP 3.18 specification.  This is the spec oracle, not a
# parity recorder: every case states an explicit expectation, and a failing
# case names the expectation it broke.
#
# The cases are the ones in docs/lsp-enhancement-plan.md §5.  The P0/P1 defects
# the session-144 audit found are expected to fail here until their phase
# lands; do not weaken an assertion to make the gate green.
#
# Usage:
#   ruby tools/lsp_conformance.rb [--bin PATH] [--only PATTERN]
#                                 [--timeout SEC] [--json OUT]
#
#   --bin PATH      compiler to drive (default: build/stage2/mtc)
#   --only PATTERN  run cases whose name contains PATTERN
#   --timeout SEC   default per-request timeout (default: 5)
#   --json OUT      write a machine-readable report
#
# Exit status: 0 when every selected case passes, 1 when any fails, 2 on usage.

require "cgi/escape"
require "fileutils"
require "json"

ROOT = File.expand_path("..", __dir__)
DEFAULT_BIN = File.join(ROOT, "build", "stage2", "mtc")
WORK_ROOT = File.join(ROOT, "tmp", "lsp-conformance")
DEFAULT_TIMEOUT = 5.0


def path_to_uri(path)
  "file://#{path.split("/").map { |seg| CGI.escape(seg).gsub("+", "%20") }.join("/")}"
end


def write_fixture(dir, name, text)
  path = File.join(dir, name)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, text)
  path
end


# ── JSON-RPC client ──────────────────────────────────────────────────────────

class LspClient
  attr_reader :server_requests, :notifications, :stderr_lines

  def initialize(bin, timeout)
    @timeout = timeout
    @next_id = 1
    @buf = String.new(encoding: Encoding::BINARY)
    @exited = false
    @exit_status = nil
    @notifications = []
    @server_requests = []
    @stderr_lines = []

    stdin_read, @stdin = IO.pipe
    @stdout, stdout_write = IO.pipe
    @stderr, stderr_write = IO.pipe
    # The server is generated C: cap its address space per the project's
    # binary-testing rule (ulimit -v 20000000, expressed in bytes here).
    @pid = Process.spawn(bin, "lsp", chdir: ROOT, in: stdin_read, out: stdout_write,
                         err: stderr_write, pgroup: true,
                         rlimit_as: [20_480_000_000, 20_480_000_000])
    [stdin_read, stdout_write, stderr_write].each(&:close)
  end

  def request(method, params, id: next_id, timeout: nil)
    write({ "jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params })
    read_until(id, timeout || @timeout)
  end

  def notify(method, params = {})
    write({ "jsonrpc" => "2.0", "method" => method, "params" => params })
  end

  def next_id
    id = @next_id
    @next_id += 1
    id
  end

  ## Wait for a notification with `method` (and matching the optional filter),
  ## reading and queueing everything that arrives before it.  Returns nil on
  ## timeout or EOF.
  def wait_notification(method, timeout = @timeout)
    if (idx = @notifications.index { |m| m["method"] == method && (!block_given? || yield(m["params"])) })
      return @notifications.delete_at(idx)
    end

    deadline = now + timeout
    loop do
      kind, message = read_next(deadline)
      return nil if kind == :timeout
      next unless kind == :notification && message["method"] == method
      next if block_given? && !yield(message["params"])

      return message
    end
  end

  ## Wait for a server→client request with `method`.  Other requests are
  ## answered by `read_next`; they stay visible in `server_requests`.
  def wait_server_request(method, timeout = @timeout)
    if (idx = @server_requests.index { |m| m["method"] == method })
      return @server_requests.delete_at(idx)
    end

    deadline = now + timeout
    loop do
      kind, message = read_next(deadline)
      return nil if kind == :timeout
      return message if kind == :request && message["method"] == method
    end
  end

  ## Reap the server if it exits within `timeout`.  Returns the exit status, or
  ## nil when it is still running.
  def wait_for_exit(timeout = @timeout)
    return @exit_status if @exited

    deadline = now + timeout
    loop do
      reaped = Process.waitpid2(@pid, Process::WNOHANG)
      if reaped
        @exited = true
        @exit_status = reaped[1].exitstatus
        return @exit_status
      end
      return nil if now >= deadline

      sleep 0.01
    end
  rescue Errno::ECHILD
    @exited = true
    nil
  end

  ## Close stdin, let the server end its loop, and force it down if it does not.
  def close
    begin
      @stdin.close unless @stdin.closed?
    rescue IOError, Errno::EPIPE
      nil
    end

    unless @exited
      wait_for_exit(1.0)
      unless @exited
        begin
          Process.kill("TERM", -@pid)
        rescue Errno::ESRCH, Errno::EPERM
          nil
        end
        wait_for_exit(1.0)
        unless @exited
          begin
            Process.kill("KILL", -@pid)
          rescue Errno::ESRCH, Errno::EPERM
            nil
          end
          wait_for_exit(1.0)
        end
      end
    end

    collect_stderr
    @stdout.close unless @stdout.closed?
    @stderr.close unless @stderr.closed?
  rescue IOError, Errno::EPIPE
    nil
  end

  def collect_stderr
    loop do
      chunk = @stderr.read_nonblock(65_536)
      @stderr_lines.concat(chunk.lines)
    end
  rescue IO::WaitReadable, Errno::EAGAIN, Errno::EIO, EOFError, IOError
    nil
  end

  def write(message)
    json = JSON.dump(message)
    @stdin.write("Content-Length: #{json.bytesize}\r\n\r\n#{json}")
    @stdin.flush
  rescue IOError, Errno::EPIPE
    @exited = true
  end

  def read_until(id, timeout)
    deadline = now + timeout
    loop do
      kind, message = read_next(deadline)
      case kind
      when :response
        return message if message["id"] == id
      when :timeout
        return { "timeout" => true }
      else
        next
      end
    end
  end

  ## Read one message and classify it.  Server requests are answered
  ## immediately so the single-threaded server is never blocked on a client
  ## round-trip; notifications and requests are also queued for the cases.
  def read_next(deadline)
    message = read_message(deadline)
    return [:timeout, nil] if message.nil?

    if message["method"].is_a?(String)
      if message.key?("id")
        @server_requests << message
        answer_server_request(message)
        [:request, message]
      else
        @notifications << message
        [:notification, message]
      end
    else
      [:response, message]
    end
  end

  def answer_server_request(message)
    result = nil
    if message["method"] == "workspace/configuration"
      params = message["params"]
      count = if params.is_a?(Array)
                params.size
              elsif params.is_a?(Hash) && params["items"].is_a?(Array)
                params["items"].size
              else
                0
              end
      result = Array.new(count, nil)
    end
    write({ "jsonrpc" => "2.0", "id" => message["id"], "result" => result })
  end

  def read_message(deadline)
    header_end = nil
    loop do
      header_end = @buf.index("\r\n\r\n")
      break if header_end
      return nil unless fill(deadline)
    end

    header = @buf.slice!(0, header_end + 4)
    length = nil
    header.split("\r\n").each do |line|
      key, value = line.split(":", 2)
      length = value.to_i if key && key.downcase == "content-length"
    end
    return nil unless length && length.positive?

    while @buf.bytesize < length
      return nil unless fill(deadline)
    end

    body = @buf.slice!(0, length)
    JSON.parse(body.force_encoding(Encoding::UTF_8))
  rescue JSON::ParserError
    nil
  end

  ## Append at least one readable chunk to the buffer.  False on deadline or
  ## EOF.
  def fill(deadline)
    loop do
      remaining = deadline - now
      return false if remaining <= 0

      ready = IO.select([@stdout], nil, nil, remaining)
      return false unless ready

      begin
        @buf << @stdout.read_nonblock(65_536)
        return true
      rescue IO::WaitReadable, Errno::EAGAIN
        next
      rescue EOFError, Errno::EIO
        return false
      end
    end
  end

  def now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end


# ── case helpers ────────────────────────────────────────────────────────────

class CaseContext
  attr_reader :root, :failures, :notes
  attr_accessor :stderr

  def initialize(root)
    @root = root
    @failures = []
    @notes = []
    @stderr = []
  end

  def check(condition, message)
    @failures << message unless condition
    condition
  end

  def eq(actual, expected, label)
    check(actual == expected, "#{label}: expected #{expected.inspect}, got #{actual.inspect}")
  end

  def note(message)
    @notes << message
  end

  def passed?
    @failures.empty?
  end
end


def init!(client, root, capabilities: {}, folders: nil)
  params = {
    "processId" => nil,
    "rootUri" => path_to_uri(root),
    "capabilities" => capabilities,
  }
  params["workspaceFolders"] = folders if folders
  response = client.request("initialize", params)
  client.notify("initialized", {})
  response
end


def open!(client, path, text: nil, version: 1)
  client.notify("textDocument/didOpen", {
    "textDocument" => {
      "uri" => path_to_uri(path),
      "languageId" => "milk-tea",
      "version" => version,
      "text" => text || File.read(path),
    },
  })
end


def hover_params(path, line, character)
  {
    "textDocument" => { "uri" => path_to_uri(path) },
    "position" => { "line" => line, "character" => character },
  }
end


def decode_semantic_tokens(data)
  line = 0
  character = 0
  data.each_slice(5).map do |delta_line, delta_char, length, type, modifiers|
    line += delta_line
    character = delta_line.zero? ? character + delta_char : delta_char
    { line: line, character: character, length: length, type: type, modifiers: modifiers }
  end
end


def publish_for(client, uri, timeout, require_items: false)
  client.wait_notification("textDocument/publishDiagnostics", timeout) do |params|
    params["uri"] == uri && (!require_items || !Array(params["diagnostics"]).empty?)
  end
end


UTF16_SOURCE = <<~MT
  function add(a: int, b: int) -> int:
      return a + b

  function main() -> int:
      let before = 1
      let s = "😀" + before
      let t = "😀" + add(before, 2)
      let u = "😀" + missing_after
      return before
MT

ASCII_SOURCE = <<~MT
  function add(a: int, b: int) -> int:
      return a + b

  function main() -> int:
      let before = 1
      let s = "abc" + before
      let u = "abc" + missing_after
      return before
MT

DID_CHANGE_SOURCE = <<~MT
  function main() -> int:
      let s = "😀" + 1
      return 1
MT

DOCS_SOURCE = <<~MT
  ## Adds two numbers.
  ## @param a first addend
  function foo(a: int, b: int) -> int:
      return a + b

  function main() -> int:
      return fo
MT

HELPER_SOURCE = <<~MT
  public function helper_sum(a: int, b: int) -> int:
      return a + b
MT

USER_SOURCE = <<~MT
  import helper

  function user_call() -> int:
      return int<-helper_sum(1, 2)
MT

WATCHED_SOURCE = <<~MT
  public function watched_one() -> int:
      return 1
MT

WATCHED_UPDATED = <<~MT
  public function watched_one() -> int:
      return 1

  public function watched_two() -> int:
      return 2
MT

MULTI_ROOT_A = <<~MT
  public function multi_root_a() -> int:
      return 1
MT

MULTI_ROOT_B = <<~MT
  public function multi_root_b() -> int:
      return 2
MT

PULL_OPEN_SOURCE = <<~MT
  function pull_open() -> int:
      return missing_open
MT

PULL_CLOSED_SOURCE = <<~MT
  function pull_closed() -> int:
      return missing_closed
MT

DEP_SOURCE = <<~MT
  public function dep_value() -> int:
      return 1
MT

DEP_UPDATED = <<~MT
  public function dep_value() -> int:
      return 2
MT

USER_OF_DEP_SOURCE = <<~MT
  import dep

  function use_dep() -> int:
      return dep.dep_value()
MT

SIMPLE_SOURCE = <<~MT
  function main() -> int:
      let value = 1
      return value
MT

ERROR_SOURCE = <<~MT
  function broken() -> int:
      return missing_name
MT


# ── cases ───────────────────────────────────────────────────────────────────

CASES = []

def add_case(name, timeout: nil, &block)
  CASES << { name: name, timeout: timeout, run: block }
end


add_case("capabilities/code-action-kinds") do |ctx, client|
  response = init!(client, ctx.root)
  caps = response.dig("result", "capabilities") || {}
  ctx.eq(caps.dig("codeActionProvider", "codeActionKinds"),
         %w[quickfix source.fixAll],
         "codeActionProvider.codeActionKinds")
end


add_case("capabilities/workspace-shape") do |ctx, client|
  response = init!(client, ctx.root)
  caps = response.dig("result", "capabilities") || {}
  ctx.eq(caps.dig("workspace", "didChangeWatchedFiles"), nil,
         "workspace.didChangeWatchedFiles must not be advertised (not a ServerCapabilities field)")
  ctx.eq(caps.dig("workspace", "workspaceFolders", "supported"), true,
         "workspace.workspaceFolders.supported")
  ctx.eq(caps.dig("diagnosticProvider", "workspaceDiagnostics"), true,
         "diagnosticProvider.workspaceDiagnostics")
end


add_case("encoding/utf8-negotiation") do |ctx, client|
  response = init!(client, ctx.root,
                   capabilities: { "general" => { "positionEncodings" => %w[utf-8 utf-16] } })
  ctx.eq(response.dig("result", "capabilities", "positionEncoding"), "utf-8",
         "advertised position encoding when the client offers utf-8")

  path = write_fixture(ctx.root, "main.mt", UTF16_SOURCE)
  uri = path_to_uri(path)
  open!(client, path)
  tokens = decode_semantic_tokens(
    Array(client.request("textDocument/semanticTokens/full",
                         { "textDocument" => { "uri" => uri } }).dig("result", "data"))
  )
  token = tokens.find { |t| t[:line] == 5 && t[:type] == 18 }
  ctx.check(token, "no string token on the astral line")
  ctx.eq(token && token[:length], 6, "UTF-8 semantic token length (bytes)") if token

  range = client.request("textDocument/hover", hover_params(path, 5, 21)).dig("result", "range")
  ctx.eq(range && range.dig("start", "character"), 21, "UTF-8 hover range start") if range
  ctx.eq(range && range.dig("end", "character"), 27, "UTF-8 hover range end") if range

  message = publish_for(client, uri, 5.0, require_items: true)
  diag = Array(message&.dig("params", "diagnostics")).find do |d|
    d.dig("range", "start", "line") == 7
  end
  ctx.eq(diag && diag.dig("range", "start", "character"), 21, "UTF-8 diagnostic start")
end


add_case("utf16/document-highlight") do |ctx, client|
  init!(client, ctx.root)
  path = write_fixture(ctx.root, "main.mt", UTF16_SOURCE)
  open!(client, path)
  response = client.request("textDocument/documentHighlight", hover_params(path, 5, 20))
  range = Array(response["result"]).find { |h| h.dig("range", "start", "line") == 5 }&.dig("range")
  ctx.check(range, "no document highlight on the astral line")
  ctx.eq(range && range.dig("start", "character"), 19, "highlight start (UTF-16)") if range
  ctx.eq(range && range.dig("end", "character"), 25, "highlight end (UTF-16)") if range
end


add_case("utf16/references") do |ctx, client|
  init!(client, ctx.root)
  path = write_fixture(ctx.root, "main.mt", UTF16_SOURCE)
  open!(client, path)
  response = client.request("textDocument/references",
                            hover_params(path, 5, 20).merge("context" => { "includeDeclaration" => true }))
  location = Array(response["result"]).find { |loc| loc.dig("range", "start", "line") == 5 }
  ctx.check(location, "no reference on the astral line")
  if location
    ctx.eq(location.dig("range", "start", "character"), 19, "reference start (UTF-16)")
    ctx.eq(location.dig("range", "end", "character"), 25, "reference end (UTF-16)")
  end
end


add_case("utf16/semantic-token-length") do |ctx, client|
  init!(client, ctx.root)
  path = write_fixture(ctx.root, "main.mt", UTF16_SOURCE)
  open!(client, path)
  response = client.request("textDocument/semanticTokens/full",
                            { "textDocument" => { "uri" => path_to_uri(path) } })
  tokens = decode_semantic_tokens(Array(response.dig("result", "data")))
  token = tokens.find { |t| t[:line] == 5 && t[:type] == 18 }
  ctx.check(token, "no string token on the astral line")
  ctx.eq(token && token[:length], 4, "semantic token length for \"😀\" (UTF-16 units)") if token
end


add_case("utf16/diagnostic-range") do |ctx, client|
  init!(client, ctx.root)
  path = write_fixture(ctx.root, "main.mt", UTF16_SOURCE)
  uri = path_to_uri(path)
  open!(client, path)
  message = publish_for(client, uri, 5.0, require_items: true)
  ctx.check(message, "no diagnostics published")
  diag = Array(message&.dig("params", "diagnostics")).find do |d|
    d.dig("range", "start", "line") == 7
  end
  ctx.check(diag, "no diagnostic on the astral line")
  if diag
    ctx.eq(diag.dig("range", "start", "character"), 19, "diagnostic start character (UTF-16)")
    ctx.eq(diag.dig("range", "end", "character"), 32, "diagnostic end character (UTF-16)")
  end
end


add_case("utf16/hover-range") do |ctx, client|
  init!(client, ctx.root)
  path = write_fixture(ctx.root, "main.mt", UTF16_SOURCE)
  open!(client, path)
  response = client.request("textDocument/hover", hover_params(path, 5, 20))
  range = response.dig("result", "range")
  ctx.check(range, "hover returned no range")
  ctx.eq(range && range.dig("start", "character"), 19, "hover range start (UTF-16)")
  ctx.eq(range && range.dig("end", "character"), 25, "hover range end (UTF-16)")
end


add_case("utf16/rename-edit") do |ctx, client|
  init!(client, ctx.root)
  path = write_fixture(ctx.root, "main.mt", UTF16_SOURCE)
  open!(client, path)
  response = client.request("textDocument/rename",
                            hover_params(path, 5, 20).merge("newName" => "renamed"))
  changes = response.dig("result", "changes") || {}
  edits = changes.values.flatten
  edit = edits.find { |e| e.dig("range", "start", "line") == 5 }
  ctx.check(edit, "no rename edit on the astral line")
  if edit
    ctx.eq(edit.dig("range", "start", "character"), 19, "rename edit start (UTF-16)")
    ctx.eq(edit.dig("range", "end", "character"), 25, "rename edit end (UTF-16)")
  end
end


add_case("utf16/inlay-hint") do |ctx, client|
  init!(client, ctx.root)
  path = write_fixture(ctx.root, "main.mt", UTF16_SOURCE)
  open!(client, path)
  response = client.request("textDocument/inlayHint", {
    "textDocument" => { "uri" => path_to_uri(path) },
    "range" => { "start" => { "line" => 0, "character" => 0 },
                 "end" => { "line" => 10, "character" => 0 } },
  })
  hint = Array(response["result"]).find do |h|
    h.dig("position", "line") == 6 && h["label"].to_s.start_with?("a:")
  end
  ctx.check(hint, "no argument hint on the astral call line")
  ctx.eq(hint && hint.dig("position", "character"), 23, "inlay hint position (UTF-16)") if hint
end


add_case("utf16/selection-range") do |ctx, client|
  init!(client, ctx.root)
  path = write_fixture(ctx.root, "main.mt", UTF16_SOURCE)
  open!(client, path)
  response = client.request("textDocument/selectionRange", {
    "textDocument" => { "uri" => path_to_uri(path) },
    "positions" => [{ "line" => 5, "character" => 20 }],
  })
  range = response.dig("result", 0, "range")
  ctx.check(range, "selectionRange returned no range")
  ctx.eq(range && range.dig("start", "character"), 19, "selection range start (UTF-16)")
  ctx.eq(range && range.dig("end", "character"), 25, "selection range end (UTF-16)")
end


add_case("utf16/did-change") do |ctx, client|
  init!(client, ctx.root)
  path = write_fixture(ctx.root, "main.mt", DID_CHANGE_SOURCE)
  uri = path_to_uri(path)
  open!(client, path, version: 1)
  client.notify("textDocument/didChange", {
    "textDocument" => { "uri" => uri, "version" => 2 },
    "contentChanges" => [{
      "range" => { "start" => { "line" => 1, "character" => 19 },
                   "end" => { "line" => 1, "character" => 20 } },
      "text" => "replaced",
    }],
  })
  response = client.request("textDocument/formatting", {
    "textDocument" => { "uri" => uri },
    "options" => { "tabSize" => 4, "insertSpaces" => true },
  })
  new_text = response.dig("result", 0, "newText")
  ctx.check(new_text, "formatting returned no edit")
  if new_text
    ctx.check(new_text.include?("replaced"), "didChange did not insert the replacement text")
    ctx.check(!new_text.include?("1replaced"),
              "didChange used scalar columns: the replacement landed after the '1'")
  end
end


add_case("ascii/outputs-unchanged") do |ctx, client|
  init!(client, ctx.root)
  path = write_fixture(ctx.root, "main.mt", ASCII_SOURCE)
  uri = path_to_uri(path)
  open!(client, path)

  tokens = decode_semantic_tokens(
    Array(client.request("textDocument/semanticTokens/full",
                         { "textDocument" => { "uri" => uri } }).dig("result", "data"))
  )
  token = tokens.find { |t| t[:line] == 5 && t[:type] == 18 }
  ctx.check(token, "no string token on the ASCII line")
  ctx.eq(token && token[:length], 5, "ASCII semantic token length") if token

  range = client.request("textDocument/hover", hover_params(path, 5, 20)).dig("result", "range")
  ctx.eq(range && range.dig("start", "character"), 20, "ASCII hover range start") if range
  ctx.eq(range && range.dig("end", "character"), 26, "ASCII hover range end") if range

  message = publish_for(client, uri, 5.0, require_items: true)
  diag = Array(message&.dig("params", "diagnostics")).find do |d|
    d.dig("range", "start", "line") == 6
  end
  ctx.eq(diag && diag.dig("range", "start", "character"), 20, "ASCII diagnostic start")
end


add_case("code-action/returned-kind") do |ctx, client|
  init!(client, ctx.root)
  path = write_fixture(ctx.root, "main.mt", SIMPLE_SOURCE)
  open!(client, path)
  diag = {
    "range" => { "start" => { "line" => 0, "character" => 0 },
                 "end" => { "line" => 0, "character" => 8 } },
    "severity" => 2,
    "code" => "shadow",
    "source" => "milk-tea",
    "message" => "shadowed name",
  }
  response = client.request("textDocument/codeAction", {
    "textDocument" => { "uri" => path_to_uri(path) },
    "range" => diag["range"],
    "context" => { "diagnostics" => [diag], "only" => ["quickfix"] },
  })
  action = Array(response["result"]).first
  ctx.check(action, "no quickfix returned")
  ctx.eq(action && action["kind"], "quickfix", "returned code action kind") if action
end


add_case("completion/resolve-docs") do |ctx, client|
  init!(client, ctx.root)
  path = write_fixture(ctx.root, "main.mt", DOCS_SOURCE)
  open!(client, path)
  list = client.request("textDocument/completion", {
    "textDocument" => { "uri" => path_to_uri(path) },
    "position" => { "line" => 6, "character" => 13 },
  })
  items = list.dig("result", "items") || Array(list["result"])
  item = Array(items).find { |i| i["label"] == "foo" }
  ctx.check(item, "completion did not offer foo")
  next unless item

  resolved = client.request("completionItem/resolve", item)
  documentation = resolved.dig("result", "documentation")
  value = documentation.is_a?(Hash) ? documentation["value"] : documentation
  ctx.check(value.to_s.include?("Adds two numbers."),
            "completionItem/resolve returned no documentation for foo")
end


add_case("completion/resolve-preserves-item") do |ctx, client|
  init!(client, ctx.root)
  path = write_fixture(ctx.root, "main.mt", DOCS_SOURCE)
  open!(client, path)
  list = client.request("textDocument/completion", {
    "textDocument" => { "uri" => path_to_uri(path) },
    "position" => { "line" => 6, "character" => 13 },
  })
  items = list.dig("result", "items") || Array(list["result"])
  item = Array(items).find { |i| i["label"] == "foo" }
  ctx.check(item, "completion did not offer foo")
  next unless item

  resolved = client.request("completionItem/resolve", item).dig("result") || {}
  documentation = resolved["documentation"]
  value = documentation.is_a?(Hash) ? documentation["value"] : documentation
  ctx.check(value.to_s.include?("Adds two numbers."),
            "completionItem/resolve returned no documentation for foo")
  %w[kind detail insertText sortText data].each do |field|
    ctx.eq(resolved[field], item[field], "resolved item field #{field}")
  end
end


add_case("workspace/will-rename-files") do |ctx, client|
  init!(client, ctx.root)
  helper = write_fixture(ctx.root, "helper.mt", HELPER_SOURCE)
  user = write_fixture(ctx.root, "user.mt", USER_SOURCE)
  new_path = File.join(ctx.root, "util.mt")
  response = client.request("workspace/willRenameFiles", {
    "files" => [{ "oldUri" => path_to_uri(helper), "newUri" => path_to_uri(new_path) }],
  }, timeout: 2.0)
  ctx.check(!response["timeout"], "workspace/willRenameFiles did not respond within 2s")
  next if response["timeout"]

  edit = response.dig("result", "changes") || {}
  user_edits = edit.find { |key, _| key.end_with?("/user.mt") }&.last
  ctx.check(user_edits && !user_edits.empty?,
            "workspace/willRenameFiles returned no edit rewriting user.mt's import")
  if user_edits && !user_edits.empty?
    new_text = user_edits.first["newText"].to_s
    ctx.check(new_text.include?("util"), "import rewrite does not name util: #{new_text.inspect}")
    ctx.check(!new_text.include?("helper"), "import rewrite still names helper: #{new_text.inspect}")
  end
end


add_case("workspace/multi-root") do |ctx, client|
  root_a = File.join(ctx.root, "a")
  root_b = File.join(ctx.root, "b")
  write_fixture(root_a, "a.mt", MULTI_ROOT_A)
  write_fixture(root_b, "b.mt", MULTI_ROOT_B)
  init!(client, root_a, folders: [
         { "uri" => path_to_uri(root_a), "name" => "A" },
         { "uri" => path_to_uri(root_b), "name" => "B" },
       ])

  first = client.request("workspace/symbol", { "query" => "multi_root_b" })
  labels = Array(first["result"]).map { |s| s["name"] }
  ctx.check(labels.include?("multi_root_b"), "symbol from the added workspace folder is missing")

  client.notify("workspace/didChangeWorkspaceFolders", {
    "event" => {
      "added" => [],
      "removed" => [{ "uri" => path_to_uri(root_b), "name" => "B" }],
    },
  })
  second = client.request("workspace/symbol", { "query" => "multi_root_b" })
  labels = Array(second["result"]).map { |s| s["name"] }
  ctx.check(!labels.include?("multi_root_b"), "symbol survived removal of its workspace folder")
end


add_case("workspace/watched-files") do |ctx, client|
  path = write_fixture(ctx.root, "watched.mt", WATCHED_SOURCE)
  uri = path_to_uri(path)
  init!(client, ctx.root,
        capabilities: { "workspace" => { "didChangeWatchedFiles" => { "dynamicRegistration" => true } } })

  registration = client.wait_server_request("client/registerCapability", 2.0)
  ctx.check(registration, "no client/registerCapability after initialized")
  if registration
    methods = Array(registration.dig("params", "registrations")).map { |r| r["method"] }
    ctx.check(methods.include?("workspace/didChangeWatchedFiles"),
              "watched files were not dynamically registered: #{methods.inspect}")
  end

  client.request("workspace/symbol", { "query" => "watched_one" })
  File.write(path, WATCHED_UPDATED)
  client.notify("workspace/didChangeWatchedFiles", {
    "changes" => [{ "uri" => uri, "type" => 2 }],
  })
  response = client.request("workspace/symbol", { "query" => "watched_two" })
  labels = Array(response["result"]).map { |s| s["name"] }
  ctx.check(labels.include?("watched_two"),
            "an on-disk change did not reach the workspace index without reopening")
end


add_case("pull/document-full-unchanged") do |ctx, client|
  path = write_fixture(ctx.root, "main.mt", PULL_OPEN_SOURCE)
  uri = path_to_uri(path)
  init!(client, ctx.root, capabilities: { "textDocument" => { "diagnostic" => {} } })
  open!(client, path, version: 2)

  first = client.request("textDocument/diagnostic", { "textDocument" => { "uri" => uri } })
  ctx.eq(first.dig("result", "kind"), "full", "first pull report kind")
  ctx.check(!Array(first.dig("result", "items")).empty?, "first pull report carried no diagnostics")
  result_id = first.dig("result", "resultId")
  ctx.check(result_id, "first pull report carried no resultId")

  second = client.request("textDocument/diagnostic", {
    "textDocument" => { "uri" => uri },
    "previousResultId" => result_id,
  })
  ctx.eq(second.dig("result", "kind"), "unchanged", "repeat pull report kind")
end


add_case("pull/workspace-scope") do |ctx, client|
  open_path = write_fixture(ctx.root, "open.mt", PULL_OPEN_SOURCE)
  write_fixture(ctx.root, "closed.mt", PULL_CLOSED_SOURCE)
  init!(client, ctx.root, capabilities: { "textDocument" => { "diagnostic" => {} } })
  open!(client, open_path)

  response = client.request("workspace/diagnostic", { "previousResultIds" => [] })
  uris = Array(response.dig("result", "items")).map { |i| i["uri"] }
  ctx.check(uris.any? { |u| u.to_s.end_with?("/closed.mt") },
            "workspace/diagnostic omitted the unopened workspace file closed.mt")
end


add_case("pull/refresh-after-import-change") do |ctx, client|
  dep = write_fixture(ctx.root, "dep.mt", DEP_SOURCE)
  user = write_fixture(ctx.root, "user.mt", USER_OF_DEP_SOURCE)
  init!(client, ctx.root, capabilities: {
         "textDocument" => { "diagnostic" => {} },
         "workspace" => { "diagnostics" => { "refreshSupport" => true } },
       })
  open!(client, user)
  open!(client, dep)
  client.notify("textDocument/didChange", {
    "textDocument" => { "uri" => path_to_uri(dep), "version" => 2 },
    "contentChanges" => [{ "text" => DEP_UPDATED }],
  })
  refresh = client.wait_server_request("workspace/diagnostic/refresh", 2.0)
  ctx.check(refresh, "no workspace/diagnostic/refresh after a dependency change")
end


add_case("publish/diagnostics-version") do |ctx, client|
  path = write_fixture(ctx.root, "main.mt", ERROR_SOURCE)
  uri = path_to_uri(path)
  init!(client, ctx.root)
  open!(client, path, version: 9)
  message = publish_for(client, uri, 5.0, require_items: true)
  ctx.check(message, "no diagnostics published")
  ctx.eq(message&.dig("params", "version"), 9, "publishDiagnostics.version") if message
end


add_case("lifecycle/pre-init-request") do |ctx, client|
  response = client.request("textDocument/hover", hover_params(File.join(ctx.root, "main.mt"), 0, 0))
  ctx.eq(response.dig("error", "code"), -32_002, "request before initialize")
end


add_case("lifecycle/duplicate-initialize") do |ctx, client|
  init!(client, ctx.root)
  response = client.request("initialize", {
    "processId" => nil,
    "rootUri" => path_to_uri(ctx.root),
    "capabilities" => {},
  })
  ctx.eq(response.dig("error", "code"), -32_600, "second initialize")
end


add_case("lifecycle/post-shutdown-request") do |ctx, client|
  init!(client, ctx.root)
  client.request("shutdown", nil)
  response = client.request("textDocument/hover", hover_params(File.join(ctx.root, "main.mt"), 0, 0))
  ctx.eq(response.dig("error", "code"), -32_600, "request after shutdown")
end


add_case("lifecycle/exit-without-shutdown") do |ctx, client|
  init!(client, ctx.root)
  client.notify("exit", {})
  ctx.eq(client.wait_for_exit(3.0), 1, "exit status without shutdown")
end


add_case("lifecycle/exit-after-shutdown") do |ctx, client|
  init!(client, ctx.root)
  client.request("shutdown", nil)
  client.notify("exit", {})
  ctx.eq(client.wait_for_exit(3.0), 0, "exit status after shutdown")
end


add_case("cancel/completed-id-reuse") do |ctx, client|
  path = write_fixture(ctx.root, "main.mt", SIMPLE_SOURCE)
  init!(client, ctx.root)
  open!(client, path)

  first = client.request("textDocument/hover", hover_params(path, 1, 9), id: 7)
  ctx.check(!first["error"] && !first["timeout"], "the first request did not complete")
  client.notify("$/cancelRequest", { "id" => 7 })
  second = client.request("textDocument/hover", hover_params(path, 1, 9), id: 7)
  ctx.check(second.dig("error", "code") != -32_800,
            "a completed request id cancelled a later request that reused it")
end


# ── runner ──────────────────────────────────────────────────────────────────

class CaseReport
  attr_reader :name, :failures, :notes
  attr_accessor :error, :duration, :stderr

  def initialize(name)
    @name = name
    @failures = []
    @notes = []
    @stderr = []
    @duration = 0.0
    @error = nil
  end

  def passed?
    @failures.empty? && @error.nil?
  end
end


def run_case(case_def, bin)
  report = CaseReport.new(case_def[:name])
  root = File.join(WORK_ROOT, case_def[:name].tr("/", "-"))
  FileUtils.rm_rf(root)
  FileUtils.mkdir_p(root)
  ctx = CaseContext.new(root)
  client = nil
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  begin
    client = LspClient.new(bin, case_def[:timeout] || DEFAULT_TIMEOUT)
    case_def[:run].call(ctx, client)
  rescue StandardError => e
    location = e.backtrace&.first.to_s.sub("#{ROOT}/", "")
    report.error = "#{e.class}: #{e.message} (#{location})"
  ensure
    client&.close
    report.duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    report.failures.concat(ctx.failures)
    report.notes.concat(ctx.notes)
    report.stderr = client&.stderr_lines || []
  end

  report
end


def main(argv)
  bin = DEFAULT_BIN
  only = nil
  timeout = DEFAULT_TIMEOUT
  json_out = nil

  until argv.empty?
    arg = argv.shift
    case arg
    when "--bin" then bin = argv.shift
    when "--only" then only = argv.shift
    when "--timeout" then timeout = argv.shift.to_f
    when "--json" then json_out = argv.shift
    when "-h", "--help" then return usage(0)
    else
      warn "lsp_conformance: unknown option #{arg}"
      return usage(2)
    end
  end

  unless File.executable?(bin)
    warn "lsp_conformance: no executable at #{bin}"
    return 2
  end

  FileUtils.rm_rf(WORK_ROOT)
  FileUtils.mkdir_p(WORK_ROOT)

  selected = CASES.select { |c| only.nil? || c[:name].include?(only) }
  if selected.empty?
    warn "lsp_conformance: no cases match #{only.inspect}"
    return 2
  end

  reports = selected.map do |case_def|
    case_def[:timeout] = timeout if case_def[:timeout].nil? && timeout != DEFAULT_TIMEOUT
    run_case(case_def, bin)
  end

  reports.each do |report|
    if report.passed?
      puts "ok    #{report.name}"
    else
      puts "FAIL  #{report.name}"
      report.failures.each { |failure| puts "        #{failure}" }
      report.error&.then { |error| puts "        #{error}" }
      unless report.stderr.empty?
        puts "        server stderr: #{report.stderr.last(3).join.strip[0, 500]}"
      end
    end
  end

  passed = reports.count(&:passed?)
  failed = reports.size - passed
  puts
  puts "lsp conformance: #{passed} passed, #{failed} failed (#{reports.size} cases)"

  if json_out
    payload = {
      "bin" => bin,
      "passed" => passed,
      "failed" => failed,
      "total" => reports.size,
      "cases" => reports.map do |report|
        {
          "name" => report.name,
          "passed" => report.passed?,
          "failures" => report.failures,
          "error" => report.error,
          "stderr" => report.stderr,
          "duration_ms" => (report.duration * 1000).round(1),
        }
      end,
    }
    FileUtils.mkdir_p(File.dirname(File.expand_path(json_out)))
    File.write(json_out, JSON.pretty_generate(payload))
    puts "wrote #{json_out}"
  end

  failed.zero? ? 0 : 1
end


def usage(status)
  puts <<~TEXT
    usage: ruby tools/lsp_conformance.rb [--bin PATH] [--only PATTERN]
                                          [--timeout SEC] [--json OUT]
  TEXT
  status
end


exit(main(ARGV)) if $PROGRAM_NAME == __FILE__
