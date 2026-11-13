#!/usr/bin/env ruby
# frozen_string_literal: true

# Diagnostic parity: compare what the two compilers *report* about a file,
# independent of how they render it.
#
# The existing sweeps only compare files both compilers accept:
#   * `sexpr_parity` skips a file the host rejects (the "host-rejected" bucket),
#     so a disagreement about *whether* a file is valid is invisible;
#   * `cli_parity`'s `check`/`parse` fixtures abort at their first error.
# This harness compares the diagnostic verdict itself: exit status, the
# `code: message` set, and the positions.
#
# Usage:
#   ruby tools/diag_parity.rb [TARGET...] [options]
#   ruby tools/diag_parity.rb parse [TARGET...]    # parse diagnostics only
#   ruby tools/diag_parity.rb check [TARGET...]    # check diagnostics only
#   TARGET           files or directories       (default: std examples projects/mtc/src)
#   --self PATH      self-host compiler binary  (default: build/stage2/mtc)
#   -j N             parallel workers           (default: 8)
#   --timeout SEC    per-invocation timeout     (default: 120)
#   --max-files N    print at most N differing files (default: 10)
#   -q, --quiet      print only the summary
#   -h, --help       show this message
#
# Exit status: 0 when every file's diagnostic set matches, 1 otherwise.

require "open3"
require "optparse"

ROOT = File.expand_path("..", __dir__)
mode = "check"
argv = ARGV.dup
mode = argv.shift if %w[parse check].include?(argv.first)

options = {
  self: File.join(ROOT, "build/stage2/mtc"),
  jobs: 8,
  timeout: 120,
  quiet: false,
  max_files: 10,
}
OptionParser.new do |opts|
  opts.on("--self PATH") { |v| options[:self] = File.expand_path(v, ROOT) }
  opts.on("-j N", Integer) { |v| options[:jobs] = v }
  opts.on("--timeout SEC", Integer) { |v| options[:timeout] = v }
  opts.on("-q", "--quiet") { options[:quiet] = true }
  opts.on("--max-files N", Integer) { |v| options[:max_files] = v }
  opts.on("-h", "--help") { puts opts; exit 0 }
end.parse!(argv)

targets = argv.empty? ? %w[std examples projects/mtc/src] : argv
files = targets.flat_map do |t|
  p = File.expand_path(t, ROOT)
  File.directory?(p) ? Dir.glob(File.join(p, "**", "*.mt")).sort : [p]
end.reject { |f| File.basename(f).start_with?("__mt_test_runner_") }.uniq

# Host: `warning[unused-local]: msg -- path:2:9` blocks on stderr.
# Self (check): `path:2: unused-local: msg` one-liners on stdout.
# Self (parse): `parse error: L7:22 lexeme=')' kind=rparen: msg`.
HOST_DIAG = /^(error|warning|hint|info)\[([^\]]+)\]: (.*?) -- (.*):(\d+):(\d+)$/
SELF_DIAG = /^(.*):(\d+): ([a-z0-9-]+): (.*)$/
SELF_PARSE = /^parse error: L(\d+):(\d+) lexeme='.*?' kind=\S+: (.*)$/

def norm_msg(msg)
  # The host embeds the location in some message text; the renderer strips it.
  msg.sub(/ at .*:\d+:\d+\z/, "").strip
end

def diags(mode, stdout, stderr)
  out = []
  (stderr + stdout).each_line do |line|
    line = line.chomp
    if (m = line.match(HOST_DIAG))
      _sev, code, msg, _path, l, c = m.captures
      out << [code, norm_msg(msg), l.to_i, c.to_i, :host_format]
    elsif (m = line.match(SELF_DIAG))
      _path, l, code, msg = m.captures
      out << [code, norm_msg(msg), l.to_i, c.to_i, :one_line]
    elsif (m = line.match(SELF_PARSE))
      l, c, msg = m.captures
      out << ["parse/error", norm_msg(msg), l.to_i, c.to_i, :self_parse]
    end
  end
  out
end

# Compare on code + message (positions are reported separately: a same-message
# different-position is a position bug, a different message is a wording bug).
queue = Queue.new
files.each { |f| queue << f }
res = []
mutex = Mutex.new
threads = [options[:jobs], files.length].min.times.map do
  Thread.new do
    loop do
      f = begin
        queue.pop(true)
      rescue ThreadError
        break
      end
      # Only the generated self binary needs the memory cap; the Ruby host is
      # itself a large process and aborts under a 20 GB `ulimit -v`.
      hout, herr, hs = Open3.capture3("timeout", options[:timeout].to_s, "ruby", "-Ilib", "bin/mtc", mode, f, chdir: ROOT)
      # A Ruby host killed by a signal is an out-of-memory casualty of running
      # many hosts in parallel, not a disagreement: retry it alone.
      if hs.exitstatus.nil? && hs.termsig
        hout, herr, hs = Open3.capture3("timeout", options[:timeout].to_s, "ruby", "-Ilib", "bin/mtc", mode, f, chdir: ROOT)
      end
      sout, serr, ss = Open3.capture3(
        "bash", "-c", "ulimit -v 20000000; exec \"$0\" \"$@\"",
        options[:self], mode, f, chdir: ROOT
      )
      hd = diags(mode, hout, herr).map { |d| d[0, 4] }
      sd = diags(mode, sout, serr).map { |d| d[0, 4] }
      hrc = hs.exitstatus || 128 + hs.termsig.to_i
      src = ss.exitstatus || 128 + ss.termsig.to_i
      mutex.synchronize { res << [f.sub("#{ROOT}/", ""), hrc, src, hd.sort, sd.sort] }
    end
  end
end
threads.each(&:join)
res.sort_by!(&:first)

verdict_differ = res.select { |(_f, hrc, src, _h, _s)| (hrc.zero?) != (src.zero?) }
msg_differ = res.select { |(_f, hrc, src, h, s)| (hrc.zero? == src.zero?) && h.map { |d| d[0, 2] } != s.map { |d| d[0, 2] } }
pos_differ = res.select { |(_f, hrc, src, h, s)| (hrc.zero? == src.zero?) && h.map { |d| d[0, 2] } == s.map { |d| d[0, 2] } && h != s }
agree = res.length - verdict_differ.length - msg_differ.length - pos_differ.length

unless options[:quiet]
  { "VERDICT (one accepts, the other rejects)" => verdict_differ,
    "MESSAGE (same verdict, different diagnostics)" => msg_differ,
    "POSITION (same diagnostics, different positions)" => pos_differ }.each do |label, list|
    next if list.empty?

    puts "── #{label}: #{list.length}"
    list.first(options[:max_files]).each do |(f, hrc, src, h, s)|
      puts "  #{f}  host rc=#{hrc} self rc=#{src}"
      (h - s).first(3).each { |d| puts "    host-only: #{d[2]}:#{d[3]} #{d[0]}: #{d[1]}" }
      (s - h).first(3).each { |d| puts "    self-only: #{d[2]}:#{d[3]} #{d[0]}: #{d[1]}" }
    end
    puts "  (showing #{[list.length, options[:max_files]].min} of #{list.length})" if list.length > options[:max_files]
  end
end

puts "mode=#{mode} files=#{res.length} agree=#{agree} verdict=#{verdict_differ.length} message=#{msg_differ.length} position=#{pos_differ.length}"
exit(agree == res.length ? 0 : 1)
