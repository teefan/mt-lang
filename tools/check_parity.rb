#!/usr/bin/env ruby
# frozen_string_literal: true

# Compare the self-host and Ruby host `check` output over a file set.
#
# `check` is the only command that surfaces the *semantic analyzer's* verdict
# (type errors, assignability, immutability) plus the full lint pass, so it is
# the differential oracle for analyzer parity.  The other sweeps cannot see
# this class: `sexpr_parity` only compares files both compilers accept, and
# `lint_parity` runs `lint`, which never reports a semantic error.
#
# Usage:
#   ruby tools/check_parity.rb [TARGET...] [options]
#   TARGET           files or directories       (default: std examples projects/mtc/src)
#   --self PATH      self-host compiler binary  (default: build/stage2/mtc)
#   --host CMD       host compiler command      (default: ruby -Ilib bin/mtc)
#   -j N             parallel workers           (default: 8)
#   --timeout SEC    per-invocation timeout     (default: 180)
#   -q, --quiet      print only the summary
#   --max-files N    print at most N differing files (default: 20)
#   --host-cache F   cache host outputs in F (a JSON file)
#   -h, --help       show this message
#
# Exit status: 0 when every file's output is byte-identical, 1 otherwise.

require "digest"
require "json"
require "open3"
require "optparse"

ROOT = File.expand_path("..", __dir__)
options = {
  self: File.join(ROOT, "build/stage2/mtc"),
  host: ["ruby", "-Ilib", "bin/mtc", "check"],
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
  opts.on("--host-cache FILE") { |v| options[:host_cache] = File.expand_path(v, ROOT) }
  opts.on("-h", "--help") { puts opts; exit 0 }
end.parse!
targets = ARGV.empty? ? %w[std examples projects/mtc/src] : ARGV

abort "self-host binary not found: #{options[:self]}" unless File.executable?(options[:self])

files = targets.flat_map do |target|
  path = File.expand_path(target, ROOT)
  if File.directory?(path)
    Dir.glob(File.join(path, "**", "*.mt")).reject { |f| File.basename(f).start_with?("__mt_test_runner_") }.sort
  else
    [path]
  end
end.uniq

def run_check(command, file, timeout)
  out, err, status = Open3.capture3("timeout", timeout.to_s, *command, file, chdir: ROOT)
  return "<timeout after #{timeout}s>" if status.exitstatus == 124

  "--- stdout ---\n#{out}--- stderr ---\n#{err}--- exit #{status.exitstatus} ---"
end

# Host-output cache: the host runs one Ruby process per file, so its outputs
# are cached per file digest plus a digest of the host compiler's own sources.
host_cache = nil
digests = {}
if options[:host_cache]
  host_version = Digest::SHA256.hexdigest(
    Dir.glob([File.join(ROOT, "lib/**/*.rb"), File.join(ROOT, "bin/mtc")]).sort
       .map { |f| "#{f}:#{Digest::SHA256.file(f).hexdigest}" }
       .join("\n")
  )
  if File.exist?(options[:host_cache])
    cached = JSON.parse(File.read(options[:host_cache])) rescue {}
    host_cache = cached if cached["version"] == host_version
  end
  host_cache ||= { "version" => host_version, "files" => {} }
end

def cached_host(cache, file)
  return nil unless cache

  digest = Digest::SHA256.file(file).hexdigest
  entry = cache["files"][file]
  return nil unless entry && entry["digest"] == digest

  entry["output"]
end

def store_host(cache, file, output)
  return unless cache

  cache["files"][file] = { "digest" => Digest::SHA256.file(file).hexdigest, "output" => output }
end

def flush_cache(cache, path)
  return unless cache && path

  File.write(path, JSON.generate(cache))
end

results = []
mutex = Mutex.new
queue = Queue.new
files.each { |f| queue << f }
workers = [options[:jobs], files.length].min
workers = 1 if workers < 1

threads = workers.times.map do
  Thread.new do
    loop do
      file = begin
        queue.pop(true)
      rescue ThreadError
        break
      end
      rel = file.sub("#{ROOT}/", "")
      host_out = cached_host(host_cache, file)
      if host_out.nil?
        host_out = run_check(options[:host], file, options[:timeout])
        store_host(host_cache, file, host_out)
      end
      self_out = run_check([options[:self], "check"], file, options[:timeout])
      mutex.synchronize { results << [rel, host_out, self_out] }
    end
  end
end
threads.each(&:join)
flush_cache(host_cache, options[:host_cache])

results.sort_by!(&:first)
differ = results.select { |(_, h, s)| h != s }

results.each do |(rel, host_out, self_out)|
  next if host_out == self_out
  break if differ.index([rel, host_out, self_out]).to_i >= options[:max_files]
end

unless options[:quiet]
  shown = 0
  differ.each do |(rel, host_out, self_out)|
    break if shown >= options[:max_files]

    shown += 1
    puts "=== #{rel}"
    puts "--- host"
    puts host_out
    puts "--- self"
    puts self_out
  end
  puts "(showing #{shown} of #{differ.length} differing files)" if differ.length > shown
end

puts "files=#{results.length} agree=#{results.length - differ.length} differ=#{differ.length}"
exit(differ.empty? ? 0 : 1)
