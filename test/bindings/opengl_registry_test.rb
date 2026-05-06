# frozen_string_literal: true

require "open3"
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
  assert_match(/extern def glCreateShader\(type_: uint\) -> GLuint/, generated)
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

  def test_generated_header_compiles_loader_selectors_for_glfw_and_sdl
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless executable_available?(compiler)

    Dir.mktmpdir("milk-tea-opengl-loader-smoke") do |dir|
      header_path = File.join(dir, "gl_registry_helpers.h")
      program_path = File.join(dir, "loader_smoke.c")
      output_path = File.join(dir, "loader_smoke")
      glfw_dir = File.join(dir, "GLFW")
      sdl_dir = File.join(dir, "SDL3")
      FileUtils.mkdir_p(glfw_dir)
      FileUtils.mkdir_p(sdl_dir)

      File.write(header_path, generate_header(profile: "compatibility"))
      File.write(File.join(glfw_dir, "glfw3.h"), <<~C)
        #ifndef GLFW_GLFW3_H
        #define GLFW_GLFW3_H
        typedef void (*GLFWglproc)(void);
        GLFWglproc glfwGetProcAddress(const char *procname);
        #endif
      C
      File.write(File.join(sdl_dir, "SDL.h"), <<~C)
        #ifndef SDL3_SDL_H
        #define SDL3_SDL_H
        typedef void (*SDL_FunctionPointer)(void);
        SDL_FunctionPointer SDL_GL_GetProcAddress(const char *proc_name);
        #endif
      C
      File.write(program_path, <<~C)
        #include <stdlib.h>
        #include <string.h>

        #define #{MilkTea::OpenGLRegistry::IMPLEMENTATION_DEFINE}
        #define MT_LANG_GL_REGISTRY_HAVE_GLFW
        #define MT_LANG_GL_REGISTRY_HAVE_SDL3
        #include "gl_registry_helpers.h"

        static int glfw_loader_calls = 0;
        static int sdl_loader_calls = 0;
        static int bind_buffer_calls = 0;

        static void MTLANG_GL_APIENTRY fake_glBindBuffer(GLenum target, GLuint buffer)
        {
            if ((target == 10u && buffer == 20u) || (target == 30u && buffer == 40u) || (target == 50u && buffer == 60u)) {
                bind_buffer_calls += 1;
                return;
            }
            abort();
        }

        GLFWglproc glfwGetProcAddress(const char *procname)
        {
            glfw_loader_calls += 1;
            return strcmp(procname, "glBindBuffer") == 0 ? (GLFWglproc) fake_glBindBuffer : (GLFWglproc) 0;
        }

        SDL_FunctionPointer SDL_GL_GetProcAddress(const char *proc_name)
        {
            sdl_loader_calls += 1;
            return strcmp(proc_name, "glBindBuffer") == 0 ? (SDL_FunctionPointer) fake_glBindBuffer : (SDL_FunctionPointer) 0;
        }

        int main(void)
        {
            mt_gl_use_glfw_loader();
            glBindBuffer(10u, 20u);
            glBindBuffer(30u, 40u);
            if (glfw_loader_calls != 1 || bind_buffer_calls != 2) {
                return 1;
            }

            mt_gl_reset_loader();
            mt_gl_use_sdl_loader();
            glBindBuffer(50u, 60u);
            if (sdl_loader_calls != 1 || bind_buffer_calls != 3) {
                return 2;
            }

            return 0;
        }
      C

      stdout, stderr, status = Open3.capture3(compiler, program_path, "-I", dir, "-o", output_path)
      assert status.success?, [stdout, stderr].reject(&:empty?).join

      stdout, stderr, status = Open3.capture3(output_path)
      assert_equal "", stdout
      assert_equal "", stderr
      assert_equal 0, status.exitstatus
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
