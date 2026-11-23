#!/usr/bin/env ruby
# frozen_string_literal: true

# Diagnostic oracle: replay the compiler's per-file diagnostic verdict — exit
# status, the `code: message` set, and the positions — against a digest-keyed
# fixture.  A diagnostic change on an unchanged input is a regression that must
# be reviewed and re-recorded.
#
# Usage:
#   ruby tools/diag_parity.rb [TARGET...] --expect FILE [options]
#   ruby tools/diag_parity.rb [TARGET...] --record FILE [options]
#   ruby tools/diag_parity.rb parse [TARGET...]    # parse diagnostics only
#   ruby tools/diag_parity.rb check [TARGET...]    # check diagnostics only
#   TARGET           files or directories       (default: std examples projects/mtc/src)
#   --self PATH      compiler binary            (default: build/stage2/mtc)
#   -j N             parallel workers           (default: 4, hard-capped)
#   --timeout SEC    per-invocation timeout     (default: 120)
#   --max-files N    print at most N differing files (default: 10)
#   -q, --quiet      print only the summary
#   --record FILE    record the compiler's diagnostics to FILE
#   --expect FILE    replay FILE and fail on any difference
#   -h, --help       show this message
#
# Exit status: 0 when every compared file matches, 1 otherwise.

require "digest"
require "fileutils"
require "optparse"
require_relative "lib/golden"
require_relative "lib/jobs"

ROOT = File.expand_path("..", __dir__)
MEM_CAP_BYTES = 20_000_000 * 1024

mode = "check"
argv = ARGV.dup
mode = argv.shift if %w[parse check].include?(argv.first)

options = {
  self: File.join(ROOT, "build/stage2/mtc"),
  jobs: 4,
  timeout: 120,
  quiet: false,
  max_files: 10,
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
end.parse!(argv)

options[:jobs] = Jobs.clamp(options[:jobs])
if options[:record] && options[:expect]
  abort "error: --record and --expect are mutually exclusive"
end
unless options[:record] || options[:expect]
  abort "error: pass --expect FILE to replay the oracle or --record FILE to refresh it"
end

targets = argv.empty? ? %w[std examples projects/mtc/src] : argv
files = targets.flat_map do |t|
  p = File.expand_path(t, ROOT)
  File.directory?(p) ? Dir.glob(File.join(p, "**", "*.mt")).sort : [p]
end.reject { |f| File.basename(f).start_with?("__mt_test_runner_") }.uniq

abort "compiler not found: #{options[:self]}" unless File.executable?(options[:self])

# A diagnostic block renders its location as `-- path:line:col`.
BLOCK_DIAG = /^(error|warning|hint|info)\[([^\]]+)\]: (.*?) -- (.*):(\d+):(\d+)$/
# A one-line diagnostic (`path:line: code: msg`) carries no column.
ONE_LINE_DIAG = /^(.*):(\d+): ([a-z0-9-]+): (.*)$/
# Parse failures use `parse error: L7:22 lexeme=')' kind=rparen: msg`.
SELF_PARSE = /^parse error: L(\d+):(\d+) lexeme='.*?' kind=\S+: (.*)$/

def norm_msg(msg)
  msg.sub(/ at .*:\d+:\d+\z/, "").strip
end

def diags(stdout, stderr)
  out = []
  (stderr + stdout).each_line do |line|
    line = line.chomp
    if (m = line.match(BLOCK_DIAG))
      _sev, code, msg, _path, l, c = m.captures
      out << [code, norm_msg(msg), l.to_i, c.to_i]
    elsif (m = line.match(ONE_LINE_DIAG))
      _path, l, code, msg = m.captures
      out << [code, norm_msg(msg), l.to_i, 0]
    elsif (m = line.match(SELF_PARSE))
      l, c, msg = m.captures
      out << ["parse/error", norm_msg(msg), l.to_i, c.to_i]
    end
  end
  out
end

# A golden fixture is digest-keyed: a file whose text changed since recording is
# skipped (its row is stale by design), so source edits do not turn the gate
# red.  Only unchanged inputs are re-measured against the fixture.
golden_expected = nil
changed_inputs = 0
unrecorded_inputs = 0
if options[:expect]
  golden_expected = Golden.read(options[:expect], "diag_parity")
  unless golden_expected["mode"] == mode
    abort "error: fixture mode #{golden_expected['mode'].inspect} does not match #{mode.inspect}"
  end
  selected = []
  files.each do |f|
    relative = f.sub("#{ROOT}/", "")
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
tmp_dir = File.join(ROOT, "tmp", "diag-parity")
FileUtils.rm_rf(tmp_dir)
FileUtils.mkdir_p(tmp_dir)

work = files.dup
running = []
golden = {}
index = 0
until work.empty? && running.empty?
  while running.length < options[:jobs] && !work.empty?
    file = work.shift
    out_path = File.join(tmp_dir, "#{index}.out")
    err_path = File.join(tmp_dir, "#{index}.err")
    index += 1
    pid = Process.spawn(
      "timeout", options[:timeout].to_s, options[:self], mode, file,
      chdir: ROOT, out: out_path, err: err_path, rlimit_as: MEM_CAP_BYTES
    )
    running << [pid, file, out_path, err_path]
  end

  pid, status = Process.wait2
  entry = running.find { |row| row[0] == pid }
  running.delete(entry)
  _pid, file, out_path, err_path = entry
  stdout = File.binread(out_path).force_encoding(Encoding::UTF_8)
  stderr = File.binread(err_path).force_encoding(Encoding::UTF_8)
  FileUtils.rm_f([out_path, err_path])
  rc = status.exitstatus || 128 + status.termsig.to_i
  relative = file.sub("#{ROOT}/", "")
  golden[relative] = {
    "digest" => Digest::SHA256.file(file).hexdigest,
    "rc" => rc,
    "diags" => diags(stdout, stderr).sort,
  }
end
FileUtils.rm_rf(tmp_dir)

payload = { "mode" => mode, "files" => golden.sort.to_h }
if options[:record]
  Golden.write(options[:record], "diag_parity", payload)
  puts "recorded #{golden.length} file(s) -> #{options[:record]}" unless options[:quiet]
  exit 0
end

expected = {}
actual = {}
golden.each do |relative, row|
  recorded_row = golden_expected["files"][relative]
  expected[relative] = { "rc" => recorded_row["rc"], "diags" => recorded_row["diags"] }
  actual[relative] = { "rc" => row["rc"], "diags" => row["diags"] }
end
diffs = Golden.diff(expected, actual)
puts "mode=#{mode} files=#{golden.length} changed=#{changed_inputs} " \
     "unrecorded=#{unrecorded_inputs} differ=#{diffs.length}"
diffs.first(options[:max_files] * 4).each { |line| puts "  #{line}" }
exit(diffs.empty? ? 0 : 1)
