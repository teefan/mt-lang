# frozen_string_literal: true

require "json"
require "cgi/escape"
require "tmpdir"
require "timeout"
require_relative "../../../test_helper"

module LSPServerTestHelpers
  HOVER_LATENCY_BUDGET_MS = 250.0
  SEMANTIC_TOKENS_LATENCY_BUDGET_MS = 450.0

  ROOT_DIR = File.expand_path("../../../..", __dir__).freeze
  LIB_DIR = File.join(ROOT_DIR, "lib").freeze

  class << self
    attr_accessor :_shared_client, :_shared_pid
  end

  def self.ensure_shared_server!
    return if self._shared_client

    stdin_read, stdin_write = IO.pipe
    stdout_read, stdout_write = IO.pipe

    pid = spawn(
      RbConfig.ruby, "-I", LIB_DIR,
      "-e", "require 'milk_tea'; MilkTea::LSP::Server.new.run",
      in: stdin_read, out: stdout_write, err: File::NULL
    )

    stdin_read.close
    stdout_write.close

    client = LSPClient.new(stdin_write, stdout_read)
    client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
    client.send_notification("initialized", {})

    self._shared_client = client
    self._shared_pid = pid

    Minitest.after_run do
      stdin_write&.close rescue nil
      stdout_read&.close rescue nil
      Process.kill("TERM", pid) rescue nil
      Process.wait(pid) rescue nil
    end
  end

  def teardown
    ObjectSpace.each_object(MilkTea::LSP::Server) do |server|
      server.send(:handle_shutdown, nil)
    rescue StandardError
      nil
    end

    super
  end

  class RecordingProtocol
    attr_reader :notifications, :responses, :errors

    def initialize
      @notifications = Queue.new
      @responses = []
      @errors = []
    end

    def read_message = nil

    def write_notification(method, params)
      @notifications << { "method" => method, "params" => params }
    end

    def write_response(id, result)
      @responses << { "id" => id, "result" => result }
    end

    def write_error(id, code, message)
      @errors << { "id" => id, "code" => code, "message" => message }
    end
  end

  class ScriptedProtocol
    attr_reader :responses, :errors

    def initialize(messages)
      @messages = messages.dup
      @responses = []
      @errors = []
    end

    def read_message
      @messages.shift
    end

    def write_notification(_method, _params)
    end

    def write_response(id, result)
      @responses << { "id" => id, "result" => result }
    end

    def write_error(id, code, message)
      @errors << { "id" => id, "code" => code, "message" => message }
    end
  end

  class LSPClient
    def initialize(stdin_write, stdout_read)
      @stdin = stdin_write
      @stdout = stdout_read
      @next_id = 1
    end

    def send_request(method, params = {})
      id = @next_id
      @next_id += 1
      write_message({ jsonrpc: "2.0", id: id, method: method, params: params })
      read_until_response(id)
    end

    def send_notification(method, params = {})
      write_message({ jsonrpc: "2.0", method: method, params: params })
    end

    private

    def write_message(message)
      json = JSON.dump(message)
      @stdin.write("Content-Length: #{json.bytesize}\r\n\r\n#{json}")
      @stdin.flush
    end

    def read_until_response(expected_id, timeout: 5)
      Timeout.timeout(timeout) do
        loop do
          message = read_message
          return nil if message.nil?
          next unless message["id"] == expected_id

          return message
        end
      end
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

      content_length = headers["Content-Length"]&.to_i
      return nil if content_length.nil? || content_length <= 0

      JSON.parse(@stdout.read(content_length))
    end
  end

  class SharedLSPClient
    def initialize(delegate)
      @delegate = delegate
    end

    def send_request(method, params = {})
      return @delegate.send_request(method, params) unless method == "initialize"

      {}
    end

    def send_notification(method, params = {})
      return if method == "initialized"

      @delegate.send_notification(method, params)
    end
  end

  SOURCE = <<~MT
    struct Vec2:
        x: float
        y: float

    function add(a: int, b: int) -> int:
        return a + b
  MT

  # Source that has both a definition and a call-site for 'add'.
  SOURCE_WITH_CALL = <<~MT
    function add(a: int, b: int) -> int:
        return a + b

    function main() -> int:
        return add(1, 2)
  MT

  # Source with a struct + extending block so method completion/hover can be tested.
  SOURCE_WITH_METHODS = <<~MT
    struct Point:
        x: int
        y: int

    extending Point:
        function zero() -> int:
            return 0

    function get_val() -> int:
        return 1
  MT

  SOURCE_WITH_EDITABLE_METHOD_RECEIVER_COMPLETION = <<~MT
    struct Counter:
        value: int

    extending Counter:
        editable function reset():
            this.value = 0
  MT

  SOURCE_WITH_MEMBER_CHAIN_HOVER = <<~MT
    struct Piece:
        kind: int

    struct Game:
        active: Piece

    extending Game:
        function current_kind() -> int:
            return this.active.kind
  MT

  SOURCE_WITH_HOVER_DOCS = <<~MT
    ## Adds two values.
    ## Used by main.
    function add(a: int, b: int) -> int:
        return a + b

    function main() -> int:
        return add(1, 2)
  MT

  SOURCE_WITH_HOVER_PLAIN_COMMENT = <<~MT
    # Not documentation.
    function add(a: int, b: int) -> int:
        return a + b

    function main() -> int:
        return add(1, 2)
  MT

  SOURCE_WITH_HOVER_DOC_GAP = <<~MT
    ## Detached doc.

    function add(a: int, b: int) -> int:
        return a + b

    function main() -> int:
        return add(1, 2)
  MT

  SOURCE_WITH_STRUCTURED_DOC_TAGS = <<~MT
    ## Adds two values.
    ## @param a first addend
    ## @param b second addend
    ## @return sum of both values
    ## @see [math reference](https://example.com/math)
    function add(a: int, b: int) -> int:
        return a + b

    function main() -> int:
        return add(1, 2)
  MT

  SOURCE_WITH_LOCAL_INTERFACES = <<~MT
    ## Shared gameplay contract.
    interface ScreenState:
        editable function update(effect: int) -> void
        function draw(texture: int) -> void

    struct TitleScreen implements ScreenState:
        ticks: int

    struct PauseScreen implements ScreenState:
        ticks: int

    extending TitleScreen:
        editable function update(effect: int):
            this.ticks += effect

        function draw(texture: int) -> void:
            let sink = texture

    extending PauseScreen:
        editable function update(effect: int):
            this.ticks += effect

        function draw(texture: int) -> void:
            let sink = texture
  MT

  SOURCE_WITH_LOCAL_VALUE_COMPLETION = <<~MT
    struct Point:
        x: int
        y: int

    extending Point:
        function length() -> int:
            return this.x + this.y

    function main() -> int:
        let p = Point(x = 1, y = 2)
        return p.x
  MT

  SOURCE_WITH_SHADOWED_VALUE_COMPLETION = <<~MT
    struct Point:
        x: int

    struct Size:
        w: int

    function main() -> int:
        let v = Point(x = 1)
        if true:
            let v = Size(w = 2)
            let _inner = v.w
        return v.x
  MT

  SOURCE_WITH_NULLABLE_FLOW_COMPLETION = <<~MT
    struct Point:
        x: int

    function main() -> int:
        var p: Point? = null
        if p != null:
            return p.x
        return 0
  MT

  SOURCE_WITH_REF_RECEIVER_COMPLETION = <<~MT
    struct Point:
        x: int
        y: int

    function main() -> int:
        var p = Point(x = 1, y = 2)
        let rp = ref_of(p)
        return rp.x
  MT

  SOURCE_WITH_POINTER_RECEIVER_COMPLETION = <<~MT
    struct Point:
        x: int
        y: int

    function main() -> int:
        var p = Point(x = 1, y = 2)
        let pp = ptr_of(p)
        unsafe:
            return pp.x
  MT

  SOURCE_WITH_TOP_LEVEL_VALUE_RECEIVER_COMPLETION = <<~MT
    struct Point:
        x: int
        y: int

    extending Point:
        function area() -> int:
            return this.x * this.y

    var origin: Point = Point(x = 3, y = 4)

    function main() -> int:
        return origin.x
  MT

  SOURCE_WITH_STR_BUFFER_METHODS = <<~MT
    function main() -> int:
        var editor_text: str_buffer[64]
        editor_text.assign("Milk Tea")
        let current = editor_text.as_str()
        if editor_text.capacity() == 64:
            return current.len
        return 0
  MT

  SOURCE_WITH_GENERIC_TYPE_SURFACES = <<~MT
    function takes(values: span[int]) -> array[int, 4]:
        return array[int, 4](1, 2, 3, 4)
  MT

  SOURCE_WITH_MULTI_TYPE_ARGUMENT_SEMANTICS = <<~MT
    struct HashMap[K, V]:
        left: int

    struct Holder[K, V]:
        items: HashMap[K, V]

    function make[K, V]() -> HashMap[K, V]:
        return HashMap[K, V](left = 1)
  MT

  SOURCE_WITH_PARAMETER_AND_LABEL_SEMANTICS = <<~MT
    struct Vec2:
        x: int
        y: int

    function sample(position: int, speed: int) -> int:
        let point = Vec2(x = position, y = speed)
        for index in 0..1:
            return point.x + index + position
        return speed
  MT

  SOURCE_WITH_STRUCT_FIELD_SEMANTICS = <<~MT
    struct Packet:
        str: ptr[char]
        size: int

    function read(packet: Packet) -> int:
        let raw = packet.str
        return packet.size
  MT

  SOURCE_WITH_RESOLVED_CALLABLE_SEMANTICS = <<~MT
    struct Point:
        x: int
        y: int

    struct Entry:
        callback: proc(value: int) -> int

    function add(a: int, b: int) -> int:
        return a + b

    function build() -> Point:
        return Point(x = 1, y = 2)

    function main() -> int:
        let callback = proc(value: int) -> int:
            return value + 1
        let entry = Entry(callback = callback)
        let invoked = callback(3)
        let from_entry = entry.callback(4)
        return add(invoked, from_entry)
  MT

  SOURCE_WITH_FUNCTION_VALUE_AND_ZERO_SEMANTICS = <<~MT
    struct Box:
        value: int

    extending Box:
        static function default() -> Box:
            return Box(value = 7)

    function add_one(value: int) -> int:
        return value + 1

    function apply(callback: fn(value: int) -> int, value: int) -> int:
        return callback(value)

    function main() -> int:
        let callback: fn(value: int) -> int = add_one
        let zeroed = zero[Box]
        let defaulted = default[Box]
        return apply(add_one, zeroed.value) + callback(defaulted.value)
  MT

  SOURCE_WITH_BUILTIN_CALLABLE_HOVER = <<~MT
    function main() -> int:
        var items = array[int, 2](1, 2)
        let view = span[int](data = ptr_of(items[0]), len = 2)
        let alias = ref_of(items[0])
        let first = read(alias)
        return first + view[1]
  MT

    SOURCE_WITH_ASSOCIATED_HOOK_BUILTINS = (<<~MT) + "\n"

struct Key:
    value: int

extending Key:
    public static function hash(value: const_ptr[Key]) -> uint:
        unsafe:
            return uint<-read(value).value

    public static function equal(left: const_ptr[Key], right: const_ptr[Key]) -> bool:
        unsafe:
            return read(left).value == read(right).value

    public static function order(left: const_ptr[Key], right: const_ptr[Key]) -> int:
        unsafe:
            return read(left).value - read(right).value

function probe(key: Key, other: Key) -> int:
    let hashed = hash[Key](key)
    let same = equal[Key](key, other)
    return int<-hashed + order[Key](key, other) + (if same: 1 else: 0)
    MT

  SOURCE_WITH_USER_DEFINED_CAST_AND_RANGE_SEMANTICS = <<~MT
    function cast(value: int) -> int:
        return value

    function range(value: int) -> int:
        return value + 1

    function main(value: int) -> int:
        let from_cast = cast(value)
        let from_range = range(value)
        return from_cast + from_range
  MT

  SOURCE_WITH_USER_DEFINED_ASSOCIATED_HOOK_NAMES = (<<~MT) + "\n"

function hash[T](value: T) -> uint:
    return 0

function equal[T](left: T, right: T) -> bool:
    return true

function order[T](left: T, right: T) -> int:
    return 0

function main(value: int) -> int:
    let hashed = hash[int](value)
    let same = equal[int](value, value)
    return order[int](value, value) + int<-hashed + (if same: 1 else: 0)
  MT

  SOURCE_WITH_INVALID_BARE_FUNCTION_REFERENCE_SEMANTICS = <<~MT
    function add_one(value: int) -> int:
        return value + 1

    function main() -> int:
        let callback = add_one
        return 0
  MT

  SOURCE_WITH_SPECIALIZED_MEMBER_CALL_SEMANTICS = <<~MT
    import std.mem.pool as pool

    struct Mat4:
        value: int

    function main() -> int:
        var matrices = pool.create_for[Mat4](2)
        let item = matrices.alloc[Mat4]()
        if item == null:
            return 1
        return 0
  MT

      SOURCE_WITH_GENERIC_PARAMETER_SHADOWING_IMPORT_SEMANTICS = <<~MT


      function wrap[T](status: int, value: T) -> int:
          if status != 0:
              return status
          return 0
      MT

      SOURCE_WITH_SPECIALIZED_FUNCTION_CALL_SEMANTICS = <<~MT
      function identity[T](value: T) -> T:
          return value

      function main() -> int:
          return identity[int](1)
      MT

      SOURCE_WITH_GENERIC_PARAMETER_AND_PROPERTY_SEMANTICS = <<~MT
      struct Box:
          status: int

      function read_status[T](status: int, box: Box) -> int:
          let current = box.status
          return status + current
      MT

      SOURCE_WITH_KEYWORD_NAMESPACE_PATH_SEMANTICS = <<~MT
      import tmp.async as impl

      function main() -> int:
          return 0
      MT

      SOURCE_WITH_GENERIC_LOCAL_AND_SPECIALIZED_FUNCTION_VALUE_SEMANTICS = <<~MT


      function invoke(callback: fn() -> int) -> int:
          return callback()

      function make_status[T]() -> int:
          return 1

      function run[T]() -> int:
          var status = 0
          status = invoke(make_status[T])
          if status != 0:
              return status
          return 0
      MT

    SOURCE_WITH_GENERIC_VARIANT_SEMANTICS = <<~MT
      variant PayloadBox[T]:
          some(value: T)
          none

      function has_payload(value: PayloadBox[int]) -> bool:
          match value:
              PayloadBox.some as payload:
                  return payload.value > 0
              PayloadBox.none:
                  return false
    MT

  SOURCE_WITH_FSTRING_INTERPOLATION = <<~'MT'
    function main() -> int:
        let name = "milk"
        let msg = f"hello #{name}"
        return msg.len
  MT

  SOURCE_WITH_FSTRING_MEMBER_INTERPOLATION = <<~'MT'
    struct Snapshot:
        score: int

    struct Screen:
        snapshot: Snapshot

    extending Screen:
        function label() -> str:
            return f"score #{this.snapshot.score}"
  MT

  SOURCE_WITH_PLAIN_HEREDOC_CSTRING = <<~MT
    const text: cstr = c<<-TEXT
        alpha
        beta
    TEXT
  MT

  SOURCE_WITH_GLSL_HEREDOC_CSTRING = <<~MT
    const shader: cstr = c<<-GLSL
        #version 330
        void main()
        {
        }
    GLSL
  MT

  SOURCE_WITH_VERT_HEREDOC_CSTRING = <<~MT
    const shader: cstr = c<<-VERT
        #version 330
        layout (location = 0) in vec3 vertex_position;
        void main()
        {
            gl_Position = vec4(vertex_position, 1.0);
        }
    VERT
  MT

  SOURCE_WITH_JSON_HEREDOC_CSTRING = <<~MT
    const payload: cstr = c<<-JSON
        {
            "name": "milk-tea",
            "count": 3,
            "ready": true
        }
    JSON
  MT

  SOURCE_WITH_JSONC_HEREDOC_CSTRING = <<~MT
    const payload: cstr = c<<-JSONC
        {
            // comment
            "name": "milk-tea"
        }
    JSONC
  MT

  SOURCE_WITH_SQL_HEREDOC_CSTRING = <<~MT
    const query: cstr = c<<-SQL
        select id, name
        from saves
        where slot = :slot and profile_id = ?1;
    SQL
  MT



  def path_to_uri(path)
    escaped_path = path.split("/").map { |segment| CGI.escape(segment).gsub("+", "%20") }.join("/")
    "file://#{escaped_path}"
  end

  def decode_semantic_token_entries(data, legend)
    line = 0
    char = 0

    data.each_slice(5).map do |delta_line, delta_start, length, token_type_idx, modifier_bits|
      line += delta_line
      char = delta_line.zero? ? char + delta_start : delta_start

      {
        "line" => line,
        "startChar" => char,
        "endChar" => char + length,
        "tokenType" => legend.fetch("tokenTypes").fetch(token_type_idx),
        "modifierBits" => modifier_bits,
        "modifierNames" => legend.fetch("tokenModifiers").each_with_index.filter_map do |name, bit|
          name if (modifier_bits & (1 << bit)) != 0
        end
      }
    end
  end

  def apply_workspace_edits_to_source(source, edits)
    updated = source.dup

    edits
      .sort_by { |edit| [edit.dig("range", "start", "line"), edit.dig("range", "start", "character")] }
      .reverse_each do |edit|
      start_pos = edit.dig("range", "start")
      end_pos = edit.dig("range", "end")

      start_off = lsp_position_to_byte_offset(updated, start_pos.fetch("line"), start_pos.fetch("character"))
      end_off = lsp_position_to_byte_offset(updated, end_pos.fetch("line"), end_pos.fetch("character"))

      updated = updated.byteslice(0, start_off).to_s + edit.fetch("newText") + updated.byteslice(end_off..).to_s
    end

    updated
  end

  def lsp_position_to_byte_offset(content, line, character)
    lines = content.split("\n", -1)
    clamped_line = [[line.to_i, 0].max, lines.length - 1].min

    preceding = if clamped_line.zero?
                  ""
                else
                  lines[0...clamped_line].join("\n") + "\n"
                end

    line_text = lines[clamped_line] || ""
    target_units = [character.to_i, 0].max

    utf16_units_seen = 0
    byte_index = 0
    line_text.each_char do |ch|
      codepoint = ch.ord
      units = codepoint > 0xFFFF ? 2 : 1
      break if utf16_units_seen + units > target_units

      utf16_units_seen += units
      byte_index += ch.bytesize
    end

    (preceding + line_text.byteslice(0, byte_index).to_s).bytesize
  end

  def measure_request_ms
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    response = yield
    finished = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    [(finished - started) * 1000.0, response]
  end

  def assert_embedded_heredoc_body_has_no_string_semantic_tokens(source, uri)
    with_server do |client|
      init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      response = client.send_request("textDocument/semanticTokens/full", {
        "textDocument" => { "uri" => uri }
      })

      legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
      entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

      refute entries.any? { |entry| entry.fetch("tokenType") == "string" }
    end
  end

  def semantic_entry_for_lexeme(source, entries, lexeme)
    lines = source.lines
    entries.find do |entry|
      line_text = lines.fetch(entry.fetch("line"))
      entry.fetch("endChar") - entry.fetch("startChar") == lexeme.length &&
        line_text[entry.fetch("startChar"), lexeme.length] == lexeme
    end or flunk("expected semantic token entry for #{lexeme.inspect}")
  end

  def semantic_entry_for_lexeme_on_line(source, entries, lexeme, line)
    lines = source.lines
    entries.find do |entry|
      next false unless entry.fetch("line") == line

      line_text = lines.fetch(line)
      entry.fetch("endChar") - entry.fetch("startChar") == lexeme.length &&
        line_text[entry.fetch("startChar"), lexeme.length] == lexeme
    end or flunk("expected semantic token entry for #{lexeme.inspect} on line #{line}")
  end

  def with_shared_server
    LSPServerTestHelpers.ensure_shared_server!
    client = SharedLSPClient.new(LSPServerTestHelpers._shared_client)
    yield client
  end

  def with_server
    stdin_read, stdin_write = IO.pipe
    stdout_read, stdout_write = IO.pipe

    pid = spawn(
      RbConfig.ruby, "-I", LIB_DIR,
      "-e", "require 'milk_tea'; MilkTea::LSP::Server.new.run",
      in: stdin_read,
      out: stdout_write,
      err: File::NULL,
    )

    stdin_read.close
    stdout_write.close

    client = LSPClient.new(stdin_write, stdout_read)
    yield client
  ensure
    stdin_write&.close
    stdout_read&.close
    Process.kill("TERM", pid) rescue nil
    Process.wait(pid) rescue nil
  end
end
