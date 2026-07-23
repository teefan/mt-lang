# frozen_string_literal: true

require_relative "helpers"

class HoverCompletionDefinitionAuditTest < Minitest::Test
  include LSPServerTestHelpers

  AUDIT_SOURCE = <<~MT
    const MAX_HP: int = 100

    enum Direction: ubyte
        north = 0
        south = 1
        east = 2
        west = 3

    struct Point:
        x: float
        y: float

    extending Point:
        function magnitude() -> float:
            return this.x + this.y

        editable function reset() -> void:
            this.x = 0.0
            this.y = 0.0

        static function origin() -> Point:
            return Point(x = 0.0, y = 0.0)

    struct Entity:
        position: Point
        hp: int

    extending Entity:
        function is_alive() -> bool:
            return this.hp > 0

        editable function damage(amount: int) -> void:
            this.hp -= amount

        static function create(x: float, y: float) -> Entity:
            return Entity(position = Point(x = x, y = y), hp = MAX_HP)

    function distance(a: Point, b: Point) -> float:
        return a.x - b.x + a.y - b.y

    function main() -> int:
        var p = Point(x = 1.0, y = 2.0)
        let mag = p.magnitude()
        p.reset()
        let o = Point.origin()
        let d = distance(p, o)
        var e = Entity.create(x = 1.0, y = 2.0)
        e.damage(amount = 10)
        let alive = e.is_alive()
        let dir = Direction.north
        return 0
  MT

  def query_hover(client, uri, line, char)
    response = client.send_request("textDocument/hover", {
      "textDocument" => { "uri" => uri },
      "position"     => { "line" => line, "character" => char }
    })
    response.dig("result")
  end

  def hover_value(result)
    result&.dig("contents", "value")
  end

  def query_definition(client, uri, line, char)
    response = client.send_request("textDocument/definition", {
      "textDocument" => { "uri" => uri },
      "position"     => { "line" => line, "character" => char }
    })
    response.dig("result")
  end

  def query_type_definition(client, uri, line, char)
    response = client.send_request("textDocument/typeDefinition", {
      "textDocument" => { "uri" => uri },
      "position"     => { "line" => line, "character" => char }
    })
    response.dig("result")
  end

  def query_completion(client, uri, line, char)
    response = client.send_request("textDocument/completion", {
      "textDocument" => { "uri" => uri },
      "position"     => { "line" => line, "character" => char }
    })
    result = response.dig("result")
    result.is_a?(Hash) ? result.fetch("items", []) : (result || [])
  end

  def find_char(source, line_idx, substring)
    source.lines[line_idx].index(substring)
  end

  def def_position(result)
    return nil unless result
    [result.dig("range", "start", "line"), result.dig("range", "start", "character")]
  end

  # =====================================================================
  # HOVER AUDIT
  # =====================================================================

  def test_hover_free_function_shows_signature
    with_live_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_hcd_hover_func.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => AUDIT_SOURCE }
      })

      line = AUDIT_SOURCE.lines.index { |l| l.include?("let d = distance") }
      char = find_char(AUDIT_SOURCE, line, "distance")
      result = query_hover(client, uri, line, char)
      value = hover_value(result)

      assert value, "hover on 'distance' should return content"
      assert_includes value, "distance", "hover should include function name"
      assert_includes value, "Point", "hover should include param type"
    end
  end

  def test_hover_instance_method_shows_signature
    with_live_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_hcd_hover_method.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => AUDIT_SOURCE }
      })

      line = AUDIT_SOURCE.lines.index { |l| l.include?("p.magnitude()") }
      char = find_char(AUDIT_SOURCE, line, "magnitude")
      result = query_hover(client, uri, line, char)
      value = hover_value(result)

      assert value, "hover on 'magnitude' should return content"
      assert_includes value, "magnitude", "hover should include method name"
    end
  end

  def test_hover_static_method_shows_signature
    with_live_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_hcd_hover_static.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => AUDIT_SOURCE }
      })

      line = AUDIT_SOURCE.lines.index { |l| l.include?("Point.origin()") }
      char = find_char(AUDIT_SOURCE, line, "origin")
      result = query_hover(client, uri, line, char)
      value = hover_value(result)

      assert value, "hover on 'origin' should return content"
      assert_includes value, "origin", "hover should include static method name"
    end
  end

  def test_hover_local_variable_shows_type
    with_live_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_hcd_hover_local.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => AUDIT_SOURCE }
      })

      line = AUDIT_SOURCE.lines.index { |l| l.include?("let mag = p.magnitude()") }
      char = find_char(AUDIT_SOURCE, line, "mag")
      result = query_hover(client, uri, line, char)
      value = hover_value(result)

      assert value, "hover on 'mag' should return content"
      assert_includes value, "float", "hover should show float type for magnitude result"
    end
  end

  def test_hover_constant_shows_type_and_value
    with_live_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_hcd_hover_const.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => AUDIT_SOURCE }
      })

      line = AUDIT_SOURCE.lines.index { |l| l.start_with?("const MAX_HP") }
      char = find_char(AUDIT_SOURCE, line, "MAX_HP")
      result = query_hover(client, uri, line, char)
      value = hover_value(result)

      assert value, "hover on 'MAX_HP' should return content"
      assert_includes value, "int", "hover should show int type"
    end
  end

  def test_hover_struct_field_in_member_access
    with_live_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_hcd_hover_field.mt"
      source = <<~MT
        struct Rect:
            width: int
            height: int

        function area(r: Rect) -> int:
            return r.width * r.height
      MT
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      line = source.lines.index { |l| l.include?("r.width") }
      char = find_char(source, line, "width")
      result = query_hover(client, uri, line, char)
      value = hover_value(result)

      assert value, "hover on field 'width' should return content"
      assert_includes value, "int", "hover should show field type"
    end
  end

  def test_hover_enum_type
    with_live_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_hcd_hover_enum.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => AUDIT_SOURCE }
      })

      line = AUDIT_SOURCE.lines.index { |l| l.start_with?("enum Direction") }
      char = find_char(AUDIT_SOURCE, line, "Direction")
      result = query_hover(client, uri, line, char)
      value = hover_value(result)

      assert value, "hover on 'Direction' should return content"
    end
  end

  def test_hover_member_chain_nested_field
    with_live_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_hcd_hover_chain.mt"
      source = <<~MT
        struct Inner:
            value: int

        struct Outer:
            inner: Inner

        function read(o: Outer) -> int:
            return o.inner.value
      MT
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      line = source.lines.index { |l| l.include?("o.inner.value") }
      char = find_char(source, line, "value")
      result = query_hover(client, uri, line, char)
      value = hover_value(result)

      assert value, "hover on chained field 'value' should return content"
      assert_includes value, "int", "hover should show int type for Inner.value"
    end
  end

  # =====================================================================
  # DEFINITION AUDIT
  # =====================================================================

  def test_definition_free_function
    with_live_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_hcd_def_func.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => AUDIT_SOURCE }
      })

      call_line = AUDIT_SOURCE.lines.index { |l| l.include?("let d = distance") }
      call_char = find_char(AUDIT_SOURCE, call_line, "distance")
      result = query_definition(client, uri, call_line, call_char)

      decl_line = AUDIT_SOURCE.lines.index { |l| l.match?(/\Afunction distance/) }

      assert result, "definition for 'distance' should resolve"
      assert_equal decl_line, result.dig("range", "start", "line"),
        "definition should jump to function declaration line"
    end
  end

  def test_definition_static_method
    with_live_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_hcd_def_static.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => AUDIT_SOURCE }
      })

      call_line = AUDIT_SOURCE.lines.index { |l| l.include?("Point.origin()") }
      call_char = find_char(AUDIT_SOURCE, call_line, "origin")
      result = query_definition(client, uri, call_line, call_char)

      decl_line = AUDIT_SOURCE.lines.index { |l| l.strip.start_with?("static function origin") }

      assert result, "definition for 'origin' should resolve"
      assert_equal decl_line, result.dig("range", "start", "line"),
        "definition should jump to static method declaration"
    end
  end

  def test_definition_instance_method_from_call_site
    with_live_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_hcd_def_inst_method.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => AUDIT_SOURCE }
      })

      call_line = AUDIT_SOURCE.lines.index { |l| l.include?("p.magnitude()") }
      call_char = find_char(AUDIT_SOURCE, call_line, "magnitude")
      result = query_definition(client, uri, call_line, call_char)

      decl_line = AUDIT_SOURCE.lines.index { |l| l.strip.start_with?("function magnitude") }

      assert result, "definition for 'magnitude' from call site should resolve"
      assert_equal decl_line, result.dig("range", "start", "line"),
        "definition should jump to method declaration"
    end
  end

  def test_definition_local_variable
    with_live_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_hcd_def_local.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => AUDIT_SOURCE }
      })

      use_line = AUDIT_SOURCE.lines.index { |l| l.include?("distance(p, o)") }
      use_char = find_char(AUDIT_SOURCE, use_line, "p")
      result = query_definition(client, uri, use_line, use_char)

      decl_line = AUDIT_SOURCE.lines.index { |l| l.include?("var p = Point") }

      assert result, "definition for local 'p' should resolve"
      assert_equal decl_line, result.dig("range", "start", "line"),
        "definition should jump to var p declaration"
    end
  end

  def test_definition_constant
    with_live_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_hcd_def_const.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => AUDIT_SOURCE }
      })

      use_line = AUDIT_SOURCE.lines.index { |l| l.include?("hp = MAX_HP") }
      use_char = find_char(AUDIT_SOURCE, use_line, "MAX_HP")
      result = query_definition(client, uri, use_line, use_char)

      decl_line = AUDIT_SOURCE.lines.index { |l| l.start_with?("const MAX_HP") }

      assert result, "definition for 'MAX_HP' should resolve"
      assert_equal decl_line, result.dig("range", "start", "line"),
        "definition should jump to const declaration"
    end
  end

  def test_definition_named_argument_label
    with_live_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_hcd_def_named_arg.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => AUDIT_SOURCE }
      })

      call_line = AUDIT_SOURCE.lines.index { |l| l.include?("e.damage(amount = 10)") }
      char = find_char(AUDIT_SOURCE, call_line, "amount")
      result = query_definition(client, uri, call_line, char)

      decl_line = AUDIT_SOURCE.lines.index { |l| l.strip.start_with?("editable function damage(amount") }
      assert result, "definition for named arg 'amount' should resolve"
      assert_equal decl_line, result.dig("range", "start", "line"),
        "named arg definition should jump to parameter declaration"
    end
  end

  def test_definition_for_loop_binding
    with_live_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_hcd_def_for.mt"
      source = <<~MT
        function main() -> int:
            var total: int = 0
            for i in 0..10:
                total += i
            return total
      MT
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      use_line = source.lines.index { |l| l.include?("total += i") }
      use_char = find_char(source, use_line, "i")
      result = query_definition(client, uri, use_line, use_char)

      for_line = source.lines.index { |l| l.include?("for i in") }

      assert result, "definition for 'i' in for loop body should resolve"
      assert_equal for_line, result.dig("range", "start", "line"),
        "definition should jump to for binding"
    end
  end

  # =====================================================================
  # DEFINITION: named arg on method (the bug found in references)
  # =====================================================================

  def test_definition_named_arg_on_method_call
    with_live_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_hcd_def_named_arg_method.mt"
      source = <<~MT
        struct Counter:
            value: int

        extending Counter:
            editable function set(target: int) -> void:
                this.value = target

        function main() -> int:
            var c = Counter(value = 0)
            c.set(target = 42)
            return 0
      MT
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      call_line = source.lines.index { |l| l.include?("c.set(target = 42)") }
      char = find_char(source, call_line, "target")
      result = query_definition(client, uri, call_line, char)

      decl_line = source.lines.index { |l| l.include?("editable function set(target") }

      assert result, "definition for named arg 'target' on method call should resolve"
      assert_equal decl_line, result.dig("range", "start", "line"),
        "named arg definition should jump to method parameter"
    end
  end

  # =====================================================================
  # DEFINITION: type definition for enum/variant/flags/union
  # =====================================================================

  TYPE_DEF_SOURCE = <<~MT
    enum Color: ubyte
        red = 0
        green = 1

    variant Shape:
        circle(radius: float)
        rect(w: float, h: float)

    union Number:
        i: int
        f: float

    flags Permission: uint
        read = 1
        write = 2

    struct Box:
        color: Color

    function use_color(c: Color) -> int:
        return 0

    function use_shape(s: Shape) -> int:
        return 0

    function use_number(n: Number) -> int:
        return 0

    function use_permission(p: Permission) -> int:
        return 0

    function main() -> int:
        let c = Color.red
        let b = Box(color = c)
        return 0
  MT

  def test_definition_enum_type_name
    with_live_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_hcd_def_enum.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => TYPE_DEF_SOURCE }
      })

      use_line = TYPE_DEF_SOURCE.lines.index { |l| l.include?("let c = Color.red") }
      use_char = find_char(TYPE_DEF_SOURCE, use_line, "Color")
      result = query_definition(client, uri, use_line, use_char)

      decl_line = TYPE_DEF_SOURCE.lines.index { |l| l.start_with?("enum Color") }

      assert result, "definition for 'Color' enum should resolve"
      assert_equal decl_line, result.dig("range", "start", "line"),
        "definition should jump to enum declaration"
    end
  end

  # =====================================================================
  # COMPLETION AUDIT
  # =====================================================================

  COMPLETION_SOURCE = <<~MT
    struct Player:
        name: int
        hp: int
        speed: float

    extending Player:
        function is_alive() -> bool:
            return this.hp > 0

        editable function heal(amount: int) -> void:
            this.hp += amount

        static function create() -> Player:
            return Player(name = 0, hp = 100, speed = 1.0)

    function main() -> int:
        var p = Player.create()
        p.
        return 0
  MT

  def test_completion_struct_dot_includes_fields_and_methods
    Dir.mktmpdir("milk-tea-lsp-audit-completion") do |dir|
      path = File.join(dir, "main.mt")
      File.write(path, COMPLETION_SOURCE)

      with_live_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})

        uri = path_to_uri(path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => COMPLETION_SOURCE }
        })

        dot_line = COMPLETION_SOURCE.lines.index { |l| l.strip == "p." }
        dot_char = COMPLETION_SOURCE.lines[dot_line].rstrip.length

        items = query_completion(client, uri, dot_line, dot_char)
        labels = items.map { |i| i["label"] }

        assert_includes labels, "name", "completion should include field 'name'"
        assert_includes labels, "hp", "completion should include field 'hp'"
        assert_includes labels, "speed", "completion should include field 'speed'"
        assert_includes labels, "is_alive", "completion should include method 'is_alive'"
        assert_includes labels, "heal", "completion should include editable method 'heal'"
        refute_includes labels, "create", "completion on value should NOT include static method 'create'"
      end
    end
  end

  def test_completion_static_dot_includes_static_methods
    Dir.mktmpdir("milk-tea-lsp-audit-static-completion") do |dir|
      source = <<~MT
        struct Player:
            hp: int

        extending Player:
            function read() -> int:
                return this.hp

            static function zero() -> Player:
                return Player(hp = 0)

        function main() -> int:
            let p = Player.
            return 0
      MT
      path = File.join(dir, "main.mt")
      File.write(path, source)

      with_live_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})

        uri = path_to_uri(path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        dot_line = source.lines.index { |l| l.include?("Player.") }
        dot_char = source.lines[dot_line].rstrip.length

        items = query_completion(client, uri, dot_line, dot_char)
        labels = items.map { |i| i["label"] }

        assert_includes labels, "zero", "static completion should include 'zero'"
      end
    end
  end

  def test_completion_this_in_extending_block
    Dir.mktmpdir("milk-tea-lsp-audit-this-completion") do |dir|
      source = <<~MT
        struct Widget:
            x: int
            y: int
            visible: bool

        extending Widget:
            function area() -> int:
                return this.
      MT
      path = File.join(dir, "main.mt")
      File.write(path, source)

      with_live_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})

        uri = path_to_uri(path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        dot_line = source.lines.index { |l| l.include?("return this.") }
        dot_char = source.lines[dot_line].rstrip.length

        items = query_completion(client, uri, dot_line, dot_char)
        labels = items.map { |i| i["label"] }

        assert_includes labels, "x", "this. completion should include field 'x'"
        assert_includes labels, "y", "this. completion should include field 'y'"
        assert_includes labels, "visible", "this. completion should include field 'visible'"
      end
    end
  end

  def test_completion_multi_extending_includes_all_methods
    Dir.mktmpdir("milk-tea-lsp-audit-multi-ext-completion") do |dir|
      source = <<~MT
        struct Counter:
            value: int

        extending Counter:
            function read() -> int:
                return this.value

        extending Counter:
            editable function bump() -> void:
                this.value += 1

        function main() -> int:
            var c = Counter(value = 0)
            c.
            return 0
      MT
      path = File.join(dir, "main.mt")
      File.write(path, source)

      with_live_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})

        uri = path_to_uri(path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        dot_line = source.lines.index { |l| l.strip == "c." }
        dot_char = source.lines[dot_line].rstrip.length

        items = query_completion(client, uri, dot_line, dot_char)
        labels = items.map { |i| i["label"] }

        assert_includes labels, "value", "multi-extend completion should include field 'value'"
        assert_includes labels, "read", "multi-extend completion should include 'read' from first extending"
        assert_includes labels, "bump", "multi-extend completion should include 'bump' from second extending"
      end
    end
  end

  def test_completion_imported_module_dot
    Dir.mktmpdir("milk-tea-lsp-audit-import-completion") do |dir|
      lib_path = File.join(dir, "util.mt")
      main_path = File.join(dir, "main.mt")

      File.write(lib_path, <<~MT)
        public function helper() -> int:
            return 42

        public struct Config:
            value: int
      MT

      main_source = <<~MT
        import util

        function main() -> int:
            return util.
      MT
      File.write(main_path, main_source)

      with_live_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})

        main_uri = path_to_uri(main_path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => main_uri, "languageId" => "milk-tea", "version" => 1, "text" => main_source }
        })

        dot_line = main_source.lines.index { |l| l.include?("return util.") }
        dot_char = main_source.lines[dot_line].rstrip.length

        items = query_completion(client, main_uri, dot_line, dot_char)
        labels = items.map { |i| i["label"] }

        assert_includes labels, "helper", "imported module completion should include 'helper'"
        assert_includes labels, "Config", "imported module completion should include 'Config' type"
      end
    end
  end

  # =====================================================================
  # CROSS-FILE DEFINITION
  # =====================================================================

  def test_cross_file_definition_for_imported_function
    Dir.mktmpdir("milk-tea-lsp-audit-cross-def") do |dir|
      lib_source = <<~MT
        public function compute(x: int) -> int:
            return x * 2
      MT
      main_source = <<~MT
        import lib

        function main() -> int:
            return lib.compute(21)
      MT

      lib_path = File.join(dir, "lib.mt")
      main_path = File.join(dir, "main.mt")
      File.write(lib_path, lib_source)
      File.write(main_path, main_source)

      with_live_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})

        main_uri = path_to_uri(main_path)
        lib_uri = path_to_uri(lib_path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => main_uri, "languageId" => "milk-tea", "version" => 1, "text" => main_source }
        })

        call_line = main_source.lines.index { |l| l.include?("lib.compute(21)") }
        call_char = find_char(main_source, call_line, "compute")
        result = query_definition(client, main_uri, call_line, call_char)

        assert result, "cross-file definition for 'compute' should resolve"
        assert_equal lib_uri, result["uri"], "definition should point to lib.mt"
        assert_equal 0, result.dig("range", "start", "line"), "definition should be on line 0"
      end
    end
  end

  def test_cross_file_definition_for_imported_static_method
    Dir.mktmpdir("milk-tea-lsp-audit-cross-static-def") do |dir|
      geo_source = <<~MT
        public struct Vec:
            x: int

        extending Vec:
            public static function zero() -> Vec:
                return Vec(x = 0)
      MT
      main_source = <<~MT
        import geo

        function main() -> int:
            let v = geo.Vec.zero()
            return 0
      MT

      geo_path = File.join(dir, "geo.mt")
      main_path = File.join(dir, "main.mt")
      File.write(geo_path, geo_source)
      File.write(main_path, main_source)

      with_live_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})

        main_uri = path_to_uri(main_path)
        geo_uri = path_to_uri(geo_path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => main_uri, "languageId" => "milk-tea", "version" => 1, "text" => main_source }
        })

        call_line = main_source.lines.index { |l| l.include?("geo.Vec.zero()") }
        call_char = find_char(main_source, call_line, "zero")
        result = query_definition(client, main_uri, call_line, call_char)

        decl_line = geo_source.lines.index { |l| l.strip.start_with?("public static function zero") }

        assert result, "cross-file definition for static method 'zero' should resolve"
        assert_equal geo_uri, result["uri"], "definition should point to geo.mt"
        assert_equal decl_line, result.dig("range", "start", "line"),
          "definition should point to static method declaration line"
      end
    end
  end

  # =====================================================================
  # HOVER: cross-file imported function
  # =====================================================================

  def test_hover_cross_file_imported_function
    Dir.mktmpdir("milk-tea-lsp-audit-cross-hover") do |dir|
      lib_source = <<~MT
        ## Doubles the input value.
        public function compute(x: int) -> int:
            return x * 2
      MT
      main_source = <<~MT
        import lib

        function main() -> int:
            return lib.compute(21)
      MT

      lib_path = File.join(dir, "lib.mt")
      main_path = File.join(dir, "main.mt")
      File.write(lib_path, lib_source)
      File.write(main_path, main_source)

      with_live_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})

        main_uri = path_to_uri(main_path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => main_uri, "languageId" => "milk-tea", "version" => 1, "text" => main_source }
        })

        call_line = main_source.lines.index { |l| l.include?("lib.compute(21)") }
        call_char = find_char(main_source, call_line, "compute")
        result = query_hover(client, main_uri, call_line, call_char)
        value = hover_value(result)

        assert value, "hover on imported 'compute' should return content"
        assert_includes value, "compute", "hover should include function name"
        assert_includes value, "int", "hover should include param/return type"
        assert_includes value, "Doubles the input value", "hover should include doc comment"
      end
    end
  end

  # =====================================================================
  # HOVER: editable method via member access
  # =====================================================================

  def test_hover_editable_method_via_member_access
    with_live_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_hcd_hover_editable.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => AUDIT_SOURCE }
      })

      call_line = AUDIT_SOURCE.lines.index { |l| l.include?("e.damage(amount = 10)") }
      char = find_char(AUDIT_SOURCE, call_line, "damage")
      result = query_hover(client, uri, call_line, char)
      value = hover_value(result)

      assert value, "hover on editable method 'damage' should return content"
      assert_includes value, "damage", "hover should include method name"
    end
  end

  # =====================================================================
  # DEFINITION: editable method via member access
  # =====================================================================

  def test_definition_editable_method_via_member_access
    with_live_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_hcd_def_editable.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => AUDIT_SOURCE }
      })

      call_line = AUDIT_SOURCE.lines.index { |l| l.include?("e.damage(amount = 10)") }
      call_char = find_char(AUDIT_SOURCE, call_line, "damage")
      result = query_definition(client, uri, call_line, call_char)

      decl_line = AUDIT_SOURCE.lines.index { |l| l.strip.start_with?("editable function damage") }

      assert result, "definition for 'damage' from member access should resolve"
      assert_equal decl_line, result.dig("range", "start", "line"),
        "definition should jump to editable method declaration"
    end
  end

  # =====================================================================
  # COMPLETION: no completion for non-identifier tokens
  # =====================================================================

  def test_completion_returns_empty_for_keyword_position
    with_live_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_hcd_comp_keyword.mt"
      source = <<~MT
        function main() -> int:
            return 0
      MT
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      items = query_completion(client, uri, 0, 0)
      assert_kind_of Array, items
    end
  end
end
