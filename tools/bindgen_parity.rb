#!/usr/bin/env ruby
# frozen_string_literal: true

# Compare the self-host bindgen with the Ruby host generator over the repo's
# raw-binding registry.  For each binding:
#
#   1. run the binding's `prepare!` so vendored headers/libraries exist,
#   2. generate the module with the host library (the same call the Rake
#      `bindgen:*` tasks make, including the per-binding option tables),
#   3. write the same option table to a JSON file and run
#      `mtc bindgen MODULE HEADER --options-json TABLE -o OUT`,
#   4. compare the two sources byte for byte (the header provenance line is
#      identical because both receive the resolved absolute header path).
#
# The host generation and the self invocation both use a temporary directory;
# checked-in files are never touched unless `--write` is passed (then the host
# output is written to `--write DIR`, or the binding path with `--in-place`).
#
# Usage:
#   ruby tools/bindgen_parity.rb [NAME...] [options]
#   --self PATH        self-host compiler binary (default: build/stage2/mtc)
#   --json FILE        write the per-binding result table as JSON
#   --max-diff N       lines of each first difference (default: 40)
#   -q, --quiet        print only the summary
#   --list             list the binding names and headers
#   -h, --help         show this message
#
# A binding registered with a host `generator:` lambda (tracy) returns a
# hand-written module rather than a generated one; it is reported as `custom`
# and not compared.
#
# Exit status: 0 when no selected binding differs or errors (custom entries
# are allowed), 1 otherwise.

require "json"
require "open3"
require "optparse"
require "tmpdir"
require "fileutils"

ROOT = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(ROOT, "lib"))
require "milk_tea"
require "milk_tea/bindings"

options = {
  self: File.join(ROOT, "build/stage2/mtc"),
  json: nil,
  max_diff: 40,
  quiet: false,
  list: false,
}
OptionParser.new do |opts|
  opts.on("--self PATH") { |v| options[:self] = File.expand_path(v, ROOT) }
  opts.on("--json FILE") { |v| options[:json] = File.expand_path(v, ROOT) }
  opts.on("--max-diff N", Integer) { |v| options[:max_diff] = v }
  opts.on("-q", "--quiet") { options[:quiet] = true }
  opts.on("--list") { options[:list] = true }
  opts.on("-h", "--help") { puts opts; exit 0 }
end.parse!
requested = ARGV.dup

registry = MilkTea::RawBindings.default_registry(root: MilkTea.root)
bindings = registry.to_a
bindings = bindings.select { |b| requested.include?(b.name) } unless requested.empty?

if options[:list]
  bindings.each { |b| puts "#{b.name}\t#{b.header_label}" }
  exit 0
end

abort "self-host binary not found: #{options[:self]}" unless File.executable?(options[:self])

def diff_summary(expected, actual, limit)
  a = expected.lines
  b = actual.lines
  index = 0
  index += 1 while index < a.length && index < b.length && a[index] == b[index]
  rows = []
  rows << "first difference at line #{index + 1}"
  rows << "  host: #{a[index].inspect}" if index < a.length
  rows << "  self: #{b[index].inspect}" if index < b.length
  a[index, limit].to_a.each_with_index { |line, offset| rows << "  -#{index + offset + 1}: #{line.rstrip}" }
  b[index, limit].to_a.each_with_index { |line, offset| rows << "  +#{index + offset + 1}: #{line.rstrip}" }
  rows.join("\n")
end

def option_table(binding, header_path)
  {
    "module_name" => binding.module_name,
    "header_path" => header_path,
    "link_libraries" => binding.link_libraries,
    "include_directives" => binding.include_directives,
    "bindgen_defines" => binding.bindgen_defines,
    "bindgen_include_directives" => binding.bindgen_include_directives,
    "module_imports" => binding.module_imports,
    "clang" => ENV.fetch("CLANG", "clang"),
    "clang_args" => binding.clang_args,
    "type_name_overrides" => binding.type_name_overrides,
    "type_overrides" => binding.type_overrides.transform_values(&:to_s),
    "function_param_type_overrides" => binding.function_param_type_overrides,
    "function_return_type_overrides" => binding.function_return_type_overrides.transform_values(&:to_s),
    "field_type_overrides" => binding.field_type_overrides.transform_values { |fields| fields.transform_values(&:to_s) },
    "tracked_header_paths" => binding.tracked_header_paths,
    "tracked_header_prefixes" => binding.tracked_header_prefixes,
    "declaration_name_prefixes" => binding.declaration_name_prefixes,
    "excluded_declaration_names" => binding.excluded_declaration_names,
    "allow_static_inline_functions" => binding.allow_static_inline_functions,
    "strip_leading_underscores" => binding.strip_leading_underscores,
  }
end

results = []
bindings.each do |binding|
  row = { "name" => binding.name, "status" => "error", "detail" => nil }
  begin
    binding.prepare!(env: ENV)
    header_path = binding.header_path(env: ENV)
    # A host custom generator (tracy) returns a hand-written checked-in module
    # rather than generating from the header; there is no generic reference.
    if binding.instance_variable_get(:@generator)
      row["status"] = "custom"
      row["detail"] = "host registry uses a custom generator"
      unless options[:quiet]
        puts "#{row['name']}: custom"
        puts row["detail"]
      end
      results << row
      next
    end
    expected = binding.generate(env: ENV, header_path:)

    Dir.mktmpdir("bindgen-parity") do |dir|
      table_path = File.join(dir, "options.json")
      output_path = File.join(dir, "self.mt")
      File.write(table_path, JSON.generate(option_table(binding, header_path)))
      command = [
        options[:self], "bindgen", binding.module_name, header_path,
        "--options-json", table_path, "-o", output_path,
      ]
      stdout, stderr, status = Open3.capture3(*command, chdir: ROOT)
      row["command"] = command.join(" ")
      if !status.success? || !File.file?(output_path)
        row["detail"] = (stderr.empty? ? stdout : stderr).strip.lines.first(5).join
        results << row
        next
      end
      actual = File.read(output_path)
      if expected == actual
        row["status"] = "match"
      else
        row["status"] = "differ"
        row["detail"] = diff_summary(expected, actual, options[:max_diff])
      end
    end
  rescue StandardError => e
    row["detail"] = "#{e.class}: #{e.message}"
  end
  results << row
  unless options[:quiet]
    puts "#{row['name']}: #{row['status']}"
    puts row["detail"] if row["detail"]
  end
end

matched = results.count { |r| r["status"] == "match" }
differed = results.count { |r| r["status"] == "differ" }
errored = results.count { |r| r["status"] == "error" }
custom = results.count { |r| r["status"] == "custom" }
puts "files=#{results.size} match=#{matched} differ=#{differed} error=#{errored} custom=#{custom}"
File.write(options[:json], JSON.pretty_generate(results)) if options[:json]
exit(differed.zero? && errored.zero? ? 0 : 1)
