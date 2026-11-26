#!/usr/bin/env ruby
# frozen_string_literal: true
#
# watch_smoke — prove the watch loop reuses ModuleCache analysis, compiles only
# the changed split TU, handles leaf/core/no-op edits, and does not accumulate
# RSS or descriptors across a 100-cycle soak.
#
# Usage:
#   tools/watch_smoke.rb [--self PATH] [--soak N]

require "fileutils"
require "open3"
require "tmpdir"
require "timeout"

ROOT = File.expand_path("..", __dir__)
self_bin = File.join(ROOT, "build/stage2/mtc")
soak = 0

argv = ARGV.dup
until argv.empty?
  arg = argv.shift
  case arg
  when "--self"
    self_bin = File.expand_path(argv.shift.to_s, ROOT)
  when "--soak"
    soak = Integer(argv.shift.to_s, 10)
  when "-h", "--help"
    puts "usage: tools/watch_smoke.rb [--self PATH] [--soak N]"
    exit 0
  else
    warn "error: unknown argument #{arg}"
    exit 2
  end
end

unless File.executable?(self_bin)
  warn "error: compiler not executable: #{self_bin}"
  exit 2
end

def wait_until(timeout, description)
  deadline = Time.now + timeout
  while Time.now < deadline
    return if yield
    sleep 0.05
  end
  raise "timed out waiting for #{description}"
end

def proc_metric(pid, name)
  status = File.read("/proc/#{pid}/status")
  match = status.match(/^#{name}:\s+(\d+)/)
  match ? match[1].to_i : 0
rescue Errno::ENOENT
  0
end

def fd_count(pid)
  Dir.children("/proc/#{pid}/fd").length
rescue Errno::ENOENT
  0
end

def run_binary(path)
  out, err, status = Open3.capture3(path)
  [out, err, status.exitstatus]
end

def last_cache_counts(log)
  matches = log.scan(/watch: cache parse=(\d+) analysis=(\d+)/)
  matches.empty? ? nil : matches.last.map(&:to_i)
end

def live_watchers(path)
  Dir["/proc/[0-9]*/cmdline"].filter_map do |cmdline|
    pid = File.basename(File.dirname(cmdline))
    next if pid == Process.pid.to_s

    args = File.binread(cmdline).split("\0")
    cmdline if args.include?(path)
  rescue Errno::ENOENT, Errno::EACCES
    nil
  end
end

failures = []
leaf_ms = nil
Dir.mktmpdir("mtc-watch-gate-") do |dir|
  lib = File.join(dir, "lib.mt")
  core = File.join(dir, "core.mt")
  main = File.join(dir, "main.mt")
  app = File.join(dir, "app")
  log_path = File.join(dir, "watch.log")
  File.write(lib, "public function value() -> int:\n    return 1\n")
  File.write(core, "public function base() -> int:\n    return 10\n")
  File.write(
    main,
    "import lib\nimport core\n\nfunction main() -> int:\n    return lib.value() + core.base()\n"
  )
  File.write(log_path, "")

  pid = Process.spawn(
    self_bin, "watch", main, "--split", "--interval", "50", "-o", app, "-I", dir,
    chdir: ROOT, out: log_path, err: [:child, :out], pgroup: true
  )

  begin
    wait_until(30, "initial build") do
      log = File.read(log_path)
      log.include?("watching") && File.executable?(app)
    end
    out, err, status = run_binary(app)
    failures << "initial run #{out.inspect}/#{status} expected 11 (stderr=#{err.inspect})" unless out.empty? && status == 11
    initial_cache = last_cache_counts(File.read(log_path))
    failures << "initial build did not report ModuleCache counters" if initial_cache.nil?
    baseline_rss = proc_metric(pid, "VmRSS")
    baseline_fds = fd_count(pid)

    # Leaf edit: only lib and its dependent main re-analyze.
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    File.write(lib, "public function value() -> int:\n    return 2\n")
    wait_until(30, "leaf rebuild") { File.read(log_path).scan("built ").length >= 2 }
    leaf_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    out, err, status = run_binary(app)
    failures << "leaf run #{out.inspect}/#{status} expected 12 (stderr=#{err.inspect})" unless out.empty? && status == 12
    leaf_cache = last_cache_counts(File.read(log_path))
    if initial_cache && leaf_cache && !(leaf_cache[0] > initial_cache[0] && leaf_cache[1] > initial_cache[1])
      failures << "leaf edit did not advance ModuleCache counters: #{initial_cache.inspect} -> #{leaf_cache.inspect}"
    end
    leaf_log = File.read(log_path)
    unless leaf_log.match?(/split: \d+ object\(s\) reused, 1 compiled/)
      failures << "leaf edit did not compile exactly one object: #{leaf_log.lines.grep(/split:/).last.inspect}"
    end

    # Core edit: an imported module outside the leaf changes.
    File.write(core, "public function base() -> int:\n    return 20\n")
    wait_until(30, "core rebuild") { File.read(log_path).scan("built ").length >= 3 }
    out, err, status = run_binary(app)
    failures << "core run #{out.inspect}/#{status} expected 22 (stderr=#{err.inspect})" unless out.empty? && status == 22
    core_cache = last_cache_counts(File.read(log_path))
    if leaf_cache && core_cache && !(core_cache[0] > leaf_cache[0] && core_cache[1] > leaf_cache[1])
      failures << "core edit did not advance ModuleCache counters: #{leaf_cache.inspect} -> #{core_cache.inspect}"
    end

    # No-op save: metadata changes, content does not.  The cache must not re-parse
    # or re-analyze, and every object must come from the object cache.
    File.write(lib, "public function value() -> int:\n    return 2\n")
    wait_until(30, "no-op rebuild") { File.read(log_path).scan("built ").length >= 4 }
    out, err, status = run_binary(app)
    failures << "no-op run #{out.inspect}/#{status} expected 22 (stderr=#{err.inspect})" unless out.empty? && status == 22
    noop_cache = last_cache_counts(File.read(log_path))
    failures << "no-op save re-parsed/re-analyzed: #{core_cache.inspect} -> #{noop_cache.inspect}" if core_cache && noop_cache && noop_cache != core_cache
    noop_log = File.read(log_path)
    unless noop_log.match?(/split: \d+ object\(s\) reused, 0 compiled/)
      failures << "no-op save did not reuse all objects: #{noop_log.lines.grep(/split:/).last.inspect}"
    end

    expected_builds = 4
    soak.times do |iteration|
      value = iteration + 3
      File.write(lib, "public function value() -> int:\n    return #{value}\n")
      expected_builds += 1
      wait_until(30, "soak rebuild #{iteration + 1}") do
        File.read(log_path).scan("built ").length >= expected_builds
      end
      out, err, status = run_binary(app)
      unless out.empty? && status == 20 + value
        failures << "soak #{iteration + 1} #{out.inspect}/#{status} expected #{20 + value} (stderr=#{err.inspect})"
        break
      end
    end

    final_rss = proc_metric(pid, "VmRSS")
    final_fds = fd_count(pid)
    if final_rss > baseline_rss + 4096
      failures << "watcher RSS grew #{final_rss - baseline_rss} KiB across #{soak} rebuilds"
    end
    if final_fds > baseline_fds + 4
      failures << "watcher FD count grew #{final_fds - baseline_fds} across #{soak} rebuilds"
    end
    failures << "leaf edit-to-build latency was #{leaf_ms} ms" if leaf_ms > 20_000
  rescue StandardError => e
    failures << e.message
  ensure
    begin
      Process.kill("TERM", -pid)
      Timeout.timeout(5) { Process.wait(pid) }
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    rescue Timeout::Error
      Process.kill("KILL", -pid) rescue nil
      Process.wait(pid) rescue nil
    end
    stale = live_watchers(main)
    failures << "stale watcher/build process remains: #{stale.inspect}" unless stale.empty?
    unless failures.empty?
      warn File.read(log_path)
      warn "watch log: #{log_path}"
    end
  end
end

if failures.empty?
  puts "watch smoke: initial + leaf + core + no-op + #{soak} rebuilds OK (leaf #{leaf_ms} ms)"
  exit 0
else
  failures.each { |failure| warn "FAIL: #{failure}" }
  exit 1
end
