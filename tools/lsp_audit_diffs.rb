#!/usr/bin/env ruby
# frozen_string_literal: true

# lsp_audit_diffs — summarize the differing entries of a `lsp_project_audit`
# JSON, and compare two audits' differing-key *sets* (the audit's per-method
# counters drift ±10 between runs because the host warms its caches as the audit
# proceeds, so a fix is verified by comparing sets of differing keys, not
# counts).
#
# Usage:
#   ruby tools/lsp_audit_diffs.rb AUDIT.json [METHOD-FILTER] [MAX-ROWS]
#   ruby tools/lsp_audit_diffs.rb --compare BEFORE.json AFTER.json [METHOD-FILTER]
#
# With one file: per-method totals and the differing entries' labels with the
# host/self payloads (truncated).  With `--compare`: per-method added / removed
# / still-differing keys, since a fix must close entries without adding any.

require "json"

def normalize(value, workspace)
  case value
  when Hash
    value.each_with_object({}) do |(k, v), out|
      next if k == "resultId"

      out[k] = normalize(v, workspace)
    end
  when Array
    value.map { |v| normalize(v, workspace) }
  when String
    value.gsub(workspace, "<WS>")
  else
    value
  end
end

def diff_entries(path)
  data = JSON.parse(File.read(path))
  workspace = data["workspace"] || ""
  by_method = Hash.new { |h, k| h[k] = { total: 0, diffs: [] } }
  data["entries"].each do |label, per_server|
    method = label.split(" ").last
    entry = by_method[method]
    entry[:total] += 1
    host = normalize(per_server["host"], workspace)
    self_ = normalize(per_server["self"], workspace)
    next if host == self_

    entry[:diffs] << [label, host, self_]
  end
  [data, by_method]
end

def differing_keys(path)
  data, by_method = diff_entries(path)
  workspace = data["workspace"] || ""
  out = {}
  data["entries"].each do |label, per_server|
    next if normalize(per_server["host"], workspace) == normalize(per_server["self"], workspace)

    out[label] = label.split(" ").last
  end
  out
end

if ARGV.first == "--compare"
  before_path = ARGV[1] or abort "usage: lsp_audit_diffs.rb --compare BEFORE.json AFTER.json [METHOD]"
  after_path = ARGV[2] or abort "usage: lsp_audit_diffs.rb --compare BEFORE.json AFTER.json [METHOD]"
  filter = ARGV[3]
  before = differing_keys(before_path)
  after = differing_keys(after_path)
  added = after.keys - before.keys
  removed = before.keys - after.keys
  added.sort.each { |key| puts "ADDED   #{key}" if !filter || key.include?(filter) }
  removed.sort.each { |key| puts "CLOSED  #{key}" if !filter || key.include?(filter) }
  printf("total differing entries: %d -> %d (closed %d, added %d)\n", before.size, after.size, removed.size, added.size)
  exit(added.empty? ? 0 : 1)
end

path = ARGV[0] or abort "usage: lsp_audit_diffs.rb AUDIT.json [METHOD-FILTER] [MAX-ROWS]"
filter = ARGV[1]
max_rows = (ARGV[2] || "50").to_i

_data, by_method = diff_entries(path)
total = by_method.values.sum { |entry| entry[:diffs].size }
by_method.sort.each do |method, entry|
  next if filter && !method.include?(filter)

  printf("%-4s %-42s %5d entries, %4d differ\n",
         entry[:diffs].empty? ? "ok" : "DIFF", method, entry[:total], entry[:diffs].size)
end
puts "TOTAL differing entries: #{total}"

shown = 0
by_method.sort.each do |method, entry|
  next if filter && !method.include?(filter)

  entry[:diffs].each do |label, host, self_|
    break if shown >= max_rows

    shown += 1
    puts "── #{label}"
    puts "   host: #{JSON.dump(host)[0, 400]}"
    puts "   self: #{JSON.dump(self_)[0, 400]}"
  end
end
