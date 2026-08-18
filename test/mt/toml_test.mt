# In-language tests for std.toml (migrated from
# test/std/std_toml_test.rb, run by `mtc test`).

import std.str as str
import std.string as string
import std.toml as toml

@[test]
function test_toml_parse_query_render_roundtrip() -> void:
    var source = string.String.create()
    defer: source.release()
    source.append("schema_version = 2\n")
    source.append("root_package = \"snake_duel\"\n")
    source.append("active = true\n")
    source.append("\n")
    source.append("[dependencies]\n")
    source.append("\"teefan.ui\" = { path = \"../../libs/ui\", version = \"1.2.3\" }\n")
    source.append("\n")
    source.append("[[package]]\n")
    source.append("name = \"snake_duel\"\n")
    source.append("dependency_ids = [\"ui-v1\", \"ui-v2\"]\n")

    match toml.parse(source.as_str()):
        Result.failure as payload:
            var error = payload.error
            error.release()
            expect(false, "initial parse failed")
        Result.success as payload:
            var document = payload.value
            defer: document.release()

            match document.get_integer("schema_version"):
                Option.some as int_payload:
                    expect(int_payload.value == long<-2, "schema_version == 2")
                Option.none:
                    expect(false, "schema_version missing")

            match document.get_boolean("active"):
                Option.some as bool_payload:
                    expect(bool_payload.value)
                Option.none:
                    expect(false, "active missing")

            let deps = document.get_table("dependencies")
            expect(deps != null, "dependencies table present")

            unsafe:
                let dep_spec = read(ptr[toml.Table]<-deps).get_object("teefan.ui")
                expect(dep_spec != null, "teefan.ui object present")
                match read(ptr[toml.Object]<-dep_spec).get_string("path"):
                    Option.some as path_payload:
                        expect(path_payload.value.equal("../../libs/ui"))
                    Option.none:
                        expect(false, "dependency path missing")
                match read(ptr[toml.Object]<-dep_spec).get_string("version"):
                    Option.some as version_payload:
                        expect(version_payload.value.equal("1.2.3"))
                    Option.none:
                        expect(false, "dependency version missing")

            let packages = document.get_array_table("package")
            expect(packages != null, "package array table present")

            unsafe:
                let packages_table = read(ptr[toml.ArrayTable]<-packages)
                expect(packages_table.len() == 1z, "one package entry")
                let first_package = packages_table.get(0)
                expect(first_package != null, "first package present")
                match read(ptr[toml.Object]<-first_package).get_string("name"):
                    Option.some as name_payload:
                        expect(name_payload.value.equal("snake_duel"))
                    Option.none:
                        expect(false, "package name missing")
                let dependency_ids = read(ptr[toml.Object]<-first_package).get_array("dependency_ids")
                expect(dependency_ids != null, "dependency_ids array present")
                let ids = read(ptr[toml.Array]<-dependency_ids)
                expect(ids.len() == 2z, "two dependency ids")
                match ids.get_string(1):
                    Option.some as id_payload:
                        expect(id_payload.value.equal("ui-v2"))
                    Option.none:
                        expect(false, "second dependency id missing")

            var rendered = toml.render(document)
            defer: rendered.release()
            match toml.parse(rendered.as_str()):
                Result.failure as error_payload:
                    var error = error_payload.error
                    error.release()
                    expect(false, "reparse of rendered document failed")
                Result.success as reparsed_payload:
                    var reparsed = reparsed_payload.value
                    defer: reparsed.release()
                    match reparsed.get_string("root_package"):
                        Option.some as root_payload:
                            expect(root_payload.value.equal("snake_duel"))
                        Option.none:
                            expect(false, "root_package missing after reparse")

            match toml.parse("[package"):
                Result.success as broken_payload:
                    var broken = broken_payload.value
                    broken.release()
                    expect(false, "malformed toml should fail to parse")
                Result.failure as broken_error_payload:
                    var broken_error = broken_error_payload.error
                    defer: broken_error.release()
                    expect(broken_error.line == 1z, "error line == 1")
                    expect(broken_error.column != 0z, "error column != 0")

