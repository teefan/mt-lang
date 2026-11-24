#!/usr/bin/env ruby
# frozen_string_literal: true

# Capture the checked-in raw modules' nullable annotations as bindgen policies.
#
# `mtc bindgen` only emits `?` for a return/parameter when `--nullable-policy`
# supplies it, so regenerating a binding without this policy silently drops
# those annotations.  Run this before changing a vendored header, then pass
# bindings/nullable/<name>.json to `mtc bindgen`.
#
# Usage:
#   tools/nullable_policy_from_raw.rb [RAW.mt ...]
#
# With no arguments it scans std/c/*.mt and writes a policy only for modules
# that carry a nullable annotation.

require "fileutils"
require "json"

ROOT = File.expand_path("..", __dir__)
OUT_DIR = File.join(ROOT, "bindings", "nullable")

def split_params(text)
  parts = []
  current = +""
  depth = 0
  text.each_char do |ch|
    case ch
    when "(", "["
      depth += 1
      current << ch
    when ")", "]"
      depth -= 1
      current << ch
    when ","
      if depth.zero?
        parts << current.strip
        current = +""
      else
        current << ch
      end
    else
      current << ch
    end
  end
  parts << current.strip unless current.strip.empty?
  parts
end

def policy_for(path)
  return_types = {}
  parameters = {}

  File.foreach(path) do |line|
    match = line.chomp.match(/\Aexternal function ([A-Za-z_][A-Za-z0-9_]*)\((.*)\) -> (.+)\z/)
    next unless match

    function = match[1]
    return_type = match[3]
    return_types[function] = return_type if return_type.end_with?("?")

    split_params(match[2]).each do |param|
      name, type = param.split(": ", 2)
      next unless type&.end_with?("?")

      (parameters[function] ||= {})[name] = type
    end
  end

  { "return_types" => return_types, "parameters" => parameters }
end

files = ARGV.empty? ? Dir[File.join(ROOT, "std/c/*.mt")].sort : ARGV
written = 0

files.each do |path|
  policy = policy_for(path)
  next if policy["return_types"].empty? && policy["parameters"].empty?

  FileUtils.mkdir_p(OUT_DIR)
  name = File.basename(path, ".mt")
  out = File.join(OUT_DIR, "#{name}.json")
  File.write(out, "#{JSON.pretty_generate(policy)}\n")
  puts "#{path.delete_prefix("#{ROOT}/")} -> #{out.delete_prefix("#{ROOT}/")}"
  written += 1
end

puts "#{written} policy file(s)"
