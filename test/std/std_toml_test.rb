# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdTomlTest < Minitest::Test
  def test_host_runtime_parses_and_renders_supported_toml_subset
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "import std.maybe as maybe",
      "import std.status as status",
      "import std.str as text",
      "import std.string as string",
      "import std.toml as toml",
      "",
      "function main() -> int:",
      "    var source = string.String.create()",
      "    defer source.release()",
      "    source.append(\"schema_version = 2\")",
      "    source.push_byte(ubyte<-10)",
      "    source.append(\"root_package = \")",
      "    source.push_byte(ubyte<-34)",
      "    source.append(\"snake_duel\")",
      "    source.push_byte(ubyte<-34)",
      "    source.push_byte(ubyte<-10)",
      "    source.append(\"active = true\")",
      "    source.push_byte(ubyte<-10)",
      "    source.push_byte(ubyte<-10)",
      "    source.append(\"[dependencies]\")",
      "    source.push_byte(ubyte<-10)",
      "    source.push_byte(ubyte<-34)",
      "    source.append(\"teefan.ui\")",
      "    source.push_byte(ubyte<-34)",
      "    source.append(\" = { path = \" )",
      "    source.push_byte(ubyte<-34)",
      "    source.append(\"../../libs/ui\")",
      "    source.push_byte(ubyte<-34)",
      "    source.append(\", version = \" )",
      "    source.push_byte(ubyte<-34)",
      "    source.append(\"1.2.3\")",
      "    source.push_byte(ubyte<-34)",
      "    source.append(\" }\")",
      "    source.push_byte(ubyte<-10)",
      "    source.push_byte(ubyte<-10)",
      "    source.append(\"[[package]]\")",
      "    source.push_byte(ubyte<-10)",
      "    source.append(\"name = \" )",
      "    source.push_byte(ubyte<-34)",
      "    source.append(\"snake_duel\")",
      "    source.push_byte(ubyte<-34)",
      "    source.push_byte(ubyte<-10)",
      "    source.append(\"dependency_ids = [\")",
      "    source.push_byte(ubyte<-34)",
      "    source.append(\"ui-v1\")",
      "    source.push_byte(ubyte<-34)",
      "    source.append(\", \" )",
      "    source.push_byte(ubyte<-34)",
      "    source.append(\"ui-v2\")",
      "    source.push_byte(ubyte<-34)",
      "    source.append(\"]\")",
      "    source.push_byte(ubyte<-10)",
      "",
      "    match toml.parse(source.as_str()):",
      "        status.Status.err as payload:",
      "            var error = payload.error",
      "            defer error.release()",
      "            return 1",
      "        status.Status.ok as payload:",
      "            var document = payload.value",
      "            defer document.release()",
      "",
      "            match document.get_integer(\"schema_version\"):",
      "                maybe.Maybe.some as int_payload:",
      "                    if int_payload.value != long<-2:",
      "                        return 2",
      "                maybe.Maybe.none:",
      "                    return 3",
      "",
      "            match document.get_boolean(\"active\"):",
      "                maybe.Maybe.some as bool_payload:",
      "                    if not bool_payload.value:",
      "                        return 4",
      "                maybe.Maybe.none:",
      "                    return 5",
      "",
      "            let deps = document.get_table(\"dependencies\")",
      "            if deps == null:",
      "                return 6",
      "",
      "            unsafe:",
      "                let dep_spec = read(ptr[toml.Table]<-deps).get_object(\"teefan.ui\")",
      "                if dep_spec == null:",
      "                    return 7",
      "                match read(ptr[toml.Object]<-dep_spec).get_string(\"path\"):",
      "                    maybe.Maybe.some as path_payload:",
      "                        if not path_payload.value.equal(\"../../libs/ui\"):",
      "                            return 8",
      "                    maybe.Maybe.none:",
      "                        return 9",
      "                match read(ptr[toml.Object]<-dep_spec).get_string(\"version\"):",
      "                    maybe.Maybe.some as version_payload:",
      "                        if not version_payload.value.equal(\"1.2.3\"):",
      "                            return 10",
      "                    maybe.Maybe.none:",
      "                        return 11",
      "",
      "            let packages = document.get_array_table(\"package\")",
      "            if packages == null:",
      "                return 12",
      "",
      "            unsafe:",
      "                let packages_table = read(ptr[toml.ArrayTable]<-packages)",
      "                if packages_table.len() != ptr_uint<-1:",
      "                    return 13",
      "                let first_package = packages_table.get(0)",
      "                if first_package == null:",
      "                    return 14",
      "                match read(ptr[toml.Object]<-first_package).get_string(\"name\"):",
      "                    maybe.Maybe.some as name_payload:",
      "                        if not name_payload.value.equal(\"snake_duel\"):",
      "                            return 15",
      "                    maybe.Maybe.none:",
      "                        return 16",
      "                let dependency_ids = read(ptr[toml.Object]<-first_package).get_array(\"dependency_ids\")",
      "                if dependency_ids == null:",
      "                    return 17",
      "                let ids = read(ptr[toml.Array]<-dependency_ids)",
      "                if ids.len() != ptr_uint<-2:",
      "                    return 18",
      "                match ids.get_string(1):",
      "                    maybe.Maybe.some as id_payload:",
      "                        if not id_payload.value.equal(\"ui-v2\"):",
      "                            return 19",
      "                    maybe.Maybe.none:",
      "                        return 20",
      "",
      "            var rendered = toml.render(document)",
      "            defer rendered.release()",
      "            match toml.parse(rendered.as_str()):",
      "                status.Status.err as error_payload:",
      "                    var error = error_payload.error",
      "                    defer error.release()",
      "                    return 21",
      "                status.Status.ok as reparsed_payload:",
      "                    var reparsed = reparsed_payload.value",
      "                    defer reparsed.release()",
      "                    match reparsed.get_string(\"root_package\"):",
      "                        maybe.Maybe.some as root_payload:",
      "                            if not root_payload.value.equal(\"snake_duel\"):",
      "                                return 22",
      "                        maybe.Maybe.none:",
      "                            return 23",
      "",
      "            match toml.parse(\"[package\"):",
      "                status.Status.ok as broken_payload:",
      "                    var broken = broken_payload.value",
      "                    defer broken.release()",
      "                    return 24",
      "                status.Status.err as broken_error_payload:",
      "                    var broken_error = broken_error_payload.error",
      "                    defer broken_error.release()",
      "                    if broken_error.line != ptr_uint<-1:",
      "                        return 25",
      "                    if broken_error.column == ptr_uint<-0:",
      "                        return 26",
      "",
      "            return 0",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_equal [], result.link_flags
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-toml") do |dir|
      source_path = File.join(dir, "program.mt")
      File.write(source_path, source)
      return MilkTea::Run.run(source_path, cc: compiler)
    end
  end

  def compiler_available?(compiler)
    return File.executable?(compiler) if compiler.include?(File::SEPARATOR)

    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |entry|
      candidate = File.join(entry, compiler)
      File.file?(candidate) && File.executable?(candidate)
    end
  end
end
