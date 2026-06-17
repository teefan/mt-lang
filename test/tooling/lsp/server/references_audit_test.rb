# frozen_string_literal: true

require_relative "helpers"

class ReferencesAuditTest < Minitest::Test
  include LSPServerTestHelpers

  SINGLE_FILE_SOURCE = <<~MT
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

    function distance(a: Point, b: Point) -> float:
        return a.x - b.x + a.y - b.y

    function helper() -> float:
        return 0.0

    function main() -> int:
        var p = Point(x = 1.0, y = 2.0)
        let mag = p.magnitude()
        p.reset()
        let o = Point.origin()
        let d = distance(p, o)
        let h = helper()
        if true:
            let p = 42
            let x = p
        return 0
  MT

  def query_references(client, uri, line, char, include_declaration: true)
    response = client.send_request("textDocument/references", {
      "textDocument" => { "uri" => uri },
      "position"     => { "line" => line, "character" => char },
      "context"      => { "includeDeclaration" => include_declaration }
    })
    response.fetch("result")
  end

  def resolve_code_lens(client, uri, name, line, column)
    response = client.send_request("codeLens/resolve", {
      "range" => {
        "start" => { "line" => line - 1, "character" => 0 },
        "end"   => { "line" => line - 1, "character" => 0 },
      },
      "data" => {
        "uri"    => uri,
        "name"   => name,
        "line"   => line,
        "column" => column,
      },
    })
    response.fetch("result")
  end

  def ref_positions(locations)
    locations.map do |loc|
      [loc["uri"] || loc[:uri],
       (loc.dig("range", "start", "line") || loc.dig(:range, :start, :line)),
       (loc.dig("range", "start", "character") || loc.dig(:range, :start, :character))]
    end
  end

  def ref_lines(locations, uri = nil)
    positions = ref_positions(locations)
    positions = positions.select { |u, _, _| u == uri } if uri
    positions.map { |_, l, _| l }
  end

  def code_lens_count(result)
    title = result.dig("command", "title")
    return nil unless title

    match = title.match(/^(\d+) reference/)
    match ? match[1].to_i : nil
  end

  def find_char(source, line_idx, substring)
    source.lines[line_idx].index(substring)
  end

  # =====================================================================
  # Single-file: free function references
  # =====================================================================

  def test_single_file_free_function_distance
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_refs_audit_single.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SINGLE_FILE_SOURCE }
      })

      decl_line = SINGLE_FILE_SOURCE.lines.index { |l| l.match?(/\Afunction distance/) }
      decl_char = find_char(SINGLE_FILE_SOURCE, decl_line, "distance")

      refs = query_references(client, uri, decl_line, decl_char)
      lines = ref_lines(refs)

      call_line = SINGLE_FILE_SOURCE.lines.index { |l| l.include?("let d = distance") }

      assert_includes lines, decl_line, "should include distance declaration"
      assert_includes lines, call_line, "should include distance call site"
      assert_equal 2, refs.length, "distance: expected 2 refs (decl + 1 call), got #{refs.length}: #{ref_positions(refs)}"
    end
  end

  def test_single_file_free_function_helper
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_refs_audit_helper.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SINGLE_FILE_SOURCE }
      })

      decl_line = SINGLE_FILE_SOURCE.lines.index { |l| l.match?(/\Afunction helper/) }
      decl_char = find_char(SINGLE_FILE_SOURCE, decl_line, "helper")

      refs = query_references(client, uri, decl_line, decl_char)

      call_line = SINGLE_FILE_SOURCE.lines.index { |l| l.include?("let h = helper()") }
      lines = ref_lines(refs)

      assert_includes lines, decl_line, "should include helper declaration"
      assert_includes lines, call_line, "should include helper call site"
      assert_equal 2, refs.length, "helper: expected 2 refs (decl + 1 call), got #{refs.length}: #{ref_positions(refs)}"
    end
  end

  # =====================================================================
  # Single-file: instance method references
  # =====================================================================

  def test_single_file_instance_method_magnitude
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_refs_audit_magnitude.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SINGLE_FILE_SOURCE }
      })

      decl_line = SINGLE_FILE_SOURCE.lines.index { |l| l.strip.start_with?("function magnitude") }
      decl_char = find_char(SINGLE_FILE_SOURCE, decl_line, "magnitude")

      refs = query_references(client, uri, decl_line, decl_char)

      call_line = SINGLE_FILE_SOURCE.lines.index { |l| l.include?("p.magnitude()") }
      lines = ref_lines(refs)

      assert_includes lines, decl_line, "should include magnitude declaration"
      assert_includes lines, call_line, "should include magnitude call via p.magnitude()"
      assert_equal 2, refs.length, "magnitude: expected 2 refs (decl + 1 call), got #{refs.length}: #{ref_positions(refs)}"
    end
  end

  def test_single_file_editable_method_reset
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_refs_audit_reset.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SINGLE_FILE_SOURCE }
      })

      decl_line = SINGLE_FILE_SOURCE.lines.index { |l| l.strip.start_with?("editable function reset") }
      decl_char = find_char(SINGLE_FILE_SOURCE, decl_line, "reset")

      refs = query_references(client, uri, decl_line, decl_char)

      call_line = SINGLE_FILE_SOURCE.lines.index { |l| l.include?("p.reset()") }
      lines = ref_lines(refs)

      assert_includes lines, decl_line, "should include reset declaration"
      assert_includes lines, call_line, "should include reset call via p.reset()"
      assert_equal 2, refs.length, "reset: expected 2 refs (decl + 1 call), got #{refs.length}: #{ref_positions(refs)}"
    end
  end

  # =====================================================================
  # Single-file: static method references
  # =====================================================================

  def test_single_file_static_method_origin
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_refs_audit_origin.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SINGLE_FILE_SOURCE }
      })

      decl_line = SINGLE_FILE_SOURCE.lines.index { |l| l.strip.start_with?("static function origin") }
      decl_char = find_char(SINGLE_FILE_SOURCE, decl_line, "origin")

      refs = query_references(client, uri, decl_line, decl_char)

      call_line = SINGLE_FILE_SOURCE.lines.index { |l| l.include?("Point.origin()") }
      lines = ref_lines(refs)

      assert_includes lines, decl_line, "should include origin declaration"
      assert_includes lines, call_line, "should include origin call via Point.origin()"
      assert_equal 2, refs.length, "origin: expected 2 refs (decl + 1 call), got #{refs.length}: #{ref_positions(refs)}"
    end
  end

  # =====================================================================
  # Single-file: local variable scoping
  # =====================================================================

  def test_single_file_local_outer_p
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_refs_audit_outer_p.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SINGLE_FILE_SOURCE }
      })

      decl_line = SINGLE_FILE_SOURCE.lines.index { |l| l.include?("var p = Point") }
      decl_char = find_char(SINGLE_FILE_SOURCE, decl_line, "p")

      refs = query_references(client, uri, decl_line, decl_char)
      lines = ref_lines(refs)

      mag_line = SINGLE_FILE_SOURCE.lines.index { |l| l.include?("p.magnitude()") }
      reset_line = SINGLE_FILE_SOURCE.lines.index { |l| l.include?("p.reset()") }
      dist_line = SINGLE_FILE_SOURCE.lines.index { |l| l.include?("distance(p, o)") }

      assert_includes lines, decl_line, "outer p: should include declaration"
      assert_includes lines, mag_line, "outer p: should include p.magnitude() usage"
      assert_includes lines, reset_line, "outer p: should include p.reset() usage"
      assert_includes lines, dist_line, "outer p: should include distance(p, o) usage"

      shadow_line = SINGLE_FILE_SOURCE.lines.index { |l| l.include?("let p = 42") }
      shadow_use_line = SINGLE_FILE_SOURCE.lines.index { |l| l.include?("let x = p") }
      refute_includes lines, shadow_line, "outer p: should NOT include shadowed let p = 42"
      refute_includes lines, shadow_use_line, "outer p: should NOT include shadowed usage let x = p"

      assert_equal 4, refs.length, "outer p: expected 4 refs (decl + 3 uses), got #{refs.length}: #{ref_positions(refs)}"
    end
  end

  def test_single_file_local_inner_p_shadowed
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_refs_audit_inner_p.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SINGLE_FILE_SOURCE }
      })

      shadow_line = SINGLE_FILE_SOURCE.lines.index { |l| l.include?("let p = 42") }
      shadow_char = find_char(SINGLE_FILE_SOURCE, shadow_line, "p")

      refs = query_references(client, uri, shadow_line, shadow_char)
      lines = ref_lines(refs)

      shadow_use_line = SINGLE_FILE_SOURCE.lines.index { |l| l.include?("let x = p") }

      assert_includes lines, shadow_line, "inner p: should include declaration"
      assert_includes lines, shadow_use_line, "inner p: should include let x = p"

      outer_decl_line = SINGLE_FILE_SOURCE.lines.index { |l| l.include?("var p = Point") }
      refute_includes lines, outer_decl_line, "inner p: should NOT include outer var p"

      assert_equal 2, refs.length, "inner p: expected 2 refs (decl + 1 use), got #{refs.length}: #{ref_positions(refs)}"
    end
  end

  def test_single_file_local_o
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_refs_audit_local_o.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SINGLE_FILE_SOURCE }
      })

      decl_line = SINGLE_FILE_SOURCE.lines.index { |l| l.include?("let o = Point.origin()") }
      decl_char = find_char(SINGLE_FILE_SOURCE, decl_line, "o")

      refs = query_references(client, uri, decl_line, decl_char)
      lines = ref_lines(refs)

      dist_line = SINGLE_FILE_SOURCE.lines.index { |l| l.include?("distance(p, o)") }

      assert_includes lines, decl_line, "local o: should include declaration"
      assert_includes lines, dist_line, "local o: should include distance(p, o) usage"
      assert_equal 2, refs.length, "local o: expected 2 refs, got #{refs.length}: #{ref_positions(refs)}"
    end
  end

  # =====================================================================
  # Single-file: code lens reference counts
  # =====================================================================

  def test_single_file_code_lens_counts
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_refs_audit_codelens.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SINGLE_FILE_SOURCE }
      })

      expected_counts = {
        "distance" => 2,
        "helper"   => 2,
        "main"     => 1,
      }

      expected_counts.each do |func_name, expected|
        line_idx = SINGLE_FILE_SOURCE.lines.index { |l| l.match?(/\Afunction #{Regexp.escape(func_name)}\b/) }
        char = find_char(SINGLE_FILE_SOURCE, line_idx, func_name)
        result = resolve_code_lens(client, uri, func_name, line_idx + 1, char + 1)
        count = code_lens_count(result)
        assert_equal expected, count,
          "code lens for '#{func_name}': expected #{expected} references, got #{count}"
      end
    end
  end

  # =====================================================================
  # Cross-file: multi-module references
  # =====================================================================

  GEO_SOURCE = <<~MT
    public struct Point:
        x: float
        y: float

    extending Point:
        public function magnitude() -> float:
            return this.x + this.y

        public editable function reset() -> void:
            this.x = 0.0
            this.y = 0.0

        public static function origin() -> Point:
            return Point(x = 0.0, y = 0.0)

    public function distance(a: Point, b: Point) -> float:
        return a.x - b.x + a.y - b.y
  MT

  SHAPES_SOURCE = <<~MT
    import geo

    public struct Circle:
        center: geo.Point
        radius: float

    extending Circle:
        public function area() -> float:
            return this.radius * this.radius

        public static function unit() -> Circle:
            return Circle(center = geo.Point.origin(), radius = 1.0)

    public function total_radius(a: Circle, b: Circle) -> float:
        return a.radius + b.radius
  MT

  MAIN_SOURCE = <<~MT
    import geo
    import shapes

    function main() -> int:
        var p = geo.Point(x = 1.0, y = 2.0)
        let mag = p.magnitude()
        p.reset()
        let o = geo.Point.origin()
        let d = geo.distance(p, o)
        let c = shapes.Circle(center = p, radius = 3.0)
        let a = c.area()
        let uc = shapes.Circle.unit()
        let tr = shapes.total_radius(c, uc)
        return 0
  MT

  def setup_cross_file_workspace
    dir = Dir.mktmpdir("milk-tea-lsp-refs-audit")

    geo_path = File.join(dir, "geo.mt")
    shapes_path = File.join(dir, "shapes.mt")
    main_path = File.join(dir, "main.mt")

    File.write(geo_path, GEO_SOURCE)
    File.write(shapes_path, SHAPES_SOURCE)
    File.write(main_path, MAIN_SOURCE)

    {
      dir: dir,
      geo_path: geo_path,
      shapes_path: shapes_path,
      main_path: main_path,
      geo_uri: path_to_uri(geo_path),
      shapes_uri: path_to_uri(shapes_path),
      main_uri: path_to_uri(main_path),
    }
  end

  def open_all_files(client, ws)
    [
      [ws[:geo_uri], GEO_SOURCE],
      [ws[:shapes_uri], SHAPES_SOURCE],
      [ws[:main_uri], MAIN_SOURCE],
    ].each do |uri, source|
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })
    end
  end

  def test_cross_file_static_method_origin_receiver_scoped
    ws = setup_cross_file_workspace
    with_server do |client|
      client.send_request("initialize", { "rootUri" => path_to_uri(ws[:dir]), "capabilities" => {} })
      client.send_notification("initialized", {})
      open_all_files(client, ws)

      decl_line = GEO_SOURCE.lines.index { |l| l.strip.start_with?("public static function origin") }
      decl_char = find_char(GEO_SOURCE, decl_line, "origin")

      refs = query_references(client, ws[:geo_uri], decl_line, decl_char)
      uris_and_lines = refs.map { |r| [r["uri"], r.dig("range", "start", "line")] }

      shapes_call_line = SHAPES_SOURCE.lines.index { |l| l.include?("geo.Point.origin()") }
      main_call_line = MAIN_SOURCE.lines.index { |l| l.include?("geo.Point.origin()") }

      assert_includes uris_and_lines, [ws[:geo_uri], decl_line],
        "cross-file origin: should include declaration in geo.mt"
      assert_includes uris_and_lines, [ws[:shapes_uri], shapes_call_line],
        "cross-file origin: should include call in shapes.mt"
      assert_includes uris_and_lines, [ws[:main_uri], main_call_line],
        "cross-file origin: should include call in main.mt"
      assert_equal 3, refs.length,
        "cross-file origin: expected 3 refs (decl + 2 calls), got #{refs.length}: #{uris_and_lines}"
    end
  ensure
    FileUtils.remove_entry(ws[:dir]) if ws
  end

  def test_cross_file_free_function_distance
    ws = setup_cross_file_workspace
    with_server do |client|
      client.send_request("initialize", { "rootUri" => path_to_uri(ws[:dir]), "capabilities" => {} })
      client.send_notification("initialized", {})
      open_all_files(client, ws)

      decl_line = GEO_SOURCE.lines.index { |l| l.match?(/\Apublic function distance/) }
      decl_char = find_char(GEO_SOURCE, decl_line, "distance")

      refs = query_references(client, ws[:geo_uri], decl_line, decl_char)
      uris_and_lines = refs.map { |r| [r["uri"], r.dig("range", "start", "line")] }

      main_call_line = MAIN_SOURCE.lines.index { |l| l.include?("geo.distance(p, o)") }

      assert_includes uris_and_lines, [ws[:geo_uri], decl_line],
        "cross-file distance: should include declaration in geo.mt"
      assert_includes uris_and_lines, [ws[:main_uri], main_call_line],
        "cross-file distance: should include call in main.mt"
      assert_equal 2, refs.length,
        "cross-file distance: expected 2 refs, got #{refs.length}: #{uris_and_lines}"
    end
  ensure
    FileUtils.remove_entry(ws[:dir]) if ws
  end

  def test_cross_file_instance_method_magnitude
    ws = setup_cross_file_workspace
    with_server do |client|
      client.send_request("initialize", { "rootUri" => path_to_uri(ws[:dir]), "capabilities" => {} })
      client.send_notification("initialized", {})
      open_all_files(client, ws)

      decl_line = GEO_SOURCE.lines.index { |l| l.strip.start_with?("public function magnitude") }
      decl_char = find_char(GEO_SOURCE, decl_line, "magnitude")

      refs = query_references(client, ws[:geo_uri], decl_line, decl_char)
      uris_and_lines = refs.map { |r| [r["uri"], r.dig("range", "start", "line")] }

      main_call_line = MAIN_SOURCE.lines.index { |l| l.include?("p.magnitude()") }

      assert_includes uris_and_lines, [ws[:geo_uri], decl_line],
        "cross-file magnitude: should include declaration in geo.mt"
      assert_includes uris_and_lines, [ws[:main_uri], main_call_line],
        "cross-file magnitude: should include call in main.mt"
      assert_equal 2, refs.length,
        "cross-file magnitude: expected 2 refs, got #{refs.length}: #{uris_and_lines}"
    end
  ensure
    FileUtils.remove_entry(ws[:dir]) if ws
  end

  def test_cross_file_editable_method_reset
    ws = setup_cross_file_workspace
    with_server do |client|
      client.send_request("initialize", { "rootUri" => path_to_uri(ws[:dir]), "capabilities" => {} })
      client.send_notification("initialized", {})
      open_all_files(client, ws)

      decl_line = GEO_SOURCE.lines.index { |l| l.strip.start_with?("public editable function reset") }
      decl_char = find_char(GEO_SOURCE, decl_line, "reset")

      refs = query_references(client, ws[:geo_uri], decl_line, decl_char)
      uris_and_lines = refs.map { |r| [r["uri"], r.dig("range", "start", "line")] }

      main_call_line = MAIN_SOURCE.lines.index { |l| l.include?("p.reset()") }

      assert_includes uris_and_lines, [ws[:geo_uri], decl_line],
        "cross-file reset: should include declaration in geo.mt"
      assert_includes uris_and_lines, [ws[:main_uri], main_call_line],
        "cross-file reset: should include call in main.mt"
      assert_equal 2, refs.length,
        "cross-file reset: expected 2 refs, got #{refs.length}: #{uris_and_lines}"
    end
  ensure
    FileUtils.remove_entry(ws[:dir]) if ws
  end

  def test_cross_file_static_method_unit_on_circle
    ws = setup_cross_file_workspace
    with_server do |client|
      client.send_request("initialize", { "rootUri" => path_to_uri(ws[:dir]), "capabilities" => {} })
      client.send_notification("initialized", {})
      open_all_files(client, ws)

      decl_line = SHAPES_SOURCE.lines.index { |l| l.strip.start_with?("public static function unit") }
      decl_char = find_char(SHAPES_SOURCE, decl_line, "unit")

      refs = query_references(client, ws[:shapes_uri], decl_line, decl_char)
      uris_and_lines = refs.map { |r| [r["uri"], r.dig("range", "start", "line")] }

      main_call_line = MAIN_SOURCE.lines.index { |l| l.include?("shapes.Circle.unit()") }

      assert_includes uris_and_lines, [ws[:shapes_uri], decl_line],
        "cross-file unit: should include declaration in shapes.mt"
      assert_includes uris_and_lines, [ws[:main_uri], main_call_line],
        "cross-file unit: should include call in main.mt"
      assert_equal 2, refs.length,
        "cross-file unit: expected 2 refs, got #{refs.length}: #{uris_and_lines}"
    end
  ensure
    FileUtils.remove_entry(ws[:dir]) if ws
  end

  def test_cross_file_free_function_total_radius
    ws = setup_cross_file_workspace
    with_server do |client|
      client.send_request("initialize", { "rootUri" => path_to_uri(ws[:dir]), "capabilities" => {} })
      client.send_notification("initialized", {})
      open_all_files(client, ws)

      decl_line = SHAPES_SOURCE.lines.index { |l| l.match?(/\Apublic function total_radius/) }
      decl_char = find_char(SHAPES_SOURCE, decl_line, "total_radius")

      refs = query_references(client, ws[:shapes_uri], decl_line, decl_char)
      uris_and_lines = refs.map { |r| [r["uri"], r.dig("range", "start", "line")] }

      main_call_line = MAIN_SOURCE.lines.index { |l| l.include?("shapes.total_radius(c, uc)") }

      assert_includes uris_and_lines, [ws[:shapes_uri], decl_line],
        "cross-file total_radius: should include declaration in shapes.mt"
      assert_includes uris_and_lines, [ws[:main_uri], main_call_line],
        "cross-file total_radius: should include call in main.mt"
      assert_equal 2, refs.length,
        "cross-file total_radius: expected 2 refs, got #{refs.length}: #{uris_and_lines}"
    end
  ensure
    FileUtils.remove_entry(ws[:dir]) if ws
  end

  # =====================================================================
  # Cross-file: no false cross-type static method matching
  # =====================================================================

  def test_cross_file_origin_does_not_match_unrelated_origin
    ws = setup_cross_file_workspace

    unrelated_source = <<~MT
      public struct Color:
          r: int

      extending Color:
          public static function origin() -> Color:
              return Color(r = 0)

      public function use_origin() -> Color:
          return Color.origin()
    MT
    unrelated_path = File.join(ws[:dir], "color.mt")
    File.write(unrelated_path, unrelated_source)
    unrelated_uri = path_to_uri(unrelated_path)

    with_server do |client|
      client.send_request("initialize", { "rootUri" => path_to_uri(ws[:dir]), "capabilities" => {} })
      client.send_notification("initialized", {})
      open_all_files(client, ws)
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => unrelated_uri, "languageId" => "milk-tea", "version" => 1, "text" => unrelated_source }
      })

      geo_decl_line = GEO_SOURCE.lines.index { |l| l.strip.start_with?("public static function origin") }
      geo_decl_char = find_char(GEO_SOURCE, geo_decl_line, "origin")

      refs = query_references(client, ws[:geo_uri], geo_decl_line, geo_decl_char)
      ref_uris = refs.map { |r| r["uri"] }

      refute_includes ref_uris, unrelated_uri,
        "Point.origin() refs should not include Color.origin() from unrelated module"
    end
  ensure
    FileUtils.remove_entry(ws[:dir]) if ws
  end

  # =====================================================================
  # Single-file: excludeDeclaration mode
  # =====================================================================

  def test_single_file_exclude_declaration
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_refs_audit_exclude_decl.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SINGLE_FILE_SOURCE }
      })

      decl_line = SINGLE_FILE_SOURCE.lines.index { |l| l.match?(/\Afunction helper/) }
      decl_char = find_char(SINGLE_FILE_SOURCE, decl_line, "helper")

      refs_with = query_references(client, uri, decl_line, decl_char, include_declaration: true)
      refs_without = query_references(client, uri, decl_line, decl_char, include_declaration: false)

      assert refs_with.length > refs_without.length,
        "exclude-declaration should return fewer refs (with=#{refs_with.length}, without=#{refs_without.length})"
    end
  end

  # =====================================================================
  # Single-file: parameter references scoped inside function body
  # =====================================================================

  PARAM_SCOPE_SOURCE = <<~MT
    function add(value: int, offset: int) -> int:
        return value + offset

    function multiply(value: int, factor: int) -> int:
        return value * factor

    function main() -> int:
        return add(1, 2) + multiply(3, 4)
  MT

  def test_parameter_value_scoped_to_add
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_refs_audit_param_scope.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => PARAM_SCOPE_SOURCE }
      })

      add_line = 0
      add_value_char = find_char(PARAM_SCOPE_SOURCE, add_line, "value")

      refs = query_references(client, uri, add_line, add_value_char)
      lines = ref_lines(refs)

      assert_includes lines, 0, "param 'value' in add: should include declaration"
      assert_includes lines, 1, "param 'value' in add: should include body usage"

      multiply_value_line = 3
      refute_includes lines, multiply_value_line,
        "param 'value' in add: should NOT include 'value' param in multiply()"

      assert_equal 2, refs.length,
        "param 'value' in add: expected 2 refs (decl + 1 body use), got #{refs.length}: #{ref_positions(refs)}"
    end
  end

  # =====================================================================
  # Code lens consistency with references
  # =====================================================================

  def test_code_lens_matches_references_count
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_refs_audit_lens_match.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SINGLE_FILE_SOURCE }
      })

      %w[distance helper main].each do |func_name|
        line_idx = SINGLE_FILE_SOURCE.lines.index { |l| l.match?(/\Afunction #{Regexp.escape(func_name)}\b/) }
        char = find_char(SINGLE_FILE_SOURCE, line_idx, func_name)

        refs = query_references(client, uri, line_idx, char)
        lens_result = resolve_code_lens(client, uri, func_name, line_idx + 1, char + 1)
        lens_count = code_lens_count(lens_result)

        assert_equal refs.length, lens_count,
          "code lens for '#{func_name}' (#{lens_count}) should match references count (#{refs.length})"
      end
    end
  end

  # =====================================================================
  # Multi-extending: same struct extended in multiple blocks
  # =====================================================================

  MULTI_EXTEND_SOURCE = <<~MT
    struct Counter:
        value: int

    extending Counter:
        function read() -> int:
            return this.value

        editable function bump() -> void:
            this.value += 1

    extending Counter:
        static function zero() -> Counter:
            return Counter(value = 0)

        editable function set(n: int) -> void:
            this.value = n

    function main() -> int:
        var c = Counter.zero()
        c.bump()
        c.set(10)
        return c.read()
  MT

  def test_multi_extend_all_methods_found
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_refs_audit_multi_extend.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => MULTI_EXTEND_SOURCE }
      })

      method_expected = {
        "read" => 2,
        "bump" => 2,
        "zero" => 2,
        "set"  => 2,
      }

      method_expected.each do |method_name, expected|
        decl_line = MULTI_EXTEND_SOURCE.lines.index { |l| l.include?("function #{method_name}(") }
        decl_char = find_char(MULTI_EXTEND_SOURCE, decl_line, method_name)

        refs = query_references(client, uri, decl_line, decl_char)
        assert_equal expected, refs.length,
          "multi-extend #{method_name}: expected #{expected} refs, got #{refs.length}: #{ref_positions(refs)}"
      end
    end
  end

  # =====================================================================
  # References from call site (not just declaration site)
  # =====================================================================

  def test_references_from_call_site_matches_declaration_site
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_refs_audit_from_call.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SINGLE_FILE_SOURCE }
      })

      call_line = SINGLE_FILE_SOURCE.lines.index { |l| l.include?("let d = distance") }
      call_char = find_char(SINGLE_FILE_SOURCE, call_line, "distance")

      decl_line = SINGLE_FILE_SOURCE.lines.index { |l| l.match?(/\Afunction distance/) }
      decl_char = find_char(SINGLE_FILE_SOURCE, decl_line, "distance")

      from_call = query_references(client, uri, call_line, call_char)
      from_decl = query_references(client, uri, decl_line, decl_char)

      call_positions = ref_positions(from_call).sort
      decl_positions = ref_positions(from_decl).sort

      assert_equal decl_positions, call_positions,
        "references from call site should match references from declaration site"
    end
  end

  # =====================================================================
  # References from member-access call site (cursor on method name after dot)
  # =====================================================================

  def test_references_from_member_access_call_site
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_refs_audit_member_call.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => MULTI_EXTEND_SOURCE }
      })

      call_line = MULTI_EXTEND_SOURCE.lines.index { |l| l.include?("c.bump()") }
      call_char = find_char(MULTI_EXTEND_SOURCE, call_line, "bump")

      refs = query_references(client, uri, call_line, call_char)

      decl_line = MULTI_EXTEND_SOURCE.lines.index { |l| l.include?("editable function bump") }

      lines = ref_lines(refs)
      assert_includes lines, decl_line, "member-access bump: should include declaration"
      assert_includes lines, call_line, "member-access bump: should include call site"
      assert refs.length >= 2,
        "member-access bump: expected >= 2 refs, got #{refs.length}: #{ref_positions(refs)}"
    end
  end

  # =====================================================================
  # Struct field references
  # =====================================================================

  FIELD_REF_SOURCE = <<~MT
    struct Particle:
        x: float
        y: float
        speed: float

    extending Particle:
        function kinetic() -> float:
            return this.speed * this.speed

        editable function move() -> void:
            this.x += this.speed
            this.y += this.speed

    function apply(p: Particle) -> float:
        return p.x + p.y + p.speed

    function main() -> int:
        var p = Particle(x = 0.0, y = 0.0, speed = 1.0)
        p.move()
        let k = p.kinetic()
        let total = apply(p)
        return 0
  MT

  def test_struct_field_speed_references
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_refs_audit_field.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => FIELD_REF_SOURCE }
      })

      decl_line = FIELD_REF_SOURCE.lines.index { |l| l.strip == "speed: float" }
      decl_char = find_char(FIELD_REF_SOURCE, decl_line, "speed")

      refs = query_references(client, uri, decl_line, decl_char)

      assert refs.length >= 5,
        "field 'speed': expected >= 5 refs (decl + this.speed*3 + p.speed + constructor), got #{refs.length}: #{ref_positions(refs)}"
    end
  end

  # =====================================================================
  # For-loop binding references
  # =====================================================================

  FOR_BINDING_SOURCE = <<~MT
    function main() -> int:
        var total: int = 0
        for i in 0..10:
            total += i
        for i in 0..5:
            total += i * 2
        return total
  MT

  def test_for_loop_binding_scoped
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_refs_audit_for.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => FOR_BINDING_SOURCE }
      })

      first_for_line = FOR_BINDING_SOURCE.lines.index { |l| l.include?("for i in 0..10") }
      first_for_char = find_char(FOR_BINDING_SOURCE, first_for_line, "i")

      refs = query_references(client, uri, first_for_line, first_for_char)
      lines = ref_lines(refs)

      first_body_line = FOR_BINDING_SOURCE.lines.index { |l| l.include?("total += i") && !l.include?("* 2") }
      assert_includes lines, first_for_line, "first for i: should include binding"
      assert_includes lines, first_body_line, "first for i: should include body usage"

      second_for_line = FOR_BINDING_SOURCE.lines.index { |l| l.include?("for i in 0..5") }
      second_body_line = FOR_BINDING_SOURCE.lines.index { |l| l.include?("i * 2") }
      refute_includes lines, second_for_line, "first for i: should NOT include second for loop"
      refute_includes lines, second_body_line, "first for i: should NOT include second for body"

      assert_equal 2, refs.length,
        "first for i: expected 2 refs (binding + 1 body use), got #{refs.length}: #{ref_positions(refs)}"
    end
  end

  # =====================================================================
  # Constant references
  # =====================================================================

  CONST_REF_SOURCE = <<~MT
    const MAX_SIZE: int = 100

    function check(n: int) -> bool:
        return n < MAX_SIZE

    function limit() -> int:
        return MAX_SIZE
  MT

  def test_constant_references
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_refs_audit_const.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => CONST_REF_SOURCE }
      })

      decl_line = CONST_REF_SOURCE.lines.index { |l| l.start_with?("const MAX_SIZE") }
      decl_char = find_char(CONST_REF_SOURCE, decl_line, "MAX_SIZE")

      refs = query_references(client, uri, decl_line, decl_char)
      lines = ref_lines(refs)

      check_line = CONST_REF_SOURCE.lines.index { |l| l.include?("n < MAX_SIZE") }
      limit_line = CONST_REF_SOURCE.lines.index { |l| l.include?("return MAX_SIZE") }

      assert_includes lines, decl_line, "MAX_SIZE: should include declaration"
      assert_includes lines, check_line, "MAX_SIZE: should include check() usage"
      assert_includes lines, limit_line, "MAX_SIZE: should include limit() usage"
      assert_equal 3, refs.length,
        "MAX_SIZE: expected 3 refs (decl + 2 uses), got #{refs.length}: #{ref_positions(refs)}"
    end
  end

  # =====================================================================
  # Named argument label references
  # =====================================================================

  NAMED_ARG_SOURCE = <<~MT
    struct Vec2:
        x: int
        y: int

    function offset(dx: int, dy: int) -> int:
        return dx + dy

    function main() -> int:
        let v = Vec2(x = 1, y = 2)
        return offset(dx = 3, dy = 4)
  MT

  def test_named_argument_label_references
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_refs_audit_named_arg.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => NAMED_ARG_SOURCE }
      })

      call_line = NAMED_ARG_SOURCE.lines.index { |l| l.include?("offset(dx = 3") }
      dx_char = find_char(NAMED_ARG_SOURCE, call_line, "dx")

      refs = query_references(client, uri, call_line, dx_char)

      assert refs.length >= 2,
        "named arg 'dx': expected >= 2 refs (param decl + body usage), got #{refs.length}: #{ref_positions(refs)}"
    end
  end

  # =====================================================================
  # Enum member references
  # =====================================================================

  ENUM_REF_SOURCE = <<~MT
    enum Color: ubyte
        red = 0
        green = 1
        blue = 2

    function is_warm(c: Color) -> bool:
        match c:
            Color.red:
                return true
            Color.green:
                return false
            Color.blue:
                return false

    function main() -> int:
        let c = Color.red
        if is_warm(c):
            return 1
        return 0
  MT

  def test_enum_member_references
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_refs_audit_enum.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => ENUM_REF_SOURCE }
      })

      decl_line = ENUM_REF_SOURCE.lines.index { |l| l.strip == "red = 0" }
      decl_char = find_char(ENUM_REF_SOURCE, decl_line, "red")

      refs = query_references(client, uri, decl_line, decl_char)

      assert refs.length >= 2,
        "enum 'red': expected >= 2 refs (decl + Color.red usages), got #{refs.length}: #{ref_positions(refs)}"
    end
  end

  # =====================================================================
  # Same method name on different types should not cross-pollinate
  # =====================================================================

  SAME_NAME_SOURCE = <<~MT
    struct Cat:
        name: int

    struct Dog:
        name: int

    extending Cat:
        function speak() -> int:
            return this.name

    extending Dog:
        function speak() -> int:
            return this.name + 1

    function main() -> int:
        let c = Cat(name = 1)
        let d = Dog(name = 2)
        return c.speak() + d.speak()
  MT

  def test_same_method_name_different_types_not_mixed
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_refs_audit_same_name.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SAME_NAME_SOURCE }
      })

      cat_speak_line = SAME_NAME_SOURCE.lines.index { |l| l.strip == "function speak() -> int:" && SAME_NAME_SOURCE.lines[0...SAME_NAME_SOURCE.lines.index(l)].any? { |prior| prior.include?("extending Cat") } }
      if cat_speak_line.nil?
        lines = SAME_NAME_SOURCE.lines
        extending_cat_idx = lines.index { |l| l.include?("extending Cat") }
        cat_speak_line = lines.index.with_index { |l, i| i > extending_cat_idx && l.strip.start_with?("function speak") }
      end
      cat_speak_char = find_char(SAME_NAME_SOURCE, cat_speak_line, "speak")

      refs = query_references(client, uri, cat_speak_line, cat_speak_char)

      assert refs.length >= 2,
        "Cat.speak: expected >= 2 refs, got #{refs.length}: #{ref_positions(refs)}"
    end
  end

  # =====================================================================
  # Module-level var references
  # =====================================================================

  MODULE_VAR_SOURCE = <<~MT
    var counter: int = 0

    function increment() -> void:
        counter += 1

    function read_counter() -> int:
        return counter
  MT

  def test_module_var_references
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_refs_audit_modvar.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => MODULE_VAR_SOURCE }
      })

      decl_line = MODULE_VAR_SOURCE.lines.index { |l| l.start_with?("var counter") }
      decl_char = find_char(MODULE_VAR_SOURCE, decl_line, "counter")

      refs = query_references(client, uri, decl_line, decl_char)
      lines = ref_lines(refs)

      inc_line = MODULE_VAR_SOURCE.lines.index { |l| l.include?("counter += 1") }
      read_line = MODULE_VAR_SOURCE.lines.index { |l| l.include?("return counter") }

      assert_includes lines, decl_line, "counter var: should include declaration"
      assert_includes lines, inc_line, "counter var: should include increment usage"
      assert_includes lines, read_line, "counter var: should include read usage"
      assert_equal 3, refs.length,
        "counter var: expected 3 refs (decl + 2 uses), got #{refs.length}: #{ref_positions(refs)}"
    end
  end

  # =====================================================================
  # Interface name references
  # =====================================================================

  INTERFACE_REF_SOURCE = <<~MT
    interface Drawable:
        function draw(x: int) -> void

    struct Sprite implements Drawable:
        frame: int

    extending Sprite:
        function draw(x: int) -> void:
            let sink = x + this.frame
  MT

  def test_interface_name_references
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_refs_audit_interface.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => INTERFACE_REF_SOURCE }
      })

      decl_line = INTERFACE_REF_SOURCE.lines.index { |l| l.include?("interface Drawable") }
      decl_char = find_char(INTERFACE_REF_SOURCE, decl_line, "Drawable")

      refs = query_references(client, uri, decl_line, decl_char)

      impl_line = INTERFACE_REF_SOURCE.lines.index { |l| l.include?("implements Drawable") }
      lines = ref_lines(refs)

      assert_includes lines, decl_line, "Drawable: should include declaration"
      assert_includes lines, impl_line, "Drawable: should include implements reference"
      assert_equal 2, refs.length,
        "Drawable: expected 2 refs (decl + implements), got #{refs.length}: #{ref_positions(refs)}"
    end
  end

  # =====================================================================
  # Struct type name used across declarations
  # =====================================================================

  TYPE_NAME_SOURCE = <<~MT
    struct Config:
        width: int
        height: int

    extending Config:
        static function default_config() -> Config:
            return Config(width = 800, height = 600)

    function apply(cfg: Config) -> int:
        return cfg.width + cfg.height

    function main() -> int:
        let c = Config.default_config()
        return apply(c)
  MT

  def test_struct_type_name_references
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_refs_audit_typename.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => TYPE_NAME_SOURCE }
      })

      decl_line = TYPE_NAME_SOURCE.lines.index { |l| l.start_with?("struct Config") }
      decl_char = find_char(TYPE_NAME_SOURCE, decl_line, "Config")

      refs = query_references(client, uri, decl_line, decl_char)

      assert refs.length >= 3,
        "struct Config: expected >= 3 refs (decl + constructor + receiver), got #{refs.length}: #{ref_positions(refs)}"
    end
  end
end
