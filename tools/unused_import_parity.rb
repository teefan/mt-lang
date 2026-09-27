#!/usr/bin/env ruby
# frozen_string_literal: true

# Compare the self-host and Ruby host linters' `unused-import` warnings over a
# file set.  Both linters must agree file by file: the host credits imports
# through its semantic facts (receiver types, extension methods, hook
# providers) and its lexical name collection, so any disagreement is a
# linter-fidelity bug on our side.
#
# Usage:
#   ruby tools/unused_import_parity.rb [TARGET...] [options]
#   TARGET    files or directories               (default: std examples projects/mtc/src)
#   --self PATH      self-host compiler binary   (default: build/stage2/mtc)
#   --host CMD       host compiler command       (default: ruby -Ilib bin/mtc)
#   -q, --quiet      print only the summary
#   -h, --help       show this message
#
# Exit status: 0 when every file agrees, 1 otherwise.
#
# Known residual (documented): `examples/async_network_lobby.mt` — a match-arm
# payload binding is typed `ty_error` by our analyzer, so a `Vec` receiver
# cannot be attributed to `import std.vec`; the host's analyzer types it.

require "open3"
require "optparse"

ROOT = File.expand_path("..", __dir__)
options = { self: File.join(ROOT, "build/stage2/mtc"), quiet: false }
OptionParser.new do |opts|
  opts.on("--self PATH") { |v| options[:self] = File.expand_path(v, ROOT) }
  opts.on("-q", "--quiet") { options[:quiet] = true }
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

unused_import_lines = lambda do |command, file|
  out, = Open3.capture2e(*command, file, chdir: ROOT)
  out.lines.select { |line| line.include?("unused-import:") }.sort
end

mismatches = []
files.each do |file|
  relative = file.delete_prefix("#{ROOT}/")
  host = unused_import_lines.call(["ruby", "-Ilib", "bin/mtc", "lint"], file)
  self_host = unused_import_lines.call([options[:self], "lint"], file)
  next if host == self_host

  mismatches << [relative, host, self_host]
end

unless options[:quiet]
  mismatches.each do |relative, host, self_host|
    puts "#{relative}: host #{host.size} / self #{self_host.size}"
    (host - self_host).each { |line| puts "  host-only: #{line.strip}" }
    (self_host - host).each { |line| puts "  self-only: #{line.strip}" }
  end
end
puts "files=#{files.size} agree=#{files.size - mismatches.size} differ=#{mismatches.size}"
exit(mismatches.empty? ? 0 : 1)
