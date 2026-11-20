#!/usr/bin/env ruby
# frozen_string_literal: true
#
# format_parity — compare the self-host formatter (`mtc format`) against the
# Ruby host's `MilkTea::Formatter` for the CST-backed modes, byte for byte.
#
# The host formatter runs in-process (one `require "milk_tea"` for the whole
# sweep); the self-host is a native binary, invoked once per file with a
# timeout and an optional virtual-memory cap.
#
# Modes:
#   preserve   CST reconstruct (verbatim)
#   tidy       CST normalize + long-line wrap + blank-line rules
#   canonical  AST pretty printer (`safe` behaves the same)
#
# Usage:
#   tools/format_parity.rb [MODE...] [TARGET...] [options]
#
#   MODE      preserve | tidy | canonical | all   (default: all)
#   TARGET    files or directories                (default: repository root)
#
# Options:
#   --self PATH      self-host compiler binary  (default: build/stage2/mtc)
#   -j, --jobs N     parallel workers           (default: 4, hard-capped)
#   --timeout SEC    per self-host invocation timeout (default: 30)
#   --mem-mb MB      virtual-memory cap for the self-host binary (0 = off)
#   --max-diffs N    differing files to detail  (default: 20)
#   --keep           keep generated outputs and print their directory
#   --record FILE    record the self's per-mode output hashes to FILE (host-free)
#   --expect FILE    replay FILE and fail on any difference (host-free)
#   -q, --quiet      print only the summary
#   -h, --help       show this message
#
# Exit status: 0 when every comparable file matches, 1 otherwise.

require "digest"
require "etc"
require "fileutils"
require "open3"
require "shellwords"
require_relative "lib/golden"
require_relative "lib/jobs"

ROOT = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(ROOT, "lib"))

MODES = %w[preserve tidy canonical].freeze
HOST_MODES = { "preserve" => :preserve, "tidy" => :tidy, "canonical" => :safe }.freeze
EXCLUDE_DIRS = %w[.git .opencode build dist node_modules third_party tmp].freeze

def usage
  File.read(__FILE__).lines.drop(2).take_while { |l| l.start_with?("#") }
      .map { |l| l.sub(/\A# ?/, "") }.join
end

# ── options ──────────────────────────────────────────────────────────────────

modes = []
targets = []
self_bin = nil
jobs = [Etc.nprocessors, Jobs::MAX].min
timeout_s = 30
mem_mb = 0
max_diffs = 20
keep = false
quiet = false
record_path = nil
expect_path = nil

argv = ARGV.dup
until argv.empty?
  a = argv.shift
  case a
  when "--self"     then self_bin = argv.shift
  when "-j", "--jobs" then jobs = argv.shift.to_i
  when "--timeout"  then timeout_s = argv.shift.to_i
  when "--mem-mb"   then mem_mb = argv.shift.to_i
  when "--max-diffs" then max_diffs = argv.shift.to_i
  when "--keep"     then keep = true
  when "-q", "--quiet" then quiet = true
  when "--record"   then record_path = argv.shift
  when "--expect"   then expect_path = argv.shift
  when "-h", "--help" then puts usage; exit 0
  else
    if MODES.include?(a)
      modes << a
    elsif a == "all"
      modes = MODES.dup
    else
      targets << a
    end
  end
end

modes = MODES.dup if modes.empty?
modes.uniq!
jobs = Jobs.clamp(jobs)

self_bin ||= File.join(ROOT, "build", "stage2", "mtc")
self_bin = File.expand_path(self_bin)
unless File.executable?(self_bin)
  warn "error: self-host compiler not found or not executable: #{self_bin}"
  warn "       build one with: ruby -Ilib bin/mtc build projects/mtc -I . --no-cache -o #{self_bin}"
  exit 1
end

record_path = File.expand_path(record_path, ROOT) if record_path
expect_path = File.expand_path(expect_path, ROOT) if expect_path
if record_path && expect_path
  warn "error: --record and --expect are mutually exclusive"
  exit 1
end
recorded = !record_path.nil? || !expect_path.nil?

newest_src = Dir.glob(File.join(ROOT, "projects", "mtc", "src", "**", "*.mt"))
                .map { |f| File.mtime(f) }.max
if newest_src && File.mtime(self_bin) < newest_src
  warn "warning: #{self_bin} is older than the newest self-host source — rebuild it for accurate parity."
end

# ── file list ────────────────────────────────────────────────────────────────

def excluded?(path)
  parts = path.split(File::SEPARATOR)
  return true if parts.any? { |p| EXCLUDE_DIRS.include?(p) }
  return true if path.include?("test/mt/diagnostics/")

  path.include?("/bindings/vscode/")
end

def expand_targets(targets)
  files = []
  targets.each do |t|
    if File.directory?(t)
      Dir.glob(File.join(t, "**", "*.mt")).each { |f| files << f unless excluded?(f) }
    elsif File.exist?(t)
      files << t
    else
      warn "warning: target does not exist: #{t}"
    end
  end
  files.map { |f| f.sub(%r{\A\./}, "") }.uniq.sort
end

targets = [ROOT] if targets.empty?
files = expand_targets(targets)
if files.empty?
  warn "error: no .mt files found"
  exit 1
end

require "milk_tea" unless recorded

unless quiet
  if recorded
    puts "self: #{self_bin} (built #{File.mtime(self_bin).strftime('%Y-%m-%d %H:%M')})"
  else
    puts "host: ruby #{RUBY_VERSION} (milk_tea #{MilkTea::VERSION})"
    puts "self: #{self_bin} (built #{File.mtime(self_bin).strftime('%Y-%m-%d %H:%M')})"
  end
end

# ── host / self invocation ───────────────────────────────────────────────────

def run_host(mode, file)
  source = File.read(file)
  result = MilkTea::Formatter.check_source(source, path: file, mode: HOST_MODES.fetch(mode))
  [result.formatted_source, nil]
rescue StandardError => e
  [nil, "#{e.class}: #{e.message}"]
end

def run_self(bin, mode, file, timeout_s, mem_mb)
  full = [bin, "format", "--#{mode}", file]
  if mem_mb.positive?
    inner = full.map { |a| Shellwords.escape(a) }.join(" ")
    full = ["bash", "-c", "ulimit -v #{mem_mb * 1024}; exec #{inner}"]
  end
  full = ["timeout", timeout_s.to_s, *full]

  out, err, status = Open3.capture3(*full)
  rc = status.exitstatus || (128 + status.termsig.to_i)
  [out, rc, err]
end

# ── worker ───────────────────────────────────────────────────────────────────

def run_workers(mode, jobs, files, host_dir, self_dir, self_bin, timeout_s, mem_mb)
  jobs = files.length if jobs > files.length
  pids = (0...jobs).map do |worker|
    fork do
      require "milk_tea"
      idx = worker
      while idx < files.length
        file = files[idx]
        begin
          hout, herr = run_host(mode, file)
          if herr
            File.write(File.join(host_dir, "#{idx}.err"), herr)
          else
            File.binwrite(File.join(host_dir, "#{idx}.out"), hout)
          end

          sout, src, serr = run_self(self_bin, mode, file, timeout_s, mem_mb)
          if src.zero?
            File.binwrite(File.join(self_dir, "#{idx}.out"), sout)
          else
            File.write(File.join(self_dir, "#{idx}.err"), "#{serr}\n(exit #{src})")
          end
        rescue => e
          File.write(File.join(host_dir, "#{idx}.err"), "harness error: #{e.class}: #{e.message}")
          File.write(File.join(self_dir, "#{idx}.err"), "harness error: #{e.class}: #{e.message}")
        end
        idx += jobs
      end
      exit!(0)
    end
  end
  pids.each { |pid| Process.wait(pid) }
end

# Recorded mode: no host process at all.  The self's output is hashed per
# (file, mode) and compared with the committed fixture.
def run_self_workers(mode, jobs, files, self_dir, self_bin, timeout_s, mem_mb)
  jobs = files.length if jobs > files.length
  pids = (0...jobs).map do |worker|
    fork do
      idx = worker
      while idx < files.length
        file = files[idx]
        sout, src, serr = run_self(self_bin, mode, file, timeout_s, mem_mb)
        if src.zero?
          File.binwrite(File.join(self_dir, "#{idx}.out"), sout)
        else
          File.write(File.join(self_dir, "#{idx}.err"), "#{serr}\n(exit #{src})")
        end
        idx += jobs
      end
      exit!(0)
    end
  end
  pids.each { |pid| Process.wait(pid) }
end

# ── comparison ───────────────────────────────────────────────────────────────

def first_diff(a, b)
  n = [a.bytesize, b.bytesize].min
  i = 0
  i += 1 while i < n && a.getbyte(i) == b.getbyte(i)
  i
end

def line_of(bytes, at)
  bytes[0...at].count("\n") + 1
end

def snippet(bytes, at)
  text = bytes[at, 120] || +""
  text.encode("UTF-8", invalid: :replace, undef: :replace).gsub(/[[:space:]]+/, " ").strip
end

# ── run ──────────────────────────────────────────────────────────────────────

overall_ok = true
recorded_data = {}

# A golden fixture is digest-keyed: a file whose text changed since recording is
# skipped (its row is stale by design), so source edits do not turn the gate
# red.  Only unchanged inputs are re-measured against the fixture.
golden_expected = nil
changed_inputs = 0
unrecorded_inputs = 0
if recorded && expect_path
  golden_expected = Golden.read(expect_path, "format_parity")
  first_mode = golden_expected["files"].values.first || {}
  selected = []
  files.each do |file|
    relative = file.delete_prefix("#{ROOT}/")
    row = first_mode[relative]
    if row.nil?
      unrecorded_inputs += 1
    elsif row["digest"] == Digest::SHA256.file(file).hexdigest
      selected << file
    else
      changed_inputs += 1
    end
  end
  files = selected
end

modes.each do |mode|
  host_dir = File.join(ROOT, "tmp", "format-parity", mode, "host")
  self_dir = File.join(ROOT, "tmp", "format-parity", mode, "self")
  FileUtils.rm_rf(File.dirname(host_dir))
  FileUtils.mkdir_p(host_dir)
  FileUtils.mkdir_p(self_dir)

  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  if recorded
    run_self_workers(mode, jobs, files, self_dir, self_bin, timeout_s, mem_mb)
  else
    run_workers(mode, jobs, files, host_dir, self_dir, self_bin, timeout_s, mem_mb)
  end
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

  if recorded
    rows = {}
    files.each_with_index do |file, idx|
      self_out = File.join(self_dir, "#{idx}.out")
      err_path = File.join(self_dir, "#{idx}.err")
      rows[file.delete_prefix("#{ROOT}/")] =
        if File.exist?(err_path) || !File.exist?(self_out)
          {
            "digest" => Digest::SHA256.file(file).hexdigest,
            "error" => File.read(err_path).lines.first.to_s.strip
                                            .gsub(ROOT, "<ROOT>").gsub(self_bin, "<SELF>"),
          }
        else
          {
            "digest" => Digest::SHA256.file(file).hexdigest,
            "sha256" => Digest::SHA256.hexdigest(File.binread(self_out)),
          }
        end
    end
    recorded_data[mode] = rows
    puts format("%-10s %3d file(s) recorded (%.1fs)", mode, files.length, elapsed) unless quiet
    next
  end

  match = 0
  differ = []
  host_rejected = []
  self_rejected = []

  files.each_with_index do |file, idx|
    host_out = File.join(host_dir, "#{idx}.out")
    self_out = File.join(self_dir, "#{idx}.out")
    host_failed = File.exist?(File.join(host_dir, "#{idx}.err")) || !File.exist?(host_out)
    self_failed = File.exist?(File.join(self_dir, "#{idx}.err")) || !File.exist?(self_out)

    if host_failed && self_failed
      match += 1
    elsif host_failed
      host_rejected << file
    elsif self_failed
      self_rejected << [file, File.read(File.join(self_dir, "#{idx}.err")).lines.first.to_s.strip]
    else
      a = File.binread(host_out)
      b = File.binread(self_out)
      if a == b
        match += 1
      else
        at = first_diff(a, b)
        differ << [file, line_of(a, at), snippet(a, at), snippet(b, at)]
      end
    end
  end

  ok = differ.empty? && self_rejected.empty?
  overall_ok &&= ok

  unless quiet
    printf("%-10s %3d/%3d byte-identical", mode, match, files.length)
    printf(", %d host-rejected", host_rejected.size) if host_rejected.any?
    printf(", %d self-rejected", self_rejected.size) if self_rejected.any?
    printf(", %d differ", differ.size) if differ.any?
    printf("  (%.1fs)\n", elapsed)
  end

  host_rejected.first(5).each { |f| puts "  host-rejected: #{f}" } unless quiet
  self_rejected.first(max_diffs).each { |f, e| puts "  SELF-REJECTED #{f}: #{e}" } unless quiet
  differ.first(max_diffs).each do |f, ln, h, s|
    puts "  ── #{f} (line #{ln})"
    puts "     host: #{h}"
    puts "     self: #{s}"
  end unless quiet
end

if recorded
  payload = { "modes" => modes, "files" => recorded_data }
  if record_path
    Golden.write(record_path, "format_parity", payload)
    puts "recorded #{modes.length} mode(s) over #{files.length} file(s) -> #{record_path}" unless quiet
    exit 0
  end

  expected = {}
  actual = {}
  recorded_data.each do |mode, rows|
    expected[mode] = {}
    actual[mode] = {}
    rows.each do |relative, row|
      recorded_row = golden_expected["files"].dig(mode, relative)
      expected[mode][relative] = recorded_row.reject { |key, _| key == "digest" }
      actual[mode][relative] = row.reject { |key, _| key == "digest" }
    end
  end
  diffs = Golden.diff(expected, actual)
  puts "modes=#{modes.length} files=#{files.length} changed=#{changed_inputs} " \
       "unrecorded=#{unrecorded_inputs} differ=#{diffs.length}"
  diffs.first(max_diffs * 2).each { |line| puts "  #{line}" }
  exit(diffs.empty? ? 0 : 1)
end

if keep
  puts "outputs kept under #{File.join(ROOT, 'tmp', 'format-parity')}"
else
  FileUtils.rm_rf(File.join(ROOT, "tmp", "format-parity"))
end

exit(overall_ok ? 0 : 1)
