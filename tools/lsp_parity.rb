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
  import flat_mod

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
      let _color = Color.green
      total += alpha.fn_alpha(10)
      total += flat_mod.flat_fn(5)
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

# A flat (`.mt` file) module — the directory-shaped `mod_alpha/lib.mt` pair is
# not linked by the host's import-dependency graph, so a cross-file rename needs
# a module name the graph can match.
FLAT_SOURCE = <<~MT
  public function flat_fn(value: int) -> int:
      return value + 2
MT

# A std-generic fixture: the locals' inferred types come from imported generic
# methods (`vec.Vec[int].create()` -> `Vec[int]`, `v.get(0)` -> `ptr[int]?`) and
# from a method another module extends onto the type (`v.iter()` in std.iter ->
# `Iter[int]`), which the outline's `detail` must render as the host does.
# A resolvable import pair (`helper.mt` is what `import helper` names, unlike
# the directory-shaped `mod_alpha/lib.mt`): cross-file references must come from
# the declaration's import dependents, as the host's
# `reverse_import_dependents_for` does.
HELPER_SOURCE = <<~MT
  public function helper_sum(a: int, b: int) -> int:
      return a + b
MT

USER_SOURCE = <<~MT
  import helper

  function user_call() -> int:
      return int<-helper_sum(1, 2)
MT

# Generic declarations and function-typed members: the outline must render the
# host's shapes — type parameters as `TypeParameter` (kind 26) children with no
# detail, `fn(int) -> bool` without parameter names, and no `static`/`mut`
# prefix on methods (only `async`).
GENERICS_SOURCE = <<~MT
  public struct Pair[A, B]:
      left: A
      right: B
      cb: fn(value: A) -> bool

  public variant Maybe[T]:
      Some(value: T)
      None

  public flags Level:
      low = 1
      high = 2

  extending Pair[A, B]:
      public static function of(left: A, right: B) -> Pair[A, B]:
          return Pair[A, B](left = left, right = right, cb = always)

      public editable function swap(self: ref[Pair[A, B]]) -> void:
          let tmp = self.left
          self.left = self.right
          self.right = tmp

      public async function fetch(self: ref[Pair[A, B]]) -> int:
          return 1

  public function always(value: int) -> bool:
      return true

  public function make[A](value: A) -> Pair[A, int]:
      return Pair[A, int](left = value, right = 0, cb = always)
MT

CONTAINERS_SOURCE = <<~MT
  import std.vec as vec

  function containers_demo() -> int:
      let v = vec.Vec[int].create()
      let elem = v.get(0)
      let n = v.len()
      let as_iter = v.iter()
      let _elem = elem
      let _iter = as_iter
      return int<-n

  # `var` plus an `editable` method call: correct code the host does not warn
  # about, so prefer-let must not fire either.
  function containers_mutating() -> int:
      var v = vec.Vec[int].create()
      v.push(1)
      let n = v.len()
      v.release()
      return int<-n
MT

# Inlay-hint cases: argument-name hints through direct and receiver-method
# callees, self-describing arguments, and a function whose return type is not
# written (the host emits a `-> T` hint for the non-void ones).  Self-contained:
# an import would drag the fixture's import-resolution diagnostics into the
# workspace-diagnostic entry.
INLAY_SOURCE = <<~MT
  function inlay_compute(a: int, b: int) -> int:
      return a + b

  struct Sample:
      x: int
      y: int

  extending Sample:
      function sum() -> int:
          return this.x + this.y

      function scale(f: int) -> int:
          return this.x * f

  async function af_noarrow():
      return

  function main() -> int:
      let s = Sample(x = 1, y = 2)
      let total = s.sum()
      total += inlay_compute(3, 4)
      let scaled = s.scale(2)
      let _scaled = scaled
      return total
MT

# A reserved-primitive-name binding with uses: the code action renames the
# declaration and every site in one action.
RESERVED_SOURCE = <<~MT
  function int(a: int, b: int) -> int:
      return a + b

  function main() -> int:
      let x = int(1, 2)
      return x
MT

# Format-string interpolation: a cursor inside `#{loc}` must complete the
# enclosing function's locals (sort `2_`) rather than the global bucket.
FORMAT_SOURCE = <<~'MT'
  function format_demo(seed: int) -> int:
      let local_value = seed + 1
      let msg = f"value #{local_value}"
      return local_value
MT

# An imported struct with a field of an imported generic type: a
# `ref[ImportedStruct]` receiver completes its fields, and a method reached
# through the field (`r.lookup.len()`) resolves through the chain.  The holder
# module is imported, not opened, so only the requests below touch it.
HOLDING_SOURCE = <<~MT
  import std.map as map_mod

  public struct Holder:
      lookup: map_mod.Map[str, int]

  extending Holder:
      public function put(key: str, value: int) -> void:
          this.lookup.set(key, value)
MT

IMPORTED_SOURCE = <<~MT
  import mod_holding as holding

  function imported_demo(r: ref[holding.Holder], h: holding.Holder) -> int:
      let via_ref = r.lookup.len()
      let via_value = h.lookup.len()
      let _via_ref = via_ref
      let _via_value = via_value
      return 0
MT

# A package with its own `source_root`: a bare `import local_mod` resolves from
# the requesting file's package root, and a match-arm payload binding's fields
# hover from the arm's recorded payload type.
PACKAGE_MANIFEST = <<~MT
  [package]
  name = "probe_pkg"
  version = "0.1.0"
  source_root = "src"
MT

PACKAGE_LOCAL_SOURCE = <<~MT
  public variant Local:
      one(value: int)
      two

  public struct Box:
      value: int

  extending Box:
      public function get() -> int:
          return this.value
MT

PACKAGE_USER_SOURCE = <<~MT
  import local_mod as local

  function pkg_demo(v: local.Local) -> int:
      match v:
          local.Local.one as o:
              return o.value
          local.Local.two:
              return 0

  function box_demo(b: local.Box) -> int:
      return b.get()
MT

# A `str` receiver's extending method (`equal` in std.str) and the same call
# through a struct field, so the builtin-`str` type key and the field-chain walk
# are both exercised.  The guarded locals (`var x = … else:`) pin the narrowed
# binding type: their member calls resolve through the success type, not the
# initializer's `Option[…]`/`T?`.
STR_METHOD_SOURCE = <<~MT
  import std.string as string

  function str_eq(a: str, b: str) -> bool:
      return a.equal(b)

  struct Named:
      name: str

  function named_eq(n: Named) -> bool:
      return n.name.equal("x")

  struct Holder:
      size: int

  extending Holder:
      function doubled() -> int:
          return this.size * 2

  function maybe_holder() -> Holder?:
      return null

  function guarded_holder() -> int:
      var holder = maybe_holder() else:
          return 0
      return holder.doubled()

  function maybe_text() -> Option[string.String]:
      return Option[string.String].none

  function guarded_text() -> str:
      var text = maybe_text() else:
          return ""
      return text.as_str()
MT

def path_to_uri(path)
  "file://#{path.split("/").map { |seg| CGI.escape(seg).gsub("+", "%20") }.join("/")}"
end

def build_workspace(dir)
  FileUtils.mkdir_p(File.join(dir, "mod_alpha"))
  FileUtils.mkdir_p(File.join(dir, "mod_beta"))
  FileUtils.mkdir_p(File.join(dir, "mod_holding"))
  FileUtils.mkdir_p(File.join(dir, "pkg", "src"))
  FileUtils.mkdir_p(File.join(dir, "assets"))
  paths = {
    alpha: File.join(dir, "mod_alpha", "lib.mt"),
    beta: File.join(dir, "mod_beta", "lib.mt"),
    holding: File.join(dir, "mod_holding", "lib.mt"),
    flat: File.join(dir, "flat_mod.mt"),
    main: File.join(dir, "main.mt"),
    scratch: File.join(dir, "scratch.mt"),
    containers: File.join(dir, "containers.mt"),
    generics: File.join(dir, "generics.mt"),
    helper: File.join(dir, "helper.mt"),
    user: File.join(dir, "user.mt"),
    inlay: File.join(dir, "inlay.mt"),
    reserved: File.join(dir, "reserved.mt"),
    format: File.join(dir, "format.mt"),
    imported: File.join(dir, "imported.mt"),
    package_manifest: File.join(dir, "pkg", "package.toml"),
    package_local: File.join(dir, "pkg", "src", "local_mod.mt"),
    package_user: File.join(dir, "pkg", "src", "user.mt"),
    strings: File.join(dir, "strings.mt"),
  }
  File.write(paths[:alpha], ALPHA_SOURCE)
  File.write(paths[:beta], BETA_SOURCE)
  File.write(paths[:holding], HOLDING_SOURCE)
  File.write(paths[:flat], FLAT_SOURCE)
  File.write(paths[:main], MAIN_SOURCE)
  File.write(paths[:scratch], "function scratch_fn() -> int:\n    return 1\n")
  File.write(paths[:containers], CONTAINERS_SOURCE)
  File.write(paths[:generics], GENERICS_SOURCE)
  File.write(paths[:helper], HELPER_SOURCE)
  File.write(paths[:user], USER_SOURCE)
  File.write(paths[:inlay], INLAY_SOURCE)
  File.write(paths[:reserved], RESERVED_SOURCE)
  File.write(paths[:format], FORMAT_SOURCE)
  File.write(paths[:imported], IMPORTED_SOURCE)
  File.write(paths[:package_manifest], PACKAGE_MANIFEST)
  File.write(paths[:package_local], PACKAGE_LOCAL_SOURCE)
  File.write(paths[:package_user], PACKAGE_USER_SOURCE)
  File.write(paths[:strings], STR_METHOD_SOURCE)
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
    value.gsub(workspace, "<WS>")
         .gsub(%r{file://<WS>}, "file://<WS>")
         # `milkTea/debugInfo`'s Bindings section renders the host's Ruby
         # object ids (and the self's node keys) per site; only the binding-id
         # sequence is comparable across implementations.
         .gsub(/obj \d+ → binding_id:/, "obj <OBJ> → binding_id:")
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

  ## Write bytes straight to the server's input: the malformed-frame probe
  ## needs a frame the JSON writer can never produce.
  def write_raw(bytes)
    @stdin.write(bytes)
    @stdin.flush
  end

  ## The next message the server sends, whatever it is (used after a raw frame).
  def read_after_raw_frame
    message = Timeout.timeout(@timeout_s) { read_message }
    return { "closed" => true } if message.nil?
    message
  rescue Timeout::Error
    { "timeout" => true }
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
  # A qualified enum member: `member: Type = <value>` at the member's own
  # declaration (the enum-member arm, not the receiver's type).
  requests["hover/enum-member"] = ["textDocument/hover", at.call("Color.green", off: 6)]
  requests["definition/enum-member"] = ["textDocument/definition", at.call("Color.green", off: 6)]
  requests["hover/imported-fn"] = ["textDocument/hover", at.call("alpha.fn_alpha")]
  requests["hover/field"] = ["textDocument/hover", at.call("x = 1, y = 2")]
  requests["hover/keyword"] = ["textDocument/hover", { "textDocument" => { "uri" => main_uri }, "position" => { "line" => 0, "character" => 0 } }]
  requests["definition/compute"] = ["textDocument/definition", at.call("compute(3, 4)")]
  requests["definition/local"] = ["textDocument/definition", at.call("total += s.sum()", within: nil)]
  requests["definition/imported"] = ["textDocument/definition", at.call("alpha.fn_alpha")]
  requests["definition/imported-member"] = ["textDocument/definition", at.call("alpha.fn_alpha", off: 6)]
  requests["typeDefinition/std-member"] = ["textDocument/typeDefinition", { "textDocument" => { "uri" => path_to_uri(paths[:containers]) }, "position" => { "line" => 3, "character" => 16 } }]
  requests["typeDefinition/imported-method"] = ["textDocument/typeDefinition", { "textDocument" => { "uri" => path_to_uri(paths[:containers]) }, "position" => { "line" => 6, "character" => 20 } }]
  requests["declaration/struct"] = ["textDocument/declaration", at.call("Sample(x = 1")]
  requests["typeDefinition/circle"] = ["textDocument/typeDefinition", at.call("Circle(radius")]
  requests["implementation/area"] = ["textDocument/implementation", at.call("c.area()")]
  requests["references/compute"] = ["textDocument/references", at.call("compute(3, 4)").merge("context" => { "includeDeclaration" => true })]
  requests["references/sum"] = ["textDocument/references", at.call("s.sum()").merge("context" => { "includeDeclaration" => true })]
  # Cross-file: the declaration of an imported function, referenced from main.
  requests["references/imported-decl"] = ["textDocument/references", {
    "textDocument" => { "uri" => alpha_uri },
    "position" => { "line" => 1, "character" => 16 },
    "context" => { "includeDeclaration" => true },
  }]
  # Cross-file, resolvable import: the declaration plus the importer's call.
  requests["references/imported-call"] = ["textDocument/references", {
    "textDocument" => { "uri" => path_to_uri(paths[:helper]) },
    "position" => { "line" => 0, "character" => 20 },
    "context" => { "includeDeclaration" => true },
  }]
  requests["documentHighlight"] = ["textDocument/documentHighlight", at.call("total += s.sum()", off: 0)]
  requests["documentSymbol"] = ["textDocument/documentSymbol", tc]
  requests["foldingRange"] = ["textDocument/foldingRange", tc]
  requests["selectionRange"] = ["textDocument/selectionRange", { "textDocument" => { "uri" => main_uri }, "positions" => [at.call("total += s.sum()")["position"]] }]
  requests["completion/member"] = ["textDocument/completion", at.call("s.sum()", off: 2)]
  requests["completion/import-member"] = ["textDocument/completion", at.call("alpha.fn_alpha", off: 6)]
  requests["completion/top-level"] = ["textDocument/completion", at.call("return total")]
  requests["completion/struct-field"] = ["textDocument/completion", at.call("Sample(x = 1", off: 8)]
  # Inside `f"value #{loc}`: the local `local_value` completes from the host's
  # snapshot bucket (`2_`), not the global bucket.
  format_line = 2
  format_open = FORMAT_SOURCE.split("\n", -1)[format_line].index('#{') + 2
  requests["completion/format-string"] = ["textDocument/completion", {
    "textDocument" => { "uri" => path_to_uri(paths[:format]) },
    "position" => { "line" => format_line, "character" => format_open + 3 },
  }]
  # Hover inside the interpolation: the host re-lexes `local_value` and answers
  # the binding (range is the inner identifier, not the whole f-string).
  requests["hover/format-string"] = ["textDocument/hover", {
    "textDocument" => { "uri" => path_to_uri(paths[:format]) },
    "position" => { "line" => format_line, "character" => format_open + 3 },
  }]
  # An imported struct reached through `ref[T]`: fields complete, and the method
  # of an imported generic field resolves through the receiver chain.
  imported_uri = path_to_uri(paths[:imported])
  ref_line, ref_col = find_pos(IMPORTED_SOURCE, "r.lookup.len()")
  value_line, value_col = find_pos(IMPORTED_SOURCE, "h.lookup.len()")
  requests["completion/ref-imported-field"] = ["textDocument/completion", {
    "textDocument" => { "uri" => imported_uri },
    "position" => { "line" => ref_line, "character" => ref_col + 2 },
  }]
  requests["hover/imported-field-method"] = ["textDocument/hover", {
    "textDocument" => { "uri" => imported_uri },
    "position" => { "line" => ref_line, "character" => ref_col + 9 },
  }]
  requests["hover/imported-field-method/value"] = ["textDocument/hover", {
    "textDocument" => { "uri" => imported_uri },
    "position" => { "line" => value_line, "character" => value_col + 9 },
  }]
  # Cross-file rename of an imported function: `flat_mod.mt` is open, so its
  # declaration is edited alongside the call site in `main.mt`.
  requests["rename/imported-function"] = ["textDocument/rename", at.call("flat_mod.flat_fn(5)", off: 11).merge("newName" => "renamed_flat_fn")]
  # A package `source_root` module: the alias and the type it introduces resolve
  # from the requesting file's package root, and the arm binding's field hovers
  # from its payload type.
  package_uri = path_to_uri(paths[:package_user])
  pkg_line, pkg_col = find_pos(PACKAGE_USER_SOURCE, "local.Local) -> int")
  requests["hover/package-module"] = ["textDocument/hover", {
    "textDocument" => { "uri" => package_uri },
    "position" => { "line" => pkg_line, "character" => pkg_col },
  }]
  requests["hover/package-type"] = ["textDocument/hover", {
    "textDocument" => { "uri" => package_uri },
    "position" => { "line" => pkg_line, "character" => pkg_col + 6 },
  }]
  payload_line, payload_col = find_pos(PACKAGE_USER_SOURCE, "o.value")
  requests["hover/variant-payload-field"] = ["textDocument/hover", {
    "textDocument" => { "uri" => package_uri },
    "position" => { "line" => payload_line, "character" => payload_col + 2 },
  }]
  # An extending method declared in the package-local module.
  method_line, method_col = find_pos(PACKAGE_USER_SOURCE, "b.get()")
  requests["hover/package-method"] = ["textDocument/hover", {
    "textDocument" => { "uri" => package_uri },
    "position" => { "line" => method_line, "character" => method_col + 2 },
  }]
  # A module-qualified variant arm (`local.Local.one`): the self resolves the
  # arm from the imported type's module; the host answers null here (a
  # self-better extension, documented in the plan).
  arm_line, arm_col = find_pos(PACKAGE_USER_SOURCE, "local.Local.one as o")
  requests["hover/imported-variant-arm"] = ["textDocument/hover", {
    "textDocument" => { "uri" => package_uri },
    "position" => { "line" => arm_line, "character" => arm_col + 12 },
  }]
  # A `str` receiver's extending method, directly and through a struct field.
  strings_uri = path_to_uri(paths[:strings])
  str_line, str_col = find_pos(STR_METHOD_SOURCE, "a.equal(b)")
  requests["hover/str-method"] = ["textDocument/hover", {
    "textDocument" => { "uri" => strings_uri },
    "position" => { "line" => str_line, "character" => str_col + 2 },
  }]
  named_line, named_col = find_pos(STR_METHOD_SOURCE, "n.name.equal")
  requests["hover/str-method-field-chain"] = ["textDocument/hover", {
    "textDocument" => { "uri" => strings_uri },
    "position" => { "line" => named_line, "character" => named_col + 7 },
  }]
  # The reported shape: guarded locals over a nullable and an
  # `Option[string.String]` initializer, whose member calls resolve through the
  # narrowed binding type.
  text_line, text_col = find_pos(STR_METHOD_SOURCE, "text.as_str()")
  requests["hover/guarded-local-str-method"] = ["textDocument/hover", {
    "textDocument" => { "uri" => strings_uri },
    "position" => { "line" => text_line, "character" => text_col + 5 },
  }]
  holder_line, holder_col = find_pos(STR_METHOD_SOURCE, "holder.doubled()")
  requests["hover/guarded-local-method"] = ["textDocument/hover", {
    "textDocument" => { "uri" => strings_uri },
    "position" => { "line" => holder_line, "character" => holder_col + 8 },
  }]
  # A field name in its own declaration (the `field <name>: <type>` arm).
  requests["hover/field-declaration"] = ["textDocument/hover", at.call("x: int")]
  requests["signatureHelp"] = ["textDocument/signatureHelp", at.call("compute(3, 4)", off: 8)]
  requests["prepareRename"] = ["textDocument/prepareRename", at.call("s.sum()", off: 2)]
  requests["rename"] = ["textDocument/rename", at.call("s.sum()", off: 2).merge("newName" => "renamed_sum")]
  requests["linkedEditingRange"] = ["textDocument/linkedEditingRange", at.call("total += s.sum()")]
  requests["inlayHint"] = ["textDocument/inlayHint", { "textDocument" => { "uri" => main_uri }, "range" => { "start" => { "line" => 0, "character" => 0 }, "end" => { "line" => 40, "character" => 0 } } }]
  requests["inlayHint/fixture"] = ["textDocument/inlayHint", { "textDocument" => { "uri" => path_to_uri(paths[:inlay]) }, "range" => { "start" => { "line" => 0, "character" => 0 }, "end" => { "line" => 40, "character" => 0 } } }]
  requests["semanticTokens/full"] = ["textDocument/semanticTokens/full", tc]
  requests["semanticTokens/range"] = ["textDocument/semanticTokens/range", tc.merge("range" => { "start" => { "line" => 0, "character" => 0 }, "end" => { "line" => 40, "character" => 0 } })]
  requests["codeLens"] = ["textDocument/codeLens", tc]
  requests["codeAction"] = ["textDocument/codeAction", tc.merge("range" => { "start" => { "line" => 0, "character" => 0 }, "end" => { "line" => 40, "character" => 0 } }, "context" => { "diagnostics" => [] })]
  # Every quickfix branch, with diagnostics a real client would echo back:
  # cast, engine rules, shadow, unused-param, dead-assignment, unsafe wrap,
  # match arms, unused-import and an import suggestion.
  requests["codeAction/quickfixes"] = ["textDocument/codeAction", {
    "textDocument" => { "uri" => main_uri },
    "range" => { "start" => { "line" => 0, "character" => 0 }, "end" => { "line" => 47, "character" => 0 } },
    "context" => { "diagnostics" => [
      { "range" => { "start" => { "line" => 37, "character" => 8 }, "end" => { "line" => 37, "character" => 9 } },
        "severity" => 1, "source" => "milk-tea", "message" => "cannot assign str to s: expected int",
        "data" => { "stage" => "sema" } },
      { "range" => { "start" => { "line" => 36, "character" => 8 }, "end" => { "line" => 36, "character" => 13 } },
        "severity" => 4, "source" => "milk-tea", "code" => "prefer-let",
        "message" => "variable 'total' is never reassigned, prefer 'let'", "data" => { "stage" => "lint" } },
      { "range" => { "start" => { "line" => 43, "character" => 8 }, "end" => { "line" => 43, "character" => 10 } },
        "severity" => 4, "source" => "milk-tea", "code" => "shadow",
        "message" => "local 'a' shadows an earlier binding", "data" => { "stage" => "lint" } },
      { "range" => { "start" => { "line" => 32, "character" => 17 }, "end" => { "line" => 32, "character" => 18 } },
        "severity" => 4, "source" => "milk-tea", "code" => "unused-param",
        "message" => "unused parameter 'a'", "data" => { "stage" => "lint" } },
      { "range" => { "start" => { "line" => 43, "character" => 8 }, "end" => { "line" => 43, "character" => 10 } },
        "severity" => 4, "source" => "milk-tea", "code" => "dead-assignment",
        "message" => "dead assignment to 'a'", "data" => { "stage" => "lint" } },
      { "range" => { "start" => { "line" => 39, "character" => 13 }, "end" => { "line" => 39, "character" => 14 } },
        "severity" => 1, "source" => "milk-tea", "message" => "pointer cast requires unsafe",
        "data" => { "stage" => "sema" } },
      { "range" => { "start" => { "line" => 38, "character" => 4 }, "end" => { "line" => 38, "character" => 9 } },
        "severity" => 1, "source" => "milk-tea", "message" => "match on Color is missing cases: blue, red",
        "data" => { "stage" => "sema" } },
      { "range" => { "start" => { "line" => 0, "character" => 7 }, "end" => { "line" => 0, "character" => 16 } },
        "severity" => 4, "source" => "milk-tea", "code" => "unused-import",
        "message" => "unused import 'mod_alpha'", "data" => { "stage" => "lint" } },
      { "range" => { "start" => { "line" => 37, "character" => 8 }, "end" => { "line" => 37, "character" => 9 } },
        "severity" => 1, "source" => "milk-tea", "message" => "unknown type Vec",
        "data" => { "stage" => "sema", "suggestion" => "did you mean 'std.vec.Vec'?" } },
    ] }
  }]
  requests["documentLink"] = ["textDocument/documentLink", tc]
  requests["prepareCallHierarchy"] = ["textDocument/prepareCallHierarchy", at.call("compute(3, 4)")]
  requests["prepareCallHierarchy/imported"] = ["textDocument/prepareCallHierarchy", at.call("alpha.fn_alpha", off: 6)]
  requests["prepareCallHierarchy/method"] = ["textDocument/prepareCallHierarchy", at.call("s.sum()", off: 2)]
  requests["typeDefinition/function"] = ["textDocument/typeDefinition", at.call("compute(3, 4)")]
  requests["typeDefinition/imported"] = ["textDocument/typeDefinition", at.call("alpha.fn_alpha", off: 6)]
  requests["linkedEditingRange/type"] = ["textDocument/linkedEditingRange", at.call("struct Sample", within: nil, off: 7)]
  requests["linkedEditingRange/function"] = ["textDocument/linkedEditingRange", at.call("compute(3, 4)")]
  requests["executeCommand/unknown"] = ["workspace/executeCommand", { "command" => "mtc.noSuchCommand", "arguments" => [] }]
  # A `reserved-primitive-name` diagnostic: the action renames the binding at
  # its declaration and every use.
  requests["codeAction/reserved-name"] = ["textDocument/codeAction", {
    "textDocument" => { "uri" => path_to_uri(paths[:reserved]) },
    "range" => { "start" => { "line" => 0, "character" => 0 }, "end" => { "line" => 0, "character" => 0 } },
    "context" => { "diagnostics" => [
      { "range" => { "start" => { "line" => 0, "character" => 9 }, "end" => { "line" => 0, "character" => 12 } },
        "severity" => 2, "source" => "milk-tea", "code" => "reserved-primitive-name",
        "message" => "function 'int' uses reserved built-in type name 'int'; rename it before this becomes a hard error",
        "data" => { "stage" => "lint" } },
    ] }
  }]
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
  requests["documentSymbol/containers"] = ["textDocument/documentSymbol", { "textDocument" => { "uri" => path_to_uri(paths[:containers]) } }]
  requests["documentSymbol/generics"] = ["textDocument/documentSymbol", { "textDocument" => { "uri" => path_to_uri(paths[:generics]) } }]
  requests
end

def run_corpus(client, dir, paths)
  recordings = {}
  init = client.request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
  recordings["initialize"] = init
  client.notify("initialized", {})
  client.notify("textDocument/didOpen", { "textDocument" => { "uri" => path_to_uri(paths[:main]), "languageId" => "milk-tea", "version" => 1, "text" => MAIN_SOURCE } })
  client.notify("textDocument/didOpen", { "textDocument" => { "uri" => path_to_uri(paths[:alpha]), "languageId" => "milk-tea", "version" => 1, "text" => ALPHA_SOURCE } })
  client.notify("textDocument/didOpen", { "textDocument" => { "uri" => path_to_uri(paths[:flat]), "languageId" => "milk-tea", "version" => 1, "text" => FLAT_SOURCE } })
  client.notify("textDocument/didOpen", { "textDocument" => { "uri" => path_to_uri(paths[:beta]), "languageId" => "milk-tea", "version" => 1, "text" => BETA_SOURCE } })
  client.notify("textDocument/didOpen", { "textDocument" => { "uri" => path_to_uri(paths[:scratch]), "languageId" => "milk-tea", "version" => 1, "text" => "function scratch_fn() -> int:\n    return 1\n" } })
  client.notify("textDocument/didOpen", { "textDocument" => { "uri" => path_to_uri(paths[:containers]), "languageId" => "milk-tea", "version" => 1, "text" => CONTAINERS_SOURCE } })
  client.notify("textDocument/didOpen", { "textDocument" => { "uri" => path_to_uri(paths[:generics]), "languageId" => "milk-tea", "version" => 1, "text" => GENERICS_SOURCE } })
  client.notify("textDocument/didOpen", { "textDocument" => { "uri" => path_to_uri(paths[:helper]), "languageId" => "milk-tea", "version" => 1, "text" => HELPER_SOURCE } })
  client.notify("textDocument/didOpen", { "textDocument" => { "uri" => path_to_uri(paths[:inlay]), "languageId" => "milk-tea", "version" => 1, "text" => INLAY_SOURCE } })
  # `reserved.mt` stays closed: its reserved-name *sema* error differs between
  # the engines (Track 2), and only the open documents feed
  # `workspace/diagnostic`.  The code-action request reads it from disk.
  # `user.mt` stays closed on purpose: the host's pull diagnostics report
  # `unknown callable helper_sum` for the (resolvable) import, while its
  # reference facts resolve it, so opening it would diff the workspace
  # diagnostics entry over a host-side gap rather than a self-host one.
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
  # A file mid-edit still gets an outline (the host reports what it parsed).
  outcomes["stress/unterminated-source+symbols"] = client.request("textDocument/documentSymbol", { "textDocument" => { "uri" => main_uri } })

  # 5b. a frame the server cannot parse must not end the session: the JSON-RPC
  # body is garbage, so the answer is a ParseError and the next request still
  # works.  The host exits on this frame, so the entry differs by design
  # (documented in docs/self-host-plan.md §0k).
  client.write_raw("Content-Length: 7\r\n\r\nnotjson")
  outcomes["stress/malformed-frame+parseError"] = client.read_after_raw_frame
  outcomes["stress/malformed-frame+recovery"] = client.request("textDocument/documentSymbol", { "textDocument" => { "uri" => main_uri } })

  # 5c. an edit that adds a symbol must be visible to index-backed requests.
  client.notify("textDocument/didOpen", { "textDocument" => { "uri" => path_to_uri(paths[:helper]), "languageId" => "milk-tea", "version" => 1, "text" => HELPER_SOURCE } })
  version += 1
  client.notify("textDocument/didChange", {
    "textDocument" => { "uri" => path_to_uri(paths[:helper]), "version" => version + 1 },
    "contentChanges" => [{ "text" => HELPER_SOURCE + "\npublic function helper_extra() -> int:\n    return 3\n" }],
  })
  outcomes["stress/edited-symbol+workspaceSymbol"] = client.request("workspace/symbol", { "query" => "helper_extra" })

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

  # 8. cache-invalidating client notifications: they run after the C5 probes
  # below (see the end of this method) so they cannot perturb a measured
  # request — `willRenameFiles` moves the host's indexed document to the new
  # URI, and a later reference query would see that copy (`renamed.mt`).
  # 9. client-behaviour probes (C5): measured outcomes for the notification
  # paths the corpus does not cover — configuration changes, watched files,
  # workspace-folder events, cancellation and closed-file disk edits.  Probes
  # 1–7 left main.mt on the unicode source, so restore a known state first.
  version += 1
  client.notify("textDocument/didChange", {
    "textDocument" => { "uri" => main_uri, "version" => version },
    "contentChanges" => [{ "text" => MAIN_SOURCE }],
  })

  # 9a. references with includeDeclaration: false.
  ref_line, ref_col = find_pos(MAIN_SOURCE, "compute(3, 4)")
  outcomes["c5/references-no-declaration"] = client.request("textDocument/references", {
    "textDocument" => { "uri" => main_uri },
    "position" => { "line" => ref_line, "character" => ref_col },
    "context" => { "includeDeclaration" => false },
  })

  # 9b. a configuration change switches the formatter mode for the next format.
  client.notify("workspace/didChangeConfiguration", {
    "settings" => { "milkTea" => { "format" => { "mode" => "preserve" } } },
  })
  outcomes["c5/config-preserve+formatting"] = client.request("textDocument/formatting", { "textDocument" => { "uri" => main_uri }, "options" => { "tabSize" => 4, "insertSpaces" => true } })
  client.notify("workspace/didChangeConfiguration", {
    "settings" => { "milkTea" => { "format" => { "mode" => "tidy" } } },
  })
  outcomes["c5/config-tidy+formatting"] = client.request("textDocument/formatting", { "textDocument" => { "uri" => main_uri }, "options" => { "tabSize" => 4, "insertSpaces" => true } })

  # 9c. a watched file appears on disk while the server runs.
  watched_path = File.join(dir, "watched.mt")
  File.write(watched_path, "public function watched_marker() -> int:\n    return 7\n")
  client.notify("workspace/didChangeWatchedFiles", { "changes" => [{ "uri" => path_to_uri(watched_path), "type" => 1 }] })
  outcomes["c5/watched-created+workspaceSymbol"] = client.request("workspace/symbol", { "query" => "watched_marker" })

  # 9d. a cancellation notification for an unknown id must not disturb the
  # next request (real in-flight cancellation is not drivable frame-by-frame).
  client.notify("$/cancelRequest", { "id" => 987_654 })
  outcomes["c5/cancel-then-hover"] = client.request("textDocument/hover", { "textDocument" => { "uri" => main_uri }, "position" => { "line" => 0, "character" => 0 } })

  # 9e. adding a workspace folder while the current root remains.  The host
  # reindexes the new root on a worker, so an immediate query can still see the
  # pre-folder index (its documented facts lag); poll a fixed number of times
  # and record the settled answer.
  extra_dir = File.join(dir, "extra_ws")
  FileUtils.mkdir_p(extra_dir)
  File.write(File.join(extra_dir, "extra.mt"), "public function extra_marker() -> int:\n    return 9\n")
  client.notify("workspace/didChangeWorkspaceFolders", { "event" => { "added" => [{ "uri" => path_to_uri(extra_dir), "name" => "extra_ws" }], "removed" => [] } })
  folder_symbol_result = nil
  5.times do |attempt|
    sleep 0.05 if attempt.positive?
    folder_symbol_result = client.request("workspace/symbol", { "query" => "extra_marker" })
  end
  outcomes["c5/workspace-folder-added+workspaceSymbol"] = folder_symbol_result

  # 9f. a closed file is edited on disk: hover before the edit, then after —
  # the client sends no notification, so this pins each server's content-cache
  # semantics for closed documents.
  scratch_uri = path_to_uri(paths[:scratch])
  client.notify("textDocument/didOpen", { "textDocument" => { "uri" => scratch_uri, "languageId" => "milk-tea", "version" => 1, "text" => "function scratch_fn() -> int:\n    return 1\n" } })
  outcomes["c5/closed-edit-before"] = client.request("textDocument/hover", { "textDocument" => { "uri" => scratch_uri }, "position" => { "line" => 0, "character" => 10 } })
  client.notify("textDocument/didClose", { "textDocument" => { "uri" => scratch_uri } })
  File.write(paths[:scratch], "function scratch_renamed() -> int:\n    return 2\n")
  sleep 0.2
  outcomes["c5/closed-edit-after-hover"] = client.request("textDocument/hover", { "textDocument" => { "uri" => scratch_uri }, "position" => { "line" => 0, "character" => 10 } })

  # The cache-invalidating notifications run after every measured probe (see
  # step 8): `willRenameFiles` moves the host's indexed document to `renamed.mt`,
  # so any later reference query would see that copy.
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
