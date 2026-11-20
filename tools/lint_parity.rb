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
#   -j N             parallel workers           (default: 4, hard-capped)
#   --timeout SEC    per-invocation timeout     (default: 180)
#   -q, --quiet      print only the summary
#   --max-files N    print at most N differing files (default: 20)
#   --host-cache F   cache host outputs in F (a JSON file); entries are reused
#                    when the file's digest matches, and the whole cache is
#                    dropped when the host compiler's sources change.  The
#                    self-host side always runs live.
#   --record FILE    record the self's lint output to FILE (host-free)
#   --expect FILE    replay FILE and fail on any difference (host-free)
#   -h, --help       show this message
#
# Exit status: 0 when every file's output is byte-identical, 1 otherwise.

require "digest"
require "json"
require "open3"
require "optparse"
require_relative "lib/golden"
require_relative "lib/jobs"

ROOT = File.expand_path("..", __dir__)
options = {
  self: File.join(ROOT, "build/stage2/mtc"),
  host: ["ruby", "-Ilib", "bin/mtc", "lint"],
  jobs: 4,
  timeout: 180,
  quiet: false,
  max_files: 20,
  record: nil,
  expect: nil,
}
OptionParser.new do |opts|
  opts.on("--self PATH") { |v| options[:self] = File.expand_path(v, ROOT) }
  opts.on("--host CMD") { |v| options[:host] = v.split }
  opts.on("-j N", Integer) { |v| options[:jobs] = v }
  opts.on("--timeout SEC", Integer) { |v| options[:timeout] = v }
  opts.on("-q", "--quiet") { options[:quiet] = true }
  opts.on("--max-files N", Integer) { |v| options[:max_files] = v }
  opts.on("--host-cache FILE") { |v| options[:host_cache] = File.expand_path(v, ROOT) }
  opts.on("--record FILE") { |v| options[:record] = File.expand_path(v, ROOT) }
  opts.on("--expect FILE") { |v| options[:expect] = File.expand_path(v, ROOT) }
  opts.on("-h", "--help") { puts opts; exit 0 }
end.parse!

options[:jobs] = Jobs.clamp(options[:jobs])
if options[:record] && options[:expect]
  abort "error: --record and --expect are mutually exclusive"
end
recorded = !options[:record].nil? || !options[:expect].nil?
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
  return "<timeout after #{timeout}s>" if status.exitstatus == 124
  # A signalled process (OOM killer, for one) captured no output; make that
  # explicit so it is never mistaken for a clean run.
  return "<killed by signal #{status.termsig}>" if status.exitstatus.nil?

  out
end

# Host-output cache.  The host is deterministic but expensive (one Ruby
# process per file), so its outputs are cached per file digest; the *self*
# side is what changes while iterating and always runs live.  A change to the
# host compiler's own sources drops the whole cache.
host_cache = nil
digests = {}
if options[:host_cache]
  host_version = Digest::SHA256.hexdigest(
    Dir.glob([File.join(ROOT, "lib/**/*.rb"), File.join(ROOT, "bin/mtc")]).sort
       .map { |f| "#{f}:#{Digest::SHA256.file(f).hexdigest}" }
       .join("\n")
  )
  host_cache = { "version" => host_version, "commands" => [options[:host]], "files" => {} }
  if File.exist?(options[:host_cache])
    loaded = begin
      JSON.parse(File.read(options[:host_cache]))
    rescue JSON::ParserError
      {}
    end
    if loaded["version"] == host_version && loaded["commands"] == [options[:host]]
      host_cache["files"] = loaded["files"] || {}
    end
  end
  files.each { |f| digests[f] = Digest::SHA256.file(f).hexdigest }
end
cache_mutex = Mutex.new

def host_lint(options, host_cache, digests, cache_mutex, file)
  return lint_output(options[:host], file, options[:timeout]) if host_cache.nil?

  key = file.delete_prefix("#{ROOT}/")
  digest = digests[file]
  cache_mutex.synchronize do
    entry = host_cache["files"][key]
    return entry[1] if entry && entry[0] == digest
  end
  out = lint_output(options[:host], file, options[:timeout])
  cache_mutex.synchronize { host_cache["files"][key] = [digest, out] }
  out
end

def rule_tally(text)
  text.lines.filter_map { |line| line[%r{^\S+\.mt:\d+: ([a-z-]+):}, 1] }.tally
end

# The host linter swallows lex/parse/sema errors and lints the AST anyway, so a
# rejection shows up as an error block with no warning lines.  Treat that as
# "host could not analyze" rather than "host emitted zero warnings".
def analysis_failure?(text)
  rule_tally(text).empty? &&
    text.lines.any? { |line| line.start_with?("error[") || line.start_with?("error: ") }
end

# A golden fixture is digest-keyed: a file whose text changed since recording is
# skipped (its row is stale by design), so source edits do not turn the gate
# red.  Only unchanged inputs are re-measured against the fixture.
golden_expected = nil
changed_inputs = 0
unrecorded_inputs = 0
if recorded && options[:expect]
  golden_expected = Golden.read(options[:expect], "lint_parity")
  selected = []
  files.each do |f|
    relative = f.delete_prefix("#{ROOT}/")
    row = golden_expected["files"][relative]
    if row.nil?
      unrecorded_inputs += 1
    elsif row["digest"] == Digest::SHA256.file(f).hexdigest
      selected << f
    else
      changed_inputs += 1
    end
  end
  files = selected
end

results = Queue.new
files.each { |f| results << f }

diffs = []
hostfail = []
selffail = []
golden = {}
timed_out = 0
mutex = Mutex.new
workers = Array.new(options[:jobs]) do
  Thread.new do
    loop do
      file = begin
        results.pop(true)
      rescue ThreadError
        break
      end
      self_host = lint_output([options[:self], "lint"], file, options[:timeout])
      relative = file.delete_prefix("#{ROOT}/")
      if recorded
        # A timed-out or signalled file is not a stable oracle (the self linter
        # is slow and memory-hungry on the largest compiler sources); leave it
        # unreferenced.
        if self_host.start_with?("<timeout after ", "<killed by signal ")
          mutex.synchronize { timed_out += 1 }
          next
        end
        mutex.synchronize do
          golden[relative] = {
            "digest" => Digest::SHA256.file(file).hexdigest,
            "output" => self_host.gsub(ROOT, "<ROOT>"),
          }
        end
        next
      end

      host = host_lint(options, host_cache, digests, cache_mutex, file)
      if analysis_failure?(host)
        mutex.synchronize { hostfail << [relative, host] }
      elsif analysis_failure?(self_host)
        mutex.synchronize { selffail << [relative, self_host] }
      elsif host != self_host
        mutex.synchronize { diffs << [relative, host, self_host] }
      end
    end
  end
end
workers.each(&:join)

if recorded
  payload = { "files" => golden }
  if options[:record]
    Golden.write(options[:record], "lint_parity", payload)
    puts "recorded #{golden.length} file(s) (#{timed_out} timed out) -> #{options[:record]}" unless options[:quiet]
    exit 0
  end

  expected = {}
  actual = {}
  golden.each do |relative, row|
    recorded_row = golden_expected["files"][relative]
    expected[relative] = { "output" => recorded_row["output"] }
    actual[relative] = { "output" => row["output"] }
  end
  diffs = Golden.diff(expected, actual)
  puts "files=#{golden.length} changed=#{changed_inputs} " \
       "unrecorded=#{unrecorded_inputs} differ=#{diffs.length}"
  diffs.first(options[:max_files] * 2).each { |line| puts "  #{line}" }
  exit(diffs.empty? ? 0 : 1)
end

if options[:host_cache]
  tmp_path = "#{options[:host_cache]}.tmp"
  File.write(tmp_path, JSON.generate(host_cache))
  File.rename(tmp_path, options[:host_cache])
end

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
hostfail.first(options[:max_files]).each do |relative, output|
  detail = output.lines.find { |line| line.start_with?("error[", "error: ") }.to_s.strip
  puts "HOST-FAIL #{relative}: #{detail}"
end
selffail.first(options[:max_files]).each do |relative, output|
  detail = output.lines.find { |line| line.start_with?("error[", "error: ") }.to_s.strip
  puts "SELF-FAIL #{relative}: #{detail}"
end
agree = files.size - diffs.size - hostfail.size - selffail.size
puts "files=#{files.size} agree=#{agree} differ=#{diffs.size} " \
     "hostfail=#{hostfail.size} selffail=#{selffail.size} (jobs=#{options[:jobs]})"
exit(diffs.empty? && selffail.empty? ? 0 : 1)
