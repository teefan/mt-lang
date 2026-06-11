#!/usr/bin/env ruby
# Standalone test: verifies findReferences for main() returns 1 ref, not 227.
# Run: ruby test_references.rb

$LOAD_PATH.unshift(File.expand_path("lib", __dir__))
require "milk_tea"

uri = "file:///home/teefan/Projects/Ruby/mt-lang/examples/raylib/others/raylib_opengl_interop.mt"
path = "/home/teefan/Projects/Ruby/mt-lang/examples/raylib/others/raylib_opengl_interop.mt"

puts "=== Setting up LSP workspace ==="
server = MilkTea::LSP::Server.new
workspace = server.instance_variable_get(:@workspace)

puts "Indexing workspace…"
workspace.index_workspace("file:///home/teefan/Projects/Ruby/mt-lang")

puts "Opening document…"
workspace.open_document(uri, File.read(path))

puts ""
puts "=== Triggering textDocument/references for main at line 39 ==="
params = {
  "textDocument" => { "uri" => uri },
  "position" => { "line" => 38, "character" => 9 },
  "context" => { "includeDeclaration" => true }
}

result = server.instance_eval { handle_references(params) }

puts ""
puts "=== Results ==="
puts "Total references: #{result.length}"
if result.length <= 10
  result.each_with_index do |r, i|
    puts "  #{i + 1}. #{r[:uri].sub("file:///home/teefan/Projects/Ruby/mt-lang/", "")} L#{r.dig(:range, :start, :line)}"
  end
else
  puts "  (showing first 5 of #{result.length})"
  result.first(5).each_with_index do |r, i|
    puts "  #{i + 1}. #{r[:uri].sub("file:///home/teefan/Projects/Ruby/mt-lang/", "")} L#{r.dig(:range, :start, :line)}"
  end
end

puts ""
if result.length <= 1
  puts "OK: module-level-scoped reference search is working."
else
  puts "BUG: text fallback returned #{result.length} cross-file false positives."
end
