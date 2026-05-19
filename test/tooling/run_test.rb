# frozen_string_literal: true

require "tmpdir"
require "net/http"
require_relative "../test_helper"

class MilkTeaRunTest < Minitest::Test
  def test_run_executes_built_program_and_preserves_requested_artifacts
    Dir.mktmpdir("milk-tea-run") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = write_fake_script_compiler(dir, compiler_log, stdout: "hello\n", stderr: "warn\n", exit_status: 5)
      output_path = File.join(dir, "demo-run")
      c_path = File.join(dir, "demo-run.c")

      result = MilkTea::Run.run(language_fixture_path, output_path:, cc: compiler_path, keep_c_path: c_path)

      assert_equal "hello\n", result.stdout
      assert_equal "warn\n", result.stderr
      assert_equal 5, result.exit_status
      assert_equal File.expand_path(output_path), result.output_path
      assert_equal File.expand_path(c_path), result.c_path
      assert_equal File.expand_path(compiler_path), result.compiler
      assert_equal [], result.link_flags
      assert_nil result.bundle_root
      assert_nil result.archive_path
      assert File.exist?(output_path)
      assert File.exist?(c_path)
      refute_match(/^#line\s+/m, File.read(c_path))
      invocation = File.read(compiler_log).lines(chomp: true)
      refute_includes invocation, "-lm"
    end
  end

  def test_run_executes_binary_from_source_directory_for_relative_assets
    Dir.mktmpdir("milk-tea-run-cwd") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = File.join(dir, "fake-run-cwd-cc")
      File.write(compiler_path, <<~SH)
        #!/bin/sh
        printf '%s\n' "$@" > #{compiler_log.inspect}
        output=''
        previous=''
        for argument in "$@"; do
          if [ "$previous" = '-o' ]; then
            output="$argument"
          fi
          previous="$argument"
        done
        cat > "$output" <<'SCRIPT'
        #!/bin/sh
        pwd
        SCRIPT
        chmod +x "$output"
      SH
      File.chmod(0o755, compiler_path)

      source_path = File.join(dir, "cwd.mt")
      File.write(source_path, [
        "function main() -> int:",
        "    return 0",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler_path)

      assert_equal "#{dir}\n", result.stdout
      assert_equal "", result.stderr
      assert_equal 0, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler_path, result.compiler
      assert_equal [], result.link_flags
      assert_includes File.read(compiler_log).lines(chomp: true), "-o"
    end
  end

  def test_run_with_host_compiler_executes_real_binary
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-real") do |dir|
      source_path = File.join(dir, "smoke.mt")

      File.write(source_path, [
        "function main() -> int:",
        "    return 42",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 42, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_source_file_inside_package_surfaces_invalid_manifest
    Dir.mktmpdir("milk-tea-run-invalid-package-manifest") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = write_fake_script_compiler(dir, compiler_log, stdout: "", stderr: "", exit_status: 0)
      package_root = File.join(dir, "snake-duel")
      src_dir = File.join(package_root, "src")
      FileUtils.mkdir_p(src_dir)

      File.write(File.join(package_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"

        [build]
        entry =
      TOML

      source_path = File.join(src_dir, "main.mt")
      File.write(source_path, [
        "function main() -> int:",
        "    return 0",
        "",
      ].join("\n"))

      error = assert_raises(MilkTea::BuildError) do
        MilkTea::Run.run(source_path, cc: compiler_path)
      end

      assert_match(/invalid package\.toml/, error.message)
      refute File.exist?(compiler_log)
    end
  end

  def test_run_package_build_accepts_archive_option
    Dir.mktmpdir("milk-tea-run-package-archive") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = write_fake_script_compiler(dir, compiler_log, stdout: "bundle-run\n", stderr: "bundle-err\n", exit_status: 9)
      package_root = File.join(dir, "desktop-demo")
      src_dir = File.join(package_root, "src")
      assets_dir = File.join(package_root, "assets")
      output_root = File.join(dir, "dist", "desktop_demo")
      FileUtils.mkdir_p(src_dir)
      FileUtils.mkdir_p(assets_dir)

      File.write(File.join(package_root, "package.toml"), <<~TOML)
        [package]
        name = "desktop_demo"

        [platform]
        default = "linux"

        [build]
        entry = "src/main.mt"
        assets = "assets"
      TOML

      File.write(File.join(src_dir, "main.mt"), <<~MT)
        function main() -> int:
            return 0
      MT
      File.write(File.join(assets_dir, "note.txt"), "hello")

      result = MilkTea::Run.run(package_root, cc: compiler_path, output_path: output_root, archive: true)

      assert_equal "bundle-run\n", result.stdout
      assert_equal "bundle-err\n", result.stderr
      assert_equal 9, result.exit_status
      assert_equal File.expand_path(output_root), result.output_path
      assert_nil result.c_path
      assert_equal File.expand_path(compiler_path), result.compiler
      assert_equal [], result.link_flags
      assert_equal :linux, result.platform
      assert_equal File.expand_path(output_root), result.bundle_root
      assert_equal "#{File.expand_path(output_root)}.tar.gz", result.archive_path
      assert File.exist?(File.join(output_root, "desktop_demo"))
      assert File.exist?(File.join(output_root, "assets.mtpack"))
      assert File.exist?("#{output_root}.tar.gz")
      refute File.exist?(File.join(output_root, "assets", "note.txt"))
      assert_includes File.read(compiler_log).lines(chomp: true), "-o"
    end
  end

  def test_run_wasm_target_opens_browser_preview
    Dir.mktmpdir("milk-tea-run-wasm") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = write_fake_script_compiler(dir, compiler_log, stdout: "", stderr: "", exit_status: 0)
      source_path = File.join(dir, "web.mt")
      opened_urls = []
      opened_after_listen = nil

      preview_server_class = Class.new do
        class << self
          attr_accessor :listening, :started_root_dir, :served_forever
        end

        def initialize(root_dir:, idle_timeout: nil)
          self.class.started_root_dir = root_dir
          self.class.listening = false
          self.class.served_forever = false
        end

        def listen!
          self.class.listening = true
          self
        end

        def url_for(entry_name)
          "http://127.0.0.1:43123/#{entry_name}"
        end

        def serve_forever
          self.class.served_forever = true
        end
      end

      File.write(source_path, [
        "function main() -> int:",
        "    return 0",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(
        source_path,
        cc: compiler_path,
        platform: :wasm,
        browser_opener: lambda do |url|
          opened_after_listen = preview_server_class.listening
          opened_urls << url
        end,
        preview_server_class: preview_server_class,
      )

      expected_output = File.expand_path(File.join(dir, "web.html"))

      assert_equal true, opened_after_listen
      assert_equal ["http://127.0.0.1:43123/web.html"], opened_urls
      assert_equal File.expand_path(dir), preview_server_class.started_root_dir
      assert_equal true, preview_server_class.served_forever
      assert_equal "serving http://127.0.0.1:43123/web.html (press Ctrl-C to stop)\n", result.stdout
      assert_equal "", result.stderr
      assert_equal 0, result.exit_status
      assert_equal expected_output, result.output_path
      assert_nil result.c_path
      assert_equal File.expand_path(compiler_path), result.compiler
      assert_equal [], result.link_flags
      assert_equal :wasm, result.platform
      assert_nil result.bundle_root
      assert_nil result.archive_path
      assert File.exist?(compiler_log)
    end
  end

  def test_wasm_preview_server_sets_cross_origin_isolation_headers_and_png_mime_type
    Dir.mktmpdir("milk-tea-run-wasm-server") do |dir|
      File.write(File.join(dir, "index.html"), "<html></html>")
      File.binwrite(File.join(dir, "sprite.png"), "fake-png")

      server = MilkTea::Run::WasmPreviewServer.new(root_dir: dir, idle_timeout: 30).start

      begin
        uri = URI("http://#{server.host}:#{server.port}/sprite.png")
        response = Net::HTTP.get_response(uri)

        assert_equal "200", response.code
        assert_equal "image/png", response["content-type"]
        assert_equal "same-origin", response["cross-origin-opener-policy"]
        assert_equal "require-corp", response["cross-origin-embedder-policy"]
      ensure
        begin
          server.stop
        rescue Errno::ESRCH, Errno::ENOENT
          nil
        end
      end
    end
  end

  def test_run_with_host_compiler_executes_program_using_local_generic_helper
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-generic-helper") do |dir|
      source_path = File.join(dir, "generic-helper.mt")

      File.write(source_path, [
        "function clamp[T](value: T, min_value: T, max_value: T) -> T:",
        "    if value < min_value:",
        "        return min_value",
        "    else if value > max_value:",
        "        return max_value",
        "    return value",
        "",
        "function main() -> int:",
        "    let clamped = clamp(42, 0, 40)",
        "    if clamped == 40:",
        "        return 7",
        "    return 1",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 7, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_mixed_numeric_binary_operations
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-numeric") do |dir|
      source_path = File.join(dir, "numeric.mt")

      File.write(source_path, [
        "function main() -> int:",
        "    let sum = 1 + 2.5",
        "    if 3 < 3.5 and sum > 3.0:",
        "        return 7",
        "    return 0",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 7, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_address_of_and_dereference
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-pointers") do |dir|
      source_path = File.join(dir, "pointers.mt")

      File.write(source_path, [
        "struct Counter:",
        "    value: int",
        "",
        "function main() -> int:",
        "    var counter = Counter(value = 3)",
        "    let counter_ptr = ptr_of(counter)",
        "    var value = 0",
        "    unsafe:",
        "        counter_ptr.value = 7",
        "        value = counter_ptr.value",
        "    return value",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 7, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_integer_to_char_buffer_writes
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-char-buffer") do |dir|
      source_path = File.join(dir, "char-buffer.mt")

      File.write(source_path, [
        "function main() -> int:",
        "    let first = 65",
        "    var buffer = zero[array[char, 4]]",
        "    unsafe:",
        "        var raw_buffer = ptr_of(buffer[0])",
        "        raw_buffer[0] = first",
        "        raw_buffer[1] = char<-66",
        "    return int<-buffer[0] + int<-buffer[1] - 131",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 0, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_safe_refs
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-refs") do |dir|
      source_path = File.join(dir, "refs.mt")

      File.write(source_path, [
        "struct Counter:",
        "    value: int",
        "",
        "extending Counter:",
        "    mutable function add(delta: int):",
        "        this.value += delta",
        "",
        "    function read() -> int:",
        "        return this.value",
        "",
        "function increment(counter: ref[Counter], amount: int) -> void:",
        "    counter.add(amount)",
        "    counter.value += 1",
        "",
        "function main() -> int:",
        "    var counter = Counter(value = 3)",
        "    let handle = ref_of(counter)",
        "    increment(handle, 4)",
        "    let value_ref = ref_of(handle.value)",
        "    read(value_ref) += 2",
        "    unsafe:",
        "        let raw_counter = ptr_of(handle)",
        "        raw_counter.value += 1",
        "    return handle.read()",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 11, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_raw_pointer_methods
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-pointer-methods") do |dir|
      source_path = File.join(dir, "pointer-methods.mt")

      File.write(source_path, [
        "struct Counter:",
        "    value: int",
        "",
        "extending Counter:",
        "    mutable function add(delta: int):",
        "        this.value += delta",
        "",
        "    function read() -> int:",
        "        return this.value",
        "",
        "function main() -> int:",
        "    var counter = Counter(value = 3)",
        "    let counter_ptr = ptr_of(counter)",
        "    unsafe:",
        "        counter_ptr.add(4)",
        "        return counter_ptr.read()",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 7, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_explicit_value_for_by_value_parameters
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-explicit-value") do |dir|
      source_path = File.join(dir, "explicit-value.mt")

      File.write(source_path, [
        "struct Counter:",
        "    value: int",
        "",
        "function project(counter: Counter) -> int:",
        "    return counter.value",
        "",
        "function main() -> int:",
        "    var counter = Counter(value = 9)",
        "    let handle = ref_of(counter)",
        "    counter.value = 12",
        "    return project(read(handle))",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 12, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_spans
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-spans") do |dir|
      source_path = File.join(dir, "spans.mt")

      File.write(source_path, [
        "function first(items: span[int]) -> int:",
        "    if items.len == 0:",
        "        return 0",
        "    unsafe:",
        "        return read(items.data)",
        "",
        "function main() -> int:",
        "    var value = 7",
        "    let items = span[int](data = ptr_of(value), len = 1)",
        "    return first(items)",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 7, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_safe_span_indexing
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-span-index") do |dir|
      source_path = File.join(dir, "span_index.mt")

      File.write(source_path, [
        "function bump(items: span[int]) -> int:",
        "    let first = items[0]",
        "    items[0] = first + 2",
        "    return items[0]",
        "",
        "function main() -> int:",
        "    var value = 7",
        "    let items = span[int](data = ptr_of(value), len = 1)",
        "    return bump(items)",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 9, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_generic_structs
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-generics") do |dir|
      source_path = File.join(dir, "generics.mt")

      File.write(source_path, [
        "struct Slice[T]:",
        "    data: ptr[T]",
        "    len: ptr_uint",
        "",
        "struct Holder:",
        "    items: Slice[int]",
        "",
        "function first(items: Slice[int]) -> int:",
        "    if items.len == 0:",
        "        return 0",
        "    unsafe:",
        "        return read(items.data)",
        "",
        "function main() -> int:",
        "    var value = 7",
        "    let holder = Holder(items = Slice[int](data = ptr_of(value), len = 1))",
        "    return first(holder.items)",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 7, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_generic_struct_only_in_expression
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-generic-expression-only") do |dir|
      source_path = File.join(dir, "generic-expression-only.mt")

      File.write(source_path, [
        "struct Box[T]:",
        "    value: T",
        "",
        "function main() -> int:",
        "    let ok: bool = Box[int](value = 7).value == 7",
        "    if ok:",
        "        return 1",
        "    return 0",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 1, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_generic_functions
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-generic-functions") do |dir|
      source_path = File.join(dir, "generic-functions.mt")

      File.write(source_path, [
        "struct Slice[T]:",
        "    data: ptr[T]",
        "    len: ptr_uint",
        "",
        "function head[T](items: Slice[T]) -> ptr[T]:",
        "    return items.data",
        "",
        "function min[T](a: T, b: T) -> T:",
        "    if a < b:",
        "        return a",
        "    return b",
        "",
        "function main() -> int:",
        "    var value = 7",
        "    let items = Slice[int](data = ptr_of(value), len = 1)",
        "    let smallest = min(9, 4)",
        "    unsafe:",
        "        return read(head(items)) + smallest",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 11, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_ref_arguments_for_by_value_parameters
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-ref-value-args") do |dir|
      source_path = File.join(dir, "ref-value-args.mt")

      File.write(source_path, [
        "struct Counter:",
        "    value: int",
        "",
        "function project(counter: Counter) -> int:",
        "    return counter.value",
        "",
        "function main() -> int:",
        "    var counter = Counter(value = 9)",
        "    let handle = ref_of(counter)",
        "    counter.value = 12",
        "    return project(read(handle))",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 12, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_status_construction
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-result") do |dir|
      source_path = File.join(dir, "result.mt")

      File.write(source_path, [
        "",
        "",
        "enum LoadError: ubyte",
        "    invalid_format = 1",
        "",
        "function load(available: bool) -> Result[int, LoadError]:",
        "    if available:",
        "        return Result[int, LoadError].success(value= 7)",
        "    return Result[int, LoadError].failure(error= LoadError.invalid_format)",
        "",
        "function main() -> int:",
        "    let success = load(true)",
        "    let failure = load(false)",
        "    match success:",
        "        Result.success as success_payload:",
        "            match failure:",
        "                Result.failure as failure_payload:",
        "                    if failure_payload.error == LoadError.invalid_format:",
        "                        return success_payload.value + 1",
        "                Result.success as ignored_payload:",
        "                    return 0",
        "        Result.failure as ignored_error:",
        "            return 0",
        "    return 0",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 8, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_nested_option_result_alias_values
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-option-result") do |dir|
      source_path = File.join(dir, "option_result_reader.mt")

      File.write(source_path, [
        "",
        "",
        "import std.asset_pack as pack",
        "",
        "type Reader = pack.Reader",
        "",
        "function make() -> Result[Option[Reader], int]:",
        "    return Result[Option[Reader], int].success(value= Option[Reader].some(value= Reader(file = null, entry_count = 0)))",
        "",
        "function main() -> int:",
        "    let result = make()",
        "    match result:",
        "        Result.failure as payload:",
        "            return payload.error",
        "        Result.success as payload:",
        "            match payload.value:",
        "                Option.none:",
        "                    return 1",
        "                Option.some as reader_payload:",
        "                    if reader_payload.value.file == null:",
        "                        return int<-reader_payload.value.entry_count",
        "                    return 2",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 0, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_builtin_fatal
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-fatal") do |dir|
      source_path = File.join(dir, "fatal.mt")

      File.write(source_path, [
        "function main() -> int:",
        "    fatal(\"bad state\")",
        "    return 0",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_includes result.stderr, "bad state"
      assert_equal 134, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_enum_match
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-match") do |dir|
      source_path = File.join(dir, "match.mt")

      File.write(source_path, [
        "enum EventKind: ubyte",
        "    quit = 1",
        "    resize = 2",
        "",
        "function dispatch(kind: EventKind) -> int:",
        "    match kind:",
        "        EventKind.quit:",
        "            return 4",
        "        EventKind.resize:",
        "            return 7",
        "",
        "function main() -> int:",
        "    return dispatch(EventKind.resize)",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 7, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_for_loops
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-for") do |dir|
      source_path = File.join(dir, "for.mt")

      File.write(source_path, [
        "function sum(items: array[int, 4]) -> int:",
        "    var total = 0",
        "    for item in items:",
        "        total += item",
        "    for i in 0..4:",
        "        total += i",
        "    return total",
        "",
        "function main() -> int:",
        "    return sum(array[int, 4](1, 2, 3, 4))",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 16, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_status_values
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-result") do |dir|
      source_path = File.join(dir, "result.mt")

      File.write(source_path, [
        "",
        "",
        "enum ParseError: ubyte",
        "    empty = 1",
        "    invalid = 2",
        "",
        "function parse(flag: int) -> Result[int, ParseError]:",
        "    if flag == 0:",
        "        return Result[int, ParseError].failure(error= ParseError.empty)",
        "    else if flag < 0:",
        "        return Result[int, ParseError].failure(error= ParseError.invalid)",
        "    return Result[int, ParseError].success(value= flag + 10)",
        "",
        "function value_or_code(result: Result[int, ParseError]) -> int:",
        "    match result:",
        "        Result.success as payload:",
        "            return payload.value",
        "        Result.failure as payload:",
        "            match payload.error:",
        "                ParseError.empty:",
        "                    return 2",
        "                ParseError.invalid:",
        "                    return 3",
        "    return 0",
        "",
        "function main() -> int:",
        "    let parsed = parse(4)",
        "    let failed = parse(0)",
        "    return value_or_code(parsed) + value_or_code(failed)",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 16, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_let_else_status_success_binding
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-status-let-else") do |dir|
      source_path = File.join(dir, "status_let_else.mt")

      File.write(source_path, [
        "",
        "",
        "function parse(flag: int) -> Result[int, int]:",
        "    if flag < 0:",
        "        return Result[int, int].failure(error= 20)",
        "    return Result[int, int].success(value= flag + 1)",
        "",
        "function consume(flag: int) -> int:",
        "    let value: int = parse(flag) else:",
        "        return 20",
        "    return value + 3",
        "",
        "function main() -> int:",
        "    return consume(4) + consume(-1)",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 28, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_let_else_status_error_binding
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-status-let-else-error") do |dir|
      source_path = File.join(dir, "status_let_else_error.mt")

      File.write(source_path, [
        "",
        "",
        "function parse(flag: int) -> Result[int, int]:",
        "    if flag < 0:",
        "        return Result[int, int].failure(error= 20)",
        "    return Result[int, int].success(value= flag + 1)",
        "",
        "function consume(flag: int) -> int:",
        "    let value: int = parse(flag) else as error:",
        "        return error",
        "    return value + 3",
        "",
        "function main() -> int:",
        "    return consume(4) + consume(-1)",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 28, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_let_else_status_void_discard_binding
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-status-let-else-void") do |dir|
      source_path = File.join(dir, "status_let_else_void.mt")

      File.write(source_path, [
        "",
        "",
        "function done() -> void:",
        "    return",
        "",
        "function parse(flag: int) -> Result[void, int]:",
        "    if flag < 0:",
        "        return Result[void, int].failure(error= 20)",
        "    return Result[void, int].success(value= done())",
        "",
        "function consume(flag: int) -> int:",
        "    let _ = parse(flag) else as error:",
        "        return error",
        "    return 8",
        "",
        "function main() -> int:",
        "    return consume(1) + consume(-1)",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 28, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_callable_values
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-callable") do |dir|
      source_path = File.join(dir, "callable.mt")

      File.write(source_path, [
        "struct Entry:",
        "    callback: fn(value: int) -> int",
        "",
        "function add_two(value: int) -> int:",
        "    return value + 2",
        "",
        "function triple(value: int) -> int:",
        "    return value * 3",
        "",
        "function main() -> int:",
        "    let callbacks = array[fn(value: int) -> int, 2](add_two, triple)",
        "    let entry = Entry(callback = callbacks[1])",
        "    return callbacks[0](5) + entry.callback(4)",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 19, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_proc_closures
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-proc") do |dir|
      source_path = File.join(dir, "proc_closure.mt")

      File.write(source_path, [
        "function apply(callback: proc(value: int) -> int, value: int) -> int:",
        "    return callback(value)",
        "",
        "function main() -> int:",
        "    let offset = 4",
        "    let callback = proc(value: int) -> int:",
        "        return value * 2 + offset",
        "    return apply(callback, 3)",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 10, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_loop_control_in_match
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-loop-control") do |dir|
      source_path = File.join(dir, "loop_control.mt")

      File.write(source_path, [
        "enum Step: ubyte",
        "    skip = 1",
        "    keep = 2",
        "    stop = 3",
        "",
        "function add(target: ptr[int], amount: int) -> void:",
        "    unsafe:",
        "        read(target) += amount",
        "",
        "function main() -> int:",
        "    var total = 0",
        "    for step in array[Step, 4](Step.keep, Step.skip, Step.keep, Step.stop):",
        "        defer add(ptr_of(total), 1)",
        "        match step:",
        "            Step.skip:",
        "                continue",
        "            Step.keep:",
        "                total += 10",
        "            Step.stop:",
        "                break",
        "    return total",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 24, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_layout_queries_and_static_assert
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-layout") do |dir|
      source_path = File.join(dir, "layout.mt")

      File.write(source_path, [
        "struct Header:",
        "    magic: array[ubyte, 4]",
        "    version: ushort",
        "",
        "static_assert(size_of(Header) == 6, \"Header size should stay stable\")",
        "static_assert(offset_of(Header, version) == 4, \"Header.version offset drifted\")",
        "",
        "function main() -> int:",
        "    return int<-(size_of(Header) + align_of(Header) + offset_of(Header, version))",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 12, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_packed_and_aligned_structs
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-layout-modifiers") do |dir|
      source_path = File.join(dir, "layout_modifiers.mt")

      File.write(source_path, [
        "packed struct Header:",
        "    tag: ubyte",
        "    value: uint",
        "",
        "align(16) struct Mat4:",
        "    data: array[float, 16]",
        "",
        "static_assert(size_of(Header) == 5, \"Header should stay packed\")",
        "static_assert(offset_of(Header, value) == 1, \"Header.value offset drifted\")",
        "static_assert(align_of(Mat4) == 16, \"Mat4 alignment drifted\")",
        "",
        "function main() -> int:",
        "    return int<-(size_of(Header) + offset_of(Header, value) + align_of(Mat4))",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 22, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_passing_real_str_values
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-str") do |dir|
      source_path = File.join(dir, "str_value.mt")

      File.write(source_path, [
        "const greeting: str = \"hello\"",
        "",
        "function score(message: str) -> int:",
        "    return 7",
        "",
        "function main() -> int:",
        "    return score(greeting)",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 7, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_str_slice_and_cstr_conversion
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-str-ops") do |dir|
      source_path = File.join(dir, "str_ops.mt")

      File.write(source_path, [
        "import std.str as text_ops",
        "import std.mem.arena as arena",
        "import std.c.libc as libc",
        "",
        "function main() -> int:",
        "    var scratch = arena.create(64)",
        "    defer scratch.release()",
        "    let text = \"12345!\"",
        "    let part = text.slice(0, 5)",
        "    let copied = part.to_cstr(ref_of(scratch))",
        "    if text.len == ptr_uint<-6 and libc.atoi(copied) == 12345:",
        "        return int<-part.len",
        "    return 0",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 5, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_std_libc_parse_int_str_boundary
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-std-libc") do |dir|
      source_path = File.join(dir, "std_libc.mt")

      File.write(source_path, [
        "import std.libc as libc",
        "import std.str as text_ops",
        "",
        "function main() -> int:",
        "    let text = \"12345!\"",
        "    let part = text.slice(0, 5)",
        "    if libc.parse_int(part) == 12345:",
        "        return int<-part.len",
        "    return 0",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 5, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_defer_block_cleanup_order
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-defer-block") do |dir|
      source_path = File.join(dir, "defer_block.mt")

      File.write(source_path, [
        "function append_digit(target: ptr[int], digit: int) -> void:",
        "    unsafe:",
        "        read(target) = read(target) * 10 + digit",
        "",
        "function run(target: ptr[int]) -> void:",
        "    defer append_digit(target, 3)",
        "    defer:",
        "        append_digit(target, 1)",
        "        append_digit(target, 2)",
        "",
        "function main() -> int:",
        "    var total = 0",
        "    run(ptr_of(total))",
        "    return total",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 123, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_utf_8_str_slice_on_codepoint_boundary
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-str-utf8-slice") do |dir|
      source_path = File.join(dir, "str_utf8_slice.mt")

      File.write(source_path, [
        "import std.str as text_ops",
        "",
        "function main() -> int:",
        "    let text = \"éx\"",
        "    let part = text.slice(0, 2)",
        "    if text.len == ptr_uint<-3 and part.len == ptr_uint<-2:",
        "        return int<-part.len",
        "    return 0",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 2, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_rejects_str_slice_with_non_utf_8_start_boundary
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-str-bad-start-boundary") do |dir|
      source_path = File.join(dir, "str_bad_start_boundary.mt")

      File.write(source_path, [
        "import std.str as text_ops",
        "",
        "function main() -> int:",
        "    let text = \"éx\"",
        "    let part = text.slice(1, 2)",
        "    return int<-part.len",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_includes result.stderr, "str slice start must be a UTF-8 boundary"
      assert_equal 134, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_rejects_str_slice_with_non_utf_8_end_boundary
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-str-bad-end-boundary") do |dir|
      source_path = File.join(dir, "str_bad_end_boundary.mt")

      File.write(source_path, [
        "import std.str as text_ops",
        "",
        "function main() -> int:",
        "    let text = \"éx\"",
        "    let part = text.slice(0, 1)",
        "    return int<-part.len",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_includes result.stderr, "str slice end must be a UTF-8 boundary"
      assert_equal 134, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_rejects_array_char_as_str_method
    Dir.mktmpdir("milk-tea-run-array-char-bad-str") do |dir|
      source_path = File.join(dir, "array_char_bad_str.mt")

      File.write(source_path, [
        "function main() -> int:",
        "    var buffer: array[char, 2]",
        "    let view = buffer.as_str()",
        "    return int<-view.len",
        "",
      ].join("\n"))

      error = assert_raises(MilkTea::SemaError) do
        MilkTea::Run.run(source_path)
      end

      assert_match(/array\[char, 2\]\.as_str is not available; array\[char, N\] is raw storage/, error.message)
    end
  end

  def test_run_rejects_array_char_as_cstr_method
    Dir.mktmpdir("milk-tea-run-array-char-bad-cstr") do |dir|
      source_path = File.join(dir, "array_char_bad_cstr.mt")

      File.write(source_path, [
        "function main() -> int:",
        "    var buffer: array[char, 2]",
        "    let label = buffer.as_cstr()",
        "    return 0",
        "",
      ].join("\n"))

      error = assert_raises(MilkTea::SemaError) do
        MilkTea::Run.run(source_path)
      end

      assert_match(/array\[char, 2\]\.as_cstr is not available; array\[char, N\] is raw storage/, error.message)
    end
  end

  def test_run_with_host_compiler_executes_program_using_str_buffer_methods
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-str-builder") do |dir|
      source_path = File.join(dir, "str_buffer.mt")

      File.write(source_path, [
        "function write_raw(items: span[char]) -> void:",
        "    unsafe:",
        "        items.data[0] = char<-65",
        "        items.data[1] = 0",
        "",
        "function view(items: span[char]) -> ptr_uint:",
        "    return items.len",
        "",
        "function main() -> int:",
        "    var buffer: str_buffer[8]",
        "    buffer.assign(\"ab\")",
        "    buffer.append(\"cd\")",
        "    if view(buffer) != ptr_uint<-9:",
        "        return 1",
        "    if buffer.len() != ptr_uint<-4:",
        "        return 2",
        "    write_raw(buffer)",
        "    let text = buffer.as_str()",
        "    if text.len != ptr_uint<-1:",
        "        return 3",
        "    if buffer.len() != ptr_uint<-1:",
        "        return 4",
        "    buffer.clear()",
        "    if buffer.len() != ptr_uint<-0:",
        "        return 5",
        "    return 0",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 0, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_rejects_str_buffer_as_str_after_invalid_raw_write
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-str-builder-bad-str") do |dir|
      source_path = File.join(dir, "str_buffer_bad_str.mt")

      File.write(source_path, [
        "function corrupt(items: span[char]) -> void:",
        "    unsafe:",
        "        items.data[0] = char<-0x80",
        "        items.data[1] = 0",
        "",
        "function main() -> int:",
        "    var buffer: str_buffer[4]",
        "    corrupt(buffer)",
        "    let text = buffer.as_str()",
        "    return int<-text.len",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_includes result.stderr, "str_buffer text must be valid UTF-8"
      assert_equal 134, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_span_str_foreign_list_marshalling
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    dir_name = "run_span_str_#{Process.pid}_#{Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)}"
    dir = File.join(MilkTea.root, "tmp", dir_name)
    source_path = File.join(dir, "main.mt")
    sample_path = File.join(dir, "sample.mt")

    Dir.mkdir(dir)

    begin
      module_prefix = "tmp.#{dir_name}"

      File.write(sample_path, [
        "import std.c.libc as libc",
        "",
        "public foreign function first(labels: span[str] as span[ptr[char]]) -> int = libc.atoi(labels[0])",
        "public foreign function second(labels: span[str] as span[ptr[char]]) -> int = libc.atoi(labels[1])",
        "",
      ].join("\n"))

      File.write(source_path, [
        "import #{module_prefix}.sample as sample",
        "",
        "function main() -> int:",
        "    var labels = array[str, 2](\"12\", \"34\")",
        "    let first = sample.first(labels)",
        "    let second = sample.second(labels)",
        "    if first != 12:",
        "        return 1",
        "    if second != 34:",
        "        return 2",
        "    return 0",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 0, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    ensure
      File.delete(sample_path) if File.exist?(sample_path)
      File.delete(source_path) if File.exist?(source_path)
      Dir.rmdir(dir) if Dir.exist?(dir)
    end
  end

  def test_run_with_host_compiler_executes_program_using_nested_imported_foreign_calls
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    dir_name = "run_nested_foreign_#{Process.pid}_#{Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)}"
    dir = File.join(MilkTea.root, "tmp", dir_name)
    source_path = File.join(dir, "main.mt")
    sample_path = File.join(dir, "sample.mt")

    Dir.mkdir(dir)

    begin
      module_prefix = "tmp.#{dir_name}"

      File.write(sample_path, [
        "import std.c.libc as libc",
        "",
        "public foreign function first(labels: span[str] as span[ptr[char]]) -> int = libc.atoi(labels[0])",
        "public foreign function second(labels: span[str] as span[ptr[char]]) -> int = libc.atoi(labels[1])",
        "public foreign function same_div(value: int) -> libc.div_t = libc.div(value, value)",
        "",
      ].join("\n"))

      File.write(source_path, [
        "import #{module_prefix}.sample as sample",
        "",
        "function keep(value: int) -> int:",
        "    return value",
        "",
        "function main() -> int:",
        "    var labels = array[str, 2](\"12\", \"34\")",
        "    var short_labels = array[str, 1](\"12\")",
        "    let nested_sum = keep(sample.first(labels) + sample.second(labels))",
        "    if nested_sum != 46:",
        "        return 1",
        "    let duplicated = sample.same_div(1 + 2).quot",
        "    if duplicated != 1:",
        "        return 2",
        "    let chosen = if true: keep(sample.first(labels)) else: keep(sample.second(short_labels))",
        "    if chosen != 12:",
        "        return 3",
        "    if false and sample.second(short_labels) != 0:",
        "        return 4",
        "    let always_true = if true or sample.second(short_labels) != 0: 1 else: 0",
        "    if always_true != 1:",
        "        return 5",
        "    return 0",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 0, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    ensure
      File.delete(sample_path) if File.exist?(sample_path)
      File.delete(source_path) if File.exist?(source_path)
      Dir.rmdir(dir) if Dir.exist?(dir)
    end
  end

  def test_run_with_host_compiler_executes_match_expression_once
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-match-expr") do |dir|
      source_path = File.join(dir, "match_expr.mt")

      File.write(source_path, [
        "struct Counter:",
        "    value: int",
        "",
        "variant Step:",
        "    keep(value: int)",
        "    stop",
        "",
        "function next_step(counter: ref[Counter]) -> Step:",
        "    counter.value += 1",
        "    return Step.keep(value = 41)",
        "",
        "function main() -> int:",
        "    var counter = Counter(value = 0)",
        "    let result = match next_step(counter):",
        "        Step.keep as payload: payload.value + counter.value",
        "        Step.stop: 0",
        "    if counter.value != 1:",
        "        return 1",
        "    return if result == 42: 0 else: 2",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 0, result.exit_status
    end
  end

  def test_run_with_host_compiler_executes_program_using_unsafe_reinterpret
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-reinterpret") do |dir|
      source_path = File.join(dir, "reinterpret.mt")

      File.write(source_path, [
        "function main() -> int:",
        "    let value: float = 1.0",
        "    let expected: uint = 1065353216",
        "    unsafe:",
        "        let bits = reinterpret[uint](value)",
        "        if bits != expected:",
        "            return 1",
        "    return 0",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 0, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_fixed_arrays
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-arrays") do |dir|
      source_path = File.join(dir, "arrays.mt")

      File.write(source_path, [
        "struct Palette:",
        "    colors: array[uint, 4]",
        "",
        "function main() -> int:",
        "    var palette = array[uint, 4](1, 2, 3, 4)",
        "    var holder = Palette(colors = array[uint, 4](5, 6, 7, 8))",
        "    unsafe:",
        "        if read(ptr_of(palette[0])) != 1:",
        "            return 1",
        "        if read(ptr_of(holder.colors[0])) != 5:",
        "            return 2",
        "    return 0",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 0, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_addr_of_fixed_array_element_through_pointer_deref
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-ptr-array-addr") do |dir|
      source_path = File.join(dir, "ptr-array-addr.mt")

      File.write(source_path, [
        "struct Palette:",
        "    colors: array[uint, 4]",
        "",
        "function main() -> int:",
        "    var holder = Palette(colors = array[uint, 4](5, 6, 7, 8))",
        "    unsafe:",
        "        let base = ptr_of(holder)",
        "        let first = ptr_of(base.colors[0])",
        "        read(first) = 9",
        "    if holder.colors[0] != 9:",
        "        return 1",
        "    return 0",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 0, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_array_indexing
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-array-indexing") do |dir|
      source_path = File.join(dir, "array-indexing.mt")

      File.write(source_path, [
        "struct Palette:",
        "    colors: array[uint, 4]",
        "",
        "function main() -> int:",
        "    var palette = array[uint, 4](1, 2, 3, 4)",
        "    var holder = Palette(colors = array[uint, 4](5, 6, 7, 8))",
        "    palette[1] = 9",
        "    holder.colors[2] = 10",
        "    if palette[0] != 1:",
        "        return 1",
        "    if palette[1] != 9:",
        "        return 2",
        "    if holder.colors[2] != 10:",
        "        return 3",
        "    return 0",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 0, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_traps_out_of_bounds_safe_array_indexing
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-array-bounds") do |dir|
      source_path = File.join(dir, "array-bounds.mt")

      File.write(source_path, [
        "function main() -> int:",
        "    let palette = array[int, 4](1, 2, 3, 4)",
        "    return palette[4]",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_includes result.stderr, "array index out of bounds"
      assert_equal 134, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_array_assignment_and_by_value_params
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-array-copy") do |dir|
      source_path = File.join(dir, "array-copy.mt")

      File.write(source_path, [
        "function mutate(values: array[int, 4]) -> int:",
        "    var local = values",
        "    unsafe:",
        "        local[1] = 9",
        "        return local[1]",
        "",
        "function main() -> int:",
        "    var lhs = array[int, 4](1, 2, 3, 4)",
        "    let rhs = array[int, 4](5, 6, 7, 8)",
        "    lhs = rhs",
        "    let changed = mutate(lhs)",
        "    if changed != 9:",
        "        return 1",
        "    unsafe:",
        "        if lhs[1] != 6:",
        "            return 2",
        "    return 0",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 0, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_zero_initialization
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-zero") do |dir|
      source_path = File.join(dir, "zero.mt")

      File.write(source_path, [
        "struct Palette:",
        "    colors: array[uint, 4]",
        "",
        "function main() -> int:",
        "    let palette = zero[array[uint, 4]]",
        "    let holder = zero[Palette]",
        "    if palette[0] != 0:",
        "        return 1",
        "    if holder.colors[3] != 0:",
        "        return 2",
        "    return 0",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 0, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_partial_aggregate_and_array_initialization
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-partial-init") do |dir|
      source_path = File.join(dir, "partial-init.mt")

      File.write(source_path, [
        "struct Point:",
        "    x: int",
        "    y: int",
        "",
        "struct Holder:",
        "    point: Point",
        "    colors: array[uint, 4]",
        "",
        "function main() -> int:",
        "    let origin = Point()",
        "    let point = Point(x = 5)",
        "    let colors = array[uint, 4](1, 2)",
        "    let holder = Holder(point = point)",
        "    if origin.x != 0 or origin.y != 0:",
        "        return 1",
        "    if point.x != 5 or point.y != 0:",
        "        return 2",
        "    if colors[0] != 1 or colors[1] != 2 or colors[2] != 0 or colors[3] != 0:",
        "        return 3",
        "    if holder.point.x != 5 or holder.point.y != 0:",
        "        return 4",
        "    if holder.colors[0] != 0 or holder.colors[3] != 0:",
        "        return 5",
        "    return 0",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 0, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_local_array_returns
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-array-returns") do |dir|
      source_path = File.join(dir, "array-returns.mt")

      File.write(source_path, [
        "function make() -> array[int, 4]:",
        "    return array[int, 4](1, 2, 3, 4)",
        "",
        "function clone(values: array[int, 4]) -> array[int, 4]:",
        "    return values",
        "",
        "function read(values: array[int, 4]) -> int:",
        "    unsafe:",
        "        return values[1]",
        "",
        "function main() -> int:",
        "    return read(clone(make()))",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 2, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  private

  def language_fixture_path
    materialized_language_fixture_path
  end

  def write_fake_script_compiler(dir, log_path, stdout:, stderr:, exit_status:)
    path = File.join(dir, "fake-run-cc")
    File.write(path, <<~SH)
      #!/bin/sh
      printf '%s\n' "$@" > #{log_path.inspect}
      output=''
      previous=''
      for argument in "$@"; do
        if [ "$previous" = '-o' ]; then
          output="$argument"
        fi
        previous="$argument"
      done
      cat > "$output" <<'SCRIPT'
      #!/bin/sh
      printf '%b' #{stdout.inspect}
      printf '%b' #{stderr.inspect} >&2
      exit #{exit_status}
      SCRIPT
      chmod +x "$output"
    SH
    File.chmod(0o755, path)
    path
  end

  def compiler_available?(compiler)
    return File.executable?(compiler) if compiler.include?(File::SEPARATOR)

    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |entry|
      candidate = File.join(entry, compiler)
      File.file?(candidate) && File.executable?(candidate)
    end
  end
end
