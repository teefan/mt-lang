#!/usr/bin/env ruby
# frozen_string_literal: true

# lsp_token_diffs — compare the semantic-token streams of a `lsp_project_audit`
# JSON by *position*: every (line, start_char, length) key with its
# (type, modifiers), reported as host-only, self-only or differing entries.
#
# A token-index comparison misleads once the two streams shift (one missing token
# misaligns everything after it), so this tool keys by position.  The streams are
# long: `--count` prints only the per-file differing-position counts, which is
# what a set comparison across two audits needs.
#
# Usage:
#   ruby tools/lsp_token_diffs.rb AUDIT.json [WORKSPACE] [MAX-ROWS]
#   ruby tools/lsp_token_diffs.rb --count AUDIT.json

require "json"

LEGEND = %w[namespace type class enum interface struct typeParameter parameter variable property
            enumMember event function method macro keyword modifier comment string number regexp
            operator decorator].freeze

def decode(data)
  entries = {}
  line = 0
  char = 0
  i = 0
  while i < data.size
    delta_line, delta_char, length, type, mods = data[i, 5]
    line += delta_line
    char = delta_line.zero? ? char + delta_char : delta_char
    entries[[line, char, length]] = "#{LEGEND[type]}:#{mods}"
    i += 5
  end
  entries
end

count_only = ARGV.first == "--count"
json_path = count_only ? ARGV[1] : ARGV[0]
workspace = count_only ? "tmp" : (ARGV[1] || ".")
max_rows = (ARGV[2] || "8").to_i
abort "usage: lsp_token_diffs.rb [--count] AUDIT.json [WORKSPACE] [MAX-ROWS]" unless json_path

data = JSON.parse(File.read(json_path))
total = 0
data["entries"].each do |label, per_server|
  next unless label.end_with?("textDocument/semanticTokens/full")
  next if per_server["host"] == per_server["self"]

  file = label.split(" ").first
  host = decode(per_server.dig("host", "result", "data") || [])
  self_ = decode(per_server.dig("self", "result", "data") || [])
  diffs = (host.keys | self_.keys).select { |key| host[key] != self_[key] }.sort
  total += diffs.size
  if count_only
    printf("%-40s %5d differing positions (host %d tokens, self %d)\n", file, diffs.size, host.size, self_.size)
    next
  end

  source = File.readlines(File.join(workspace, file))
  puts "── #{file}: host #{host.size} tokens, self #{self_.size} tokens, #{diffs.size} differing positions"
  diffs.first(max_rows).each do |(line, char, length)|
    text = source[line] ? source[line][char, length].inspect : nil
    printf("   %4d:%-4d len %3d %-24s host=%-16s self=%s\n",
           line, char, length, text, host[[line, char, length]].inspect, self_[[line, char, length]].inspect)
  end
  puts "   ... #{diffs.size - max_rows} more" if diffs.size > max_rows
end
printf("TOTAL differing token positions: %d\n", total) if count_only
