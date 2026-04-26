# frozen_string_literal: true

require "tmpdir"
require_relative "test_helper"

class MilkTeaRawBindingsTest < Minitest::Test
  def test_default_registry_exposes_known_checked_in_bindings
    registry = MilkTea::RawBindings.default_registry

    assert_equal %w[raylib raygui rlgl msf_gif libc], registry.map(&:name)
    assert_equal "std.c.raylib", registry.fetch("raylib").module_name
    assert_includes registry.fetch("raylib").header_candidates.first, "third_party/raylib-upstream/src/raylib.h"
    assert_includes registry.fetch("raylib").link_flags, "-lglfw"
    assert_equal({ "codepoints" => "ptr[i32]?" }, registry.fetch("raylib").function_param_type_overrides.fetch("LoadFontEx"))
    assert_equal ["RAYGUI_IMPLEMENTATION"], registry.fetch("raygui").implementation_defines
    assert_equal ["raylib", "m"], registry.fetch("raygui").link_libraries
    assert_includes registry.fetch("raygui").header_candidates.first, "third_party/raylib-upstream/examples/shapes/raygui.h"
    assert_equal({ "codepoints" => "ptr[i32]?" }, registry.fetch("raygui").function_param_type_overrides.fetch("LoadFontData"))
    assert_equal "std.c.rlgl", registry.fetch("rlgl").module_name
    assert_equal ["raylib"], registry.fetch("rlgl").link_libraries
    assert_includes registry.fetch("rlgl").header_candidates.last, "third_party/raylib-upstream/src/rlgl.h"
    assert_equal "std.c.msf_gif", registry.fetch("msf_gif").module_name
    assert_equal ["MSF_GIF_IMPL"], registry.fetch("msf_gif").implementation_defines
    assert_includes registry.fetch("msf_gif").header_candidates.first, "third_party/raylib-upstream/examples/core/msf_gif.h"
    assert_equal "bindgen:check:libc", registry.fetch("libc").check_task_name
    assert_equal "bindgen:check_raylib", registry.fetch("raylib").legacy_check_task_name
  end

  def test_header_path_prefers_env_override_before_default_candidates
    Dir.mktmpdir("milk-tea-raw-binding-path") do |dir|
      default_header = File.join(dir, "default.h")
      override_header = File.join(dir, "override.h")
      File.write(default_header, "")
      File.write(override_header, "")

      binding = MilkTea::RawBindings::Binding.new(
        name: "sample",
        module_name: "std.c.sample",
        binding_path: File.join(dir, "sample.mt"),
        header_candidates: [default_header],
        include_directives: ["sample.h"],
        env_var: "SAMPLE_HEADER",
      )

      assert_equal override_header, binding.header_path(env: { "SAMPLE_HEADER" => override_header })
      assert_equal default_header, binding.header_path(env: {})
    end
  end

  def test_generate_forwards_binding_configuration_to_bindgen
    Dir.mktmpdir("milk-tea-raw-binding-generate") do |dir|
      header_path = File.join(dir, "sample.h")
      File.write(header_path, "")

      binding = MilkTea::RawBindings::Binding.new(
        name: "sample",
        module_name: "std.c.sample",
        binding_path: File.join(dir, "sample.mt"),
        header_candidates: [header_path],
        include_directives: ["sample.h"],
        link_libraries: ["sample"],
        env_var: "SAMPLE_HEADER",
        clang_args: ["-I#{dir}"],
        function_param_type_overrides: { "sample_function" => { "data" => "ptr[u8]?" } },
      )

      observed = nil
      with_singleton_method_override(MilkTea::Bindgen, :generate, lambda { |**kwargs|
        observed = kwargs
        "generated"
      }) do
        assert_equal "generated", binding.generate(env: { "SAMPLE_HEADER" => header_path, "CLANG" => "clang-custom" })
      end

      assert_equal(
        {
          module_name: "std.c.sample",
          header_path:,
          link_libraries: ["sample"],
          include_directives: ["sample.h"],
          clang: "clang-custom",
          clang_args: ["-I#{dir}"],
          function_param_type_overrides: { "sample_function" => { "data" => "ptr[u8]?" } },
        },
        observed,
      )
    end
  end

  def test_build_flags_include_header_directory_implementation_defines_and_extra_compiler_flags
    Dir.mktmpdir("milk-tea-raw-binding-build-flags") do |dir|
      header_path = File.join(dir, "sample.h")
      File.write(header_path, "")

      binding = MilkTea::RawBindings::Binding.new(
        name: "sample",
        module_name: "std.c.sample",
        binding_path: File.join(dir, "sample.mt"),
        header_candidates: [header_path],
        include_directives: ["sample.h"],
        implementation_defines: ["SAMPLE_IMPLEMENTATION"],
        compiler_flags: ["-DSAMPLE_TOOLING=1"],
      )

      assert_equal ["-I#{dir}", "-DSAMPLE_IMPLEMENTATION", "-DSAMPLE_TOOLING=1"], binding.build_flags
    end
  end

  def test_binding_exposes_extra_link_flags
    binding = MilkTea::RawBindings::Binding.new(
      name: "sample",
      module_name: "std.c.sample",
      binding_path: "/tmp/sample.mt",
      header_candidates: ["/tmp/sample.h"],
      link_flags: ["-L/tmp/sample", "-lsample_helper"],
    )

    assert_equal ["-L/tmp/sample", "-lsample_helper"], binding.link_flags
  end

  def test_prepare_hook_can_be_invoked
    invoked = []
    binding = MilkTea::RawBindings::Binding.new(
      name: "sample",
      module_name: "std.c.sample",
      binding_path: "/tmp/sample.mt",
      header_candidates: ["/tmp/sample.h"],
      prepare: ->(_binding, env:, cc:) { invoked << [env.fetch("MARKER"), cc] },
    )

    binding.prepare!(env: { "MARKER" => "ok", "CC" => "cc" }, cc: "clang")

    assert_equal [["ok", "clang"]], invoked
  end

  def test_registry_can_find_bindings_by_module_name
    registry = MilkTea::RawBindings::Registry.new([
      MilkTea::RawBindings::Binding.new(
        name: "sample",
        module_name: "std.c.sample",
        binding_path: "/tmp/sample.mt",
        header_candidates: ["/tmp/sample.h"],
      ),
    ])

    assert_equal "sample", registry.find_by_module_name("std.c.sample").name
    assert_nil registry.find_by_module_name("std.c.missing")
  end

  def test_check_ignores_generated_header_banner_path_and_validates_module
    Dir.mktmpdir("milk-tea-raw-binding-check") do |dir|
      header_path = File.join(dir, "sample.h")
      binding_path = File.join(dir, "sample.mt")
      File.write(header_path, "")
      File.write(binding_path, "# generated by mtc bindgen from /tmp/original.h\nextern module std.c.sample:\n")

      binding = MilkTea::RawBindings::Binding.new(
        name: "sample",
        module_name: "std.c.sample",
        binding_path:,
        header_candidates: [header_path],
        include_directives: ["sample.h"],
        env_var: "SAMPLE_HEADER",
      )

      checked_paths = []
      generated = "# generated by mtc bindgen from #{header_path}\nextern module std.c.sample:\n"

      with_singleton_method_override(MilkTea::Bindgen, :generate, ->(**) { generated }) do
        with_singleton_method_override(MilkTea::ModuleLoader, :check_file, ->(path) { checked_paths << path }) do
          assert_equal header_path, binding.check!(env: { "SAMPLE_HEADER" => header_path })
        end
      end

      assert_equal [binding_path], checked_paths
    end
  end

  def test_check_reports_binding_drift_with_regeneration_task_name
    Dir.mktmpdir("milk-tea-raw-binding-drift") do |dir|
      header_path = File.join(dir, "sample.h")
      binding_path = File.join(dir, "sample.mt")
      File.write(header_path, "")
      File.write(binding_path, "# generated by mtc bindgen from /tmp/original.h\nextern module std.c.sample:\n")

      binding = MilkTea::RawBindings::Binding.new(
        name: "sample",
        module_name: "std.c.sample",
        binding_path:,
        header_candidates: [header_path],
        include_directives: ["sample.h"],
        env_var: "SAMPLE_HEADER",
      )

      with_singleton_method_override(MilkTea::Bindgen, :generate, ->(**) { "# generated by mtc bindgen from #{header_path}\nextern module std.c.sample:\n    const CHANGED: i32 = 1\n" }) do
        error = assert_raises(MilkTea::RawBindings::Error) do
          binding.check!(env: { "SAMPLE_HEADER" => header_path })
        end

        assert_match(/#{Regexp.escape(binding_path)} is out of date for #{Regexp.escape(header_path)}/, error.message)
        assert_match(/Run `rake bindgen:sample` to regenerate it\./, error.message)
      end
    end
  end

  def with_singleton_method_override(object, method_name, implementation)
    singleton_class = class << object; self; end
    original_name = "__raw_bindings_original_#{method_name}__"
    original_defined = singleton_class.method_defined?(method_name) || singleton_class.private_method_defined?(method_name)
    singleton_class.alias_method(original_name, method_name) if original_defined
    singleton_class.define_method(method_name) do |*args, **kwargs, &block|
      implementation.call(*args, **kwargs, &block)
    end
    yield
  ensure
    singleton_class.remove_method(method_name) if singleton_class.method_defined?(method_name)
    if original_defined
      singleton_class.alias_method(method_name, original_name)
      singleton_class.remove_method(original_name)
    end
  end
end
