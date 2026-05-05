# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"
require_relative "../../lib/milk_tea/bindings"

class MilkTeaOpenGLRegistryTest < Minitest::Test
  FIXTURE_XML = <<~XML
    <registry>
      <types>
        <type name="khrplatform">#include &lt;KHR/khrplatform.h&gt;</type>
        <type requires="khrplatform">typedef khronos_uint32_t <name>GLenum</name>;</type>
        <type requires="khrplatform">typedef khronos_uint32_t <name>GLuint</name>;</type>
        <type>typedef void (<apientry/> *<name>GLDEBUGPROC</name>)(GLenum source);</type>
      </types>
      <enums>
        <enum name="GL_TRIANGLES" value="0x0004" />
        <enum name="GL_ARRAY_BUFFER" value="0x8892" />
        <enum name="GL_VERTEX_SHADER" value="0x8B31" />
      </enums>
      <commands>
        <command>
          <proto>void <name>glBegin</name></proto>
          <param><ptype>GLenum</ptype> <name>mode</name></param>
        </command>
        <command>
          <proto>void <name>glBindBuffer</name></proto>
          <param><ptype>GLenum</ptype> <name>target</name></param>
          <param><ptype>GLuint</ptype> <name>buffer</name></param>
        </command>
        <command>
          <proto><ptype>GLuint</ptype> <name>glCreateShader</name></proto>
          <param><ptype>GLenum</ptype> <name>type</name></param>
        </command>
      </commands>
      <feature api="gl" name="GL_VERSION_1_0" number="1.0">
        <require>
          <enum name="GL_TRIANGLES" />
          <command name="glBegin" />
        </require>
      </feature>
      <feature api="gl" name="GL_VERSION_1_5" number="1.5">
        <require>
          <enum name="GL_ARRAY_BUFFER" />
          <command name="glBindBuffer" />
        </require>
      </feature>
      <feature api="gl" name="GL_VERSION_2_0" number="2.0">
        <require>
          <enum name="GL_VERTEX_SHADER" />
          <command name="glCreateShader" />
        </require>
      </feature>
      <feature api="gl" name="GL_VERSION_3_2" number="3.2">
        <remove profile="core">
          <command name="glBegin" />
        </remove>
      </feature>
    </registry>
  XML

  def test_generate_keeps_legacy_commands_for_compatibility_profile
    header = generate_header(profile: "compatibility")

    assert_includes header, "typedef uint32_t GLenum;"
    assert_includes header, "typedef void (MTLANG_GL_APIENTRY *GLDEBUGPROC)(GLenum source);"
    assert_includes header, "#define GL_TRIANGLES 0x0004"
    assert_includes header, "void MTLANG_GL_APIENTRY glBegin(GLenum mode);"
    assert_includes header, "void MTLANG_GL_APIENTRY glBindBuffer(GLenum target, GLuint buffer);"
    assert_includes header, "GLuint MTLANG_GL_APIENTRY glCreateShader(GLenum type);"
  end

  def test_generate_applies_core_profile_removals
    header = generate_header(profile: "core")

    refute_includes header, "void MTLANG_GL_APIENTRY glBegin(GLenum mode);"
    assert_includes header, "void MTLANG_GL_APIENTRY glBindBuffer(GLenum target, GLuint buffer);"
  end

  def test_generated_header_is_bindgen_compatible
    clang = ENV.fetch("CLANG", "clang")
    skip "clang not available: #{clang}" unless executable_available?(clang)

    Dir.mktmpdir("milk-tea-opengl-registry") do |dir|
      header_path = File.join(dir, "gl_registry_helpers.h")
      output_path = File.join(dir, "gl.mt")
      File.write(header_path, generate_header(profile: "compatibility"))

      generated = MilkTea::Bindgen.generate(
        module_name: "std.c.gl",
        header_path:,
        include_directives: ["gl_registry_helpers.h"],
        declaration_name_prefixes: ["GL", "gl", "mt_gl_"],
        clang:,
      )

      assert_match(/const GL_TRIANGLES: int = 4/, generated)
      assert_match(/extern def glBegin\(mode: uint\) -> void/, generated)
      assert_match(/extern def glBindBuffer\(target: uint, buffer: uint\) -> void/, generated)
      assert_match(/extern def glCreateShader\(type: uint\) -> GLuint/, generated)
      assert_match(/extern def mt_gl_use_glfw_loader\(\) -> void/, generated)
      assert_match(/extern def mt_gl_use_sdl_loader\(\) -> void/, generated)

      File.write(output_path, generated)
      analysis = MilkTea::ModuleLoader.check_file(output_path)

      assert_equal :extern_module, analysis.module_kind
      assert_equal "std.c.gl", analysis.module_name
      assert_includes analysis.functions.keys, "glBindBuffer"
      assert_includes analysis.functions.keys, "mt_gl_use_glfw_loader"
      assert_includes analysis.functions.keys, "mt_gl_use_sdl_loader"
      assert_includes analysis.types.keys, "GLenum"
    end
  end

  private

  def generate_header(profile:)
    MilkTea::OpenGLRegistry::Generator.new(
      xml_source: FIXTURE_XML,
      api: "gl",
      version: "4.6",
      profile:,
    ).generate
  end

  def executable_available?(program)
    return File.executable?(program) if program.include?(File::SEPARATOR)

    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |entry|
      candidate = File.join(entry, program)
      File.file?(candidate) && File.executable?(candidate)
    end
  end
end
