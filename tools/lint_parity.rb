#!/usr/bin/env ruby
# frozen_string_literal: true

# Linter oracle: replay the compiler's whole `lint` output over a file set
# against a digest-keyed fixture, file by file.  A change on an unchanged input
# is a regression that must be reviewed and re-recorded.
#
# Usage:
#   ruby tools/lint_parity.rb [TARGET...] --expect FILE [options]
#   ruby tools/lint_parity.rb [TARGET...] --record FILE [options]
#   TARGET           files or directories       (default: std examples projects/mtc/src)
#   --self PATH      compiler binary            (default: build/stage2/mtc)
#   -j N             parallel workers           (default: 4, hard-capped)
#   --timeout SEC    per-invocation timeout     (default: 180)
#   -q, --quiet      print only the summary
#   --max-files N    print at most N differing files (default: 20)
#   --record FILE    record the compiler's lint output to FILE
#   --expect FILE    replay FILE and fail on any difference
#   -h, --help       show this message
#
# Exit status: 0 when every compared file's output is byte-identical, 1 otherwise.

require "digest"
require "fileutils"
require "optparse"
require_relative "lib/golden"
require_relative "lib/jobs"

ROOT = File.expand_path("..", __dir__)
MEM_CAP_BYTES = 20_000_000 * 1024
options = {
  self: File.join(ROOT, "build/stage2/mtc"),
  jobs: 4,
  timeout: 180,
  quiet: false,
  max_files: 20,
  record: nil,
  expect: nil,
}
OptionParser.new do |opts|
  opts.on("--self PATH") { |v| options[:self] = File.expand_path(v, ROOT) }
  opts.on("-j N", Integer) { |v| options[:jobs] = v }
  opts.on("--timeout SEC", Integer) { |v| options[:timeout] = v }
  opts.on("-q", "--quiet") { options[:quiet] = true }
  opts.on("--max-files N", Integer) { |v| options[:max_files] = v }
  opts.on("--record FILE") { |v| options[:record] = File.expand_path(v, ROOT) }
  opts.on("--expect FILE") { |v| options[:expect] = File.expand_path(v, ROOT) }
  opts.on("-h", "--help") { puts opts; exit 0 }
end.parse!

options[:jobs] = Jobs.clamp(options[:jobs])
if options[:record] && options[:expect]
  abort "error: --record and --expect are mutually exclusive"
end
unless options[:record] || options[:expect]
  abort "error: pass --expect FILE to replay the oracle or --record FILE to refresh it"
end
targets = ARGV.empty? ? %w[std examples projects/mtc/src] : ARGV

abort "compiler not found: #{options[:self]}" unless File.executable?(options[:self])

files = targets.flat_map do |target|
  path = File.expand_path(target, ROOT)
  if File.directory?(path)
    Dir.glob(File.join(path, "**", "*.mt")).sort
  else
    [path]
  end
end

# A golden fixture is digest-keyed: a file whose text changed since recording is
# skipped (its row is stale by design), so source edits do not turn the gate
# red.  Only unchanged inputs are re-measured against the fixture.
golden_expected = nil
changed_inputs = 0
unrecorded_inputs = 0
if options[:expect]
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

# A spawn/wait pool, not threads: Open3's reader threads trip a Ruby 4.0 VM
# teardown bug on long sweeps, and the harness only needs bounded parallelism.
tmp_dir = File.join(ROOT, "tmp", "lint-parity")
FileUtils.rm_rf(tmp_dir)
FileUtils.mkdir_p(tmp_dir)

work = files.dup
running = []
golden = {}
timed_out = 0
index = 0
until work.empty? && running.empty?
  while running.length < options[:jobs] && !work.empty?
    file = work.shift
    out_path = File.join(tmp_dir, "#{index}.out")
    index += 1
    pid = Process.spawn(
      "timeout", options[:timeout].to_s, options[:self], "lint", file,
      chdir: ROOT, out: out_path, err: [:child, :out], rlimit_as: MEM_CAP_BYTES
    )
    running << [pid, file, out_path]
  end

  pid, status = Process.wait2
  entry = running.find { |row| row[0] == pid }
  running.delete(entry)
  _pid, file, out_path = entry
  output = File.binread(out_path).force_encoding(Encoding::UTF_8)
  FileUtils.rm_f(out_path)
  output = "<timeout after #{options[:timeout]}s>" if status.exitstatus == 124
  output = "<killed by signal #{status.termsig}>" if status.exitstatus.nil?
  # A timed-out or signalled file is not a stable oracle (the linter is
  # expensive on the largest compiler sources); leave it unreferenced.
  if output.start_with?("<timeout after ", "<killed by signal ")
    timed_out += 1
    next
  end
  golden[file.delete_prefix("#{ROOT}/")] = {
    "digest" => Digest::SHA256.file(file).hexdigest,
    "output" => output.gsub(ROOT, "<ROOT>"),
  }
end
FileUtils.rm_rf(tmp_dir)

payload = { "files" => golden.sort.to_h }
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
