#!/usr/bin/env ruby
# frozen_string_literal: true
#
# sexpr_parity — compare the self-host compiler's `lex|parse|lower --sexpr`
# output against the Ruby host compiler, byte for byte.
#
# The Ruby host is slow to start (~0.5s per process: startup + require), which
# dominates `lex`/`parse` and is a large fixed cost for `lower`.  So this tool
# loads `milk_tea` once in the parent, then forks workers that invoke the CLI
# in-process for a slice of the file list.  The self-host compiler is a native
# binary, so it is run once per file (startup is negligible) in parallel.
#
# Usage:
#   tools/sexpr_parity.rb [MODE] [TARGET...] [options]
#
#   MODE      lex | parse | lower | all        (default: all)
#   TARGET    files or directories             (default: repository root)
#
# Options:
#   --self PATH      self-host compiler binary  (default: build/stage2/mtc)
#   -j, --jobs N     parallel workers           (default: nproc)
#   -I, --include D  extra module root for `lower` (repeatable)
#   --timeout SEC    per self-host invocation timeout (default: 120)
#   --mem-mb MB      virtual-memory cap for the self-host binary (0 = off)
#   --max-diffs N    differing files to detail  (default: 20)
#   --keep           keep generated outputs and print their directory
#   -q, --quiet      print only the summary
#   -h, --help       show this message
#
# Exit status: 0 when every comparable file matches, 1 otherwise.

require "etc"
require "fileutils"
require "open3"
require "shellwords"
require "stringio"

ROOT = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(ROOT, "lib"))

MODES = %w[lex parse lower].freeze
EXCLUDE_DIRS = %w[.git .opencode build node_modules third_party tmp].freeze

def usage
  File.read(__FILE__).lines.drop(2).take_while { |l| l.start_with?("#") }
      .map { |l| l.sub(/\A# ?/, "") }.join
end

# ── options ──────────────────────────────────────────────────────────────────

mode = nil
targets = []
self_bin = nil
jobs = Etc.nprocessors
includes = []
timeout_s = 120
mem_mb = 0
max_diffs = 20
keep = false
quiet = false

argv = ARGV.dup
until argv.empty?
  a = argv.shift
  case a
  when "--self"     then self_bin = argv.shift
  when "-j", "--jobs" then jobs = argv.shift.to_i
  when "-I", "--include" then includes << argv.shift
  when "--timeout"  then timeout_s = argv.shift.to_i
  when "--mem-mb"   then mem_mb = argv.shift.to_i
  when "--max-diffs" then max_diffs = argv.shift.to_i
  when "--keep"     then keep = true
  when "-q", "--quiet" then quiet = true
  when "-h", "--help" then puts usage; exit 0
  else
    if mode.nil? && MODES.include?(a)
      mode = a
    else
      targets << a
    end
  end
end

mode ||= "all"
jobs = 1 if jobs < 1
modes = mode == "all" ? MODES : [mode]

self_bin ||= File.join(ROOT, "build", "stage2", "mtc")
self_bin = File.expand_path(self_bin)
unless File.executable?(self_bin)
  warn "error: self-host compiler not found or not executable: #{self_bin}"
  warn "       build one with: ruby -Ilib bin/mtc build projects/mtc -I . --no-cache -o #{self_bin}"
  exit 1
end

newest_src = Dir.glob(File.join(ROOT, "projects", "mtc", "src", "**", "*.mt"))
                .map { |f| File.mtime(f) }.max
if newest_src && File.mtime(self_bin) < newest_src
  warn "warning: #{self_bin} is older than the newest self-host source — rebuild it for accurate parity."
end

# ── file list ────────────────────────────────────────────────────────────────

def excluded?(path)
  parts = path.split(File::SEPARATOR)
  return true if parts.any? { |p| EXCLUDE_DIRS.include?(p) }
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

require "milk_tea"

unless quiet
  puts "host: ruby #{RUBY_VERSION} (milk_tea #{MilkTea::VERSION})"
  puts "self: #{self_bin} (built #{File.mtime(self_bin).strftime('%Y-%m-%d %H:%M')})"
end

# ── host / self invocation ───────────────────────────────────────────────────

def run_host(mode, file, includes)
  cmd = [mode, file]
  includes.each { |d| cmd += ["-I", d] } if mode == "lower"
  cmd << "--sexpr"
  out = StringIO.new
  err = StringIO.new
  rc = MilkTea::CLI.start(cmd, out: out, err: err)
  [out.string, err.string, rc]
end

def run_self(bin, mode, file, includes, timeout_s, mem_mb)
  cmd = [mode, file]
  if mode == "lower"
    roots = (MilkTea::ModuleRoots.roots_for_path(file) + includes).uniq
    roots.each { |d| cmd += ["-I", d] }
  end
  cmd << "--sexpr"

  full = [bin, *cmd]
  if mem_mb.positive?
    inner = full.map { |a| Shellwords.escape(a) }.join(" ")
    full = ["bash", "-c", "ulimit -v #{mem_mb * 1024}; exec #{inner}"]
  end
  full = ["timeout", timeout_s.to_s, *full]

  out, err, status = Open3.capture3(*full)
  [out, err, status.exitstatus]
end

# ── worker ───────────────────────────────────────────────────────────────────

def run_workers(mode, jobs, files, host_dir, self_dir, self_bin, includes, timeout_s, mem_mb)
  jobs = files.length if jobs > files.length
  pids = (0...jobs).map do |worker|
    fork do
      idx = worker
      while idx < files.length
        file = files[idx]
        begin
          out, herr, rc = run_host(mode, file, includes)
          File.binwrite(File.join(host_dir, "#{idx}.out"), out)
          File.write(File.join(host_dir, "#{idx}.err"), herr)
          File.write(File.join(host_dir, "#{idx}.rc"), rc.to_s)

          sout, serr, src = run_self(self_bin, mode, file, includes, timeout_s, mem_mb)
          File.binwrite(File.join(self_dir, "#{idx}.out"), sout)
          File.write(File.join(self_dir, "#{idx}.err"), serr)
          File.write(File.join(self_dir, "#{idx}.rc"), src.to_s)
        rescue => e
          File.write(File.join(host_dir, "#{idx}.rc"), "1")
          File.write(File.join(self_dir, "#{idx}.rc"), "1")
          File.write(File.join(self_dir, "#{idx}.err"), "harness error: #{e.class}: #{e.message}")
        end
        idx += jobs
      end
      exit!(0)
    end
  end
  pids.each { |pid| Process.wait(pid) }
end

# ── comparison ───────────────────────────────────────────────────────────────

def read_int(path)
  File.exist?(path) ? File.read(path).to_i : 1
end

def first_diff(a, b)
  n = [a.bytesize, b.bytesize].min
  i = 0
  i += 1 while i < n && a.getbyte(i) == b.getbyte(i)
  i
end

def snippet(bytes, at)
  text = bytes[[at - 60, 0].max, 180] || +""
  text.encode("UTF-8", invalid: :replace, undef: :replace).gsub(/[[:space:]]+/, " ").strip
end

# ── run ──────────────────────────────────────────────────────────────────────

overall_ok = true

modes.each do |mode|
  host_dir = File.join(ROOT, "tmp", "sexpr-parity", mode, "host")
  self_dir = File.join(ROOT, "tmp", "sexpr-parity", mode, "self")
  FileUtils.rm_rf(File.dirname(host_dir))
  FileUtils.mkdir_p(host_dir)
  FileUtils.mkdir_p(self_dir)

  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  run_workers(mode, jobs, files, host_dir, self_dir, self_bin, includes, timeout_s, mem_mb)
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

  match = 0
  differ = []
  hostfail = []
  selffail = []

  files.each_with_index do |file, idx|
    hrc = read_int(File.join(host_dir, "#{idx}.rc"))
    src = read_int(File.join(self_dir, "#{idx}.rc"))
    if hrc != 0
      hostfail << [idx, file]
    elsif src != 0
      selffail << [idx, file]
    else
      hout = File.binread(File.join(host_dir, "#{idx}.out"))
      sout = File.binread(File.join(self_dir, "#{idx}.out"))
      if hout == sout
        match += 1
      else
        differ << [file, hout, sout]
      end
    end
  end

  # A host-side rejection is not a self-host regression; a `differ` or a
  # `selffail` (self-host failed where the host succeeded) is.
  overall_ok = false if differ.any? || selffail.any?

  puts format("mode=%-5s files=%-4d match=%-4d differ=%-3d hostfail=%-3d selffail=%-3d (%.1fs, %d jobs)",
              mode, files.length, match, differ.length, hostfail.length, selffail.length, elapsed, jobs)

  next if quiet

  differ.take(max_diffs).each do |file, hout, sout|
    at = first_diff(hout, sout)
    puts "  DIFF #{file} @byte #{at}"
    puts "    host: #{snippet(hout, at)}"
    puts "    self: #{snippet(sout, at)}"
  end
  puts "  ... #{differ.length - max_diffs} more differing file(s)" if differ.length > max_diffs

  selffail.take(max_diffs).each do |idx, file|
    err_path = File.join(self_dir, "#{idx}.err")
    out_path = File.join(self_dir, "#{idx}.out")
    detail = File.exist?(err_path) ? File.read(err_path).strip : ""
    # The self-host `parse` command writes diagnostics to stdout, so fall back
    # to it when stderr is empty.
    if detail.empty? && File.exist?(out_path)
      detail = File.binread(out_path)[0, 200].to_s
                   .encode("UTF-8", invalid: :replace, undef: :replace).strip
    end
    puts "  SELF-FAIL #{file}: #{detail.lines.first(2).join.strip}"
  end
  hostfail.take(max_diffs).each do |idx, file|
    err_path = File.join(host_dir, "#{idx}.err")
    detail = File.exist?(err_path) ? File.read(err_path).strip.lines.first.to_s.strip : ""
    puts "  HOST-FAIL #{file}: #{detail}"
  end

  FileUtils.rm_rf(File.dirname(host_dir)) unless keep
end

puts "kept outputs under tmp/sexpr-parity/" if keep
exit(overall_ok ? 0 : 1)
