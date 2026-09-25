#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Count-based attribution of `lower --sexpr` divergences to concrete categories.

ROOT = "/home/teefan/Projects/Ruby/mt-lang"
MODE = ARGV[0] || "lower"
EXCLUDE_DIRS = %w[.git .opencode build node_modules third_party tmp].freeze
def excluded?(p) = p.split(File::SEPARATOR).any? { |x| EXCLUDE_DIRS.include?(x) } || p.include?("/bindings/vscode/")
files = Dir.glob(File.join(ROOT, "**", "*.mt")).reject { |f| excluded?(f) }.uniq.sort
base = File.join(ROOT, "tmp", "sexpr-parity", MODE)
def read_int(p) = File.exist?(p) ? File.read(p).to_i : 1
def cnt(t, s) = t.scan(s).length

# each check: name => [marker counted in host, marker counted in self]
CHECKS = {
  "int-literal ctx typing (ubyte)"          => [':type (Types::Primitive :name "ubyte")', ':type (Types::Primitive :name "ubyte")'],
  "guard else_body nil vs ()"               => [":else_body nil", ":else_body ()"],
  "ptr[void] as Primitive"                  => ['(Types::Primitive :name "ptr[void]")', '(Types::Primitive :name "ptr[void]")'],
  "module qual std.raylib vs std.c.raylib"  => [':module_name "std.c.raylib"', ':module_name "std.c.raylib"'],
  "enum member not folded (_dot_)"          => ["_dot_", "_dot_"],
  "IR::GotoStmt"                            => ["(IR::GotoStmt", "(IR::GotoStmt"],
  "proc (Types::Proc)"                      => ["(Types::Proc", "(Types::Proc"],
  "foreign temp naming"                     => ["__mt_foreign_cstr_", "__mt_foreign_cstr_"],
  "Types::Error leakage"                    => ["(Types::Error)", "(Types::Error)"],
  "StructInstance"                          => ["(Types::StructInstance", "(Types::StructInstance"],
  "VariantInstance"                         => ["(Types::VariantInstance", "(Types::VariantInstance"],
  "ZeroInit"                                => ["(IR::ZeroInit", "(IR::ZeroInit"],
  "Vector type"                             => ["(Types::Vector :name", "(Types::Vector :name"],
  ":setup field"                            => [":setup ", ":setup "],
  "addr_of/cast shape"                      => ["(IR::AddressOf", "(IR::AddressOf"],
  "extra LocalDecl (narrowing)"             => ["(IR::LocalDecl", "(IR::LocalDecl"],
  "IR::Constant count"                      => ["(IR::Constant", "(IR::Constant"],
  "IR::IfStmt count"                        => ["(IR::IfStmt", "(IR::IfStmt"],
  "IR::ReturnStmt count"                    => ["(IR::ReturnStmt", "(IR::ReturnStmt"],
  "IR::Name count"                          => ["(IR::Name", "(IR::Name"],
}.freeze

rows = []
files.each_with_index do |file, idx|
  next unless read_int(File.join(base, "host", "#{idx}.rc")) == 0
  next unless read_int(File.join(base, "self", "#{idx}.rc")) == 0
  hpath = File.join(base, "host", "#{idx}.out")
  spath = File.join(base, "self", "#{idx}.out")
  next unless File.exist?(hpath) && File.exist?(spath)
  h = File.binread(hpath)
  s = File.binread(spath)
  next if h == s

  hits = []
  CHECKS.each do |name, (hm, sm)|
    hits << name if cnt(h, hm) != cnt(s, sm)
  end
  # include header sequence
  hits << "include set/order" if h.scan(/:header "([^"]*)"/).flatten != s.scan(/:header "([^"]*)"/).flatten
  rows << [file, hits, h.bytesize]
end

counts = Hash.new(0)
rows.each { |_, hits, _| hits.each { |k| counts[k] += 1 } }
puts "=== #{MODE}: #{rows.length} differing files"
puts "\n=== category frequency"
counts.sort_by { |_, v| -v }.each { |k, v| puts format("  %-4d  %s", v, k) }

unknown = rows.select { |_, hits, _| hits.length > 12 }
puts "\n=== files with >12 categories (likely dominated by a systemic issue): #{unknown.length}"
unknown.first(12).each { |f, hits, sz| puts "    #{f.sub(ROOT + '/', '')} (#{hits.length} cats, #{sz} B)" }

only = Hash.new { |h, k| h[k] = [] }
rows.each { |f, hits, _| only[hits.sort.join(" + ")] << f if hits.length <= 2 && hits.any? }
puts "\n=== combinations of <=2 categories, with file counts"
only.sort_by { |_, v| -v.length }.first(20).each do |k, v|
  puts format("  %-4d  %s", v.length, k)
  v.first(3).each { |f| puts "          #{f.sub(ROOT + '/', '')}" }
end

solo_targets = Hash.new { |h, k| h[k] = [] }
rows.each { |f, hits, _| solo_targets[hits.first] << f if hits.length == 1 }
puts "\n=== files explained by exactly ONE category"
solo_targets.sort_by { |_, v| -v.length }.each do |k, v|
  puts format("  %-4d  %s", v.length, k)
end
