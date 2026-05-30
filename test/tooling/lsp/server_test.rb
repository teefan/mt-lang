# frozen_string_literal: true

require "json"
require "cgi/escape"
require "tmpdir"
require "timeout"
require_relative "../../test_helper"

class LSPServerTest < Minitest::Test
  HOVER_LATENCY_BUDGET_MS = 250.0
  SEMANTIC_TOKENS_LATENCY_BUDGET_MS = 450.0

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
        mutable function reset():
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

  SOURCE_WITH_LOCAL_INTERFACES = <<~MT
    ## Shared gameplay contract.
    interface ScreenState:
        mutable function update(effect: int) -> void
        function draw(texture: int) -> void

    struct TitleScreen implements ScreenState:
        ticks: int

    struct PauseScreen implements ScreenState:
        ticks: int

    extending TitleScreen:
        mutable function update(effect: int):
            this.ticks += effect

        function draw(texture: int) -> void:
            let sink = texture

    extending PauseScreen:
        mutable function update(effect: int):
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

  def test_shutdown_stops_background_diagnostics_workers
    server = MilkTea::LSP::Server.new(protocol: RecordingProtocol.new)
    workers = server.instance_variable_get(:@diagnostics_workers).dup

    refute_empty workers

    server.send(:stop_diagnostics_workers)

    assert workers.none?(&:alive?)
  end

  def test_initialize_advertises_expected_capabilities
    with_server do |client|
      response = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      capabilities = response.dig("result", "capabilities")

      assert_equal 2, capabilities.dig("textDocumentSync", "change")
      assert_equal true, capabilities["hoverProvider"]
      assert_equal true, capabilities["definitionProvider"]
      assert_equal true, capabilities["declarationProvider"]
      assert_equal true, capabilities["typeDefinitionProvider"]
      assert_equal true, capabilities["implementationProvider"]
      assert_equal true, capabilities["referencesProvider"]
      assert_kind_of Hash, capabilities["documentLinkProvider"]
      assert_equal true, capabilities["documentHighlightProvider"]
      assert_equal true, capabilities["documentRangeFormattingProvider"]
      assert_kind_of Hash, capabilities["codeActionProvider"]
      assert_equal true, capabilities["inlayHintProvider"]
      assert_kind_of Hash, capabilities["renameProvider"]
      assert_kind_of Hash, capabilities["signatureHelpProvider"]
      assert_kind_of Hash, capabilities["completionProvider"]
      assert_equal true, capabilities["workspaceSymbolProvider"]
      workspace_folders = capabilities.dig("workspace", "workspaceFolders")
      assert_equal true, workspace_folders["supported"]
      assert_equal true, workspace_folders["changeNotifications"]
    end
  end

  def test_cancel_request_replies_with_request_cancelled_error
    protocol = RecordingProtocol.new
    server = MilkTea::LSP::Server.new(protocol: protocol)

    server.send(:process_message, {
      "jsonrpc" => "2.0",
      "method" => "$/cancelRequest",
      "params" => { "id" => 99 }
    })
    server.send(:process_message, {
      "jsonrpc" => "2.0",
      "id" => 99,
      "method" => "initialize",
      "params" => { "rootUri" => nil, "capabilities" => {} }
    })

    assert_equal [], protocol.responses
    error = protocol.errors.find { |entry| entry["id"] == 99 }
    refute_nil error
    assert_equal(-32_800, error["code"])
    assert_equal("Request cancelled", error["message"])
  ensure
    server&.send(:handle_shutdown, nil)
  end

  def test_run_skips_invalid_messages_and_processes_following_requests
    protocol = ScriptedProtocol.new([
      MilkTea::LSP::Protocol::INVALID_MESSAGE,
      {
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => { "rootUri" => nil, "capabilities" => {} }
      },
      nil,
    ])

    server = MilkTea::LSP::Server.new(protocol: protocol)
    server.run

    response = protocol.responses.find { |entry| entry["id"] == 1 }
    refute_nil response
    capabilities = response.fetch("result")[:capabilities] || response.fetch("result")["capabilities"]
    assert_kind_of Hash, capabilities
    assert_equal [], protocol.errors
  ensure
    server&.send(:handle_shutdown, nil)
  end

  def test_workspace_folder_change_updates_workspace_root_and_reindexes
    Dir.mktmpdir("milk-tea-lsp-workspace-folder-change") do |dir|
      first_root = File.join(dir, "first")
      second_root = File.join(dir, "second")
      FileUtils.mkdir_p(first_root)
      FileUtils.mkdir_p(second_root)
      File.write(File.join(second_root, "new_symbol.mt"), <<~MT)
        function folder_changed_symbol() -> int:
            return 1
      MT

      first_root_uri = path_to_uri(first_root)
      second_root_uri = path_to_uri(second_root)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => first_root_uri, "capabilities" => {} })
        client.send_notification("initialized", {})

        before = client.send_request("workspace/symbol", { "query" => "folder_changed_symbol" })
        assert_equal [], before.fetch("result")

        client.send_notification("workspace/didChangeWorkspaceFolders", {
          "event" => {
            "added" => [{ "uri" => second_root_uri, "name" => "second" }],
            "removed" => [{ "uri" => first_root_uri, "name" => "first" }],
          }
        })

        after = client.send_request("workspace/symbol", { "query" => "folder_changed_symbol" })
        names = after.fetch("result").map { |symbol| symbol["name"] }
        assert_includes names, "folder_changed_symbol"
      end
    end
  end

  def test_document_symbol_and_hover_work_after_open
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      client.send_notification("initialized", {})

      uri = "file:///tmp/lsp_server_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => {
          "uri" => uri,
          "languageId" => "milk-tea",
          "version" => 1,
          "text" => SOURCE
        }
      })

      symbols_response = client.send_request("textDocument/documentSymbol", {
        "textDocument" => { "uri" => uri }
      })
      names = symbols_response.fetch("result").map { |sym| sym["name"] }
      assert_includes names, "Vec2"
      assert_includes names, "add"

      hover_response = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => 4, "character" => 9 }
      })
      hover_value = hover_response.dig("result", "contents", "value")
      assert_includes hover_value, "add"
      assert_includes hover_value, "-> int"
    end
  end

  def test_document_symbol_includes_event_declarations
    source = <<~MT
      event reloaded[4]

      struct Window:
          public event closed[4]
          title: str

      function main() -> void:
          reloaded.emit()
    MT

    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_event_symbols_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      response = client.send_request("textDocument/documentSymbol", {
        "textDocument" => { "uri" => uri }
      })

      names = response.fetch("result").map { |symbol| symbol["name"] }
      assert_includes names, "reloaded"
      assert_includes names, "closed"
      assert_includes names, "main"
    end
  end

  def test_hover_includes_docs_source_and_range
    Dir.mktmpdir("milk-tea-lsp-hover") do |dir|
      source_path = File.join(dir, "main.mt")
      source = SOURCE_WITH_HOVER_DOCS
      File.write(source_path, source)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})

        uri = path_to_uri(source_path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => source
          }
        })

        hover_response = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => uri },
          "position" => { "line" => 6, "character" => 11 }
        })

        hover_result = hover_response.fetch("result")
        hover_value = hover_result.dig("contents", "value")
        hover_range = hover_result.fetch("range")

        assert_includes hover_value, "function add(a: int, b: int) -> int"
        assert_includes hover_value, "Adds two values."
        assert_includes hover_value, "Used by main."
        assert_includes hover_value, "Defined at: [main.mt:3](#{uri}#L3)"

        assert_equal 6, hover_range.dig("start", "line")
        assert_equal 11, hover_range.dig("start", "character")
        assert_equal 14, hover_range.dig("end", "character")
      end
    end
  end

  def test_hover_returns_interface_info_for_local_implements_clause
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })

      uri = "file:///tmp/lsp_hover_interface_local.mt"
      source = SOURCE_WITH_LOCAL_INTERFACES
      client.send_notification("textDocument/didOpen", {
        "textDocument" => {
          "uri" => uri,
          "languageId" => "milk-tea",
          "version" => 1,
          "text" => source,
        },
      })

      implements_line = source.lines.index { |line| line.include?("implements ScreenState") }
      interface_char = source.lines[implements_line].index("ScreenState") + 1

      hover_response = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => implements_line, "character" => interface_char },
      })

      hover_value = hover_response.dig("result", "contents", "value")
      assert_includes hover_value, "interface ScreenState"
      assert_includes hover_value, "mutable function update(effect: int) -> void"
      assert_includes hover_value, "function draw(texture: int) -> void"
      assert_includes hover_value, "Shared gameplay contract."
      refute_includes hover_value, "local ScreenState"
    end
  end

  def test_hover_and_definition_on_imported_interface_jump_to_interface_declaration
    Dir.mktmpdir("milk-tea-lsp-interface-import") do |dir|
      std_dir = File.join(dir, "std")
      FileUtils.mkdir_p(std_dir)

      contracts_source = <<~MT
        ## Damage contract.
        public interface Damageable:
            mutable function take_damage(amount: int) -> void
      MT
      main_source = <<~MT
        import std.contracts as contracts

        struct NPC implements contracts.Damageable:
            hp: int

        extending NPC:
            mutable function take_damage(amount: int):
                this.hp -= amount
      MT

      contracts_path = File.join(std_dir, "contracts.mt")
      main_path = File.join(dir, "main.mt")
      File.write(contracts_path, contracts_source)
      File.write(main_path, main_source)

      root_uri = path_to_uri(dir)
      contracts_uri = path_to_uri(contracts_path)
      main_uri = path_to_uri(main_path)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => root_uri, "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => main_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => main_source,
          }
        })

        implements_line = main_source.lines.index { |line| line.include?("contracts.Damageable") }
        interface_char = main_source.lines[implements_line].index("Damageable") + 1
        definition_line = contracts_source.lines.index { |line| line.include?("interface Damageable") }
        definition_char = contracts_source.lines[definition_line].index("Damageable")

        hover = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => implements_line, "character" => interface_char }
        })
        hover_value = hover.dig("result", "contents", "value")
        assert_includes hover_value, "interface Damageable"
        assert_includes hover_value, "mutable function take_damage(amount: int) -> void"
        assert_includes hover_value, "Damage contract."
        assert_includes hover_value, "Defined at: [std/contracts.mt:#{definition_line + 1}](#{contracts_uri}#L#{definition_line + 1})"

        definition = client.send_request("textDocument/definition", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => implements_line, "character" => interface_char }
        })

        assert_equal contracts_uri, definition.dig("result", "uri")
        assert_equal definition_line, definition.dig("result", "range", "start", "line")
        assert_equal definition_char, definition.dig("result", "range", "start", "character")
      end
    end
  end

  def test_hover_shows_local_variable_type
    source = <<~MT
      function main() -> int:
          let value = 1
          return value
    MT

    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      client.send_notification("initialized", {})

      uri = "file:///tmp/lsp_hover_local_type.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => {
          "uri" => uri,
          "languageId" => "milk-tea",
          "version" => 1,
          "text" => source,
        },
      })

      hover_response = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => 2, "character" => 11 },
      })

      hover_value = hover_response.dig("result", "contents", "value")
      assert_includes hover_value, "let value: int (immutable)"
    end
  end

  def test_hover_shows_local_declaration_type
    source = <<~MT
      function main() -> int:
          let value = 1
          return value
    MT

    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      client.send_notification("initialized", {})

      uri = "file:///tmp/lsp_hover_local_decl_type.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => {
          "uri" => uri,
          "languageId" => "milk-tea",
          "version" => 1,
          "text" => source,
        },
      })

      hover_response = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => 1, "character" => 8 },
      })

      hover_value = hover_response.dig("result", "contents", "value")
      assert_includes hover_value, "let value: int (immutable)"
    end
  end

  def test_hover_shows_let_else_error_binding_declaration_type
    source = <<~MT


      function load() -> Result[int, int]:
          return Result[int, int].failure(error = 1)

      function main() -> int:
          let value = load() else as error:
              return error
          return value
    MT
        error_decl_line = source.lines.index { |line| line.include?("else as error") }
        error_decl_char = source.lines.fetch(error_decl_line).index("error") + 1

    Dir.mktmpdir("lsp_hover_let_else_error_decl") do |dir|
      path = File.join(dir, "main.mt")
      File.write(path, source)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
        client.send_notification("initialized", {})

        uri = "file://#{path}"
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => source,
          },
        })

        hover_response = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => uri },
          "position" => { "line" => error_decl_line, "character" => error_decl_char },
        })

        hover_value = hover_response.dig("result", "contents", "value")
        assert_includes hover_value, "let error: int (immutable)"
      end
    end
  end

  def test_hover_shows_parameter_type
    source = <<~MT
      function main(value: int) -> int:
          return value
    MT

    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      client.send_notification("initialized", {})

      uri = "file:///tmp/lsp_hover_param_type.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => {
          "uri" => uri,
          "languageId" => "milk-tea",
          "version" => 1,
          "text" => source,
        },
      })

      hover_response = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => 1, "character" => 11 },
      })

      hover_value = hover_response.dig("result", "contents", "value")
      assert_includes hover_value, "parameter value: int (immutable)"
    end
  end

  def test_hover_shows_var_and_const_binding_kinds
    source = <<~MT
      const answer: int = 42
      var score: int = 0

      function main() -> int:
          score += 1
          return answer + score
    MT

    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      client.send_notification("initialized", {})

      uri = "file:///tmp/lsp_hover_value_kind_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => {
          "uri" => uri,
          "languageId" => "milk-tea",
          "version" => 1,
          "text" => source,
        },
      })

      const_hover = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => 5, "character" => 11 },
      })
      const_hover_value = const_hover.dig("result", "contents", "value")
      assert_includes const_hover_value, "const answer: int (immutable)"

      var_hover = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => 5, "character" => 20 },
      })
      var_hover_value = var_hover.dig("result", "contents", "value")
      assert_includes var_hover_value, "var score: int (mutable)"
    end
  end

  def test_hover_shows_declared_generic_parameter_type_in_generic_body
    source = <<~MT
      interface ScreenState:
          function update(effect: int) -> void

      struct TitleScreen implements ScreenState:
          ticks: int

      extending TitleScreen:
          function update(effect: int) -> void:
              let sink = effect

      function run_screen_frame[T implements ScreenState](screen: ref[T], effect: int) -> void:
          screen.update(effect)

      function main() -> int:
          var title = TitleScreen(ticks = 0)
          run_screen_frame(title, 1)
          return 0
    MT

    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      client.send_notification("initialized", {})

      uri = "file:///tmp/lsp_hover_generic_param_type.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => {
          "uri" => uri,
          "languageId" => "milk-tea",
          "version" => 1,
          "text" => source,
        },
      })

      hover_response = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => 11, "character" => 6 },
      })

      hover_value = hover_response.dig("result", "contents", "value")
      assert_includes hover_value, "parameter screen: ref[T] (immutable)"
      refute_includes hover_value, "TitleScreen"
    end
  end

  def test_hover_shows_builtin_default_value_signature
    source = SOURCE_WITH_FUNCTION_VALUE_AND_ZERO_SEMANTICS

    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      client.send_notification("initialized", {})

      uri = "file:///tmp/lsp_hover_builtin_default_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => {
          "uri" => uri,
          "languageId" => "milk-tea",
          "version" => 1,
          "text" => source,
        },
      })

      line = source.lines.index { |text| text.include?("default[Box]") }
      character = source.lines.fetch(line).rindex("default")

      hover_response = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => line, "character" => character },
      })

      zero_line = source.lines.index { |text| text.include?("zero[Box]") }
      zero_character = source.lines.fetch(zero_line).rindex("zero")

      zero_hover_response = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => zero_line, "character" => zero_character },
      })

      zero_hover_value = zero_hover_response.dig("result", "contents", "value")
      assert_includes zero_hover_value, "builtin zero[Box] -> Box"
      assert_includes zero_hover_value, "value form, not a callable"

      hover_value = hover_response.dig("result", "contents", "value")
      assert_includes hover_value, "builtin default[Box] -> Box"
      assert_includes hover_value, "requires an accessible zero-argument associated function `T.default()` that returns `T`"
      assert_includes hover_value, "value form, not a callable"
      refute_includes hover_value, "local default"
    end
  end

  def test_hover_shows_builtin_callable_signatures
    source = SOURCE_WITH_BUILTIN_CALLABLE_HOVER

    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      client.send_notification("initialized", {})

      uri = "file:///tmp/lsp_hover_builtin_callable_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => {
          "uri" => uri,
          "languageId" => "milk-tea",
          "version" => 1,
          "text" => source,
        },
      })

      array_line = source.lines.index { |text| text.include?("array[int, 2](1, 2)") }
      array_hover = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => array_line, "character" => source.lines.fetch(array_line).index("array") },
      })
      array_hover_value = array_hover.dig("result", "contents", "value")
      assert_includes array_hover_value, "builtin array[int, 2](...) -> array[int, 2]"

      span_line = source.lines.index { |text| text.include?("span[int](data =") }
      span_hover = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => span_line, "character" => source.lines.fetch(span_line).index("span") },
      })
      span_hover_value = span_hover.dig("result", "contents", "value")
      assert_includes span_hover_value, "builtin span[int](data = ..., len = ...) -> span[int]"

      ptr_hover = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => span_line, "character" => source.lines.fetch(span_line).index("ptr_of") },
      })
      ptr_hover_value = ptr_hover.dig("result", "contents", "value")
      assert_includes ptr_hover_value, "builtin ptr_of(value) -> ptr[T]"

      ref_line = source.lines.index { |text| text.include?("ref_of(items[0])") }
      ref_hover = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => ref_line, "character" => source.lines.fetch(ref_line).index("ref_of") },
      })
      ref_hover_value = ref_hover.dig("result", "contents", "value")
      assert_includes ref_hover_value, "builtin ref_of(value) -> ref[T]"

      read_line = source.lines.index { |text| text.include?("read(alias)") }
      read_hover = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => read_line, "character" => source.lines.fetch(read_line).index("read") },
      })
      read_hover_value = read_hover.dig("result", "contents", "value")
      assert_includes read_hover_value, "builtin read(value) -> T"
    end
  end

  def test_hover_shows_builtin_associated_hook_signatures
    source = SOURCE_WITH_ASSOCIATED_HOOK_BUILTINS

    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      client.send_notification("initialized", {})

      uri = "file:///tmp/lsp_hover_builtin_associated_hooks_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => {
          "uri" => uri,
          "languageId" => "milk-tea",
          "version" => 1,
          "text" => source,
        },
      })

      hash_line = source.lines.index { |text| text.include?("let hashed = hash[Key](key)") }
      equal_line = source.lines.index { |text| text.include?("let same = equal[Key](key, other)") }
      order_line = source.lines.index { |text| text.include?("order[Key](key, other)") }

      hash_hover = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => hash_line, "character" => source.lines.fetch(hash_line).index("hash[") + 1 },
      })
      hash_hover_value = hash_hover.dig("result", "contents", "value")
      assert_includes hash_hover_value, "builtin hash[Key](value) -> uint"
      assert_includes hash_hover_value, "lowers to `T.hash(value: const_ptr[T]) -> uint`"

      equal_hover = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => equal_line, "character" => source.lines.fetch(equal_line).index("equal") + 1 },
      })
      equal_hover_value = equal_hover.dig("result", "contents", "value")
      assert_includes equal_hover_value, "builtin equal[Key](left, right) -> bool"

      order_hover = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => order_line, "character" => source.lines.fetch(order_line).index("order") + 1 },
      })
      order_hover_value = order_hover.dig("result", "contents", "value")
      assert_includes order_hover_value, "builtin order[Key](left, right) -> int"
    end
  end

  def test_builtin_hover_info_describes_attribute_reflection_helpers
    source = <<~MT
      public attribute[field, callable] trace(name: str)

      struct Packet:
          @[trace("payload_len")]
          payload_len: uint

      @[trace("parse_packet")]
      function parse_packet() -> int:
          return 0

      function main() -> ptr_uint:
          let field_present = has_attribute(field_of(Packet, payload_len), trace)
          let callable_present = has_attribute(callable_of(parse_packet), trace)
          if field_present and callable_present:
              return attribute_arg[str](attribute_of(field_of(Packet, payload_len), trace), name).len
          return 0
    MT

    tokens = MilkTea::Lexer.lex(source, path: "/tmp/lsp_builtin_attribute_reflection_hover.mt")
    server = MilkTea::LSP::Server.new(protocol: RecordingProtocol.new)
    begin
      fetch_builtin_hover = lambda do |lexeme, occurrence = 0|
        token_index = tokens.each_index.select { |index| tokens[index].lexeme == lexeme }.fetch(occurrence)
        server.send(:builtin_hover_info, lexeme, tokens, token_index)
      end

      field_hover = fetch_builtin_hover.call("field_of")
      assert_includes field_hover.fetch(:signature), "builtin field_of(Type, field_name) -> field_handle"
      assert_includes field_hover.fetch(:docs), "compile-time handle for the named field"

      callable_hover = fetch_builtin_hover.call("callable_of")
      assert_includes callable_hover.fetch(:signature), "builtin callable_of(name) -> callable_handle"
      assert_includes callable_hover.fetch(:docs), "compile-time handle for a callable declaration name"

      has_attribute_hover = fetch_builtin_hover.call("has_attribute")
      assert_includes has_attribute_hover.fetch(:signature), "builtin has_attribute(target, attribute_name) -> bool"
      assert_includes has_attribute_hover.fetch(:docs), "checks at compile time whether the resolved attribute is applied"

      attribute_of_hover = fetch_builtin_hover.call("attribute_of")
      assert_includes attribute_of_hover.fetch(:signature), "builtin attribute_of(target, attribute_name) -> attribute_handle"
      assert_includes attribute_of_hover.fetch(:docs), "use `has_attribute(...)` when absence is expected"

      attribute_arg_hover = fetch_builtin_hover.call("attribute_arg")
      assert_includes attribute_arg_hover.fetch(:signature), "builtin attribute_arg[str](attribute, param_name) -> str"
      assert_includes attribute_arg_hover.fetch(:docs), "`T` must exactly match the declared parameter type"
    ensure
      server&.send(:stop_diagnostics_workers)
    end
  end

  def test_hover_and_definition_resolve_fstring_local_bindings
    source = <<~'MT'
      function main() -> int:
          let name = "milk"
          let msg = f"hello #{name}"
          return 0
    MT

    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      client.send_notification("initialized", {})

      uri = "file:///tmp/lsp_hover_fstring_local_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => {
          "uri" => uri,
          "languageId" => "milk-tea",
          "version" => 1,
          "text" => source,
        },
      })

      line = source.lines.index { |text| text.include?('#{name}') }
      character = source.lines.fetch(line).index("name")

      hover = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => line, "character" => character },
      })
      hover_value = hover.dig("result", "contents", "value")
      assert_includes hover_value, "let name: str (immutable)"

      definition = client.send_request("textDocument/definition", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => line, "character" => character },
      })
      definition_result = definition.fetch("result")

      assert_equal uri, definition_result.fetch("uri")
      assert_equal 1, definition_result.dig("range", "start", "line")
    end
  end

  def test_hover_response_stays_within_latency_budget
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      client.send_notification("initialized", {})

      uri = "file:///tmp/lsp_hover_latency_test.mt"
      source = SOURCE_WITH_HOVER_DOCS
      client.send_notification("textDocument/didOpen", {
        "textDocument" => {
          "uri" => uri,
          "languageId" => "milk-tea",
          "version" => 1,
          "text" => source
        }
      })

      elapsed_ms, response = measure_request_ms do
        client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => uri },
          "position" => { "line" => 6, "character" => 11 }
        })
      end

      assert response.fetch("result"), "expected non-nil hover result"
      assert_operator elapsed_ms, :<, HOVER_LATENCY_BUDGET_MS,
                      "hover took #{format("%.2f", elapsed_ms)}ms (budget #{HOVER_LATENCY_BUDGET_MS}ms)"
    end
  end

  def test_hover_ignores_plain_hash_comments_for_docs
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      client.send_notification("initialized", {})

      uri = "file:///tmp/lsp_hover_plain_comment_test.mt"
      source = SOURCE_WITH_HOVER_PLAIN_COMMENT
      client.send_notification("textDocument/didOpen", {
        "textDocument" => {
          "uri" => uri,
          "languageId" => "milk-tea",
          "version" => 1,
          "text" => source
        }
      })

      hover_response = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => 5, "character" => 11 }
      })

      hover_value = hover_response.dig("result", "contents", "value")
      refute_includes hover_value, "Not documentation."
    end
  end

  def test_hover_doc_block_requires_no_blank_line_before_definition
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      client.send_notification("initialized", {})

      uri = "file:///tmp/lsp_hover_doc_gap_test.mt"
      source = SOURCE_WITH_HOVER_DOC_GAP
      client.send_notification("textDocument/didOpen", {
        "textDocument" => {
          "uri" => uri,
          "languageId" => "milk-tea",
          "version" => 1,
          "text" => source
        }
      })

      hover_response = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => 6, "character" => 11 }
      })

      hover_value = hover_response.dig("result", "contents", "value")
      refute_includes hover_value, "Detached doc."
    end
  end

  def test_hover_defined_at_is_markdown_link
    Dir.mktmpdir("milk-tea-lsp-hover-link") do |dir|
      source_path = File.join(dir, "main.mt")
      source = SOURCE_WITH_HOVER_DOCS
      File.write(source_path, source)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})

        uri = path_to_uri(source_path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => source
          }
        })

        hover_response = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => uri },
          "position" => { "line" => 6, "character" => 11 }
        })

        hover_value = hover_response.dig("result", "contents", "value")

        # Verify only the source path segment is linked
        assert_includes hover_value, "Defined at: [main.mt:3](#{uri}#L3)"
      end
    end
  end

  def test_hover_on_imported_type_static_method_uses_qualified_receiver
    Dir.mktmpdir("milk-tea-lsp-hover-imported-type") do |dir|
      std_dir = File.join(dir, "std")
      FileUtils.mkdir_p(std_dir)

      foo_source = <<~MT
        public struct Point:
            x: int
            y: int

        extending Point:
            public static function zero() -> int:
                return 0
      MT
      main_source = <<~MT
        import std.foo as foo

        public function main() -> int:
            return foo.Point.zero()
      MT

      foo_path = File.join(std_dir, "foo.mt")
      main_path = File.join(dir, "main.mt")
      File.write(foo_path, foo_source)
      File.write(main_path, main_source)

      root_uri = path_to_uri(dir)
      foo_uri = path_to_uri(foo_path)
      main_uri = path_to_uri(main_path)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => root_uri, "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => main_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => main_source
          }
        })

        call_line = main_source.lines.index { |line| line.include?("foo.Point.zero") }
        call_char = main_source.lines[call_line].index("zero") + 1
        definition_line = foo_source.lines.index { |line| line.include?("static function zero") }

        hover = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => call_line, "character" => call_char }
        })

        hover_value = hover.dig("result", "contents", "value")
        assert_includes hover_value, "static function zero() -> int"
        assert_includes hover_value, "Defined at: [std/foo.mt:#{definition_line + 1}](#{foo_uri}#L#{definition_line + 1})"
      end
    end
  end

  def test_document_link_resolves_existing_relative_resource_path_string
    Dir.mktmpdir("milk-tea-lsp-doc-link") do |dir|
      assets_dir = File.join(dir, "assets")
      Dir.mkdir(assets_dir)

      asset_path = File.join(assets_dir, "raybunny.png")
      File.binwrite(asset_path, "png")

      main_path = File.join(dir, "main.mt")
      source = <<~MT
        const bunny_path: str = "./assets/raybunny.png"
        const title: str = "Milk Tea Bunnymark"
      MT
      File.write(main_path, source)

      root_uri = path_to_uri(dir)
      main_uri = path_to_uri(main_path)
      asset_uri = path_to_uri(asset_path)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => root_uri, "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => main_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => source
          }
        })

        response = client.send_request("textDocument/documentLink", {
          "textDocument" => { "uri" => main_uri }
        })

        links = response.fetch("result")
        assert_equal 1, links.length
        assert_equal asset_uri, links[0]["target"]
        assert_equal 0, links[0].dig("range", "start", "line")
      end
    end
  end

  def test_references_finds_all_occurrences_of_a_name
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_refs_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_CALL }
      })
      response = client.send_request("textDocument/references", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => 0, "character" => 9 },
        "context"      => { "includeDeclaration" => true }
      })
      locations = response.fetch("result")
      lines = locations.map { |loc| loc.dig("range", "start", "line") }
      assert_includes lines, 0
      assert_includes lines, 4
    end
  end

  def test_references_on_imported_type_static_method_are_receiver_scoped
    Dir.mktmpdir("milk-tea-lsp-refs-imported-type") do |dir|
      std_dir = File.join(dir, "std")
      FileUtils.mkdir_p(std_dir)

      foo_source = <<~MT
        public struct Point:
            x: int
            y: int

        extending Point:
            public static function zero() -> int:
                return 0

        public function call_zero() -> int:
            return Point.zero()
      MT
      other_source = <<~MT
        public function zero() -> int:
            return 0

        public function call_zero() -> int:
            return zero()
      MT
      main_source = <<~MT
        import std.foo as foo

        public function main() -> int:
            return foo.Point.zero()
      MT

      foo_path = File.join(std_dir, "foo.mt")
      other_path = File.join(dir, "other.mt")
      main_path = File.join(dir, "main.mt")
      File.write(foo_path, foo_source)
      File.write(other_path, other_source)
      File.write(main_path, main_source)

      root_uri = path_to_uri(dir)
      foo_uri = path_to_uri(foo_path)
      other_uri = path_to_uri(other_path)
      main_uri = path_to_uri(main_path)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => root_uri, "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => main_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => main_source
          }
        })

        call_line = main_source.lines.index { |line| line.include?("foo.Point.zero") }
        call_char = main_source.lines[call_line].index("zero") + 1

        response = client.send_request("textDocument/references", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => call_line, "character" => call_char },
          "context" => { "includeDeclaration" => true }
        })

        locations = response.fetch("result")
        starts = locations.map { |loc| [loc["uri"], loc.dig("range", "start", "line")] }
        foo_definition_line = foo_source.lines.index { |line| line.include?("static function zero") }
        foo_call_line = foo_source.lines.index { |line| line.include?("Point.zero") }

        assert_includes starts, [foo_uri, foo_definition_line]
        assert_includes starts, [foo_uri, foo_call_line]
        assert_includes starts, [main_uri, call_line]
        refute_includes starts, [other_uri, other_source.lines.index { |line| line.include?("function zero") }]
        refute_includes starts, [other_uri, other_source.lines.index { |line| line.include?("return zero()") }]
      end
    end
  end

  def test_references_local_variable_are_scoped_under_shadowing
    source = <<~MT
      function main() -> int:
          let value = 1
          let a = value
          if true:
              let value = 2
              let b = value
          return value
    MT

    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_references_shadowed_local.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      response = client.send_request("textDocument/references", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => 5, "character" => 17 },
        "context"      => { "includeDeclaration" => true }
      })

      refs = response.fetch("result")
      assert_equal 2, refs.length
      starts = refs.map { |entry| [entry.dig("range", "start", "line"), entry.dig("range", "start", "character")] }
      assert_includes starts, [4, 12]
      assert_includes starts, [5, 16]
    end
  end

  def test_document_highlight_returns_all_occurrences_in_file
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_highlight_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_CALL }
      })
      response = client.send_request("textDocument/documentHighlight", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => 0, "character" => 9 }
      })
      highlights = response.fetch("result")
      assert highlights.length >= 2, "expected at least 2 highlights for 'add', got #{highlights.length}"
      highlights.each { |h| assert_equal 1, h["kind"] }
    end
  end

  def test_document_highlight_local_variable_is_scoped_under_shadowing
    source = <<~MT
      function main() -> int:
          let value = 1
          let a = value
          if true:
              let value = 2
              let b = value
          return value
    MT

    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_highlight_shadowed_local.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      response = client.send_request("textDocument/documentHighlight", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => 5, "character" => 17 }
      })

      highlights = response.fetch("result")
      assert_equal 2, highlights.length
      starts = highlights.map { |entry| [entry.dig("range", "start", "line"), entry.dig("range", "start", "character")] }
      assert_includes starts, [4, 12]
      assert_includes starts, [5, 16]
    end
  end

  def test_signature_help_returns_function_signature_at_call_site
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_sighel_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_CALL }
      })
      # Cursor right after "add(" on line 4: "    return add(" = 15 chars
      response = client.send_request("textDocument/signatureHelp", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => 4, "character" => 15 }
      })
      result = response.fetch("result")
      assert_equal 0, result["activeSignature"]
      assert_equal 0, result["activeParameter"]
      sig_label = result.dig("signatures", 0, "label")
      assert_includes sig_label, "add"
      assert_includes sig_label, "a: int"
      assert_includes sig_label, "b: int"
    end
  end

  def test_signature_help_tracks_active_parameter_by_comma_count
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_sighel2_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_CALL }
      })
      # Cursor after "add(1, " on line 4: "    return add(1, " = 18 chars
      response = client.send_request("textDocument/signatureHelp", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => 4, "character" => 18 }
      })
      result = response.fetch("result")
      assert_equal 1, result["activeParameter"]
    end
  end

  def test_prepare_rename_returns_range_and_placeholder
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_prep_rename_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_CALL }
      })
      response = client.send_request("textDocument/prepareRename", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => 0, "character" => 9 }
      })
      result = response.fetch("result")
      assert_equal "add", result["placeholder"]
      assert_equal 0, result.dig("range", "start", "line")
      assert_equal 9, result.dig("range", "start", "character")
    end
  end

  def test_rename_produces_workspace_edit_for_all_occurrences
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_rename_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_CALL }
      })
      response = client.send_request("textDocument/rename", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => 0, "character" => 9 },
        "newName"      => "sum"
      })
      changes = response.dig("result", "changes", uri)
      assert_kind_of Array, changes
      assert changes.length >= 2, "expected at least 2 edits for 'add' rename, got #{changes.length}"
      changes.each { |edit| assert_equal "sum", edit["newText"] }
    end
  end

  def test_rename_local_variable_is_scoped_under_shadowing
    source = <<~MT
      function main() -> int:
          let value = 1
          let a = value
          if true:
              let value = 2
              let b = value
          return value
    MT

    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_rename_shadowed_local.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      # Rename the inner `value` declaration inside the if block.
      response = client.send_request("textDocument/rename", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => 4, "character" => 12 },
        "newName"      => "inner_value"
      })

      changes = response.dig("result", "changes", uri)
      assert_kind_of Array, changes
      assert_equal 2, changes.length

      starts = changes.map { |edit| [edit.dig("range", "start", "line"), edit.dig("range", "start", "character")] }
      assert_includes starts, [4, 12]
      assert_includes starts, [5, 16]
      changes.each { |edit| assert_equal "inner_value", edit["newText"] }
    end
  end

  def test_rename_local_variable_from_usage_is_scoped_under_shadowing
    source = <<~MT
      function main() -> int:
          let value = 1
          let a = value
          if true:
              let value = 2
              let b = value
          return value
    MT

    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_rename_shadowed_local_usage.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      # Rename from the inner usage `value` in `let b = value`.
      response = client.send_request("textDocument/rename", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => 5, "character" => 17 },
        "newName"      => "inner_value"
      })

      changes = response.dig("result", "changes", uri)
      assert_kind_of Array, changes
      assert_equal 2, changes.length

      starts = changes.map { |edit| [edit.dig("range", "start", "line"), edit.dig("range", "start", "character")] }
      assert_includes starts, [4, 12]
      assert_includes starts, [5, 16]
      changes.each { |edit| assert_equal "inner_value", edit["newText"] }
    end
  end

  def test_did_save_republishes_diagnostics
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_save_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => "struct Vec2:\n    x: float\n" }
      })
      client.send_notification("textDocument/didSave", { "textDocument" => { "uri" => uri } })
      # Server still alive if we get a response to a followup request
      response = client.send_request("textDocument/documentSymbol", { "textDocument" => { "uri" => uri } })
      assert_kind_of Array, response.fetch("result")
    end
  end

  def test_publish_diagnostics_uses_full_mode_on_open_and_save
    protocol = RecordingProtocol.new
    server = MilkTea::LSP::Server.new(protocol: protocol)
    uri = "file:///tmp/lsp_fast_publish_diagnostics.mt"
    source = <<~MT
      function main(value: int) -> int:
          unsafe:
              let copy = value + 1
          return int<-value
    MT

    server.send(:handle_did_open, {
      "textDocument" => {
        "uri" => uri,
        "text" => source,
      }
    })

    Timeout.timeout(5) do
      loop do
        message = protocol.notifications.pop
        break message if message.dig("method") == "textDocument/publishDiagnostics" && message.dig("params", :uri) == uri
      end
    end


    server.send(:handle_did_save, {
      "textDocument" => {
        "uri" => uri,
      }
    })

    Timeout.timeout(5) do
      loop do
        message = protocol.notifications.pop
        break message if message.dig("method") == "textDocument/publishDiagnostics" && message.dig("params", :uri) == uri
      end
    end

  ensure
    server&.send(:handle_shutdown, nil)
  end

  def test_perf_log_context_includes_short_uri_for_threshold_logs
    server = MilkTea::LSP::Server.new
    root_path = File.join(Dir.tmpdir, "milk-tea-lsp-perf")
    source_path = File.join(root_path, "demo", "slow.mt")
    FileUtils.mkdir_p(File.dirname(source_path))

    server.instance_variable_set(:@root_uri, path_to_uri(root_path))

    detail = server.send(:perf_log_context, 'textDocument/didOpen', {
      "textDocument" => { "uri" => path_to_uri(source_path) }
    }, verbose: false)

    assert_equal " uri=demo/slow.mt", detail
  ensure
    server&.send(:handle_shutdown, nil)
  end

  def test_semantic_tokens_classify_import_heavy_imported_module_function_reference_as_function
    Dir.mktmpdir("lsp_semantic_import_heavy") do |dir|
      c_dir = File.join(dir, "std", "c")
      FileUtils.mkdir_p(c_dir)

      File.write(File.join(c_dir, "sdl3.mt"), <<~MT)
        external

        external function SDL_SetWindowFillDocument(window: ptr[void], fill: bool) -> bool
      MT

      %w[alpha beta gamma].each do |name|
        File.write(File.join(dir, "std", "#{name}.mt"), <<~MT)
          public function answer() -> int:
              return 42
        MT
      end

      source_path = File.join(dir, "std", "sdl3.mt")
      FileUtils.mkdir_p(File.dirname(source_path))
      source = <<~MT
        import std.c.sdl3 as c
        import std.alpha as a
        import std.beta as b
        import std.gamma as g

        public foreign function set_window_fill_document(window: ptr[void], fill: bool) -> bool = c.SDL_SetWindowFillDocument
      MT
      File.write(source_path, source)

      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        uri = path_to_uri(source_path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

        alias_entry = semantic_entry_for_lexeme(source, entries, "c")
        member_entry = semantic_entry_for_lexeme(source, entries, "SDL_SetWindowFillDocument")

        assert_equal "namespace", alias_entry.fetch("tokenType")
        assert_equal "function", member_entry.fetch("tokenType")
      end
    end
  end

  def test_background_document_context_skips_diagnostics_until_promoted
    protocol = RecordingProtocol.new
    server = MilkTea::LSP::Server.new(protocol: protocol)
    uri = "file:///tmp/lsp_background_context.mt"
    source = <<~MT
      function main() -> int:
          return 0
    MT

    server.send(:handle_document_context, {
      "textDocument" => { "uri" => uri },
      "source" => "background-document"
    })
    server.send(:handle_did_open, {
      "textDocument" => { "uri" => uri, "text" => source }
    })

    refute_includes server.instance_variable_get(:@diagnostics_last_scheduled_hash).keys, uri

    server.send(:handle_document_context, {
      "textDocument" => { "uri" => uri },
      "source" => "active-editor"
    })

    assert_includes server.instance_variable_get(:@diagnostics_last_scheduled_hash).keys, uri

    published = Timeout.timeout(5) do
      loop do
        message = protocol.notifications.pop
        break message if message.dig("method") == "textDocument/publishDiagnostics" && message.dig("params", :uri) == uri
      end
    end

    assert_equal "textDocument/publishDiagnostics", published.fetch("method")
    assert_equal uri, published.dig("params", :uri)
  ensure
    server&.send(:handle_shutdown, nil)
  end

  def test_watched_file_change_skips_diagnostics_for_background_documents
    protocol = RecordingProtocol.new
    server = MilkTea::LSP::Server.new(protocol: protocol)

    Dir.mktmpdir("milk-tea-lsp-watch-background") do |dir|
      lib_path = File.join(dir, "mathx.mt")
      main_path = File.join(dir, "main.mt")

      File.write(lib_path, <<~MT)
        public function greet() -> int:
            return 1
      MT

      main_source = <<~MT
        import mathx as mx

        function main() -> int:
            return mx.greet()
      MT
      File.write(main_path, main_source)

      root_uri = path_to_uri(dir)
      lib_uri = path_to_uri(lib_path)
      main_uri = path_to_uri(main_path)

      server.send(:handle_initialize, { "rootUri" => root_uri, "capabilities" => {} })
      server.send(:handle_initialized, {})
      server.send(:handle_document_context, {
        "textDocument" => { "uri" => main_uri },
        "source" => "background-document"
      })
      server.send(:handle_did_open, {
        "textDocument" => {
          "uri" => main_uri,
          "languageId" => "milk-tea",
          "version" => 1,
          "text" => main_source
        }
      })

      refute_includes server.instance_variable_get(:@diagnostics_last_scheduled_hash).keys, main_uri

      File.write(lib_path, <<~MT)
        public function greet() -> str:
            return "oops"
      MT

      server.send(:handle_did_change_watched_files, {
        "changes" => [{ "uri" => lib_uri, "type" => 2 }]
      })

      refute_includes server.instance_variable_get(:@diagnostics_last_scheduled_hash).keys, main_uri
    end
  ensure
    server&.send(:handle_shutdown, nil)
  end

  def test_document_symbol_captures_opaque_declarations
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_opaque_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => "opaque SDL_Window\n" }
      })
      response = client.send_request("textDocument/documentSymbol", { "textDocument" => { "uri" => uri } })
      names = response.fetch("result").map { |s| s["name"] }
      assert_includes names, "SDL_Window"
    end
  end

  def test_document_symbol_captures_interface_declarations_with_interface_kind
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_interface_symbol_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_LOCAL_INTERFACES }
      })

      response = client.send_request("textDocument/documentSymbol", { "textDocument" => { "uri" => uri } })
      symbol = response.fetch("result").find { |entry| entry["name"] == "ScreenState" }

      refute_nil symbol
      assert_equal 11, symbol["kind"]
    end
  end

  def test_implementation_on_interface_returns_implementing_type_locations
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_interface_implementation_test.mt"
      source = SOURCE_WITH_LOCAL_INTERFACES
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      interface_line = source.lines.index { |line| line.include?("interface ScreenState") }
      interface_char = source.lines[interface_line].index("ScreenState") + 1
      title_line = source.lines.index { |line| line.include?("struct TitleScreen") }
      title_char = source.lines[title_line].index("TitleScreen")
      pause_line = source.lines.index { |line| line.include?("struct PauseScreen") }
      pause_char = source.lines[pause_line].index("PauseScreen")

      implementation = client.send_request("textDocument/implementation", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => interface_line, "character" => interface_char }
      })

      starts = implementation.fetch("result").map do |location|
        [location.fetch("uri"), location.dig("range", "start", "line"), location.dig("range", "start", "character")]
      end

      assert_includes starts, [uri, title_line, title_char]
      assert_includes starts, [uri, pause_line, pause_char]
    end
  end

  def test_implementation_on_interface_method_returns_implementing_method_locations
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_interface_method_implementation_test.mt"
      source = SOURCE_WITH_LOCAL_INTERFACES
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      interface_line = source.lines.index { |line| line.include?("mutable function update(effect: int) -> void") }
      interface_char = source.lines[interface_line].index("update") + 1

      update_lines = source.lines.each_index.select do |index|
        source.lines[index].include?("mutable function update(effect: int):")
      end
      title_line, pause_line = update_lines
      title_char = source.lines[title_line].index("update")
      pause_char = source.lines[pause_line].index("update")

      implementation = client.send_request("textDocument/implementation", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => interface_line, "character" => interface_char }
      })

      starts = implementation.fetch("result").map do |location|
        [location.fetch("uri"), location.dig("range", "start", "line"), location.dig("range", "start", "character")]
      end

      assert_includes starts, [uri, title_line, title_char]
      assert_includes starts, [uri, pause_line, pause_char]
    end
  end

  def test_implementation_on_imported_interface_method_returns_implementing_method_locations
    Dir.mktmpdir("milk-tea-lsp-interface-method-import") do |dir|
      std_dir = File.join(dir, "std")
      FileUtils.mkdir_p(std_dir)

      contracts_source = <<~MT
        public interface Damageable:
            mutable function take_damage(amount: int) -> void
      MT
      entities_source = <<~MT
        import std.contracts as contracts

        public struct NPC implements contracts.Damageable:
            hp: int

        extending NPC:
            public mutable function take_damage(amount: int):
                this.hp -= amount
      MT

      contracts_path = File.join(std_dir, "contracts.mt")
      entities_path = File.join(std_dir, "entities.mt")
      File.write(contracts_path, contracts_source)
      File.write(entities_path, entities_source)

      root_uri = path_to_uri(dir)
      contracts_uri = path_to_uri(contracts_path)
      entities_uri = path_to_uri(entities_path)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => root_uri, "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => contracts_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => contracts_source
          }
        })

        interface_line = contracts_source.lines.index { |line| line.include?("take_damage") }
        interface_char = contracts_source.lines[interface_line].index("take_damage") + 1
        method_line = entities_source.lines.index { |line| line.include?("mutable function take_damage") }
        method_char = entities_source.lines[method_line].index("take_damage")

        implementation = client.send_request("textDocument/implementation", {
          "textDocument" => { "uri" => contracts_uri },
          "position" => { "line" => interface_line, "character" => interface_char }
        })

        starts = implementation.fetch("result").map do |location|
          [location.fetch("uri"), location.dig("range", "start", "line"), location.dig("range", "start", "character")]
        end

        assert_includes starts, [entities_uri, method_line, method_char]
      end
    end
  end

  def test_range_formatting_returns_text_edits
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_range_fmt_test.mt"
      source = "function add(a:int,b:int)->int:\n    return a+b\n"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      response = client.send_request("textDocument/rangeFormatting", {
        "textDocument" => { "uri" => uri },
        "range" => {
          "start" => { "line" => 0, "character" => 0 },
          "end" => { "line" => 1, "character" => 14 }
        },
        "options" => { "tabSize" => 4, "insertSpaces" => true }
      })

      edits = response.fetch("result")
      assert_kind_of Array, edits
      assert_equal 1, edits.length
      assert_match(/function\s+add\(a:\s*int,\s*b:\s*int\)\s*->\s*int:/, edits[0]["newText"])
    end
  end

  def test_code_action_returns_source_fixall_action
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_code_action_test.mt"
      source = "function main() -> int:\n    var x = 1\n    return x\n"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      response = client.send_request("textDocument/codeAction", {
        "textDocument" => { "uri" => uri },
        "range" => {
          "start" => { "line" => 0, "character" => 0 },
          "end" => { "line" => 1, "character" => 14 }
        },
        "context" => { "diagnostics" => [], "only" => ["source.fixAll"] }
      })

      actions = response.fetch("result")
      assert_kind_of Array, actions
      fixall = actions.find { |a| a["kind"] == "source.fixAll" }
      assert fixall, "expected a source.fixAll action"
      assert_equal "Apply all auto-fixes", fixall["title"]
      assert_kind_of Hash, fixall.dig("edit", "changes")
      assert_kind_of Array, fixall.dig("edit", "changes", uri)
    end
  end

  def test_source_fixall_preserves_required_match_bindings
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_fixall_match_bindings.mt"
      source = <<~MT
        function main(value: Result[int, str]) -> int:
            match value:
                Result.failure as payload:
                    return payload.error.length()
                Result.success as _:
                    return 0
      MT
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      response = client.send_request("textDocument/codeAction", {
        "textDocument" => { "uri" => uri },
        "range" => {
          "start" => { "line" => 0, "character" => 0 },
          "end" => { "line" => 5, "character" => 0 }
        },
        "context" => { "diagnostics" => [], "only" => ["source.fixAll"] }
      })

      actions = response.fetch("result")
      fixall = actions.find { |a| a["kind"] == "source.fixAll" }
      assert fixall, "expected a source.fixAll action"
      edit_text = fixall.dig("edit", "changes", uri, 0, "newText")
      assert_includes edit_text, "Result.failure as payload:"
      assert_includes edit_text, "return payload.error.length()"
      assert_includes edit_text, "Result.success:"
      refute_includes edit_text, "Result.success as _:"
    end
  end

  def test_source_fixall_does_not_offer_action_for_line_too_long_only_file
    Dir.mktmpdir("milk-tea-lsp-fixall-line-length") do |dir|
      path = File.join(dir, "sample.mt")
      File.write(File.join(dir, ".mt-lint.yml"), <<~YAML)
        max_line_length: 40
        select:
          - line-too-long
        ignore: []
      YAML

      source = <<~MT
        function main() -> int:
            return log_value("alpha", "beta", "gamma", "delta")
      MT
      uri = path_to_uri(path)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/codeAction", {
          "textDocument" => { "uri" => uri },
          "range" => {
            "start" => { "line" => 0, "character" => 0 },
            "end" => { "line" => 2, "character" => 0 }
          },
          "context" => { "diagnostics" => [], "only" => ["source.fixAll"] }
        })

        actions = response.fetch("result")
        refute actions.any? { |action| action["kind"] == "source.fixAll" }
      end
    end
  end

  def test_source_fixall_does_not_offer_action_for_line_too_long_tuple_only_file
    Dir.mktmpdir("milk-tea-lsp-fixall-line-length-tuple") do |dir|
      path = File.join(dir, "sample.mt")
      File.write(File.join(dir, ".mt-lint.yml"), <<~YAML)
        max_line_length: 40
        select:
          - line-too-long
        ignore: []
      YAML

      source = <<~MT
        function main() -> int:
            let pair = (alpha_value, beta_value, gamma_value)
            return 0
      MT
      uri = path_to_uri(path)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/codeAction", {
          "textDocument" => { "uri" => uri },
          "range" => {
            "start" => { "line" => 0, "character" => 0 },
            "end" => { "line" => 3, "character" => 0 }
          },
          "context" => { "diagnostics" => [], "only" => ["source.fixAll"] }
        })

        actions = response.fetch("result")
        refute actions.any? { |action| action["kind"] == "source.fixAll" }
      end
    end
  end

  def test_source_fixall_does_not_offer_action_for_line_too_long_condition_only_file
    Dir.mktmpdir("milk-tea-lsp-fixall-line-length-condition") do |dir|
      path = File.join(dir, "sample.mt")
      File.write(File.join(dir, ".mt-lint.yml"), <<~YAML)
        max_line_length: 100
        select:
          - line-too-long
        ignore: []
      YAML

      source = <<~MT
        function main(kind: int, has_byte: bool, ctrl: bool, alt: bool, input_byte: int) -> void:
            if kind == 2 and has_byte and not ctrl and not alt and input_byte >= 32 and input_byte < 127 and input_byte != 64:
                pass
      MT
      uri = path_to_uri(path)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/codeAction", {
          "textDocument" => { "uri" => uri },
          "range" => {
            "start" => { "line" => 0, "character" => 0 },
            "end" => { "line" => 3, "character" => 0 }
          },
          "context" => { "diagnostics" => [], "only" => ["source.fixAll"] }
        })

        actions = response.fetch("result")
        refute actions.any? { |action| action["kind"] == "source.fixAll" }
      end
    end
  end

  def test_source_fixall_is_lint_only_and_ignores_formatter_mode_changes
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      client.send_notification("initialized", {})
      uri = "file:///tmp/lsp_fixall_formatter_mode.mt"
      source = <<~MT
        function main() -> int:
            var x = 1
            return x
      MT
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      expected = MilkTea::Linter.fix_source(source, path: "demo.mt")

      tidy_response = client.send_request("textDocument/codeAction", {
        "textDocument" => { "uri" => uri },
        "range" => {
          "start" => { "line" => 0, "character" => 0 },
          "end" => { "line" => 3, "character" => 0 }
        },
        "context" => { "diagnostics" => [], "only" => ["source.fixAll"] }
      })

      tidy_actions = tidy_response.fetch("result")
      tidy_fixall = tidy_actions.find { |action| action["kind"] == "source.fixAll" }
      assert tidy_fixall, "expected a source.fixAll action for tidy mode"
      assert_equal expected, tidy_fixall.dig("edit", "changes", uri, 0, "newText")

      client.send_notification("workspace/didChangeConfiguration", {
        "settings" => {
          "milkTea" => {
            "format" => {
              "mode" => "safe"
            }
          }
        }
      })

      safe_response = client.send_request("textDocument/codeAction", {
        "textDocument" => { "uri" => uri },
        "range" => {
          "start" => { "line" => 0, "character" => 0 },
          "end" => { "line" => 3, "character" => 0 }
        },
        "context" => { "diagnostics" => [], "only" => ["source.fixAll"] }
      })

      safe_actions = safe_response.fetch("result")
      safe_fixall = safe_actions.find { |action| action["kind"] == "source.fixAll" }
      assert safe_fixall, "expected a source.fixAll action for safe mode"
      assert_equal expected, safe_fixall.dig("edit", "changes", uri, 0, "newText")
    end
  end

  def test_code_action_provides_source_fixall_for_workspace_std_files
    Dir.mktmpdir("milk-tea-lsp-code-action-std") do |dir|
      std_dir = File.join(dir, "std")
      Dir.mkdir(File.join(dir, "std"))

      file_path = File.join(std_dir, "demo.mt")
      source = "function main() -> int:\n    var x = 1\n    return x\n"
      File.write(file_path, source)

      root_uri = path_to_uri(dir)
      uri = path_to_uri(file_path)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => root_uri, "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/codeAction", {
          "textDocument" => { "uri" => uri },
          "range" => {
            "start" => { "line" => 0, "character" => 0 },
            "end" => { "line" => 2, "character" => 14 }
          },
          "context" => { "diagnostics" => [], "only" => ["source.fixAll"] }
        })

        actions = response.fetch("result")
        fixall = actions.find { |a| a["kind"] == "source.fixAll" }
        assert fixall, "expected a source.fixAll action for std file"
        edit_text = fixall.dig("edit", "changes", uri, 0, "newText")
        assert_includes edit_text, "let x = 1"
      end
    end
  end

  def test_inlay_hint_returns_parameter_name_hints_for_call_arguments
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_inlay_hint_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_CALL }
      })

      response = client.send_request("textDocument/inlayHint", {
        "textDocument" => { "uri" => uri },
        "range" => {
          "start" => { "line" => 4, "character" => 0 },
          "end" => { "line" => 4, "character" => 30 }
        }
      })

      hints = response.fetch("result")
      labels = hints.map { |h| h["label"] }
      assert_includes labels, "a: "
      assert_includes labels, "b: "

      positions = hints.map { |h| [h.dig("position", "line"), h.dig("position", "character")] }
      assert_includes positions, [4, 15]
      assert_includes positions, [4, 18]
    end
  end

  def test_inlay_hint_respects_requested_range
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_inlay_hint_range_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_CALL }
      })

      response = client.send_request("textDocument/inlayHint", {
        "textDocument" => { "uri" => uri },
        "range" => {
          "start" => { "line" => 4, "character" => 0 },
          "end" => { "line" => 4, "character" => 16 }
        }
      })

      hints = response.fetch("result")
      labels = hints.map { |h| h["label"] }
      assert_includes labels, "a: "
      refute_includes labels, "b: "
    end
  end

  def test_inlay_hint_returns_parameter_name_hints_for_imported_module_call_arguments
    Dir.mktmpdir("mt_lsp_inlay_module_call") do |dir|
      Dir.mkdir(File.join(dir, "std"))

      module_path = File.join(dir, "mathx.mt")
      module_source = <<~MT
        public function add(a: int, b: int) -> int:
            return a + b
      MT
      File.write(module_path, module_source)

      main_path = File.join(dir, "main.mt")
      main_source = <<~MT
        import mathx as mx

        function main() -> int:
            return mx.add(1, 2)
      MT
      File.write(main_path, main_source)
      call_line = main_source.lines.index { |line| line.include?("mx.add") }
      call_end_char = main_source.lines.fetch(call_line).chomp.length

      with_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})
        uri = path_to_uri(main_path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => main_source }
        })

        response = client.send_request("textDocument/inlayHint", {
          "textDocument" => { "uri" => uri },
          "range" => {
            "start" => { "line" => call_line, "character" => 0 },
            "end" => { "line" => call_line, "character" => call_end_char }
          }
        })

        hints = response.fetch("result")
        labels = hints.map { |h| h["label"] }
        assert_includes labels, "a: "
        assert_includes labels, "b: "
      end
    end
  end

  def test_inlay_hint_suppresses_identifier_arguments_but_keeps_literal_hints_for_imported_module_calls
    Dir.mktmpdir("mt_lsp_inlay_module_call_identifiers") do |dir|
      Dir.mkdir(File.join(dir, "std"))

      module_path = File.join(dir, "ui.mt")
      module_source = <<~MT
        public function draw(width: int, title: str, count: int) -> int:
            return count
      MT
      File.write(module_path, module_source)

      main_path = File.join(dir, "main.mt")
      main_source = <<~MT
        import ui as ui

        function main() -> int:
            let screen_width = 800
            return ui.draw(screen_width, "Milk Tea", 3)
      MT
      File.write(main_path, main_source)
      call_line = main_source.lines.index { |line| line.include?("ui.draw") }
      call_end_char = main_source.lines.fetch(call_line).chomp.length

      with_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})
        uri = path_to_uri(main_path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => main_source }
        })

        response = client.send_request("textDocument/inlayHint", {
          "textDocument" => { "uri" => uri },
          "range" => {
            "start" => { "line" => call_line, "character" => 0 },
            "end" => { "line" => call_line, "character" => call_end_char }
          }
        })

        labels = response.fetch("result").map { |hint| hint["label"] }
        refute_includes labels, "width: "
        assert_includes labels, "title: "
        assert_includes labels, "count: "
      end
    end
  end

  def test_document_diagnostic_returns_full_report
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_doc_diag_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => {
          "uri" => uri,
          "languageId" => "milk-tea",
          "version" => 1,
          "text" => "function add(a: int, b: int) -> int:\n    return a + b\n"
        }
      })

      response = client.send_request("textDocument/diagnostic", {
        "textDocument" => { "uri" => uri }
      })

      result = response.fetch("result")
      assert_equal "full", result["kind"]
      assert_kind_of Array, result["items"]
      assert_equal [], result["items"]
    end
  end

  def test_document_diagnostic_reports_syntax_errors
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_doc_diag_err_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => {
          "uri" => uri,
          "languageId" => "milk-tea",
          "version" => 1,
          "text" => "function bad(\n"
        }
      })

      response = client.send_request("textDocument/diagnostic", {
        "textDocument" => { "uri" => uri }
      })

      result = response.fetch("result")
      assert_equal "full", result["kind"]
      assert result["items"].length >= 1
      assert_match(/expected|unterminated|unclosed|error/i, result["items"][0]["message"])
    end
  end

  def test_document_diagnostic_returns_unchanged_when_previous_result_matches
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_doc_diag_unchanged_test.mt"
      source = "function add(a: int, b: int) -> int:\n    return a + b\n"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => {
          "uri" => uri,
          "languageId" => "milk-tea",
          "version" => 1,
          "text" => source
        }
      })

      first = client.send_request("textDocument/diagnostic", {
        "textDocument" => { "uri" => uri }
      })
      first_result = first.fetch("result")
      assert_equal "full", first_result["kind"]
      refute_nil first_result["resultId"]

      second = client.send_request("textDocument/diagnostic", {
        "textDocument" => { "uri" => uri },
        "previousResultId" => first_result["resultId"]
      })
      second_result = second.fetch("result")
      assert_equal "unchanged", second_result["kind"]
      assert_equal first_result["resultId"], second_result["resultId"]
    end
  end

  def test_document_diagnostic_returns_full_after_content_changes
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_doc_diag_change_test.mt"
      source = "function add(a: int, b: int) -> int:\n    return a + b\n"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => {
          "uri" => uri,
          "languageId" => "milk-tea",
          "version" => 1,
          "text" => source
        }
      })

      first = client.send_request("textDocument/diagnostic", {
        "textDocument" => { "uri" => uri }
      })
      first_result = first.fetch("result")
      assert_equal "full", first_result["kind"]

      changed = "function add(a: int, b: int) -> int:\n    return a - b\n"
      client.send_notification("textDocument/didChange", {
        "textDocument" => { "uri" => uri, "version" => 2 },
        "contentChanges" => [{ "text" => changed }]
      })

      second = client.send_request("textDocument/diagnostic", {
        "textDocument" => { "uri" => uri },
        "previousResultId" => first_result["resultId"]
      })
      second_result = second.fetch("result")
      assert_equal "full", second_result["kind"]
      refute_equal first_result["resultId"], second_result["resultId"]
    end
  end

  def test_document_diagnostic_strict_current_root_diagnostics_can_be_enabled_live
    Dir.mktmpdir("milk-tea-lsp-strict-current-root") do |dir|
      FileUtils.mkdir_p(File.join(dir, "std"))
      dependency_path = File.join(dir, "dep.mt")
      main_path = File.join(dir, "main.mt")

      File.write(dependency_path, <<~MT)
        public function answer() -> int:
            return 42

        public function broken() -> int:
            return "wrong type"
      MT

      main_source = <<~MT
        import dep as dep

        function main() -> int:
            return dep.answer()
      MT
      File.write(main_path, main_source)

      main_uri = path_to_uri(main_path)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => main_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => main_source
          }
        })

        initial = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => main_uri }
        })
        assert_equal [], initial.fetch("result").fetch("items")

        client.send_notification("workspace/didChangeConfiguration", {
          "settings" => {
            "milkTea" => {
              "lsp" => {
                "strictCurrentRootDiagnostics" => true
              }
            }
          }
        })

        updated = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => main_uri }
        })
        items = updated.fetch("result").fetch("items")
        strict_root = items.find { |item| item.dig("data", "stage") == "strict-root" }

        refute_nil strict_root, "expected strict-root diagnostic, got: #{items.inspect}"
        assert_includes strict_root.fetch("message"), "strict current-root check failed"
        assert_match(/return type mismatch|wrong type/, strict_root.fetch("message"))
      end
    end
  end

  def test_document_diagnostic_strict_current_root_diagnostics_reports_invalid_entrypoint
    Dir.mktmpdir("milk-tea-lsp-strict-entrypoint") do |dir|
      FileUtils.mkdir_p(File.join(dir, "std"))
      path = File.join(dir, "main.mt")
      source = <<~MT
        function main(value: int) -> int:
            return value
      MT
      File.write(path, source)

      with_server do |client|
        client.send_request("initialize", {
          "rootUri" => path_to_uri(dir),
          "capabilities" => {},
          "initializationOptions" => {
            "milkTea" => {
              "lsp" => {
                "strictCurrentRootDiagnostics" => true
              }
            }
          }
        })

        uri = path_to_uri(path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => uri }
        })
        items = response.fetch("result").fetch("items")
        strict_root = items.find { |item| item.dig("data", "stage") == "strict-root" }

        refute_nil strict_root, "expected strict-root diagnostic, got: #{items.inspect}"
        assert_equal "build/error", strict_root.fetch("code")
        assert_includes strict_root.fetch("message"), "root main is not a valid executable entrypoint"
      end
    end
  end

  def test_declaration_and_type_definition_delegate_to_definition_location
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_decl_type_def_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_CALL }
      })

      declaration = client.send_request("textDocument/declaration", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => 4, "character" => 11 }
      })
      type_definition = client.send_request("textDocument/typeDefinition", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => 4, "character" => 11 }
      })

      assert_equal uri, declaration.dig("result", "uri")
      assert_equal 0, declaration.dig("result", "range", "start", "line")
      assert_equal 9, declaration.dig("result", "range", "start", "character")

      assert_equal uri, type_definition.dig("result", "uri")
      assert_equal 0, type_definition.dig("result", "range", "start", "line")
      assert_equal 9, type_definition.dig("result", "range", "start", "character")
    end
  end

  def test_definition_falls_back_to_other_workspace_file
    Dir.mktmpdir("milk-tea-lsp-def") do |dir|
      shared_path = File.join(dir, "shared.mt")
      main_path = File.join(dir, "main.mt")
      File.write(shared_path, <<~MT)
        function shared(a: int, b: int) -> int:
            return a + b
      MT
      File.write(main_path, <<~MT)
        function main() -> int:
            return shared(1, 2)
      MT

      root_uri = path_to_uri(dir)
      shared_uri = path_to_uri(shared_path)
      main_uri = path_to_uri(main_path)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => root_uri, "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => main_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => File.read(main_path)
          }
        })

        definition = client.send_request("textDocument/definition", {
          "textDocument" => { "uri" => main_uri },
          "position"     => { "line" => 1, "character" => 11 }
        })

        assert_equal shared_uri, definition.dig("result", "uri")
        assert_equal 0, definition.dig("result", "range", "start", "line")
        assert_equal 9, definition.dig("result", "range", "start", "character")
      end
    end
  end

  def test_definition_on_imported_module_member_jumps_to_member_declaration
    Dir.mktmpdir("milk-tea-lsp-def-member") do |dir|
      lib_path = File.join(dir, "demo", "lib.mt")
      main_path = File.join(dir, "main.mt")
      Dir.mkdir(File.join(dir, "demo"))

      lib_source = <<~MT
        public function greet() -> int:
            return 1
      MT
      main_source = <<~MT
        import demo.lib as lib

        function main() -> int:
            return lib.greet()
      MT

      File.write(lib_path, lib_source)
      File.write(main_path, main_source)

      root_uri = path_to_uri(dir)
      lib_uri = path_to_uri(lib_path)
      main_uri = path_to_uri(main_path)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => root_uri, "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => main_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => main_source
          }
        })

        call_line = main_source.lines.index { |line| line.include?("lib.greet") }
        call_char = main_source.lines[call_line].index("greet")

        definition = client.send_request("textDocument/definition", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => call_line, "character" => call_char }
        })
        definition_line = lib_source.lines.index { |line| line.include?("function greet") }
        definition_char = lib_source.lines.fetch(definition_line).index("greet")

        assert_equal lib_uri, definition.dig("result", "uri")
        assert_equal definition_line, definition.dig("result", "range", "start", "line")
        assert_equal definition_char, definition.dig("result", "range", "start", "character")
      end
    end
  end

  def test_definition_on_imported_module_member_refreshes_when_closed_file_changes_within_same_second
    Dir.mktmpdir("milk-tea-lsp-def-member-mtime") do |dir|
      lib_path = File.join(dir, "demo", "lib.mt")
      main_path = File.join(dir, "main.mt")
      FileUtils.mkdir_p(File.join(dir, "demo"))

      initial_lib_source = <<~MT
        function greet() -> int:
            return 1
      MT
      updated_lib_source = <<~MT
        # shifted on purpose
        function greet() -> int:
            return 1
      MT
      main_source = <<~MT
        import demo.lib as lib

        function main() -> int:
            return lib.greet()
      MT

      File.write(lib_path, initial_lib_source)
      File.write(main_path, main_source)

      first_time = Time.at(Time.now.to_i, 100_000_000, :nsec)
      second_time = Time.at(first_time.to_i, 700_000_000, :nsec)
      File.utime(first_time, first_time, lib_path)

      root_uri = path_to_uri(dir)
      lib_uri = path_to_uri(lib_path)
      main_uri = path_to_uri(main_path)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => root_uri, "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => main_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => main_source
          }
        })

        call_line = main_source.lines.index { |line| line.include?("lib.greet") }
        call_char = main_source.lines[call_line].index("greet") + 1

        first_definition = client.send_request("textDocument/definition", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => call_line, "character" => call_char }
        })

        assert_equal lib_uri, first_definition.dig("result", "uri")
        assert_equal 0, first_definition.dig("result", "range", "start", "line")

        File.write(lib_path, updated_lib_source)
        File.utime(second_time, second_time, lib_path)

        second_definition = client.send_request("textDocument/definition", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => call_line, "character" => call_char }
        })

        assert_equal lib_uri, second_definition.dig("result", "uri")
        assert_equal 1, second_definition.dig("result", "range", "start", "line")
      end
    end
  end

  def test_hover_on_imported_module_member_uses_loose_workspace_root_for_import_resolution
    Dir.mktmpdir("milk-tea-lsp-hover-imported-module") do |dir|
      lib_path = File.join(dir, "demo", "lib.mt")
      main_path = File.join(dir, "main.mt")
      FileUtils.mkdir_p(File.join(dir, "demo"))

      lib_source = <<~MT
        public function greet() -> int:
            return 1
      MT
      main_source = <<~MT
        import demo.lib as lib

        function main() -> int:
            return lib.greet()
      MT

      File.write(lib_path, lib_source)
      File.write(main_path, main_source)

      root_uri = path_to_uri(dir)
      lib_uri = path_to_uri(lib_path)
      main_uri = path_to_uri(main_path)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => root_uri, "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => main_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => main_source
          }
        })

        call_line = main_source.lines.index { |line| line.include?("lib.greet") }
        call_char = main_source.lines[call_line].index("greet")

        hover = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => call_line, "character" => call_char }
        })

        hover_value = hover.dig("result", "contents", "value")
        assert_includes hover_value, "function greet() -> int"
        assert_includes hover_value, "Defined at: [demo/lib.mt:1](#{lib_uri}#L1)"
      end
    end
  end

  def test_definition_on_imported_type_static_method_jumps_to_method_declaration
    Dir.mktmpdir("milk-tea-lsp-def-imported-type") do |dir|
      std_dir = File.join(dir, "std")
      FileUtils.mkdir_p(std_dir)

      foo_source = <<~MT
        public struct Point:
            x: int
            y: int

        extending Point:
            public static function zero() -> int:
                return 0
      MT
      main_source = <<~MT
        import std.foo as foo

        public function main() -> int:
            return foo.Point.zero()
      MT

      foo_path = File.join(std_dir, "foo.mt")
      main_path = File.join(dir, "main.mt")
      File.write(foo_path, foo_source)
      File.write(main_path, main_source)

      root_uri = path_to_uri(dir)
      foo_uri = path_to_uri(foo_path)
      main_uri = path_to_uri(main_path)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => root_uri, "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => main_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => main_source
          }
        })

        call_line = main_source.lines.index { |line| line.include?("foo.Point.zero") }
        call_char = main_source.lines[call_line].index("zero") + 1
        definition_line = foo_source.lines.index { |line| line.include?("static function zero") }
        definition_char = foo_source.lines[definition_line].index("zero")

        definition = client.send_request("textDocument/definition", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => call_line, "character" => call_char }
        })

        assert_equal foo_uri, definition.dig("result", "uri")
        assert_equal definition_line, definition.dig("result", "range", "start", "line")
        assert_equal definition_char, definition.dig("result", "range", "start", "character")
      end
    end
  end

  def test_type_definition_on_imported_type_static_method_jumps_to_method_declaration
    Dir.mktmpdir("milk-tea-lsp-type-def-imported-type") do |dir|
      std_dir = File.join(dir, "std")
      FileUtils.mkdir_p(std_dir)

      foo_source = <<~MT
        public struct Point:
            x: int
            y: int

        extending Point:
            public static function zero() -> int:
                return 0
      MT
      main_source = <<~MT
        import std.foo as foo

        public function main() -> int:
            return foo.Point.zero()
      MT

      foo_path = File.join(std_dir, "foo.mt")
      main_path = File.join(dir, "main.mt")
      File.write(foo_path, foo_source)
      File.write(main_path, main_source)

      root_uri = path_to_uri(dir)
      foo_uri = path_to_uri(foo_path)
      main_uri = path_to_uri(main_path)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => root_uri, "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => main_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => main_source
          }
        })

        call_line = main_source.lines.index { |line| line.include?("foo.Point.zero") }
        call_char = main_source.lines[call_line].index("zero") + 1
        definition_line = foo_source.lines.index { |line| line.include?("static function zero") }
        definition_char = foo_source.lines[definition_line].index("zero")

        definition = client.send_request("textDocument/typeDefinition", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => call_line, "character" => call_char }
        })

        assert_equal foo_uri, definition.dig("result", "uri")
        assert_equal definition_line, definition.dig("result", "range", "start", "line")
        assert_equal definition_char, definition.dig("result", "range", "start", "character")
      end
    end
  end

  def test_did_change_watched_files_refreshes_workspace_index
    Dir.mktmpdir("milk-tea-lsp-watch") do |dir|
      watched_path = File.join(dir, "watched.mt")
      File.write(watched_path, <<~MT)
        function old_name() -> int:
            return 0
      MT

      root_uri = path_to_uri(dir)
      watched_uri = path_to_uri(watched_path)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => root_uri, "capabilities" => {} })
        client.send_notification("initialized", {})

        old_symbols = client.send_request("workspace/symbol", { "query" => "old_name" })
        old_names = old_symbols.fetch("result").map { |s| s["name"] }
        assert_includes old_names, "old_name"

        File.write(watched_path, <<~MT)
          function new_name() -> int:
              return 0
        MT

        client.send_notification("workspace/didChangeWatchedFiles", {
          "changes" => [{ "uri" => watched_uri, "type" => 2 }]
        })

        new_symbols = client.send_request("workspace/symbol", { "query" => "new_name" })
        new_names = new_symbols.fetch("result").map { |s| s["name"] }
        assert_includes new_names, "new_name"
      end
    end
  end

  def test_document_diagnostic_refreshes_after_imported_module_watched_change
    Dir.mktmpdir("milk-tea-lsp-watch-diagnostics") do |dir|
      Dir.mkdir(File.join(dir, "std"))

      lib_path = File.join(dir, "mathx.mt")
      main_path = File.join(dir, "main.mt")

      File.write(lib_path, <<~MT)
        public function greet() -> int:
            return 1
      MT
      main_source = <<~MT
        import mathx as mx

        function main() -> int:
            return mx.greet()
      MT
      File.write(main_path, main_source)

      root_uri = path_to_uri(dir)
      lib_uri = path_to_uri(lib_path)
      main_uri = path_to_uri(main_path)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => root_uri, "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => main_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => main_source
          }
        })

        first = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => main_uri }
        })
        first_result = first.fetch("result")
        assert_equal "full", first_result["kind"]
        assert_equal [], first_result["items"]

        File.write(lib_path, <<~MT)
          public function greet() -> str:
              return "oops"
        MT

        client.send_notification("workspace/didChangeWatchedFiles", {
          "changes" => [{ "uri" => lib_uri, "type" => 2 }]
        })

        second = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => main_uri },
          "previousResultId" => first_result["resultId"]
        })
        second_result = second.fetch("result")

        assert_equal "full", second_result["kind"]
        refute_equal first_result["resultId"], second_result["resultId"]
        assert_operator second_result.fetch("items").length, :>=, 1
      end
    end
  end

  def test_document_diagnostic_refreshes_after_imported_module_watched_create
    Dir.mktmpdir("milk-tea-lsp-watch-create-diagnostics") do |dir|
      Dir.mkdir(File.join(dir, "std"))

      lib_path = File.join(dir, "mathx.mt")
      main_path = File.join(dir, "main.mt")

      main_source = <<~MT
        import mathx as mx

        function main() -> int:
            return mx.greet()
      MT
      File.write(main_path, main_source)

      root_uri = path_to_uri(dir)
      lib_uri = path_to_uri(lib_path)
      main_uri = path_to_uri(main_path)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => root_uri, "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => main_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => main_source
          }
        })

        first = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => main_uri }
        })
        first_result = first.fetch("result")
        first_messages = first_result.fetch("items").map { |item| item["message"] }
        assert first_messages.any? { |message| message.include?("module not found") }

        File.write(lib_path, <<~MT)
          public function greet() -> int:
              return 1
        MT

        client.send_notification("workspace/didChangeWatchedFiles", {
          "changes" => [{ "uri" => lib_uri, "type" => 1 }]
        })

        second = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => main_uri },
          "previousResultId" => first_result["resultId"]
        })
        second_result = second.fetch("result")

        assert_equal "full", second_result["kind"]
        refute_equal first_result["resultId"], second_result["resultId"]
        assert_equal [], second_result.fetch("items")
      end
    end
  end

  def test_document_diagnostic_refreshes_after_imported_module_watched_delete
    Dir.mktmpdir("milk-tea-lsp-watch-delete-diagnostics") do |dir|
      Dir.mkdir(File.join(dir, "std"))

      lib_path = File.join(dir, "mathx.mt")
      main_path = File.join(dir, "main.mt")

      File.write(lib_path, <<~MT)
        public function greet() -> int:
            return 1
      MT
      main_source = <<~MT
        import mathx as mx

        function main() -> int:
            return mx.greet()
      MT
      File.write(main_path, main_source)

      root_uri = path_to_uri(dir)
      lib_uri = path_to_uri(lib_path)
      main_uri = path_to_uri(main_path)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => root_uri, "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => main_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => main_source
          }
        })

        first = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => main_uri }
        })
        first_result = first.fetch("result")
        assert_equal [], first_result.fetch("items")

        File.delete(lib_path)

        client.send_notification("workspace/didChangeWatchedFiles", {
          "changes" => [{ "uri" => lib_uri, "type" => 3 }]
        })

        second = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => main_uri },
          "previousResultId" => first_result["resultId"]
        })
        second_result = second.fetch("result")
        second_messages = second_result.fetch("items").map { |item| item["message"] }

        assert_equal "full", second_result["kind"]
        refute_equal first_result["resultId"], second_result["resultId"]
        assert second_messages.any? { |message| message.include?("module not found") }
      end
    end
  end

  def test_document_diagnostic_refreshes_after_imported_module_did_change
    Dir.mktmpdir("milk-tea-lsp-didchange-diagnostics") do |dir|
      Dir.mkdir(File.join(dir, "std"))
      helper_path = File.join(dir, "helper.mt")
      main_path = File.join(dir, "main.mt")

      helper_initial = <<~MT
      MT
      helper_updated = <<~MT
        extending str:
            public function excited() -> int:
                return 1
      MT
      main_source = <<~MT
        import helper as helper

        function main() -> int:
            return "milk".excited()
      MT

      File.write(helper_path, helper_initial)
      File.write(main_path, main_source)

      root_uri = path_to_uri(dir)
      helper_uri = path_to_uri(helper_path)
      main_uri = path_to_uri(main_path)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => root_uri, "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => helper_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => helper_initial
          }
        })
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => main_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => main_source
          }
        })

        first = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => main_uri }
        })
        first_result = first.fetch("result")
        first_codes = first_result.fetch("items").map { |item| item["code"] }

        assert_equal "full", first_result["kind"]
        assert_operator first_result.fetch("items").length, :>=, 1
        assert_includes first_codes, "sema/error"

        client.send_notification("textDocument/didChange", {
          "textDocument" => { "uri" => helper_uri, "version" => 2 },
          "contentChanges" => [{ "text" => helper_updated }]
        })

        second = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => main_uri },
          "previousResultId" => first_result["resultId"]
        })
        second_result = second.fetch("result")
        second_codes = second_result.fetch("items").map { |item| item["code"] }

        assert_equal "full", second_result["kind"]
        refute_equal first_result["resultId"], second_result["resultId"]
        refute_includes second_codes, "sema/error"
      end
    end
  end

  def test_document_diagnostic_locked_uses_package_lock_when_manifest_dependencies_drift
    Dir.mktmpdir("milk-tea-lsp-locked-diagnostics") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      ui_root = File.join(dir, "libs", "ui")
      app_src_dir = File.join(app_root, "src", "snake_duel")
      ui_src_dir = File.join(ui_root, "src", "teefan", "ui")

      FileUtils.mkdir_p(app_src_dir)
      FileUtils.mkdir_p(ui_src_dir)

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"

        [dependencies]
        "teefan.ui" = { path = "../../libs/ui" }
      TOML

      File.write(File.join(ui_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "0.3.0"
        kind = "library"
        source_root = "src"
      TOML

      main_source = <<~MT
        import teefan.ui.layout as layout

        function main() -> int:
            let value = layout.default_width()
            unsafe:
                let copy = value + 1
            return value
      MT

      File.write(File.join(app_src_dir, "main.mt"), main_source)
      File.write(File.join(ui_src_dir, "layout.mt"), <<~MT)
        public function default_width() -> int:
            return 10
      MT

      MilkTea::PackageLock.write(app_root)

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"
      TOML

      root_uri = path_to_uri(dir)
      main_path = File.join(app_src_dir, "main.mt")
      main_uri = path_to_uri(main_path)

      with_server do |client|
        client.send_request("initialize", {
          "rootUri" => root_uri,
          "capabilities" => {},
          "initializationOptions" => {
            "milkTea" => {
              "lsp" => {
                "dependencyResolution" => "locked"
              }
            }
          }
        })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => main_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => main_source
          }
        })

        response = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => main_uri }
        })
        result = response.fetch("result")
        items = result.fetch("items")
        messages = items.map { |item| item["message"] }

        refute messages.any? { |message| message.match?(/module not found|package dependency not declared/) },
               "expected locked diagnostics to avoid live-manifest import failures, got: #{messages.inspect}"
      end
    end
  end

  def test_document_diagnostic_frozen_reports_stale_package_lock
    Dir.mktmpdir("milk-tea-lsp-frozen-diagnostics") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      ui_root = File.join(dir, "libs", "ui")
      app_src_dir = File.join(app_root, "src", "snake_duel")
      ui_src_dir = File.join(ui_root, "src", "teefan", "ui")

      FileUtils.mkdir_p(app_src_dir)
      FileUtils.mkdir_p(ui_src_dir)

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"

        [dependencies]
        "teefan.ui" = { path = "../../libs/ui" }
      TOML

      File.write(File.join(ui_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "0.3.0"
        kind = "library"
        source_root = "src"
      TOML

      main_source = <<~MT
        import teefan.ui.layout as layout

        function main() -> int:
            let value = layout.default_width()
            unsafe:
                let copy = value + 1
            return value
      MT

      File.write(File.join(app_src_dir, "main.mt"), main_source)
      File.write(File.join(ui_src_dir, "layout.mt"), <<~MT)
        public function default_width() -> int:
            return 10
      MT

      MilkTea::PackageLock.write(app_root)

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"
      TOML

      root_uri = path_to_uri(dir)
      main_path = File.join(app_src_dir, "main.mt")
      main_uri = path_to_uri(main_path)

      with_server do |client|
        client.send_request("initialize", {
          "rootUri" => root_uri,
          "capabilities" => {},
          "initializationOptions" => {
            "milkTea" => {
              "lsp" => {
                "dependencyResolution" => "frozen"
              }
            }
          }
        })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => main_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => main_source
          }
        })

        response = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => main_uri }
        })
        result = response.fetch("result")
        items = result.fetch("items")
        messages = items.map { |item| item["message"] }

        assert messages.any? { |message| message.include?("package.lock is out of date") },
               "expected frozen diagnostics to report stale package.lock, got: #{messages.inspect}"
      end
    end
  end

  def test_document_diagnostic_platform_override_uses_platform_specific_import_variant_from_initialize
    Dir.mktmpdir("milk-tea-lsp-platform-diagnostics") do |dir|
      main_path = File.join(dir, "main.mt")
      support_path = File.join(dir, "support.mt")
      support_windows_path = File.join(dir, "support.windows.mt")

      File.write(File.join(dir, "package.toml"), <<~TOML)
        [package]
        name = "demo"
      TOML

      main_source = <<~MT
        import support

        function main() -> int:
            return support.value()
      MT

      File.write(main_path, main_source)
      File.write(support_path, <<~MT)
      MT
      File.write(support_windows_path, <<~MT)
        public function value() -> int:
            return 2
      MT

      main_uri = path_to_uri(main_path)

      with_server do |client|
        client.send_request("initialize", {
          "rootUri" => path_to_uri(dir),
          "capabilities" => {},
          "initializationOptions" => {
            "milkTea" => {
              "lsp" => {
                "platform" => "windows"
              }
            }
          }
        })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => main_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => main_source
          }
        })

        response = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => main_uri }
        })
        items = response.fetch("result").fetch("items")
        messages = items.map { |item| item["message"] }

        refute messages.any? { |message| message.match?(/function not found|value/) },
               "expected windows platform override to resolve support.windows.mt, got: #{messages.inspect}"
      end
    end
  end

  def test_document_diagnostic_platform_override_updates_live_via_did_change_configuration
    Dir.mktmpdir("milk-tea-lsp-platform-live-change") do |dir|
      main_path = File.join(dir, "main.mt")
      support_path = File.join(dir, "support.mt")
      support_windows_path = File.join(dir, "support.windows.mt")

      File.write(File.join(dir, "package.toml"), <<~TOML)
        [package]
        name = "demo"
      TOML

      main_source = <<~MT
        import support

        function main() -> int:
            return support.value()
      MT

      File.write(main_path, main_source)
      File.write(support_path, <<~MT)
      MT
      File.write(support_windows_path, <<~MT)
        public function value() -> int:
            return 2
      MT

      main_uri = path_to_uri(main_path)

      with_server do |client|
        client.send_request("initialize", {
          "rootUri" => path_to_uri(dir),
          "capabilities" => {}
        })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => main_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => main_source
          }
        })

        initial_response = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => main_uri }
        })
        initial_messages = initial_response.fetch("result").fetch("items").map { |item| item["message"] }
        assert initial_messages.any? { |message| message.match?(/function not found|value/) },
               "expected shared-platform diagnostics before override, got: #{initial_messages.inspect}"

        client.send_notification("workspace/didChangeConfiguration", {
          "settings" => {
            "milkTea" => {
              "lsp" => {
                "platform" => "windows"
              }
            }
          }
        })

        updated_response = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => main_uri }
        })
        updated_messages = updated_response.fetch("result").fetch("items").map { |item| item["message"] }

        refute updated_messages.any? { |message| message.match?(/function not found|value/) },
               "expected live platform override to invalidate diagnostics caches, got: #{updated_messages.inspect}"
      end
    end
  end

  def test_diagnostic_with_std_fs_import_honors_configured_platform
    Dir.mktmpdir("milk-tea-lsp-platform-std-fs") do |dir|
      main_path = File.join(dir, "main.mt")

      File.write(File.join(dir, "package.toml"), <<~TOML)
        [package]
        name = "demo"
      TOML

      main_source = <<~MT
        import std.fs as fs

        function main() -> int:
            var temp = fs.temporary_directory()
            defer temp.release()
            return 0
      MT

      File.write(main_path, main_source)
      main_uri = path_to_uri(main_path)
      with_server do |client|
        client.send_request("initialize", {
          "rootUri" => path_to_uri(dir),
          "capabilities" => {},
          "initializationOptions" => {
            "milkTea" => {
              "lsp" => {
                "platform" => "windows"
              }
            }
          }
        })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => main_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => main_source
          }
        })

        diagnostic = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => main_uri }
        })
        items = diagnostic.fetch("result").fetch("items")
        messages = items.map { |item| item["message"] }

        refute messages.any? { |message| message.match?(/function not found|temporary_directory/) },
               "expected configured platform diagnostics to resolve std.fs members, got: #{messages.inspect}"
      end
    end
  end

  def test_completion_locked_uses_package_lock_when_manifest_dependencies_drift
    Dir.mktmpdir("milk-tea-lsp-locked-completion") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      ui_root = File.join(dir, "libs", "ui")
      app_src_dir = File.join(app_root, "src", "snake_duel")
      ui_src_dir = File.join(ui_root, "src", "teefan", "ui")

      FileUtils.mkdir_p(app_src_dir)
      FileUtils.mkdir_p(ui_src_dir)

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"

        [dependencies]
        "teefan.ui" = { path = "../../libs/ui" }
      TOML

      File.write(File.join(ui_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "0.3.0"
        kind = "library"
        source_root = "src"
      TOML

      main_source = <<~MT
        import teefan.ui.layout as duel_ui

        function main() -> int:
            return duel_ui.default_width()
      MT

      File.write(File.join(app_src_dir, "main.mt"), main_source)
      File.write(File.join(ui_src_dir, "layout.mt"), <<~MT)
        public function default_width() -> int:
            return 10
      MT

      MilkTea::PackageLock.write(app_root)

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"
      TOML

      root_uri = path_to_uri(dir)
      main_path = File.join(app_src_dir, "main.mt")
      main_uri = path_to_uri(main_path)
      partial_source = main_source.sub("return duel_ui.default_width()", "return duel_ui.")
      dot_line = partial_source.lines.index { |line| line.include?("return duel_ui.") }
      dot_char = partial_source.lines.fetch(dot_line).chomp.length

      with_server do |client|
        client.send_request("initialize", {
          "rootUri" => root_uri,
          "capabilities" => {},
          "initializationOptions" => {
            "milkTea" => {
              "lsp" => {
                "dependencyResolution" => "locked"
              }
            }
          }
        })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => main_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => main_source
          }
        })
        client.send_notification("textDocument/didChange", {
          "textDocument" => { "uri" => main_uri, "version" => 2 },
          "contentChanges" => [{ "text" => partial_source }]
        })

        response = client.send_request("textDocument/completion", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => dot_line, "character" => dot_char }
        })
        result = response.fetch("result")
        items = result.fetch("items")
        labels = items.map { |item| item["label"] }
        default_width = items.find { |item| item["label"] == "default_width" }

        assert_includes labels, "default_width"
        assert_equal 3, default_width.fetch("kind")
      end
    end
  end

  def test_hover_and_completion_still_work_for_resolved_imports_when_another_import_is_missing
    Dir.mktmpdir("milk-tea-lsp-missing-import-partial-analysis") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      ui_root = File.join(dir, "libs", "ui")
      app_src_dir = File.join(app_root, "src", "snake_duel")
      ui_src_dir = File.join(ui_root, "src", "teefan", "ui")

      FileUtils.mkdir_p(app_src_dir)
      FileUtils.mkdir_p(ui_src_dir)

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"

        [dependencies]
        "teefan.ui" = { path = "../../libs/ui" }
      TOML

      File.write(File.join(ui_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "0.1.0"
        kind = "library"
        source_root = "src"
      TOML

      File.write(File.join(ui_src_dir, "layout.mt"), <<~MT)
        public function default_width() -> int:
            return 10
      MT

      main_path = File.join(app_src_dir, "main.mt")
      main_source = <<~MT
        import teefan.ui.layout as layout
        import test

        function main() -> int:
            return layout.default_width()
      MT
      File.write(main_path, main_source)

      root_uri = path_to_uri(dir)
      main_uri = path_to_uri(main_path)
      dot_source = main_source.sub("return layout.default_width()", "return layout.")
      dot_line = dot_source.lines.index { |line| line.include?("return layout.") }
      dot_char = dot_source.lines.fetch(dot_line).chomp.length
      hover_line = main_source.lines.index { |line| line.include?("layout.default_width") }
      hover_char = main_source.lines.fetch(hover_line).index("layout") + 1

      with_server do |client|
        client.send_request("initialize", { "rootUri" => root_uri, "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => main_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => main_source,
          }
        })

        hover = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => hover_line, "character" => hover_char },
        })
        hover_value = hover.dig("result", "contents", "value")
        assert_includes hover_value, "module teefan.ui.layout"

        client.send_notification("textDocument/didChange", {
          "textDocument" => { "uri" => main_uri, "version" => 2 },
          "contentChanges" => [{ "text" => dot_source }],
        })

        completion = client.send_request("textDocument/completion", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => dot_line, "character" => dot_char },
        })
        labels = completion.fetch("result").fetch("items").map { |item| item.fetch("label") }

        assert_includes labels, "default_width"
      end
    end
  end

  def test_hover_and_completion_still_work_after_invalid_top_level_declaration
    Dir.mktmpdir("milk-tea-lsp-top-level-parse-recovery") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      ui_root = File.join(dir, "libs", "ui")
      app_src_dir = File.join(app_root, "src", "snake_duel")
      ui_src_dir = File.join(ui_root, "src", "teefan", "ui")

      FileUtils.mkdir_p(app_src_dir)
      FileUtils.mkdir_p(ui_src_dir)

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"

        [dependencies]
        "teefan.ui" = { path = "../../libs/ui" }
      TOML

      File.write(File.join(ui_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "0.1.0"
        kind = "library"
        source_root = "src"
      TOML

      File.write(File.join(ui_src_dir, "layout.mt"), <<~MT)
        public function default_width() -> int:
            return 10
      MT

      main_path = File.join(app_src_dir, "main.mt")
      main_source = <<~MT
        import teefan.ui.layout as layout

        const board_height: int = 20a
        const board_cells: int = 200

        function main() -> int:
        return layout.default_width() + board_height + board_cells
      MT
      File.write(main_path, main_source)

      root_uri = path_to_uri(dir)
      main_uri = path_to_uri(main_path)
      dot_source = main_source.sub("return layout.default_width() + board_height + board_cells", "return layout.")
      dot_line = dot_source.lines.index { |line| line.include?("return layout.") }
      dot_char = dot_source.lines.fetch(dot_line).chomp.length
      hover_line = main_source.lines.index { |line| line.include?("layout.default_width") }
      hover_char = main_source.lines.fetch(hover_line).index("layout") + 1
      board_height_char = main_source.lines.fetch(hover_line).index("board_height") + 1

      with_server do |client|
        client.send_request("initialize", { "rootUri" => root_uri, "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => main_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => main_source,
          }
        })

        diagnostics = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => main_uri },
        })
        messages = diagnostics.fetch("result").fetch("items").map { |item| item.fetch("message") }
        assert_includes messages, "expected end of statement at #{main_uri}:3:29"

        board_height_hover = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => hover_line, "character" => board_height_char },
        })
        board_height_hover_value = board_height_hover.dig("result", "contents", "value")
        assert_includes board_height_hover_value, "const board_height: int (immutable)"

        hover = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => hover_line, "character" => hover_char },
        })
        hover_value = hover.dig("result", "contents", "value")
        assert_includes hover_value, "module teefan.ui.layout"

        client.send_notification("textDocument/didChange", {
          "textDocument" => { "uri" => main_uri, "version" => 2 },
          "contentChanges" => [{ "text" => dot_source }],
        })

        completion = client.send_request("textDocument/completion", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => dot_line, "character" => dot_char },
        })
        labels = completion.fetch("result").fetch("items").map { |item| item.fetch("label") }

        assert_includes labels, "default_width"
      end
    end
  end

  def test_hover_still_works_after_invalid_statement_in_block
    Dir.mktmpdir("milk-tea-lsp-block-parse-recovery") do |dir|
      path = File.join(dir, "main.mt")
      source = <<~MT
        function main() -> int:
            let value = 1
            let broken = 20a
            return value
      MT
      File.write(path, source)
      hover_line = source.lines.index { |line| line.include?("return value") }
      hover_char = source.lines.fetch(hover_line).index("value") + 1

      with_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})

        uri = path_to_uri(path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => source,
          },
        })

        diagnostics = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => uri },
        })
        messages = diagnostics.fetch("result").fetch("items").map { |item| item.fetch("message") }
        assert_includes messages, "expected end of statement at #{uri}:3:20"

        hover_response = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => uri },
          "position" => { "line" => hover_line, "character" => hover_char },
        })

        hover_value = hover_response.dig("result", "contents", "value")
        assert_includes hover_value, "let value: int (immutable)"
      end
    end
  end

  def test_hover_still_works_after_invalid_typed_local_declaration
    Dir.mktmpdir("milk-tea-lsp-typed-local-recovery") do |dir|
      path = File.join(dir, "main.mt")
      source = <<~MT
        struct Point:
            x: int
            y: int

        extending Point:
            function length() -> int:
                return this.x + this.y

        function main() -> int:
            let p: Point = 20a
            return p.x
      MT
      File.write(path, source)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})

        uri = path_to_uri(path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => source,
          },
        })

        diagnostics = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => uri },
        })
        messages = diagnostics.fetch("result").fetch("items").map { |item| item.fetch("message") }
        assert_includes messages, "expected end of statement at #{uri}:10:22"

        hover_line = source.lines.index { |line| line.include?("return p.x") }
        p_char = source.lines.fetch(hover_line).index("p")
        x_char = source.lines.fetch(hover_line).index("x")

        p_hover = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => uri },
          "position" => { "line" => hover_line, "character" => p_char },
        })
        p_hover_value = p_hover.dig("result", "contents", "value")
        assert_includes p_hover_value, "let p: main.Point (immutable)"

        x_hover = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => uri },
          "position" => { "line" => hover_line, "character" => x_char },
        })
        x_hover_value = x_hover.dig("result", "contents", "value")
        assert_includes x_hover_value, "field x: int"
      end
    end
  end

  def test_hover_still_works_after_invalid_untyped_local_declaration
    Dir.mktmpdir("milk-tea-lsp-untyped-local-recovery") do |dir|
      path = File.join(dir, "main.mt")
      source = <<~MT
        function main() -> int:
            let value = 20a
            return value
      MT
      File.write(path, source)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})

        uri = path_to_uri(path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => source,
          },
        })

        diagnostics = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => uri },
        })
        messages = diagnostics.fetch("result").fetch("items").map { |item| item.fetch("message") }
        assert_includes messages, "expected end of statement at #{uri}:2:19"

        hover_response = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => uri },
          "position" => { "line" => 2, "character" => 11 },
        })

        hover_value = hover_response.dig("result", "contents", "value")
        assert_includes hover_value, "let value: <error> (immutable)"
      end
    end
  end

  def test_hover_still_works_after_invalid_let_else_declaration
    Dir.mktmpdir("milk-tea-lsp-let-else-recovery") do |dir|
      path = File.join(dir, "main.mt")
      source = <<~MT
        function main(handle: ptr[int]?) -> int:
            let value = handle else as error
                return 1
            unsafe:
                return read(value)
      MT
      File.write(path, source)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})

        uri = path_to_uri(path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => source,
          },
        })

        diagnostics = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => uri },
        })
        messages = diagnostics.fetch("result").fetch("items").map { |item| item.fetch("message") }
        assert messages.any? { |message| message.include?("expected ':' before block") }

        hover_line = source.lines.index { |line| line.include?("read(value)") }
        hover_char = source.lines.fetch(hover_line).index("value")

        hover_response = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => uri },
          "position" => { "line" => hover_line, "character" => hover_char },
        })

        hover_value = hover_response.dig("result", "contents", "value")
        assert_includes hover_value, "let value: ptr[int] (immutable)"
      end
    end
  end

  def test_completion_works_for_file_backed_local_value_receiver_after_invalid_last_statement
    Dir.mktmpdir("milk-tea-lsp-file-backed-error-stmt-completion") do |dir|
      path = File.join(dir, "main.mt")
      source = <<~MT
        struct Point:
            x: int
            y: int

        extending Point:
            function length() -> int:
                return this.x + this.y

        function main() -> int:
            let p = Point(x = 1, y = 2)
            return p.
      MT
      File.write(path, source)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})

        uri = path_to_uri(path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => source,
          },
        })

        diagnostics = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => uri },
        })
        messages = diagnostics.fetch("result").fetch("items").map { |item| item.fetch("message") }
        assert messages.any? { |message| message.include?("expected member name after '.'") }

        dot_line = source.lines.index { |line| line.include?("return p.") }
        dot_char = source.lines.fetch(dot_line).chomp.length

        completion = client.send_request("textDocument/completion", {
          "textDocument" => { "uri" => uri },
          "position" => { "line" => dot_line, "character" => dot_char },
        })
        items = completion.fetch("result").fetch("items")
        labels = items.map { |item| item.fetch("label") }
        kinds_by_label = items.to_h { |item| [item.fetch("label"), item.fetch("kind")] }

        assert_includes labels, "x"
        assert_includes labels, "y"
        assert_includes labels, "length"
        assert_equal 10, kinds_by_label["x"]
        assert_equal 2, kinds_by_label["length"]
      end
    end
  end

  def test_hover_works_inside_invalid_block_header_body
    Dir.mktmpdir("milk-tea-lsp-error-block-hover") do |dir|
      path = File.join(dir, "main.mt")
      source = <<~MT
        function main() -> int:
            let value = 1
            unsafe
                let inner = value
                return inner
      MT
      File.write(path, source)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})

        uri = path_to_uri(path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => source,
          },
        })

        diagnostics = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => uri },
        })
        messages = diagnostics.fetch("result").fetch("items").map { |item| item.fetch("message") }
        assert messages.any? { |message| message.include?("expected ':' after unsafe") }

        hover_line = source.lines.index { |line| line.include?("return inner") }
        hover_char = source.lines.fetch(hover_line).index("inner")

        hover_response = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => uri },
          "position" => { "line" => hover_line, "character" => hover_char },
        })

        hover_value = hover_response.dig("result", "contents", "value")
        assert_includes hover_value, "let inner: int (immutable)"
      end
    end
  end

  def test_diagnostics_do_not_report_unsafe_requirement_inside_invalid_unsafe_block
    Dir.mktmpdir("milk-tea-lsp-invalid-unsafe-diagnostics") do |dir|
      path = File.join(dir, "main.mt")
      source = <<~MT
        struct Counter:
            value: int

        function main() -> int:
            var counter = Counter(value = 3)
            let counter_ptr = ptr_of(counter)
            unsafe
                return read(counter_ptr).value
      MT
      File.write(path, source)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})

        uri = path_to_uri(path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => source,
          },
        })

        diagnostics = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => uri },
        })
        messages = diagnostics.fetch("result").fetch("items").map { |item| item.fetch("message") }

        assert messages.any? { |message| message.include?("expected ':' after unsafe") }
        refute messages.any? { |message| message.include?("raw pointer dereference requires unsafe") }
      end
    end
  end

  def test_completion_uses_flow_refined_type_inside_invalid_if_block
    Dir.mktmpdir("milk-tea-lsp-invalid-if-flow-completion") do |dir|
      path = File.join(dir, "main.mt")
      source = <<~MT
        struct Point:
            x: int

        function main() -> int:
            var p: Point? = null
            if p != null
                return p.
            return 0
      MT
      File.write(path, source)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})

        uri = path_to_uri(path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => source,
          },
        })

        diagnostics = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => uri },
        })
        messages = diagnostics.fetch("result").fetch("items").map { |item| item.fetch("message") }
        assert messages.any? { |message| message.include?("expected ':' before block") }

        dot_line = source.lines.index { |line| line.include?("return p.") }
        dot_char = source.lines.fetch(dot_line).chomp.length

        completion = client.send_request("textDocument/completion", {
          "textDocument" => { "uri" => uri },
          "position" => { "line" => dot_line, "character" => dot_char },
        })
        labels = completion.fetch("result").fetch("items").map { |item| item.fetch("label") }

        assert_includes labels, "x"
      end
    end
  end

  def test_completion_uses_flow_refined_type_inside_invalid_while_block
    Dir.mktmpdir("milk-tea-lsp-invalid-while-flow-completion") do |dir|
      path = File.join(dir, "main.mt")
      source = <<~MT
        struct Point:
            x: int

        function main() -> int:
            var p: Point? = Point(x = 1)
            while p != null
                return p.
            return 0
      MT
      File.write(path, source)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})

        uri = path_to_uri(path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => source,
          },
        })

        diagnostics = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => uri },
        })
        messages = diagnostics.fetch("result").fetch("items").map { |item| item.fetch("message") }
        assert messages.any? { |message| message.include?("expected ':' before block") }

        dot_line = source.lines.index { |line| line.include?("return p.") }
        dot_char = source.lines.fetch(dot_line).chomp.length

        completion = client.send_request("textDocument/completion", {
          "textDocument" => { "uri" => uri },
          "position" => { "line" => dot_line, "character" => dot_char },
        })
        labels = completion.fetch("result").fetch("items").map { |item| item.fetch("label") }

        assert_includes labels, "x"
      end
    end
  end

  def test_completion_uses_for_binding_inside_invalid_for_block
    Dir.mktmpdir("milk-tea-lsp-invalid-for-completion") do |dir|
      path = File.join(dir, "main.mt")
      source = <<~MT
        struct Point:
            x: int

        function main() -> int:
            let items = array[Point, 1](Point(x = 1))
            for item in items
                return item.
            return 0
      MT
      File.write(path, source)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})

        uri = path_to_uri(path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => source,
          },
        })

        diagnostics = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => uri },
        })
        messages = diagnostics.fetch("result").fetch("items").map { |item| item.fetch("message") }
        assert messages.any? { |message| message.include?("expected ':' before block") }

        dot_line = source.lines.index { |line| line.include?("return item.") }
        dot_char = source.lines.fetch(dot_line).chomp.length

        completion = client.send_request("textDocument/completion", {
          "textDocument" => { "uri" => uri },
          "position" => { "line" => dot_line, "character" => dot_char },
        })
        labels = completion.fetch("result").fetch("items").map { |item| item.fetch("label") }

        assert_includes labels, "x"
      end
    end
  end

  def test_completion_works_inside_if_block_without_condition
    Dir.mktmpdir("milk-tea-lsp-headerless-if-completion") do |dir|
      path = File.join(dir, "main.mt")
      source = <<~MT
        struct Point:
            x: int

        function main() -> int:
            let p = Point(x = 1)
            if:
                return p.
            return 0
      MT
      File.write(path, source)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})

        uri = path_to_uri(path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => source,
          },
        })

        diagnostics = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => uri },
        })
        messages = diagnostics.fetch("result").fetch("items").map { |item| item.fetch("message") }
        assert messages.any? { |message| message.include?("expected expression") }

        dot_line = source.lines.index { |line| line.include?("return p.") }
        dot_char = source.lines.fetch(dot_line).chomp.length

        completion = client.send_request("textDocument/completion", {
          "textDocument" => { "uri" => uri },
          "position" => { "line" => dot_line, "character" => dot_char },
        })
        labels = completion.fetch("result").fetch("items").map { |item| item.fetch("label") }

        assert_includes labels, "x"
      end
    end
  end

  def test_completion_uses_match_binding_inside_invalid_match_arm
    Dir.mktmpdir("milk-tea-lsp-invalid-match-arm-completion") do |dir|
      path = File.join(dir, "main.mt")
      source = <<~MT
        struct Point:
            x: int

        variant MaybePoint:
            some(value: Point)
            none

        function main(value: MaybePoint) -> int:
            match value:
                MaybePoint.some as payload
                    return payload.
                MaybePoint.none:
                    return 0
      MT
      File.write(path, source)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})

        uri = path_to_uri(path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => source,
          },
        })

        diagnostics = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => uri },
        })
        messages = diagnostics.fetch("result").fetch("items").map { |item| item.fetch("message") }
        assert messages.any? { |message| message.include?("expected ':' before block") }

        dot_line = source.lines.index { |line| line.include?("return payload.") }
        dot_char = source.lines.fetch(dot_line).chomp.length

        completion = client.send_request("textDocument/completion", {
          "textDocument" => { "uri" => uri },
          "position" => { "line" => dot_line, "character" => dot_char },
        })
        labels = completion.fetch("result").fetch("items").map { |item| item.fetch("label") }

        assert_includes labels, "value"
      end
    end
  end

  def test_hover_uses_error_type_for_match_binding_when_scrutinee_is_missing
    Dir.mktmpdir("milk-tea-lsp-invalid-match-scrutinee-hover") do |dir|
      path = File.join(dir, "main.mt")
      source = <<~MT
        struct Point:
            x: int

        variant MaybePoint:
            some(value: Point)
            none

        function main() -> int:
            match:
                MaybePoint.some as payload:
                    return payload
                MaybePoint.none:
                    return 0
      MT
      File.write(path, source)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})

        uri = path_to_uri(path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => source,
          },
        })

        diagnostics = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => uri },
        })
        messages = diagnostics.fetch("result").fetch("items").map { |item| item.fetch("message") }
        assert messages.any? { |message| message.include?("expected expression") }

        hover_line = source.lines.index { |line| line.include?("return payload") }
        hover_char = source.lines.fetch(hover_line).index("payload")

        hover_response = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => uri },
          "position" => { "line" => hover_line, "character" => hover_char },
        })

        hover_value = hover_response.dig("result", "contents", "value")
        assert_includes hover_value, "local payload: <error> (immutable)"
      end
    end
  end

  def test_semantic_tokens_locked_uses_package_lock_when_manifest_dependencies_drift
    Dir.mktmpdir("milk-tea-lsp-locked-semantic-tokens") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      ui_root = File.join(dir, "libs", "ui")
      app_src_dir = File.join(app_root, "src", "snake_duel")
      ui_src_dir = File.join(ui_root, "src", "teefan", "ui")

      FileUtils.mkdir_p(app_src_dir)
      FileUtils.mkdir_p(ui_src_dir)

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"

        [dependencies]
        "teefan.ui" = { path = "../../libs/ui" }
      TOML

      File.write(File.join(ui_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "0.3.0"
        kind = "library"
        source_root = "src"
      TOML

      main_source = <<~MT
        import teefan.ui.layout as duel_ui

        function main() -> int:
            return duel_ui.default_width()
      MT

      File.write(File.join(app_src_dir, "main.mt"), main_source)
      File.write(File.join(ui_src_dir, "layout.mt"), <<~MT)
        public function default_width() -> int:
            return 10
      MT

      MilkTea::PackageLock.write(app_root)

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"
      TOML

      root_uri = path_to_uri(dir)
      main_path = File.join(app_src_dir, "main.mt")
      main_uri = path_to_uri(main_path)

      with_server do |client|
        client.send_request("initialize", {
          "rootUri" => root_uri,
          "capabilities" => {},
          "initializationOptions" => {
            "milkTea" => {
              "lsp" => {
                "dependencyResolution" => "locked"
              }
            }
          }
        })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => main_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => main_source
          }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => main_uri }
        })

        legend = {
          "tokenTypes" => MilkTea::LSP::Server::SEMANTIC_TOKEN_TYPES,
          "tokenModifiers" => MilkTea::LSP::Server::SEMANTIC_TOKEN_MODIFIERS,
        }
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)
        alias_entry = semantic_entry_for_lexeme(main_source, entries, "duel_ui")
        member_entry = semantic_entry_for_lexeme(main_source, entries, "default_width")

        assert_equal "namespace", alias_entry.fetch("tokenType")
        assert_equal "function", member_entry.fetch("tokenType")
      end
    end
  end

  def test_hover_and_definition_locked_uses_package_lock_when_manifest_dependencies_drift
    Dir.mktmpdir("milk-tea-lsp-locked-hover-definition") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      ui_root = File.join(dir, "libs", "ui")
      app_src_dir = File.join(app_root, "src", "snake_duel")
      ui_src_dir = File.join(ui_root, "src", "teefan", "ui")

      FileUtils.mkdir_p(app_src_dir)
      FileUtils.mkdir_p(ui_src_dir)

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"

        [dependencies]
        "teefan.ui" = { path = "../../libs/ui" }
      TOML

      File.write(File.join(ui_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "0.3.0"
        kind = "library"
        source_root = "src"
      TOML

      ui_source = <<~MT
        public function default_width() -> int:
            return 10
      MT
      main_source = <<~MT
        import teefan.ui.layout as duel_ui

        function main() -> int:
            return duel_ui.default_width()
      MT

      main_path = File.join(app_src_dir, "main.mt")
      ui_path = File.join(ui_src_dir, "layout.mt")
      File.write(main_path, main_source)
      File.write(ui_path, ui_source)

      MilkTea::PackageLock.write(app_root)

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"
      TOML

      root_uri = path_to_uri(dir)
      main_uri = path_to_uri(main_path)
      ui_uri = path_to_uri(ui_path)

      with_server do |client|
        client.send_request("initialize", {
          "rootUri" => root_uri,
          "capabilities" => {},
          "initializationOptions" => {
            "milkTea" => {
              "lsp" => {
                "dependencyResolution" => "locked"
              }
            }
          }
        })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => main_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => main_source
          }
        })

        call_line = main_source.lines.index { |line| line.include?("duel_ui.default_width") }
        call_char = main_source.lines.fetch(call_line).index("default_width") + 1
        definition_line = ui_source.lines.index { |line| line.include?("public function default_width") }
        definition_char = ui_source.lines.fetch(definition_line).index("default_width")

        hover = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => call_line, "character" => call_char }
        })

        hover_value = hover.dig("result", "contents", "value")
        assert_includes hover_value, "function default_width() -> int"
        assert_includes hover_value, "Defined at: [libs/ui/src/teefan/ui/layout.mt:#{definition_line + 1}](#{ui_uri}#L#{definition_line + 1})"

        definition = client.send_request("textDocument/definition", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => call_line, "character" => call_char }
        })

        assert_equal ui_uri, definition.dig("result", "uri")
        assert_equal definition_line, definition.dig("result", "range", "start", "line")
        assert_equal definition_char, definition.dig("result", "range", "start", "character")
      end
    end
  end

  def test_hover_frozen_stops_using_stale_facts_after_manifest_watched_change
    Dir.mktmpdir("milk-tea-lsp-frozen-hover-watch") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      ui_root = File.join(dir, "libs", "ui")
      app_src_dir = File.join(app_root, "src", "snake_duel")
      ui_src_dir = File.join(ui_root, "src", "teefan", "ui")

      FileUtils.mkdir_p(app_src_dir)
      FileUtils.mkdir_p(ui_src_dir)

      manifest_path = File.join(app_root, "package.toml")
      manifest_uri = path_to_uri(manifest_path)

      File.write(manifest_path, <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"

        [dependencies]
        "teefan.ui" = { path = "../../libs/ui" }
      TOML

      File.write(File.join(ui_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "0.3.0"
        kind = "library"
        source_root = "src"
      TOML

      main_source = <<~MT
        import teefan.ui.layout as duel_ui

        function main() -> int:
            return duel_ui.default_width()
      MT

      File.write(File.join(app_src_dir, "main.mt"), main_source)
      File.write(File.join(ui_src_dir, "layout.mt"), <<~MT)
        public function default_width() -> int:
            return 10
      MT

      MilkTea::PackageLock.write(app_root)

      root_uri = path_to_uri(dir)
      main_path = File.join(app_src_dir, "main.mt")
      main_uri = path_to_uri(main_path)
      call_line = main_source.lines.index { |line| line.include?("duel_ui.default_width") }
      call_char = main_source.lines.fetch(call_line).index("default_width") + 1

      with_server do |client|
        client.send_request("initialize", {
          "rootUri" => root_uri,
          "capabilities" => {},
          "initializationOptions" => {
            "milkTea" => {
              "lsp" => {
                "dependencyResolution" => "frozen"
              }
            }
          }
        })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => main_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => main_source
          }
        })

        first_hover = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => call_line, "character" => call_char }
        })
        first_hover_value = first_hover.dig("result", "contents", "value")

        assert_includes first_hover_value, "function default_width() -> int"

        File.write(manifest_path, <<~TOML)
          [package]
          name = "snake_duel"
          version = "0.1.0"
          source_root = "src"
        TOML

        client.send_notification("workspace/didChangeWatchedFiles", {
          "changes" => [{ "uri" => manifest_uri, "type" => 2 }]
        })

        diagnostics = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => main_uri }
        })
        diagnostic_messages = diagnostics.fetch("result").fetch("items").map { |item| item["message"] }

        assert diagnostic_messages.any? { |message| message.include?("package.lock is out of date") },
               "expected frozen diagnostics after watched manifest drift, got: #{diagnostic_messages.inspect}"

        second_hover = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => call_line, "character" => call_char }
        })

        assert_nil second_hover["result"]
      end
    end
  end

  def test_completion_returns_function_names
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_completion_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_CALL }
      })

      response = client.send_request("textDocument/completion", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => 4, "character" => 11 }
      })
      result = response.fetch("result")
      labels = result["items"].map { |i| i["label"] }
      assert_includes labels, "add"
      assert_includes labels, "main"
      result["items"].each { |item| assert_equal 3, item["kind"] }
    end
  end

  def test_completion_returns_method_names_after_dot
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_method_completion_test.mt"
      # Open valid source so analysis succeeds and is cached as last-good.
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_METHODS }
      })
      # Simulate user editing to a mid-state with "p." on the last line (breaks sema,
      # but last-good facts are retained so method completions still work).
      partial_source = SOURCE_WITH_METHODS.sub("    return 1\n", "    return p.\n")
      client.send_notification("textDocument/didChange", {
        "textDocument" => { "uri" => uri, "version" => 2 },
        "contentChanges" => [{ "text" => partial_source }]
      })
      # Cursor is right after 'p.' on the last non-empty line.
      dot_line = partial_source.lines.count - 1  # "    return p." is the last line
      dot_char = partial_source.lines[dot_line].chomp.length

      response = client.send_request("textDocument/completion", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => dot_line, "character" => dot_char }
      })
      result = response.fetch("result")
      labels = result["items"].map { |i| i["label"] }
      assert_includes labels, "zero"
      result["items"].each { |item| assert_equal 2, item["kind"] }  # kind 2 = Method
    end
  end

  def test_completion_returns_static_methods_for_imported_type_receiver
    Dir.mktmpdir("mt_lsp_imported_type_completion") do |dir|
      std_dir = File.join(dir, "std")
      FileUtils.mkdir_p(std_dir)

      File.write(File.join(std_dir, "foo.mt"), <<~MT)
        public struct Point:
            x: int
            y: int

        extending Point:
            public static function zero() -> int:
                return 0

            public function length() -> int:
                return this.x + this.y
      MT

      source = <<~MT
        import std.foo as foo

        public function main() -> int:
            return foo.Point.zero()
      MT
      source_path = File.join(dir, "main.mt")
      File.write(source_path, source)

      server = MilkTea::LSP::Server.new(protocol: RecordingProtocol.new)
      begin
        uri = path_to_uri(source_path)
        workspace = server.instance_variable_get(:@workspace)
        workspace.open_document(uri, source)

        partial_source = source.sub("return foo.Point.zero()", "return foo.Point.")
        workspace.update_document(uri, partial_source)

        dot_line = partial_source.lines.index { |line| line.include?("return foo.Point.") }
        dot_char = partial_source.lines[dot_line].chomp.length

        result = server.send(:handle_completion, {
          "textDocument" => { "uri" => uri },
          "position"     => { "line" => dot_line, "character" => dot_char }
        })

        items = result.fetch(:items)
        labels = items.map { |item| item[:label] }

        assert_includes labels, "zero"
        refute_includes labels, "length"
      ensure
        server&.send(:stop_diagnostics_workers)
      end
    end
  end

  def test_completion_returns_fields_and_methods_for_local_value_receiver
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_local_value_completion_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_LOCAL_VALUE_COMPLETION }
      })

      partial_source = SOURCE_WITH_LOCAL_VALUE_COMPLETION.sub("return p.x", "return p.")
      client.send_notification("textDocument/didChange", {
        "textDocument" => { "uri" => uri, "version" => 2 },
        "contentChanges" => [{ "text" => partial_source }]
      })

      dot_line = partial_source.lines.index { |line| line.include?("return p.") }
      dot_char = partial_source.lines[dot_line].chomp.length

      response = client.send_request("textDocument/completion", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => dot_line, "character" => dot_char }
      })

      items = response.fetch("result").fetch("items")
      labels = items.map { |i| i["label"] }
      kinds_by_label = items.to_h { |i| [i["label"], i["kind"]] }

      assert_includes labels, "x"
      assert_includes labels, "y"
      assert_includes labels, "length"
      assert_equal 10, kinds_by_label["x"]
      assert_equal 2, kinds_by_label["length"]
    end
  end

  def test_completion_uses_lexical_scope_for_shadowed_value_receiver
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_shadow_value_completion_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_SHADOWED_VALUE_COMPLETION }
      })

      partial_source = SOURCE_WITH_SHADOWED_VALUE_COMPLETION.sub("return v.x", "return v.")
      client.send_notification("textDocument/didChange", {
        "textDocument" => { "uri" => uri, "version" => 2 },
        "contentChanges" => [{ "text" => partial_source }]
      })

      dot_line = partial_source.lines.index { |line| line.include?("return v.") }
      dot_char = partial_source.lines[dot_line].chomp.length

      response = client.send_request("textDocument/completion", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => dot_line, "character" => dot_char }
      })

      labels = response.fetch("result").fetch("items").map { |i| i["label"] }
      assert_includes labels, "x"
      refute_includes labels, "w"
    end
  end

  def test_completion_uses_flow_refined_type_for_nullable_receiver
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_nullable_flow_completion_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_NULLABLE_FLOW_COMPLETION }
      })

      partial_source = SOURCE_WITH_NULLABLE_FLOW_COMPLETION.sub("return p.x", "return p.")
      client.send_notification("textDocument/didChange", {
        "textDocument" => { "uri" => uri, "version" => 2 },
        "contentChanges" => [{ "text" => partial_source }]
      })

      dot_line = partial_source.lines.index { |line| line.include?("return p.") }
      dot_char = partial_source.lines[dot_line].chomp.length

      response = client.send_request("textDocument/completion", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => dot_line, "character" => dot_char }
      })

      labels = response.fetch("result").fetch("items").map { |i| i["label"] }
      assert_includes labels, "x"
    end
  end

  def test_completion_uses_ref_receiver_type_for_fields
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_ref_receiver_completion_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_REF_RECEIVER_COMPLETION }
      })

      partial_source = SOURCE_WITH_REF_RECEIVER_COMPLETION.sub("return rp.x", "return rp.")
      client.send_notification("textDocument/didChange", {
        "textDocument" => { "uri" => uri, "version" => 2 },
        "contentChanges" => [{ "text" => partial_source }]
      })

      dot_line = partial_source.lines.index { |line| line.include?("return rp.") }
      dot_char = partial_source.lines[dot_line].chomp.length

      response = client.send_request("textDocument/completion", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => dot_line, "character" => dot_char }
      })

      labels = response.fetch("result").fetch("items").map { |i| i["label"] }
      assert_includes labels, "x"
      assert_includes labels, "y"
    end
  end

  def test_completion_uses_pointer_receiver_type_for_fields
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_ptr_receiver_completion_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_POINTER_RECEIVER_COMPLETION }
      })

      partial_source = SOURCE_WITH_POINTER_RECEIVER_COMPLETION.sub("return pp.x", "return pp.")
      client.send_notification("textDocument/didChange", {
        "textDocument" => { "uri" => uri, "version" => 2 },
        "contentChanges" => [{ "text" => partial_source }]
      })

      dot_line = partial_source.lines.index { |line| line.include?("return pp.") }
      dot_char = partial_source.lines[dot_line].chomp.length

      response = client.send_request("textDocument/completion", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => dot_line, "character" => dot_char }
      })

      labels = response.fetch("result").fetch("items").map { |i| i["label"] }
      assert_includes labels, "x"
      assert_includes labels, "y"
    end
  end

  def test_completion_uses_top_level_value_receiver_type
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_top_level_value_receiver_completion_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_TOP_LEVEL_VALUE_RECEIVER_COMPLETION }
      })

      partial_source = SOURCE_WITH_TOP_LEVEL_VALUE_RECEIVER_COMPLETION.sub("return origin.x", "return origin.")
      client.send_notification("textDocument/didChange", {
        "textDocument" => { "uri" => uri, "version" => 2 },
        "contentChanges" => [{ "text" => partial_source }]
      })

      dot_line = partial_source.lines.index { |line| line.include?("return origin.") }
      dot_char = partial_source.lines[dot_line].chomp.length

      response = client.send_request("textDocument/completion", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => dot_line, "character" => dot_char }
      })

      labels = response.fetch("result").fetch("items").map { |i| i["label"] }
      assert_includes labels, "x"
      assert_includes labels, "y"
      assert_includes labels, "area"
    end
  end

  def test_completion_uses_enclosing_receiver_for_this_in_editable_method
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_editable_this_completion_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_EDITABLE_METHOD_RECEIVER_COMPLETION }
      })

      partial_source = SOURCE_WITH_EDITABLE_METHOD_RECEIVER_COMPLETION.sub("        this.value = 0", "        this.")
      client.send_notification("textDocument/didChange", {
        "textDocument" => { "uri" => uri, "version" => 2 },
        "contentChanges" => [{ "text" => partial_source }]
      })

      dot_line = partial_source.lines.index { |line| line.include?("this.") }
      dot_char = partial_source.lines[dot_line].chomp.length

      response = client.send_request("textDocument/completion", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => dot_line, "character" => dot_char }
      })

      labels = response.fetch("result").fetch("items").map { |i| i["label"] }
      assert_includes labels, "value"
      assert_includes labels, "reset"
    end
  end

  def test_hover_returns_method_info_for_method_name
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_method_hover_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_METHODS }
      })
      # Line 5 (0-based) is "    function zero() -> int:", 'zero' starts at character 13.
      response = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => 5, "character" => 13 }
      })
      hover_value = response.dig("result", "contents", "value")
      assert_includes hover_value, "function zero() -> int"
      refute_includes hover_value, "local zero"
    end
  end

  def test_hover_formats_builtin_type_without_redundant_alias
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_builtin_type_hover_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_CALL }
      })

      response = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => 0, "character" => 16 }
      })
      hover_value = response.dig("result", "contents", "value")
      assert_includes hover_value, "type int"
      refute_includes hover_value, "type int = int"
    end
  end

  def test_hover_returns_field_info_for_field_declarations
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_field_declaration_hover_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE }
      })

      x_hover = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => 1, "character" => 4 }
      })
      x_hover_value = x_hover.dig("result", "contents", "value")
      assert_includes x_hover_value, "x: float"
      refute_includes x_hover_value, "local x"

      y_hover = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => 2, "character" => 4 }
      })
      y_hover_value = y_hover.dig("result", "contents", "value")
      assert_includes y_hover_value, "y: float"
      refute_includes y_hover_value, "local y"
    end
  end

  def test_hover_returns_field_info_for_member_chain_segments
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_member_chain_hover_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_MEMBER_CHAIN_HOVER }
      })

      active_hover = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => 8, "character" => 20 }
      })
      active_hover_value = active_hover.dig("result", "contents", "value")
      assert_includes active_hover_value, "field active: Piece"

      kind_hover = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => 8, "character" => 27 }
      })
      kind_hover_value = kind_hover.dig("result", "contents", "value")
      assert_includes kind_hover_value, "field kind: int"
    end
  end

  def test_definition_returns_field_declaration_for_member_access_segments
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_member_chain_definition_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_MEMBER_CHAIN_HOVER }
      })

      definition = client.send_request("textDocument/definition", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => 8, "character" => 27 }
      })
      definition_result = definition.fetch("result")

      assert_equal uri, definition_result.fetch("uri")
      assert_equal 1, definition_result.dig("range", "start", "line")
    end
  end

  def test_hover_and_definition_resolve_imported_generic_member_chain_segments
    Dir.mktmpdir("milk-tea-lsp-imported-generic-member") do |dir|
      std_dir = File.join(dir, "std")
      FileUtils.mkdir_p(std_dir)

      foo_source = <<~MT
        public struct Bucket[K, V]:
            value: V

        extending Bucket[K, V]:
            public mutable function get_or_insert(key: K, value: V) -> ptr[V]:
                let _ = key
                this.value = value
                return ptr_of(this.value)
      MT

      main_source = <<~MT
        import std.foo as foo

        struct Counter[T]:
            values: foo.Bucket[T, ptr_uint]

        extending Counter[T]:
            mutable function add(value: T) -> ptr_uint:
                let current = this.values.get_or_insert(value, 0)
                unsafe:
                    return read(current)
      MT

      foo_path = File.join(std_dir, "foo.mt")
      main_path = File.join(dir, "main.mt")
      File.write(foo_path, foo_source)
      File.write(main_path, main_source)

      root_uri = path_to_uri(dir)
      foo_uri = path_to_uri(foo_path)
      main_uri = path_to_uri(main_path)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => root_uri, "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => main_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => main_source,
          }
        })

        access_line = main_source.lines.index { |line| line.include?("this.values.get_or_insert") }
        access_text = main_source.lines.fetch(access_line)
        values_char = access_text.index("values") + 1
        method_char = access_text.index("get_or_insert") + 1

        field_definition_line = main_source.lines.index { |line| line.include?("values: foo.Bucket") }
        field_definition_char = main_source.lines.fetch(field_definition_line).index("values")
        method_definition_line = foo_source.lines.index { |line| line.include?("function get_or_insert") }
        method_definition_char = foo_source.lines.fetch(method_definition_line).index("get_or_insert")

        values_hover = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => access_line, "character" => values_char }
        })
        values_hover_value = values_hover.dig("result", "contents", "value")
        assert_includes values_hover_value, "field values: std.foo.Bucket[T, ptr_uint]"

        method_hover = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => access_line, "character" => method_char }
        })
        method_hover_value = method_hover.dig("result", "contents", "value")
        assert_includes method_hover_value, "mutable function get_or_insert(key: K, value: V) -> ptr[V]"
        assert_includes method_hover_value, "Defined at: [std/foo.mt:#{method_definition_line + 1}](#{foo_uri}#L#{method_definition_line + 1})"

        values_definition = client.send_request("textDocument/definition", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => access_line, "character" => values_char }
        })
        values_definition_result = values_definition.fetch("result")
        assert_equal main_uri, values_definition_result.fetch("uri")
        assert_equal field_definition_line, values_definition_result.dig("range", "start", "line")
        assert_equal field_definition_char, values_definition_result.dig("range", "start", "character")

        method_definition = client.send_request("textDocument/definition", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => access_line, "character" => method_char }
        })
        method_definition_result = method_definition.fetch("result")
        assert_equal foo_uri, method_definition_result.fetch("uri")
        assert_equal method_definition_line, method_definition_result.dig("range", "start", "line")
        assert_equal method_definition_char, method_definition_result.dig("range", "start", "character")
      end
    end
  end

  def test_definition_returns_current_module_field_declaration_in_tetris
    with_server do |client|
      client.send_request("initialize", { "rootUri" => path_to_uri(Dir.pwd), "capabilities" => {} })
      client.send_notification("initialized", {})

      source_path = File.expand_path("projects/tetris/src/main.mt", Dir.pwd)
      uri = path_to_uri(source_path)
      source = File.read(source_path)
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      line = source.lines.index { |text| text.include?("this.drop_timer +=") }
      character = source.lines.fetch(line).index("drop_timer")
      definition = client.send_request("textDocument/definition", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => line, "character" => character }
      })
      definition_result = definition.fetch("result")

      expected_line = source.lines.index { |text| text == "    drop_timer: float\n" }
      assert_equal uri, definition_result.fetch("uri")
      assert_equal expected_line, definition_result.dig("range", "start", "line")
    end
  end

  def test_hover_and_definition_resolve_fstring_member_access_segments_in_tetris
    with_server do |client|
      client.send_request("initialize", { "rootUri" => path_to_uri(Dir.pwd), "capabilities" => {} })
      client.send_notification("initialized", {})

      source_path = File.expand_path("projects/tetris/src/main.mt", Dir.pwd)
      uri = path_to_uri(source_path)
      source = File.read(source_path)
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      line = source.lines.index { |text| text.include?('f"Score  #{this.snapshot.score}"') }
      line_text = source.lines.fetch(line)

      snapshot_character = line_text.index("snapshot")
      snapshot_hover = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => line, "character" => snapshot_character }
      })
      snapshot_hover_value = snapshot_hover.dig("result", "contents", "value")
      assert_includes snapshot_hover_value, "field snapshot: main.Game"

      snapshot_definition = client.send_request("textDocument/definition", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => line, "character" => snapshot_character }
      })
      snapshot_result = snapshot_definition.fetch("result")
      snapshot_line = source.lines.index { |text| text == "    snapshot: Game\n" }
      assert_equal uri, snapshot_result.fetch("uri")
      assert_equal snapshot_line, snapshot_result.dig("range", "start", "line")

      score_character = line_text.rindex("score")
      score_hover = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => line, "character" => score_character }
      })
      score_hover_value = score_hover.dig("result", "contents", "value")
      assert_includes score_hover_value, "field score: int"

      score_definition = client.send_request("textDocument/definition", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => line, "character" => score_character }
      })
      score_result = score_definition.fetch("result")
      score_line = source.lines.index { |text| text == "    score: int\n" }
      assert_equal uri, score_result.fetch("uri")
      assert_equal score_line, score_result.dig("range", "start", "line")
    end
  end

  def test_hover_returns_method_info_for_member_access_segments
    with_server do |client|
      client.send_request("initialize", { "rootUri" => path_to_uri(Dir.pwd), "capabilities" => {} })
      client.send_notification("initialized", {})

      source_path = File.expand_path("projects/tetris/src/main.mt", Dir.pwd)
      uri = path_to_uri(source_path)
      source = File.read(source_path)
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      line = source.lines.index { |text| text.include?("this.reset()") }
      character = source.lines.fetch(line).index("reset")

      hover = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => line, "character" => character }
      })
      hover_value = hover.dig("result", "contents", "value")

      assert_includes hover_value, "mutable function reset() -> void"
      refute_includes hover_value, "local reset"
    end
  end

  def test_hover_returns_field_info_for_named_constructor_labels
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_named_constructor_label_hover_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_PARAMETER_AND_LABEL_SEMANTICS }
      })

      x_hover = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => 5, "character" => 21 }
      })
      x_hover_value = x_hover.dig("result", "contents", "value")
      assert_includes x_hover_value, "x: int"
      refute_includes x_hover_value, "local x"

      y_hover = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => 5, "character" => 35 }
      })
      y_hover_value = y_hover.dig("result", "contents", "value")
      assert_includes y_hover_value, "y: int"
      refute_includes y_hover_value, "local y"
    end
  end

  def test_hover_and_definition_resolve_imported_enum_members
    with_server do |client|
      client.send_request("initialize", { "rootUri" => path_to_uri(Dir.pwd), "capabilities" => {} })
      client.send_notification("initialized", {})

      source_path = File.expand_path("projects/tetris/src/main.mt", Dir.pwd)
      uri = path_to_uri(source_path)
      source = File.read(source_path)
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      line = source.lines.index { |text| text.include?("KEY_ENTER") }
      character = source.lines.fetch(line).index("KEY_ENTER")

      hover = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => line, "character" => character }
      })
      hover_value = hover.dig("result", "contents", "value")
      assert_includes hover_value, "KEY_ENTER"
      assert_includes hover_value, "rl.KeyboardKey"
      assert_includes hover_value, "257"
      assert_includes hover_value, "std/c/raylib.mt"

      definition = client.send_request("textDocument/definition", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => line, "character" => character }
      })
      definition_result = definition.fetch("result")

      expected_path = File.expand_path("std/c/raylib.mt", Dir.pwd)
      expected_line = File.readlines(expected_path).index { |text| text.include?("KEY_ENTER = 257") }
      assert_equal path_to_uri(expected_path), definition_result.fetch("uri")
      assert_equal expected_line, definition_result.dig("range", "start", "line")
    end
  end

  def test_code_lens_returns_empty_when_disabled
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_codelens_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_CALL }
      })
      response = client.send_request("textDocument/codeLens", {
        "textDocument" => { "uri" => uri }
      })
      error = response.fetch("error")
      assert_equal(-32_601, error["code"])
      assert_includes(error["message"], "Method not found")
    end
  end

  def test_document_diagnostic_collects_errors_from_multiple_functions
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_multi_err_test.mt"
      source = <<~MT
        function foo() -> int:
            return "not an int"

        function bar() -> bool:
            return 42
      MT
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      response = client.send_request("textDocument/diagnostic", { "textDocument" => { "uri" => uri } })
      result = response.fetch("result")
      assert_equal "full", result["kind"]
      assert result["items"].length >= 2,
             "expected errors from both foo and bar, got #{result['items'].length}: #{result['items'].map { |i| i['message'] }.inspect}"
    end
  end

  def test_document_diagnostic_sema_errors_have_accurate_line_numbers
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_err_line_test.mt"
      source = <<~MT
        function ok(a: int, b: int) -> int:
            return a + b

        function broken() -> int:
            return "wrong type"
      MT
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      response = client.send_request("textDocument/diagnostic", { "textDocument" => { "uri" => uri } })
      result = response.fetch("result")
      assert_equal "full", result["kind"]
      assert result["items"].length >= 1

      # "return 'wrong type'" is on source line 5 (1-based), LSP 0-based = 4.
      error_lines = result["items"].map { |i| i.dig("range", "start", "line") }
      assert_includes error_lines, 4,
                      "expected sema error on line 4 (0-based), got lines: #{error_lines.inspect}"
    end
  end

  def test_document_diagnostic_reports_attribute_target_errors_at_attribute_name
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_attribute_target_error_test.mt"
      source = <<~MT
        public attribute[field] rename(name: str)

        @[rename("packet")]
        struct Packet:
            payload_len: uint
      MT

      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      response = client.send_request("textDocument/diagnostic", { "textDocument" => { "uri" => uri } })
      items = response.fetch("result").fetch("items")
      diagnostic = items.find { |item| item.fetch("message").include?("attribute rename cannot target struct") }

      refute_nil diagnostic, "expected attribute target diagnostic, got #{items.map { |item| item['message'] }.inspect}"
      assert_equal 2, diagnostic.dig("range", "start", "line")
      assert_equal 2, diagnostic.dig("range", "start", "character")
      assert_equal 8, diagnostic.dig("range", "end", "character")
    end
  end

  def test_document_diagnostic_reports_ambiguous_imported_extension_method_at_member_token
    Dir.mktmpdir("milk-tea-lsp-ambiguous-extension") do |dir|
      Dir.mkdir(File.join(dir, "std"))
      demo_dir = File.join(dir, "demo")
      FileUtils.mkdir_p(demo_dir)

      File.write(File.join(demo_dir, "dep.mt"), <<~MT)
        public struct Counter:
            value: int
      MT

      File.write(File.join(demo_dir, "a.mt"), <<~MT)
        import demo.dep as dep

        extending dep.Counter:
            public function tag() -> int:
                return 1
      MT

      File.write(File.join(demo_dir, "b.mt"), <<~MT)
        import demo.dep as dep

        extending dep.Counter:
            public function tag() -> int:
                return 2
      MT

      main_path = File.join(demo_dir, "main.mt")
      source = <<~MT
        import demo.dep as dep
        import demo.a as a
        import demo.b as b

        function main(value: dep.Counter) -> int:
            value.tag()
            return 0
      MT
      File.write(main_path, source)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})

        uri = path_to_uri(main_path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/diagnostic", { "textDocument" => { "uri" => uri } })
        items = response.fetch("result").fetch("items")
        diagnostic = items.find do |item|
          item.fetch("message").include?("ambiguous imported method demo.dep.Counter.tag")
        end

        refute_nil diagnostic, "expected ambiguous imported method diagnostic, got #{items.map { |item| item['message'] }.inspect}"
        assert_equal 5, diagnostic.dig("range", "start", "line")
        assert_equal 10, diagnostic.dig("range", "start", "character")
        assert_equal 11, diagnostic.dig("range", "end", "character")
      end
    end
  end

  def test_semantic_tokens_classify_imported_module_function_reference_as_function
    Dir.mktmpdir("mt_lsp_semantic_tokens") do |dir|
      c_dir = File.join(dir, "std", "c")
      FileUtils.mkdir_p(c_dir)

      File.write(File.join(c_dir, "sdl3.mt"), <<~MT)
        external

        external function SDL_SetWindowFillDocument(window: ptr[void], fill: bool) -> bool
      MT

      source_path = File.join(dir, "std", "sdl3.mt")
      FileUtils.mkdir_p(File.dirname(source_path))
      source = <<~MT
        import std.c.sdl3 as c

        public foreign function set_window_fill_document(window: ptr[void], fill: bool) -> bool = c.SDL_SetWindowFillDocument
      MT
      File.write(source_path, source)

      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        uri = path_to_uri(source_path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

        alias_entry = semantic_entry_for_lexeme(source, entries, "c")
        member_entry = semantic_entry_for_lexeme(source, entries, "SDL_SetWindowFillDocument")

        assert_equal "namespace", alias_entry.fetch("tokenType")
        assert_equal "function", member_entry.fetch("tokenType")
      end
    end
  end

  def test_semantic_tokens_classify_imported_type_static_method_as_method
    Dir.mktmpdir("mt_lsp_semantic_tokens_static_method") do |dir|
      demo_dir = File.join(dir, "demo")
      FileUtils.mkdir_p(demo_dir)

      File.write(File.join(demo_dir, "dep.mt"), <<~MT)
        public struct Box[T]:
            value: T

        extending Box[T]:
            public static function create(value: T) -> Box[T]:
                return Box[T](value = value)
      MT

      source_path = File.join(dir, "main.mt")
      source = <<~MT
        import demo.dep as dep

        function main() -> dep.Box[int]:
            return dep.Box[int].create(1)
      MT
      File.write(source_path, source)

      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        uri = path_to_uri(source_path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

        create_entry = semantic_entry_for_lexeme(source, entries, "create")

        assert_equal "method", create_entry.fetch("tokenType")
      end
    end
  end

  def test_semantic_tokens_classify_loose_workspace_imported_module_function_reference_as_function
    Dir.mktmpdir("mt_lsp_semantic_tokens_loose_root") do |dir|
      demo_dir = File.join(dir, "demo")
      FileUtils.mkdir_p(demo_dir)

      File.write(File.join(demo_dir, "lib.mt"), <<~MT)
        public function greet() -> int:
            return 1
      MT

      source_path = File.join(dir, "main.mt")
      source = <<~MT
        import demo.lib as lib

        function main() -> int:
            return lib.greet()
      MT
      File.write(source_path, source)

      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        uri = path_to_uri(source_path)
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

        alias_entry = semantic_entry_for_lexeme(source, entries, "lib")
        member_entry = semantic_entry_for_lexeme(source, entries, "greet")

        assert_equal "namespace", alias_entry.fetch("tokenType")
        assert_equal "function", member_entry.fetch("tokenType")
      end
    end
  end

  def test_semantic_tokens_do_not_classify_invalid_imported_module_function_reference_as_function
    Dir.mktmpdir("mt_lsp_semantic_tokens_invalid_imported") do |dir|
      c_dir = File.join(dir, "std", "c")
      FileUtils.mkdir_p(c_dir)

      File.write(File.join(c_dir, "sdl3.mt"), <<~MT)
        external

        external function SDL_SetWindowFillDocument(window: ptr[void], fill: bool) -> bool
      MT

      source_path = File.join(dir, "std", "sdl3.mt")
      FileUtils.mkdir_p(File.dirname(source_path))
      source = <<~MT
        import std.c.sdl3 as c

        function main() -> int:
            let callback = c.SDL_SetWindowFillDocument
            return 0
      MT
      File.write(source_path, source)

      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        uri = path_to_uri(source_path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)
        member_line = source.lines.index { |line| line.include?("SDL_SetWindowFillDocument") }
        member_entry = semantic_entry_for_lexeme_on_line(source, entries, "SDL_SetWindowFillDocument", member_line)

        assert_equal "property", member_entry.fetch("tokenType")
      end
    end
  end

  def test_semantic_tokens_classify_large_std_imported_module_type_reference
    Dir.mktmpdir("mt_lsp_semantic_tokens_large_std") do |dir|
      c_dir = File.join(dir, "std", "c")
      FileUtils.mkdir_p(c_dir)

      File.write(File.join(c_dir, "raylib.mt"), <<~MT)
        external

        struct Vector2:
            x: float
            y: float
      MT

      filler = (1..160).map { |i| "public const PAD_#{i}: int = #{i}" }.join("\n")
      source_path = File.join(dir, "std", "raylib.mt")
      FileUtils.mkdir_p(File.dirname(source_path))
      source = <<~MT
        import std.c.raylib as c

        public type VecAlias = c.Vector2
        #{filler}
      MT
      File.write(source_path, source)

      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        uri = path_to_uri(source_path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)
        type_alias_line = source.lines.index { |line| line.include?("c.Vector2") }

        alias_entry = entries.find do |entry|
          next false unless entry.fetch("line") == type_alias_line

          line_text = source.lines.fetch(entry.fetch("line"))
          line_text[entry.fetch("startChar"), 1] == "c"
        end or flunk("expected semantic token entry for aliased module receiver on the type alias line")

        member_entry = entries.find do |entry|
          next false unless entry.fetch("line") == type_alias_line

          line_text = source.lines.fetch(entry.fetch("line"))
          line_text[entry.fetch("startChar"), "Vector2".length] == "Vector2"
        end or flunk("expected semantic token entry for imported type member on the type alias line")

        assert_equal "namespace", alias_entry.fetch("tokenType")
        assert_equal "type", member_entry.fetch("tokenType")
      end
    end
  end

  def test_semantic_tokens_keep_generic_helper_parameter_declarations_and_imported_lowercase_enum_members
    Dir.mktmpdir("mt_lsp_semantic_tokens_generic_helper_enum") do |dir|
      c_dir = File.join(dir, "std", "c")
      FileUtils.mkdir_p(c_dir)

      File.write(File.join(c_dir, "foo.mt"), <<~MT)
        external

        enum thing_t: int
            THING_A = 1
      MT

      source_path = File.join(dir, "demo.mt")
      source = <<~MT
        import std.c.foo as c

        function uses_helper(loop: int) -> int:
            return helper[int](loop)

        function helper[T](value: T) -> T:
            return value

        function use_enum() -> c.thing_t:
            return c.thing_t.THING_A
      MT
      File.write(source_path, source)

      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        uri = path_to_uri(source_path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)
        loop_decl_line = source.lines.index { |line| line.include?("function uses_helper") }
        enum_member_line = source.lines.index { |line| line.include?("THING_A") }
        loop_decl = semantic_entry_for_lexeme_on_line(source, entries, "loop", loop_decl_line)
        enum_member = semantic_entry_for_lexeme_on_line(source, entries, "THING_A", enum_member_line)

        assert_equal "parameter", loop_decl.fetch("tokenType")
        assert_includes loop_decl.fetch("modifierNames"), "declaration"
        assert_equal "enumMember", enum_member.fetch("tokenType")
      end
    end
  end

  def test_semantic_tokens_refresh_after_imported_module_did_change
    Dir.mktmpdir("mt_lsp_semantic_tokens_import_change") do |dir|
      Dir.mkdir(File.join(dir, "std"))
      api_path = File.join(dir, "api.mt")
      main_path = File.join(dir, "main.mt")

      api_initial = <<~MT
      MT
      api_updated = <<~MT
        public type Answer = int
      MT
      main_source = <<~MT
        import api as api

        public type Reply = api.Answer
      MT

      File.write(api_path, api_initial)
      File.write(main_path, main_source)

      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        api_uri = path_to_uri(api_path)
        main_uri = path_to_uri(main_path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => api_uri, "languageId" => "milk-tea", "version" => 1, "text" => api_initial }
        })
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => main_uri, "languageId" => "milk-tea", "version" => 1, "text" => main_source }
        })

        first = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => main_uri }
        })
        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        first_entries = decode_semantic_token_entries(first.fetch("result").fetch("data"), legend)
        first_answer = semantic_entry_for_lexeme(main_source, first_entries, "Answer")

        assert_equal "property", first_answer.fetch("tokenType")

        client.send_notification("textDocument/didChange", {
          "textDocument" => { "uri" => api_uri, "version" => 2 },
          "contentChanges" => [{ "text" => api_updated }]
        })

        second = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => main_uri }
        })
        second_entries = decode_semantic_token_entries(second.fetch("result").fetch("data"), legend)
        second_answer = semantic_entry_for_lexeme(main_source, second_entries, "Answer")

        assert_equal "type", second_answer.fetch("tokenType")
      end
    end
  end

  def test_semantic_tokens_classify_local_interfaces_like_types
    source = <<~MT
      interface ScreenState:
          function draw(texture: int) -> void

      struct PauseScreen implements ScreenState:
          ticks: int

      extending PauseScreen:
          function draw(texture: int) -> void:
              let sink = texture

      function run_screen_frame[T implements ScreenState](screen: ref[T], texture: int) -> void:
          screen.draw(texture)
    MT

    with_server do |client|
      init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_semantic_interface_local_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      response = client.send_request("textDocument/semanticTokens/full", {
        "textDocument" => { "uri" => uri }
      })

      legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
      entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

      interface_decl = semantic_entry_for_lexeme_on_line(source, entries, "ScreenState", 0)
      interface_impl = semantic_entry_for_lexeme_on_line(source, entries, "ScreenState", 3)
      interface_constraint = semantic_entry_for_lexeme_on_line(source, entries, "ScreenState", 10)

      assert_equal "type", interface_decl.fetch("tokenType")
      assert_includes interface_decl.fetch("modifierNames"), "declaration"
      assert_equal "type", interface_impl.fetch("tokenType")
      assert_equal "type", interface_constraint.fetch("tokenType")
    end
  end

  def test_semantic_tokens_classify_imported_interfaces_like_types
    Dir.mktmpdir("mt_lsp_semantic_tokens_imported_interface") do |dir|
      std_dir = File.join(dir, "std")
      FileUtils.mkdir_p(std_dir)

      contracts_source = <<~MT
        public interface Damageable:
            mutable function take_damage(amount: int) -> void
      MT
      main_source = <<~MT
        import std.contracts as contracts

        struct NPC implements contracts.Damageable:
            hp: int

        extending NPC:
            mutable function take_damage(amount: int):
                this.hp -= amount
      MT

      contracts_path = File.join(std_dir, "contracts.mt")
      main_path = File.join(dir, "main.mt")
      File.write(contracts_path, contracts_source)
      File.write(main_path, main_source)

      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        uri = path_to_uri(main_path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => main_source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)
        implements_line = main_source.lines.index { |line| line.include?("contracts.Damageable") }
        alias_entry = semantic_entry_for_lexeme_on_line(main_source, entries, "contracts", implements_line)
        interface_entry = semantic_entry_for_lexeme_on_line(main_source, entries, "Damageable", implements_line)

        assert_equal "namespace", alias_entry.fetch("tokenType")
        assert_equal "type", interface_entry.fetch("tokenType")
      end
    end
  end

  def test_semantic_tokens_classify_event_declarations
    source = <<~MT
      event reloaded[4]

      struct Window:
          public event closed[4]
          title: str

      function main() -> void:
          reloaded.emit()
    MT

    with_server do |client|
      init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_semantic_event_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      response = client.send_request("textDocument/semanticTokens/full", {
        "textDocument" => { "uri" => uri }
      })

      legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
      entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

      top_level_event = semantic_entry_for_lexeme_on_line(source, entries, "reloaded", 0)
      struct_event = semantic_entry_for_lexeme_on_line(source, entries, "closed", 3)

      assert_equal "variable", top_level_event.fetch("tokenType")
      assert_includes top_level_event.fetch("modifierNames"), "declaration"
      assert_equal "property", struct_event.fetch("tokenType")
      assert_includes struct_event.fetch("modifierNames"), "declaration"
    end
  end


    def test_semantic_tokens_classify_str_buffer_and_value_receiver_methods
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
        uri = "file:///tmp/lsp_semantic_str_buffer_test.mt"
        source = SOURCE_WITH_STR_BUFFER_METHODS
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

        str_buffer_entry = semantic_entry_for_lexeme(source, entries, "str_buffer")
        assign_entry = semantic_entry_for_lexeme(source, entries, "assign")
        as_str_entry = semantic_entry_for_lexeme(source, entries, "as_str")
        capacity_entry = semantic_entry_for_lexeme(source, entries, "capacity")

        assert_equal "type", str_buffer_entry.fetch("tokenType")
        assert_equal "method", assign_entry.fetch("tokenType")
        assert_equal "method", as_str_entry.fetch("tokenType")
        assert_equal "method", capacity_entry.fetch("tokenType")
      end
    end

    def test_semantic_tokens_classify_array_and_span_as_types_but_array_ctor_as_function
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
        uri = "file:///tmp/lsp_semantic_generic_types_test.mt"
        source = SOURCE_WITH_GENERIC_TYPE_SURFACES
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

        span_type_entry = entries.find do |entry|
          entry.fetch("line") == 0 && source.lines.fetch(entry.fetch("line"))[entry.fetch("startChar"), 4] == "span"
        end or flunk("expected span semantic token entry in parameter type")

        array_return_entry = entries.find do |entry|
          entry.fetch("line") == 0 && source.lines.fetch(entry.fetch("line"))[entry.fetch("startChar"), 5] == "array"
        end or flunk("expected array semantic token entry in return type")

        array_ctor_entry = entries.find do |entry|
          entry.fetch("line") == 1 && source.lines.fetch(entry.fetch("line"))[entry.fetch("startChar"), 5] == "array"
        end or flunk("expected array semantic token entry in constructor call")

        assert_equal "type", span_type_entry.fetch("tokenType")
        assert_equal "type", array_return_entry.fetch("tokenType")
        assert_equal "function", array_ctor_entry.fetch("tokenType")
      end
    end

    def test_semantic_tokens_classify_all_generic_type_arguments_as_type_parameters
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
        uri = "file:///tmp/lsp_semantic_multi_type_argument_test.mt"
        source = SOURCE_WITH_MULTI_TYPE_ARGUMENT_SEMANTICS
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

        field_k = semantic_entry_for_lexeme_on_line(source, entries, "K", 4)
        field_v = semantic_entry_for_lexeme_on_line(source, entries, "V", 4)
        ctor_k = semantic_entry_for_lexeme_on_line(source, entries, "K", 7)
        ctor_v = semantic_entry_for_lexeme_on_line(source, entries, "V", 7)

        assert_equal "typeParameter", field_k.fetch("tokenType")
        assert_equal "typeParameter", field_v.fetch("tokenType")
        assert_equal "typeParameter", ctor_k.fetch("tokenType")
        assert_equal "typeParameter", ctor_v.fetch("tokenType")
      end
    end

    def test_semantic_tokens_classify_generic_methods_receiver_and_receiver_type_parameters
      source = <<~MT
        struct Cache[K, V]:
            key: K
            value: V

        extending Cache[K, V]:
            function read_key() -> K:
                return this.key

            function read_value() -> V:
                return this.value

            function choose[T](fallback: T) -> T:
                let selected = fallback
                return selected

            static function create(key: K, value: V) -> Cache[K, V]:
                return Cache[K, V](key = key, value = value)
      MT

      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
        uri = "file:///tmp/lsp_semantic_generic_methods_receiver_test.mt"
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

        header_k = semantic_entry_for_lexeme_on_line(source, entries, "K", 4)
        header_v = semantic_entry_for_lexeme_on_line(source, entries, "V", 4)
        read_key_return = semantic_entry_for_lexeme_on_line(source, entries, "K", 5)
        read_value_return = semantic_entry_for_lexeme_on_line(source, entries, "V", 8)
        this_key = semantic_entry_for_lexeme_on_line(source, entries, "this", 6)
        this_value = semantic_entry_for_lexeme_on_line(source, entries, "this", 9)
        fallback_ref = semantic_entry_for_lexeme_on_line(source, entries, "fallback", 12)
        selected_decl = semantic_entry_for_lexeme_on_line(source, entries, "selected", 12)
        selected_ref = semantic_entry_for_lexeme_on_line(source, entries, "selected", 13)
        ctor_k = semantic_entry_for_lexeme_on_line(source, entries, "K", 16)
        ctor_v = semantic_entry_for_lexeme_on_line(source, entries, "V", 16)

        assert_equal "typeParameter", header_k.fetch("tokenType")
        assert_includes header_k.fetch("modifierNames"), "declaration"
        assert_equal "typeParameter", header_v.fetch("tokenType")
        assert_includes header_v.fetch("modifierNames"), "declaration"
        assert_equal "typeParameter", read_key_return.fetch("tokenType")
        assert_equal "typeParameter", read_value_return.fetch("tokenType")
        assert_equal "parameter", this_key.fetch("tokenType")
        assert_equal "parameter", this_value.fetch("tokenType")
        assert_equal "parameter", fallback_ref.fetch("tokenType")
        assert_equal "variable", selected_decl.fetch("tokenType")
        assert_includes selected_decl.fetch("modifierNames"), "declaration"
        assert_equal "variable", selected_ref.fetch("tokenType")
        assert_equal "typeParameter", ctor_k.fetch("tokenType")
        assert_equal "typeParameter", ctor_v.fetch("tokenType")
      end
    end

    def test_semantic_tokens_prefer_parameter_binding_over_builtin_type_name
      source = <<~MT
        function is_ascii_space(ch: ubyte) -> bool:
            return ch == 32
      MT

      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
        uri = "file:///tmp/lsp_semantic_byte_parameter_test.mt"
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

        byte_decl = semantic_entry_for_lexeme_on_line(source, entries, "ch", 0)
        byte_ref = semantic_entry_for_lexeme_on_line(source, entries, "ch", 1)

        assert_equal "parameter", byte_decl.fetch("tokenType")
        assert_includes byte_decl.fetch("modifierNames"), "declaration"
        assert_equal "parameter", byte_ref.fetch("tokenType")
      end
    end

    def test_semantic_tokens_classify_ordered_map_receiver_type_parameters_and_members
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => path_to_uri(Dir.pwd), "capabilities" => {} })
        source_path = File.join(Dir.pwd, "std", "ordered_map.mt")
        source = File.read(source_path)
        uri = path_to_uri(source_path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

        header_line = source.lines.index { |line| line == "extending OrderedMap[K, V]:\n" } or flunk("expected OrderedMap extending header")
        set_line = source.lines.index { |line| line.include?("public mutable function set(key: K, value: V) -> Option[V]:") } or flunk("expected OrderedMap.set declaration")
        entries_line = source.lines.index { |line| line.include?("return this.entries()") } or flunk("expected OrderedMap.iter body")
        next_line = source.lines.index { |line| line.include?("if not this.started:") } or flunk("expected Entries.next guard")
        current_line = source.lines.index { |line| line.include?("public function current() -> Entry[K, V]:") } or flunk("expected Entries.current declaration")
        current_guard_line = source.lines.index { |line| line.include?("if current == null or not this.started:") } or flunk("expected Entries.current guard")

        header_k = semantic_entry_for_lexeme_on_line(source, entries, "K", header_line)
        header_v = semantic_entry_for_lexeme_on_line(source, entries, "V", header_line)
        option_type = semantic_entry_for_lexeme_on_line(source, entries, "Option", set_line)
        entries_call = semantic_entry_for_lexeme_on_line(source, entries, "entries", entries_line)
        next_this = semantic_entry_for_lexeme_on_line(source, entries, "this", next_line)
        next_started = semantic_entry_for_lexeme_on_line(source, entries, "started", next_line)
        current_decl = semantic_entry_for_lexeme_on_line(source, entries, "current", current_line)
        entry_return = semantic_entry_for_lexeme_on_line(source, entries, "Entry", current_line)
        current_k = semantic_entry_for_lexeme_on_line(source, entries, "K", current_line)
        current_v = semantic_entry_for_lexeme_on_line(source, entries, "V", current_line)
        current_this = semantic_entry_for_lexeme_on_line(source, entries, "this", current_guard_line)
        current_started = semantic_entry_for_lexeme_on_line(source, entries, "started", current_guard_line)

        assert_equal "typeParameter", header_k.fetch("tokenType")
        assert_includes header_k.fetch("modifierNames"), "declaration"
        assert_equal "typeParameter", header_v.fetch("tokenType")
        assert_includes header_v.fetch("modifierNames"), "declaration"
        assert_equal "type", option_type.fetch("tokenType")
        assert_equal "method", entries_call.fetch("tokenType")
        assert_equal "parameter", next_this.fetch("tokenType")
        assert_equal "property", next_started.fetch("tokenType")
        assert_equal "function", current_decl.fetch("tokenType")
        assert_equal "type", entry_return.fetch("tokenType")
        assert_equal "typeParameter", current_k.fetch("tokenType")
        assert_equal "typeParameter", current_v.fetch("tokenType")
        assert_equal "parameter", current_this.fetch("tokenType")
        assert_equal "property", current_started.fetch("tokenType")
      end
    end

    def test_semantic_tokens_classify_binary_heap_receiver_type_parameter_and_members
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => path_to_uri(Dir.pwd), "capabilities" => {} })
        source_path = File.join(Dir.pwd, "std", "binary_heap.mt")
        source = File.read(source_path)
        uri = path_to_uri(source_path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

        header_line = source.lines.index { |line| line == "extending BinaryHeap[T]:\n" } or flunk("expected BinaryHeap extending header")
        create_line = source.lines.index { |line| line.include?("return BinaryHeap[T](values = vec.Vec[T].create())") } or flunk("expected BinaryHeap.create body")
        push_line = source.lines.index { |line| line.include?("this.values.push(value)") } or flunk("expected BinaryHeap.push body")

        header_t = semantic_entry_for_lexeme_on_line(source, entries, "T", header_line)
        vec_alias = semantic_entry_for_lexeme_on_line(source, entries, "vec", create_line)
        push_this = semantic_entry_for_lexeme_on_line(source, entries, "this", push_line)
        push_values = semantic_entry_for_lexeme_on_line(source, entries, "values", push_line)
        push_call = semantic_entry_for_lexeme_on_line(source, entries, "push", push_line)

        assert_equal "typeParameter", header_t.fetch("tokenType")
        assert_includes header_t.fetch("modifierNames"), "declaration"
        assert_equal "namespace", vec_alias.fetch("tokenType")
        assert_equal "parameter", push_this.fetch("tokenType")
        assert_equal "property", push_values.fetch("tokenType")
        assert_equal "method", push_call.fetch("tokenType")
      end
    end

    def test_semantic_tokens_classify_priority_queue_receiver_type_parameter_and_members
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => path_to_uri(Dir.pwd), "capabilities" => {} })
        source_path = File.join(Dir.pwd, "std", "priority_queue.mt")
        source = File.read(source_path)
        uri = path_to_uri(source_path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

        header_line = source.lines.index { |line| line == "extending PriorityQueue[T]:\n" } or flunk("expected PriorityQueue extending header")
        iter_signature_line = source.lines.index { |line| line.include?("public function iter() -> binary_heap.Iter[T]:") } or flunk("expected PriorityQueue.iter signature")
        iter_line = source.lines.index { |line| line.include?("return this.values.iter()") } or flunk("expected PriorityQueue.iter body")
        enqueue_line = source.lines.index { |line| line.include?("this.values.push(value)") } or flunk("expected PriorityQueue.enqueue body")
        dequeue_line = source.lines.index { |line| line.include?("return this.values.pop()") } or flunk("expected PriorityQueue.dequeue body")

        header_t = semantic_entry_for_lexeme_on_line(source, entries, "T", header_line)
        binary_heap_alias = semantic_entry_for_lexeme_on_line(source, entries, "binary_heap", iter_signature_line)
        iter_this = semantic_entry_for_lexeme_on_line(source, entries, "this", iter_line)
        iter_values = semantic_entry_for_lexeme_on_line(source, entries, "values", iter_line)
        iter_call = semantic_entry_for_lexeme_on_line(source, entries, "iter", iter_line)
        enqueue_push = semantic_entry_for_lexeme_on_line(source, entries, "push", enqueue_line)
        dequeue_pop = semantic_entry_for_lexeme_on_line(source, entries, "pop", dequeue_line)

        assert_equal "typeParameter", header_t.fetch("tokenType")
        assert_includes header_t.fetch("modifierNames"), "declaration"
        assert_equal "namespace", binary_heap_alias.fetch("tokenType")
        assert_equal "parameter", iter_this.fetch("tokenType")
        assert_equal "property", iter_values.fetch("tokenType")
        assert_equal "method", iter_call.fetch("tokenType")
        assert_equal "method", enqueue_push.fetch("tokenType")
        assert_equal "method", dequeue_pop.fetch("tokenType")
      end
    end

    def test_semantic_tokens_classify_ordered_set_receiver_type_parameter_and_members
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => path_to_uri(Dir.pwd), "capabilities" => {} })
        source_path = File.join(Dir.pwd, "std", "ordered_set.mt")
        source = File.read(source_path)
        uri = path_to_uri(source_path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

        header_line = source.lines.index { |line| line == "extending OrderedSet[T]:\n" } or flunk("expected OrderedSet extending header")
        contains_line = source.lines.index { |line| line.include?("return this.get(value) != null") } or flunk("expected OrderedSet.contains body")
        iter_line = source.lines.index { |line| line.include?("return Iter[T](node = OrderedSet[T].minimum(this.root))") } or flunk("expected OrderedSet.iter body")
        next_line = source.lines.index { |line| line.include?("this.node = OrderedSet[T].successor(current)") } or flunk("expected OrderedSet.Iter.next body")

        header_t = semantic_entry_for_lexeme_on_line(source, entries, "T", header_line)
        contains_this = semantic_entry_for_lexeme_on_line(source, entries, "this", contains_line)
        get_call = semantic_entry_for_lexeme_on_line(source, entries, "get", contains_line)
        iter_t = semantic_entry_for_lexeme_on_line(source, entries, "T", iter_line)
        iter_root = semantic_entry_for_lexeme_on_line(source, entries, "root", iter_line)
        next_this = semantic_entry_for_lexeme_on_line(source, entries, "this", next_line)
        next_node = semantic_entry_for_lexeme_on_line(source, entries, "node", next_line)

        assert_equal "typeParameter", header_t.fetch("tokenType")
        assert_includes header_t.fetch("modifierNames"), "declaration"
        assert_equal "parameter", contains_this.fetch("tokenType")
        assert_equal "method", get_call.fetch("tokenType")
        assert_equal "typeParameter", iter_t.fetch("tokenType")
        assert_equal "property", iter_root.fetch("tokenType")
        assert_equal "parameter", next_this.fetch("tokenType")
        assert_equal "property", next_node.fetch("tokenType")
      end
    end

    def test_semantic_tokens_classify_parameters_named_labels_and_for_binders
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
        uri = "file:///tmp/lsp_semantic_parameter_labels_test.mt"
        source = SOURCE_WITH_PARAMETER_AND_LABEL_SEMANTICS
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

        position_decl = semantic_entry_for_lexeme_on_line(source, entries, "position", 4)
        position_ref = semantic_entry_for_lexeme_on_line(source, entries, "position", 7)
        x_label = semantic_entry_for_lexeme_on_line(source, entries, "x", 5)
        y_label = semantic_entry_for_lexeme_on_line(source, entries, "y", 5)
        index_decl = semantic_entry_for_lexeme_on_line(source, entries, "index", 6)
        index_ref = semantic_entry_for_lexeme_on_line(source, entries, "index", 7)

        assert_equal "parameter", position_decl.fetch("tokenType")
        assert_includes position_decl.fetch("modifierNames"), "declaration"
        assert_equal "parameter", position_ref.fetch("tokenType")
        refute_includes position_ref.fetch("modifierNames"), "declaration"
        assert_equal "property", x_label.fetch("tokenType")
        assert_equal "property", y_label.fetch("tokenType")
        assert_equal "variable", index_decl.fetch("tokenType")
        assert_includes index_decl.fetch("modifierNames"), "declaration"
        assert_equal "variable", index_ref.fetch("tokenType")
      end
    end

    def test_semantic_tokens_classify_struct_field_declarations_and_member_access
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
        uri = "file:///tmp/lsp_semantic_struct_field_test.mt"
        source = SOURCE_WITH_STRUCT_FIELD_SEMANTICS
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

        str_decl = semantic_entry_for_lexeme_on_line(source, entries, "str", 1)
        size_decl = semantic_entry_for_lexeme_on_line(source, entries, "size", 2)
        str_access = semantic_entry_for_lexeme_on_line(source, entries, "str", 5)
        size_access = semantic_entry_for_lexeme_on_line(source, entries, "size", 6)

        assert_equal "property", str_decl.fetch("tokenType")
        assert_includes str_decl.fetch("modifierNames"), "declaration"
        assert_equal "property", size_decl.fetch("tokenType")
        assert_includes size_decl.fetch("modifierNames"), "declaration"
        assert_equal "property", str_access.fetch("tokenType")
        refute_includes str_access.fetch("modifierNames"), "declaration"
        assert_equal "property", size_access.fetch("tokenType")
      end
    end

    def test_semantic_tokens_classify_resolved_callables_for_constructors_and_callable_values
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
        uri = "file:///tmp/lsp_semantic_resolved_callable_test.mt"
        source = SOURCE_WITH_RESOLVED_CALLABLE_SEMANTICS
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

        point_ctor = semantic_entry_for_lexeme_on_line(source, entries, "Point", 11)
        entry_ctor = semantic_entry_for_lexeme_on_line(source, entries, "Entry", 16)
        callback_call = semantic_entry_for_lexeme_on_line(source, entries, "callback", 17)
        field_callback_call = semantic_entry_for_lexeme_on_line(source, entries, "callback", 18)
        add_call = semantic_entry_for_lexeme_on_line(source, entries, "add", 19)

        assert_equal "type", point_ctor.fetch("tokenType")
        assert_equal "type", entry_ctor.fetch("tokenType")
        assert_equal "variable", callback_call.fetch("tokenType")
        assert_equal "property", field_callback_call.fetch("tokenType")
        assert_equal "function", add_call.fetch("tokenType")
      end
    end

    def test_semantic_tokens_classify_function_values_and_bare_zero_specialization
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
        uri = "file:///tmp/lsp_semantic_function_value_zero_test.mt"
        source = SOURCE_WITH_FUNCTION_VALUE_AND_ZERO_SEMANTICS
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

        callback_value_line = source.lines.index { |text| text.include?("let callback: fn(value: int) -> int = add_one") }
        zero_value_line = source.lines.index { |text| text.include?("let zeroed = zero[Box]") }
        default_value_line = source.lines.index { |text| text.include?("let defaulted = default[Box]") }
        callback_argument_line = source.lines.index { |text| text.include?("return apply(add_one, zeroed.value) + callback(defaulted.value)") }

        callback_value = semantic_entry_for_lexeme_on_line(source, entries, "add_one", callback_value_line)
        zero_value = semantic_entry_for_lexeme_on_line(source, entries, "zero", zero_value_line)
        default_value = semantic_entry_for_lexeme_on_line(source, entries, "default", default_value_line)
        callback_argument = semantic_entry_for_lexeme_on_line(source, entries, "add_one", callback_argument_line)

        assert_equal "function", callback_value.fetch("tokenType")
        assert_equal "function", callback_argument.fetch("tokenType")
        assert_equal "function", zero_value.fetch("tokenType")
        assert_equal "function", default_value.fetch("tokenType")
        assert_includes zero_value.fetch("modifierNames"), "defaultLibrary"
        assert_includes default_value.fetch("modifierNames"), "defaultLibrary"
      end
    end

    def test_semantic_tokens_do_not_mark_user_defined_cast_or_range_as_default_library
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
        uri = "file:///tmp/lsp_semantic_user_defined_cast_range_test.mt"
        source = SOURCE_WITH_USER_DEFINED_CAST_AND_RANGE_SEMANTICS
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

        cast_call = semantic_entry_for_lexeme_on_line(source, entries, "cast", 7)
        range_call = semantic_entry_for_lexeme_on_line(source, entries, "range", 8)

        assert_equal "function", cast_call.fetch("tokenType")
        assert_equal "function", range_call.fetch("tokenType")
        refute_includes cast_call.fetch("modifierNames"), "defaultLibrary"
        refute_includes range_call.fetch("modifierNames"), "defaultLibrary"
      end
    end

    def test_semantic_tokens_mark_builtin_associated_hooks_as_default_library
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
        uri = "file:///tmp/lsp_semantic_builtin_associated_hooks_test.mt"
        source = SOURCE_WITH_ASSOCIATED_HOOK_BUILTINS
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

        hash_line = source.lines.index { |text| text.include?("let hashed = hash[Key](key)") }
        equal_line = source.lines.index { |text| text.include?("let same = equal[Key](key, other)") }
        order_line = source.lines.index { |text| text.include?("order[Key](key, other)") }

        hash_call = semantic_entry_for_lexeme_on_line(source, entries, "hash", hash_line)
        equal_call = semantic_entry_for_lexeme_on_line(source, entries, "equal", equal_line)
        order_call = semantic_entry_for_lexeme_on_line(source, entries, "order", order_line)

        assert_equal "function", hash_call.fetch("tokenType")
        assert_equal "function", equal_call.fetch("tokenType")
        assert_equal "function", order_call.fetch("tokenType")
        assert_includes hash_call.fetch("modifierNames"), "defaultLibrary"
        assert_includes equal_call.fetch("modifierNames"), "defaultLibrary"
        assert_includes order_call.fetch("modifierNames"), "defaultLibrary"
      end
    end

    def test_semantic_tokens_mark_attribute_reflection_builtins_as_default_library
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
        uri = "file:///tmp/lsp_semantic_attribute_reflection_test.mt"
        source = <<~MT
          public attribute[field, callable] trace(name: str)

          @[packed]
          @[align(16)]
          struct Packet:
              @[trace("payload_len")]
              payload_len: uint

          @[trace("parse_packet")]
          function parse_packet() -> int:
              return 0

          static_assert(has_attribute(field_of(Packet, payload_len), trace), "field attribute missing")
          static_assert(has_attribute(callable_of(parse_packet), trace), "callable attribute missing")
          static_assert(
              has_attribute(Packet, packed) and
              attribute_arg[ptr_uint](attribute_of(Packet, align), bytes) == 16 and
              attribute_arg[str](attribute_of(field_of(Packet, payload_len), trace), name) == "payload_len",
              "attribute reflection changed"
          )

          function main() -> int:
              return 0
        MT

        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

        has_attribute_field_line = source.lines.index { |text| text.include?("has_attribute(field_of(Packet, payload_len), trace)") }
        has_attribute_callable_line = source.lines.index { |text| text.include?("has_attribute(callable_of(parse_packet), trace)") }
        packed_attribute_line = source.lines.index { |text| text.include?("@[packed]") }
        align_attribute_line = source.lines.index { |text| text.include?("@[align(16)]") }
        trace_attribute_line = source.lines.index { |text| text.include?("@[trace(\"payload_len\")]") }
        packed_reflection_line = source.lines.index { |text| text.include?("has_attribute(Packet, packed) and") }
        align_reflection_line = source.lines.index { |text| text.include?("attribute_arg[ptr_uint](attribute_of(Packet, align), bytes) == 16") }
        attribute_arg_line = source.lines.index { |text| text.include?("attribute_arg[str](attribute_of(field_of(Packet, payload_len), trace), name)") }

        attribute_keyword = semantic_entry_for_lexeme_on_line(source, entries, "attribute", 0)
        attribute_decl_name = semantic_entry_for_lexeme_on_line(source, entries, "trace", 0)
        packed_attribute = semantic_entry_for_lexeme_on_line(source, entries, "packed", packed_attribute_line)
        align_attribute = semantic_entry_for_lexeme_on_line(source, entries, "align", align_attribute_line)
        trace_attribute = semantic_entry_for_lexeme_on_line(source, entries, "trace", trace_attribute_line)
        has_attribute_call = semantic_entry_for_lexeme_on_line(source, entries, "has_attribute", has_attribute_field_line)
        field_of_call = semantic_entry_for_lexeme_on_line(source, entries, "field_of", has_attribute_field_line)
        callable_of_call = semantic_entry_for_lexeme_on_line(source, entries, "callable_of", has_attribute_callable_line)
        attribute_arg_call = semantic_entry_for_lexeme_on_line(source, entries, "attribute_arg", attribute_arg_line)
        attribute_of_call = semantic_entry_for_lexeme_on_line(source, entries, "attribute_of", attribute_arg_line)
        trace_reflection_name = semantic_entry_for_lexeme_on_line(source, entries, "trace", has_attribute_field_line)
        packed_reflection_name = semantic_entry_for_lexeme_on_line(source, entries, "packed", packed_reflection_line)
        align_reflection_name = semantic_entry_for_lexeme_on_line(source, entries, "align", align_reflection_line)

        assert_equal "keyword", attribute_keyword.fetch("tokenType")
        assert_equal "decorator", attribute_decl_name.fetch("tokenType")
        assert_includes attribute_decl_name.fetch("modifierNames"), "declaration"

        [packed_attribute, align_attribute, trace_attribute, trace_reflection_name, packed_reflection_name, align_reflection_name].each do |entry|
          assert_equal "decorator", entry.fetch("tokenType")
          assert_empty entry.fetch("modifierNames")
        end

        [has_attribute_call, field_of_call, callable_of_call, attribute_arg_call, attribute_of_call].each do |entry|
          assert_equal "function", entry.fetch("tokenType")
          assert_includes entry.fetch("modifierNames"), "defaultLibrary"
        end
      end
    end

    def test_semantic_tokens_do_not_mark_user_defined_hash_equal_order_as_default_library
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
        uri = "file:///tmp/lsp_semantic_user_defined_associated_hooks_test.mt"
        source = SOURCE_WITH_USER_DEFINED_ASSOCIATED_HOOK_NAMES
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

        hash_line = source.lines.index { |text| text.include?("let hashed = hash[int](value)") }
        equal_line = source.lines.index { |text| text.include?("let same = equal[int](value, value)") }
        order_line = source.lines.index { |text| text.include?("return order[int](value, value)") }

        hash_call = semantic_entry_for_lexeme_on_line(source, entries, "hash", hash_line)
        equal_call = semantic_entry_for_lexeme_on_line(source, entries, "equal", equal_line)
        order_call = semantic_entry_for_lexeme_on_line(source, entries, "order", order_line)

        assert_equal "function", hash_call.fetch("tokenType")
        assert_equal "function", equal_call.fetch("tokenType")
        assert_equal "function", order_call.fetch("tokenType")
        refute_includes hash_call.fetch("modifierNames"), "defaultLibrary"
        refute_includes equal_call.fetch("modifierNames"), "defaultLibrary"
        refute_includes order_call.fetch("modifierNames"), "defaultLibrary"
      end
    end

    def test_semantic_tokens_do_not_classify_invalid_bare_function_reference_as_function
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
        uri = "file:///tmp/lsp_semantic_invalid_bare_function_reference_test.mt"
        source = SOURCE_WITH_INVALID_BARE_FUNCTION_REFERENCE_SEMANTICS
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)
        invalid_reference = semantic_entry_for_lexeme_on_line(source, entries, "add_one", 4)

        assert_equal "variable", invalid_reference.fetch("tokenType")
      end
    end

    def test_semantic_tokens_classify_specialized_member_calls_as_function_and_method
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => path_to_uri(Dir.pwd), "capabilities" => {} })
        source = SOURCE_WITH_SPECIALIZED_MEMBER_CALL_SEMANTICS
        path = File.join(Dir.pwd, "tmp", "lsp_semantic_specialized_member_calls_test.mt")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, source)
        uri = path_to_uri(path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)
        create_for_line = source.lines.index { |line| line.include?("create_for") }
        alloc_line = source.lines.index { |line| line.include?("alloc") }
        create_for_entry = semantic_entry_for_lexeme_on_line(source, entries, "create_for", create_for_line)
        alloc_entry = semantic_entry_for_lexeme_on_line(source, entries, "alloc", alloc_line)

        assert_equal "function", create_for_entry.fetch("tokenType")
        assert_equal "method", alloc_entry.fetch("tokenType")
      end
    end

    def test_semantic_tokens_classify_generic_parameter_shadowing_import_alias_as_parameter
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => path_to_uri(Dir.pwd), "capabilities" => {} })
        source = SOURCE_WITH_GENERIC_PARAMETER_SHADOWING_IMPORT_SEMANTICS
        path = File.join(Dir.pwd, "tmp", "lsp_semantic_generic_param_shadow_test.mt")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, source)
        uri = path_to_uri(path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)
        status_decl_line = source.lines.index { |line| line.include?("function wrap") }
        status_if_line = source.lines.index { |line| line.include?("if status") }
        status_return_line = source.lines.index { |line| line.include?("return status") }
        status_decl = semantic_entry_for_lexeme_on_line(source, entries, "status", status_decl_line)
        status_if_ref = semantic_entry_for_lexeme_on_line(source, entries, "status", status_if_line)
        status_return_ref = semantic_entry_for_lexeme_on_line(source, entries, "status", status_return_line)

        assert_equal "parameter", status_decl.fetch("tokenType")
        assert_includes status_decl.fetch("modifierNames"), "declaration"
        assert_equal "parameter", status_if_ref.fetch("tokenType")
        refute_includes status_if_ref.fetch("modifierNames"), "declaration"
        assert_equal "parameter", status_return_ref.fetch("tokenType")
        refute_includes status_return_ref.fetch("modifierNames"), "declaration"
      end
    end

    def test_semantic_tokens_classify_specialized_generic_function_calls_as_function
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
        uri = "file:///tmp/lsp_semantic_specialized_function_call_test.mt"
        source = SOURCE_WITH_SPECIALIZED_FUNCTION_CALL_SEMANTICS
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)
        identity_call = semantic_entry_for_lexeme_on_line(source, entries, "identity", 4)

        assert_equal "function", identity_call.fetch("tokenType")
      end
    end

    def test_semantic_tokens_classify_keyword_module_and_import_path_segments_as_namespace
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => path_to_uri(Dir.pwd), "capabilities" => {} })
        source = SOURCE_WITH_KEYWORD_NAMESPACE_PATH_SEMANTICS
        path = File.join(Dir.pwd, "tmp", "lsp_semantic_keyword_namespace_path_test.mt")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, source)
        uri = path_to_uri(path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)
        import_async_line = source.lines.index { |line| line.include?("tmp.async") }
        import_async = semantic_entry_for_lexeme_on_line(source, entries, "async", import_async_line)

        assert_equal "namespace", import_async.fetch("tokenType")
      end
    end

    def test_semantic_tokens_classify_generic_local_shadowing_and_specialized_function_values
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => path_to_uri(Dir.pwd), "capabilities" => {} })
        source = SOURCE_WITH_GENERIC_LOCAL_AND_SPECIALIZED_FUNCTION_VALUE_SEMANTICS
        path = File.join(Dir.pwd, "tmp", "lsp_semantic_generic_local_specialized_test.mt")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, source)
        uri = path_to_uri(path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)
        status_decl_line = source.lines.index { |line| line.include?("var status") }
        status_assign_line = source.lines.index { |line| line.include?("status = invoke") }
        status_if_line = source.lines.index { |line| line.include?("if status") }
        status_return_line = source.lines.index { |line| line.include?("return status") }
        status_decl = semantic_entry_for_lexeme_on_line(source, entries, "status", status_decl_line)
        status_assign_ref = semantic_entry_for_lexeme_on_line(source, entries, "status", status_assign_line)
        make_status_ref = semantic_entry_for_lexeme_on_line(source, entries, "make_status", status_assign_line)
        status_if_ref = semantic_entry_for_lexeme_on_line(source, entries, "status", status_if_line)
        status_return_ref = semantic_entry_for_lexeme_on_line(source, entries, "status", status_return_line)

        assert_equal "variable", status_decl.fetch("tokenType")
        assert_includes status_decl.fetch("modifierNames"), "declaration"
        assert_equal "variable", status_assign_ref.fetch("tokenType")
        refute_includes status_assign_ref.fetch("modifierNames"), "declaration"
        assert_equal "function", make_status_ref.fetch("tokenType")
        assert_equal "variable", status_if_ref.fetch("tokenType")
        assert_equal "variable", status_return_ref.fetch("tokenType")
      end
    end

    def test_semantic_tokens_do_not_let_generic_parameter_fallback_override_member_access
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
        uri = "file:///tmp/lsp_semantic_generic_parameter_property_test.mt"
        source = SOURCE_WITH_GENERIC_PARAMETER_AND_PROPERTY_SEMANTICS
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)
        property_access = semantic_entry_for_lexeme_on_line(source, entries, "status", 4)
        parameter_ref = semantic_entry_for_lexeme_on_line(source, entries, "status", 5)

        assert_equal "property", property_access.fetch("tokenType")
        assert_equal "parameter", parameter_ref.fetch("tokenType")
      end
    end

    def test_semantic_tokens_classify_type_parameters_match_scrutinees_and_match_binders
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
        uri = "file:///tmp/lsp_semantic_generic_variant_test.mt"
        source = SOURCE_WITH_GENERIC_VARIANT_SEMANTICS
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

        header_type_param = semantic_entry_for_lexeme_on_line(source, entries, "T", 0)
        field_type_param = semantic_entry_for_lexeme_on_line(source, entries, "T", 1)
        match_scrutinee = semantic_entry_for_lexeme_on_line(source, entries, "value", 5)
        match_binder = semantic_entry_for_lexeme_on_line(source, entries, "payload", 6)

        assert_equal "typeParameter", header_type_param.fetch("tokenType")
        assert_includes header_type_param.fetch("modifierNames"), "declaration"
        assert_equal "typeParameter", field_type_param.fetch("tokenType")
        assert_equal "parameter", match_scrutinee.fetch("tokenType")
        refute_includes match_scrutinee.fetch("modifierNames"), "declaration"
        assert_equal "variable", match_binder.fetch("tokenType")
        assert_includes match_binder.fetch("modifierNames"), "declaration"
      end
    end

    def test_semantic_tokens_classify_variant_members_payload_fields_and_generic_constructor_labels
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
        uri = "file:///tmp/lsp_semantic_variant_constructor_labels_test.mt"
        source = <<~MT
            variant Choice[T]:
                some(value: T)
                none

            variant Outcome[T, E]:
                success(value: T)
                failure(error: E)

            struct Entry[T]:
                key: T
                count: int

            function classify(entry: Entry[int]) -> Outcome[int, int]:
                let rebuilt = Entry[int](key = entry.key, count = entry.count)
                match Choice[int].some(value = rebuilt.count):
                    Choice.some as payload:
                        return Outcome[int, int].success(value = payload.value)
                    Choice.none:
                        return Outcome[int, int].failure(error = rebuilt.count)
        MT

        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

        some_decl = semantic_entry_for_lexeme_on_line(source, entries, "some", 1)
        error_decl = semantic_entry_for_lexeme_on_line(source, entries, "error", 6)
        key_label = semantic_entry_for_lexeme_on_line(source, entries, "key", 13)
        count_label = semantic_entry_for_lexeme_on_line(source, entries, "count", 13)
        some_ctor = semantic_entry_for_lexeme_on_line(source, entries, "some", 14)
        some_match = semantic_entry_for_lexeme_on_line(source, entries, "some", 15)
        none_match = semantic_entry_for_lexeme_on_line(source, entries, "none", 17)
        failure_return = semantic_entry_for_lexeme_on_line(source, entries, "failure", 18)
        error_label = semantic_entry_for_lexeme_on_line(source, entries, "error", 18)

        assert_equal "enumMember", some_decl.fetch("tokenType")
        assert_includes some_decl.fetch("modifierNames"), "declaration"
        assert_equal "property", error_decl.fetch("tokenType")
        assert_includes error_decl.fetch("modifierNames"), "declaration"
        assert_equal "property", key_label.fetch("tokenType")
        assert_equal "property", count_label.fetch("tokenType")
        assert_equal "enumMember", some_ctor.fetch("tokenType")
        assert_equal "enumMember", some_match.fetch("tokenType")
        assert_equal "enumMember", none_match.fetch("tokenType")
        assert_equal "enumMember", failure_return.fetch("tokenType")
        assert_equal "property", error_label.fetch("tokenType")
      end
    end

    def test_semantic_tokens_fstring_delimiters_do_not_override_textmate
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
        uri = "file:///tmp/lsp_semantic_fstring_test.mt"
        source = SOURCE_WITH_FSTRING_INTERPOLATION
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)
        interpolation_line = source.lines.fetch(2)
        hash_index = interpolation_line.index('#{')
        rbrace_index = interpolation_line.index("}", hash_index)

        refute entries.any? { |entry| entry.fetch("line") == 2 && entry.fetch("startChar") == hash_index && entry.fetch("tokenType") == "operator" }
        refute entries.any? { |entry| entry.fetch("line") == 2 && entry.fetch("startChar") == (hash_index + 1) && entry.fetch("tokenType") == "operator" }
        refute entries.any? { |entry| entry.fetch("line") == 2 && entry.fetch("startChar") == rbrace_index && entry.fetch("tokenType") == "operator" }

        interpolation_name_entry = entries.find do |entry|
          entry.fetch("line") == 2 && interpolation_line[entry.fetch("startChar"), 4] == "name"
        end
        refute_nil interpolation_name_entry
        assert_equal "variable", interpolation_name_entry.fetch("tokenType")
      end
    end

    def test_semantic_tokens_classify_fstring_member_access_with_real_context
      protocol = Object.new
      protocol.define_singleton_method(:write_notification) { |_method, _params| nil }

      server = MilkTea::LSP::Server.new(protocol: protocol)
      init = server.send(:handle_initialize, { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_semantic_fstring_member_access_test.mt"
      source = SOURCE_WITH_FSTRING_MEMBER_INTERPOLATION

      server.send(:handle_did_open, {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      response = server.send(:handle_semantic_tokens_full, {
        "textDocument" => { "uri" => uri }
      })

      legend = init.fetch(:capabilities).fetch(:semanticTokensProvider).fetch(:legend)
      entries = decode_semantic_token_entries(response.fetch(:data), {
        "tokenTypes" => legend.fetch(:tokenTypes),
        "tokenModifiers" => legend.fetch(:tokenModifiers),
      })
      snapshot_entry = semantic_entry_for_lexeme_on_line(source, entries, "snapshot", 8)
      score_entry = semantic_entry_for_lexeme_on_line(source, entries, "score", 8)

      assert_equal "property", snapshot_entry.fetch("tokenType")
      assert_equal "property", score_entry.fetch("tokenType")
    ensure
      server&.send(:handle_shutdown, {})
    end

    def test_semantic_tokens_cover_multiline_heredoc_strings
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
        uri = "file:///tmp/lsp_semantic_heredoc_test.mt"
        source = SOURCE_WITH_PLAIN_HEREDOC_CSTRING
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)
        string_entries = entries.select { |entry| entry.fetch("tokenType") == "string" }
        covered_lines = string_entries.map { |entry| entry.fetch("line") }.uniq.sort

        assert_includes covered_lines, 0
        assert_includes covered_lines, 1
        assert_includes covered_lines, 2
        assert_includes covered_lines, 3
      end
    end

    def test_semantic_tokens_do_not_override_glsl_heredoc_body
      assert_embedded_heredoc_body_has_no_string_semantic_tokens(
        SOURCE_WITH_GLSL_HEREDOC_CSTRING,
        "file:///tmp/lsp_semantic_glsl_heredoc_test.mt"
      )
    end

    def test_semantic_tokens_do_not_override_alt_shader_tag_heredoc_body
      assert_embedded_heredoc_body_has_no_string_semantic_tokens(
        SOURCE_WITH_VERT_HEREDOC_CSTRING,
        "file:///tmp/lsp_semantic_vert_heredoc_test.mt"
      )
    end

    def test_semantic_tokens_do_not_override_json_heredoc_body
      assert_embedded_heredoc_body_has_no_string_semantic_tokens(
        SOURCE_WITH_JSON_HEREDOC_CSTRING,
        "file:///tmp/lsp_semantic_json_heredoc_test.mt"
      )
    end

    def test_semantic_tokens_do_not_override_jsonc_heredoc_body
      assert_embedded_heredoc_body_has_no_string_semantic_tokens(
        SOURCE_WITH_JSONC_HEREDOC_CSTRING,
        "file:///tmp/lsp_semantic_jsonc_heredoc_test.mt"
      )
    end

    def test_semantic_tokens_do_not_override_sql_heredoc_body
      assert_embedded_heredoc_body_has_no_string_semantic_tokens(
        SOURCE_WITH_SQL_HEREDOC_CSTRING,
        "file:///tmp/lsp_semantic_sql_heredoc_test.mt"
      )
    end

    def test_semantic_tokens_full_stays_within_latency_budget
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
        uri = "file:///tmp/lsp_semantic_latency_test.mt"
        source = <<~MT
          #{SOURCE_WITH_STR_BUFFER_METHODS}
          #{SOURCE_WITH_GENERIC_TYPE_SURFACES}
          #{SOURCE_WITH_FSTRING_INTERPOLATION}
        MT
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        elapsed_ms, response = measure_request_ms do
          client.send_request("textDocument/semanticTokens/full", {
            "textDocument" => { "uri" => uri }
          })
        end

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

        assert entries.length >= 6, "expected semantic token entries for latency source"
        assert_operator elapsed_ms, :<, SEMANTIC_TOKENS_LATENCY_BUDGET_MS,
                        "semanticTokens/full took #{format("%.2f", elapsed_ms)}ms (budget #{SEMANTIC_TOKENS_LATENCY_BUDGET_MS}ms)"
      end
    end

  public

  def test_code_action_quickfix_prefer_let
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_quickfix_prefer_let.mt"
      source = <<~MT
        function main() -> int:
            var x = 1
            return x
      MT
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      prefer_let_diag = {
        "source" => "milk-tea",
        "code"   => "prefer-let",
        "range"  => { "start" => { "line" => 1, "character" => 4 }, "end" => { "line" => 1, "character" => 13 } },
        "message" => "var 'x' is never reassigned; prefer 'let'"
      }

      response = client.send_request("textDocument/codeAction", {
        "textDocument" => { "uri" => uri },
        "range" => { "start" => { "line" => 1, "character" => 0 }, "end" => { "line" => 1, "character" => 0 } },
        "context" => { "diagnostics" => [prefer_let_diag] }
      })

      actions = response.fetch("result")
      quickfix = actions.find { |a| a["code"] == "prefer-let" || a.dig("diagnostics", 0, "code") == "prefer-let" }
      assert quickfix, "expected a quickFix action for prefer-let"
      assert_equal "quickFix", quickfix["kind"]
      edit_text = quickfix.dig("edit", "changes", uri, 0, "newText")
      assert_match(/\blet\b/, edit_text)
      refute_match(/\bvar\b/, edit_text)
    end
  end

  def test_code_action_quickfix_reserved_primitive_name
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_quickfix_reserved_primitive_name.mt"
      source = <<~MT
        function is_ascii_space(byte: ubyte) -> bool:
            let byte_value = byte
            return byte == 32 and byte_value == 32
      MT
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      reserved_diag = {
        "source" => "milk-tea",
        "code" => "reserved-primitive-name",
        "range" => { "start" => { "line" => 0, "character" => 24 }, "end" => { "line" => 0, "character" => 28 } },
        "message" => "parameter 'byte' uses reserved built-in type name 'byte'; rename it before this becomes a hard error"
      }

      response = client.send_request("textDocument/codeAction", {
        "textDocument" => { "uri" => uri },
        "range" => { "start" => { "line" => 0, "character" => 24 }, "end" => { "line" => 0, "character" => 28 } },
        "context" => { "diagnostics" => [reserved_diag] }
      })

      actions = response.fetch("result")
      quickfix = actions.find { |action| action["kind"] == "quickFix" && action["title"] == "Rename 'byte' to 'byte_value_2'" }
      assert quickfix, "expected a quickFix action for reserved-primitive-name"
      edits = quickfix.dig("edit", "changes", uri)
      assert_equal 3, edits.length
      assert_equal ["byte_value_2"], edits.map { |edit| edit["newText"] }.uniq
    end
  end

  def test_code_action_quickfix_redundant_else
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_quickfix_redundant_else.mt"
      source = <<~MT
        function sign(n: int) -> int:
            if n > 0:
                return 1
            else:
                return -1
      MT
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      redundant_diag = {
        "source" => "milk-tea",
        "code"   => "redundant-else",
        "range"  => { "start" => { "line" => 4, "character" => 8 }, "end" => { "line" => 4, "character" => 17 } },
        "message" => "else block is redundant because all preceding branches return"
      }

      response = client.send_request("textDocument/codeAction", {
        "textDocument" => { "uri" => uri },
        "range" => { "start" => { "line" => 4, "character" => 0 }, "end" => { "line" => 4, "character" => 0 } },
        "context" => { "diagnostics" => [redundant_diag] }
      })

      actions = response.fetch("result")
      quickfix = actions.find { |a| a["kind"] == "quickFix" && a["title"] == "Remove redundant else" }
      assert quickfix, "expected a quickFix action for redundant-else"
      edit_changes = quickfix.dig("edit", "changes", uri)
      assert_kind_of Array, edit_changes
      new_text = edit_changes.first["newText"]
      refute_match(/else:/, new_text)
      assert_match(/return -1/, new_text)
    end
  end


  def test_code_action_quickfix_redundant_return
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_quickfix_redundant_return.mt"
      source = <<~MT
        function main() -> void:
            let _ = 1
            return
      MT
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      redundant_diag = {
        "source" => "milk-tea",
        "code"   => "redundant-return",
        "range"  => { "start" => { "line" => 2, "character" => 4 }, "end" => { "line" => 2, "character" => 10 } },
        "message" => "final bare return in void function is redundant"
      }

      response = client.send_request("textDocument/codeAction", {
        "textDocument" => { "uri" => uri },
        "range" => { "start" => { "line" => 2, "character" => 0 }, "end" => { "line" => 2, "character" => 0 } },
        "context" => { "diagnostics" => [redundant_diag] }
      })

      actions = response.fetch("result")
      quickfix = actions.find { |a| a["kind"] == "quickFix" && a["title"] == "Remove redundant return" }
      assert quickfix, "expected a quickFix action for redundant-return"
      edit = quickfix.dig("edit", "changes", uri, 0)
      assert_equal "", edit["newText"]
      assert_equal({ "line" => 2, "character" => 0 }, edit.dig("range", "start"))
      assert_equal({ "line" => 3, "character" => 0 }, edit.dig("range", "end"))
    end
  end

  def test_code_action_quickfix_line_too_long_wraps_argument_list
    Dir.mktmpdir("milk-tea-lsp-line-too-long") do |dir|
      path = File.join(dir, "sample.mt")
      File.write(File.join(dir, ".mt-lint.yml"), <<~YAML)
        max_line_length: 40
        select:
          - line-too-long
        ignore: []
      YAML

      source = <<~MT
        function main() -> int:
            return log_value("alpha", "beta", "gamma", "delta")
      MT
      uri = path_to_uri(path)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/codeAction", {
          "textDocument" => { "uri" => uri },
          "range" => { "start" => { "line" => 1, "character" => 40 }, "end" => { "line" => 1, "character" => 55 } },
          "context" => {
            "diagnostics" => [{
              "source" => "milk-tea",
              "code" => "line-too-long",
              "range" => { "start" => { "line" => 1, "character" => 40 }, "end" => { "line" => 1, "character" => 55 } },
              "message" => "line exceeds max length of 40 columns (55); wrap the expression"
            }]
          }
        })

        actions = response.fetch("result")
        quickfix = actions.find { |action| action["kind"] == "quickFix" && action["title"] == "Wrap long line" }
        assert quickfix, "expected a quickFix action for line-too-long"
        edit = quickfix.dig("edit", "changes", uri, 0)
        assert_includes edit["newText"], "return log_value(\n"
        assert_includes edit["newText"], "        \"delta\"\n"
      end
    end
  end

  def test_code_action_quickfix_line_too_long_wraps_type_argument_list
    Dir.mktmpdir("milk-tea-lsp-line-too-long-type-list") do |dir|
      path = File.join(dir, "sample.mt")
      File.write(File.join(dir, ".mt-lint.yml"), <<~YAML)
        max_line_length: 50
        select:
          - line-too-long
        ignore: []
      YAML

      source = <<~MT
        function main() -> Result[Option[AlphaValue], BetaValue, GammaValue]:
            return 0
      MT
      uri = path_to_uri(path)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/codeAction", {
          "textDocument" => { "uri" => uri },
          "range" => { "start" => { "line" => 0, "character" => 50 }, "end" => { "line" => 0, "character" => 68 } },
          "context" => {
            "diagnostics" => [{
              "source" => "milk-tea",
              "code" => "line-too-long",
              "range" => { "start" => { "line" => 0, "character" => 50 }, "end" => { "line" => 0, "character" => 68 } },
              "message" => "line exceeds max length of 50 columns (68); wrap the expression"
            }]
          }
        })

        actions = response.fetch("result")
        quickfix = actions.find { |action| action["kind"] == "quickFix" && action["title"] == "Wrap long line" }
        assert quickfix, "expected a quickFix action for line-too-long"
        edit = quickfix.dig("edit", "changes", uri, 0)
        assert_includes edit["newText"], "function main() -> Result[\n"
        assert_includes edit["newText"], "    Option[AlphaValue],\n"
        assert_includes edit["newText"], "    GammaValue\n"
      end
    end
  end

  def test_code_action_quickfix_line_too_long_wraps_if_logical_chain
    Dir.mktmpdir("milk-tea-lsp-line-too-long-condition") do |dir|
      path = File.join(dir, "sample.mt")
      File.write(File.join(dir, ".mt-lint.yml"), <<~YAML)
        max_line_length: 100
        select:
          - line-too-long
        ignore: []
      YAML

      source = <<~MT
        function main(kind: int, has_byte: bool, ctrl: bool, alt: bool, input_byte: int) -> void:
            if kind == 2 and has_byte and not ctrl and not alt and input_byte >= 32 and input_byte < 127 and input_byte != 64:
                pass
      MT
      uri = path_to_uri(path)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/codeAction", {
          "textDocument" => { "uri" => uri },
          "range" => { "start" => { "line" => 1, "character" => 100 }, "end" => { "line" => 1, "character" => 114 } },
          "context" => {
            "diagnostics" => [{
              "source" => "milk-tea",
              "code" => "line-too-long",
              "range" => { "start" => { "line" => 1, "character" => 100 }, "end" => { "line" => 1, "character" => 114 } },
              "message" => "line exceeds max length of 100 columns (114); wrap the expression"
            }]
          }
        })

        actions = response.fetch("result")
        quickfix = actions.find { |action| action["kind"] == "quickFix" && action["title"] == "Wrap long line" }
        assert quickfix, "expected a quickFix action for line-too-long"
        edit = quickfix.dig("edit", "changes", uri, 0)
        assert_includes edit["newText"], "    if (\n"
        assert_includes edit["newText"], "        and has_byte\n"
        assert_includes edit["newText"], "        and input_byte != 64\n"
        assert_includes edit["newText"], "    ):\n"
      end
    end
  end

  def test_code_action_quickfix_line_too_long_wraps_else_if_logical_chain
    Dir.mktmpdir("milk-tea-lsp-line-too-long-else-if") do |dir|
      path = File.join(dir, "sample.mt")
      File.write(File.join(dir, ".mt-lint.yml"), <<~YAML)
        max_line_length: 90
        select:
          - line-too-long
        ignore: []
      YAML

      source = <<~MT
        function main(flag: bool, value: int, other: int) -> int:
            if flag:
                return 1
            else if flag and value > 0 and other > 0 and value != other and other < 100 and value < 200:
                return 2
            return 0
      MT
      uri = path_to_uri(path)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/codeAction", {
          "textDocument" => { "uri" => uri },
          "range" => { "start" => { "line" => 3, "character" => 90 }, "end" => { "line" => 3, "character" => 101 } },
          "context" => {
            "diagnostics" => [{
              "source" => "milk-tea",
              "code" => "line-too-long",
              "range" => { "start" => { "line" => 3, "character" => 90 }, "end" => { "line" => 3, "character" => 101 } },
              "message" => "line exceeds max length of 90 columns (101); wrap the expression"
            }]
          }
        })

        actions = response.fetch("result")
        quickfix = actions.find { |action| action["kind"] == "quickFix" && action["title"] == "Wrap long line" }
        assert quickfix, "expected a quickFix action for line-too-long"
        edit = quickfix.dig("edit", "changes", uri, 0)
        assert_includes edit["newText"], "    else if (\n"
        assert_includes edit["newText"], "        and value > 0\n"
        assert_includes edit["newText"], "        and value < 200\n"
        assert_includes edit["newText"], "    ):\n"
      end
    end
  end

  def test_code_action_quickfix_redundant_ignored_match_binding
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_quickfix_redundant_ignored_match_binding.mt"
      source = <<~MT
        function main(value: Option[int]) -> int:
            match value:
                Option.some as _:
                    return 1
                Option.none:
                    return 0
      MT
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      span_start = source.lines[2].index(" as _")
      span_end = span_start + " as _".length

      redundant_diag = {
        "source" => "milk-tea",
        "code" => "redundant-ignored-match-binding",
        "range" => { "start" => { "line" => 2, "character" => span_start }, "end" => { "line" => 2, "character" => span_end } },
        "message" => "ignored match binding is redundant; remove 'as _'"
      }

      response = client.send_request("textDocument/codeAction", {
        "textDocument" => { "uri" => uri },
        "range" => { "start" => { "line" => 2, "character" => span_start }, "end" => { "line" => 2, "character" => span_end } },
        "context" => { "diagnostics" => [redundant_diag] }
      })

      actions = response.fetch("result")
      quickfix = actions.find { |a| a["kind"] == "quickFix" && a["title"] == "Remove redundant as _" }
      assert quickfix, "expected a quickFix action for redundant-ignored-match-binding"
      edit = quickfix.dig("edit", "changes", uri, 0)
      assert_equal "", edit["newText"]
      assert_equal({ "line" => 2, "character" => span_start }, edit.dig("range", "start"))
      assert_equal({ "line" => 2, "character" => span_end }, edit.dig("range", "end"))
    end
  end

  def test_code_action_quickfix_redundant_read_cast
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_quickfix_redundant_read_cast.mt"
      source = <<~MT
        function maybe_handle(handle: ptr[int]?) -> ptr[int]?:
            return handle

        function main(handle: ptr[int]?) -> int:
            let value_ptr = maybe_handle(handle)
            if value_ptr == null:
                fatal("missing")
            unsafe:
                return read(ptr[int]<-value_ptr)
      MT
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      redundant_diag = {
        "source" => "milk-tea",
        "code" => "redundant-read-cast",
        "range" => { "start" => { "line" => 8, "character" => 20 }, "end" => { "line" => 8, "character" => 39 } },
        "message" => "cast to ptr[int] is redundant here; use read(value_ptr) directly"
      }

      response = client.send_request("textDocument/codeAction", {
        "textDocument" => { "uri" => uri },
        "range" => { "start" => { "line" => 8, "character" => 20 }, "end" => { "line" => 8, "character" => 39 } },
        "context" => { "diagnostics" => [redundant_diag] }
      })

      actions = response.fetch("result")
      quickfix = actions.find { |a| a["kind"] == "quickFix" && a["title"] == "Remove redundant read cast" }
      assert quickfix, "expected a quickFix action for redundant-read-cast"
      edit = quickfix.dig("edit", "changes", uri, 0)
      assert_equal "value_ptr", edit["newText"]
    end
  end

  def test_code_action_quickfix_redundant_read_release_temp
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_quickfix_redundant_read_release_temp.mt"
      source = <<~MT
        struct Box:
            value: int

        extending Box:
            mutable function release() -> void:
                pass

        function main(box_ptr: ptr[Box]) -> void:
            unsafe:
                var owned = read(box_ptr)
                owned.release()
      MT
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      redundant_diag = {
        "source" => "milk-tea",
        "code" => "redundant-read-release-temp",
        "range" => { "start" => { "line" => 9, "character" => 12 }, "end" => { "line" => 9, "character" => 17 } },
        "message" => "temporary 'owned' only stores read(...) to call release(); use read(...).release() directly"
      }

      response = client.send_request("textDocument/codeAction", {
        "textDocument" => { "uri" => uri },
        "range" => { "start" => { "line" => 9, "character" => 12 }, "end" => { "line" => 9, "character" => 17 } },
        "context" => { "diagnostics" => [redundant_diag] }
      })

      actions = response.fetch("result")
      quickfix = actions.find { |a| a["kind"] == "quickFix" && a["title"] == "Inline read(...).release()" }
      assert quickfix, "expected a quickFix action for redundant-read-release-temp"
      edit = quickfix.dig("edit", "changes", uri, 0)
      assert_equal "        read(box_ptr).release()\n", edit["newText"]
    end
  end

  def test_code_action_quickfix_prefer_let_else
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_quickfix_prefer_let_else.mt"
      source = <<~MT
        function maybe_handle(handle: ptr[int]?) -> ptr[int]?:
            return handle

        function main(handle: ptr[int]?) -> int:
            let value_ptr = maybe_handle(handle)
            if value_ptr == null:
                return 0
            unsafe:
                return read(value_ptr)
      MT
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      prefer_diag = {
        "source" => "milk-tea",
        "code" => "prefer-let-else",
        "range" => { "start" => { "line" => 5, "character" => 4 }, "end" => { "line" => 5, "character" => 24 } },
        "message" => "nullable guard for 'value_ptr' can use let ... else"
      }

      response = client.send_request("textDocument/codeAction", {
        "textDocument" => { "uri" => uri },
        "range" => { "start" => { "line" => 5, "character" => 4 }, "end" => { "line" => 5, "character" => 24 } },
        "context" => { "diagnostics" => [prefer_diag] }
      })

      actions = response.fetch("result")
      quickfix = actions.find { |a| a["kind"] == "quickFix" && a["title"] == "Rewrite as let-else" }
      assert quickfix, "expected a quickFix action for prefer-let-else"
      edit = quickfix.dig("edit", "changes", uri, 0)
      assert_equal "    let value_ptr = maybe_handle(handle) else:\n", edit["newText"]
    end
  end

  def test_code_action_quickfix_prefer_var_else
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_quickfix_prefer_var_else.mt"
      source = <<~MT
        function maybe_handle(handle: ptr[int]?) -> ptr[int]?:
            return handle

        function main(handle: ptr[int]?) -> int:
            var value_ptr = maybe_handle(handle)
            if value_ptr == null:
                return 0
            unsafe:
                return read(value_ptr)
      MT
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      prefer_diag = {
        "source" => "milk-tea",
        "code" => "prefer-var-else",
        "range" => { "start" => { "line" => 5, "character" => 4 }, "end" => { "line" => 5, "character" => 24 } },
        "message" => "nullable guard for 'value_ptr' can use var ... else"
      }

      response = client.send_request("textDocument/codeAction", {
        "textDocument" => { "uri" => uri },
        "range" => { "start" => { "line" => 5, "character" => 4 }, "end" => { "line" => 5, "character" => 24 } },
        "context" => { "diagnostics" => [prefer_diag] }
      })

      actions = response.fetch("result")
      quickfix = actions.find { |a| a["kind"] == "quickFix" && a["title"] == "Rewrite as var-else" }
      assert quickfix, "expected a quickFix action for prefer-var-else"
      edit = quickfix.dig("edit", "changes", uri, 0)
      assert_equal "    var value_ptr = maybe_handle(handle) else:\n", edit["newText"]
    end
  end

  def test_code_action_quickfix_redundant_bool_compare
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_quickfix_redundant_bool_compare.mt"
      source = <<~MT
        function main(flag: bool) -> int:
            if flag != true:
                return 1
            return 0
      MT
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      expression_start = source.lines[1].index("flag != true")
      expression_end = expression_start + "flag != true".length

      redundant_diag = {
        "source" => "milk-tea",
        "code" => "redundant-bool-compare",
        "range" => { "start" => { "line" => 1, "character" => expression_start }, "end" => { "line" => 1, "character" => expression_end } },
        "message" => "boolean comparison against literal is redundant; invert the expression with 'not'"
      }

      response = client.send_request("textDocument/codeAction", {
        "textDocument" => { "uri" => uri },
        "range" => { "start" => { "line" => 1, "character" => expression_start }, "end" => { "line" => 1, "character" => expression_end } },
        "context" => { "diagnostics" => [redundant_diag] }
      })

      actions = response.fetch("result")
      quickfix = actions.find { |a| a["kind"] == "quickFix" && a["title"] == "Simplify boolean comparison" }
      assert quickfix, "expected a quickFix action for redundant-bool-compare"
      edit = quickfix.dig("edit", "changes", uri, 0)
      assert_equal "not flag", edit["newText"]
      assert_equal({ "line" => 1, "character" => expression_start }, edit.dig("range", "start"))
      assert_equal({ "line" => 1, "character" => expression_end }, edit.dig("range", "end"))
    end
  end

  def test_initialize_advertises_quickfix_code_action_kind
    with_server do |client|
      response = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      kinds = response.dig("result", "capabilities", "codeActionProvider", "codeActionKinds")
      assert_includes kinds, "quickFix"
      assert_includes kinds, "source.fixAll"
    end
  end

  private

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

  def with_server
    stdin_read, stdin_write = IO.pipe
    stdout_read, stdout_write = IO.pipe

    pid = spawn(
      'bundle exec ruby -Ilib -e "require \'milk_tea\'; MilkTea::LSP::Server.new.run"',
      in: stdin_read,
      out: stdout_write,
      err: File::NULL,
      chdir: File.expand_path("../../..", __dir__)
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
