#!/usr/bin/env ruby
# frozen_string_literal: true

# Compare the self-host and Ruby host linters' *whole output* over a file set,
# file by file, and summarize the per-rule deltas.  `unused_import_parity.rb`
# guards one rule; this sweep is what caught the constant-condition solver's
# non-convergence (a 176-line file pinning a core for minutes) and it measures
# the corpus-wide rule residue the two-file scoreboard cannot see.
#
# Usage:
#   ruby tools/lint_parity.rb [TARGET...] [options]
#   TARGET           files or directories       (default: std examples projects/mtc/src)
#   --self PATH      self-host compiler binary  (default: build/stage2/mtc)
#   --host CMD       host compiler command      (default: ruby -Ilib bin/mtc)
#   -j N             parallel workers           (default: 8)
#   --timeout SEC    per-invocation timeout     (default: 180)
#   -q, --quiet      print only the summary
#   --max-files N    print at most N differing files (default: 20)
#   -h, --help       show this message
#
# Exit status: 0 when every file's output is byte-identical, 1 otherwise.

require "open3"
require "optparse"

ROOT = File.expand_path("..", __dir__)
options = {
  self: File.join(ROOT, "build/stage2/mtc"),
  host: ["ruby", "-Ilib", "bin/mtc", "lint"],
  jobs: 8,
  timeout: 180,
  quiet: false,
  max_files: 20,
}
OptionParser.new do |opts|
  opts.on("--self PATH") { |v| options[:self] = File.expand_path(v, ROOT) }
  opts.on("--host CMD") { |v| options[:host] = v.split }
  opts.on("-j N", Integer) { |v| options[:jobs] = v }
  opts.on("--timeout SEC", Integer) { |v| options[:timeout] = v }
  opts.on("-q", "--quiet") { options[:quiet] = true }
  opts.on("--max-files N", Integer) { |v| options[:max_files] = v }
  opts.on("-h", "--help") { puts opts; exit 0 }
end.parse!
targets = ARGV.empty? ? %w[std examples projects/mtc/src] : ARGV

abort "self-host binary not found: #{options[:self]}" unless File.executable?(options[:self])

files = targets.flat_map do |target|
  path = File.expand_path(target, ROOT)
  if File.directory?(path)
    Dir.glob(File.join(path, "**", "*.mt")).sort
  else
    [path]
  end
end

def lint_output(command, file, timeout)
  out, status = Open3.capture2e("timeout", timeout.to_s, *command, file, chdir: ROOT)
  status.exitstatus == 124 ? "<timeout after #{timeout}s>" : out
end

def rule_tally(text)
  text.lines.filter_map { |line| line[%r{^\S+\.mt:\d+: ([a-z-]+):}, 1] }.tally
end

results = Queue.new
files.each { |f| results << f }

diffs = []
mutex = Mutex.new
workers = Array.new(options[:jobs]) do
  Thread.new do
    loop do
      file = begin
        results.pop(true)
      rescue ThreadError
        break
      end
      host = lint_output(options[:host], file, options[:timeout])
      self_host = lint_output([options[:self], "lint"], file, options[:timeout])
      next if host == self_host

      mutex.synchronize { diffs << [file.delete_prefix("#{ROOT}/"), host, self_host] }
    end
  end
end
workers.each(&:join)

host_only = Hash.new(0)
self_only = Hash.new(0)
diffs.each do |_, host, self_host|
  ht = rule_tally(host)
  st = rule_tally(self_host)
  (ht.keys | st.keys).each do |rule|
    delta = st.fetch(rule, 0) - ht.fetch(rule, 0)
    if delta.positive?
      self_only[rule] += delta
    elsif delta.negative?
      host_only[rule] += -delta
    end
  end
end

unless options[:quiet]
  diffs.first(options[:max_files]).each do |relative, host, self_host|
    puts "#{relative}:"
    (host.lines - self_host.lines).first(3).each { |l| puts "  host-only: #{l.strip}" }
    (self_host.lines - host.lines).first(3).each { |l| puts "  self-only: #{l.strip}" }
  end
  puts "... #{diffs.size - options[:max_files]} more differing file(s)" if diffs.size > options[:max_files]
end

puts "--- warnings only the self reports (rule count)"
self_only.sort_by { |_, v| -v }.first(12).each { |k, v| puts format("  %-30s %6d", k, v) }
puts "--- warnings only the host reports (rule count)"
host_only.sort_by { |_, v| -v }.first(12).each { |k, v| puts format("  %-30s %6d", k, v) }
puts "files=#{files.size} agree=#{files.size - diffs.size} differ=#{diffs.size} (jobs=#{options[:jobs]})"
exit(diffs.empty? ? 0 : 1)
