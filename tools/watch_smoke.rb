#!/usr/bin/env ruby
# frozen_string_literal: true
#
# watch_smoke — prove the polling watch loop rebuilds a changed leaf module and
# reuses the other per-TU object-cache entries.  Optional --soak N repeats the
# edit and checks that the long-lived watcher's RSS and FD count stay flat.
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
  match = status.match(/^#{name}:\\s+(\\d+)/)
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

failures = []
Dir.mktmpdir("mtc-watch-gate-") do |dir|
  lib = File.join(dir, "lib.mt")
  main = File.join(dir, "main.mt")
  app = File.join(dir, "app")
  log_path = File.join(dir, "watch.log")
  File.write(lib, "public function value() -> int:\n    return 1\n")
  File.write(main, "import lib\n\nfunction main() -> int:\n    return lib.value()\n")
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
    failures << "initial run #{out.inspect}/#{status} (stderr=#{err.inspect})" unless out.empty? && status == 1
    baseline_rss = proc_metric(pid, "VmRSS")
    baseline_fds = fd_count(pid)

    expected_builds = 1
    soak.times do |iteration|
      value = iteration + 2
      File.write(lib, "public function value() -> int:\n    return #{value}\n")
      expected_builds += 1
      wait_until(30, "rebuild #{iteration + 1}") do
        File.read(log_path).scan("built ").length >= expected_builds
      end
      out, err, status = run_binary(app)
      unless out.empty? && status == value
        failures << "rebuild #{iteration + 1} #{out.inspect}/#{status} expected #{value} (stderr=#{err.inspect})"
        break
      end
    end

    log = File.read(log_path)
    if soak.positive? && !log.match?(/split: 2 object\(s\) reused, 1 compiled/)
      failures << "leaf edit did not reuse 2 objects and compile 1: #{log.lines.grep(/split:/).last.inspect}"
    end
    final_rss = proc_metric(pid, "VmRSS")
    final_fds = fd_count(pid)
    if final_rss > baseline_rss + 4096
      failures << "watcher RSS grew #{final_rss - baseline_rss} KiB across #{soak} rebuilds"
    end
    if final_fds > baseline_fds + 4
      failures << "watcher FD count grew #{final_fds - baseline_fds} across #{soak} rebuilds"
    end
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
    unless failures.empty?
      warn File.read(log_path)
      warn "watch log: #{log_path}"
    end
  end
end

if failures.empty?
  puts "watch smoke: initial build + #{soak} leaf rebuild(s) OK"
  exit 0
else
  failures.each { |failure| warn "FAIL: #{failure}" }
  exit 1
end
