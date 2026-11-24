#!/usr/bin/env ruby
# frozen_string_literal: true

# Regenerate a raw binding from its checked-in option table and nullable policy.
#
# `bindings/raw/<name>.json` is the host-era option table (tracked headers,
# defines, overrides, module imports); `bindings/nullable/<name>.json` carries
# the `?` annotations that a bare bindgen run would otherwise drop.  The
# tables store machine-specific paths with a `$ROOT/` prefix.
#
# Usage:
#   tools/rebind_binding.rb NAME [--check|--write] [--self PATH] [--header PATH]
#   tools/rebind_binding.rb --all [--check|--write] [--self PATH]
#
# The default is --check: generate to a temporary file and diff the checked-in
# module.  --write updates std/c/<name>.mt.

require "json"
require "open3"
require "optparse"
require "tempfile"

ROOT = File.expand_path("..", __dir__)

options = {
  self: File.join(ROOT, "build", "stage2", "mtc"),
  check: true,
  all: false,
  header: nil,
  max_diff: 12,
}

OptionParser.new do |opts|
  opts.banner = "usage: tools/rebind_binding.rb NAME|--all [--check|--write] [--self PATH] [--header PATH]"
  opts.on("--self PATH", "compiler binary (default: build/stage2/mtc)") { |v| options[:self] = File.expand_path(v, ROOT) }
  opts.on("--header PATH", "override the table's header path") { |v| options[:header] = v }
  opts.on("--check", "diff instead of writing (default)") { options[:check] = true }
  opts.on("--write", "update std/c/<name>.mt") { options[:check] = false }
  opts.on("--all", "process every table under bindings/raw") { options[:all] = true }
  opts.on("--max-diff N", Integer, "lines of the first difference") { |v| options[:max_diff] = v }
  opts.on("-h", "--help") { puts opts; exit 0 }
end.parse!

names = ARGV.dup
names = Dir[File.join(ROOT, "bindings/raw/*.json")].map { |p| File.basename(p, ".json") }.sort if options[:all]
if names.empty?
  warn "rebind: name or --all required"
  exit 2
end
unless File.executable?(options[:self])
  warn "rebind: compiler not found: #{options[:self]}"
  exit 2
end

def expand(value)
  case value
  when String
    value.gsub("$ROOT", ROOT)
  when Array
    value.map { |v| expand(v) }
  when Hash
    value.transform_values { |v| expand(v) }
  else
    value
  end
end

def resolve_header(table, override)
  path = override || table["header_path"]
  return File.expand_path(path, ROOT) if path.start_with?("/")

  File.expand_path(path, ROOT)
end

def first_difference(expected, actual, limit)
  expected_lines = expected.lines
  actual_lines = actual.lines
  index = 0
  index += 1 while index < expected_lines.length && index < actual_lines.length && expected_lines[index] == actual_lines[index]
  rows = ["first difference at line #{index + 1}"]
  rows << "  expected: #{expected_lines[index].inspect}" if index < expected_lines.length
  rows << "  actual:   #{actual_lines[index].inspect}" if index < actual_lines.length
  expected_lines[index, limit].to_a.each_with_index { |line, i| rows << "  -#{index + i + 1}: #{line.rstrip}" }
  actual_lines[index, limit].to_a.each_with_index { |line, i| rows << "  +#{index + i + 1}: #{line.rstrip}" }
  rows.join("\n")
end

failures = 0
changed = 0
checked = 0

names.each do |name|
  table_path = File.join(ROOT, "bindings", "raw", "#{name}.json")
  unless File.file?(table_path)
    warn "#{name}: no option table at bindings/raw/#{name}.json"
    failures += 1
    next
  end

  table = expand(JSON.parse(File.read(table_path)))
  if table["custom"]
    puts "#{name}: custom binding, skipped"
    next
  end

  raw_path = File.join(ROOT, "std/c", "#{name}.mt")
  unless File.file?(raw_path)
    warn "#{name}: no raw module at std/c/#{name}.mt"
    failures += 1
    next
  end

  header = resolve_header(table, options[:header])
  unless File.file?(header)
    warn "#{name}: header not found: #{header} (run mtc toolchain bootstrap/prepare first)"
    failures += 1
    next
  end

  Tempfile.create(["options", ".json"]) do |options_file|
    options_file.write(JSON.generate(table))
    options_file.flush

    if options[:check]
      Tempfile.create(["#{name}", ".mt"]) do |out|
        command = [options[:self], "bindgen", table["module_name"], header,
                   "--options-json", options_file.path, "-o", out.path]
        policy = File.join(ROOT, "bindings", "nullable", "#{name}.json")
        command += ["--nullable-policy", policy] if File.file?(policy)
        stdout, stderr, status = Open3.capture3(*command, chdir: ROOT)
        unless status.success?
          warn "#{name}: FAIL"
          warn((stderr.empty? ? stdout : stderr).strip.lines.first(5).join)
          failures += 1
          next
        end

        expected = File.read(raw_path)
        actual = File.read(out.path)
        checked += 1
        if expected == actual
          puts "#{name}: OK"
        else
          changed += 1
          puts "#{name}: DIFF"
          puts first_difference(expected, actual, options[:max_diff])
        end
      end
    else
      command = [options[:self], "bindgen", table["module_name"], header,
                 "--options-json", options_file.path, "-o", raw_path]
      policy = File.join(ROOT, "bindings", "nullable", "#{name}.json")
      command += ["--nullable-policy", policy] if File.file?(policy)
      _stdout, stderr, status = Open3.capture3(*command, chdir: ROOT)
      unless status.success?
        warn "#{name}: FAIL"
        warn stderr.strip.lines.first(5).join
        failures += 1
        next
      end
      puts "#{name}: wrote std/c/#{name}.mt"
    end
  end
end

puts "rebind: checked=#{checked} changed=#{changed} failed=#{failures}"
exit(failures.zero? && (options[:check] ? changed.zero? : true) ? 0 : 1)
