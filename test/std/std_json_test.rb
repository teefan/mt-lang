# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdJsonTest < Minitest::Test
  def test_host_runtime_parses_builds_and_renders_json
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "import std.str as text",
      "import std.json as json",
      "",
      "function main() -> int:",
      "    match json.parse(\"{\\\"name\\\":\\\"mt\\\",\\\"active\\\":true,\\\"score\\\":2.5,\\\"items\\\":[1,null,{\\\"nested\\\":\\\"ok\\\"}]}\"):",
      "        Result.failure as payload:",
      "            var error = payload.error",
      "            defer error.release()",
      "            return 1",
      "        Result.success as payload:",
      "            var parsed = payload.value",
      "            defer json.release_value(parsed)",
      "",
      "            let root = parsed.as_object()",
      "            if root == null:",
      "                return 2",
      "",
      "            unsafe:",
      "                let object = read(ptr[json.Object]<-root)",
      "                match object.get_string(\"name\"):",
      "                    Option.some as name_payload:",
      "                        if not name_payload.value.equal(\"mt\"):",
      "                            return 3",
      "                    Option.none:",
      "                        return 4",
      "                match object.get_boolean(\"active\"):",
      "                    Option.some as active_payload:",
      "                        if not active_payload.value:",
      "                            return 5",
      "                    Option.none:",
      "                        return 6",
      "                match object.get_number(\"score\"):",
      "                    Option.some as score_payload:",
      "                        if score_payload.value != 2.5:",
      "                            return 7",
      "                    Option.none:",
      "                        return 8",
      "                let items = object.get_array(\"items\")",
      "                if items == null:",
      "                    return 9",
      "                let list = read(ptr[json.Array]<-items)",
      "                if list.len() != ptr_uint<-3:",
      "                    return 10",
      "                match list.get_number(0):",
      "                    Option.some as item_payload:",
      "                        if item_payload.value != 1.0:",
      "                            return 11",
      "                    Option.none:",
      "                        return 12",
      "                let null_item = list.get(1)",
      "                if null_item == null:",
      "                    return 13",
      "                if not read(null_item).is_null():",
      "                    return 14",
      "                let nested = list.get_object(2)",
      "                if nested == null:",
      "                    return 15",
      "                match read(ptr[json.Object]<-nested).get_string(\"nested\"):",
      "                    Option.some as nested_payload:",
      "                        if not nested_payload.value.equal(\"ok\"):",
      "                            return 16",
      "                    Option.none:",
      "                        return 17",
      "",
      "            match json.render(parsed):",
      "                Result.failure as render_payload:",
      "                    var render_error = render_payload.error",
      "                    defer render_error.release()",
      "                    return 18",
      "                Result.success as render_payload:",
      "                    var compact = render_payload.value",
      "                    defer compact.release()",
      "                    if not compact.as_str().equal(\"{\\\"name\\\":\\\"mt\\\",\\\"active\\\":true,\\\"score\\\":2.5,\\\"items\\\":[1,null,{\\\"nested\\\":\\\"ok\\\"}]}\"):",
      "                        return 19",
      "",
      "                    match json.render_pretty(parsed):",
      "                        Result.failure as pretty_payload:",
      "                            var pretty_error = pretty_payload.error",
      "                            defer pretty_error.release()",
      "                            return 20",
      "                        Result.success as pretty_payload:",
      "                            var pretty = pretty_payload.value",
      "                            defer pretty.release()",
      "                            if pretty.as_str().equal(compact.as_str()):",
      "                                return 21",
      "                            match json.parse(pretty.as_str()):",
      "                                Result.failure as reparsed_payload:",
      "                                    var reparsed_error = reparsed_payload.error",
      "                                    defer reparsed_error.release()",
      "                                    return 22",
      "                                Result.success as reparsed_payload:",
      "                                    var reparsed = reparsed_payload.value",
      "                                    defer json.release_value(reparsed)",
      "                                    match json.render(reparsed):",
      "                                        Result.failure as rerender_payload:",
      "                                            var rerender_error = rerender_payload.error",
      "                                            defer rerender_error.release()",
      "                                            return 23",
      "                                        Result.success as rerender_payload:",
      "                                            var rerendered = rerender_payload.value",
      "                                            defer rerendered.release()",
      "                                            if not rerendered.as_str().equal(compact.as_str()):",
      "                                                return 24",
      "",
      "            var built = json.create_object_value()",
      "            defer json.release_value(built)",
      "            let built_object = built.as_object()",
      "            if built_object == null:",
      "                return 25",
      "",
      "            var built_items = json.create_array_value()",
      "            let built_items_array = built_items.as_array()",
      "            if built_items_array == null:",
      "                return 26",
      "",
      "            var nested_built = json.create_object_value()",
      "            let nested_built_object = nested_built.as_object()",
      "            if nested_built_object == null:",
      "                return 27",
      "",
      "            unsafe:",
      "                read(ptr[json.Object]<-nested_built_object).set(\"ok\", json.boolean_value(true))",
      "                read(ptr[json.Array]<-built_items_array).push(json.number_value(1.0))",
      "                read(ptr[json.Array]<-built_items_array).push(json.null_value())",
      "                read(ptr[json.Array]<-built_items_array).push(nested_built)",
      "                read(ptr[json.Object]<-built_object).set(\"name\", json.string_from_str(\"builder\"))",
      "                read(ptr[json.Object]<-built_object).set(\"items\", built_items)",
      "",
      "            match json.render(built):",
      "                Result.failure as built_payload:",
      "                    var built_error = built_payload.error",
      "                    defer built_error.release()",
      "                    return 28",
      "                Result.success as built_payload:",
      "                    var built_text = built_payload.value",
      "                    defer built_text.release()",
      "                    if not built_text.as_str().equal(\"{\\\"name\\\":\\\"builder\\\",\\\"items\\\":[1,null,{\\\"ok\\\":true}]}\"):",
      "                        return 29",
      "",
      "            match json.parse(\"{\"):",
      "                Result.success as broken_payload:",
      "                    var broken = broken_payload.value",
      "                    defer json.release_value(broken)",
      "                    return 30",
      "                Result.failure as broken_payload:",
      "                    var broken_error = broken_payload.error",
      "                    defer broken_error.release()",
      "                    if broken_error.message.as_str().len == 0:",
      "                        return 31",
      "",
      "            return 0",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_includes result.link_flags, "-lcjson"
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-json") do |dir|
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
