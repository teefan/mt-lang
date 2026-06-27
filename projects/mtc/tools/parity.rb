#!/usr/bin/env ruby
# frozen_string_literal: true

# Differential parity harness for the self-hosted Milk Tea lexer/parser.
#
# Compares the self-host binary's JSON output against the authoritative Ruby
# CLI output (the contract), and classifies each divergence into:
#   ACCURACY - self-host is objectively wrong about the source (must fix)
#   SHAPE    - valid-but-different representation / wire-format mismatch (contract)
#   POSITION - line/column/offset divergence (depends on lexer position fidelity)
#
# Usage:
#   ruby projects/mtc/tools/parity.rb <lex|parse|both> [FILES_OR_GLOBS...] [opts]
#
# Options:
#   --ignore-positions   ignore line/column/*_offset/length (Parser Milestone A)
#   --build              rebuild the self-host binary first
#   --first N            show details for the first N failing files (default 3)
#   --max-diffs N        cap reported diffs per file (default 8)
#   --quiet              only print the summary
#
# Exit code is nonzero if any file diverges (after normalization).

require "json"
require "open3"
require "shellwords"

ROOT = File.expand_path("../../..", __dir__)
RUBY_MTC = File.join(ROOT, "bin", "mtc")
SELFHOST = File.join(ROOT, "projects", "mtc", "build", "bin", "linux", "debug", "mtc")
POSITION_KEYS = %w[line column start_offset end_offset length].freeze
SANDBOX_TIMEOUT = 10
SANDBOX_VMEM_KB = 2_000_000

def fail!(msg)
  warn("parity: #{msg}")
  exit 2
end

def parse_args(argv)
  opts = { ignore_positions: false, build: false, first: 3, max_diffs: 8, quiet: false }
  files = []
  stage = nil
  i = 0
  while i < argv.length
    a = argv[i]
    case a
    when "lex", "parse", "both" then stage = a
    when "--ignore-positions" then opts[:ignore_positions] = true
    when "--build" then opts[:build] = true
    when "--quiet" then opts[:quiet] = true
    when "--first" then i += 1; opts[:first] = Integer(argv[i])
    when "--max-diffs" then i += 1; opts[:max_diffs] = Integer(argv[i])
    else files.concat(Dir.glob(a).then { |g| g.empty? ? [a] : g })
    end
    i += 1
  end
  fail!("first arg must be lex|parse|both") unless stage
  files = Dir.glob(File.join(ROOT, "examples", "*.mt")).sort if files.empty?
  [stage, files, opts]
end

def run_ref(stage, file)
  out_path = "#{file}.#{stage}.ref.json"
  flag = stage == "lex" ? "--emit-tokens-json" : "--emit-ast-json"
  _o, e, st = Open3.capture3(RUBY_MTC, stage, file, flag, out_path)
  return [nil, "ruby #{stage} failed: #{e.lines.first}"] unless st.success? && File.exist?(out_path)

  json = File.read(out_path)
  [json, nil]
ensure
  File.delete(out_path) if out_path && File.exist?(out_path)
end

def run_selfhost(stage, file)
  inner = "ulimit -v #{SANDBOX_VMEM_KB}; exec #{Shellwords.escape(SELFHOST)} #{stage} #{Shellwords.escape(file)}"
  out, _e, st = Open3.capture3("timeout", SANDBOX_TIMEOUT.to_s, "bash", "-c", inner)
  code = st.exitstatus
  case code
  when 0 then [out, nil]
  when 124 then [nil, "self-host TIMED OUT (hang)"]
  when 137 then [nil, "self-host OOM/SIGKILL"]
  when 139 then [nil, "self-host SIGSEGV"]
  when 134 then [nil, "self-host SIGABRT"]
  else [nil, "self-host exit #{code}"]
  end
end

def position_key?(key)
  POSITION_KEYS.include?(key) || key.to_s =~ /_(line|column|offset)\z/
end

def classify(key, sv, rv)
  return :position if position_key?(key)
  return :shape if sv.nil? || rv.nil? || sv.class != rv.class

  :accuracy
end

def deep_diff(s, r, path, key, acc, opts)
  return if opts[:ignore_positions] && position_key?(key)

  if s.is_a?(Hash) && r.is_a?(Hash)
    (s.keys | r.keys).each do |k|
      next if path.empty? && k == "module_name" # harness/contract artifact, tracked separately
      next if opts[:ignore_positions] && position_key?(k)

      if !s.key?(k) || !r.key?(k)
        acc << { path: "#{path}.#{k}", kind: :shape, self: s.fetch(k, :__missing__), ruby: r.fetch(k, :__missing__) }
      else
        deep_diff(s[k], r[k], "#{path}.#{k}", k, acc, opts)
      end
    end
  elsif s.is_a?(Array) && r.is_a?(Array)
    acc << { path: "#{path}[len]", kind: :accuracy, self: s.length, ruby: r.length } if s.length != r.length
    [s.length, r.length].min.times { |i| deep_diff(s[i], r[i], "#{path}[#{i}]", key, acc, opts) }
  elsif s != r
    acc << { path: path.empty? ? "(root)" : path, kind: classify(key, s, r), self: s, ruby: r }
  end
end

def compare_file(stage, file, opts)
  ref_json, ref_err = run_ref(stage, file)
  return { file:, status: :ref_error, error: ref_err } if ref_err

  sh_json, sh_err = run_selfhost(stage, file)
  return { file:, status: :selfhost_error, error: sh_err } if sh_err

  begin
    ref = JSON.parse(ref_json)
    sh = JSON.parse(sh_json)
  rescue JSON::ParserError => e
    return { file:, status: :parse_error, error: e.message }
  end

  diffs = []
  deep_diff(sh, ref, "", nil, diffs, opts)
  buckets = diffs.group_by { |d| d[:kind] }.transform_values(&:length)
  { file:, status: diffs.empty? ? :pass : :diff, diffs:, buckets: }
end

def short(v)
  s = v == :__missing__ ? "(absent)" : v.inspect
  s.length > 80 ? "#{s[0, 77]}..." : s
end

stage_arg, files, opts = parse_args(ARGV)
stages = stage_arg == "both" ? %w[lex parse] : [stage_arg]

unless File.executable?(SELFHOST) || opts[:build]
  fail!("self-host binary missing: #{SELFHOST} (pass --build)")
end
if opts[:build]
  warn("parity: building self-host...")
  ok = system(RUBY_MTC, "build", File.join(ROOT, "projects", "mtc"))
  fail!("self-host build failed") unless ok
end

overall_fail = false
stages.each do |stage|
  results = files.map { |f| compare_file(stage, f, opts) }
  passed = results.count { |r| r[:status] == :pass }
  diffed = results.select { |r| r[:status] == :diff }
  errored = results.reject { |r| %i[pass diff].include?(r[:status]) }
  totals = Hash.new(0)
  diffed.each { |r| r[:buckets].each { |k, v| totals[k] += v } }

  puts "\n=== #{stage.upcase}  (#{files.length} files, ignore_positions=#{opts[:ignore_positions]}) ==="
  unless opts[:quiet]
    diffed.first(opts[:first]).each do |r|
      b = r[:buckets].map { |k, v| "#{k}:#{v}" }.join(" ")
      puts "\n  DIFF #{File.basename(r[:file])}  [#{b}]"
      r[:diffs].first(opts[:max_diffs]).each do |d|
        puts "    #{d[:kind].to_s.upcase.ljust(8)} #{d[:path]}"
        puts "        self=#{short(d[:self])}"
        puts "        ruby=#{short(d[:ruby])}"
      end
    end
    errored.first(opts[:first]).each { |r| puts "\n  ERROR #{File.basename(r[:file])}: #{r[:error]}" }
  end

  puts "\n  summary: #{passed} pass, #{diffed.length} diff, #{errored.length} error / #{files.length}"
  puts "  diff buckets: #{totals.map { |k, v| "#{k}=#{v}" }.join(', ')}" unless totals.empty?
  overall_fail = true unless diffed.empty? && errored.empty?
end

exit(overall_fail ? 1 : 0)
