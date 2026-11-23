#!/usr/bin/env ruby
# frozen_string_literal: true
#
# format_parity — replay the compiler's formatter oracle: the per-mode output
# hash (or its error) for every `.mt` file, against a digest-keyed fixture.
#
# Modes:
#   preserve   CST reconstruct (verbatim)
#   tidy       CST normalize + long-line wrap + blank-line rules
#   canonical  AST pretty printer (`safe` behaves the same)
#
# Usage:
#   tools/format_parity.rb [MODE...] [TARGET...] --expect FILE [options]
#   tools/format_parity.rb [MODE...] [TARGET...] --record FILE [options]
#
#   MODE      preserve | tidy | canonical | all   (default: all)
#   TARGET    files or directories                (default: repository root)
#
# Options:
#   --self PATH      compiler binary            (default: build/stage2/mtc)
#   -j, --jobs N     parallel workers           (default: 4, hard-capped)
#   --timeout SEC    per-invocation timeout     (default: 30)
#   --mem-mb MB      virtual-memory cap (0 = off)
#   --max-diffs N    differing files to detail  (default: 20)
#   --keep           keep generated outputs and print their directory
#   --record FILE    record the per-mode output hashes to FILE
#   --expect FILE    replay FILE and fail on any difference
#   -q, --quiet      print only the summary
#   -h, --help       show this message
#
# Exit status: 0 when every compared file matches, 1 otherwise.

require "digest"
require "etc"
require "fileutils"
require "shellwords"
require "tmpdir"
require_relative "lib/golden"
require_relative "lib/jobs"

ROOT = File.expand_path("..", __dir__)

MODES = %w[preserve tidy canonical].freeze
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
  warn "error: compiler not found or not executable: #{self_bin}"
  warn "       build it with tools/bootstrap.sh -j 4"
  exit 1
end

record_path = File.expand_path(record_path, ROOT) if record_path
expect_path = File.expand_path(expect_path, ROOT) if expect_path
if record_path && expect_path
  warn "error: --record and --expect are mutually exclusive"
  exit 1
end
unless record_path || expect_path
  warn "error: pass --expect FILE to replay the oracle or --record FILE to refresh it"
  exit 1
end

newest_src = Dir.glob(File.join(ROOT, "projects", "mtc", "src", "**", "*.mt"))
                .map { |f| File.mtime(f) }.max
if newest_src && File.mtime(self_bin) < newest_src
  warn "warning: #{self_bin} is older than the newest self-host source — rebuild it for accurate replay."
end

# ── file list ────────────────────────────────────────────────────────────────

def excluded?(path)
  # Only repository-relative components are exclusions; an external target under
  # `/tmp/...` must not be rejected because an ancestor happens to be named tmp.
  return false unless path.start_with?("#{ROOT}/")

  relative = path.delete_prefix("#{ROOT}/")
  parts = relative.split(File::SEPARATOR)
  return true if parts.any? { |p| EXCLUDE_DIRS.include?(p) }
  return true if relative.start_with?("test/mt/diagnostics/")

  relative.start_with?("bindings/vscode/")
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

unless quiet
  puts "self: #{self_bin} (built #{File.mtime(self_bin).strftime('%Y-%m-%d %H:%M')})"
end

# ── self invocation ──────────────────────────────────────────────────────────

def run_self(bin, mode, file, timeout_s, mem_mb)
  full = [bin, "format", "--#{mode}", file]
  if mem_mb.positive?
    inner = full.map { |a| Shellwords.escape(a) }.join(" ")
    full = ["bash", "-c", "ulimit -v #{mem_mb * 1024}; exec #{inner}"]
  end
  full = ["timeout", timeout_s.to_s, *full]

  # A spawn/wait run, not Open3: Open3's reader threads trip a Ruby 4.0 VM
  # teardown segfault on a long sweep (diag_parity/lint_parity use the same).
  out_path = File.join(Dir.tmpdir, "mtc-format-#{Process.pid}.out")
  err_path = File.join(Dir.tmpdir, "mtc-format-#{Process.pid}.err")
  FileUtils.rm_f([out_path, err_path])
  pid = Process.spawn(*full, out: out_path, err: err_path)
  _pid, status = Process.wait2(pid)
  rc = status.exitstatus || (128 + status.termsig.to_i)
  out = File.binread(out_path).force_encoding(Encoding::UTF_8)
  err = File.binread(err_path).force_encoding(Encoding::UTF_8)
  FileUtils.rm_f([out_path, err_path])
  [out, rc, err]
end

# ── worker ───────────────────────────────────────────────────────────────────

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

# ── run ──────────────────────────────────────────────────────────────────────

recorded_data = {}

# A golden fixture is digest-keyed: a file whose text changed since recording is
# skipped (its row is stale by design), so source edits do not turn the gate
# red.  Only unchanged inputs are re-measured against the fixture.
golden_expected = nil
changed_inputs = 0
unrecorded_inputs = 0
if expect_path
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
  self_dir = File.join(ROOT, "tmp", "format-parity", mode, "self")
  FileUtils.rm_rf(File.dirname(self_dir))
  FileUtils.mkdir_p(self_dir)

  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  run_self_workers(mode, jobs, files, self_dir, self_bin, timeout_s, mem_mb)
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

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
end

if record_path
  payload = { "modes" => modes, "files" => recorded_data }
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

if keep
  puts "outputs kept under #{File.join(ROOT, 'tmp', 'format-parity')}"
else
  FileUtils.rm_rf(File.join(ROOT, "tmp", "format-parity"))
end

exit(diffs.empty? ? 0 : 1)
