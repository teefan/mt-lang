#!/usr/bin/env ruby
# frozen_string_literal: true

# lsp_parity — drive the same JSON-RPC corpus through the Ruby host LSP and the
# self-host LSP (`mtc lsp`), recording normalized responses so the two can be
# compared endpoint by endpoint.
#
# Usage:
#   ruby tools/lsp_parity.rb record --server host  --out /tmp/host.json
#   ruby tools/lsp_parity.rb record --server self  --out /tmp/self.json
#   ruby tools/lsp_parity.rb compare /tmp/host.json /tmp/self.json [--full]
#
# Options for `record`:
#   --server host|self|PATH   server to drive (default: host)
#   --self PATH               self-host binary (default: build/stage2/mtc)
#   --out FILE                where the recording is written (required)
#   --timeout SEC             per-request timeout (default: 20)
#   --stress                  also run the stress sequence (rapid edits, odd
#                             positions, malformed input) and record outcomes

require "cgi/escape"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "timeout"

ROOT = File.expand_path("..", __dir__)

MAIN_SOURCE = <<~MT
  import mod_alpha as alpha
  import mod_beta as beta

  ## A sample struct.
  ## @param x the x value
  struct Sample:
      x: int
      y: int

  extending Sample:
      function sum() -> int:
          return this.x + this.y

  interface Shape:
      function area() -> float

  struct Circle implements Shape:
      radius: float

  extending Circle:
      function area() -> float:
          return 3.14159 * this.radius * this.radius

  enum Color:
      red
      green
      blue

  variant Token:
      ident(text: str)
      eof

  function compute(a: int, b: int) -> int:
      return a + b

  function main() -> int:
      var total: int = 0
      let s = Sample(x = 1, y = 2)
      total += s.sum()
      total += compute(3, 4)
      total += alpha.fn_alpha(10)
      let c = Circle(radius = 1.0)
      let area = c.area()
      let _a = area
      let asset = "assets/file.txt"
      let _asset = asset
      return total
MT

ALPHA_SOURCE = <<~MT
  ## Alpha helper module.
  public function fn_alpha(value: int) -> int:
      return value * 2

  public struct Widget:
      size: int

  extending Widget:
      function grow() -> int:
          return this.size + 1
MT

BETA_SOURCE = <<~MT
  ## Beta helper module.
  public function fn_beta(value: int) -> int:
      return value + 3
MT

def path_to_uri(path)
  "file://#{path.split("/").map { |seg| CGI.escape(seg).gsub("+", "%20") }.join("/")}"
end

def build_workspace(dir)
  FileUtils.mkdir_p(File.join(dir, "mod_alpha"))
  FileUtils.mkdir_p(File.join(dir, "mod_beta"))
  FileUtils.mkdir_p(File.join(dir, "assets"))
  paths = {
    alpha: File.join(dir, "mod_alpha", "lib.mt"),
    beta: File.join(dir, "mod_beta", "lib.mt"),
    main: File.join(dir, "main.mt"),
    scratch: File.join(dir, "scratch.mt"),
  }
  File.write(paths[:alpha], ALPHA_SOURCE)
  File.write(paths[:beta], BETA_SOURCE)
  File.write(paths[:main], MAIN_SOURCE)
  File.write(paths[:scratch], "function scratch_fn() -> int:\n    return 1\n")
  File.write(File.join(dir, "assets", "file.txt"), "hello\n")
  paths
end

# Replace volatile content so a host/self diff shows behavioural differences
# only: the (fixed) workspace path, fingerprint-style result ids, and the
# semantic-token legend indices (compared as decoded entries instead).
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
    value.gsub(workspace, "<WS>").gsub(%r{file://<WS>}, "file://<WS>")
  else
    value
  end
end

# Decode `semanticTokens` data with the server's own legend so token *types*
# compare by name rather than by legend index.
def decode_semantic_tokens(recording, request_label, legend)
  data = recording.dig("requests", request_label, "result", "data")
  return nil unless data.is_a?(Array) && legend

  types = legend["tokenTypes"]
  line = 0
  char = 0
  data.each_slice(5).map do |dl, ds, len, type_idx, mods|
    line += dl
    char = dl.zero? ? char + ds : ds
    { "line" => line, "char" => char, "len" => len, "type" => types[type_idx] || type_idx, "mods" => mods }
  end
end

# 0-based [line, col] of the first occurrence of +marker+ (+within+ narrows the
# searched lines).
def find_pos(source, marker, within: nil, column_offset: 0)
  lines = source.split("\n", -1)
  idx = if within
          lines.index { |l| l.include?(marker) && l.include?(within) }
        else
          lines.index { |l| l.include?(marker) }
        end
  return nil unless idx

  col = lines[idx].index(marker)
  return nil unless col

  [idx, col + column_offset]
end

class LspClient
  attr_reader :stderr_lines

  def initialize(stdin, stdout, stderr_read, timeout_s)
    @stdin = stdin
    @stdout = stdout
    @stderr_read = stderr_read
    @timeout_s = timeout_s
    @next_id = 1
    @stderr_lines = []
    @notifications = []
  end

  def request(method, params)
    id = @next_id
    @next_id += 1
    write({ "jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params })
    read_until(id)
  end

  def notify(method, params)
    write({ "jsonrpc" => "2.0", "method" => method, "params" => params })
  end

  def drain_notifications
    out = @notifications.dup
    @notifications.clear
    out
  end

  def write(message)
    json = JSON.dump(message)
    @stdin.write("Content-Length: #{json.bytesize}\r\n\r\n#{json}")
    @stdin.flush
  end

  def read_until(id)
    Timeout.timeout(@timeout_s) do
      loop do
        message = read_message
        return { "timeout" => true } if message.nil?
        next if message["method"] && !message.key?("id")

        if message["method"]
          @notifications << { "method" => message["method"], "params" => message["params"] }
          answer_server_request(message)
          next
        end
        return message if message["id"] == id
      end
    end
  rescue Timeout::Error
    { "timeout" => true }
  end

  # A real client answers server→client requests; the self-host blocks its
  # `milkTea/documentContext` reply on the `workspace/configuration` pull, so an
  # unanswered request would look like a hang.
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
    @server_requests ||= []
    @server_requests << { "method" => message["method"], "params" => message["params"] }
  end

  def server_requests
    @server_requests || []
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
    rescue JSON::ParserError => e
      dump = File.join(ROOT, "tmp", "lsp-frame-error.bin")
      File.binwrite(dump, body.to_s)
      raise JSON::ParserError, "#{e.message} (declared=#{length} read=#{body.to_s.bytesize}, dumped to #{dump})"
    end
  end

  def collect_stderr
    return unless @stderr_read

    while (line = @stderr_read.read_nonblock(65_536, exception: false)) && line != :wait_readable
      @stderr_lines.concat(line.lines)
    end
  rescue IOError, EOFError, Errno::EIO
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

# ── corpus ───────────────────────────────────────────────────────────────────

def corpus(dir, paths)
  main_uri = path_to_uri(paths[:main])
  alpha_uri = path_to_uri(paths[:alpha])
  beta_uri = path_to_uri(paths[:beta])
  scratch_uri = path_to_uri(paths[:scratch])
  tc = { "textDocument" => { "uri" => main_uri } }
  at = lambda { |marker, within: nil, off: 0|
    line, col = find_pos(MAIN_SOURCE, marker, within: within)
    raise "marker not found: #{marker}" unless line

    { "textDocument" => { "uri" => main_uri }, "position" => { "line" => line, "character" => col + off } }
  }
  requests = {}
  requests["initialize"] = ["initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} }]
  requests["hover/function-call"] = ["textDocument/hover", at.call("compute(3, 4)")]
  requests["hover/struct"] = ["textDocument/hover", at.call("struct Sample", within: nil)]
  requests["hover/local"] = ["textDocument/hover", at.call("let s = Sample")]
  requests["hover/method-call"] = ["textDocument/hover", at.call("s.sum()")]
  requests["hover/imported-fn"] = ["textDocument/hover", at.call("alpha.fn_alpha")]
  requests["hover/field"] = ["textDocument/hover", at.call("x = 1, y = 2")]
  requests["hover/keyword"] = ["textDocument/hover", { "textDocument" => { "uri" => main_uri }, "position" => { "line" => 0, "character" => 0 } }]
  requests["definition/compute"] = ["textDocument/definition", at.call("compute(3, 4)")]
  requests["definition/local"] = ["textDocument/definition", at.call("total += s.sum()", within: nil)]
  requests["definition/imported"] = ["textDocument/definition", at.call("alpha.fn_alpha")]
  requests["declaration/struct"] = ["textDocument/declaration", at.call("Sample(x = 1")]
  requests["typeDefinition/circle"] = ["textDocument/typeDefinition", at.call("Circle(radius")]
  requests["implementation/area"] = ["textDocument/implementation", at.call("c.area()")]
  requests["references/compute"] = ["textDocument/references", at.call("compute(3, 4)").merge("context" => { "includeDeclaration" => true })]
  requests["references/sum"] = ["textDocument/references", at.call("s.sum()").merge("context" => { "includeDeclaration" => true })]
  requests["documentHighlight"] = ["textDocument/documentHighlight", at.call("total += s.sum()", off: 0)]
  requests["documentSymbol"] = ["textDocument/documentSymbol", tc]
  requests["foldingRange"] = ["textDocument/foldingRange", tc]
  requests["selectionRange"] = ["textDocument/selectionRange", { "textDocument" => { "uri" => main_uri }, "positions" => [at.call("total += s.sum()")["position"]] }]
  requests["completion/member"] = ["textDocument/completion", at.call("s.sum()", off: 2)]
  requests["completion/import-member"] = ["textDocument/completion", at.call("alpha.fn_alpha", off: 6)]
  requests["completion/top-level"] = ["textDocument/completion", at.call("return total")]
  requests["completion/struct-field"] = ["textDocument/completion", at.call("Sample(x = 1", off: 8)]
  requests["signatureHelp"] = ["textDocument/signatureHelp", at.call("compute(3, 4)", off: 8)]
  requests["prepareRename"] = ["textDocument/prepareRename", at.call("s.sum()", off: 2)]
  requests["rename"] = ["textDocument/rename", at.call("s.sum()", off: 2).merge("newName" => "renamed_sum")]
  requests["linkedEditingRange"] = ["textDocument/linkedEditingRange", at.call("total += s.sum()")]
  requests["inlayHint"] = ["textDocument/inlayHint", { "textDocument" => { "uri" => main_uri }, "range" => { "start" => { "line" => 0, "character" => 0 }, "end" => { "line" => 40, "character" => 0 } } }]
  requests["semanticTokens/full"] = ["textDocument/semanticTokens/full", tc]
  requests["semanticTokens/range"] = ["textDocument/semanticTokens/range", tc.merge("range" => { "start" => { "line" => 0, "character" => 0 }, "end" => { "line" => 40, "character" => 0 } })]
  requests["codeLens"] = ["textDocument/codeLens", tc]
  requests["codeAction"] = ["textDocument/codeAction", tc.merge("range" => { "start" => { "line" => 0, "character" => 0 }, "end" => { "line" => 40, "character" => 0 } }, "context" => { "diagnostics" => [] })]
  requests["documentLink"] = ["textDocument/documentLink", tc]
  requests["prepareCallHierarchy"] = ["textDocument/prepareCallHierarchy", at.call("compute(3, 4)")]
  requests["prepareTypeHierarchy"] = ["textDocument/prepareTypeHierarchy", at.call("struct Circle", within: nil)]
  requests["diagnostic/pull"] = ["textDocument/diagnostic", tc]
  requests["workspace/diagnostic"] = ["workspace/diagnostic", {}]
  requests["milkTea/documentContext"] = ["milkTea/documentContext", tc]
  requests["milkTea/debugInfo"] = ["milkTea/debugInfo", tc]
  requests["workspace/symbol"] = ["workspace/symbol", { "query" => "compute" }]
  requests["formatting"] = ["textDocument/formatting", tc.merge("options" => { "tabSize" => 4, "insertSpaces" => true })]
  requests["rangeFormatting"] = ["textDocument/rangeFormatting", tc.merge("range" => { "start" => { "line" => 10, "character" => 0 }, "end" => { "line" => 12, "character" => 0 } }, "options" => { "tabSize" => 4, "insertSpaces" => true })]
  requests["onTypeFormatting"] = ["textDocument/onTypeFormatting", { "textDocument" => { "uri" => main_uri }, "position" => { "line" => 14, "character" => 0 }, "ch" => "\n", "options" => { "tabSize" => 4, "insertSpaces" => true } }]
  requests["willSaveWaitUntil"] = ["textDocument/willSaveWaitUntil", tc.merge("reason" => 1)]
  requests["foldingRange/scratch"] = ["textDocument/foldingRange", { "textDocument" => { "uri" => scratch_uri } }]
  requests["hover/alpha"] = ["textDocument/hover", { "textDocument" => { "uri" => alpha_uri }, "position" => { "line" => 1, "character" => 10 } }]
  requests["documentSymbol/beta"] = ["textDocument/documentSymbol", { "textDocument" => { "uri" => beta_uri } }]
  requests
end

def run_corpus(client, dir, paths)
  recordings = {}
  init = client.request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
  recordings["initialize"] = init
  client.notify("initialized", {})
  client.notify("textDocument/didOpen", { "textDocument" => { "uri" => path_to_uri(paths[:main]), "languageId" => "milk-tea", "version" => 1, "text" => MAIN_SOURCE } })
  client.notify("textDocument/didOpen", { "textDocument" => { "uri" => path_to_uri(paths[:alpha]), "languageId" => "milk-tea", "version" => 1, "text" => ALPHA_SOURCE } })
  client.notify("textDocument/didOpen", { "textDocument" => { "uri" => path_to_uri(paths[:beta]), "languageId" => "milk-tea", "version" => 1, "text" => BETA_SOURCE } })
  client.notify("textDocument/didOpen", { "textDocument" => { "uri" => path_to_uri(paths[:scratch]), "languageId" => "milk-tea", "version" => 1, "text" => "function scratch_fn() -> int:\n    return 1\n" } })
  # Let the background diagnostics worker settle, and pull diagnostics once per
  # document so facts are materialized in a deterministic order.
  sleep 1.0

  corpus(dir, paths).each do |label, (method, params)|
    next if label == "initialize"

    recordings[label] = client.request(method, params)
  end

  # The resolve endpoints and post-open notifications a real editor sends:
  # VS Code resolves fresh code lenses, document links and completion items
  # itself, and notifies on save / watched-file changes / configuration.
  # Derived payloads come from the responses the two servers just produced.
  lens = Array(recordings.dig("codeLens", "result")).first
  recordings["codeLens/resolve"] = client.request("codeLens/resolve", lens) if lens

  item = Array(recordings.dig("completion/member", "result", "items")).first
  recordings["completionItem/resolve"] = client.request("completionItem/resolve", item) if item

  link = Array(recordings.dig("documentLink", "result")).first
  recordings["documentLink/resolve"] = client.request("documentLink/resolve", link) if link

  client.notify("$/setTrace", { "value" => "off" })
  client.notify("textDocument/didSave", { "textDocument" => { "uri" => path_to_uri(paths[:main]) }, "text" => MAIN_SOURCE })
  client.notify("milkTea/documentContext", { "textDocument" => { "uri" => path_to_uri(paths[:main]) }, "source" => "active-editor" })

  recordings
end

# ── stress ───────────────────────────────────────────────────────────────────

def run_stress(client, dir, paths)
  main_uri = path_to_uri(paths[:main])
  outcomes = {}
  version = 100

  # 1. rapid incremental edits on the open document, then a hover
  body = MAIN_SOURCE.dup
  insert_at = find_pos(body, "return total")
  line, col = insert_at
  range = { "start" => { "line" => line, "character" => col }, "end" => { "line" => line, "character" => col } }
  20.times do |i|
    version += 1
    client.notify("textDocument/didChange", {
      "textDocument" => { "uri" => main_uri, "version" => version },
      "contentChanges" => [{ "range" => range, "text" => "let __stress_#{i} = #{i}\n" }],
    })
  end
  outcomes["stress/rapid-didChange+hover"] = client.request("textDocument/hover", { "textDocument" => { "uri" => main_uri }, "position" => { "line" => line, "character" => col + 4 } })

  # 2. full-document replacement edits
  5.times do |i|
    version += 1
    client.notify("textDocument/didChange", {
      "textDocument" => { "uri" => main_uri, "version" => version },
      "contentChanges" => [{ "text" => "#{MAIN_SOURCE}\n# edit #{i}\n" }],
    })
  end
  outcomes["stress/full-didChange+symbols"] = client.request("textDocument/documentSymbol", { "textDocument" => { "uri" => main_uri } })

  # 3. positions far outside the document, negative and huge
  [ -5, 9_999, 0 ].each_with_index do |line_no, i|
    outcomes["stress/out-of-range-#{i}"] = client.request("textDocument/hover", { "textDocument" => { "uri" => main_uri }, "position" => { "line" => line_no, "character" => 9_999 } })
  end

  # 4. malformed / unknown requests
  outcomes["stress/unknown-method"] = client.request("textDocument/definitelyNotAMethod", {})
  outcomes["stress/missing-params"] = client.request("textDocument/hover", {})
  outcomes["stress/wrong-param-type"] = client.request("textDocument/hover", { "textDocument" => { "uri" => main_uri }, "position" => "not-a-position" })
  outcomes["stress/unknown-document"] = client.request("textDocument/hover", { "textDocument" => { "uri" => path_to_uri(File.join(dir, "missing.mt")) }, "position" => { "line" => 0, "character" => 0 } })

  # 5. unclosed / unterminated edits (parser recovery paths)
  version += 1
  client.notify("textDocument/didChange", {
    "textDocument" => { "uri" => main_uri, "version" => version },
    "contentChanges" => [{ "text" => "function broken(\n    if (\n        \"unterminated\n" }],
  })
  outcomes["stress/unterminated-source+diagnostic"] = client.request("textDocument/diagnostic", { "textDocument" => { "uri" => main_uri } })
  outcomes["stress/unterminated-source+tokens"] = client.request("textDocument/semanticTokens/full", { "textDocument" => { "uri" => main_uri } })

  # 6. multi-byte / emoji positions
  version += 1
  client.notify("textDocument/didChange", {
    "textDocument" => { "uri" => main_uri, "version" => version },
    "contentChanges" => [{ "text" => "function main() -> int:\n    let s = \"héllo 🌍 wörld\"\n    let n = s.len\n    return n\n" }],
  })
  outcomes["stress/unicode+semanticTokens"] = client.request("textDocument/semanticTokens/full", { "textDocument" => { "uri" => main_uri } })
  outcomes["stress/unicode+hover-mid-char"] = client.request("textDocument/hover", { "textDocument" => { "uri" => main_uri }, "position" => { "line" => 1, "character" => 14 } })
  outcomes["stress/unicode+completion"] = client.request("textDocument/completion", { "textDocument" => { "uri" => main_uri }, "position" => { "line" => 2, "character" => 14 } })

  # 7. rapid open/close cycles
  5.times do |i|
    uri = path_to_uri(File.join(dir, "cycle_#{i}.mt"))
    client.notify("textDocument/didOpen", { "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => MAIN_SOURCE } })
    client.notify("textDocument/didClose", { "textDocument" => { "uri" => uri } })
  end
  outcomes["stress/open-close+hover"] = client.request("textDocument/hover", { "textDocument" => { "uri" => main_uri }, "position" => { "line" => 0, "character" => 0 } })

  # 8. cache-invalidating client notifications, after the measured probes so
  # they cannot perturb them (they are here for crash coverage).
  client.notify("workspace/didChangeConfiguration", { "settings" => { "milkTea" => { "format" => { "mode" => "tidy" } } } })
  client.notify("workspace/didChangeWatchedFiles", { "changes" => [{ "uri" => main_uri, "type" => 2 }] })
  client.notify("workspace/didChangeWorkspaceFolders", { "event" => { "added" => [], "removed" => [] } })
  client.notify("workspace/willRenameFiles", { "files" => [{ "oldUri" => main_uri, "newUri" => path_to_uri(File.join(dir, "renamed.mt")) }] })

  outcomes
end

# ── main ─────────────────────────────────────────────────────────────────────

mode = ARGV.shift
case mode
when "record"
  server = "host"
  self_bin = File.join(ROOT, "build", "stage2", "mtc")
  out_path = nil
  timeout_s = 20
  stress = false
  workspace = File.join(ROOT, "tmp", "lsp-parity-ws")
  until ARGV.empty?
    a = ARGV.shift
    case a
    when "--server" then server = ARGV.shift
    when "--self" then self_bin = ARGV.shift
    when "--out" then out_path = ARGV.shift
    when "--timeout" then timeout_s = ARGV.shift.to_i
    when "--workspace" then workspace = ARGV.shift
    when "--stress" then stress = true
    else abort "unknown option: #{a}"
    end
  end
  abort "record requires --out FILE" unless out_path

  recording = { "server" => server, "requests" => {}, "stress" => {}, "crashed" => false, "stderr" => [] }
  FileUtils.rm_rf(workspace)
  FileUtils.mkdir_p(workspace)
  paths = build_workspace(workspace)
  pid, stdin, stdout, stderr_read = spawn_server(server, self_bin)
  client = LspClient.new(stdin, stdout, stderr_read, timeout_s)
  begin
    recording["requests"] = run_corpus(client, workspace, paths)
    recording["stress"] = run_stress(client, workspace, paths) if stress
  rescue StandardError => e
    recording["crashed"] = true
    recording["error"] = "#{e.class}: #{e.message}"
  ensure
    client.collect_stderr
    recording["stderr"] = client.stderr_lines.last(400)
    recording["exit"] = begin
      Process.waitpid(pid, Process::WNOHANG) ? $?.exitstatus : nil
    rescue Errno::ECHILD
      nil
    end
    shutdown(pid, stdin, stdout, stderr_read)
  end
  recording["legend"] = recording.dig("requests", "initialize", "result", "capabilities",
                                      "semanticTokensProvider", "legend")
  recording["requests"] = normalize(recording["requests"], workspace)
  recording["stress"] = normalize(recording["stress"], workspace)
  File.write(out_path, JSON.pretty_generate(recording))
  puts "recorded #{recording['requests'].size} requests + #{recording['stress'].size} stress probes -> #{out_path}"
  puts "server stderr lines: #{recording['stderr'].size}"
  puts "timed-out requests: #{recording['requests'].count { |_k, v| v.is_a?(Hash) && v['timeout'] }}"
  puts "CRASHED: #{recording['error']}" if recording["crashed"]
when "compare"
  a_path, b_path = ARGV.shift, ARGV.shift
  full = ARGV.delete("--full")
  a = JSON.parse(File.read(a_path))
  b = JSON.parse(File.read(b_path))

  # Capabilities first: a whole-object diff, reported as per-key differences.
  cap_a = a.dig("requests", "initialize", "result", "capabilities") || {}
  cap_b = b.dig("requests", "initialize", "result", "capabilities") || {}
  cap_keys = (cap_a.keys | cap_b.keys).sort
  cap_diffs = cap_keys.reject { |k| cap_a[k] == cap_b[k] }
  puts "capabilities: #{cap_keys.size} keys, #{cap_diffs.size} differ"
  cap_diffs.each do |k|
    printf("  ── %-32s host=%s\n     %-32s self=%s\n", k, JSON.dump(cap_a[k])[0, 200], "", JSON.dump(cap_b[k])[0, 200])
  end

  legend_a = a["legend"]
  legend_b = b["legend"]
  token_labels = %w[semanticTokens/full semanticTokens/range]
  token_diffs = []
  token_labels.each do |label|
    da = decode_semantic_tokens(a, label, legend_a)
    db = decode_semantic_tokens(b, label, legend_b)
    next if da == db

    token_diffs << label
    if full
      puts "  ── #{label} decoded (host #{da&.size} vs self #{db&.size} tokens)"
      puts "     host: #{JSON.dump(da)[0, 500]}"
      puts "     self: #{JSON.dump(db)[0, 500]}"
    end
  end

  sections = [["requests", a["requests"], b["requests"]], ["stress", a["stress"], b["stress"]]]
  total_diff = cap_diffs.size + token_diffs.size
  sections.each do |name, left, right|
    next if left.nil? || right.nil?

    keys = (left.keys | right.keys)
    diffs = keys.select do |k|
      next false if token_labels.include?(k) # compared decoded above

      a_val = left[k]
      b_val = right[k]
      a_val = a_val.merge("result" => "«decoded-tokens»") if token_labels.include?(k) && a_val.is_a?(Hash)
      a_val != b_val
    end
    total_diff += diffs.size
    puts "#{name}: #{left.size} vs #{right.size} recorded, #{diffs.size} differ"
    diffs.each do |k|
      puts "  ── #{k}"
      if full
        puts "     host: #{JSON.dump(left[k])[0, 900]}"
        puts "     self: #{JSON.dump(right[k])[0, 900]}"
      else
        puts "     host: #{JSON.dump(left[k])[0, 220]}"
        puts "     self: #{JSON.dump(right[k])[0, 220]}"
      end
    end
  end
  puts "TOTAL differing entries: #{total_diff}"
  exit(total_diff.zero? ? 0 : 1)
else
  abort "usage: lsp_parity.rb record --server host|self --out FILE [--stress] | compare A B"
end
