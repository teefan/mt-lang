#!/usr/bin/env ruby
# frozen_string_literal: true

# One-stop parity scoreboard: runs the existing self-host vs Ruby host sweeps and
# prints a single counter table.  Thin wrapper — it shells the tools below and
# parses their summaries; it adds no comparison logic of its own.
#
# Usage:
#   ruby tools/parity_scoreboard.rb [options]
#   --self PATH      self-host compiler binary            (default: build/stage2/mtc)
#   --full           also run the slow sweeps (lower, format, LSP, DAP)
#   --json OUT       also write the counters as JSON
#   -h, --help       show this message
#
# Cheap sections: cli, lex, parse, lint.  --full adds: lower, format, lsp, dap.

require "fileutils"
require "json"
require "optparse"
require "open3"

ROOT = File.expand_path("..", __dir__)
LANG_BASELINE = "examples/language_baseline.mt"

options = { self: File.join(ROOT, "build/stage2/mtc"), full: false, json: nil }
OptionParser.new do |opts|
  opts.on("--self PATH") { |v| options[:self] = File.expand_path(v, ROOT) }
  opts.on("--full") { options[:full] = true }
  opts.on("--json OUT") { |v| options[:json] = v }
  opts.on("-h", "--help") { puts opts; exit 0 }
end.parse!

abort "self-host binary not found: #{options[:self]}" unless File.executable?(options[:self])

SELF = options[:self]
COUNTERS = {}

def run(*cmd, chdir: ROOT)
  out, status = Open3.capture2e(*cmd, chdir: chdir)
  [out, status.exitstatus]
end

def section(name)
  print format("%-7s ... ", name)
  $stdout.flush
  yield
rescue StandardError => error
  puts "ERROR: #{error.message}"
  COUNTERS[name] = { error: error.message }
end

def report(name, text)
  puts text
  COUNTERS[name] = text
end

section("cli") do
  out, = run("ruby", "tools/cli_parity.rb", "-q")
  m = out.match(/cases=(\d+) match=(\d+) differ=(\d+) pending=(\d+)/)
  raise "no cli:parity summary" unless m

  COUNTERS["cli"] = { cases: m[1].to_i, match: m[2].to_i, differ: m[3].to_i, pending: m[4].to_i }
  report("cli", "cases=#{m[1]} match=#{m[2]} differ=#{m[3]} pending=#{m[4]}")
end

%w[lex parse].each do |mode|
  section(mode) do
    out, = run("ruby", "tools/sexpr_parity.rb", mode, "-q", "-j", "16")
    m = out.match(/mode=\S+\s+files=(\d+)\s+match=(\d+)\s+differ=(\d+)\s+hostfail=(\d+)\s+selffail=(\d+)/)
    raise "no #{mode} summary" unless m

    COUNTERS[mode] = { files: m[1].to_i, match: m[2].to_i, differ: m[3].to_i, hostfail: m[4].to_i, selffail: m[5].to_i }
    report(mode, "files=#{m[1]} match=#{m[2]} differ=#{m[3]} hostfail=#{m[4]} selffail=#{m[5]}")
  end
end

section("lint") do
  host_out, = run("ruby", "-Ilib", "bin/mtc", "lint", LANG_BASELINE)
  self_out, = run(SELF, "lint", LANG_BASELINE)
  counts = lambda do |out|
    out.scan(/^\S+:\d+: ([a-z][a-z-]*): /).flatten.tally
  end
  host_counts = counts.call(host_out)
  self_counts = counts.call(self_out)
  codes = (host_counts.keys | self_counts.keys).sort
  diff_lines = (host_out.lines.sort - self_out.lines.sort).size + (self_out.lines.sort - host_out.lines.sort).size
  COUNTERS["lint"] = {
    file: LANG_BASELINE,
    host_total: host_counts.values.sum,
    self_total: self_counts.values.sum,
    differing_lines: diff_lines,
    per_code: codes.to_h { |code| [code, { host: host_counts[code] || 0, self: self_counts[code] || 0 }] },
  }
  mismatch = codes.reject { |code| (host_counts[code] || 0) == (self_counts[code] || 0) }
  report("lint", "#{LANG_BASELINE}: host #{host_counts.values.sum} / self #{self_counts.values.sum} warnings, " \
                "#{diff_lines} differing lines, #{mismatch.size} rules with count mismatch")
  codes.each do |code|
    h = host_counts[code] || 0
    s = self_counts[code] || 0
    marker = h == s ? " " : "*"
    puts format("  %s %-32s host %-4d self %-4d", marker, code, h, s)
  end
end

if options[:full]
  section("lower") do
    out, = run("ruby", "tools/sexpr_parity.rb", "lower", "-q", "-j", "16")
    m = out.match(/files=(\d+)\s+match=(\d+)\s+differ=(\d+)\s+hostfail=(\d+)\s+selffail=(\d+)/)
    raise "no lower summary" unless m

    COUNTERS["lower"] = { files: m[1].to_i, match: m[2].to_i, differ: m[3].to_i, hostfail: m[4].to_i, selffail: m[5].to_i }
    report("lower", "files=#{m[1]} match=#{m[2]} differ=#{m[3]} hostfail=#{m[4]} selffail=#{m[5]}")
  end

  section("format") do
    out, = run("ruby", "tools/format_parity.rb", "all", "-q", "-j", "16")
    modes = out.scan(/^(\w[\w-]*)\s+(\d+)\/(\d+) byte-identical(?:,\s+(\d+) differ)?/).to_h do |mode, match, files, differ|
      [mode, { match: match.to_i, files: files.to_i, differ: (differ || 0).to_i }]
    end
    raise "no format summary" if modes.empty?

    COUNTERS["format"] = modes
    report("format", modes.map { |mode, c| "#{mode} #{c[:match]}/#{c[:files]}#{c[:differ].positive? ? " differ=#{c[:differ]}" : ''}" }.join("  "))
  end

  section("lsp") do
    dir = File.join(ROOT, "tmp", "scoreboard")
    FileUtils.mkdir_p(dir)
    host_json = File.join(dir, "lsp-host.json")
    self_json = File.join(dir, "lsp-self.json")
    _, s1 = run("ruby", "tools/lsp_parity.rb", "record", "--server", "host", "--out", host_json, "--stress")
    _, s2 = run("ruby", "tools/lsp_parity.rb", "record", "--server", "self", "--self", SELF, "--out", self_json, "--stress")
    raise "lsp record failed (host=#{s1}, self=#{s2})" unless s1.zero? && s2.zero?

    out, = run("ruby", "tools/lsp_parity.rb", "compare", host_json, self_json, "--full")
    caps = out.match(/capabilities: (\d+) keys, (\d+) differ/)
    total = out.match(/TOTAL differing entries: (\d+)/)
    raise "no lsp comparison summary" unless caps && total

    COUNTERS["lsp"] = { capability_keys: caps[1].to_i, capability_diffs: caps[2].to_i, differing_entries: total[1].to_i }
    report("lsp", "capabilities #{caps[1]} (#{caps[2]} differ), differing entries #{total[1]}")
  end

  section("dap") do
    out, = run("ruby", "tools/dap_smoke.rb", "--server", "both")
    differing = out.lines.count { |line| line.start_with?("*") }
    COUNTERS["dap"] = { differing_requests: differing }
    report("dap", "differing requests #{differing}")
  end
end

if options[:json]
  path = File.expand_path(options[:json], ROOT)
  File.write(path, JSON.pretty_generate(COUNTERS) + "\n")
  puts "scoreboard written to #{path}"
end
